//! Rectangular UTF-8 CSV data; cells contain raw strings and formulas are not calculated.
use std::{
    fmt,
    fs::File,
    io::{self, Read},
    path::Path,
};
use suite42_core::{write_new, SnapshotHistory, TextValue};
const MAX_INPUT: usize = 4 * 1024 * 1024;
const MAX_ROWS: usize = 1000;
const MAX_COLS: usize = 100;
const MAX_TEXT: usize = 4 * 1024 * 1024;
#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Csv(csv::Error),
    Limit,
    Bounds,
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::Csv(e) => write!(f, "{e}"),
            Self::Limit => write!(f, "spreadsheet limit exceeded"),
            Self::Bounds => write!(f, "cell outside table"),
        }
    }
}
impl std::error::Error for Error {}
impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<csv::Error> for Error {
    fn from(e: csv::Error) -> Self {
        Self::Csv(e)
    }
}
#[derive(Clone, PartialEq)]
struct Grid {
    rows: usize,
    cols: usize,
    cells: Vec<TextValue>,
    bytes: usize,
}
pub struct Workbook {
    history: SnapshotHistory<Grid>,
}
impl Workbook {
    pub fn new(rows: usize, cols: usize) -> Result<Self, Error> {
        if rows == 0 || cols == 0 || rows > MAX_ROWS || cols > MAX_COLS {
            return Err(Error::Limit);
        };
        Ok(Self {
            history: SnapshotHistory::new(
                Grid {
                    rows,
                    cols,
                    cells: vec![TextValue::default(); rows * cols],
                    bytes: 0,
                },
                8,
            ),
        })
    }
    pub fn open_csv(path: &Path) -> Result<Self, Error> {
        let mut data = Vec::new();
        File::open(path)?
            .take((MAX_INPUT + 1) as u64)
            .read_to_end(&mut data)?;
        if data.len() > MAX_INPUT {
            return Err(Error::Limit);
        }
        let mut reader = csv::ReaderBuilder::new()
            .has_headers(false)
            .flexible(true)
            .from_reader(data.as_slice());
        let mut rows: Vec<Vec<String>> = Vec::new();
        let mut cols = 1;
        let mut bytes = 0usize;
        for rec in reader.records() {
            let rec = rec?;
            if rows.len() == MAX_ROWS || rec.len() > MAX_COLS {
                return Err(Error::Limit);
            };
            cols = cols.max(rec.len());
            let row: Vec<String> = rec.iter().map(str::to_owned).collect();
            bytes += row.iter().map(String::len).sum::<usize>();
            if bytes > MAX_TEXT {
                return Err(Error::Limit);
            }
            rows.push(row);
        }
        if rows.is_empty() {
            rows.push(Vec::new());
        }
        let count = rows.len();
        let mut cells = Vec::with_capacity(count * cols);
        for mut row in rows {
            row.resize(cols, String::new());
            cells.extend(row.into_iter().map(TextValue::from_raw));
        }
        Ok(Self {
            history: SnapshotHistory::new(
                Grid {
                    rows: count,
                    cols,
                    cells,
                    bytes,
                },
                8,
            ),
        })
    }
    pub fn rows(&self) -> usize {
        self.history.current().rows
    }
    pub fn cols(&self) -> usize {
        self.history.current().cols
    }
    pub fn cell(&self, row: usize, col: usize) -> Option<&str> {
        let g = self.history.current();
        if row >= g.rows || col >= g.cols {
            None
        } else {
            Some(g.cells[row * g.cols + col].raw())
        }
    }
    pub fn set_cell(&mut self, row: usize, col: usize, value: String) -> Result<bool, Error> {
        let mut g = self.history.current().clone();
        if row >= g.rows || col >= g.cols {
            return Err(Error::Bounds);
        }
        let i = row * g.cols + col;
        let bytes = g.bytes - g.cells[i].raw().len() + value.len();
        if bytes > MAX_TEXT {
            return Err(Error::Limit);
        }
        g.bytes = bytes;
        if g.cells[i].raw() == value {
            return Ok(false);
        }
        g.cells[i] = TextValue::from_raw(value);
        Ok(self.history.apply(g))
    }
    pub fn set_cell_editor_text(
        &mut self,
        row: usize,
        col: usize,
        text: String,
    ) -> Result<bool, Error> {
        let mut g = self.history.current().clone();
        if row >= g.rows || col >= g.cols {
            return Err(Error::Bounds);
        }
        let i = row * g.cols + col;
        let next = g.cells[i].with_edited(&text);
        let bytes = g.bytes - g.cells[i].raw().len() + next.raw().len();
        if bytes > MAX_TEXT {
            return Err(Error::Limit);
        }
        g.bytes = bytes;
        g.cells[i] = next;
        Ok(self.history.apply(g))
    }
    pub fn can_add_row(&self) -> bool {
        self.rows() < MAX_ROWS
    }
    pub fn can_add_column(&self) -> bool {
        self.cols() < MAX_COLS
    }
    pub fn add_row(&mut self) -> Result<(), Error> {
        if !self.can_add_row() {
            return Err(Error::Limit);
        }
        let mut g = self.history.current().clone();
        g.rows += 1;
        g.cells.resize(g.rows * g.cols, TextValue::default());
        self.history.apply(g);
        Ok(())
    }
    pub fn add_column(&mut self) -> Result<(), Error> {
        if !self.can_add_column() {
            return Err(Error::Limit);
        }
        let old = self.history.current();
        let mut cells = Vec::with_capacity(old.rows * (old.cols + 1));
        for row in old.cells.chunks_exact(old.cols) {
            cells.extend_from_slice(row);
            cells.push(TextValue::default());
        }
        let g = Grid {
            rows: old.rows,
            cols: old.cols + 1,
            cells,
            bytes: old.bytes,
        };
        self.history.apply(g);
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
    pub fn save_as_csv(&mut self, path: &Path) -> Result<(), Error> {
        let g = self.history.current();
        let mut writer = csv::WriterBuilder::new().from_writer(Vec::new());
        for row in g.cells.chunks_exact(g.cols) {
            writer.write_record(row.iter().map(TextValue::raw))?;
        }
        let bytes = writer.into_inner().map_err(|e| Error::Io(e.into_error()))?;
        if bytes.len() > MAX_INPUT {
            return Err(Error::Limit);
        }
        write_new(path, &bytes)?;
        self.history.mark_saved();
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn csv_edit_dimensions_history_roundtrip() {
        let dir = std::env::temp_dir().join(format!("xls42-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.csv");
        let out = dir.join("out.csv");
        let _ = std::fs::remove_file(&out);
        std::fs::write(&input, "a,\"b,b\"\n\"line\nnext\",\"say \"\"hi\"\"\"\n").unwrap();
        let mut w = Workbook::open_csv(&input).unwrap();
        assert_eq!(w.cell(1, 0), Some("line\nnext"));
        assert_eq!(w.cell(1, 1), Some("say \"hi\""));
        w.add_column().unwrap();
        w.add_row().unwrap();
        w.set_cell(2, 2, "=SUM(A1:A2)".into()).unwrap();
        w.save_as_csv(&out).unwrap();
        assert!(!w.is_dirty());
        let r = Workbook::open_csv(&out).unwrap();
        assert_eq!((r.rows(), r.cols()), (3, 3));
        assert_eq!(r.cell(2, 2), Some("=SUM(A1:A2)"));
        assert!(w.undo());
        assert!(w.is_dirty());
        assert!(w.redo());
        assert!(!w.is_dirty());
        assert!(w.save_as_csv(&out).is_err());
        assert_eq!(
            Workbook::open_csv(&out).unwrap().cell(2, 2),
            Some("=SUM(A1:A2)")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rectangular_limits_and_bounds() {
        assert!(Workbook::new(0, 1).is_err());
        assert!(Workbook::new(1001, 1).is_err());
        let mut w = Workbook::new(2, 2).unwrap();
        assert!(matches!(w.set_cell(2, 0, "x".into()), Err(Error::Bounds)));
        assert!(!w.is_dirty());
        assert!(!w.set_cell(0, 0, String::new()).unwrap());
    }
    #[test]
    fn capacity_actions_match_refusal_and_preserve_state() {
        let mut rows = Workbook::new(MAX_ROWS - 1, 1).unwrap();
        rows.set_cell(0, 0, "row".into()).unwrap();
        assert!(rows.can_add_row());
        rows.add_row().unwrap();
        assert!(!rows.can_add_row());
        assert!(matches!(rows.add_row(), Err(Error::Limit)));
        assert_eq!(rows.rows(), MAX_ROWS);
        assert_eq!(rows.cell(0, 0), Some("row"));
        assert!(rows.undo());
        assert!(rows.can_add_row());
        assert!(rows.redo());
        assert!(!rows.can_add_row());
        let mut cols = Workbook::new(1, MAX_COLS - 1).unwrap();
        cols.set_cell(0, 0, "column".into()).unwrap();
        assert!(cols.can_add_column());
        cols.add_column().unwrap();
        assert!(!cols.can_add_column());
        assert!(matches!(cols.add_column(), Err(Error::Limit)));
        assert_eq!(cols.cols(), MAX_COLS);
        assert_eq!(cols.cell(0, 0), Some("column"));
        assert!(cols.undo());
        assert!(cols.can_add_column());
        assert!(cols.redo());
        assert!(!cols.can_add_column());
    }
    #[test]
    fn cell_policy_is_part_of_structural_history_and_branch() {
        let mut w = Workbook::new(1, 2).unwrap();
        w.set_cell(0, 0, "a\r\nb".into()).unwrap();
        w.set_cell(0, 1, "a\nb".into()).unwrap();
        w.set_cell_editor_text(0, 0, "ab".into()).unwrap();
        w.set_cell_editor_text(0, 1, "ab".into()).unwrap();
        w.add_column().unwrap();
        w.set_cell_editor_text(0, 0, "a\nb".into()).unwrap();
        w.set_cell_editor_text(0, 1, "a\nb".into()).unwrap();
        assert_eq!(w.cell(0, 0), Some("a\r\nb"));
        assert_eq!(w.cell(0, 1), Some("a\nb"));
        assert!(w.undo());
        assert!(w.undo());
        assert!(w.undo());
        assert_eq!(w.cols(), 2);
        assert_eq!(w.cell(0, 0), Some("ab"));
        assert!(w.redo());
        assert_eq!(w.cols(), 3);
        assert!(matches!(
            w.set_cell_editor_text(0, 0, "x".repeat(MAX_TEXT + 1)),
            Err(Error::Limit)
        ));
        assert!(w.can_redo());
        assert_eq!(w.cell(0, 0), Some("ab"));
        assert!(!w.set_cell_editor_text(0, 0, "ab".into()).unwrap());
        assert!(w.can_redo());
        w.set_cell_editor_text(0, 0, "x\ny".into()).unwrap();
        assert_eq!(w.cell(0, 0), Some("x\r\ny"));
        assert!(!w.can_redo());
    }
}
