//! Small native slide-deck model; this is not PPTX compatibility.
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, fs, io::Read, path::Path};
use suite42_core::{write_new, SnapshotHistory, TextValue};
const MAX_SLIDES: usize = 200;
const MAX_TEXT: usize = 32_768;
const MAX_FILE: u64 = 512 * 1024;
const HISTORY_LIMIT: usize = 10;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Slide {
    pub id: u64,
    #[serde(skip)]
    pub title: String,
    #[serde(skip)]
    pub body: String,
    title_text: TextValue,
    body_text: TextValue,
}
impl Slide {
    fn new(id: u64, title: String, body: String) -> Self {
        Self {
            id,
            title_text: TextValue::from_raw(title.clone()),
            body_text: TextValue::from_raw(body.clone()),
            title,
            body,
        }
    }
    fn edited(&self, title: &str, body: &str) -> Self {
        let title_text = self.title_text.with_edited(title);
        let body_text = self.body_text.with_edited(body);
        Self {
            id: self.id,
            title: title_text.raw().to_owned(),
            body: body_text.raw().to_owned(),
            title_text,
            body_text,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Deck {
    version: u32,
    next_id: u64,
    pub slides: Vec<Slide>,
}
impl Deck {
    fn valid(&self) -> bool {
        let mut ids = HashSet::new();
        self.version == 2
            && self.next_id > 0
            && !self.slides.is_empty()
            && self.slides.len() <= MAX_SLIDES
            && self.slides.iter().all(|s| {
                s.id > 0
                    && s.id < self.next_id
                    && ids.insert(s.id)
                    && s.title.len() <= MAX_TEXT
                    && s.body.len() <= MAX_TEXT
                    && s.title_text.policy_consistent()
                    && s.body_text.policy_consistent()
                    && s.title_text.raw() == s.title
                    && s.body_text.raw() == s.body
            })
            && serde_json::to_vec(self).is_ok_and(|bytes| bytes.len() as u64 <= MAX_FILE)
    }
}
#[derive(Clone)]
struct State {
    deck: Deck,
    selected: u64,
}
// Selection is captured for undo/redo, but does not make a saved deck dirty.
impl PartialEq for State {
    fn eq(&self, other: &Self) -> bool {
        self.deck == other.deck
    }
}
pub struct Presentation {
    history: SnapshotHistory<State>,
}
impl Default for Presentation {
    fn default() -> Self {
        Self::new()
    }
}
impl Presentation {
    pub fn new() -> Self {
        Self {
            history: SnapshotHistory::new(
                State {
                    deck: Deck {
                        version: 2,
                        next_id: 2,
                        slides: vec![Slide::new(1, String::new(), String::new())],
                    },
                    selected: 1,
                },
                HISTORY_LIMIT,
            ),
        }
    }
    pub fn slides(&self) -> &[Slide] {
        &self.history.current().deck.slides
    }
    pub fn current(&self) -> usize {
        self.slides()
            .iter()
            .position(|s| s.id == self.history.current().selected)
            .expect("valid selection")
    }
    pub fn select(&mut self, index: usize) -> Result<(), String> {
        let id = self
            .slides()
            .get(index)
            .ok_or("slide index out of range")?
            .id;
        let mut state = self.history.current().clone();
        state.selected = id;
        self.history.replace_current(state);
        Ok(())
    }
    pub fn edit(&mut self, title: String, body: String) -> Result<(), String> {
        let mut state = self.history.current().clone();
        let index = self.current();
        state.deck.slides[index] = state.deck.slides[index].edited(&title, &body);
        if !state.deck.valid() {
            return Err("invalid slide text or deck exceeds size limit".into());
        }
        self.history.apply(state);
        Ok(())
    }
    /// Import raw text and establish line-ending policy for the selected slide.
    pub fn edit_raw(&mut self, title: String, body: String) -> Result<(), String> {
        let mut state = self.history.current().clone();
        let index = self.current();
        let id = state.deck.slides[index].id;
        state.deck.slides[index] = Slide::new(id, title, body);
        if !state.deck.valid() {
            return Err("invalid slide text or deck exceeds size limit".into());
        }
        self.history.apply(state);
        Ok(())
    }
    fn deck_with_new_slide(&self) -> Result<State, String> {
        if self.slides().len() >= MAX_SLIDES {
            return Err("slide limit exceeded".into());
        }
        let mut state = self.history.current().clone();
        let id = state.deck.next_id;
        state.deck.next_id = id.checked_add(1).ok_or("slide identity exhausted")?;
        state.deck.slides.insert(
            self.current() + 1,
            Slide::new(id, String::new(), String::new()),
        );
        state.selected = id;
        if !state.deck.valid() {
            return Err("deck exceeds size limit".into());
        }
        Ok(state)
    }
    pub fn can_add(&self) -> bool {
        self.deck_with_new_slide().is_ok()
    }
    pub fn add(&mut self) -> Result<(), String> {
        let state = self.deck_with_new_slide()?;
        self.history.apply(state);
        Ok(())
    }
    fn deck_with_duplicate(&self) -> Result<State, String> {
        if self.slides().len() >= MAX_SLIDES {
            return Err("slide limit exceeded".into());
        }
        let mut state = self.history.current().clone();
        let id = state.deck.next_id;
        state.deck.next_id = id.checked_add(1).ok_or("slide identity exhausted")?;
        let mut slide = state.deck.slides[self.current()].clone();
        slide.id = id;
        state.deck.slides.insert(self.current() + 1, slide);
        state.selected = id;
        if !state.deck.valid() {
            return Err("deck exceeds size limit".into());
        }
        Ok(state)
    }
    pub fn can_duplicate(&self) -> bool {
        self.deck_with_duplicate().is_ok()
    }
    pub fn duplicate(&mut self) -> Result<(), String> {
        let state = self.deck_with_duplicate()?;
        self.history.apply(state);
        Ok(())
    }
    pub fn delete(&mut self) -> Result<(), String> {
        if self.slides().len() == 1 {
            return Err("cannot delete last slide".into());
        }
        let mut state = self.history.current().clone();
        let i = self.current();
        state.deck.slides.remove(i);
        state.selected = state.deck.slides[i.min(state.deck.slides.len() - 1)].id;
        self.history.apply(state);
        Ok(())
    }
    pub fn move_slide(&mut self, from: usize, to: usize) -> Result<(), String> {
        let mut state = self.history.current().clone();
        if from >= state.deck.slides.len() || to >= state.deck.slides.len() {
            return Err("slide index out of range".into());
        }
        let slide = state.deck.slides.remove(from);
        state.selected = slide.id;
        state.deck.slides.insert(to, slide);
        self.history.apply(state);
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
    pub fn save_as(&mut self, path: &Path) -> Result<(), String> {
        let bytes = serde_json::to_vec(&self.history.current().deck).map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_FILE {
            return Err("deck exceeds file limit".into());
        }
        write_new(path, &bytes).map_err(|e| e.to_string())?;
        self.history.mark_saved();
        Ok(())
    }
    pub fn open(path: &Path) -> Result<Self, String> {
        if fs::metadata(path).map_err(|e| e.to_string())?.len() > MAX_FILE {
            return Err("deck exceeds file limit".into());
        }
        let mut bytes = Vec::new();
        fs::File::open(path)
            .map_err(|e| e.to_string())?
            .take(MAX_FILE + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_FILE {
            return Err("deck exceeds file limit".into());
        }
        let mut deck: Deck = serde_json::from_slice(&bytes)
            .map_err(|e| format!("invalid or unsupported version 2 deck: {e}"))?;
        for slide in &mut deck.slides {
            slide.title = slide.title_text.raw().to_owned();
            slide.body = slide.body_text.raw().to_owned();
        }
        if !deck.valid() {
            return Err("unsupported version or invalid deck".into());
        }
        let selected = deck.slides[0].id;
        Ok(Self {
            history: SnapshotHistory::new(State { deck, selected }, HISTORY_LIMIT),
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_preserves_identity_policy_history_and_reopen() {
        let mut p = Presentation::new();
        p.edit_raw("same".into(), "a\r\nb".into()).unwrap();
        let original = p.slides()[0].id;
        p.duplicate().unwrap();
        let copied = p.slides()[1].id;
        assert_ne!(original, copied);
        assert_eq!(p.current(), 1);
        assert_eq!(p.slides()[1].body, "a\r\nb");
        assert!(p.undo());
        assert_eq!(p.current(), 0);
        assert!(p.redo());
        assert_eq!(p.current(), 1);
        let path =
            std::env::temp_dir().join(format!("ppt42-duplicate-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        p.save_as(&path).unwrap();
        let mut q = Presentation::open(&path).unwrap();
        q.select(1).unwrap();
        q.edit("same".into(), "a\nb\nc".into()).unwrap();
        assert_eq!(q.slides()[1].body, "a\r\nb\r\nc");
        assert_eq!(q.slides()[1].id, copied);
        assert!(p.undo());
        p.edit("branch".into(), "".into()).unwrap();
        assert!(!p.can_redo());
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn duplicate_refuses_size_budget_without_mutation() {
        let mut p = Presentation::new();
        p.edit_raw("".into(), "\u{1}".repeat(MAX_TEXT)).unwrap();
        while p.can_duplicate() {
            p.duplicate().unwrap();
        }
        let n = p.slides().len();
        let selected = p.current();
        let undo = p.can_undo();
        assert!(p.duplicate().is_err());
        assert_eq!(p.slides().len(), n);
        assert_eq!(p.current(), selected);
        assert_eq!(p.can_undo(), undo);
    }
    #[test]
    fn escaped_budget_rejection_preserves_state_and_history() {
        let mut p = Presentation::new();
        let payload = "\u{0001}".repeat(MAX_TEXT);
        for _ in 0..1 {
            p.edit(payload.clone(), payload.clone()).unwrap();
            p.add().unwrap();
        }
        let before = p.slides().to_vec();
        let current = p.current();
        let undo = p.can_undo();
        let redo = p.can_redo();
        assert!(p.edit(payload.clone(), payload).is_err());
        assert_eq!(p.slides(), before);
        assert_eq!(p.current(), current);
        assert_eq!(p.can_undo(), undo);
        assert_eq!(p.can_redo(), redo);
        let path = std::env::temp_dir().join(format!("ppt42-budget-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        p.save_as(&path).unwrap();
        assert_eq!(Presentation::open(&path).unwrap().slides(), p.slides());
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn add_capability_tracks_limits_and_undo() {
        let mut p = Presentation::new();
        for _ in 1..MAX_SLIDES {
            assert!(p.can_add());
            p.add().unwrap();
        }
        assert!(!p.can_add());
        assert!(p.add().is_err());
        assert!(p.undo());
        assert!(p.can_add());
        assert!(p.add().is_ok());
        let mut p = Presentation::new();
        let data = "\u{0001}".repeat(MAX_TEXT);
        p.edit(data.clone(), data.clone()).unwrap();
        p.add().unwrap();
        let title = data[..21000].to_string();
        p.edit(title.clone(), String::new()).unwrap();
        let used = serde_json::to_vec(&p.history.current().deck).unwrap().len();
        let body = "a".repeat(MAX_FILE as usize - used - 5);
        p.edit(title, body).unwrap();
        assert!(!p.can_add());
        assert!(p.add().is_err());
        assert!(p.undo());
        assert!(p.can_add());
    }
    #[test]
    fn identical_slides_keep_identity_and_newline_policy_through_history() {
        let mut p = Presentation::new();
        p.edit_raw("first\r\nline".into(), "body\r\nline".into())
            .unwrap();
        let crlf = p.slides()[0].id;
        p.add().unwrap();
        p.edit_raw("second\nline".into(), "body\nline".into())
            .unwrap();
        let lf = p.slides()[1].id;
        p.select(0).unwrap();
        p.edit("same".into(), "same".into()).unwrap();
        p.select(1).unwrap();
        p.edit("same".into(), "same".into()).unwrap();
        p.move_slide(0, 1).unwrap();
        assert_eq!(p.slides()[1].id, crlf);
        assert_eq!(p.slides()[0].id, lf);
        assert_eq!(p.current(), 1);
        p.edit("title\nnext".into(), "body\nnext".into()).unwrap();
        assert_eq!(p.slides()[1].title, "title\r\nnext");
        p.select(0).unwrap();
        p.edit("title\nnext".into(), "body\nnext".into()).unwrap();
        assert_eq!(p.slides()[0].title, "title\nnext");
        assert!(p.undo());
        assert_eq!(p.current(), 0);
        assert_eq!(p.slides()[0].title, "same");
        assert!(p.redo());
        assert_eq!(p.slides()[0].title, "title\nnext");
        let path = std::env::temp_dir().join(format!("ppt42-identity-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        p.save_as(&path).unwrap();
        let mut reopened = Presentation::open(&path).unwrap();
        assert_eq!(reopened.slides(), p.slides());
        reopened.select(1).unwrap();
        reopened
            .edit("again\nline".into(), "again\nline".into())
            .unwrap();
        assert_eq!(reopened.slides()[1].title, "again\r\nline");
        assert!(p.undo());
        p.edit("branch\nline".into(), "branch\nline".into())
            .unwrap();
        assert!(!p.can_redo());
        assert_eq!(p.slides()[0].id, lf);
        assert_eq!(p.slides()[0].title, "branch\nline");
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn rejects_unknown_text_fields_and_contradictory_policy_on_open() {
        let dir = std::env::temp_dir().join(format!("ppt42-schema-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("deck.json");
        let mut p = Presentation::new();
        p.edit_raw("title\r\nline".into(), "body\nline".into())
            .unwrap();
        let valid = serde_json::to_value(&p.history.current().deck).unwrap();
        for (field, unknown) in [
            ("title_text", true),
            ("body_text", true),
            ("title_text", false),
            ("body_text", false),
        ] {
            let mut value = valid.clone();
            let text = &mut value["slides"][0][field];
            if unknown {
                text["future"] = serde_json::json!(42);
            } else {
                text["crlf"] = serde_json::json!(field == "body_text");
            }
            let bytes = serde_json::to_vec(&value).unwrap();
            fs::write(&path, &bytes).unwrap();
            assert!(Presentation::open(&path).is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
        // Either retained policy is valid when no newline remains.
        let mut value = valid;
        value["slides"][0]["title_text"]["raw"] = serde_json::json!("no newline");
        for flag in [true, false] {
            value["slides"][0]["title_text"]["crlf"] = serde_json::json!(flag);
            fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(Presentation::open(&path).is_ok());
        }
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn invalid_ids_and_exhaustion_are_rejected() {
        let mut p = Presentation::new();
        p.add().unwrap();
        let mut state = p.history.current().clone();
        state.deck.slides[1].id = state.deck.slides[0].id;
        assert!(!state.deck.valid());
        state = p.history.current().clone();
        state.deck.next_id = u64::MAX;
        assert!(state.deck.valid());
        p.history.replace_current(state);
        assert!(!p.can_add());
        assert!(p.add().is_err());
    }
    #[test]
    fn state_and_roundtrip() {
        let mut p = Presentation::new();
        p.edit("First".into(), "text".into()).unwrap();
        p.add().unwrap();
        p.edit("Second".into(), "body".into()).unwrap();
        p.move_slide(1, 0).unwrap();
        assert_eq!(p.slides()[0].title, "Second");
        assert!(p.undo());
        assert_eq!(p.slides()[0].title, "First");
        assert!(p.redo());
        let path = std::env::temp_dir().join(format!("ppt42-test-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        p.save_as(&path).unwrap();
        assert!(!p.is_dirty());
        let r = Presentation::open(&path).unwrap();
        assert_eq!(r.slides(), p.slides());
        assert!(p.save_as(&path).is_err());
        fs::remove_file(path).unwrap();
        assert!(p.delete().is_ok());
        assert!(p.delete().is_err());
    }
}
