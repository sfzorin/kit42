//! Sheet filter and page layout state; rendering belongs to the host.
use super::*;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SheetFilter {
    pub range: Range,
    pub column: usize,
    pub contains: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PrintSettings {
    pub area: Option<Range>,
    pub paper_width_twips: i32,
    pub paper_height_twips: i32,
    pub margin_left_twips: i32,
    pub margin_top_twips: i32,
    pub margin_right_twips: i32,
    pub margin_bottom_twips: i32,
    pub repeat_header_rows: usize,
    pub fit_width: bool,
    pub row_breaks: Vec<usize>,
}
impl Default for PrintSettings {
    fn default() -> Self {
        Self {
            area: None,
            paper_width_twips: 11906,
            paper_height_twips: 16838,
            margin_left_twips: 720,
            margin_top_twips: 720,
            margin_right_twips: 720,
            margin_bottom_twips: 720,
            repeat_header_rows: 0,
            fit_width: false,
            row_breaks: Vec::new(),
        }
    }
}
pub(super) fn valid_filter(f: &SheetFilter, s: &Sheet) -> bool {
    f.range.valid(s)
        && f.range.top < f.range.bottom
        && f.column >= f.range.left
        && f.column <= f.range.right
        && !f.contains.is_empty()
        && f.contains.len() <= 4096
        && !s.merges.iter().any(|m| m.overlaps(f.range))
}
pub(super) fn valid_print(p: &PrintSettings, s: &Sheet) -> bool {
    p.area.is_none_or(|r| r.valid(s))
        && p.paper_width_twips > 0
        && p.paper_height_twips > 0
        && p.paper_width_twips <= 100_000
        && p.paper_height_twips <= 100_000
        && [
            p.margin_left_twips,
            p.margin_top_twips,
            p.margin_right_twips,
            p.margin_bottom_twips,
        ]
        .iter()
        .all(|v| *v >= 0)
        && i64::from(p.margin_left_twips) + i64::from(p.margin_right_twips)
            < i64::from(p.paper_width_twips)
        && i64::from(p.margin_top_twips) + i64::from(p.margin_bottom_twips)
            < i64::from(p.paper_height_twips)
        && p.repeat_header_rows <= p.area.map_or(s.rows, |r| r.bottom - r.top + 1)
        && p.row_breaks.len() <= s.rows
        && p.row_breaks.iter().all(|r| *r > 0 && *r < s.rows)
        && p.row_breaks.windows(2).all(|v| v[0] < v[1])
}
impl Workbook {
    pub fn sheet_filter(&self) -> Option<&SheetFilter> {
        self.history.current().sheet().filter.as_ref()
    }
    pub fn set_filter(&mut self, filter: Option<SheetFilter>) -> Result<bool, Error> {
        self.require_structural_edit()?;
        let mut st = self.history.current().clone();
        let sheet = st.sheet_mut();
        if sheet.protected {
            return Err(Error::Protected);
        }
        if filter.as_ref().is_some_and(|v| {
            !valid_filter(v, sheet) || sheet.merges.iter().any(|m| m.overlaps(v.range))
        }) {
            return Err(Error::Invalid("invalid filter"));
        }
        sheet.filter = filter;
        Ok(self.history.apply(st))
    }
    pub fn visible_rows(&self) -> Vec<usize> {
        let grid = self.display_grid();
        self.visible_rows_from_grid(&grid)
    }
    pub fn visible_rows_from_grid(&self, grid: &[Vec<String>]) -> Vec<usize> {
        let s = self.history.current().sheet();
        let Some(f) = &s.filter else {
            return (0..s.rows).collect();
        };
        let needle = f.contains.to_lowercase();
        (0..s.rows)
            .filter(|r| {
                *r <= f.range.top
                    || *r > f.range.bottom
                    || grid
                        .get(*r)
                        .and_then(|row| row.get(f.column))
                        .is_some_and(|value| value.to_lowercase().contains(&needle))
            })
            .collect()
    }
    pub fn print_settings(&self) -> &PrintSettings {
        &self.history.current().sheet().print
    }
    pub fn set_print_settings(&mut self, settings: PrintSettings) -> Result<bool, Error> {
        self.require_structural_edit()?;
        let mut st = self.history.current().clone();
        if !valid_print(&settings, st.sheet()) {
            return Err(Error::Invalid("invalid print settings"));
        }
        st.sheet_mut().print = settings;
        Ok(self.history.apply(st))
    }
    pub fn print_area(&self) -> Range {
        let s = self.history.current().sheet();
        if let Some(area) = s.print.area {
            return area;
        }
        let mut bottom = 0;
        let mut right = 0;
        for (&(r, c), cell) in &s.cells {
            if !cell.text.raw().is_empty() || cell.style != 0 {
                bottom = bottom.max(r);
                right = right.max(c)
            }
        }
        for m in &s.merges {
            bottom = bottom.max(m.bottom);
            right = right.max(m.right)
        }
        Range {
            top: 0,
            left: 0,
            bottom,
            right,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn filter_and_page_settings_project_and_xlsx() {
        let mut b = Workbook::new(6, 2).unwrap();
        for (r, value) in ["Header", "Apple", "Pear", "Apricot", "Plum", "More"]
            .iter()
            .enumerate()
        {
            b.set_cell(r, 0, (*value).into()).unwrap();
        }
        let filter = SheetFilter {
            range: Range {
                top: 0,
                left: 0,
                bottom: 4,
                right: 0,
            },
            column: 0,
            contains: "ap".into(),
        };
        b.set_filter(Some(filter.clone())).unwrap();
        assert_eq!(b.visible_rows(), [0, 1, 3, 5]);
        let mut p = b.print_settings().clone();
        p.area = Some(Range {
            top: 0,
            left: 0,
            bottom: 5,
            right: 1,
        });
        p.repeat_header_rows = 1;
        p.fit_width = true;
        p.row_breaks = vec![3];
        b.set_print_settings(p.clone()).unwrap();
        let bytes = b.xlsx_bytes().unwrap();
        let mut z = zip::ZipArchive::new(std::io::Cursor::new(bytes.as_slice())).unwrap();
        let mut sheet = String::new();
        z.by_name("xl/worksheets/sheet1.xml")
            .unwrap()
            .read_to_string(&mut sheet)
            .unwrap();
        assert!(sheet.contains("autoFilter"));
        assert!(sheet.contains("rowBreaks"));
        let restored = Workbook::from_office_bytes(&bytes, "xlsx").unwrap();
        assert_eq!(restored.sheet_filter(), Some(&filter));
        assert_eq!(restored.print_settings(), &p);
        assert_eq!(restored.visible_rows(), [0, 1, 3, 5]);
    }
}
