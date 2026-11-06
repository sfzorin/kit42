use std::path::Path;

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

#[derive(Clone)]
pub struct InputRequest {
    pub title: &'static str,
    pub fields: Vec<(&'static str, String)>,
}
#[derive(Clone, Copy)]
pub struct FileAction {
    pub id: u16,
    pub title: &'static str,
    pub save: bool,
    pub extension: &'static str,
    pub format: &'static str,
    pub pattern: &'static str,
}

/// Portable contract between a document model and the native Windows host.
pub trait App {
    fn name(&self) -> &'static str;
    fn extension(&self) -> &'static str;
    fn format_name(&self) -> &'static str;
    fn actions(&self) -> &'static [(u16, &'static str)];
    fn supports_new(&self) -> bool {
        false
    }
    fn new_document(&mut self) -> Result<(), String> {
        Err("New document unavailable".into())
    }
    fn file_actions(&self) -> &'static [FileAction] {
        &[]
    }
    fn file_action(&mut self, _id: u16, _path: &Path) -> Result<(), String> {
        Err("Unsupported file action".into())
    }
    fn input_request(&self, _id: u16) -> Option<InputRequest> {
        None
    }
    fn input_action(&mut self, _id: u16, _values: &[String]) -> Result<(), String> {
        Err("Unsupported input action".into())
    }
    fn supports_find_replace(&self) -> bool {
        false
    }
    fn find_next(
        &self,
        _query: &str,
        _start_utf16: usize,
    ) -> Result<Option<(usize, usize)>, String> {
        Err("Find unavailable".into())
    }
    fn replace_all(&mut self, _query: &str, _replacement: &str) -> Result<usize, String> {
        Err("Replace unavailable".into())
    }
    fn view_actions(&self) -> &'static [(u16, &'static str)] {
        &[]
    }
    fn items(&self) -> Vec<String>;
    fn text(&self) -> String;
    fn status(&self) -> String;
    fn dirty(&self) -> bool;
    fn can_undo(&self) -> bool;
    fn can_redo(&self) -> bool;
    fn open(&mut self, path: &Path) -> Result<(), String>;
    fn save(&mut self, path: &Path) -> Result<(), String>;
    fn edit(&mut self, text: String) -> Result<(), String>;
    fn select(&mut self, index: usize);
    fn action(&mut self, id: u16) -> Result<(), String>;
    fn open_filter(&self) -> String {
        format!("*.{}", self.extension())
    }
    fn open_is_add(&self) -> bool {
        false
    }
    fn selected(&self) -> usize {
        0
    }
    fn enabled(&self, _id: u16) -> bool {
        true
    }
    fn table(&self) -> Option<Vec<Vec<String>>> {
        None
    }
    fn select_cell(&mut self, _row: usize, _col: usize) {}
    fn selected_cell(&self) -> Option<(usize, usize)> {
        None
    }
    fn image_zoom(&self) -> Option<f64> {
        None
    }
    fn can_save(&self) -> bool {
        true
    }
    fn image(&self) -> Option<(u32, u32, Vec<u8>)> {
        None
    }
    fn list_visible(&self) -> bool {
        true
    }
    fn text_readonly(&self) -> bool {
        false
    }
}
#[cfg(windows)]
mod native;
#[cfg(windows)]
mod prompt;
#[cfg(windows)]
pub use native::run;
#[cfg(not(windows))]
pub fn run(app: Box<dyn App>) {
    eprintln!("{} requires Windows.", app.name());
}

/// Convert between a model string and the CRLF representation used by EDIT.
/// Mixed newlines, lone CR and NUL cannot be represented reversibly here.
pub fn validate_editable(text: &str) -> Result<(), String> {
    let canonical = text.replace("\r\n", "\n");
    if text.contains('\0')
        || canonical.contains('\r')
        || (text.contains("\r\n") && text.replace("\r\n", "").contains('\n'))
    {
        return Err("Text contains NUL, lone CR, or mixed newline styles that this editor cannot preserve. File was not opened.".into());
    }
    if canonical.encode_utf16().count() + canonical.matches('\n').count() > 16_777_216 {
        return Err("Text exceeds the native editor limit. File was not opened.".into());
    }
    Ok(())
}
pub fn to_native_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\n', "\r\n")
}
pub fn from_native_text(text: &str) -> String {
    text.replace("\r\n", "\n")
}
#[cfg(test)]
mod tests {
    #[test]
    fn native_text_round_trip_and_rejections() {
        for s in ["first\nsecond 😀", "first\r\nsecond 😀", "one line"] {
            assert!(super::validate_editable(s).is_ok());
            assert_eq!(
                super::from_native_text(&super::to_native_text(s)),
                s.replace("\r\n", "\n")
            );
        }
        assert!(super::validate_editable("a\0b").is_err());
        assert!(super::validate_editable("a\rb").is_err());
        assert!(super::validate_editable("a\r\nb\nc").is_err());
        assert!(super::validate_editable(&"x".repeat(16_777_217)).is_err());
    }
}

/// Native table operations needed to move between two rectangular presentations.
#[derive(Debug, PartialEq, Eq)]
pub enum GridTransition {
    Rebuild { selection: Option<(usize, usize)> },
    Update { cells: Vec<(usize, usize)> },
}
/// Compare presentations once, leaving unchanged native controls and view state intact.
pub fn grid_transition(
    old: Option<&[Vec<String>]>,
    new: &[Vec<String>],
    selection: Option<(usize, usize)>,
) -> GridTransition {
    let cols = new.first().map_or(0, Vec::len);
    let shape_matches = old.is_some_and(|rows| {
        rows.len() == new.len() && rows.iter().zip(new).all(|(a, b)| a.len() == b.len())
    });
    if !shape_matches {
        let selection = selection.and_then(|(row, col)| {
            if new.is_empty() || cols == 0 {
                None
            } else {
                Some((row.min(new.len() - 1), col.min(cols - 1)))
            }
        });
        return GridTransition::Rebuild { selection };
    }
    let old = old.unwrap();
    let cells = old
        .iter()
        .zip(new)
        .enumerate()
        .flat_map(|(r, (a, b))| {
            a.iter()
                .zip(b)
                .enumerate()
                .filter_map(move |(c, (x, y))| (x != y).then_some((r, c)))
        })
        .collect();
    GridTransition::Update { cells }
}
#[cfg(test)]
mod grid_tests {
    use super::*;
    #[test]
    fn selection_events_keep_the_model_authoritative() {
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(5), None, false),
            Some((5, 3))
        );
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(4), Some(1), false),
            Some((4, 1))
        );
        assert_eq!(grid_selection_event(Some((4, 3)), None, None, false), None);
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(4), None, false),
            None
        );
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(1), None, true),
            None
        );
    }
    #[test]
    fn sparse_changes_and_structure_selection() {
        let old = vec![vec![String::new(); 100]; 1000];
        let mut next = old.clone();
        next[0][0] = "1".into();
        next[999][99] = "2".into();
        assert_eq!(
            grid_transition(Some(&old), &next, Some((999, 99))),
            GridTransition::Update {
                cells: vec![(0, 0), (999, 99)]
            }
        );
        next.truncate(3);
        next.iter_mut().for_each(|r| r.truncate(2));
        assert_eq!(
            grid_transition(Some(&old), &next, Some((999, 99))),
            GridTransition::Rebuild {
                selection: Some((2, 1))
            }
        );
        assert_eq!(
            grid_transition(Some(&old), &[], Some((0, 0))),
            GridTransition::Rebuild { selection: None }
        );
    }
}

/// Resolve a selected native row or clicked cell against the current model selection.
/// Deselect-only and programmatic notifications are ignored.
pub fn grid_selection_event(
    current: Option<(usize, usize)>,
    row: Option<usize>,
    clicked_col: Option<usize>,
    programmatic: bool,
) -> Option<(usize, usize)> {
    if programmatic {
        return None;
    }
    let row = row?;
    let col = clicked_col.or_else(|| current.map(|(_, col)| col))?;
    let next = (row, col);
    (Some(next) != current).then_some(next)
}
