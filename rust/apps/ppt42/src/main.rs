#![cfg_attr(windows, windows_subsystem = "windows")]
use ppt42_core::Presentation;
use std::path::Path;
struct Ppt {
    deck: Presentation,
}
impl Ppt {
    fn new(deck: Presentation) -> Self {
        Self { deck }
    }
}
impl win42::App for Ppt {
    fn name(&self) -> &'static str {
        "PPT42"
    }
    fn extension(&self) -> &'static str {
        "json"
    }
    fn format_name(&self) -> &'static str {
        "Suite42 slides JSON"
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[
            (10, "&Add Slide"),
            (11, "&Delete Slide"),
            (12, "Move Slide &Up"),
            (13, "Move Slide D&own"),
            (14, "D&uplicate Slide"),
        ]
    }
    fn items(&self) -> Vec<String> {
        self.deck
            .slides()
            .iter()
            .enumerate()
            .map(|(i, s)| format!("{}: {}", i + 1, s.title))
            .collect()
    }
    fn text(&self) -> String {
        let s = &self.deck.slides()[self.deck.current()];
        format!("{}\r\n{}", s.title, win42::to_native_text(&s.body))
    }
    fn status(&self) -> String {
        format!(
            "Slide {} of {} | first line is title; remaining text is body | Suite42 JSON",
            self.deck.current() + 1,
            self.deck.slides().len()
        )
    }
    fn dirty(&self) -> bool {
        self.deck.is_dirty()
    }
    fn can_undo(&self) -> bool {
        self.deck.can_undo()
    }
    fn can_redo(&self) -> bool {
        self.deck.can_redo()
    }
    fn selected(&self) -> usize {
        self.deck.current()
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        let presentation = Presentation::open(p)?;
        for slide in presentation.slides() {
            win42::validate_editable(&slide.title)?;
            win42::validate_editable(&slide.body)?;
            if slide.title.contains('\n') {
                return Err("Slide titles containing line breaks cannot be preserved by this editor. File was not opened.".into());
            }
        }
        *self = Ppt::new(presentation);
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.deck.save_as(p)
    }
    fn edit(&mut self, s: String) -> Result<(), String> {
        let text = win42::from_native_text(&s);
        let (title, body) = text.split_once('\n').unwrap_or((&text, ""));
        self.deck.edit(title.into(), body.into())
    }
    fn select(&mut self, i: usize) {
        let _ = self.deck.select(i);
    }
    fn enabled(&self, id: u16) -> bool {
        let i = self.deck.current();
        let n = self.deck.slides().len();
        match id {
            10 => self.deck.can_add(),
            11 => n > 1,
            12 => i > 0,
            13 => i + 1 < n,
            14 => self.deck.can_duplicate(),
            _ => true,
        }
    }
    fn action(&mut self, id: u16) -> Result<(), String> {
        if id >= 10 && !self.enabled(id) {
            return Err("Command unavailable".into());
        }
        let i = self.deck.current();
        match id {
            4 => {
                self.deck.undo();
                Ok(())
            }
            5 => {
                self.deck.redo();
                Ok(())
            }
            10 => self.deck.add(),
            11 => self.deck.delete(),
            12 => self.deck.move_slide(i, i - 1),
            13 => self.deck.move_slide(i, i + 1),
            14 => self.deck.duplicate(),
            _ => Ok(()),
        }
    }
}
fn main() {
    win42::run(Box::new(Ppt::new(Presentation::new())))
}
#[cfg(test)]
mod tests {
    use super::*;
    use win42::App;
    #[test]
    fn duplicate_menu_dispatch_tracks_history() {
        let mut app = Ppt::new(Presentation::new());
        app.edit("Title\r\nBody".into()).unwrap();
        assert!(app.enabled(14));
        app.action(14).unwrap();
        assert_eq!(app.selected(), 1);
        assert_eq!(app.text(), "Title\r\nBody");
        assert_ne!(app.deck.slides()[0].id, app.deck.slides()[1].id);
        app.action(4).unwrap();
        assert_eq!(app.selected(), 0);
        app.action(5).unwrap();
        assert_eq!(app.selected(), 1);
    }
    #[test]
    fn slide_editor_preserves_crlf() {
        let mut p = Presentation::new();
        p.edit_raw("title".into(), "a\r\nb".into()).unwrap();
        let mut a = Ppt::new(p);
        assert_eq!(a.text(), "title\r\na\r\nb");
        a.edit("title\r\na".into()).unwrap();
        a.select(0);
        a.edit("title\r\na\r\nc".into()).unwrap();
        assert_eq!(a.deck.slides()[0].body, "a\r\nc");
    }
}
#[cfg(test)]
mod regression {
    use super::*;
    use win42::App;
    #[test]
    fn policy_survives_reorder_undo_redo_and_context_switch() {
        let mut d = Presentation::new();
        d.edit_raw("one".into(), "a\r\nb".into()).unwrap();
        d.add().unwrap();
        d.edit("two".into(), "x\ny".into()).unwrap();
        let path = std::env::temp_dir().join(format!("ppt42-policy-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        d.save_as(&path).unwrap();
        let mut a = Ppt::new(Presentation::open(&path).unwrap());
        a.select(0);
        a.edit("one\r\na".into()).unwrap();
        a.action(13).unwrap();
        a.action(4).unwrap();
        a.action(5).unwrap();
        a.select(0);
        a.select(1);
        a.edit("one\r\na\r\nc".into()).unwrap();
        assert_eq!(a.deck.slides()[1].body, "a\r\nc");
        assert_eq!(a.deck.slides()[0].body, "x\ny");
        let out =
            std::env::temp_dir().join(format!("ppt42-policy-out-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&out);
        a.save(&out).unwrap();
        let re = Presentation::open(&out).unwrap();
        assert_eq!(re.slides()[1].body, "a\r\nc");
        assert_eq!(re.slides()[0].body, "x\ny");
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(out).unwrap();
    }
    #[test]
    fn rejected_and_noop_edit_do_not_desynchronize_policy_history() {
        let mut d = Presentation::new();
        d.edit_raw("one".into(), "a\r\nb".into()).unwrap();
        let path = std::env::temp_dir().join(format!("ppt42-branch-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        d.save_as(&path).unwrap();
        let mut a = Ppt::new(Presentation::open(&path).unwrap());
        a.edit("one\r\na".into()).unwrap();
        assert!(a.edit(format!("one\r\n{}", "x".repeat(32769))).is_err());
        a.edit("one\r\na".into()).unwrap();
        a.action(4).unwrap();
        assert_eq!(a.deck.slides()[0].body, "a\r\nb");
        a.edit("one\r\nbranch".into()).unwrap();
        assert!(!a.can_redo());
        a.edit("one\r\nbranch\r\nnext".into()).unwrap();
        assert_eq!(a.deck.slides()[0].body, "branch\r\nnext");
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn bounded_policy_history_stays_aligned() {
        let mut d = Presentation::new();
        d.edit_raw("one".into(), "a\r\nb".into()).unwrap();
        let p = std::env::temp_dir().join(format!("ppt42-limit-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&p);
        d.save_as(&p).unwrap();
        let mut a = Ppt::new(Presentation::open(&p).unwrap());
        for i in 0..15 {
            a.edit(format!("one\r\nvalue{i}")).unwrap();
        }
        for _ in 0..10 {
            a.action(4).unwrap();
        }
        assert!(!a.can_undo());
        a.edit("one\r\nlast\r\nline".into()).unwrap();
        assert_eq!(a.deck.slides()[0].body, "last\r\nline");
        assert!(!a.can_redo());
        std::fs::remove_file(p).unwrap();
    }
    #[test]
    fn boundary_commands_are_refused() {
        let mut a = Ppt::new(Presentation::new());
        for id in [11, 12, 13] {
            assert!(!a.enabled(id));
            assert!(a.action(id).is_err());
        }
        a.action(10).unwrap();
        assert!(a.enabled(12));
        assert!(!a.enabled(13));
        a.action(12).unwrap();
        assert!(!a.enabled(12));
        assert!(a.enabled(13));
    }
}
#[cfg(test)]
mod identity_regression {
    use super::*;
    use win42::App;
    #[test]
    fn identical_visible_slides_keep_identity_and_newlines_through_reorder_history_and_save() {
        let mut deck = Presentation::new();
        deck.edit_raw("same".into(), "a\r\nb".into()).unwrap();
        deck.add().unwrap();
        deck.edit_raw("same".into(), "a\nb".into()).unwrap();
        let crlf_id = deck.slides()[0].id;
        let lf_id = deck.slides()[1].id;
        let mut app = Ppt::new(deck);
        app.select(0);
        app.edit("same\r\none".into()).unwrap();
        app.select(1);
        app.edit("same\r\none".into()).unwrap();
        assert_eq!(app.deck.slides()[0].body, app.deck.slides()[1].body);
        app.select(0);
        app.action(13).unwrap();
        assert_eq!(app.deck.slides()[1].id, crlf_id);
        app.action(4).unwrap();
        assert_eq!(app.deck.slides()[0].id, crlf_id);
        app.action(5).unwrap();
        assert_eq!(app.deck.slides()[0].id, lf_id);
        let path = std::env::temp_dir().join(format!("ppt42-identity-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        app.save(&path).unwrap();
        let mut reopened = Ppt::new(Presentation::open(&path).unwrap());
        reopened.select(0);
        reopened.edit("same\r\none\r\nmore".into()).unwrap();
        reopened.select(1);
        reopened.edit("same\r\none\r\nmore".into()).unwrap();
        assert_eq!(
            (
                reopened.deck.slides()[0].id,
                reopened.deck.slides()[0].body.as_str()
            ),
            (lf_id, "one\nmore")
        );
        assert_eq!(
            (
                reopened.deck.slides()[1].id,
                reopened.deck.slides()[1].body.as_str()
            ),
            (crlf_id, "one\r\nmore")
        );
        reopened.action(4).unwrap();
        reopened.action(5).unwrap();
        reopened.action(4).unwrap();
        reopened.edit("same\r\nbranch\r\nend".into()).unwrap();
        assert!(!reopened.can_redo());
        assert_eq!(reopened.deck.slides()[1].body, "branch\r\nend");
        std::fs::remove_file(path).unwrap();
    }
}
