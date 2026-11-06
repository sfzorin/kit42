//! Structural PDF operations. No renderer or signature preservation.
use lopdf::{Document, LoadOptions, Object, ObjectId};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Read,
    path::Path,
};
use suite42_core::{write_new, SnapshotHistory};
const MAX_FILE: u64 = 256 * 1024 * 1024;
const MAX_PAGES: usize = 1000;
#[derive(Clone)]
struct State {
    pages: Vec<ObjectId>,
    rotations: HashMap<ObjectId, i64>,
    metadata: HashMap<String, String>,
    selected: ObjectId,
    annotations: Vec<Annotation>,
    crops: HashMap<ObjectId, [f64; 4]>,
    deleted_annotations: HashSet<ObjectId>,
    moved_annotations: HashMap<ObjectId, [f64; 2]>,
    annotation_text: HashMap<ObjectId, String>,
    form_values: HashMap<ObjectId, String>,
    raster_pages: HashMap<ObjectId, RasterPage>,
    imported_revision: bool,
    attachments_added: Vec<(String, Vec<u8>)>,
    attachments_removed: HashSet<String>,
    bookmarks: Option<Vec<Bookmark>>,
    imported_acroform: Option<ObjectId>,
    compress_streams: bool,
}
impl PartialEq for State {
    fn eq(&self, other: &Self) -> bool {
        self.pages == other.pages
            && self.rotations == other.rotations
            && self.metadata == other.metadata
            && self.annotations == other.annotations
            && self.crops == other.crops
            && self.deleted_annotations == other.deleted_annotations
            && self.moved_annotations == other.moved_annotations
            && self.annotation_text == other.annotation_text
            && self.form_values == other.form_values
            && self.raster_pages == other.raster_pages
            && self.imported_revision == other.imported_revision
            && self.attachments_added == other.attachments_added
            && self.attachments_removed == other.attachments_removed
            && self.bookmarks == other.bookmarks
            && self.imported_acroform == other.imported_acroform
            && self.compress_streams == other.compress_streams
    }
}
pub struct FlattenedPage {
    pub width: u32,
    pub height: u32,
    pub compressed_rgb: Vec<u8>,
    pub page_width: f64,
    pub page_height: f64,
}
impl FlattenedPage {
    /// Composite a rendered page against white and optionally permanently mask its pixel region.
    pub fn from_rgba(
        width: u32,
        height: u32,
        rgba: &[u8],
        page_width: f64,
        page_height: f64,
        mask: Option<[f64; 4]>,
    ) -> Result<Self, String> {
        use std::io::Write;
        let pixels = (width as usize)
            .checked_mul(height as usize)
            .ok_or("Page exceeds pixel limit")?;
        if width == 0
            || height == 0
            || pixels > 4_000_000
            || rgba.len() != pixels * 4
            || !page_width.is_finite()
            || !page_height.is_finite()
            || page_width <= 0.
            || page_height <= 0.
        {
            return Err("Page exceeds pixel limit or has invalid geometry".into());
        }
        let bounds = if let Some([x1, y1, x2, y2]) = mask {
            if [x1, y1, x2, y2].iter().any(|v| !v.is_finite()) {
                return Err("Invalid redaction rectangle".into());
            }
            let (l, r, t, b) = (
                x1.min(x2).clamp(0., 1.),
                x1.max(x2).clamp(0., 1.),
                y1.min(y2).clamp(0., 1.),
                y1.max(y2).clamp(0., 1.),
            );
            if r - l < 0.001 || b - t < 0.001 {
                return Err("Drag a larger redaction area".into());
            }
            Some((
                (l * width as f64).floor() as u32,
                (r * width as f64).ceil() as u32,
                (t * height as f64).floor() as u32,
                (b * height as f64).ceil() as u32,
            ))
        } else {
            None
        };
        let mut rgb = Vec::with_capacity(pixels * 3);
        for (i, p) in rgba.chunks_exact(4).enumerate() {
            let x = i as u32 % width;
            let y = i as u32 / width;
            if bounds.is_some_and(|(l, r, t, b)| x >= l && x < r && y >= t && y < b) {
                rgb.extend_from_slice(&[0, 0, 0]);
            } else {
                let a = p[3] as u32;
                for c in &p[..3] {
                    rgb.push(((*c as u32 * a + 255 * (255 - a) + 127) / 255) as u8);
                }
            }
        }
        let mut encoder =
            flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(&rgb).map_err(|e| e.to_string())?;
        let compressed_rgb = encoder.finish().map_err(|e| e.to_string())?;
        Ok(Self {
            width,
            height,
            compressed_rgb,
            page_width,
            page_height,
        })
    }
}
#[derive(Clone, PartialEq)]
struct RasterPage {
    width: u32,
    height: u32,
    rgb: Vec<u8>,
    page_width: f64,
    page_height: f64,
}
#[derive(Clone, Debug, PartialEq)]
struct Annotation {
    page: ObjectId,
    kind: AnnotationKind,
    rect: [f64; 4],
    contents: String,
    points: Vec<[f64; 2]>,
    quads: Vec<[f64; 4]>,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AnnotationKind {
    Rectangle,
    Ellipse,
    Line,
    Ink,
    Highlight,
    Underline,
    StrikeOut,
    Note,
    Link,
    FreeText,
    Stamp,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AnnotationSelection {
    New(usize),
    Existing(ObjectId),
}

#[derive(Clone, Debug, PartialEq)]
struct Bookmark {
    existing: Option<ObjectId>,
    title: String,
    page: Option<ObjectId>,
    descendants: i64,
}
#[derive(Clone)]
struct FormField {
    id: ObjectId,
    name: String,
    kind: Vec<u8>,
    flags: i64,
    options: Vec<(String, String)>,
    widgets: Vec<ObjectId>,
}

pub struct SaveState(State);

pub struct PdfDocument {
    doc: Document,
    root: ObjectId,
    original_pages: Vec<ObjectId>,
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
/// Flatten a page tree while preserving inherited page attributes.
fn validate_annotation_text(text: &str) -> Result<(), String> {
    let visible: String = text.chars().filter(|c| *c != '\r' && *c != '\n').collect();
    suite42_pdf_text::PdfFont::validate(&visible)
}
fn annotation_text_appearance(
    font: &suite42_pdf_text::PdfFont,
    text: &str,
    w: f64,
    h: f64,
    background: bool,
) -> Result<String, String> {
    let mut size = 12.0_f64;
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let wrap = |size: f64| {
        let mut lines = vec![String::new()];
        let mut width = 0.;
        for ch in normalized.chars() {
            if ch == '\n' {
                lines.push(String::new());
                width = 0.;
                continue;
            }
            let advance = font.chars.get(&ch).map(|v| v.2).unwrap_or(0) as f64 * size / 1000.;
            if width + advance > (w - 4.).max(1.) && !lines.last().unwrap().is_empty() {
                lines.push(String::new());
                width = 0.;
            }
            lines.last_mut().unwrap().push(ch);
            width += advance;
        }
        lines
    };
    let mut lines = wrap(size);
    while size > 2. && lines.len() as f64 * size * 1.2 > (h - 4.).max(1.) {
        size = (size - 0.5).max(2.);
        lines = wrap(size);
    }
    let mut result = if background {
        format!(
            "1 1 0 rg 0 0 {w} {h} re f 1 0 0 RG 1 w 0.5 0.5 {} {} re S ",
            (w - 1.).max(0.),
            (h - 1.).max(0.)
        )
    } else {
        String::new()
    };
    result.push_str(&format!("q 0 0 {w} {h} re W n 0 0 0 rg "));
    for (i, line) in lines.iter().enumerate() {
        let y = h - 2. - size - (i as f64 * size * 1.2);
        if y < -size {
            break;
        }
        let hex = font.encode(line)?;
        result.push_str(&format!("BT /F1 {size} Tf 2 {y} Td <{hex}> Tj ET "));
    }
    result.push('Q');
    Ok(result)
}
fn flatten_pages(doc: &mut Document, root: ObjectId, pages: &[ObjectId]) -> Result<(), String> {
    for &page in pages {
        let mut inherited = Vec::new();
        for key in [b"MediaBox".as_slice(), b"CropBox", b"Rotate", b"Resources"] {
            let mut id = page;
            loop {
                let node = doc.get_dictionary(id).map_err(|e| e.to_string())?;
                if let Ok(value) = node.get(key) {
                    inherited.push((key.to_vec(), value.clone()));
                    break;
                }
                if id == root {
                    break;
                }
                id = node
                    .get(b"Parent")
                    .map_err(|e| e.to_string())?
                    .as_reference()
                    .map_err(|e| e.to_string())?;
            }
        }
        let node = doc.get_dictionary_mut(page).map_err(|e| e.to_string())?;
        for (key, value) in inherited {
            node.set(key, value);
        }
        node.set("Parent", root);
    }
    let node = doc.get_dictionary_mut(root).map_err(|e| e.to_string())?;
    node.set(
        "Kids",
        pages
            .iter()
            .map(|id| Object::Reference(*id))
            .collect::<Vec<_>>(),
    );
    node.set("Count", pages.len() as i64);
    Ok(())
}
fn referenced_page_objects(doc: &Document, page: ObjectId) -> Result<HashSet<ObjectId>, String> {
    let node = doc.get_dictionary(page).map_err(|e| e.to_string())?;
    let mut pending: Vec<Object> = node
        .iter()
        .filter(|(k, _)| k.as_slice() != b"Parent")
        .map(|(_, v)| v.clone())
        .collect();
    let mut ids = HashSet::new();
    let mut count = 0;
    while let Some(value) = pending.pop() {
        count += 1;
        if count > 1_000_000 {
            return Err("Page object inspection limit exceeded".into());
        }
        match value {
            Object::Reference(id) => {
                if ids.insert(id) {
                    pending.push(doc.get_object(id).map_err(|e| e.to_string())?.clone());
                }
            }
            Object::Array(a) => pending.extend(a),
            Object::Dictionary(d) => pending.extend(d.iter().map(|(_, v)| v.clone())),
            Object::Stream(s) => pending.extend(s.dict.iter().map(|(_, v)| v.clone())),
            _ => {}
        }
    }
    Ok(ids)
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
        Self::open_bytes(&data)
    }
    fn open_bytes(data: &[u8]) -> Result<Self, String> {
        let options = LoadOptions {
            max_decompressed_size: Some(32 * 1024 * 1024),
            ..Default::default()
        };
        let doc = Document::load_mem_with_options(data, options).map_err(|e| e.to_string())?;
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
        let result = Self {
            doc,
            root,
            original_pages: pages.clone(),
            history: SnapshotHistory::new(
                State {
                    selected: pages[0],
                    pages,
                    rotations: HashMap::new(),
                    metadata: HashMap::new(),
                    annotations: Vec::new(),
                    crops: HashMap::new(),
                    deleted_annotations: HashSet::new(),
                    moved_annotations: HashMap::new(),
                    annotation_text: HashMap::new(),
                    form_values: HashMap::new(),
                    raster_pages: HashMap::new(),
                    imported_revision: false,
                    attachments_added: Vec::new(),
                    attachments_removed: HashSet::new(),
                    bookmarks: None,
                    imported_acroform: None,
                    compress_streams: false,
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
        if let Some(value) = self.history.current().metadata.get(key) {
            return Ok(Some(value.clone()));
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
    pub fn set_metadata(&mut self, values: &[(String, String)]) -> Result<(), String> {
        let mut state = self.history.current().clone();
        for (key, value) in values {
            if !matches!(
                key.as_str(),
                "Title" | "Author" | "Subject" | "Keywords" | "Creator" | "Producer"
            ) || value.len() > 32768
            {
                return Err("invalid metadata".into());
            }
            state.metadata.insert(key.clone(), value.clone());
        }
        self.history.apply(state);
        Ok(())
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
        if self.history.current().raster_pages.contains_key(&id) {
            return Ok(0);
        }
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

    pub fn page_box(&self, index: usize) -> Result<[f64; 4], String> {
        let mut id = *self
            .history
            .current()
            .pages
            .get(index)
            .ok_or("page index out of range")?;
        if let Some(raster) = self.history.current().raster_pages.get(&id) {
            return Ok([0., 0., raster.page_width, raster.page_height]);
        }
        if let Some(crop) = self.history.current().crops.get(&id) {
            return Ok(*crop);
        }
        let mut media = None;
        loop {
            let node = self.doc.get_dictionary(id).map_err(|e| e.to_string())?;
            for key in [b"CropBox".as_slice(), b"MediaBox".as_slice()] {
                if key == b"MediaBox" && media.is_some() {
                    continue;
                }
                if let Ok(value) = node.get(key) {
                    let arr = self
                        .doc
                        .dereference(value)
                        .map_err(|e| e.to_string())?
                        .1
                        .as_array()
                        .map_err(|e| e.to_string())?;
                    if arr.len() != 4 {
                        return Err("invalid page box".into());
                    }
                    let mut b = [0.; 4];
                    for (i, value) in arr.iter().enumerate() {
                        b[i] = match self.doc.dereference(value).map_err(|e| e.to_string())?.1 {
                            Object::Integer(v) => *v as f64,
                            Object::Real(v) => *v as f64,
                            _ => return Err("invalid page box".into()),
                        };
                    }
                    if b.iter().any(|v| !v.is_finite()) || b[2] <= b[0] || b[3] <= b[1] {
                        return Err("invalid page box".into());
                    }
                    if key == b"CropBox" {
                        return Ok(b);
                    }
                    media = Some(b);
                }
            }
            if id == self.root {
                break;
            }
            id = node
                .get(b"Parent")
                .map_err(|e| e.to_string())?
                .as_reference()
                .map_err(|e| e.to_string())?;
        }
        media.ok_or_else(|| "page has no MediaBox".into())
    }
    /// Crop within the currently visible page box; undo restores the previous crop.
    pub fn crop_page(&mut self, index: usize, crop: [f64; 4]) -> Result<(), String> {
        let page = *self
            .history
            .current()
            .pages
            .get(index)
            .ok_or("page index out of range")?;
        let bounds = self.page_box(index)?;
        if crop.iter().any(|v| !v.is_finite())
            || crop[0] < bounds[0]
            || crop[1] < bounds[1]
            || crop[2] > bounds[2]
            || crop[3] > bounds[3]
            || crop[2] - crop[0] < 1.
            || crop[3] - crop[1] < 1.
        {
            return Err("Crop must be a nonempty rectangle inside the visible page".into());
        }
        if crop != bounds {
            let mut state = self.history.current().clone();
            state.crops.insert(page, crop);
            self.history.apply(state);
        }
        Ok(())
    }
    pub fn add_annotation(
        &mut self,
        index: usize,
        kind: AnnotationKind,
        mut rect: [f64; 4],
        contents: &str,
    ) -> Result<(), String> {
        let page = *self
            .history
            .current()
            .pages
            .get(index)
            .ok_or("page index out of range")?;
        if contents.len() > 32768 {
            return Err("Annotation text is too long".into());
        }
        if matches!(
            kind,
            AnnotationKind::FreeText | AnnotationKind::Stamp | AnnotationKind::Note
        ) && contents.is_empty()
        {
            return Err("Enter annotation text".into());
        }
        if matches!(
            kind,
            AnnotationKind::Note | AnnotationKind::FreeText | AnnotationKind::Stamp
        ) {
            validate_annotation_text(contents)?;
        }
        if kind == AnnotationKind::Link
            && !(contents.starts_with("https://") || contents.starts_with("http://"))
        {
            return Err("Enter an http or https link".into());
        }
        let b = self.page_box(index)?;
        if rect.iter().any(|v| !v.is_finite()) {
            return Err("invalid annotation coordinates".into());
        }
        rect[0] = rect[0].clamp(b[0], b[2]);
        rect[2] = rect[2].clamp(b[0], b[2]);
        rect[1] = rect[1].clamp(b[1], b[3]);
        rect[3] = rect[3].clamp(b[1], b[3]);
        if (rect[2] - rect[0]).abs() < 2. || (rect[3] - rect[1]).abs() < 2. {
            return Err("Drag a larger annotation".into());
        }
        let mut state = self.history.current().clone();
        state.annotations.push(Annotation {
            page,
            kind,
            rect,
            contents: contents.to_owned(),
            points: Vec::new(),
            quads: Vec::new(),
        });
        self.history.apply(state);
        Ok(())
    }

    pub fn add_ink(&mut self, index: usize, points: &[[f64; 2]]) -> Result<(), String> {
        let page = *self
            .history
            .current()
            .pages
            .get(index)
            .ok_or("page index out of range")?;
        if points.len() < 2
            || points.len() > 100_000
            || points.iter().flatten().any(|v| !v.is_finite())
        {
            return Err("Invalid ink stroke".into());
        }
        let b = self.page_box(index)?;
        let points: Vec<_> = points
            .iter()
            .map(|p| [p[0].clamp(b[0], b[2]), p[1].clamp(b[1], b[3])])
            .collect();
        let mut rect = [
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ];
        for p in &points {
            rect[0] = rect[0].min(p[0]);
            rect[1] = rect[1].min(p[1]);
            rect[2] = rect[2].max(p[0]);
            rect[3] = rect[3].max(p[1]);
        }
        if rect[2] - rect[0] < 0.5 && rect[3] - rect[1] < 0.5 {
            return Err("Draw a longer ink stroke".into());
        }
        rect = [rect[0] - 2., rect[1] - 2., rect[2] + 2., rect[3] + 2.];
        let mut state = self.history.current().clone();
        state.annotations.push(Annotation {
            page,
            kind: AnnotationKind::Ink,
            rect,
            contents: String::new(),
            points,
            quads: Vec::new(),
        });
        self.history.apply(state);
        Ok(())
    }

    pub fn add_text_markup(
        &mut self,
        index: usize,
        kind: AnnotationKind,
        quads: &[[f64; 4]],
    ) -> Result<(), String> {
        if !matches!(
            kind,
            AnnotationKind::Highlight | AnnotationKind::Underline | AnnotationKind::StrikeOut
        ) || quads.is_empty()
            || quads.len() > 100_000
        {
            return Err("Invalid text markup".into());
        }
        let page = *self
            .history
            .current()
            .pages
            .get(index)
            .ok_or("page index out of range")?;
        let page_box = self.page_box(index)?;
        let mut rect = [
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ];
        let mut clean = Vec::new();
        for q in quads {
            if q.iter().any(|v| !v.is_finite()) {
                return Err("Invalid text coordinates".into());
            }
            let r = [
                q[0].max(page_box[0]),
                q[1].max(page_box[1]),
                q[2].min(page_box[2]),
                q[3].min(page_box[3]),
            ];
            if r[2] <= r[0] || r[3] <= r[1] {
                continue;
            }
            rect[0] = rect[0].min(r[0]);
            rect[1] = rect[1].min(r[1]);
            rect[2] = rect[2].max(r[2]);
            rect[3] = rect[3].max(r[3]);
            clean.push(r);
        }
        if clean.is_empty() {
            return Err("Select visible text first".into());
        }
        let mut state = self.history.current().clone();
        state.annotations.push(Annotation {
            page,
            kind,
            rect,
            contents: String::new(),
            points: Vec::new(),
            quads: clean,
        });
        self.history.apply(state);
        Ok(())
    }

    fn existing_annotations(&self, page: ObjectId) -> Vec<(ObjectId, [f64; 4])> {
        let Some(array) = self
            .doc
            .get_dictionary(page)
            .ok()
            .and_then(|d| d.get(b"Annots").ok())
            .and_then(|v| self.doc.dereference(v).ok())
            .and_then(|(_, v)| v.as_array().ok())
        else {
            return Vec::new();
        };
        array
            .iter()
            .filter_map(|v| {
                let id = v.as_reference().ok()?;
                let d = self.doc.get_dictionary(id).ok()?;
                let subtype = d.get(b"Subtype").ok()?.as_name().ok()?;
                if !matches!(
                    subtype,
                    b"Square"
                        | b"Circle"
                        | b"Line"
                        | b"Ink"
                        | b"Highlight"
                        | b"Underline"
                        | b"StrikeOut"
                        | b"Text"
                        | b"Link"
                        | b"FreeText"
                        | b"Stamp"
                ) || d.get(b"Popup").is_ok()
                {
                    return None;
                }
                let values = d.get(b"Rect").ok()?.as_array().ok()?;
                if values.len() != 4 {
                    return None;
                }
                let mut r = [0.; 4];
                for (i, v) in values.iter().enumerate() {
                    r[i] = match v {
                        Object::Integer(v) => *v as f64,
                        Object::Real(v) => *v as f64,
                        _ => return None,
                    };
                }
                let delta = self
                    .history
                    .current()
                    .moved_annotations
                    .get(&id)
                    .copied()
                    .unwrap_or([0., 0.]);
                Some((
                    id,
                    [
                        r[0] + delta[0],
                        r[1] + delta[1],
                        r[2] + delta[0],
                        r[3] + delta[1],
                    ],
                ))
            })
            .collect()
    }
    pub fn hit_annotation(&self, index: usize, point: [f64; 2]) -> Option<AnnotationSelection> {
        let page = *self.history.current().pages.get(index)?;
        let contains = |r: [f64; 4]| {
            point[0] >= r[0].min(r[2])
                && point[0] <= r[0].max(r[2])
                && point[1] >= r[1].min(r[3])
                && point[1] <= r[1].max(r[3])
        };
        if let Some((i, _)) = self
            .history
            .current()
            .annotations
            .iter()
            .enumerate()
            .rev()
            .find(|(_, a)| a.page == page && contains(a.rect))
        {
            return Some(AnnotationSelection::New(i));
        }
        self.existing_annotations(page)
            .into_iter()
            .rev()
            .find(|(id, r)| {
                !self.history.current().deleted_annotations.contains(id) && contains(*r)
            })
            .map(|(id, _)| AnnotationSelection::Existing(id))
    }
    pub fn annotation_contents(&self, selection: AnnotationSelection) -> Option<String> {
        match selection {
            AnnotationSelection::New(i) => self
                .history
                .current()
                .annotations
                .get(i)
                .map(|a| a.contents.clone()),
            AnnotationSelection::Existing(id) => {
                if let Some(text) = self.history.current().annotation_text.get(&id) {
                    return Some(text.clone());
                }
                let d = self.doc.get_dictionary(id).ok()?;
                if let Ok(contents) = d.get(b"Contents") {
                    return lopdf::decode_text_string(contents).ok();
                }
                let action = d.get(b"A").ok()?.as_dict().ok()?;
                String::from_utf8(action.get(b"URI").ok()?.as_str().ok()?.to_vec()).ok()
            }
        }
    }
    pub fn set_note_text(
        &mut self,
        selection: AnnotationSelection,
        text: &str,
    ) -> Result<(), String> {
        if text.is_empty() || text.len() > 32768 {
            return Err("Enter note text up to 32768 bytes".into());
        }
        validate_annotation_text(text)?;
        let mut state = self.history.current().clone();
        match selection {
            AnnotationSelection::New(i) => {
                let a = state
                    .annotations
                    .get_mut(i)
                    .ok_or("Annotation selection is no longer valid")?;
                if !matches!(a.kind, AnnotationKind::Note | AnnotationKind::FreeText) {
                    return Err("Select a note or text annotation".into());
                }
                a.contents = text.into();
            }
            AnnotationSelection::Existing(id) => {
                let d = self.doc.get_dictionary(id).map_err(|e| e.to_string())?;
                if !matches!(
                    d.get(b"Subtype").ok().and_then(|v| v.as_name().ok()),
                    Some(b"Text" | b"FreeText")
                ) || state.deleted_annotations.contains(&id)
                {
                    return Err("Select a note or text annotation".into());
                }
                state.annotation_text.insert(id, text.into());
            }
        }
        self.history.apply(state);
        Ok(())
    }
    pub fn delete_annotation(&mut self, selection: AnnotationSelection) -> Result<(), String> {
        let mut state = self.history.current().clone();
        match selection {
            AnnotationSelection::New(index) => {
                if index >= state.annotations.len() {
                    return Err("Annotation selection is no longer valid".into());
                }
                state.annotations.remove(index);
            }
            AnnotationSelection::Existing(id) => {
                if !state
                    .pages
                    .iter()
                    .any(|p| self.existing_annotations(*p).iter().any(|(i, _)| *i == id))
                    || !state.deleted_annotations.insert(id)
                {
                    return Err("Annotation selection is no longer valid".into());
                }
            }
        }
        self.history.apply(state);
        Ok(())
    }
    pub fn move_annotation(
        &mut self,
        selection: AnnotationSelection,
        delta: [f64; 2],
    ) -> Result<(), String> {
        if delta.iter().any(|v| !v.is_finite()) {
            return Err("Invalid movement".into());
        }
        let mut state = self.history.current().clone();
        let (page, r) = match selection {
            AnnotationSelection::New(i) => {
                let a = state
                    .annotations
                    .get(i)
                    .ok_or("Annotation selection is no longer valid")?;
                (a.page, a.rect)
            }
            AnnotationSelection::Existing(id) => state
                .pages
                .iter()
                .find_map(|page| {
                    self.existing_annotations(*page)
                        .into_iter()
                        .find(|(i, _)| *i == id)
                        .map(|(_, r)| (*page, r))
                })
                .ok_or("Annotation selection is no longer valid")?,
        };
        let index = state
            .pages
            .iter()
            .position(|p| *p == page)
            .ok_or("Page is no longer present")?;
        let b = self.page_box(index)?;
        if r[0].min(r[2]) + delta[0] < b[0]
            || r[0].max(r[2]) + delta[0] > b[2]
            || r[1].min(r[3]) + delta[1] < b[1]
            || r[1].max(r[3]) + delta[1] > b[3]
        {
            return Err("Move must stay within the visible page".into());
        }
        match selection {
            AnnotationSelection::New(i) => {
                for q in &mut state.annotations[i].quads {
                    q[0] += delta[0];
                    q[2] += delta[0];
                    q[1] += delta[1];
                    q[3] += delta[1];
                }
                for p in &mut state.annotations[i].points {
                    p[0] += delta[0];
                    p[1] += delta[1];
                }
                state.annotations[i].rect = [
                    r[0] + delta[0],
                    r[1] + delta[1],
                    r[2] + delta[0],
                    r[3] + delta[1],
                ]
            }
            AnnotationSelection::Existing(id) => {
                let v = state.moved_annotations.entry(id).or_insert([0., 0.]);
                v[0] += delta[0];
                v[1] += delta[1];
            }
        }
        self.history.apply(state);
        Ok(())
    }

    fn base_bookmarks(&self) -> Result<Vec<Bookmark>, String> {
        let catalog = self.doc.catalog().map_err(|e| e.to_string())?;
        let Some(root) = catalog.get(b"Outlines").ok() else {
            return Ok(Vec::new());
        };
        let root = self
            .doc
            .dereference(root)
            .map_err(|e| e.to_string())?
            .1
            .as_dict()
            .map_err(|e| e.to_string())?;
        let mut next = root.get(b"First").ok().and_then(|v| v.as_reference().ok());
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        while let Some(id) = next {
            if !seen.insert(id) || seen.len() > 10_000 {
                return Err("Invalid bookmark list".into());
            }
            let d = self.doc.get_dictionary(id).map_err(|e| e.to_string())?;
            let title = d
                .get(b"Title")
                .ok()
                .and_then(|v| lopdf::decode_text_string(v).ok())
                .unwrap_or_default();
            let destination = d.get(b"Dest").ok().or_else(|| {
                d.get(b"A")
                    .ok()
                    .and_then(|v| self.doc.dereference(v).ok())
                    .and_then(|(_, v)| v.as_dict().ok())
                    .and_then(|d| d.get(b"D").ok())
            });
            let page = destination
                .and_then(|v| self.doc.dereference(v).ok())
                .and_then(|(_, v)| v.as_array().ok())
                .and_then(|v| v.first())
                .and_then(|v| v.as_reference().ok());
            let descendants = d
                .get(b"Count")
                .ok()
                .and_then(|v| v.as_i64().ok())
                .unwrap_or(0)
                .max(0);
            out.push(Bookmark {
                existing: Some(id),
                title,
                page,
                descendants,
            });
            next = d.get(b"Next").ok().and_then(|v| v.as_reference().ok());
        }
        Ok(out)
    }
    fn current_bookmarks(&self) -> Result<Vec<Bookmark>, String> {
        self.history
            .current()
            .bookmarks
            .clone()
            .map(Ok)
            .unwrap_or_else(|| self.base_bookmarks())
    }
    pub fn bookmarks(&self) -> Result<Vec<String>, String> {
        Ok(self
            .current_bookmarks()?
            .into_iter()
            .map(|b| b.title)
            .collect())
    }
    pub fn select_bookmark(&mut self, index: usize) -> Result<(), String> {
        let bookmarks = self.current_bookmarks()?;
        let page = bookmarks
            .get(index)
            .ok_or("Bookmark index out of range")?
            .page
            .ok_or("This bookmark uses an unsupported named or external destination")?;
        let page = self
            .history
            .current()
            .pages
            .iter()
            .position(|v| *v == page)
            .ok_or("Bookmark target page is unavailable")?;
        self.select(page)
    }
    pub fn add_bookmark(&mut self, title: &str) -> Result<(), String> {
        if title.is_empty() || title.len() > 32768 {
            return Err("Enter a bookmark title")?;
        }
        let mut bookmarks = self.current_bookmarks()?;
        if bookmarks.len() >= 10_000 {
            return Err("Bookmark limit exceeded".into());
        }
        bookmarks.push(Bookmark {
            existing: None,
            title: title.into(),
            page: Some(self.history.current().selected),
            descendants: 0,
        });
        let mut state = self.history.current().clone();
        state.bookmarks = Some(bookmarks);
        self.history.apply(state);
        Ok(())
    }
    pub fn rename_bookmark(&mut self, index: usize, title: &str) -> Result<(), String> {
        if title.is_empty() || title.len() > 32768 {
            return Err("Enter a bookmark title".into());
        }
        let mut bookmarks = self.current_bookmarks()?;
        bookmarks
            .get_mut(index)
            .ok_or("Bookmark index out of range")?
            .title = title.into();
        let mut state = self.history.current().clone();
        state.bookmarks = Some(bookmarks);
        self.history.apply(state);
        Ok(())
    }
    pub fn delete_bookmark(&mut self, index: usize) -> Result<(), String> {
        let mut bookmarks = self.current_bookmarks()?;
        if index >= bookmarks.len() {
            return Err("Bookmark index out of range".into());
        }
        bookmarks.remove(index);
        let mut state = self.history.current().clone();
        state.bookmarks = Some(bookmarks);
        self.history.apply(state);
        Ok(())
    }
    pub fn move_bookmark(&mut self, from: usize, to: usize) -> Result<(), String> {
        let mut bookmarks = self.current_bookmarks()?;
        if from >= bookmarks.len() || to >= bookmarks.len() {
            return Err("Bookmark index out of range".into());
        }
        let bookmark = bookmarks.remove(from);
        bookmarks.insert(to, bookmark);
        let mut state = self.history.current().clone();
        state.bookmarks = Some(bookmarks);
        self.history.apply(state);
        Ok(())
    }

    fn embedded_entries(&self) -> Result<Vec<(String, Object, Object)>, String> {
        fn walk(
            doc: &Document,
            node: &Object,
            seen: &mut HashSet<ObjectId>,
            out: &mut Vec<(String, Object, Object)>,
        ) -> Result<(), String> {
            if let Ok(id) = node.as_reference() {
                if !seen.insert(id) || seen.len() > 10000 {
                    return Err("Invalid embedded-file name tree".into());
                }
            }
            let dict = doc
                .dereference(node)
                .map_err(|e| e.to_string())?
                .1
                .as_dict()
                .map_err(|e| e.to_string())?;
            if let Ok(names) = dict.get(b"Names") {
                let names = doc
                    .dereference(names)
                    .map_err(|e| e.to_string())?
                    .1
                    .as_array()
                    .map_err(|e| e.to_string())?;
                if names.len() % 2 != 0 {
                    return Err("Invalid embedded-file name tree".into());
                }
                for pair in names.chunks_exact(2) {
                    let name = lopdf::decode_text_string(&pair[0]).map_err(|e| e.to_string())?;
                    out.push((name, pair[0].clone(), pair[1].clone()));
                    if out.len() > 10_000 {
                        return Err("Attachment limit exceeded".into());
                    }
                }
            }
            if let Ok(kids) = dict.get(b"Kids") {
                for kid in doc
                    .dereference(kids)
                    .map_err(|e| e.to_string())?
                    .1
                    .as_array()
                    .map_err(|e| e.to_string())?
                {
                    walk(doc, kid, seen, out)?;
                }
            }
            Ok(())
        }
        let catalog = self.doc.catalog().map_err(|e| e.to_string())?;
        let Some(names) = catalog.get(b"Names").ok() else {
            return Ok(Vec::new());
        };
        let names = self
            .doc
            .dereference(names)
            .map_err(|e| e.to_string())?
            .1
            .as_dict()
            .map_err(|e| e.to_string())?;
        let Some(tree) = names.get(b"EmbeddedFiles").ok() else {
            return Ok(Vec::new());
        };
        let mut result = Vec::new();
        walk(&self.doc, tree, &mut HashSet::new(), &mut result)?;
        Ok(result)
    }
    pub fn attachments(&self) -> Result<Vec<String>, String> {
        let state = self.history.current();
        let mut names: Vec<_> = self
            .embedded_entries()?
            .into_iter()
            .map(|(name, _, _)| name)
            .filter(|n| !state.attachments_removed.contains(n))
            .collect();
        names.extend(state.attachments_added.iter().map(|(name, _)| name.clone()));
        Ok(names)
    }
    pub fn add_attachment(&mut self, path: &Path) -> Result<(), String> {
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("Attachment filename must be Unicode")?
            .to_owned();
        if name.is_empty() || name.len() > 1024 || self.attachments()?.contains(&name) {
            return Err("Attachment filename is empty, too long or already exists".into());
        }
        if fs::metadata(path).map_err(|e| e.to_string())?.len() > 16 * 1024 * 1024 {
            return Err("Attachment exceeds 16 MB limit".into());
        }
        let data = fs::read(path).map_err(|e| e.to_string())?;
        if data.len() > 16 * 1024 * 1024 {
            return Err("Attachment exceeds 16 MB limit".into());
        }
        let mut state = self.history.current().clone();
        if state
            .attachments_added
            .iter()
            .map(|(_, v)| v.len())
            .sum::<usize>()
            .saturating_add(data.len())
            > 64 * 1024 * 1024
        {
            return Err("Added attachments exceed 64 MB".into());
        }
        state.attachments_added.push((name, data));
        self.history.apply(state);
        Ok(())
    }
    pub fn delete_attachment(&mut self, name: &str) -> Result<(), String> {
        if self
            .attachments()?
            .iter()
            .filter(|n| n.as_str() == name)
            .count()
            != 1
        {
            return Err("Attachment not found or ambiguous".into());
        }
        let mut state = self.history.current().clone();
        if let Some(i) = state.attachments_added.iter().position(|(n, _)| n == name) {
            state.attachments_added.remove(i);
        } else {
            state.attachments_removed.insert(name.to_owned());
        }
        self.history.apply(state);
        Ok(())
    }
    pub fn export_attachment(&self, name: &str, path: &Path) -> Result<(), String> {
        if let Some((_, data)) = self
            .history
            .current()
            .attachments_added
            .iter()
            .find(|(n, _)| n == name)
        {
            return write_new(path, data).map_err(|e| e.to_string());
        }
        if self.history.current().attachments_removed.contains(name) {
            return Err("Attachment not found".into());
        }
        let matches: Vec<_> = self
            .embedded_entries()?
            .into_iter()
            .filter(|(n, _, _)| n == name)
            .collect();
        if matches.len() != 1 {
            return Err("Attachment not found or ambiguous".into());
        }
        let spec = self
            .doc
            .dereference(&matches[0].2)
            .map_err(|e| e.to_string())?
            .1
            .as_dict()
            .map_err(|e| e.to_string())?;
        let ef = self
            .doc
            .dereference(spec.get(b"EF").map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?
            .1
            .as_dict()
            .map_err(|e| e.to_string())?;
        let stream = ef
            .get(b"UF")
            .or_else(|_| ef.get(b"F"))
            .map_err(|e| e.to_string())?;
        let stream = self
            .doc
            .dereference(stream)
            .map_err(|e| e.to_string())?
            .1
            .as_stream()
            .map_err(|e| e.to_string())?;
        let data = if stream.dict.get(b"Filter").is_ok() {
            stream
                .decompressed_content_with_limit(16 * 1024 * 1024)
                .map_err(|e| e.to_string())?
        } else {
            stream.content.clone()
        };
        if data.len() > 16 * 1024 * 1024 {
            return Err("Attachment exceeds 16 MB limit".into());
        }
        write_new(path, &data).map_err(|e| e.to_string())
    }

    fn form_definitions(&self) -> Vec<FormField> {
        fn walk(
            doc: &Document,
            id: ObjectId,
            prefix: &str,
            inherited: Option<Vec<u8>>,
            flags: i64,
            options: Vec<(String, String)>,
            seen: &mut HashSet<ObjectId>,
            out: &mut Vec<FormField>,
        ) {
            if seen.len() > 10000 || !seen.insert(id) {
                return;
            }
            let Ok(d) = doc.get_dictionary(id) else {
                return;
            };
            let part = d
                .get(b"T")
                .ok()
                .and_then(|v| lopdf::decode_text_string(v).ok())
                .unwrap_or_default();
            let name = if part.is_empty() {
                prefix.to_owned()
            } else if prefix.is_empty() {
                part
            } else {
                format!("{prefix}.{part}")
            };
            let kind = d
                .get(b"FT")
                .ok()
                .and_then(|v| v.as_name().ok())
                .map(|v| v.to_vec())
                .or(inherited);
            let flags = d
                .get(b"Ff")
                .ok()
                .and_then(|v| v.as_i64().ok())
                .unwrap_or(flags);
            let options = d
                .get(b"Opt")
                .ok()
                .and_then(|v| doc.dereference(v).ok())
                .and_then(|(_, v)| v.as_array().ok())
                .map(|a| {
                    a.iter()
                        .filter_map(|v| {
                            if let Ok(pair) = v.as_array() {
                                let export = lopdf::decode_text_string(pair.first()?).ok()?;
                                let display = pair
                                    .get(1)
                                    .and_then(|v| lopdf::decode_text_string(v).ok())
                                    .unwrap_or_else(|| export.clone());
                                Some((export, display))
                            } else {
                                let v = lopdf::decode_text_string(v).ok()?;
                                Some((v.clone(), v))
                            }
                        })
                        .collect()
                })
                .unwrap_or(options);
            let mut widgets = Vec::new();
            let mut children = Vec::new();
            if d.get(b"Subtype").ok().and_then(|v| v.as_name().ok()) == Some(b"Widget") {
                widgets.push(id);
            }
            if let Some(kids) = d
                .get(b"Kids")
                .ok()
                .and_then(|v| doc.dereference(v).ok())
                .and_then(|(_, v)| v.as_array().ok())
            {
                for kid in kids.iter().filter_map(|v| v.as_reference().ok()) {
                    if let Ok(k) = doc.get_dictionary(kid) {
                        if k.get(b"Subtype").ok().and_then(|v| v.as_name().ok()) == Some(b"Widget")
                            && k.get(b"T").is_err()
                        {
                            widgets.push(kid);
                        } else {
                            children.push(kid);
                        }
                    }
                }
            }
            if !widgets.is_empty() && flags & 1 == 0 && !name.is_empty() {
                if let Some(kind) = kind.clone() {
                    if matches!(kind.as_slice(), b"Tx" | b"Ch" | b"Btn")
                        && !(kind == b"Btn" && flags & (1 << 16) != 0)
                    {
                        out.push(FormField {
                            id,
                            name: name.clone(),
                            kind,
                            flags,
                            options: options.clone(),
                            widgets,
                        });
                    }
                }
            }
            for child in children {
                walk(
                    doc,
                    child,
                    &name,
                    kind.clone(),
                    flags,
                    options.clone(),
                    seen,
                    out,
                );
            }
        }
        let form = self
            .history
            .current()
            .imported_acroform
            .map(Object::Reference)
            .or_else(|| {
                self.doc
                    .catalog()
                    .ok()
                    .and_then(|d| d.get(b"AcroForm").ok())
                    .cloned()
            });
        let Some(fields) = form
            .as_ref()
            .and_then(|v| self.doc.dereference(v).ok())
            .and_then(|(_, v)| v.as_dict().ok())
            .and_then(|d| d.get(b"Fields").ok())
            .and_then(|v| self.doc.dereference(v).ok())
            .and_then(|(_, v)| v.as_array().ok())
        else {
            return Vec::new();
        };
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        for id in fields.iter().filter_map(|v| v.as_reference().ok()) {
            walk(&self.doc, id, "", None, 0, Vec::new(), &mut seen, &mut out);
        }
        out
    }
    pub fn form_fields(&self) -> Vec<(String, String, String)> {
        self.form_definitions()
            .into_iter()
            .map(|f| {
                let kind = match f.kind.as_slice() {
                    b"Tx" => "text",
                    b"Ch" if f.flags & (1 << 21) != 0 => "multi-choice (comma separated)",
                    b"Ch" => "choice",
                    b"Btn" if f.flags & (1 << 15) != 0 => "radio",
                    _ => "checkbox",
                };
                let value = self
                    .history
                    .current()
                    .form_values
                    .get(&f.id)
                    .cloned()
                    .unwrap_or_else(|| {
                        self.doc
                            .get_dictionary(f.id)
                            .ok()
                            .and_then(|d| d.get(b"V").ok())
                            .map(|v| match v {
                                Object::Name(v) => String::from_utf8_lossy(v).into_owned(),
                                Object::Array(a) => a
                                    .iter()
                                    .filter_map(|v| lopdf::decode_text_string(v).ok())
                                    .collect::<Vec<_>>()
                                    .join(","),
                                _ => lopdf::decode_text_string(v).unwrap_or_default(),
                            })
                            .unwrap_or_default()
                    });
                (f.name, kind.into(), value)
            })
            .collect()
    }
    fn button_states(&self, widget: ObjectId) -> Vec<Vec<u8>> {
        self.doc
            .get_dictionary(widget)
            .ok()
            .and_then(|d| d.get(b"AP").ok())
            .and_then(|v| self.doc.dereference(v).ok())
            .and_then(|(_, v)| v.as_dict().ok())
            .and_then(|d| d.get(b"N").ok())
            .and_then(|v| self.doc.dereference(v).ok())
            .and_then(|(_, v)| v.as_dict().ok())
            .map(|d| d.iter().map(|(k, _)| k.clone()).collect())
            .unwrap_or_default()
    }
    pub fn set_form_value(&mut self, name: &str, value: &str) -> Result<(), String> {
        if value.len() > 32768 {
            return Err("Field value is too long".into());
        }
        let fields: Vec<_> = self
            .form_definitions()
            .into_iter()
            .filter(|f| f.name == name)
            .collect();
        if fields.len() != 1 {
            return Err("Field name not found or ambiguous".into());
        }
        let f = &fields[0];
        if f.kind == b"Btn" {
            if value != "Off"
                && !f
                    .widgets
                    .iter()
                    .any(|w| self.button_states(*w).iter().any(|s| s == value.as_bytes()))
            {
                return Err("Value must match a button appearance state (or Off)".into());
            }
            if f.widgets
                .iter()
                .any(|w| !self.button_states(*w).iter().any(|s| s == b"Off"))
            {
                return Err("Button is missing its Off appearance".into());
            }
        } else {
            suite42_pdf_text::PdfFont::validate(value)?;
            if f.kind == b"Ch" {
                let selected: Vec<_> = if f.flags & (1 << 21) != 0 {
                    value.split(',').collect()
                } else {
                    vec![value]
                };
                if selected
                    .iter()
                    .any(|v| !f.options.iter().any(|(export, _)| export == v))
                {
                    return Err("Value must match available choice export values".into());
                }
                for (_, display) in &f.options {
                    suite42_pdf_text::PdfFont::validate(display)?;
                }
            }
        }
        let mut state = self.history.current().clone();
        state.form_values.insert(f.id, value.into());
        self.history.apply(state);
        Ok(())
    }

    /// Construct a new editable image-only PDF from independently compressed pages.
    pub fn from_flattened_pages(
        pages: Vec<FlattenedPage>,
        selected: usize,
    ) -> Result<Self, String> {
        if pages.is_empty() || pages.len() > MAX_PAGES || selected >= pages.len() {
            return Err("Invalid flattened document".into());
        }
        let mut output = Document::with_version("1.5");
        let root = output.new_object_id();
        let mut kids = Vec::new();
        let mut total = 0usize;
        for raster in pages {
            total = total
                .checked_add(raster.compressed_rgb.len())
                .ok_or("Flattened document too large")?;
            if total > 96 * 1024 * 1024
                || raster.width == 0
                || raster.height == 0
                || raster.width as u64 * raster.height as u64 > 4_000_000
                || !raster.page_width.is_finite()
                || !raster.page_height.is_finite()
                || raster.page_width <= 0.
                || raster.page_height <= 0.
            {
                return Err("Flattened document exceeds limits".into());
            }
            let image = output.add_object(lopdf::Stream::new(lopdf::dictionary!{"Type"=>"XObject", "Subtype"=>"Image", "Width"=>raster.width as i64, "Height"=>raster.height as i64, "ColorSpace"=>"DeviceRGB", "BitsPerComponent"=>8, "Filter"=>"FlateDecode"}, raster.compressed_rgb));
            let content = output.add_object(lopdf::Stream::new(
                lopdf::dictionary! {},
                format!(
                    "q {} 0 0 {} 0 0 cm /Im0 Do Q",
                    raster.page_width, raster.page_height
                )
                .into_bytes(),
            ));
            let page = output.add_object(lopdf::dictionary!{"Type"=>"Page", "Parent"=>root, "MediaBox"=>vec![0.into(),0.into(),Object::Real(raster.page_width as f32),Object::Real(raster.page_height as f32)], "Resources"=>lopdf::dictionary!{"XObject"=>lopdf::dictionary!{"Im0"=>image}}, "Contents"=>content});
            kids.push(Object::Reference(page));
        }
        output.objects.insert(
            root,
            Object::Dictionary(
                lopdf::dictionary! {"Type"=>"Pages", "Count"=>kids.len() as i64, "Kids"=>kids},
            ),
        );
        let catalog = output.add_object(lopdf::dictionary! {"Type"=>"Catalog", "Pages"=>root});
        output.trailer.set("Root", catalog);
        let mut bytes = Vec::new();
        output.save_to(&mut bytes).map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_FILE {
            return Err("Flattened document exceeds compressed size limit".into());
        }
        let mut doc = Self::open_bytes(&bytes)?;
        let mut state = doc.history.current().clone();
        state.imported_revision = true;
        state.selected = state.pages[selected];
        doc.history.replace_current(state);
        Ok(doc)
    }
    pub fn discard_redo(&mut self) {
        self.history.discard_redo();
    }

    /// Replace a page by the caller's rendered RGB pixels with a blacked-out pixel rectangle.
    /// This deliberately removes all original page content and requires no annotations or navigation.
    pub fn redact_raster(
        &mut self,
        index: usize,
        width: u32,
        height: u32,
        rgba: &[u8],
        rect: [u32; 4],
    ) -> Result<(), String> {
        self.ensure_reorder_safe()?;
        let page = *self
            .history
            .current()
            .pages
            .get(index)
            .ok_or("page index out of range")?;
        if self
            .doc
            .get_dictionary(page)
            .map_err(|e| e.to_string())?
            .get(b"Annots")
            .is_ok()
        {
            return Err("Remove page annotations before vector-preserving raster redaction".into());
        }
        if self
            .history
            .current()
            .annotations
            .iter()
            .any(|a| a.page == page)
        {
            return Err("Remove annotations from the page before raster redaction".into());
        }
        let pixels = (width as usize)
            .checked_mul(height as usize)
            .ok_or("Image too large")?;
        if width == 0 || height == 0 || pixels > 4_000_000 || rgba.len() != pixels * 4 {
            return Err("Raster redaction requires a rendered page under four million pixels; zoom out first".into());
        }
        let [x1, y1, x2, y2] = rect;
        let (l, r, t, b) = (
            x1.min(x2).min(width),
            x1.max(x2).min(width),
            y1.min(y2).min(height),
            y1.max(y2).min(height),
        );
        if r - l < 2 || b - t < 2 {
            return Err("Drag a larger redaction area".into());
        }
        let box_ = self.page_box(index)?;
        let rotation = self.rotation(index)?;
        let (pw, ph) = if rotation == 90 || rotation == 270 {
            (box_[3] - box_[1], box_[2] - box_[0])
        } else {
            (box_[2] - box_[0], box_[3] - box_[1])
        };
        let mut rgb = Vec::with_capacity(pixels * 3);
        for (i, p) in rgba.chunks_exact(4).enumerate() {
            let x = i as u32 % width;
            let y = i as u32 / width;
            if x >= l && x < r && y >= t && y < b {
                rgb.extend_from_slice(&[0, 0, 0]);
            } else {
                let a = p[3] as u32;
                for c in &p[..3] {
                    rgb.push(((*c as u32 * a + 255 * (255 - a) + 127) / 255) as u8);
                }
            }
        }
        let page = self.history.current().pages[index];
        let mut state = self.history.current().clone();
        state.raster_pages.insert(
            page,
            RasterPage {
                width,
                height,
                rgb,
                page_width: pw,
                page_height: ph,
            },
        );
        state.crops.remove(&page);
        state.rotations.remove(&page);
        let candidate = Self {
            doc: self.doc.clone(),
            root: self.root,
            original_pages: self.original_pages.clone(),
            history: SnapshotHistory::new(state.clone(), 20),
        };
        candidate.save_snapshot()?;
        self.history.apply(state);
        Ok(())
    }

    pub fn compress_streams(&mut self) {
        let mut state = self.history.current().clone();
        state.compress_streams = true;
        self.history.apply(state);
    }
    fn ensure_reorder_safe(&self) -> Result<(), String> {
        if self.history.current().imported_acroform.is_some()
            || self
                .history
                .current()
                .bookmarks
                .as_ref()
                .is_some_and(|v| !v.is_empty())
        {
            return Err("Page deletion or extraction with active bookmarks or forms requires reference remapping".into());
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
        Ok(())
    }
    fn ensure_position_safe(&self) -> Result<(), String> {
        if self
            .doc
            .catalog()
            .map_err(|e| e.to_string())?
            .get(b"PageLabels")
            .is_ok()
        {
            return Err("Page changes with page labels require label remapping".into());
        }
        Ok(())
    }
    pub fn can_reorder(&self) -> bool {
        self.ensure_position_safe().is_ok()
    }
    /// Whether page-tree restructuring is supported, excluding selection boundaries.
    pub fn can_restructure(&self) -> bool {
        self.ensure_reorder_safe().is_ok()
    }
    pub fn insert_blank_after(&mut self, index: usize) -> Result<(), String> {
        self.ensure_position_safe()?;
        if self.page_count() >= MAX_PAGES {
            return Err("page limit exceeded".into());
        }
        let b = self.page_box(index)?;
        let id = self.doc.add_object(lopdf::dictionary! {"Type"=>"Page", "Parent"=>self.root, "MediaBox"=>b.iter().map(|v| Object::Real(*v as f32)).collect::<Vec<_>>(), "Resources"=>lopdf::dictionary!{}});
        let mut state = self.history.current().clone();
        state.pages.insert(index + 1, id);
        state.selected = id;
        self.history.apply(state);
        Ok(())
    }
    pub fn insert_pdf_after(&mut self, index: usize, path: &Path) -> Result<(), String> {
        self.ensure_position_safe()?;
        if index >= self.page_count() {
            return Err("page index out of range".into());
        }
        let mut source = PdfDocument::open(path)?;
        let source_catalog = source.doc.catalog().map_err(|e| e.to_string())?;
        for key in [
            b"Outlines".as_slice(),
            b"Names",
            b"Dests",
            b"PageLabels",
            b"StructTreeRoot",
            b"OpenAction",
            b"Threads",
        ] {
            if source_catalog.get(key).is_ok() {
                return Err("Imported PDF navigation, names, page labels or tagged structure cannot yet be merged".into());
            }
        }
        let source_form = source_catalog.get(b"AcroForm").ok().cloned();
        if source_form.is_some()
            && (self
                .doc
                .catalog()
                .map_err(|e| e.to_string())?
                .get(b"AcroForm")
                .is_ok()
                || self.history.current().imported_acroform.is_some())
        {
            return Err(
                "Cannot merge two AcroForms: field-name and resource collisions require resolution"
                    .into(),
            );
        }
        if let Some(form) = source_form {
            if form.as_reference().is_err() {
                let form = source.doc.add_object(form);
                source
                    .doc
                    .catalog_mut()
                    .map_err(|e| e.to_string())?
                    .set("AcroForm", form);
            }
        }
        let source_pages = source.history.current().pages.clone();
        if self.page_count() + source_pages.len() > MAX_PAGES {
            return Err("page limit exceeded".into());
        }
        flatten_pages(&mut source.doc, source.root, &source_pages)?;
        let start = self
            .doc
            .max_id
            .checked_add(1)
            .ok_or("PDF object limit exceeded")?;
        source.doc.renumber_objects_with(start);
        let pages: Vec<_> = source.doc.get_pages().values().copied().collect();
        let imported_form = source
            .doc
            .catalog()
            .map_err(|e| e.to_string())?
            .get(b"AcroForm")
            .ok()
            .and_then(|v| v.as_reference().ok());
        for page in &pages {
            source
                .doc
                .get_dictionary_mut(*page)
                .map_err(|e| e.to_string())?
                .set("Parent", self.root);
        }
        self.doc.max_id = self.doc.max_id.max(source.doc.max_id);
        self.doc.objects.extend(source.doc.objects);
        let mut state = self.history.current().clone();
        if imported_form.is_some() {
            state.imported_acroform = imported_form;
        }
        state
            .pages
            .splice(index + 1..index + 1, pages.iter().copied());
        state.selected = pages[0];
        self.history.apply(state);
        Ok(())
    }
    pub fn extract_page(&self, index: usize, path: &Path) -> Result<(), String> {
        self.ensure_reorder_safe()?;
        if index >= self.page_count() {
            return Err("page index out of range".into());
        }
        let (bytes, _) = self.save_snapshot()?;
        let options = LoadOptions {
            max_decompressed_size: Some(32 * 1024 * 1024),
            ..Default::default()
        };
        let mut doc =
            Document::load_mem_with_options(&bytes, options).map_err(|e| e.to_string())?;
        let pages: Vec<_> = doc.get_pages().values().copied().collect();
        let root = doc
            .catalog()
            .map_err(|e| e.to_string())?
            .get(b"Pages")
            .map_err(|e| e.to_string())?
            .as_reference()
            .map_err(|e| e.to_string())?;
        flatten_pages(&mut doc, root, &[pages[index]])?;
        doc.prune_objects();
        if pages
            .iter()
            .enumerate()
            .any(|(i, id)| i != index && doc.objects.contains_key(id))
        {
            return Err("Other pages remain referenced; cannot safely extract".into());
        }
        let mut out = Vec::new();
        doc.save_to(&mut out).map_err(|e| e.to_string())?;
        write_new(path, &out).map_err(|e| e.to_string())
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
        self.ensure_position_safe()?;
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
    pub fn save_snapshot(&self) -> Result<(Vec<u8>, SaveState), String> {
        let captured = self.history.snapshot();
        // Export from a disposable copy: pruning must not destroy undo state.
        let mut doc = self.doc.clone();
        let state = self.history.current();
        if let Some(form) = state.imported_acroform {
            doc.catalog_mut()
                .map_err(|e| e.to_string())?
                .set("AcroForm", form);
        }
        if !state.metadata.is_empty() {
            let mut info = match doc.trailer.get(b"Info") {
                Ok(value) => doc
                    .dereference(value)
                    .map_err(|e| e.to_string())?
                    .1
                    .as_dict()
                    .map_err(|e| e.to_string())?
                    .clone(),
                Err(_) => lopdf::Dictionary::new(),
            };
            for (key, value) in &state.metadata {
                info.set(key.as_bytes(), lopdf::text_string(value));
            }
            let id = doc.add_object(info);
            doc.trailer.set("Info", Object::Reference(id));
        }
        for (&id, &rotation) in &state.rotations {
            doc.get_dictionary_mut(id)
                .map_err(|e| e.to_string())?
                .set("Rotate", rotation);
        }
        let mut redacted_objects = HashSet::new();
        for (&id, raster) in &state.raster_pages {
            redacted_objects.extend(referenced_page_objects(&doc, id)?);
            let image = doc.add_object(lopdf::Stream::new(lopdf::dictionary!{"Type"=>"XObject", "Subtype"=>"Image", "Width"=>raster.width as i64, "Height"=>raster.height as i64, "ColorSpace"=>"DeviceRGB", "BitsPerComponent"=>8}, raster.rgb.clone()));
            let content = doc.add_object(lopdf::Stream::new(
                lopdf::dictionary! {},
                format!(
                    "q {} 0 0 {} 0 0 cm /Im0 Do Q",
                    raster.page_width, raster.page_height
                )
                .into_bytes(),
            ));
            let page = doc.get_dictionary_mut(id).map_err(|e| e.to_string())?;
            *page = lopdf::dictionary! {"Type"=>"Page", "Parent"=>self.root, "MediaBox"=>vec![0.into(),0.into(),Object::Real(raster.page_width as f32),Object::Real(raster.page_height as f32)], "Rotate"=>0, "Resources"=>lopdf::dictionary!{"XObject"=>lopdf::dictionary!{"Im0"=>image}}, "Contents"=>content};
        }
        for (&id, crop) in &state.crops {
            doc.get_dictionary_mut(id).map_err(|e| e.to_string())?.set(
                "CropBox",
                crop.iter()
                    .map(|v| Object::Real(*v as f32))
                    .collect::<Vec<_>>(),
            );
        }
        for (&id, text) in &state.annotation_text {
            if !state.deleted_annotations.contains(&id) {
                doc.get_dictionary_mut(id)
                    .map_err(|e| e.to_string())?
                    .set("Contents", lopdf::text_string(text));
            }
        }
        // Update existing annotations in the disposable export copy, preserving their appearances.
        for (&id, delta) in &state.moved_annotations {
            if state.deleted_annotations.contains(&id) {
                continue;
            }
            let annot = doc.get_dictionary_mut(id).map_err(|e| e.to_string())?;
            for key in [
                b"Rect".as_slice(),
                b"L".as_slice(),
                b"QuadPoints".as_slice(),
            ] {
                if let Ok(Object::Array(values)) = annot.get_mut(key) {
                    for (i, value) in values.iter_mut().enumerate() {
                        let n = match value {
                            Object::Integer(v) => *v as f64,
                            Object::Real(v) => *v as f64,
                            _ => return Err("Invalid annotation coordinates".into()),
                        };
                        *value = Object::Real((n + delta[i % 2]) as f32);
                    }
                }
            }
            if let Ok(Object::Array(strokes)) = annot.get_mut(b"InkList") {
                for stroke in strokes {
                    let values = stroke.as_array_mut().map_err(|e| e.to_string())?;
                    for (i, value) in values.iter_mut().enumerate() {
                        let n = match value {
                            Object::Integer(v) => *v as f64,
                            Object::Real(v) => *v as f64,
                            _ => return Err("Invalid ink coordinates".into()),
                        };
                        *value = Object::Real((n + delta[i % 2]) as f32);
                    }
                }
            }
        }
        if !state.deleted_annotations.is_empty() {
            for page in &state.pages {
                let old = doc
                    .get_dictionary(*page)
                    .map_err(|e| e.to_string())?
                    .get(b"Annots")
                    .ok()
                    .cloned();
                if let Some(old) = old {
                    let mut arr = doc
                        .dereference(&old)
                        .map_err(|e| e.to_string())?
                        .1
                        .as_array()
                        .map_err(|e| e.to_string())?
                        .clone();
                    arr.retain(|v| {
                        v.as_reference()
                            .map_or(true, |id| !state.deleted_annotations.contains(&id))
                    });
                    doc.get_dictionary_mut(*page)
                        .map_err(|e| e.to_string())?
                        .set("Annots", arr);
                }
            }
        }
        let definitions = self.form_definitions();
        let choice_display_text: String = definitions
            .iter()
            .filter(|f| state.form_values.contains_key(&f.id))
            .flat_map(|f| f.options.iter().map(|(_, display)| display.as_str()))
            .collect();
        let appearance_text: String = state
            .annotations
            .iter()
            .filter(|a| {
                matches!(
                    a.kind,
                    AnnotationKind::FreeText | AnnotationKind::Stamp | AnnotationKind::Note
                )
            })
            .map(|a| a.contents.as_str())
            .chain(state.annotation_text.values().map(String::as_str))
            .chain(state.form_values.values().map(String::as_str))
            .chain(std::iter::once(choice_display_text.as_str()))
            .chain(std::iter::once(" "))
            .flat_map(|s| s.chars().filter(|c| *c != '\r' && *c != '\n'))
            .collect();
        let font = if appearance_text.is_empty()
            && state.form_values.is_empty()
            && state.annotation_text.is_empty()
        {
            None
        } else {
            Some(suite42_pdf_text::PdfFont::embed(
                &mut doc,
                &appearance_text,
            )?)
        };
        for (&id, value) in &state.form_values {
            let field = definitions
                .iter()
                .find(|f| f.id == id)
                .ok_or("Form field no longer available")?;
            if field.kind == b"Btn" {
                doc.get_dictionary_mut(id)
                    .map_err(|e| e.to_string())?
                    .set("V", Object::Name(value.as_bytes().to_vec()));
                let mut selected_once = false;
                for widget in &field.widgets {
                    let matches = self
                        .button_states(*widget)
                        .iter()
                        .any(|s| s == value.as_bytes());
                    let on = matches
                        && (value == "Off"
                            || field.flags & (1 << 15) == 0
                            || field.flags & (1 << 25) != 0
                            || !selected_once);
                    if on && value != "Off" {
                        selected_once = true;
                    }
                    let state = if on { value.as_bytes() } else { b"Off" };
                    doc.get_dictionary_mut(*widget)
                        .map_err(|e| e.to_string())?
                        .set("AS", Object::Name(state.to_vec()));
                }
                continue;
            }
            let multi = field.kind == b"Ch" && field.flags & (1 << 21) != 0;
            let selected: Vec<_> = if multi {
                value.split(',').collect()
            } else {
                vec![value.as_str()]
            };
            let val = if multi {
                Object::Array(selected.iter().map(|v| lopdf::text_string(v)).collect())
            } else {
                lopdf::text_string(value)
            };
            {
                let d = doc.get_dictionary_mut(id).map_err(|e| e.to_string())?;
                d.set("V", val);
                if multi {
                    let indices = selected
                        .iter()
                        .filter_map(|v| field.options.iter().position(|(export, _)| export == v))
                        .map(|i| Object::Integer(i as i64))
                        .collect::<Vec<_>>();
                    d.set("I", indices);
                }
            }
            let display_value = if field.kind == b"Ch" {
                selected
                    .iter()
                    .filter_map(|v| {
                        field
                            .options
                            .iter()
                            .find(|(export, _)| export == v)
                            .map(|(_, display)| display.as_str())
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            } else {
                value.clone()
            };
            for widget in &field.widgets {
                let rect = doc
                    .get_dictionary(*widget)
                    .map_err(|e| e.to_string())?
                    .get(b"Rect")
                    .map_err(|e| e.to_string())?
                    .as_array()
                    .map_err(|e| e.to_string())?
                    .clone();
                let number = |v: &Object| match v {
                    Object::Integer(v) => Ok(*v as f64),
                    Object::Real(v) => Ok(*v as f64),
                    _ => Err("Invalid widget rectangle".to_string()),
                };
                if rect.len() != 4 {
                    return Err("Invalid widget rectangle".into());
                }
                let w = (number(&rect[2])? - number(&rect[0])?).abs();
                let h = (number(&rect[3])? - number(&rect[1])?).abs();
                let font = font.as_ref().ok_or("Missing form font")?;
                let hex = font.encode(&display_value)?;
                let size = (h * 0.6).clamp(4., 14.);
                let advance: u32 = display_value.chars().map(|c| font.chars[&c].2).sum();
                let scale = if advance == 0 {
                    100.
                } else {
                    ((w - 4.).max(1.) * 100000. / (advance as f64 * size)).min(100.)
                };
                let drawing=format!("1 1 1 rg 0 0 {w} {h} re f 0 0 0 rg BT /F1 {size} Tf {scale} Tz 2 {} Td <{hex}> Tj ET",(h-size).max(0.)/2.);
                let ap = doc.add_object(lopdf::Stream::new(lopdf::dictionary!{"Type"=>"XObject", "Subtype"=>"Form", "BBox"=>vec![0.into(),0.into(),Object::Real(w as f32),Object::Real(h as f32)], "Resources"=>lopdf::dictionary!{"Font"=>lopdf::dictionary!{"F1"=>font.id}}}, drawing.into_bytes()));
                doc.get_dictionary_mut(*widget)
                    .map_err(|e| e.to_string())?
                    .set("AP", lopdf::dictionary! {"N"=>ap});
            }
        }
        for (&id, text) in &state.annotation_text {
            if state.deleted_annotations.contains(&id) {
                continue;
            }
            let font = font.as_ref().ok_or("Missing annotation font")?;
            let rect = doc
                .get_dictionary(id)
                .map_err(|e| e.to_string())?
                .get(b"Rect")
                .map_err(|e| e.to_string())?
                .as_array()
                .map_err(|e| e.to_string())?
                .clone();
            let number = |v: &Object| match v {
                Object::Integer(v) => Ok(*v as f64),
                Object::Real(v) => Ok(*v as f64),
                _ => Err("Invalid annotation rectangle".to_string()),
            };
            if rect.len() != 4 {
                return Err("Invalid annotation rectangle".into());
            }
            let w = (number(&rect[2])? - number(&rect[0])?).abs();
            let h = (number(&rect[3])? - number(&rect[1])?).abs();
            let background = doc
                .get_dictionary(id)
                .map_err(|e| e.to_string())?
                .get(b"Subtype")
                .ok()
                .and_then(|v| v.as_name().ok())
                == Some(b"Text");
            let drawing = annotation_text_appearance(font, text, w, h, background)?;
            let ap = doc.add_object(lopdf::Stream::new(lopdf::dictionary!{"Type"=>"XObject", "Subtype"=>"Form", "BBox"=>vec![0.into(),0.into(),Object::Real(w as f32),Object::Real(h as f32)], "Resources"=>lopdf::dictionary!{"Font"=>lopdf::dictionary!{"F1"=>font.id}}}, drawing.into_bytes()));
            doc.get_dictionary_mut(id)
                .map_err(|e| e.to_string())?
                .set("AP", lopdf::dictionary! {"N"=>ap});
        }
        for annotation in &state.annotations {
            if !state.pages.contains(&annotation.page) {
                continue;
            }
            let [x1, y1, x2, y2] = annotation.rect;
            let (left, bottom, right, top) = (x1.min(x2), y1.min(y2), x1.max(x2), y1.max(y2));
            let (w, h) = (right - left, top - bottom);
            let (subtype, drawing) = if !annotation.quads.is_empty() {
                let mut drawing = match annotation.kind {
                    AnnotationKind::Highlight => String::from("/GS gs 1 1 0 rg "),
                    _ => String::from("1 0 0 RG 1 w "),
                };
                for q in &annotation.quads {
                    let (x, y, qw, qh) = (q[0] - left, q[1] - bottom, q[2] - q[0], q[3] - q[1]);
                    match annotation.kind {
                        AnnotationKind::Highlight => {
                            drawing.push_str(&format!("{x} {y} {qw} {qh} re f "))
                        }
                        AnnotationKind::Underline => {
                            drawing.push_str(&format!("{x} {y} m {} {y} l S ", x + qw))
                        }
                        _ => drawing.push_str(&format!(
                            "{x} {} m {} {} l S ",
                            y + qh / 2.,
                            x + qw,
                            y + qh / 2.
                        )),
                    }
                }
                (
                    match annotation.kind {
                        AnnotationKind::Highlight => "Highlight",
                        AnnotationKind::Underline => "Underline",
                        _ => "StrikeOut",
                    },
                    drawing,
                )
            } else {
                match annotation.kind {
                    AnnotationKind::Rectangle => (
                        "Square",
                        format!(
                            "1 0 0 RG 2 w 1 1 {} {} re S",
                            (w - 2.).max(0.),
                            (h - 2.).max(0.)
                        ),
                    ),
                    AnnotationKind::Ellipse => {
                        let (cx, cy, rx, ry) =
                            (w / 2., h / 2., (w / 2. - 1.).max(0.), (h / 2. - 1.).max(0.));
                        let k = 0.55228475;
                        ("Circle", format!("1 0 0 RG 2 w {} {} m {} {} {} {} {} {} c {} {} {} {} {} {} c {} {} {} {} {} {} c {} {} {} {} {} {} c S", cx+rx,cy,cx+rx,cy+k*ry,cx+k*rx,cy+ry,cx,cy+ry,cx-k*rx,cy+ry,cx-rx,cy+k*ry,cx-rx,cy,cx-rx,cy-k*ry,cx-k*rx,cy-ry,cx,cy-ry,cx+k*rx,cy-ry,cx+rx,cy-k*ry,cx+rx,cy))
                    }
                    AnnotationKind::Line => (
                        "Line",
                        format!(
                            "1 0 0 RG 2 w {} {} m {} {} l S",
                            x1 - left,
                            y1 - bottom,
                            x2 - left,
                            y2 - bottom
                        ),
                    ),
                    AnnotationKind::Ink => {
                        let mut path = String::from("1 0 0 RG 2 w 1 J 1 j ");
                        for (i, p) in annotation.points.iter().enumerate() {
                            path.push_str(&format!(
                                "{} {} {} ",
                                p[0] - left,
                                p[1] - bottom,
                                if i == 0 { "m" } else { "l" }
                            ));
                        }
                        path.push('S');
                        ("Ink", path)
                    }
                    AnnotationKind::Highlight => {
                        ("Highlight", format!("/GS gs 1 1 0 rg 0 0 {w} {h} re f"))
                    }
                    AnnotationKind::Underline => {
                        ("Underline", format!("1 0 0 RG 2 w 0 1 m {w} 1 l S"))
                    }
                    AnnotationKind::StrikeOut => (
                        "StrikeOut",
                        format!("1 0 0 RG 2 w 0 {} m {w} {} l S", h / 2., h / 2.),
                    ),
                    AnnotationKind::FreeText | AnnotationKind::Stamp | AnnotationKind::Note => {
                        let font = font.as_ref().ok_or("Missing annotation font")?;
                        let drawing = annotation_text_appearance(
                            font,
                            &annotation.contents,
                            w,
                            h,
                            annotation.kind != AnnotationKind::FreeText,
                        )?;
                        let subtype = match annotation.kind {
                            AnnotationKind::Stamp => "Stamp",
                            AnnotationKind::Note => "Text",
                            _ => "FreeText",
                        };
                        (subtype, drawing)
                    }
                    AnnotationKind::Link => (
                        "Link",
                        format!(
                            "0 0 1 RG 1 w 0.5 0.5 {} {} re S",
                            (w - 1.).max(0.),
                            (h - 1.).max(0.)
                        ),
                    ),
                }
            };
            let mut resources = lopdf::dictionary! {"ExtGState"=>lopdf::dictionary!{"GS"=>lopdf::dictionary!{"Type"=>"ExtGState", "BM"=>"Multiply", "ca"=>0.35}}};
            if let Some(font) = &font {
                resources.set("Font", lopdf::dictionary! {"F1"=>font.id});
            }
            let ap = doc.add_object(lopdf::Stream::new(lopdf::dictionary! {"Type"=>"XObject", "Subtype"=>"Form", "BBox"=>vec![0.into(), 0.into(), Object::Real(w as f32), Object::Real(h as f32)], "Resources"=>resources}, drawing.into_bytes()));
            let mut annot = lopdf::dictionary! {"Type"=>"Annot", "Subtype"=>subtype, "Rect"=>vec![Object::Real(left as f32),Object::Real(bottom as f32),Object::Real(right as f32),Object::Real(top as f32)], "C"=>vec![1.into(),0.into(),0.into()], "F"=>4, "AP"=>lopdf::dictionary!{"N"=>ap}};
            if matches!(
                annotation.kind,
                AnnotationKind::Highlight | AnnotationKind::Underline | AnnotationKind::StrikeOut
            ) {
                let quads = if annotation.quads.is_empty() {
                    vec![[left, bottom, right, top]]
                } else {
                    annotation.quads.clone()
                };
                let values: Vec<Object> = quads
                    .iter()
                    .flat_map(|q| {
                        [q[0], q[3], q[2], q[3], q[0], q[1], q[2], q[1]]
                            .map(|v| Object::Real(v as f32))
                    })
                    .collect();
                annot.set("QuadPoints", values);
            }
            if matches!(
                annotation.kind,
                AnnotationKind::Note | AnnotationKind::FreeText | AnnotationKind::Stamp
            ) {
                annot.set("Contents", lopdf::text_string(&annotation.contents));
            }
            if annotation.kind == AnnotationKind::Link {
                annot.set("A", lopdf::dictionary!{"S"=>"URI", "URI"=>Object::string_literal(annotation.contents.as_bytes())});
            }
            if annotation.kind == AnnotationKind::Ink {
                let stroke: Vec<Object> = annotation
                    .points
                    .iter()
                    .flat_map(|p| [Object::Real(p[0] as f32), Object::Real(p[1] as f32)])
                    .collect();
                annot.set("InkList", vec![Object::Array(stroke)]);
            }
            if annotation.kind == AnnotationKind::Line {
                annot.set(
                    "L",
                    vec![
                        Object::Real(x1 as f32),
                        Object::Real(y1 as f32),
                        Object::Real(x2 as f32),
                        Object::Real(y2 as f32),
                    ],
                );
            }
            let annot_id = doc.add_object(annot);
            let existing = doc
                .get_dictionary(annotation.page)
                .map_err(|e| e.to_string())?
                .get(b"Annots")
                .ok()
                .cloned();
            let mut annots = match existing {
                Some(value) => doc
                    .dereference(&value)
                    .map_err(|e| e.to_string())?
                    .1
                    .as_array()
                    .map_err(|e| e.to_string())?
                    .clone(),
                None => Vec::new(),
            };
            annots.push(Object::Reference(annot_id));
            doc.get_dictionary_mut(annotation.page)
                .map_err(|e| e.to_string())?
                .set("Annots", annots);
        }
        if state.pages != self.original_pages || !state.raster_pages.is_empty() {
            flatten_pages(&mut doc, self.root, &state.pages)?;
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
        if let Some(bookmarks) = &state.bookmarks {
            if bookmarks.is_empty() {
                doc.catalog_mut()
                    .map_err(|e| e.to_string())?
                    .remove(b"Outlines");
            } else {
                let old = doc
                    .catalog()
                    .map_err(|e| e.to_string())?
                    .get(b"Outlines")
                    .ok()
                    .cloned();
                let mut root = match old.as_ref() {
                    Some(v) => doc
                        .dereference(v)
                        .map_err(|e| e.to_string())?
                        .1
                        .as_dict()
                        .map_err(|e| e.to_string())?
                        .clone(),
                    None => lopdf::dictionary! {"Type"=>"Outlines"},
                };
                let root_id = match old.and_then(|v| v.as_reference().ok()) {
                    Some(id) => id,
                    None => doc.new_object_id(),
                };
                let ids: Vec<_> = bookmarks
                    .iter()
                    .map(|b| b.existing.unwrap_or_else(|| doc.new_object_id()))
                    .collect();
                for (i, b) in bookmarks.iter().enumerate() {
                    let mut item = match b.existing {
                        Some(id) => doc.get_dictionary(id).map_err(|e| e.to_string())?.clone(),
                        None => lopdf::dictionary! {},
                    };
                    item.set("Title", lopdf::text_string(&b.title));
                    item.set("Parent", root_id);
                    if i > 0 {
                        item.set("Prev", ids[i - 1]);
                    } else {
                        item.remove(b"Prev");
                    }
                    if i + 1 < ids.len() {
                        item.set("Next", ids[i + 1]);
                    } else {
                        item.remove(b"Next");
                    }
                    if b.existing.is_none() {
                        item.set(
                            "Dest",
                            vec![
                                Object::Reference(b.page.ok_or("Bookmark has no page")?),
                                Object::Name(b"Fit".to_vec()),
                            ],
                        );
                    }
                    doc.objects.insert(ids[i], Object::Dictionary(item));
                }
                root.set("First", ids[0]);
                root.set("Last", *ids.last().unwrap());
                root.set(
                    "Count",
                    bookmarks.iter().map(|b| 1 + b.descendants).sum::<i64>(),
                );
                doc.objects.insert(root_id, Object::Dictionary(root));
                doc.catalog_mut()
                    .map_err(|e| e.to_string())?
                    .set("Outlines", root_id);
            }
        }
        if !state.attachments_added.is_empty() || !state.attachments_removed.is_empty() {
            let mut entries: Vec<(Object, Object)> = self
                .embedded_entries()?
                .into_iter()
                .filter(|(name, _, _)| !state.attachments_removed.contains(name))
                .map(|(_, name, spec)| (name, spec))
                .collect();
            for (name, data) in &state.attachments_added {
                let stream=doc.add_object(lopdf::Stream::new(lopdf::dictionary!{"Type"=>"EmbeddedFile","Params"=>lopdf::dictionary!{"Size"=>data.len() as i64}},data.clone()));
                let spec=doc.add_object(lopdf::dictionary!{"Type"=>"Filespec","F"=>lopdf::text_string(name),"UF"=>lopdf::text_string(name),"EF"=>lopdf::dictionary!{"F"=>stream,"UF"=>stream}});
                entries.push((lopdf::text_string(name), Object::Reference(spec)));
            }
            entries.sort_by(|a, b| a.0.as_str().unwrap_or(&[]).cmp(b.0.as_str().unwrap_or(&[])));
            let flat: Vec<Object> = entries.into_iter().flat_map(|(a, b)| [a, b]).collect();
            let tree = doc.add_object(lopdf::dictionary! {"Names"=>flat});
            let mut names = match doc.catalog().map_err(|e| e.to_string())?.get(b"Names") {
                Ok(v) => doc
                    .dereference(v)
                    .map_err(|e| e.to_string())?
                    .1
                    .as_dict()
                    .map_err(|e| e.to_string())?
                    .clone(),
                Err(_) => lopdf::Dictionary::new(),
            };
            names.set("EmbeddedFiles", tree);
            doc.catalog_mut()
                .map_err(|e| e.to_string())?
                .set("Names", names);
        }
        if state.compress_streams {
            for object in doc.objects.values_mut() {
                if let Object::Stream(stream) = object {
                    stream.compress().map_err(|e| e.to_string())?;
                }
            }
        }
        doc.prune_objects();
        if redacted_objects
            .iter()
            .any(|id| doc.objects.contains_key(id))
        {
            return Err(
                "Redaction refused: original page objects are shared or still referenced elsewhere"
                    .into(),
            );
        }
        let mut out = Vec::new();
        doc.save_to(&mut out).map_err(|e| e.to_string())?;
        if out.len() as u64 > MAX_FILE * 2 {
            return Err("output exceeds limit".into());
        }
        Ok((out, SaveState(captured)))
    }
    pub fn mark_saved_snapshot(&mut self, state: SaveState) {
        self.history.mark_saved_snapshot(state.0);
    }
    pub fn save_as(&mut self, path: &Path) -> Result<(), String> {
        let (bytes, state) = self.save_snapshot()?;
        write_new(path, &bytes).map_err(|e| e.to_string())?;
        self.mark_saved_snapshot(state);
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    #[test]
    fn annotations_roundtrip_and_undo() {
        let dir = std::env::temp_dir().join(format!("pdf42-annotations-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        let mut pdf = PdfDocument::open(&input).unwrap();
        for kind in [
            AnnotationKind::Rectangle,
            AnnotationKind::Ellipse,
            AnnotationKind::Line,
        ] {
            pdf.add_annotation(0, kind, [20., 30., 100., 120.], "")
                .unwrap();
        }
        assert!(pdf.undo());
        assert_eq!(pdf.history.current().annotations.len(), 2);
        assert!(pdf.redo());
        let (bytes, _) = pdf.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let reopened = Document::load(&output).unwrap();
        let page = *reopened.get_pages().values().next().unwrap();
        let annots = reopened
            .get_dictionary(page)
            .unwrap()
            .get(b"Annots")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(annots.len(), 3);
        for (reference, subtype) in annots
            .iter()
            .zip([b"Square".as_slice(), b"Circle", b"Line"])
        {
            let annotation = reopened
                .get_dictionary(reference.as_reference().unwrap())
                .unwrap();
            assert_eq!(
                annotation.get(b"Subtype").unwrap().as_name().unwrap(),
                subtype
            );
            let appearance = annotation
                .get(b"AP")
                .unwrap()
                .as_dict()
                .unwrap()
                .get(b"N")
                .unwrap()
                .as_reference()
                .unwrap();
            assert!(!reopened
                .get_object(appearance)
                .unwrap()
                .as_stream()
                .unwrap()
                .content
                .is_empty());
        }
        assert!(PdfDocument::open(&output).is_ok());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn markup_crop_movement_and_contents_roundtrip() {
        let dir = std::env::temp_dir().join(format!("pdf42-markup-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        let mut pdf = PdfDocument::open(&input).unwrap();
        pdf.crop_page(0, [10., 10., 180., 280.]).unwrap();
        assert!(pdf.crop_page(0, [0., 0., 200., 300.]).is_err());
        for kind in [
            AnnotationKind::Highlight,
            AnnotationKind::Underline,
            AnnotationKind::StrikeOut,
            AnnotationKind::Note,
            AnnotationKind::Link,
        ] {
            let contents = if kind == AnnotationKind::Link {
                "https://example.org"
            } else {
                "Примечание"
            };
            pdf.add_annotation(0, kind, [20., 30., 100., 120.], contents)
                .unwrap();
        }
        let i = pdf.hit_annotation(0, [30., 40.]).unwrap();
        pdf.move_annotation(i, [10., 5.]).unwrap();
        assert!(pdf.undo());
        assert!(pdf.redo());
        pdf.delete_annotation(i).unwrap();
        assert!(pdf.undo());
        let (bytes, _) = pdf.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let reopened = Document::load(&output).unwrap();
        let page = *reopened.get_pages().values().next().unwrap();
        let dict = reopened.get_dictionary(page).unwrap();
        assert_eq!(dict.get(b"CropBox").unwrap().as_array().unwrap().len(), 4);
        let annots = dict.get(b"Annots").unwrap().as_array().unwrap();
        assert_eq!(annots.len(), 5);
        for reference in annots.iter().take(3) {
            let a = reopened
                .get_dictionary(reference.as_reference().unwrap())
                .unwrap();
            assert_eq!(a.get(b"QuadPoints").unwrap().as_array().unwrap().len(), 8);
        }
        let note = reopened
            .get_dictionary(annots[3].as_reference().unwrap())
            .unwrap();
        assert_eq!(
            lopdf::decode_text_string(note.get(b"Contents").unwrap()).unwrap(),
            "Примечание"
        );
        let link = reopened
            .get_dictionary(annots[4].as_reference().unwrap())
            .unwrap();
        assert_eq!(
            link.get(b"A")
                .unwrap()
                .as_dict()
                .unwrap()
                .get(b"URI")
                .unwrap()
                .as_str()
                .unwrap(),
            b"https://example.org"
        );
        assert_eq!(
            PdfDocument::open(&output).unwrap().page_box(0).unwrap(),
            [10., 10., 180., 280.]
        );
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn insert_extract_and_reopened_annotation_edit() {
        let dir =
            std::env::temp_dir().join(format!("pdf42-page-annotation-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let annotated = dir.join("annotated.pdf");
        let edited = dir.join("edited.pdf");
        let extract = dir.join("extract.pdf");
        sample(&input, false);
        let mut p = PdfDocument::open(&input).unwrap();
        p.insert_blank_after(0).unwrap();
        assert_eq!(p.page_count(), 4);
        assert!(p.undo());
        assert_eq!(p.page_count(), 3);
        assert!(p.redo());
        p.extract_page(1, &extract).unwrap();
        assert_eq!(PdfDocument::open(&extract).unwrap().page_count(), 1);
        p.add_annotation(0, AnnotationKind::Note, [20., 30., 100., 120.], "Привет")
            .unwrap();
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&annotated, bytes).unwrap();
        let mut q = PdfDocument::open(&annotated).unwrap();
        let sel = q.hit_annotation(0, [30., 40.]).unwrap();
        assert!(matches!(sel, AnnotationSelection::Existing(_)));
        q.set_note_text(sel, "Мир").unwrap();
        q.move_annotation(sel, [10., 10.]).unwrap();
        assert!(q.undo());
        assert!(q.redo());
        let (bytes, _) = q.save_snapshot().unwrap();
        fs::write(&edited, bytes).unwrap();
        let mut r = PdfDocument::open(&edited).unwrap();
        let sel = r.hit_annotation(0, [110., 130.]).unwrap();
        assert_eq!(r.annotation_contents(sel).as_deref(), Some("Мир"));
        r.delete_annotation(sel).unwrap();
        assert!(r.hit_annotation(0, [110., 130.]).is_none());
        assert!(r.undo());
        assert!(r.hit_annotation(0, [110., 130.]).is_some());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn simple_form_values_appearances_and_history() {
        let dir = std::env::temp_dir().join(format!("pdf42-forms-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        let mut d = Document::load(&input).unwrap();
        let page = *d.get_pages().values().next().unwrap();
        let mut fields = Vec::new();
        let text = d.add_object(lopdf::dictionary!{"Type"=>"Annot", "Subtype"=>"Widget", "FT"=>"Tx", "T"=>Object::string_literal("Name"), "Rect"=>vec![10.into(),10.into(),100.into(),30.into()], "V"=>Object::string_literal("old")});
        fields.push(Object::Reference(text));
        let yes = d.add_object(lopdf::Stream::new(lopdf::dictionary! {}, b"q Q".to_vec()));
        let off = d.add_object(lopdf::Stream::new(lopdf::dictionary! {}, b"q Q".to_vec()));
        let check = d.add_object(lopdf::dictionary!{"Type"=>"Annot", "Subtype"=>"Widget", "FT"=>"Btn", "T"=>Object::string_literal("Check"), "Rect"=>vec![10.into(),40.into(),30.into(),60.into()], "V"=>"Off", "AS"=>"Off", "AP"=>lopdf::dictionary!{"N"=>lopdf::dictionary!{"Off"=>off,"Yes"=>yes}}});
        fields.push(Object::Reference(check));
        let choice = d.add_object(lopdf::dictionary!{"Type"=>"Annot", "Subtype"=>"Widget", "FT"=>"Ch", "T"=>Object::string_literal("Choice"), "Rect"=>vec![10.into(),70.into(),100.into(),90.into()], "Opt"=>vec![Object::string_literal("one"),Object::string_literal("two")]});
        fields.push(Object::Reference(choice));
        d.get_dictionary_mut(page)
            .unwrap()
            .set("Annots", fields.clone());
        let form = d.add_object(lopdf::dictionary! {"Fields"=>fields});
        d.catalog_mut().unwrap().set("AcroForm", form);
        d.save(&input).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        assert_eq!(p.form_fields().len(), 3);
        p.set_form_value("Name", "Привет").unwrap();
        p.set_form_value("Check", "Yes").unwrap();
        p.set_form_value("Choice", "two").unwrap();
        assert!(p.set_form_value("Choice", "other").is_err());
        assert!(p.undo());
        assert!(p.redo());
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let reopened = PdfDocument::open(&output).unwrap();
        let fields = reopened.form_fields();
        assert!(fields.iter().any(|(n, _, v)| n == "Name" && v == "Привет"));
        assert!(fields.iter().any(|(n, _, v)| n == "Check" && v == "Yes"));
        assert!(fields.iter().any(|(n, _, v)| n == "Choice" && v == "two"));
        let saved = Document::load(&output).unwrap();
        for id in [text, choice] {
            assert!(saved.get_dictionary(id).unwrap().get(b"AP").is_ok());
        }
        assert_eq!(
            saved
                .get_dictionary(check)
                .unwrap()
                .get(b"AS")
                .unwrap()
                .as_name()
                .unwrap(),
            b"Yes"
        );
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn import_pages_remaps_objects_and_preserves_history() {
        let dir = std::env::temp_dir().join(format!("pdf42-import-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let other = dir.join("other.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        sample(&other, false);
        let mut p = PdfDocument::open(&input).unwrap();
        p.insert_pdf_after(0, &other).unwrap();
        assert_eq!(p.page_count(), 6);
        assert!(p.undo());
        assert_eq!(p.page_count(), 3);
        assert!(p.redo());
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let r = PdfDocument::open(&output).unwrap();
        assert_eq!(r.page_count(), 6);
        for i in 0..6 {
            assert_eq!(r.rotation(i).unwrap(), 90);
            assert_eq!(r.page_box(i).unwrap(), [0., 0., 200., 300.]);
        }
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn inherited_form_fields_update_all_widgets_and_radio_states() {
        let dir = std::env::temp_dir().join(format!("pdf42-nested-form-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        let mut d = Document::load(&input).unwrap();
        let root = d.new_object_id();
        let field = d.new_object_id();
        let w1 = d.add_object(lopdf::dictionary!{"Type"=>"Annot", "Subtype"=>"Widget", "Parent"=>field, "Rect"=>vec![0.into(),0.into(),100.into(),20.into()]});
        let w2 = d.add_object(lopdf::dictionary!{"Type"=>"Annot", "Subtype"=>"Widget", "Parent"=>field, "Rect"=>vec![0.into(),30.into(),100.into(),50.into()]});
        d.objects.insert(field,Object::Dictionary(lopdf::dictionary!{"T"=>Object::string_literal("name"), "Parent"=>root, "Kids"=>vec![Object::Reference(w1),Object::Reference(w2)]}));
        d.objects.insert(root,Object::Dictionary(lopdf::dictionary!{"T"=>Object::string_literal("person"), "FT"=>"Tx", "Kids"=>vec![Object::Reference(field)]}));
        let radio = d.new_object_id();
        let off = d.add_object(lopdf::Stream::new(lopdf::dictionary! {}, b"q Q".to_vec()));
        let on = d.add_object(lopdf::Stream::new(lopdf::dictionary! {}, b"q Q".to_vec()));
        let r1 = d.add_object(lopdf::dictionary!{"Subtype"=>"Widget", "Parent"=>radio, "Rect"=>vec![0.into(),60.into(),20.into(),80.into()], "AP"=>lopdf::dictionary!{"N"=>lopdf::dictionary!{"Off"=>off,"A"=>on}}});
        let r2 = d.add_object(lopdf::dictionary!{"Subtype"=>"Widget", "Parent"=>radio, "Rect"=>vec![30.into(),60.into(),50.into(),80.into()], "AP"=>lopdf::dictionary!{"N"=>lopdf::dictionary!{"Off"=>off,"B"=>on}}});
        d.objects.insert(radio,Object::Dictionary(lopdf::dictionary!{"T"=>Object::string_literal("radio"), "FT"=>"Btn", "Ff"=>1<<15, "Kids"=>vec![Object::Reference(r1),Object::Reference(r2)]}));
        let form = d.add_object(
            lopdf::dictionary! {"Fields"=>vec![Object::Reference(root),Object::Reference(radio)]},
        );
        d.catalog_mut().unwrap().set("AcroForm", form);
        d.save(&input).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        p.set_form_value("person.name", "Иван").unwrap();
        p.set_form_value("radio", "B").unwrap();
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let saved = Document::load(&output).unwrap();
        for w in [w1, w2] {
            assert!(saved.get_dictionary(w).unwrap().get(b"AP").is_ok());
        }
        assert_eq!(
            saved
                .get_dictionary(r1)
                .unwrap()
                .get(b"AS")
                .unwrap()
                .as_name()
                .unwrap(),
            b"Off"
        );
        assert_eq!(
            saved
                .get_dictionary(r2)
                .unwrap()
                .get(b"AS")
                .unwrap()
                .as_name()
                .unwrap(),
            b"B"
        );
        let reopened = PdfDocument::open(&output).unwrap();
        assert!(reopened
            .form_fields()
            .iter()
            .any(|(n, _, v)| n == "person.name" && v == "Иван"));
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn raster_redaction_prunes_original_content_and_refuses_shared_objects() {
        let dir = std::env::temp_dir().join(format!("pdf42-redact-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        let shared = dir.join("shared.pdf");
        sample(&input, false);
        let mut d = Document::load(&input).unwrap();
        let pages: Vec<_> = d.get_pages().values().copied().collect();
        let secret = d.add_object(lopdf::Stream::new(
            lopdf::dictionary! {},
            b"SECRET-ORIGINAL".to_vec(),
        ));
        d.get_dictionary_mut(pages[0])
            .unwrap()
            .set("Contents", secret);
        d.save(&input).unwrap();
        d.get_dictionary_mut(pages[1])
            .unwrap()
            .set("Contents", secret);
        d.save(&shared).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        let pixels = vec![255; 10 * 10 * 4];
        p.redact_raster(0, 10, 10, &pixels, [2, 2, 5, 5]).unwrap();
        assert!(p.undo());
        assert!(p.redo());
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, &bytes).unwrap();
        assert!(!bytes
            .windows(b"SECRET-ORIGINAL".len())
            .any(|w| w == b"SECRET-ORIGINAL"));
        let out = Document::load(&output).unwrap();
        assert!(!out.objects.contains_key(&secret));
        let page = *out.get_pages().values().next().unwrap();
        let resources = out
            .get_dictionary(page)
            .unwrap()
            .get(b"Resources")
            .unwrap()
            .as_dict()
            .unwrap();
        let image = resources
            .get(b"XObject")
            .unwrap()
            .as_dict()
            .unwrap()
            .get(b"Im0")
            .unwrap()
            .as_reference()
            .unwrap();
        let pixels = &out.get_object(image).unwrap().as_stream().unwrap().content;
        assert_eq!(&pixels[(2 * 10 + 2) * 3..(2 * 10 + 2) * 3 + 3], &[0, 0, 0]);
        assert_eq!(&pixels[..3], &[255, 255, 255]);
        assert_eq!(PdfDocument::open(&output).unwrap().rotation(0).unwrap(), 0);
        let mut q = PdfDocument::open(&shared).unwrap();
        assert!(q.redact_raster(0, 10, 10, &pixels, [2, 2, 5, 5]).is_err());
        assert!(!q.is_dirty());
        assert!(!q.can_undo());
        assert!(!q.can_redo());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn nested_reorder_preserves_inherited_page_attributes() {
        let dir = std::env::temp_dir().join(format!("pdf42-nested-reorder-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        let mut d = Document::with_version("1.5");
        let root = d.new_object_id();
        let branch = d.new_object_id();
        let a = d.add_object(lopdf::dictionary! {"Type"=>"Page","Parent"=>branch});
        let b = d.add_object(lopdf::dictionary! {"Type"=>"Page","Parent"=>branch});
        d.objects.insert(branch,Object::Dictionary(lopdf::dictionary!{"Type"=>"Pages","Parent"=>root,"Kids"=>vec![Object::Reference(a),Object::Reference(b)],"Count"=>2,"MediaBox"=>vec![0.into(),0.into(),200.into(),300.into()],"CropBox"=>vec![10.into(),20.into(),180.into(),280.into()],"Rotate"=>90,"Resources"=>lopdf::dictionary!{"ProcSet"=>vec![Object::Name(b"PDF".to_vec())]}}));
        d.objects.insert(root,Object::Dictionary(lopdf::dictionary!{"Type"=>"Pages","Kids"=>vec![Object::Reference(branch)],"Count"=>2}));
        let catalog = d.add_object(lopdf::dictionary! {"Type"=>"Catalog","Pages"=>root});
        d.trailer.set("Root", catalog);
        d.save(&input).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        p.move_page(0, 1).unwrap();
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let r = PdfDocument::open(&output).unwrap();
        assert_eq!(r.rotation(0).unwrap(), 90);
        assert_eq!(r.page_box(0).unwrap(), [10., 20., 180., 280.]);
        let page = r.doc.get_dictionary(r.original_pages[0]).unwrap();
        assert!(page.get(b"Resources").is_ok());
        assert_eq!(page.get(b"Parent").unwrap().as_reference().unwrap(), r.root);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn compressed_flattened_pages_are_editable_and_keep_redaction_pixels() {
        let rgba = vec![255; 400];
        let mut pages = Vec::new();
        for i in 0..12 {
            pages.push(
                FlattenedPage::from_rgba(
                    10,
                    10,
                    &rgba,
                    100.,
                    100.,
                    if i == 3 {
                        Some([0.2, 0.2, 0.5, 0.5])
                    } else {
                        None
                    },
                )
                .unwrap(),
            );
        }
        let mut pdf = PdfDocument::from_flattened_pages(pages, 3).unwrap();
        assert_eq!(pdf.page_count(), 12);
        assert!(pdf.is_dirty());
        assert_eq!(pdf.current(), 3);
        pdf.rotate(3, 90).unwrap();
        pdf.add_annotation(3, AnnotationKind::Rectangle, [1., 1., 10., 10.], "")
            .unwrap();
        let (bytes, _) = pdf.save_snapshot().unwrap();
        let raw = Document::load_mem(&bytes).unwrap();
        assert_eq!(raw.get_pages().len(), 12);
        let page = *raw.get_pages().values().nth(3).unwrap();
        let dict = raw.get_dictionary(page).unwrap();
        assert!(dict.get(b"Annots").is_ok());
        let image = dict
            .get(b"Resources")
            .unwrap()
            .as_dict()
            .unwrap()
            .get(b"XObject")
            .unwrap()
            .as_dict()
            .unwrap()
            .get(b"Im0")
            .unwrap()
            .as_reference()
            .unwrap();
        let pixels = raw
            .get_object(image)
            .unwrap()
            .as_stream()
            .unwrap()
            .decompressed_content()
            .unwrap();
        assert_eq!(&pixels[(2 * 10 + 2) * 3..(2 * 10 + 2) * 3 + 3], &[0, 0, 0]);
        assert_eq!(&pixels[..3], &[255, 255, 255]);
    }
    #[test]
    fn ink_and_text_markup_survive_move_undo_and_reopen() {
        let dir = std::env::temp_dir().join(format!("pdf42-ink-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        let mut pdf = PdfDocument::open(&input).unwrap();
        pdf.add_ink(0, &[[20., 30.], [30., 50.], [60., 40.]])
            .unwrap();
        pdf.add_text_markup(
            0,
            AnnotationKind::Highlight,
            &[[70., 100., 80., 110.], [81., 100., 90., 110.]],
        )
        .unwrap();
        assert!(pdf.undo());
        assert!(pdf.redo());
        let (bytes, _) = pdf.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let mut reopened = PdfDocument::open(&output).unwrap();
        let ink = reopened.hit_annotation(0, [30., 40.]).unwrap();
        reopened.move_annotation(ink, [10., 10.]).unwrap();
        let (bytes, _) = reopened.save_snapshot().unwrap();
        let doc = Document::load_mem(&bytes).unwrap();
        let page = *doc.get_pages().values().next().unwrap();
        let annots = doc
            .get_dictionary(page)
            .unwrap()
            .get(b"Annots")
            .unwrap()
            .as_array()
            .unwrap();
        let ink = doc
            .get_dictionary(annots[0].as_reference().unwrap())
            .unwrap();
        assert_eq!(ink.get(b"Subtype").unwrap().as_name().unwrap(), b"Ink");
        let stroke = ink.get(b"InkList").unwrap().as_array().unwrap()[0]
            .as_array()
            .unwrap();
        assert_eq!(stroke[0].as_float().unwrap(), 30.);
        assert_eq!(stroke[1].as_float().unwrap(), 40.);
        let highlight = doc
            .get_dictionary(annots[1].as_reference().unwrap())
            .unwrap();
        assert_eq!(
            highlight
                .get(b"QuadPoints")
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            16
        );
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn attachments_roundtrip_export_delete_and_history() {
        let dir = std::env::temp_dir().join(format!("pdf42-attachments-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let attach = dir.join("данные.txt");
        let saved = dir.join("saved.pdf");
        let exported = dir.join("exported.bin");
        sample(&input, false);
        fs::write(&attach, b"embedded attachment bytes").unwrap();
        let mut pdf = PdfDocument::open(&input).unwrap();
        pdf.add_attachment(&attach).unwrap();
        assert!(pdf.undo());
        assert!(pdf.attachments().unwrap().is_empty());
        assert!(pdf.redo());
        let (bytes, _) = pdf.save_snapshot().unwrap();
        fs::write(&saved, bytes).unwrap();
        let mut r = PdfDocument::open(&saved).unwrap();
        assert_eq!(r.attachments().unwrap(), vec!["данные.txt"]);
        r.export_attachment("данные.txt", &exported).unwrap();
        assert_eq!(fs::read(&exported).unwrap(), b"embedded attachment bytes");
        assert!(r.export_attachment("данные.txt", &exported).is_err());
        r.delete_attachment("данные.txt").unwrap();
        assert!(r.attachments().unwrap().is_empty());
        assert!(r.undo());
        assert_eq!(r.attachments().unwrap().len(), 1);
        assert!(r.redo());
        let (bytes, _) = r.save_snapshot().unwrap();
        assert!(!bytes
            .windows(b"embedded attachment bytes".len())
            .any(|s| s == b"embedded attachment bytes"));
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn bookmarks_save_navigate_edit_and_history() {
        let dir = std::env::temp_dir().join(format!("pdf42-bookmarks-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        let mut p = PdfDocument::open(&input).unwrap();
        p.add_bookmark("Первая").unwrap();
        p.select(2).unwrap();
        p.add_bookmark("Last").unwrap();
        p.move_bookmark(1, 0).unwrap();
        p.rename_bookmark(1, "Начало").unwrap();
        assert!(p.undo());
        assert!(p.redo());
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let mut r = PdfDocument::open(&output).unwrap();
        assert_eq!(r.bookmarks().unwrap(), vec!["Last", "Начало"]);
        r.select_bookmark(0).unwrap();
        assert_eq!(r.current(), 2);
        r.select_bookmark(1).unwrap();
        assert_eq!(r.current(), 0);
        r.delete_bookmark(0).unwrap();
        assert!(r.undo());
        assert_eq!(r.bookmarks().unwrap().len(), 2);
        assert!(r.redo());
        let (bytes, _) = r.save_snapshot().unwrap();
        let doc = Document::load_mem(&bytes).unwrap();
        let root = doc
            .catalog()
            .unwrap()
            .get(b"Outlines")
            .unwrap()
            .as_reference()
            .unwrap();
        assert_eq!(
            doc.get_dictionary(root)
                .unwrap()
                .get(b"Count")
                .unwrap()
                .as_i64()
                .unwrap(),
            1
        );
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn page_reorder_preserves_bookmark_targets_and_annotations() {
        let dir = std::env::temp_dir().join(format!("pdf42-reorder-nav-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let mid = dir.join("mid.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        let mut p = PdfDocument::open(&input).unwrap();
        p.select(1).unwrap();
        p.add_bookmark("target").unwrap();
        p.add_annotation(1, AnnotationKind::Rectangle, [20., 30., 100., 120.], "")
            .unwrap();
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&mid, bytes).unwrap();
        let mut p = PdfDocument::open(&mid).unwrap();
        assert!(p.can_reorder());
        p.move_page(1, 0).unwrap();
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let mut r = PdfDocument::open(&output).unwrap();
        r.select_bookmark(0).unwrap();
        assert_eq!(r.current(), 0);
        assert!(r.hit_annotation(0, [30., 40.]).is_some());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn multiline_unicode_text_can_be_edited_after_reopening() {
        let dir = std::env::temp_dir().join(format!("pdf42-multiline-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let mid = dir.join("mid.pdf");
        sample(&input, false);
        let mut p = PdfDocument::open(&input).unwrap();
        p.add_annotation(
            0,
            AnnotationKind::FreeText,
            [20., 30., 180., 160.],
            "Первая строка\nВторая строка",
        )
        .unwrap();
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&mid, bytes).unwrap();
        let mut r = PdfDocument::open(&mid).unwrap();
        let sel = r.hit_annotation(0, [30., 40.]).unwrap();
        assert_eq!(
            r.annotation_contents(sel).as_deref(),
            Some("Первая строка\nВторая строка")
        );
        r.set_note_text(sel, "Новая\nСтрока").unwrap();
        let (bytes, _) = r.save_snapshot().unwrap();
        let raw = Document::load_mem(&bytes).unwrap();
        let page = *raw.get_pages().values().next().unwrap();
        let a = raw
            .get_dictionary(
                raw.get_dictionary(page)
                    .unwrap()
                    .get(b"Annots")
                    .unwrap()
                    .as_array()
                    .unwrap()[0]
                    .as_reference()
                    .unwrap(),
            )
            .unwrap();
        assert_eq!(
            lopdf::decode_text_string(a.get(b"Contents").unwrap()).unwrap(),
            "Новая\nСтрока"
        );
        let ap = a
            .get(b"AP")
            .unwrap()
            .as_dict()
            .unwrap()
            .get(b"N")
            .unwrap()
            .as_reference()
            .unwrap();
        let stream = &raw.get_object(ap).unwrap().as_stream().unwrap().content;
        assert_eq!(stream.windows(2).filter(|w| *w == b"BT").count(), 2);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn imported_form_and_widget_survive_insert_edit_undo_reopen() {
        let dir = std::env::temp_dir().join(format!("pdf42-import-form-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let source = dir.join("form.pdf");
        let output = dir.join("out.pdf");
        sample(&input, false);
        sample(&source, false);
        let mut d = Document::load(&source).unwrap();
        let page = *d.get_pages().values().next().unwrap();
        let widget=d.add_object(lopdf::dictionary!{"Type"=>"Annot","Subtype"=>"Widget","FT"=>"Tx","T"=>Object::string_literal("FullName"),"Rect"=>vec![10.into(),10.into(),100.into(),30.into()],"P"=>page});
        d.get_dictionary_mut(page)
            .unwrap()
            .set("Annots", vec![Object::Reference(widget)]);
        let form = d.add_object(lopdf::dictionary! {"Fields"=>vec![Object::Reference(widget)]});
        d.catalog_mut().unwrap().set("AcroForm", form);
        d.save(&source).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        p.insert_pdf_after(0, &source).unwrap();
        assert_eq!(p.page_count(), 6);
        assert_eq!(p.form_fields()[0].0, "FullName");
        p.set_form_value("FullName", "Иван").unwrap();
        assert!(p.undo());
        assert!(p.undo());
        assert!(p.form_fields().is_empty());
        assert!(p.redo());
        assert!(p.redo());
        let (bytes, _) = p.save_snapshot().unwrap();
        fs::write(&output, bytes).unwrap();
        let r = PdfDocument::open(&output).unwrap();
        assert_eq!(r.page_count(), 6);
        assert_eq!(r.form_fields()[0].2, "Иван");
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn stream_compression_preserves_content_and_history() {
        let dir = std::env::temp_dir().join(format!("pdf42-compress-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        sample(&input, false);
        let mut d = Document::load(&input).unwrap();
        let page = *d.get_pages().values().next().unwrap();
        let original = vec![b'A'; 4096];
        let stream = d.add_object(lopdf::Stream::new(lopdf::dictionary! {}, original.clone()));
        d.get_dictionary_mut(page).unwrap().set("Contents", stream);
        d.save(&input).unwrap();
        let mut p = PdfDocument::open(&input).unwrap();
        p.compress_streams();
        assert!(p.undo());
        assert!(p.redo());
        let (bytes, _) = p.save_snapshot().unwrap();
        let r = Document::load_mem(&bytes).unwrap();
        let data = r.get_object(stream).unwrap().as_stream().unwrap();
        assert!(data.dict.get(b"Filter").is_ok());
        assert_eq!(data.decompressed_content().unwrap(), original);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn metadata_history_and_reopen() {
        let path = std::env::temp_dir().join(format!("pdf42-metadata-{}.pdf", std::process::id()));
        let output =
            std::env::temp_dir().join(format!("pdf42-metadata-output-{}.pdf", std::process::id()));
        sample(&path, false);
        let mut doc = super::PdfDocument::open(&path).unwrap();
        doc.set_metadata(&[("Title".into(), "Тест title".into())])
            .unwrap();
        assert!(doc.undo());
        assert_ne!(
            doc.metadata("Title").unwrap().as_deref(),
            Some("Тест title")
        );
        assert!(doc.redo());
        let (bytes, _) = doc.save_snapshot().unwrap();
        std::fs::write(&output, bytes).unwrap();
        let reopened = super::PdfDocument::open(&output).unwrap();
        assert_eq!(
            reopened.metadata("Title").unwrap().as_deref(),
            Some("Тест title")
        );
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(output).unwrap();
    }
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
        assert!(p.can_restructure());
        p.rotate(0, 90).unwrap();
        p.save_as(&out).unwrap();
        let reopened = PdfDocument::open(&out).unwrap();
        assert_eq!(reopened.rotation(0).unwrap(), 0);
        assert_ne!(
            reopened
                .doc
                .get_dictionary(reopened.original_pages[0])
                .unwrap()
                .get(b"Parent")
                .unwrap()
                .as_reference()
                .unwrap(),
            reopened.root
        );
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
