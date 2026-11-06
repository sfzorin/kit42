//! Rectangular UTF-8 CSV data with raw cells and bounded formula evaluation.
mod formula;
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
    /// Compute the visible grid once, retaining raw values for editing and CSV.
    pub fn display_grid(&self) -> Vec<Vec<String>> {
        formula::display_grid(self)
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

#[cfg(test)]
mod formula_regression {
    use super::*;
    #[test]
    fn formulas_recalculate_history_and_csv_preserves_raw() {
        let mut b = Workbook::new(2, 3).unwrap();
        b.set_cell(0, 0, "2".into()).unwrap();
        b.set_cell(1, 0, "3".into()).unwrap();
        b.set_cell(0, 1, "=SUM(A1:A2)*2".into()).unwrap();
        b.set_cell(1, 1, "=AVERAGE(A1:A2)+MIN(A1:A2)+MAX(A1:A2)".into())
            .unwrap();
        b.set_cell(0, 2, "=-(B1+1)/2".into()).unwrap();
        assert_eq!(b.display_grid()[0], ["2", "10", "-5.5"]);
        assert_eq!(b.display_grid()[1][1], "7.5");
        b.set_cell(0, 0, "4".into()).unwrap();
        assert_eq!(b.display_grid()[0][1], "14");
        b.undo();
        assert_eq!(b.display_grid()[0][1], "10");
        b.redo();
        assert_eq!(b.display_grid()[0][1], "14");
        let path = std::env::temp_dir().join(format!("xls42-formula-{}.csv", std::process::id()));
        let _ = std::fs::remove_file(&path);
        b.save_as_csv(&path).unwrap();
        let reopened = Workbook::open_csv(&path).unwrap();
        assert_eq!(reopened.cell(0, 1), Some("=SUM(A1:A2)*2"));
        assert_eq!(reopened.display_grid()[0][1], "14");
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn errors_cycles_recover_and_limits_are_bounded() {
        let mut b = Workbook::new(2, 4).unwrap();
        for (c, value) in ["=B1", "=A1", "=1/0", "=Z99"].iter().enumerate() {
            b.set_cell(0, c, (*value).into()).unwrap();
        }
        assert_eq!(
            b.display_grid()[0],
            ["#CYCLE!", "#CYCLE!", "#DIV/0!", "#REF!"]
        );
        b.set_cell(0, 1, "5".into()).unwrap();
        assert_eq!(b.display_grid()[0][0], "5");
        b.set_cell(1, 0, "=1+".into()).unwrap();
        b.set_cell(1, 1, format!("={}1", "-".repeat(200))).unwrap();
        b.set_cell(1, 2, "text".into()).unwrap();
        b.set_cell(1, 3, "=C2+1".into()).unwrap();
        assert_eq!(
            b.display_grid()[1],
            ["#ERROR!", "#LIMIT!", "text", "#VALUE!"]
        );
    }
}

#[cfg(test)]
mod aggregate_range_regression {
    use super::*;
    #[test]
    fn mixed_empty_and_formula_error_ranges() {
        let mut b = Workbook::new(5, 5).unwrap();
        // A1:A5 contains a real zero, two numbers, plain text and a blank.
        for (r, value) in ["0", "6", "text", "", "-2"].iter().enumerate() {
            b.set_cell(r, 0, (*value).into()).unwrap();
        }
        for (r, f) in ["SUM", "AVERAGE", "MIN", "MAX"].iter().enumerate() {
            b.set_cell(r, 1, format!("={f}(A1:A5)")).unwrap();
            b.set_cell(r, 2, format!("={f}(D1:D2)")).unwrap();
            b.set_cell(r, 4, format!("={f}(D3:D4)")).unwrap();
        }
        b.set_cell(0, 3, "text".into()).unwrap();
        b.set_cell(2, 3, "=1/0".into()).unwrap();
        let grid = b.display_grid();
        assert_eq!(
            (0..4).map(|r| grid[r][1].as_str()).collect::<Vec<_>>(),
            ["4", "1.3333333333333333", "-2", "6"]
        );
        assert_eq!(
            (0..4).map(|r| grid[r][2].as_str()).collect::<Vec<_>>(),
            ["0", "#DIV/0!", "0", "0"]
        );
        assert_eq!(
            (0..4).map(|r| grid[r][4].as_str()).collect::<Vec<_>>(),
            ["#DIV/0!"; 4]
        );
        b.set_cell(2, 3, "=2-2".into()).unwrap();
        assert_eq!(b.display_grid()[1][4], "0");
    }
}
