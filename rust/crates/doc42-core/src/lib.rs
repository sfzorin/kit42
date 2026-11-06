//! UTF-8 plain text documents only; no rich text or DOCX support.
use std::{
    fmt,
    fs::File,
    io::{self, Read},
    path::Path,
};
use suite42_core::{write_new, SnapshotHistory, TextValue};
const MAX_BYTES: usize = 4 * 1024 * 1024;
#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    TooLarge,
    InvalidUtf8,
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::TooLarge => write!(f, "text exceeds 4 MiB"),
            Self::InvalidUtf8 => write!(f, "not valid UTF-8"),
        }
    }
}
impl std::error::Error for Error {}
impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
pub struct Document {
    history: SnapshotHistory<TextValue>,
}
impl Default for Document {
    fn default() -> Self {
        Self::new()
    }
}
impl Document {
    pub fn new() -> Self {
        Self {
            history: SnapshotHistory::new(TextValue::default(), 16),
        }
    }
    pub fn open(path: &Path) -> Result<Self, Error> {
        let mut bytes = Vec::new();
        File::open(path)?
            .take((MAX_BYTES + 1) as u64)
            .read_to_end(&mut bytes)?;
        if bytes.len() > MAX_BYTES {
            return Err(Error::TooLarge);
        }
        let text = String::from_utf8(bytes).map_err(|_| Error::InvalidUtf8)?;
        Ok(Self {
            history: SnapshotHistory::new(TextValue::from_raw(text), 16),
        })
    }
    pub fn text(&self) -> &str {
        self.history.current().raw()
    }
    pub fn set_text(&mut self, text: String) -> Result<bool, Error> {
        if text.len() > MAX_BYTES {
            return Err(Error::TooLarge);
        }
        if self.text() == text {
            return Ok(false);
        }
        Ok(self.history.apply(TextValue::from_raw(text)))
    }
    pub fn set_editor_text(&mut self, text: String) -> Result<bool, Error> {
        let next = self.history.current().with_edited(&text);
        if next.raw().len() > MAX_BYTES {
            return Err(Error::TooLarge);
        }
        Ok(self.history.apply(next))
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
    pub fn save_as(&mut self, path: &Path) -> Result<(), Error> {
        write_new(path, self.text().as_bytes())?;
        self.history.mark_saved();
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn edit_save_reopen_undo() {
        let dir = tempdir();
        let p = dir.join("a.txt");
        let mut d = Document::new();
        d.set_text("Привет\nworld".into()).unwrap();
        d.save_as(&p).unwrap();
        assert!(!d.is_dirty());
        assert_eq!(Document::open(&p).unwrap().text(), "Привет\nworld");
        assert!(d.undo());
        assert!(d.is_dirty());
        assert!(d.redo());
        assert!(!d.is_dirty());
        assert!(d.save_as(&p).is_err());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "Привет\nworld");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn reject_invalid_and_large() {
        let dir = tempdir();
        let p = dir.join("x");
        std::fs::write(&p, [255]).unwrap();
        assert!(matches!(Document::open(&p), Err(Error::InvalidUtf8)));
        let mut d = Document::new();
        assert!(matches!(
            d.set_text("x".repeat(MAX_BYTES + 1)),
            Err(Error::TooLarge)
        ));
        assert_eq!(d.text(), "");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn editor_policy_follows_history_and_branch() {
        let dir = tempdir();
        let path = dir.join("policy.txt");
        std::fs::write(&path, "a\r\nb").unwrap();
        let mut d = Document::open(&path).unwrap();
        assert!(d.set_editor_text("ab".into()).unwrap());
        assert!(!d.set_editor_text("ab".into()).unwrap());
        assert!(d.set_editor_text("a\nb".into()).unwrap());
        assert_eq!(d.text(), "a\r\nb");
        assert!(!d.is_dirty());
        assert!(d.undo());
        assert_eq!(d.text(), "ab");
        assert!(d.undo());
        assert_eq!(d.text(), "a\r\nb");
        assert!(d.redo());
        assert!(matches!(
            d.set_editor_text("x".repeat(MAX_BYTES + 1)),
            Err(Error::TooLarge)
        ));
        assert_eq!(d.text(), "ab");
        assert!(d.can_redo());
        d.set_editor_text("x\ny".into()).unwrap();
        assert_eq!(d.text(), "x\r\ny");
        assert!(!d.can_redo());
        std::fs::remove_dir_all(dir).unwrap();
    }
    fn tempdir() -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!(
            "doc42-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
