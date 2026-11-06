//! Image-page workflow with save-as PDF export; no scanner acquisition or OCR.
use lopdf::{dictionary, Document, Object, Stream};
use std::path::Path;
use suite42_core::{write_new, SnapshotHistory};
const MAX_PAGES: usize = 32;
const MAX_BYTES: usize = 16 * 1024 * 1024;
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}
pub struct ScanDocument {
    history: SnapshotHistory<Vec<Page>>,
}
impl Default for ScanDocument {
    fn default() -> Self {
        Self::new()
    }
}
impl ScanDocument {
    pub fn new() -> Self {
        Self {
            history: SnapshotHistory::new(Vec::new(), 5),
        }
    }
    pub fn pages(&self) -> &[Page] {
        self.history.current()
    }
    pub fn add_rgba(&mut self, width: u32, height: u32, pixels: Vec<u8>) -> Result<(), String> {
        let len = (width as usize)
            .checked_mul(height as usize)
            .and_then(|v| v.checked_mul(4))
            .ok_or("invalid dimensions")?;
        if width == 0
            || height == 0
            || width > 10000
            || height > 10000
            || pixels.len() != len
            || len > MAX_BYTES
            || self.pages().len() >= MAX_PAGES
            || self.pages().iter().map(|p| p.pixels.len()).sum::<usize>() + len > MAX_BYTES
        {
            return Err("invalid image or page/memory limit exceeded".into());
        }
        let mut pages = self.pages().to_vec();
        pages.push(Page {
            width,
            height,
            pixels,
        });
        self.history.apply(pages);
        Ok(())
    }
    pub fn delete(&mut self, index: usize) -> Result<(), String> {
        if index >= self.pages().len() {
            return Err("page index out of range".into());
        }
        let mut p = self.pages().to_vec();
        p.remove(index);
        self.history.apply(p);
        Ok(())
    }
    pub fn move_page(&mut self, from: usize, to: usize) -> Result<(), String> {
        if from >= self.pages().len() || to >= self.pages().len() {
            return Err("page index out of range".into());
        }
        let mut p = self.pages().to_vec();
        let x = p.remove(from);
        p.insert(to, x);
        self.history.apply(p);
        Ok(())
    }
    pub fn rotate(&mut self, index: usize) -> Result<(), String> {
        let mut p = self.pages().to_vec();
        let page = p.get_mut(index).ok_or("page index out of range")?;
        let (w, h) = (page.width as usize, page.height as usize);
        let mut out = vec![0; page.pixels.len()];
        for y in 0..h {
            for x in 0..w {
                let a = (y * w + x) * 4;
                let b = (x * h + (h - 1 - y)) * 4;
                out[b..b + 4].copy_from_slice(&page.pixels[a..a + 4]);
            }
        }
        page.width = h as u32;
        page.height = w as u32;
        page.pixels = out;
        self.history.apply(p);
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
    pub fn export_pdf(&mut self, path: &Path) -> Result<(), String> {
        if self.pages().is_empty() {
            return Err("cannot export an empty scan".into());
        }
        let mut doc = Document::with_version("1.5");
        let pages_id = doc.new_object_id();
        let mut kids = Vec::new();
        for page in self.pages() {
            let mut rgb = Vec::with_capacity(page.pixels.len() / 4 * 3);
            for p in page.pixels.as_chunks::<4>().0 {
                let a = p[3] as u32;
                for &c in &p[..3] {
                    rgb.push(((c as u32 * a + 255 * (255 - a) + 127) / 255) as u8)
                }
            }
            let image=doc.add_object(Stream::new(dictionary!{"Type"=>"XObject","Subtype"=>"Image","Width"=>page.width as i64,"Height"=>page.height as i64,"ColorSpace"=>"DeviceRGB","BitsPerComponent"=>8},rgb));
            let w = page.width as f32 * 72.0 / 150.0;
            let h = page.height as f32 * 72.0 / 150.0;
            let content = doc.add_object(Stream::new(
                dictionary! {},
                format!("q {w} 0 0 {h} 0 0 cm /Im0 Do Q\n").into_bytes(),
            ));
            let resources = dictionary! {"XObject"=>dictionary!{"Im0"=>image}};
            let id=doc.add_object(dictionary!{"Type"=>"Page","Parent"=>pages_id,"MediaBox"=>vec![0.into(),0.into(),w.into(),h.into()],"Resources"=>resources,"Contents"=>content});
            kids.push(Object::Reference(id));
        }
        doc.objects.insert(
            pages_id,
            Object::Dictionary(
                dictionary! {"Type"=>"Pages","Count"=>kids.len() as i64,"Kids"=>kids},
            ),
        );
        let catalog = doc.add_object(dictionary! {"Type"=>"Catalog","Pages"=>pages_id});
        doc.trailer.set("Root", catalog);
        let mut bytes = Vec::new();
        doc.save_to(&mut bytes).map_err(|e| e.to_string())?;
        write_new(path, &bytes).map_err(|e| e.to_string())?;
        self.history.mark_saved();
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn pages_history_and_pdf() {
        let mut d = ScanDocument::new();
        assert!(d.add_rgba(2, 1, vec![0; 7]).is_err());
        d.add_rgba(2, 1, vec![255, 0, 0, 255, 0, 0, 255, 0])
            .unwrap();
        d.add_rgba(1, 1, vec![1, 2, 3, 255]).unwrap();
        d.rotate(0).unwrap();
        assert_eq!((d.pages()[0].width, d.pages()[0].height), (1, 2));
        assert!(d.undo());
        assert_eq!(d.pages()[0].width, 2);
        assert!(d.redo());
        d.move_page(1, 0).unwrap();
        let path = std::env::temp_dir().join(format!("scn42-test-{}.pdf", std::process::id()));
        let _ = fs::remove_file(&path);
        d.export_pdf(&path).unwrap();
        assert!(!d.is_dirty());
        let pdf = Document::load(&path).unwrap();
        assert_eq!(pdf.get_pages().len(), 2);
        let first = *pdf.get_pages().values().next().unwrap();
        let media = pdf
            .get_dictionary(first)
            .unwrap()
            .get(b"MediaBox")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(media[2].as_float().unwrap(), 0.48);
        assert_eq!(media[3].as_float().unwrap(), 0.48);
        let images: Vec<_> = pdf
            .objects
            .values()
            .filter_map(|o| o.as_stream().ok())
            .filter(|s| {
                s.dict.get(b"Subtype").ok().and_then(|v| v.as_name().ok()) == Some(b"Image")
            })
            .collect();
        assert_eq!(images.len(), 2);
        assert!(images
            .iter()
            .any(|s| s.content == vec![255, 0, 0, 255, 255, 255]));
        assert!(d.export_pdf(&path).is_err());
        fs::remove_file(path).unwrap();
        d.delete(0).unwrap();
        assert!(d.is_dirty());
        assert!(d.undo());
        assert!(!d.is_dirty());
    }
}
