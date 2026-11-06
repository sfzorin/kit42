use std::path::Path;

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Portable contract between a document model and the native Windows host.
pub trait App {
    fn name(&self) -> &'static str;
    fn extension(&self) -> &'static str;
    fn format_name(&self) -> &'static str;
    fn actions(&self) -> &'static [(u16, &'static str)];
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
