#![cfg_attr(windows, windows_subsystem = "windows")]
use std::path::Path;
use xls42_core::Workbook;
struct Xls {
    book: Workbook,
    row: usize,
    col: usize,
}
impl win42::App for Xls {
    fn name(&self) -> &'static str {
        "XLS42"
    }
    fn extension(&self) -> &'static str {
        "csv"
    }
    fn format_name(&self) -> &'static str {
        "CSV"
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[(10, "Add &Row"), (11, "Add &Column")]
    }
    fn items(&self) -> Vec<String> {
        vec![]
    }
    fn table(&self) -> Option<Vec<Vec<String>>> {
        Some(
            (0..self.book.rows())
                .map(|r| {
                    (0..self.book.cols())
                        .map(|c| self.book.cell(r, c).unwrap_or("").to_owned())
                        .collect()
                })
                .collect(),
        )
    }
    fn select_cell(&mut self, row: usize, col: usize) {
        self.row = row.min(self.book.rows() - 1);
        self.col = col.min(self.book.cols() - 1);
    }
    fn selected_cell(&self) -> Option<(usize, usize)> {
        Some((self.row, self.col))
    }
    fn text(&self) -> String {
        self.book
            .cell(self.row, self.col)
            .map(win42::to_native_text)
            .unwrap_or_default()
    }
    fn status(&self) -> String {
        format!(
            "CSV | {} rows × {} columns | selected R{} C{} | formulas are plain text",
            self.book.rows(),
            self.book.cols(),
            self.row + 1,
            self.col + 1
        )
    }
    fn selected(&self) -> usize {
        self.row * self.book.cols() + self.col
    }
    fn dirty(&self) -> bool {
        self.book.is_dirty()
    }
    fn can_undo(&self) -> bool {
        self.book.can_undo()
    }
    fn can_redo(&self) -> bool {
        self.book.can_redo()
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        let book = Workbook::open_csv(p).map_err(|e| e.to_string())?;
        for r in 0..book.rows() {
            for c in 0..book.cols() {
                win42::validate_editable(book.cell(r, c).unwrap_or(""))?;
            }
        }
        self.book = book;
        self.row = 0;
        self.col = 0;
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.book.save_as_csv(p).map_err(|e| e.to_string())
    }
    fn edit(&mut self, s: String) -> Result<(), String> {
        self.book
            .set_cell_editor_text(self.row, self.col, win42::from_native_text(&s))
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    fn select(&mut self, i: usize) {
        self.select_cell(i / self.book.cols(), i % self.book.cols())
    }
    fn enabled(&self, id: u16) -> bool {
        match id {
            10 => self.book.can_add_row(),
            11 => self.book.can_add_column(),
            _ => true,
        }
    }
    fn action(&mut self, id: u16) -> Result<(), String> {
        if id >= 10 && !self.enabled(id) {
            return Err("Command unavailable".into());
        }
        match id {
            4 => {
                self.book.undo();
            }
            5 => {
                self.book.redo();
            }
            10 => {
                self.book.add_row().map_err(|e| e.to_string())?;
            }
            11 => {
                self.book.add_column().map_err(|e| e.to_string())?;
            }
            _ => {}
        }
        self.row = self.row.min(self.book.rows() - 1);
        self.col = self.col.min(self.book.cols() - 1);
        Ok(())
    }
}
fn main() {
    win42::run(Box::new(Xls {
        book: Workbook::new(20, 8).unwrap(),
        row: 0,
        col: 0,
    }))
}
#[cfg(test)]
mod tests {
    use super::*;
    use win42::App;
    #[test]
    fn cell_editor_preserves_crlf() {
        let mut b = Workbook::new(1, 1).unwrap();
        b.set_cell(0, 0, "a\r\nb".into()).unwrap();
        let mut a = Xls {
            book: b,
            row: 0,
            col: 0,
        };
        assert_eq!(a.text(), "a\r\nb");
        a.edit("a".into()).unwrap();
        a.select_cell(0, 0);
        a.edit("a\r\nc".into()).unwrap();
        assert_eq!(a.book.cell(0, 0), Some("a\r\nc"));
    }
}
#[cfg(test)]
mod regression {
    use super::*;
    use win42::App;
    #[test]
    fn selection_survives_structure_and_history_and_saves_exact_destination() {
        let mut a = Xls {
            book: Workbook::new(2, 2).unwrap(),
            row: 0,
            col: 0,
        };
        a.select_cell(1, 1);
        a.action(11).unwrap();
        assert_eq!(a.selected_cell(), Some((1, 1)));
        a.edit("target".into()).unwrap();
        a.action(4).unwrap();
        assert_eq!(a.book.cell(1, 1), Some(""));
        a.action(5).unwrap();
        assert_eq!(a.book.cell(1, 1), Some("target"));
        a.action(10).unwrap();
        a.select_cell(2, 1);
        a.action(4).unwrap();
        assert_eq!(a.selected_cell(), Some((1, 1)));
        a.edit("final".into()).unwrap();
        let path = std::env::temp_dir().join(format!("xls42-selection-{}.csv", std::process::id()));
        let _ = std::fs::remove_file(&path);
        a.save(&path).unwrap();
        let b = Workbook::open_csv(&path).unwrap();
        assert_eq!((b.rows(), b.cols()), (2, 3));
        for r in 0..2 {
            for c in 0..3 {
                assert_eq!(
                    b.cell(r, c),
                    Some(if (r, c) == (1, 1) { "final" } else { "" })
                );
            }
        }
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn cell_style_survives_switch_and_no_newlines() {
        let mut b = Workbook::new(1, 2).unwrap();
        b.set_cell(0, 0, "a\r\nb".into()).unwrap();
        let mut a = Xls {
            book: b,
            row: 0,
            col: 0,
        };
        a.edit("a".into()).unwrap();
        a.select_cell(0, 1);
        a.edit("other".into()).unwrap();
        a.select_cell(0, 0);
        a.edit("a\r\nc".into()).unwrap();
        assert_eq!(a.book.cell(0, 0), Some("a\r\nc"));
        let path = std::env::temp_dir().join(format!("xls42-style-{}.csv", std::process::id()));
        let _ = std::fs::remove_file(&path);
        a.save(&path).unwrap();
        let b = Workbook::open_csv(&path).unwrap();
        assert_eq!(b.cell(0, 0), Some("a\r\nc"));
        assert_eq!(b.cell(0, 1), Some("other"));
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn limits_disable_and_refuse_additions() {
        let mut a = Xls {
            book: Workbook::new(1000, 100).unwrap(),
            row: 0,
            col: 0,
        };
        assert!(!a.enabled(10));
        assert!(!a.enabled(11));
        assert!(a.action(10).is_err());
        assert!(a.action(11).is_err());
        assert_eq!((a.book.rows(), a.book.cols()), (1000, 100));
    }
}
#[cfg(test)]
mod policy_regression {
    use super::*;
    use win42::App;
    #[test]
    fn rejection_undo_branch_and_context_preserve_cell_policy() {
        let mut b = Workbook::new(1, 2).unwrap();
        b.set_cell(0, 0, "a\r\nb".into()).unwrap();
        let mut a = Xls {
            book: b,
            row: 0,
            col: 0,
        };
        a.edit("single".into()).unwrap();
        assert!(a.edit("x".repeat(4 * 1024 * 1024 + 1)).is_err());
        a.action(4).unwrap();
        assert_eq!(a.book.cell(0, 0), Some("a\r\nb"));
        a.edit("branch".into()).unwrap();
        assert!(!a.can_redo());
        a.select_cell(0, 1);
        a.edit("other".into()).unwrap();
        a.select_cell(0, 0);
        a.edit("branch\r\nend".into()).unwrap();
        assert_eq!(a.book.cell(0, 0), Some("branch\r\nend"));
    }
}
