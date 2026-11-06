//! Structural PDF operations. No renderer or signature preservation.
use lopdf::{Document, LoadOptions, Object, ObjectId};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Read,
    path::Path,
};
use suite42_core::{write_new, SnapshotHistory};
const MAX_FILE: u64 = 64 * 1024 * 1024;
const MAX_PAGES: usize = 1000;
#[derive(Clone)]
struct State {
    pages: Vec<ObjectId>,
    rotations: HashMap<ObjectId, i64>,
    selected: ObjectId,
}
impl PartialEq for State {
    fn eq(&self, other: &Self) -> bool {
        self.pages == other.pages && self.rotations == other.rotations
    }
}
pub struct PdfDocument {
    doc: Document,
    root: ObjectId,
    original_pages: Vec<ObjectId>,
    flat: bool,
    history: SnapshotHistory<State>,
}

fn collect_pages(
    doc: &Document,
    id: ObjectId,
    parent: Option<ObjectId>,
    depth: usize,
    seen: &mut HashSet<ObjectId>,
    pages: &mut Vec<ObjectId>,
) -> Result<(), String> {
    if depth > 64 || !seen.insert(id) || seen.len() > MAX_PAGES * 2 {
        return Err("invalid or excessively large page tree".into());
    }
    let node = doc.get_dictionary(id).map_err(|e| e.to_string())?;
    if let Some(parent) = parent {
        if node.get(b"Parent").ok().and_then(|o| o.as_reference().ok()) != Some(parent) {
            return Err("invalid page parent".into());
        }
    }
    match node.get(b"Type").ok().and_then(|o| o.as_name().ok()) {
        Some(b"Page") => {
            pages.push(id);
            if pages.len() > MAX_PAGES {
                return Err("page limit exceeded".into());
            }
        }
        Some(b"Pages") => {
            let start = pages.len();
            let kids = node
                .get(b"Kids")
                .map_err(|e| e.to_string())?
                .as_array()
                .map_err(|e| e.to_string())?;
            if kids.is_empty() || kids.len() > MAX_PAGES {
                return Err("invalid Kids".into());
            }
            for kid in kids {
                collect_pages(
                    doc,
                    kid.as_reference().map_err(|e| e.to_string())?,
                    Some(id),
                    depth + 1,
                    seen,
                    pages,
                )?;
            }
            let count = node
                .get(b"Count")
                .map_err(|e| e.to_string())?
                .as_i64()
                .map_err(|e| e.to_string())?;
            if count != (pages.len() - start) as i64 {
                return Err("page count mismatch".into());
            }
        }
        _ => return Err("invalid page node".into()),
    }
    Ok(())
}
impl PdfDocument {
    pub fn open(path: &Path) -> Result<Self, String> {
        if fs::metadata(path).map_err(|e| e.to_string())?.len() > MAX_FILE {
            return Err("PDF exceeds file limit".into());
        }
        let mut data = Vec::new();
        fs::File::open(path)
            .map_err(|e| e.to_string())?
            .take(MAX_FILE + 1)
            .read_to_end(&mut data)
            .map_err(|e| e.to_string())?;
        if data.len() as u64 > MAX_FILE {
            return Err("PDF exceeds file limit".into());
        }
        let options = LoadOptions {
            max_decompressed_size: Some(32 * 1024 * 1024),
            ..Default::default()
        };
        let doc = Document::load_mem_with_options(&data, options).map_err(|e| e.to_string())?;
        if doc.is_encrypted() || doc.was_encrypted() {
            return Err("encrypted PDF unsupported".into());
        }
        // Inspect every object including direct nested dictionaries and stream dictionaries.
        let mut pending: Vec<&Object> = doc.objects.values().collect();
        pending.extend(doc.trailer.iter().map(|(_, value)| value));
        let mut inspected = 0usize;
        while let Some(object) = pending.pop() {
            inspected += 1;
            if inspected > 1_000_000 {
                return Err("PDF object inspection limit exceeded".into());
            }
            let dictionary = match object {
                Object::Dictionary(d) => Some(d),
                Object::Stream(s) => Some(&s.dict),
                Object::Array(a) => {
                    pending.extend(a);
                    None
                }
                _ => None,
            };
            if let Some(d) = dictionary {
                if d.get(b"ByteRange").is_ok()
                    || d.get(b"FT").ok().and_then(|o| o.as_name().ok()) == Some(b"Sig")
                    || d.get(b"Type").ok().and_then(|o| o.as_name().ok()) == Some(b"Sig")
                {
                    return Err("signature fields unsupported".into());
                }
                pending.extend(d.iter().map(|(_, value)| value));
            }
        }
        let root = doc
            .catalog()
            .map_err(|e| e.to_string())?
            .get(b"Pages")
            .map_err(|e| e.to_string())?
            .as_reference()
            .map_err(|e| e.to_string())?;
        let mut pages = Vec::new();
        collect_pages(&doc, root, None, 0, &mut HashSet::new(), &mut pages)?;
        if pages.is_empty() {
            return Err("empty page tree".into());
        }
        let flat = pages.iter().all(|id| {
            doc.get_dictionary(*id)
                .ok()
                .and_then(|d| d.get(b"Parent").ok())
                .and_then(|o| o.as_reference().ok())
                == Some(root)
        });
        let result = Self {
            doc,
            root,
            original_pages: pages.clone(),
            flat,
            history: SnapshotHistory::new(
                State {
                    selected: pages[0],
                    pages,
                    rotations: HashMap::new(),
                },
                20,
            ),
        };
        for i in 0..result.page_count() {
            result.rotation(i)?;
        }
        Ok(result)
    }
    /// Read a standard Info dictionary text value (e.g. Title or Author).
    pub fn metadata(&self, key: &str) -> Result<Option<String>, String> {
        if !matches!(
            key,
            "Title" | "Author" | "Subject" | "Keywords" | "Creator" | "Producer"
        ) {
            return Err("unsupported metadata key".into());
        }
        let info = match self.doc.trailer.get(b"Info") {
            Ok(info) => info,
            Err(_) => return Ok(None),
        };
        let dict = self
            .doc
            .dereference(info)
            .map_err(|e| e.to_string())?
            .1
            .as_dict()
            .map_err(|e| e.to_string())?;
        let value = match dict.get(key.as_bytes()) {
            Ok(value) => value,
            Err(_) => return Ok(None),
        };
        let value = self.doc.dereference(value).map_err(|e| e.to_string())?.1;
        lopdf::decode_text_string(value)
            .map(Some)
            .map_err(|e| e.to_string())
    }
    pub fn page_count(&self) -> usize {
        self.history.current().pages.len()
    }
    pub fn current(&self) -> usize {
        self.history
            .current()
            .pages
            .iter()
            .position(|id| *id == self.history.current().selected)
            .expect("valid selection")
    }
    pub fn select(&mut self, index: usize) -> Result<(), String> {
        let mut state = self.history.current().clone();
        state.selected = *state.pages.get(index).ok_or("page index out of range")?;
        self.history.replace_current(state);
        Ok(())
    }
    pub fn undo(&mut self) -> bool {
        self.history.undo()
    }
    pub fn redo(&mut self) -> bool {
        self.history.redo()
    }
    pub fn can_undo(&self) -> bool {
        self.history.can_undo()
    }
    pub fn can_redo(&self) -> bool {
        self.history.can_redo()
    }
    pub fn is_dirty(&self) -> bool {
        self.history.is_dirty()
    }
    pub fn rotation(&self, index: usize) -> Result<i64, String> {
        let id = *self
            .history
            .current()
            .pages
            .get(index)
            .ok_or("page index out of range")?;
        if let Some(value) = self.history.current().rotations.get(&id) {
            return Ok(*value);
        }
        self.base_rotation(id)
    }
    fn base_rotation(&self, id: ObjectId) -> Result<i64, String> {
        let mut node_id = id;
        let mut v = 0;
        loop {
            let node = self
                .doc
                .get_dictionary(node_id)
                .map_err(|e| e.to_string())?;
            if let Ok(value) = node.get(b"Rotate") {
                v = self
                    .doc
                    .dereference(value)
                    .map_err(|e| e.to_string())?
                    .1
                    .as_i64()
                    .map_err(|e| e.to_string())?;
                break;
            }
            if node_id == self.root {
                break;
            }
            node_id = node
                .get(b"Parent")
                .map_err(|e| e.to_string())?
                .as_reference()
                .map_err(|e| e.to_string())?;
        }
        if v % 90 != 0 {
            return Err("invalid rotation".into());
        }
        Ok(v.rem_euclid(360))
    }
    pub fn rotate(&mut self, index: usize, degrees: i64) -> Result<(), String> {
        if degrees % 90 != 0 {
            return Err("rotation must be a multiple of 90".into());
        }
        let angle = (self.rotation(index)? + degrees.rem_euclid(360)).rem_euclid(360);
        let mut state = self.history.current().clone();
        let id = state.pages[index];
        state.selected = id;
        if angle == self.base_rotation(id)? {
            state.rotations.remove(&id);
        } else {
            state.rotations.insert(id, angle);
        }
        self.history.apply(state);
        Ok(())
    }

    fn ensure_reorder_safe(&self) -> Result<(), String> {
        if !self.flat {
            return Err("deleting or reordering nested page trees unsupported".into());
        }
        let catalog = self.doc.catalog().map_err(|e| e.to_string())?;
        for key in [
            b"Outlines".as_slice(),
            b"Names",
            b"Dests",
            b"PageLabels",
            b"AcroForm",
            b"StructTreeRoot",
            b"OpenAction",
            b"Threads",
        ] {
            if catalog.get(key).is_ok() {
                return Err("page reordering with document navigation or forms unsupported".into());
            }
        }
        for id in &self.original_pages {
            if self
                .doc
                .get_dictionary(*id)
                .map_err(|e| e.to_string())?
                .get(b"Annots")
                .is_ok()
            {
                return Err("page reordering with annotations unsupported".into());
            }
        }
        Ok(())
    }
    /// Whether page-tree restructuring is supported, excluding selection boundaries.
    pub fn can_restructure(&self) -> bool {
        self.ensure_reorder_safe().is_ok()
    }
    pub fn delete(&mut self, index: usize) -> Result<(), String> {
        self.ensure_reorder_safe()?;
        let mut state = self.history.current().clone();
        if state.pages.len() == 1 {
            return Err("cannot delete last page".into());
        }
        if index >= state.pages.len() {
            return Err("page index out of range".into());
        }
        state.pages.remove(index);
        state.selected = state.pages[index.min(state.pages.len() - 1)];
        self.history.apply(state);
        Ok(())
    }
    pub fn move_page(&mut self, from: usize, to: usize) -> Result<(), String> {
        self.ensure_reorder_safe()?;
        let mut state = self.history.current().clone();
        if from >= state.pages.len() || to >= state.pages.len() {
            return Err("page index out of range".into());
        }
        let page = state.pages.remove(from);
        state.selected = page;
        state.pages.insert(to, page);
        self.history.apply(state);
        Ok(())
    }
    pub fn save_as(&mut self, path: &Path) -> Result<(), String> {
        // Export from a disposable copy: pruning must not destroy undo state.
        let mut doc = self.doc.clone();
        let state = self.history.current();
        for (&id, &rotation) in &state.rotations {
            doc.get_dictionary_mut(id)
                .map_err(|e| e.to_string())?
                .set("Rotate", rotation);
        }
        if state.pages != self.original_pages {
            let root = doc
                .get_dictionary_mut(self.root)
                .map_err(|e| e.to_string())?;
            root.set(
                "Kids",
                state
                    .pages
                    .iter()
                    .map(|id| Object::Reference(*id))
                    .collect::<Vec<_>>(),
            );
            root.set("Count", state.pages.len() as i64);
            doc.prune_objects();
            if self
                .original_pages
                .iter()
                .filter(|id| !state.pages.contains(id))
                .any(|id| doc.objects.contains_key(id))
            {
                return Err("deleted pages remain referenced; cannot safely save".into());
            }
        }
        let mut out = Vec::new();
        doc.save_to(&mut out).map_err(|e| e.to_string())?;
        if out.len() as u64 > MAX_FILE * 2 {
            return Err("output exceeds limit".into());
        }
        write_new(path, &out).map_err(|e| e.to_string())?;
        self.history.mark_saved();
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::dictionary;
    fn sample(path: &Path, signed: bool) {
        let mut d = Document::with_version("1.5");
        let root = d.new_object_id();
        let mut kids = Vec::new();
        for _ in 0..3 {
            let p=d.add_object(dictionary!{"Type"=>"Page","Parent"=>root,"MediaBox"=>vec![0.into(),0.into(),200.into(),300.into()]});
            kids.push(Object::Reference(p));
        }
        d.objects.insert(
            root,
            Object::Dictionary(dictionary! {"Type"=>"Pages","Count"=>3,"Kids"=>kids,"Rotate"=>90}),
        );
        let catalog = d.add_object(dictionary! {"Type"=>"Catalog","Pages"=>root});
        d.trailer.set("Root", catalog);
        if signed {
            d.add_object(dictionary! {"FT"=>"Sig"});
        }
        d.save(path).unwrap();
    }
    #[test]
    fn history_survives_save_failure_pruning_and_branching() {
        let dir = std::env::temp_dir().join(format!("pdf42-history-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let out = dir.join("out.pdf");
        let restored = dir.join("restored.pdf");
        let _ = fs::remove_file(&out);
        let _ = fs::remove_file(&restored);
        sample(&input, false);
        let original = fs::read(&input).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        p.select(1).unwrap();
        p.rotate(1, 90).unwrap();
        p.move_page(1, 0).unwrap();
        p.delete(0).unwrap();
        assert_eq!(p.page_count(), 2);
        assert!(p.save_as(&input).is_err());
        assert!(p.is_dirty());
        p.save_as(&out).unwrap();
        assert!(!p.is_dirty());
        assert_eq!(PdfDocument::open(&out).unwrap().page_count(), 2);
        assert!(p.undo());
        assert!(p.is_dirty());
        assert_eq!(p.current(), 0);
        assert_eq!(p.rotation(0).unwrap(), 180);
        p.save_as(&restored).unwrap();
        assert_eq!(PdfDocument::open(&restored).unwrap().page_count(), 3);
        assert!(p.redo());
        assert!(p.is_dirty());
        assert_eq!(p.page_count(), 2);
        assert!(p.undo());
        p.rotate(0, 90).unwrap();
        assert!(!p.can_redo());
        assert_eq!(fs::read(&input).unwrap(), original);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rotation_baseline_and_bounded_history() {
        let dir = std::env::temp_dir().join(format!("pdf42-history-limit-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        sample(&input, false);
        let mut p = PdfDocument::open(&input).unwrap();
        for _ in 0..4 {
            p.rotate(0, 90).unwrap();
        }
        assert!(!p.is_dirty());
        for _ in 0..25 {
            p.rotate(0, 90).unwrap();
        }
        for _ in 0..20 {
            assert!(p.undo());
        }
        assert!(!p.undo());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn deletion_prunes_unique_content_but_preserves_shared_resources() {
        use lopdf::Stream;
        let dir = std::env::temp_dir().join(format!("pdf42-prune-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let out = dir.join("out.pdf");
        let _ = fs::remove_file(&out);
        let mut d = Document::with_version("1.5");
        let root = d.new_object_id();
        let shared =
            d.add_object(dictionary! {"Marker"=>Object::string_literal("shared-resource")});
        let mut kids = Vec::new();
        for marker in ["retained-content", "deleted-content"] {
            let content = d.add_object(Stream::new(dictionary! {}, marker.as_bytes().to_vec()));
            let p=d.add_object(dictionary!{"Type"=>"Page","Parent"=>root,"MediaBox"=>vec![0.into(),0.into(),200.into(),300.into()],"Resources"=>shared,"Contents"=>content});
            kids.push(Object::Reference(p));
        }
        d.objects.insert(
            root,
            Object::Dictionary(dictionary! {"Type"=>"Pages","Count"=>2,"Kids"=>kids}),
        );
        let catalog = d.add_object(dictionary! {"Type"=>"Catalog","Pages"=>root});
        d.trailer.set("Root", catalog);
        d.save(&input).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        p.delete(1).unwrap();
        p.save_as(&out).unwrap();
        let loaded = Document::load(&out).unwrap();
        assert_eq!(loaded.get_pages().len(), 1);
        let streams: Vec<_> = loaded
            .objects
            .values()
            .filter_map(|o| o.as_stream().ok())
            .map(|s| s.content.as_slice())
            .collect();
        assert!(streams.contains(&b"retained-content".as_slice()));
        assert!(!streams.contains(&b"deleted-content".as_slice()));
        assert!(loaded.objects.contains_key(&shared));
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn navigation_capability_matches_refusal() {
        let dir = std::env::temp_dir().join(format!("pdf42-nav-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("in.pdf");
        sample(&path, false);
        let mut d = Document::load(&path).unwrap();
        d.catalog_mut().unwrap().set("PageLabels", dictionary! {});
        d.save(&path).unwrap();
        let mut p = PdfDocument::open(&path).unwrap();
        assert!(!p.can_restructure());
        assert!(p.delete(0).is_err());
        assert!(p.move_page(0, 1).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn cyclic_page_tree_is_rejected() {
        let dir = std::env::temp_dir().join(format!("pdf42-cycle-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("in.pdf");
        sample(&path, false);
        let mut d = Document::load(&path).unwrap();
        let root = d
            .catalog()
            .unwrap()
            .get(b"Pages")
            .unwrap()
            .as_reference()
            .unwrap();
        d.get_dictionary_mut(root)
            .unwrap()
            .set("Kids", vec![Object::Reference(root)]);
        d.save(&path).unwrap();
        assert!(PdfDocument::open(&path).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn nested_direct_signature_is_rejected() {
        let dir = std::env::temp_dir().join(format!("pdf42-sig-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("in.pdf");
        sample(&path, false);
        let mut d = Document::load(&path).unwrap();
        d.catalog_mut().unwrap().set("AcroForm",dictionary!{"Fields"=>vec![Object::Dictionary(dictionary!{"Kids"=>vec![Object::Dictionary(dictionary!{"FT"=>"Sig"})]})]});
        d.save(&path).unwrap();
        let original = fs::read(&path).unwrap();
        assert!(PdfDocument::open(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), original);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn nested_rotation_roundtrip_preserves_tree() {
        let dir = std::env::temp_dir().join(format!("pdf42-nested-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let out = dir.join("out.pdf");
        let _ = fs::remove_file(&out);
        let mut d = Document::with_version("1.5");
        let root = d.new_object_id();
        let branch = d.new_object_id();
        let page=d.add_object(dictionary!{"Type"=>"Page","Parent"=>branch,"MediaBox"=>vec![0.into(),0.into(),200.into(),300.into()]});
        d.objects.insert(branch,Object::Dictionary(dictionary!{"Type"=>"Pages","Parent"=>root,"Count"=>1,"Kids"=>vec![Object::Reference(page)],"Rotate"=>270}));
        d.objects.insert(root,Object::Dictionary(dictionary!{"Type"=>"Pages","Count"=>1,"Kids"=>vec![Object::Reference(branch)],"Rotate"=>90}));
        let catalog = d.add_object(dictionary! {"Type"=>"Catalog","Pages"=>root});
        d.trailer.set("Root", catalog);
        d.save(&input).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        assert_eq!(p.rotation(0).unwrap(), 270);
        assert!(!p.can_restructure());
        assert!(p.move_page(0, 0).is_err());
        p.rotate(0, 90).unwrap();
        p.save_as(&out).unwrap();
        let reopened = PdfDocument::open(&out).unwrap();
        assert_eq!(reopened.rotation(0).unwrap(), 0);
        assert!(!reopened.flat);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn page_operations_and_reopen() {
        let dir = std::env::temp_dir().join(format!("pdf42-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        let sig = dir.join("signed.pdf");
        let _ = fs::remove_file(&output);
        sample(&input, false);
        sample(&sig, true);
        assert!(PdfDocument::open(&sig).is_err());
        let original = fs::read(&input).unwrap();
        let mut d = PdfDocument::open(&input).unwrap();
        assert!(d.can_restructure());
        assert_eq!(d.rotation(0).unwrap(), 90);
        d.rotate(1, 90).unwrap();
        d.move_page(1, 0).unwrap();
        d.delete(2).unwrap();
        d.save_as(&output).unwrap();
        let r = PdfDocument::open(&output).unwrap();
        assert_eq!(r.page_count(), 2);
        assert_eq!(r.rotation(0).unwrap(), 180);
        assert_eq!(r.rotation(1).unwrap(), 90);
        assert!(d.save_as(&output).is_err());
        assert_eq!(fs::read(&input).unwrap(), original);
        d.delete(0).unwrap();
        assert!(d.delete(0).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
}
