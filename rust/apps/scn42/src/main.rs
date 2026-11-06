#![cfg_attr(windows, windows_subsystem = "windows")]
use scn42_core::ScanDocument;
use std::path::Path;
struct Scn {
    doc: ScanDocument,
    index: usize,
}
impl win42::App for Scn {
    fn name(&self) -> &'static str {
        "SCN42"
    }
    fn extension(&self) -> &'static str {
        "scn42"
    }
    fn format_name(&self) -> &'static str {
        "SCN42 project"
    }
    fn open_filter(&self) -> String {
        "*.scn42".into()
    }
    fn supports_new(&self) -> bool {
        true
    }
    fn new_document(&mut self) -> Result<(), String> {
        self.doc = ScanDocument::new();
        self.index = 0;
        Ok(())
    }
    fn file_actions(&self) -> &'static [win42::FileAction] {
        &[
            win42::FileAction {
                id: 20,
                title: "&Import Image...",
                save: false,
                extension: "png",
                format: "PNG / JPEG image",
                pattern: "*.png;*.jpg;*.jpeg",
            },
            win42::FileAction {
                id: 21,
                title: "&Export PDF...",
                save: true,
                extension: "pdf",
                format: "PDF",
                pattern: "*.pdf",
            },
        ]
    }
    fn file_action(&mut self, id: u16, p: &Path) -> Result<(), String> {
        match id {
            20 => {
                let img = img42_core::ImageDocument::open(p).map_err(|e| e.to_string())?;
                self.doc
                    .add_rgba(img.width(), img.height(), img.pixels().to_vec())?;
                self.index = self.doc.pages().len() - 1;
                Ok(())
            }
            21 => self.doc.export_pdf(p),
            _ => Err("Unknown file action".into()),
        }
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[
            (10, "Rotate &Right"),
            (11, "&Delete Page"),
            (12, "Move Page &Up"),
            (13, "Move Page D&own"),
            (14, "Flip &Horizontal"),
            (15, "Flip &Vertical"),
        ]
    }
    fn items(&self) -> Vec<String> {
        self.doc
            .pages()
            .iter()
            .enumerate()
            .map(|(i, p)| format!("Page {} — {} × {}", i + 1, p.width, p.height))
            .collect()
    }
    fn can_save(&self) -> bool {
        true
    }
    fn selected(&self) -> usize {
        self.index
    }
    fn text(&self) -> String {
        "Import PNG or JPEG images to add pages. This build does not acquire images from a scanner or perform OCR.".into()
    }
    fn text_readonly(&self) -> bool {
        true
    }
    fn image(&self) -> Option<(u32, u32, Vec<u8>)> {
        self.doc
            .pages()
            .get(self.index)
            .map(|p| (p.width, p.height, p.pixels.clone()))
    }
    fn status(&self) -> String {
        format!(
            "{} pages | Save As project; Export PDF | no scanner or OCR",
            self.doc.pages().len()
        )
    }
    fn dirty(&self) -> bool {
        self.doc.is_dirty()
    }
    fn can_undo(&self) -> bool {
        self.doc.can_undo()
    }
    fn can_redo(&self) -> bool {
        self.doc.can_redo()
    }
    fn enabled(&self, id: u16) -> bool {
        let n = self.doc.pages().len();
        match id {
            10 | 11 | 14 | 15 | 21 => n > 0,
            12 => n > 0 && self.index > 0,
            13 => self.index + 1 < n,
            _ => true,
        }
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        let doc = ScanDocument::open_project(p)?;
        self.doc = doc;
        self.index = 0;
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.doc.save_project(p)
    }
    fn edit(&mut self, _: String) -> Result<(), String> {
        Ok(())
    }
    fn select(&mut self, i: usize) {
        self.index = i
    }
    fn action(&mut self, id: u16) -> Result<(), String> {
        if id >= 10 && !self.enabled(id) {
            return Err("Command unavailable".into());
        }
        match id {
            4 => {
                self.doc.undo();
            }
            5 => {
                self.doc.redo();
            }
            10 => self.doc.rotate(self.index)?,
            11 => self.doc.delete(self.index)?,
            14 => self.doc.flip(self.index, true)?,
            15 => self.doc.flip(self.index, false)?,
            12 if self.index > 0 => {
                self.doc.move_page(self.index, self.index - 1)?;
                self.index -= 1
            }
            13 if self.index + 1 < self.doc.pages().len() => {
                self.doc.move_page(self.index, self.index + 1)?;
                self.index += 1
            }
            _ => {}
        }
        self.index = self.index.min(self.doc.pages().len().saturating_sub(1));
        Ok(())
    }
}
fn main() {
    win42::run(Box::new(Scn {
        doc: ScanDocument::new(),
        index: 0,
    }))
}
#[cfg(test)]
mod tests {
    use super::*;
    use win42::App;
    #[test]
    fn adapter_project_and_export_are_distinct() {
        let dir = std::env::temp_dir().join(format!("scn42-adapter-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).unwrap();
        let mut app = Scn {
            doc: ScanDocument::new(),
            index: 0,
        };
        app.doc
            .add_rgba(2, 1, vec![1, 2, 3, 4, 5, 6, 7, 8])
            .unwrap();
        app.action(14).unwrap();
        let pixels = app.doc.pages()[0].pixels.clone();
        app.file_action(21, &dir.join("out.pdf")).unwrap();
        assert!(app.dirty());
        app.save(&dir.join("project.scn42")).unwrap();
        assert!(!app.dirty());
        app.action(11).unwrap();
        assert!(app.dirty());
        app.open(&dir.join("project.scn42")).unwrap();
        assert!(!app.dirty());
        assert_eq!(app.doc.pages()[0].pixels, pixels);
        let before = app.doc.pages().to_vec();
        std::fs::write(dir.join("bad.scn42"), b"broken").unwrap();
        assert!(app.open(&dir.join("bad.scn42")).is_err());
        assert_eq!(app.doc.pages(), before);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn boundary_commands_match_actions() {
        let mut a = Scn {
            doc: ScanDocument::new(),
            index: 0,
        };
        for id in 10..=13 {
            assert!(!a.enabled(id));
            assert!(a.action(id).is_err());
        }
        a.doc.add_rgba(1, 1, vec![255, 0, 0, 255]).unwrap();
        assert!(a.enabled(10));
        assert!(a.enabled(11));
        assert!(!a.enabled(12));
        assert!(!a.enabled(13));
        assert!(a.action(12).is_err());
        a.doc.add_rgba(1, 1, vec![0, 0, 0, 255]).unwrap();
        assert!(a.enabled(13));
        a.action(13).unwrap();
        assert!(a.enabled(12));
        assert!(!a.enabled(13));
    }
}
