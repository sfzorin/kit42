#![cfg_attr(windows, windows_subsystem = "windows")]
use pdf42_core::PdfDocument;
use std::path::Path;
#[derive(Default)]
struct Pdf {
    doc: Option<PdfDocument>,
    index: usize,
    dirty: bool,
}
impl win42::App for Pdf {
    fn name(&self) -> &'static str {
        "PDF42"
    }
    fn extension(&self) -> &'static str {
        "pdf"
    }
    fn format_name(&self) -> &'static str {
        "PDF document"
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[
            (10, "Rotate &Right"),
            (11, "&Delete Page"),
            (12, "Move Page &Up"),
            (13, "Move Page D&own"),
        ]
    }
    fn items(&self) -> Vec<String> {
        self.doc
            .as_ref()
            .map(|d| {
                (0..d.page_count())
                    .map(|i| format!("Page {} — {}°", i + 1, d.rotation(i).unwrap_or(0)))
                    .collect()
            })
            .unwrap_or_default()
    }
    fn text(&self) -> String {
        "PDF page structure view. Page rendering is not available in this build.\r\nSelect a page and use the Edit menu to rotate, delete or reorder it.".into()
    }
    fn status(&self) -> String {
        format!(
            "PDF structure only | {} pages | no page renderer",
            self.doc.as_ref().map_or(0, |d| d.page_count())
        )
    }
    fn can_save(&self) -> bool {
        self.doc.is_some()
    }
    fn selected(&self) -> usize {
        self.index
    }
    fn enabled(&self, id: u16) -> bool {
        let Some(d) = self.doc.as_ref() else {
            return false;
        };
        let n = d.page_count();
        match id {
            10 => self.index < n,
            11 => d.can_restructure() && n > 1 && self.index < n,
            12 => d.can_restructure() && self.index > 0 && self.index < n,
            13 => d.can_restructure() && self.index + 1 < n,
            _ => true,
        }
    }
    fn dirty(&self) -> bool {
        self.dirty
    }
    fn can_undo(&self) -> bool {
        false
    }
    fn can_redo(&self) -> bool {
        false
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        self.doc = Some(PdfDocument::open(p)?);
        self.index = 0;
        self.dirty = false;
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.doc.as_mut().ok_or("Open a PDF first")?.save_as(p)?;
        self.dirty = false;
        Ok(())
    }
    fn edit(&mut self, _: String) -> Result<(), String> {
        Ok(())
    }
    fn select(&mut self, i: usize) {
        self.index = i
    }
    fn text_readonly(&self) -> bool {
        true
    }
    fn action(&mut self, id: u16) -> Result<(), String> {
        if id >= 10 && !self.enabled(id) {
            return Err("Command unavailable".into());
        }
        let d = self.doc.as_mut().ok_or("Open a PDF first")?;
        let n = d.page_count();
        match id {
            10 => d.rotate(self.index, 90)?,
            11 => {
                d.delete(self.index)?;
                self.index = self.index.min(d.page_count().saturating_sub(1));
            }
            12 if self.index > 0 => {
                d.move_page(self.index, self.index - 1)?;
                self.index -= 1
            }
            13 if self.index + 1 < n => {
                d.move_page(self.index, self.index + 1)?;
                self.index += 1
            }
            _ => return Ok(()),
        }
        self.dirty = true;
        Ok(())
    }
}
fn main() {
    win42::run(Box::new(Pdf::default()))
}
#[cfg(test)]
mod tests {
    use super::*;
    use win42::App;
    #[test]
    fn command_boundaries_and_unsafe_structure_refuse_dispatch() {
        let dir = std::env::temp_dir().join(format!("pdf42-ui-boundary-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.pdf");
        let unsafe_path = dir.join("unsafe.pdf");
        let _ = std::fs::remove_file(&input);
        let _ = std::fs::remove_file(&unsafe_path);
        let mut scan = scn42_core::ScanDocument::new();
        scan.add_rgba(1, 1, vec![255, 255, 255, 255]).unwrap();
        scan.add_rgba(1, 1, vec![0, 0, 0, 255]).unwrap();
        scan.export_pdf(&input).unwrap();
        let mut a = Pdf::default();
        for id in 10..=13 {
            assert!(!a.enabled(id));
            assert!(a.action(id).is_err());
        }
        a.open(&input).unwrap();
        assert!(!a.enabled(12));
        assert!(a.enabled(13));
        a.action(13).unwrap();
        assert!(!a.enabled(13));
        assert!(a.enabled(12));
        a.action(11).unwrap();
        assert!(!a.enabled(11));
        assert!(a.action(11).is_err());
        let mut doc = lopdf::Document::load(&input).unwrap();
        let page = *doc.get_pages().values().next().unwrap();
        doc.get_dictionary_mut(page)
            .unwrap()
            .set("Annots", lopdf::Object::Array(vec![]));
        doc.save(&unsafe_path).unwrap();
        let mut b = Pdf::default();
        b.open(&unsafe_path).unwrap();
        assert!(b.enabled(10));
        for id in 11..=13 {
            assert!(!b.enabled(id));
            assert!(b.action(id).is_err());
        }
        assert_eq!(b.doc.as_ref().unwrap().page_count(), 2);
        assert!(!b.dirty());
        b.action(10).unwrap();
        assert!(b.dirty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
