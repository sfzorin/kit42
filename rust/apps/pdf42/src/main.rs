#![cfg_attr(windows, windows_subsystem = "windows")]
use pdf42_core::PdfDocument;
use std::path::Path;
#[derive(Default)]
struct Pdf {
    doc: Option<PdfDocument>,
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
        match &self.doc {
            Some(d) => format!("PDF structure only | Page {} of {} | {}° | Title: {} | Author: {} | no page renderer", d.current() + 1, d.page_count(), d.rotation(d.current()).unwrap_or(0), d.metadata("Title").ok().flatten().unwrap_or_default(), d.metadata("Author").ok().flatten().unwrap_or_default()),
            None => "PDF structure only | no document | no page renderer".into(),
        }
    }
    fn can_save(&self) -> bool {
        self.doc.is_some()
    }
    fn selected(&self) -> usize {
        self.doc.as_ref().map_or(0, |d| d.current())
    }
    fn enabled(&self, id: u16) -> bool {
        let Some(d) = self.doc.as_ref() else {
            return false;
        };
        let n = d.page_count();
        let index = d.current();
        match id {
            10 => index < n,
            11 => d.can_restructure() && n > 1 && index < n,
            12 => d.can_restructure() && index > 0 && index < n,
            13 => d.can_restructure() && index + 1 < n,
            _ => true,
        }
    }
    fn dirty(&self) -> bool {
        self.doc.as_ref().is_some_and(|d| d.is_dirty())
    }
    fn can_undo(&self) -> bool {
        self.doc.as_ref().is_some_and(|d| d.can_undo())
    }
    fn can_redo(&self) -> bool {
        self.doc.as_ref().is_some_and(|d| d.can_redo())
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        self.doc = Some(PdfDocument::open(p)?);
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.doc.as_mut().ok_or("Open a PDF first")?.save_as(p)?;
        Ok(())
    }
    fn edit(&mut self, _: String) -> Result<(), String> {
        Ok(())
    }
    fn select(&mut self, i: usize) {
        if let Some(d) = self.doc.as_mut() {
            let _ = d.select(i);
        }
    }
    fn text_readonly(&self) -> bool {
        true
    }
    fn action(&mut self, id: u16) -> Result<(), String> {
        if id >= 10 && !self.enabled(id) {
            return Err("Command unavailable".into());
        }
        let d = self.doc.as_mut().ok_or("Open a PDF first")?;
        let index = d.current();
        match id {
            4 => {
                d.undo();
            }
            5 => {
                d.redo();
            }
            10 => d.rotate(index, 90)?,
            11 => d.delete(index)?,
            12 => d.move_page(index, index - 1)?,
            13 => d.move_page(index, index + 1)?,
            _ => {}
        }
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
        assert!(a.can_undo());
        a.action(4).unwrap();
        assert_eq!(a.selected(), 0);
        assert!(a.can_redo());
        a.action(5).unwrap();
        assert_eq!(a.selected(), 1);
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
