#![cfg_attr(windows, windows_subsystem = "windows")]
use doc42_core::Document;
use std::path::Path;
struct Doc {
    doc: Document,
}
impl win42::App for Doc {
    fn name(&self) -> &'static str {
        "DOC42"
    }
    fn extension(&self) -> &'static str {
        "txt"
    }
    fn format_name(&self) -> &'static str {
        "UTF-8 text"
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[]
    }
    fn items(&self) -> Vec<String> {
        vec![]
    }
    fn text(&self) -> String {
        win42::to_native_text(self.doc.text())
    }
    fn status(&self) -> String {
        format!(
            "UTF-8 plain text | {} characters | {} words",
            self.doc.text().chars().count(),
            self.doc.word_count()
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
    fn open(&mut self, p: &Path) -> Result<(), String> {
        let doc = Document::open(p).map_err(|e| e.to_string())?;
        win42::validate_editable(doc.text())?;
        self.doc = doc;
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.doc.save_as(p).map_err(|e| e.to_string())
    }
    fn edit(&mut self, s: String) -> Result<(), String> {
        self.doc
            .set_editor_text(win42::from_native_text(&s))
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    fn select(&mut self, _: usize) {}
    fn action(&mut self, id: u16) -> Result<(), String> {
        match id {
            4 => {
                self.doc.undo();
            }
            5 => {
                self.doc.redo();
            }
            _ => {}
        }
        Ok(())
    }
    fn supports_find_replace(&self) -> bool {
        true
    }
    fn find_next(&self, query: &str, start_utf16: usize) -> Result<Option<(usize, usize)>, String> {
        let text = self.doc.text();
        let native = win42::to_native_text(text);
        let mut native_byte = native.len();
        let mut units = 0;
        for (i, ch) in native.char_indices() {
            if units >= start_utf16 {
                native_byte = i;
                break;
            }
            units += ch.len_utf16();
        }
        let prefix = &native[..native_byte];
        let canonical_prefix = win42::from_native_text(prefix);
        let raw_prefix = if text.contains("\r\n") {
            canonical_prefix.replace('\n', "\r\n")
        } else {
            canonical_prefix
        };
        let query = win42::from_native_text(query);
        let query = if text.contains("\r\n") {
            query.replace('\n', "\r\n")
        } else {
            query
        };
        Ok(self.doc.find_next(&query, raw_prefix.len()).map(|range| {
            let start = win42::to_native_text(&text[..range.start])
                .encode_utf16()
                .count();
            let end = start + win42::to_native_text(&text[range]).encode_utf16().count();
            (start, end)
        }))
    }
    fn replace_all(&mut self, query: &str, replacement: &str) -> Result<usize, String> {
        self.doc
            .replace_all(query, replacement)
            .map_err(|e| e.to_string())
    }
    fn list_visible(&self) -> bool {
        false
    }
}
fn main() {
    win42::run(Box::new(Doc {
        doc: Document::new(),
    }))
}
#[cfg(test)]
mod tests {
    use super::*;
    use win42::App;
    #[test]
    fn editor_preserves_crlf_during_edit_and_save() {
        let mut d = Document::new();
        d.set_text("one\r\ntwo".into()).unwrap();
        let mut app = Doc { doc: d };
        assert_eq!(app.text(), "one\r\ntwo");
        app.edit("one".into()).unwrap();
        app.edit("one\r\nthree".into()).unwrap();
        let path = std::env::temp_dir().join(format!("doc42-ui-{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&path);
        app.save(&path).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"one\r\nthree");
        assert_eq!(Document::open(&path).unwrap().text(), "one\r\nthree");
        std::fs::remove_file(path).unwrap();
    }
}
#[cfg(test)]
mod policy_regression {
    use super::*;
    use win42::App;
    #[test]
    fn rejection_undo_and_branch_keep_core_policy() {
        let mut d = Document::new();
        d.set_text("a\r\nb".into()).unwrap();
        let mut a = Doc { doc: d };
        a.edit("single".into()).unwrap();
        assert!(a.edit("x".repeat(4 * 1024 * 1024 + 1)).is_err());
        a.action(4).unwrap();
        assert_eq!(a.doc.text(), "a\r\nb");
        a.edit("branch".into()).unwrap();
        assert!(!a.can_redo());
        a.edit("branch\r\nend".into()).unwrap();
        assert_eq!(a.doc.text(), "branch\r\nend");
    }
}

#[cfg(test)]
mod find_adapter_regression {
    use super::*;
    use win42::App;
    #[test]
    fn native_caret_inside_match_wraps_across_emoji_and_crlf() {
        let mut d = Document::new();
        d.set_text("x😀z\r\nend".into()).unwrap();
        let a = Doc { doc: d };
        assert_eq!(a.find_next("😀z\r\n", 3).unwrap(), Some((1, 6)));
        assert_eq!(a.find_next("😀z\r\n", 4).unwrap(), Some((1, 6)));
    }
    #[test]
    fn native_offsets_wrap_across_unicode_and_crlf() {
        let mut d = Document::new();
        d.set_text("😀 a\n😀 a".into()).unwrap();
        let a = Doc { doc: d };
        assert_eq!(a.find_next("😀", 0).unwrap(), Some((0, 2)));
        assert_eq!(a.find_next("😀", 2).unwrap(), Some((6, 8)));
        assert_eq!(a.find_next("😀", 8).unwrap(), Some((0, 2)));
        assert_eq!(a.find_next("missing", 0).unwrap(), None);
    }
}
