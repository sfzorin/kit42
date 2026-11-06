//! XLSX export and conservative re-opening of unchanged XLS42-produced packages.
use super::*;
use rust_xlsxwriter::{Color, Format, FormatBorder, FormatUnderline, Formula, Workbook as Xlsx};
use sha2::{Digest, Sha256};
use std::io::{Cursor, Read, Write};
const EXTRA: &str = "xls42/project.json";
const LIMIT: usize = 64 * 1024 * 1024;
fn format(s: &CellStyle) -> Format {
    let mut f = Format::new();
    if s.bold {
        f = f.set_bold()
    }
    if s.italic {
        f = f.set_italic()
    }
    if s.underline {
        f = f.set_underline(FormatUnderline::Single)
    }
    if !s.font.is_empty() {
        f = f.set_font_name(&s.font)
    }
    if s.font_size > 0 {
        f = f.set_font_size(s.font_size)
    }
    if let Some(c) = s.foreground {
        f = f.set_font_color(Color::RGB(c & 0xffffff))
    }
    if let Some(c) = s.background {
        f = f.set_background_color(Color::RGB(c & 0xffffff))
    }
    if !s.number_format.is_empty() {
        f = f.set_num_format(&s.number_format)
    }
    if s.borders & 1 != 0 {
        f = f.set_border_top(FormatBorder::Thin)
    }
    if s.borders & 2 != 0 {
        f = f.set_border_right(FormatBorder::Thin)
    }
    if s.borders & 4 != 0 {
        f = f.set_border_bottom(FormatBorder::Thin)
    }
    if s.borders & 8 != 0 {
        f = f.set_border_left(FormatBorder::Thin)
    }
    f
}
fn digest(archive: &mut zip::ZipArchive<Cursor<&[u8]>>) -> Result<[u8; 32], Error> {
    let mut hash = Sha256::new();
    let mut total = 0usize;
    let mut names = std::collections::HashSet::new();
    for i in 0..archive.len() {
        let mut file = archive
            .by_index(i)
            .map_err(|_| Error::Invalid("invalid Office archive"))?;
        let name = file.name().to_string();
        if !names.insert(name.clone()) {
            return Err(Error::Invalid("duplicate Office part"));
        }
        if name == EXTRA {
            continue;
        }
        total = total
            .checked_add(file.size() as usize)
            .ok_or(Error::Limit)?;
        if total > LIMIT {
            return Err(Error::Limit);
        }
        hash.update((name.len() as u64).to_le_bytes());
        hash.update(name.as_bytes());
        hash.update(file.size().to_le_bytes());
        let mut buf = [0; 8192];
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hash.update(&buf[..n]);
        }
    }
    Ok(hash.finalize().into())
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Embedded {
    format: String,
    digest: [u8; 32],
    project: Vec<u8>,
}
fn embed(bytes: Vec<u8>, format: &str, project: Vec<u8>) -> Result<Vec<u8>, Error> {
    if bytes.len() > LIMIT {
        return Err(Error::Limit);
    }
    let sum = digest(
        &mut zip::ZipArchive::new(Cursor::new(bytes.as_slice()))
            .map_err(|_| Error::Invalid("invalid Office archive"))?,
    )?;
    let payload = serde_json::to_vec(&Embedded {
        format: format.into(),
        digest: sum,
        project,
    })
    .map_err(|_| Error::Invalid("cannot encode project"))?;
    let mut writer = zip::ZipWriter::new_append(Cursor::new(bytes))
        .map_err(|_| Error::Invalid("invalid Office archive"))?;
    writer
        .start_file(EXTRA, zip::write::SimpleFileOptions::default())
        .map_err(|_| Error::Invalid("cannot write Office metadata"))?;
    writer.write_all(&payload)?;
    let bytes = writer
        .finish()
        .map_err(|_| Error::Invalid("cannot finish Office archive"))?
        .into_inner();
    if bytes.len() > LIMIT {
        return Err(Error::Limit);
    }
    Ok(bytes)
}
impl Workbook {
    pub fn xlsx_bytes(&self) -> Result<Vec<u8>, Error> {
        self.require_editable()?;
        if self.external_source.is_some() {
            return self.patch_external("xlsx");
        }
        let state = self.history.current();
        if state
            .sheets
            .iter()
            .flat_map(|s| s.cells.values())
            .any(|c| matches!(c.text, CellContent::Date(_) | CellContent::Error(_)))
        {
            return Err(Error::Invalid(
                "XLSX export of date and error cells is unsupported",
            ));
        }
        if state.styles.iter().any(|s| s.borders & !15 != 0) {
            return Err(Error::Invalid("unsupported border style"));
        }
        let formats: Vec<_> = state.styles.iter().map(format).collect();
        let mut book = Xlsx::new();
        for sheet in &state.sheets {
            let ws = book.add_worksheet();
            ws.set_name(&sheet.name)
                .map_err(|_| Error::Invalid("invalid XLSX sheet name"))?;
            if sheet.protected {
                ws.protect();
            }
            for (&r, &h) in &sheet.row_heights {
                ws.set_row_height_pixels(r as u32, h as u32)
                    .map_err(|_| Error::Invalid("invalid row height"))?;
            }
            for (&c, &w) in &sheet.col_widths {
                ws.set_column_width_pixels(c as u16, w as u32)
                    .map_err(|_| Error::Invalid("invalid column width"))?;
            }
            for m in &sheet.merges {
                let f = &formats[sheet.cells.get(&(m.top, m.left)).map_or(0, |c| c.style)];
                ws.merge_range(
                    m.top as u32,
                    m.left as u16,
                    m.bottom as u32,
                    m.right as u16,
                    "",
                    f,
                )
                .map_err(|_| Error::Invalid("cannot export merge"))?;
            }
            let mut eval_state = state.clone();
            eval_state.active = sheet.id;
            let eval = Workbook {
                history: SnapshotHistory::new(eval_state, 0),
                snapshots: BTreeMap::new(),
                next_revision: 1,
                external_source: None,
                external_baseline: None,
                external_format: None,
                external_cache: BTreeMap::new(),
            };
            let grid = formula::display_grid(&eval);
            for (&(r, c), cell) in &sheet.cells {
                let (r, c) = (r as u32, c as u16);
                let f = &formats[cell.style];
                match &cell.text {
                    CellContent::Text(t) => ws.write_string_with_format(r, c, t.raw(), f),
                    CellContent::Number(t) => ws.write_number_with_format(
                        r,
                        c,
                        t.raw()
                            .parse::<f64>()
                            .map_err(|_| Error::Invalid("invalid number"))?,
                        f,
                    ),
                    CellContent::Boolean(t) => {
                        ws.write_boolean_with_format(r, c, t.raw().eq_ignore_ascii_case("true"), f)
                    }
                    CellContent::Formula(t) => {
                        let value = &grid[r as usize][c as usize];
                        let value = if value.starts_with('#') {
                            "#N/A"
                        } else {
                            value.as_str()
                        };
                        ws.write_formula_with_format(
                            r,
                            c,
                            Formula::new(t.raw()).set_result(value),
                            f,
                        )
                    }
                    _ => unreachable!(),
                }
                .map_err(|_| Error::Invalid("cannot encode XLSX cell"))?;
            }
            if let Some(filter) = &sheet.filter {
                use rust_xlsxwriter::{FilterCondition, FilterCriteria};
                let r = filter.range;
                ws.autofilter(r.top as u32, r.left as u16, r.bottom as u32, r.right as u16)
                    .map_err(|_| Error::Invalid("cannot encode XLSX filter"))?;
                let escaped = filter
                    .contains
                    .replace('~', "~~")
                    .replace('*', "~*")
                    .replace('?', "~?");
                let condition = FilterCondition::new()
                    .add_custom_filter(FilterCriteria::Contains, escaped.as_str());
                ws.filter_column(filter.column as u16, &condition)
                    .map_err(|_| Error::Invalid("cannot encode XLSX filter"))?;
                let grid = eval.display_grid();
                let needle = filter.contains.to_lowercase();
                for row in r.top + 1..=r.bottom {
                    if !grid[row][filter.column].to_lowercase().contains(&needle) {
                        ws.set_row_hidden(row as u32)
                            .map_err(|_| Error::Invalid("cannot hide filtered row"))?;
                    }
                }
            }
            let settings = &sheet.print;
            {
                let (w, h) = (settings.paper_width_twips, settings.paper_height_twips);
                let (short, long, landscape) = if w > h { (h, w, true) } else { (w, h, false) };
                let paper = if (short - 11906).abs() <= 20 && (long - 16838).abs() <= 20 {
                    9
                } else if (short - 12240).abs() <= 20 && (long - 15840).abs() <= 20 {
                    1
                } else {
                    return Err(Error::Invalid(
                        "XLSX export supports A4 and Letter paper sizes",
                    ));
                };
                ws.set_paper_size(paper);
                if landscape {
                    ws.set_landscape();
                } else {
                    ws.set_portrait();
                }
                ws.set_margins(
                    settings.margin_left_twips as f64 / 1440.0,
                    settings.margin_right_twips as f64 / 1440.0,
                    settings.margin_top_twips as f64 / 1440.0,
                    settings.margin_bottom_twips as f64 / 1440.0,
                    0.3,
                    0.3,
                );
                if let Some(r) = settings.area {
                    ws.set_print_area(r.top as u32, r.left as u16, r.bottom as u32, r.right as u16)
                        .map_err(|_| Error::Invalid("cannot encode print area"))?;
                }
                if settings.repeat_header_rows > 0 {
                    let first = settings.area.map_or(0, |r| r.top);
                    let last = first + settings.repeat_header_rows - 1;
                    if last >= sheet.rows {
                        return Err(Error::Invalid("print headers exceed sheet"));
                    }
                    ws.set_repeat_rows(first as u32, last as u32)
                        .map_err(|_| Error::Invalid("cannot encode print headers"))?;
                }
                if settings.fit_width {
                    ws.set_print_fit_to_pages(1, 0);
                }
                if !settings.row_breaks.is_empty() {
                    let breaks: Vec<_> = settings.row_breaks.iter().map(|r| *r as u32).collect();
                    ws.set_page_breaks(&breaks)
                        .map_err(|_| Error::Invalid("cannot encode page breaks"))?;
                }
            }
            for chart in &sheet.charts {
                use rust_xlsxwriter::{Chart as XChart, ChartType};
                let kind = match chart.kind {
                    ChartKind::Bar => ChartType::Column,
                    ChartKind::Line => ChartType::Line,
                    ChartKind::Pie => ChartType::Pie,
                    ChartKind::Scatter => ChartType::Scatter,
                };
                let mut xchart = XChart::new(kind);
                xchart.title().set_name(&chart.title);
                for series in &chart.series {
                    let source = state
                        .sheets
                        .iter()
                        .find(|s| s.id == series.sheet)
                        .ok_or(Error::Invalid("chart source sheet missing"))?;
                    let values = series.values;
                    let xseries = xchart.add_series();
                    xseries.set_name(&series.name).set_values((
                        source.name.as_str(),
                        values.top as u32,
                        values.left as u16,
                        values.bottom as u32,
                        values.right as u16,
                    ));
                    if let Some(cat) = series.categories {
                        xseries.set_categories((
                            source.name.as_str(),
                            cat.top as u32,
                            cat.left as u16,
                            cat.bottom as u32,
                            cat.right as u16,
                        ));
                    }
                }
                ws.insert_chart(chart.anchor_row as u32, chart.anchor_col as u16, &xchart)
                    .map_err(|_| Error::Invalid("cannot encode XLSX chart"))?;
            }
            for rule in &sheet.validations {
                use rust_xlsxwriter::{DataValidation as XValidation, DataValidationRule};
                let validation = match &rule.kind {
                    ValidationKind::Number { minimum, maximum } => XValidation::new()
                        .allow_decimal_number(DataValidationRule::Between(*minimum, *maximum)),
                    ValidationKind::List { values } => {
                        if values.iter().any(|s| s.contains(',')) {
                            return Err(Error::Invalid(
                                "XLSX validation list values cannot contain commas",
                            ));
                        }
                        XValidation::new().allow_list_strings(values).map_err(|_| {
                            Error::Invalid("XLSX validation list exceeds Excel limits")
                        })?
                    }
                }
                .ignore_blank(rule.allow_blank);
                let r = rule.range;
                ws.add_data_validation(
                    r.top as u32,
                    r.left as u16,
                    r.bottom as u32,
                    r.right as u16,
                    &validation,
                )
                .map_err(|_| Error::Invalid("cannot encode XLSX validation"))?;
            }
            for rule in &sheet.conditional_formats {
                use rust_xlsxwriter::{
                    ConditionalFormatCell, ConditionalFormatCellRule, ConditionalFormatText,
                    ConditionalFormatTextRule,
                };
                let mut fmt = Format::new();
                if rule.bold {
                    fmt = fmt.set_bold()
                }
                if let Some(c) = rule.foreground {
                    fmt = fmt.set_font_color(Color::RGB(c & 0xffffff))
                }
                if let Some(c) = rule.background {
                    fmt = fmt.set_background_color(Color::RGB(c & 0xffffff))
                }
                let r = rule.range;
                match &rule.condition {
                    Condition::TextContains(text) => {
                        let cf = ConditionalFormatText::new()
                            .set_rule(ConditionalFormatTextRule::Contains(text.clone()))
                            .set_format(fmt);
                        ws.add_conditional_format(
                            r.top as u32,
                            r.left as u16,
                            r.bottom as u32,
                            r.right as u16,
                            &cf,
                        )
                        .map_err(|_| Error::Invalid("cannot encode XLSX conditional format"))?;
                    }
                    condition => {
                        let pred = match condition {
                            Condition::GreaterThan(v) => ConditionalFormatCellRule::GreaterThan(*v),
                            Condition::LessThan(v) => ConditionalFormatCellRule::LessThan(*v),
                            Condition::EqualTo(v) => ConditionalFormatCellRule::EqualTo(*v),
                            _ => unreachable!(),
                        };
                        let cf = ConditionalFormatCell::new().set_rule(pred).set_format(fmt);
                        ws.add_conditional_format(
                            r.top as u32,
                            r.left as u16,
                            r.bottom as u32,
                            r.right as u16,
                            &cf,
                        )
                        .map_err(|_| Error::Invalid("cannot encode XLSX conditional format"))?;
                    }
                }
            }
        }
        let bytes = book
            .save_to_buffer()
            .map_err(|_| Error::Invalid("cannot encode XLSX"))?;
        embed(bytes, "xlsx", self.project_bytes()?)
    }
    pub fn open_office(path: &Path, kind: &str) -> Result<Self, Error> {
        let mut bytes = Vec::new();
        File::open(path)?
            .take((LIMIT + 1) as u64)
            .read_to_end(&mut bytes)?;
        Self::from_office_bytes(&bytes, kind)
    }
    pub fn from_office_bytes(bytes: &[u8], kind: &str) -> Result<Self, Error> {
        if bytes.len() > LIMIT {
            return Err(Error::Limit);
        }
        if kind != "xls" {
            let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
                .map_err(|_| Error::Invalid("invalid Office archive"))?;
            let sum = digest(&mut archive)?;
            let mut payload = Vec::new();
            if let Ok(part) = archive.by_name(EXTRA) {
                part.take((LIMIT + 1) as u64).read_to_end(&mut payload)?;
                if payload.len() <= LIMIT {
                    if let Ok(embedded) = serde_json::from_slice::<Embedded>(&payload) {
                        if embedded.format == kind && embedded.digest == sum {
                            return Self::from_project_bytes(&embedded.project);
                        }
                    }
                }
            };
        }
        Self::from_external_office(bytes, kind)
    }
}
fn ods_formula(input: &str) -> Result<String, Error> {
    let b = input.as_bytes();
    let mut out = String::from("of:");
    let mut i = 0;
    let mut quoted = false;
    while i < b.len() {
        if b[i] == b'"' {
            quoted = !quoted;
            out.push('"');
            i += 1;
            continue;
        }
        if quoted || !b[i].is_ascii() {
            let c = input[i..].chars().next().unwrap();
            out.push(c);
            i += c.len_utf8();
            continue;
        }
        if b[i] == b'!' || b[i] == b'[' || b[i] == b']' {
            return Err(Error::Invalid(
                "ODS export of qualified or structured references is unsupported",
            ));
        }
        let start = i;
        let mut j = i;
        if j < b.len() && b[j] == b'$' {
            j += 1
        }
        let cs = j;
        while j < b.len() && b[j].is_ascii_alphabetic() {
            j += 1
        }
        let ce = j;
        if j < b.len() && b[j] == b'$' {
            j += 1
        }
        let rs = j;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1
        }
        if ce > cs
            && ce - cs <= 3
            && j > rs
            && (start == 0 || !b[start - 1].is_ascii_alphanumeric())
            && (j == b.len() || (!b[j].is_ascii_alphanumeric() && b[j] != b'('))
        {
            out.push_str("[.");
            out.push_str(&input[start..j]);
            if j < b.len() && b[j] == b':' {
                let mut k = j + 1;
                if k < b.len() && b[k] == b'$' {
                    k += 1
                }
                let ks = k;
                while k < b.len() && b[k].is_ascii_alphabetic() {
                    k += 1
                }
                let ke = k;
                if k < b.len() && b[k] == b'$' {
                    k += 1
                }
                let kr = k;
                while k < b.len() && b[k].is_ascii_digit() {
                    k += 1
                }
                if ke > ks && k > kr {
                    out.push_str(":.");
                    out.push_str(&input[j + 1..k]);
                    j = k;
                }
            }
            out.push(']');
            i = j;
            continue;
        }
        out.push(if b[i] == b',' { ';' } else { b[i] as char });
        i += 1
    }
    if quoted {
        return Err(Error::Invalid("invalid formula"));
    }
    Ok(out)
}
impl Workbook {
    pub fn ods_bytes(&self) -> Result<Vec<u8>, Error> {
        self.require_editable()?;
        if self.external_source.is_some() {
            return self.patch_external("ods");
        }
        use spreadsheet_ods::{
            color::Rgb,
            style::units::{Border, LineStyle},
            CellStyle as OdsStyle, Length, Sheet, WorkBook,
        };
        let state = self.history.current();
        if state
            .sheets
            .iter()
            .any(|s| s.filter.is_some() || s.print != PrintSettings::default())
        {
            return Err(Error::Invalid(
                "ODS export of filter or print settings is not yet supported",
            ));
        }
        if state
            .sheets
            .iter()
            .any(|s| !s.charts.is_empty() || !s.pivots.is_empty())
        {
            return Err(Error::Invalid(
                "ODS export of charts or pivot configurations is not yet supported",
            ));
        }
        if state
            .sheets
            .iter()
            .any(|s| !s.validations.is_empty() || !s.conditional_formats.is_empty())
        {
            return Err(Error::Invalid(
                "ODS export of validation and conditional formatting is not yet supported",
            ));
        }
        if state.sheets.iter().any(|s| {
            s.protected
                || s.cells
                    .values()
                    .any(|c| matches!(c.text, CellContent::Date(_) | CellContent::Error(_)))
        }) || state
            .styles
            .iter()
            .any(|s| s.borders & !15 != 0 || !s.number_format.is_empty())
        {
            return Err(Error::Invalid("ODS export of protection, dates, errors, unknown borders or number formats is unsupported"));
        }
        let mut book = WorkBook::default();
        let mut styles = Vec::new();
        for (i, s) in state.styles.iter().enumerate() {
            let mut st = OdsStyle::new_empty();
            st.set_name(format!("xls42style{i}"));
            if s.bold {
                st.set_font_bold()
            }
            if s.italic {
                st.set_font_italic()
            }
            if s.underline {
                st.set_text_underline_style(LineStyle::Solid)
            }
            if s.borders & 1 != 0 {
                st.set_border_top(Length::Pt(1.0), Border::Solid, Rgb::new(0, 0, 0))
            }
            if s.borders & 2 != 0 {
                st.set_border_right(Length::Pt(1.0), Border::Solid, Rgb::new(0, 0, 0))
            }
            if s.borders & 4 != 0 {
                st.set_border_bottom(Length::Pt(1.0), Border::Solid, Rgb::new(0, 0, 0))
            }
            if s.borders & 8 != 0 {
                st.set_border_left(Length::Pt(1.0), Border::Solid, Rgb::new(0, 0, 0))
            }
            if !s.font.is_empty() {
                st.set_font_name(&s.font)
            }
            if s.font_size > 0 {
                st.set_font_size(Length::Pt(s.font_size as f64).into())
            }
            if let Some(c) = s.foreground {
                st.set_color(Rgb::new((c >> 16) as u8, (c >> 8) as u8, c as u8))
            }
            if let Some(c) = s.background {
                st.set_background_color(Rgb::new((c >> 16) as u8, (c >> 8) as u8, c as u8))
            }
            styles.push(book.add_cellstyle(st));
        }
        for sh in &state.sheets {
            let mut sheet = Sheet::new(&sh.name);
            for (&r, &h) in &sh.row_heights {
                sheet.set_row_height(r as u32, Length::Pt(h as f64 * 0.75))
            }
            for (&c, &w) in &sh.col_widths {
                sheet.set_col_width(c as u32, Length::Pt(w as f64 * 0.75))
            }
            for m in &sh.merges {
                sheet.set_row_span(m.top as u32, m.left as u32, (m.bottom - m.top + 1) as u32);
                sheet.set_col_span(m.top as u32, m.left as u32, (m.right - m.left + 1) as u32)
            }
            let mut eval_state = state.clone();
            eval_state.active = sh.id;
            let eval = Workbook {
                history: SnapshotHistory::new(eval_state, 0),
                snapshots: BTreeMap::new(),
                next_revision: 1,
                external_source: None,
                external_baseline: None,
                external_format: None,
                external_cache: BTreeMap::new(),
            };
            let grid = formula::display_grid(&eval);
            for (&(r, c), cell) in &sh.cells {
                let (r, c) = (r as u32, c as u32);
                match &cell.text {
                    CellContent::Text(t) => sheet.set_value(r, c, t.raw()),
                    CellContent::Number(t) => sheet.set_value(
                        r,
                        c,
                        t.raw()
                            .parse::<f64>()
                            .map_err(|_| Error::Invalid("invalid number"))?,
                    ),
                    CellContent::Boolean(t) => {
                        sheet.set_value(r, c, t.raw().eq_ignore_ascii_case("true"))
                    }
                    CellContent::Formula(t) => {
                        if let Ok(n) = grid[r as usize][c as usize].parse::<f64>() {
                            sheet.set_value(r, c, n)
                        }
                        sheet.set_formula(r, c, ods_formula(t.raw())?)
                    }
                    _ => unreachable!(),
                }
                sheet.set_cellstyle(r, c, &styles[cell.style]);
            }
            book.push_sheet(sheet);
        }
        let bytes = spreadsheet_ods::write_ods_buf(&mut book, Vec::new())
            .map_err(|_| Error::Invalid("cannot encode ODS"))?;
        embed(bytes, "ods", self.project_bytes()?)
    }
}

impl Workbook {
    pub fn save_office(&mut self, path: &Path, format: &str) -> Result<(), Error> {
        let bytes = match format {
            "xlsx" => self.xlsx_bytes()?,
            "ods" => self.ods_bytes()?,
            _ => return Err(Error::Invalid("unknown Office format")),
        };
        write_new(path, &bytes)?;
        self.history.mark_saved();
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn office_packages_and_safe_reopen() {
        let mut b = Workbook::new(4, 4).unwrap();
        b.set_content(0, 0, CellContent::Text(TextValue::from_raw("123".into())))
            .unwrap();
        b.set_cell(1, 0, "3".into()).unwrap();
        b.set_cell(1, 1, "=SUM(A2:A2)".into()).unwrap();
        b.set_style(
            Range {
                top: 0,
                left: 0,
                bottom: 0,
                right: 0,
            },
            CellStyle {
                bold: true,
                ..Default::default()
            },
        )
        .unwrap();
        b.merge(Range {
            top: 2,
            left: 0,
            bottom: 2,
            right: 1,
        })
        .unwrap();
        b.add_sheet("Second").unwrap();
        for format in ["xlsx", "ods"] {
            let bytes = if format == "xlsx" {
                b.xlsx_bytes().unwrap()
            } else {
                b.ods_bytes().unwrap()
            };
            let mut archive = zip::ZipArchive::new(Cursor::new(bytes.as_slice())).unwrap();
            let main = if format == "xlsx" {
                "xl/workbook.xml"
            } else {
                "content.xml"
            };
            assert!(archive.by_name(main).is_ok());
            let restored = Workbook::from_office_bytes(&bytes, format).unwrap();
            assert_eq!(restored.sheets().len(), 2);
            assert_eq!(restored.active_sheet(), b.active_sheet());
            if format == "ods" {
                let parsed = spreadsheet_ods::read_ods_buf(&bytes).unwrap();
                assert_eq!(parsed.num_sheets(), 2);
            }
        }
    }
}

impl Workbook {
    fn from_external_office(bytes: &[u8], kind: &str) -> Result<Self, Error> {
        use calamine::{Data, Reader};
        let mut source = calamine::open_workbook_auto_from_rs(Cursor::new(bytes))
            .map_err(|_| Error::Invalid("unsupported or invalid spreadsheet"))?;
        let names = source.sheet_names().to_vec();
        if names.is_empty() || names.len() > MAX_SHEETS {
            return Err(Error::Limit);
        }
        let mut sheets = Vec::new();
        let mut cache = BTreeMap::new();
        let mut total = 0usize;
        for (index, name) in names.into_iter().enumerate() {
            let values = source
                .worksheet_range(&name)
                .map_err(|_| Error::Invalid("cannot read sheet values"))?;
            let formulas = source
                .worksheet_formula(&name)
                .map_err(|_| Error::Invalid("cannot read sheet formulas"))?;
            let end = values.end().unwrap_or((0, 0));
            let fend = formulas.end().unwrap_or((0, 0));
            let rows = (end.0.max(fend.0) as usize + 1).max(20);
            let cols = (end.1.max(fend.1) as usize + 1).max(8);
            if rows > MAX_ROWS || cols > MAX_COLS {
                return Err(Error::Limit);
            }
            let id = index as u64 + 1;
            let mut sheet = Sheet::new(id, name, rows, cols);
            let start = values.start().unwrap_or((0, 0));
            for (r, c, data) in values.used_cells() {
                let (r, c) = (r + start.0 as usize, c + start.1 as usize);
                let val = match data {
                    Data::Empty => continue,
                    Data::Int(v) => CellContent::Number(TextValue::from_raw(v.to_string())),
                    Data::Float(v) if v.is_finite() => {
                        CellContent::Number(TextValue::from_raw(v.to_string()))
                    }
                    Data::Float(_) => return Err(Error::Invalid("invalid numeric value")),
                    Data::String(v) => CellContent::Text(TextValue::from_raw(v.clone())),
                    Data::Bool(v) => CellContent::Boolean(TextValue::from_raw(v.to_string())),
                    Data::DateTime(v) => CellContent::Date(TextValue::from_raw(
                        v.as_datetime()
                            .map(|d| d.format("%Y-%m-%dT%H:%M:%S%.f").to_string())
                            .unwrap_or_else(|| v.as_f64().to_string()),
                    )),
                    Data::DateTimeIso(v) | Data::DurationIso(v) => {
                        CellContent::Date(TextValue::from_raw(v.clone()))
                    }
                    Data::Error(v) => CellContent::Error(TextValue::from_raw(v.to_string())),
                };
                total = total.checked_add(val.raw().len()).ok_or(Error::Limit)?;
                if total > MAX_TEXT {
                    return Err(Error::Limit);
                }
                sheet.cells.insert(
                    (r, c),
                    Cell {
                        text: val,
                        style: 0,
                    },
                );
            }
            let start = formulas.start().unwrap_or((0, 0));
            for (r, c, formula) in formulas.used_cells() {
                let (r, c) = (r + start.0 as usize, c + start.1 as usize);
                if let Some(cached) = sheet.cells.get(&(r, c)) {
                    cache.insert((id, r, c), cached.text.raw().to_owned());
                }
                let text = if formula.starts_with('=') {
                    formula.clone()
                } else {
                    format!("={formula}")
                };
                total = total.checked_add(text.len()).ok_or(Error::Limit)?;
                if total > MAX_TEXT {
                    return Err(Error::Limit);
                }
                sheet.cells.insert(
                    (r, c),
                    Cell {
                        text: CellContent::Formula(TextValue::from_raw(text)),
                        style: 0,
                    },
                );
            }
            sheets.push(sheet);
        }
        let mut state = State {
            next_id: sheets.len() as u64 + 1,
            sheets,
            active: 1,
            styles: vec![CellStyle::default()],
            selection: Range {
                top: 0,
                left: 0,
                bottom: 0,
                right: 0,
            },
        };
        if kind == "ods" {
            import_ods_layout(bytes, &mut state)?;
        } else if kind == "xlsx" {
            import_xlsx_layout(bytes, &mut state)?;
        }
        Ok(Self {
            history: SnapshotHistory::new(state.clone(), 8),
            snapshots: BTreeMap::new(),
            next_revision: 1,
            external_source: Some(bytes.to_vec()),
            external_baseline: Some(state),
            external_format: Some(kind.to_owned()),
            external_cache: cache,
        })
    }
}

fn import_ods_layout(bytes: &[u8], state: &mut State) -> Result<(), Error> {
    use spreadsheet_ods::Length;
    let book = spreadsheet_ods::read_ods_buf(bytes)
        .map_err(|_| Error::Invalid("cannot parse ODS layout"))?;
    if book.num_sheets() != state.sheets.len() {
        return Err(Error::Invalid("inconsistent ODS sheets"));
    }
    for i in 0..state.sheets.len() {
        let source = book.sheet(i);
        let sheet = &mut state.sheets[i];
        for r in 0..sheet.rows {
            if let Length::Pt(v) = source.row_height(r as u32) {
                if v > 0.0 && v < 49151.0 {
                    sheet.row_heights.insert(r, (v / 0.75).round() as u16);
                }
            }
        }
        for c in 0..sheet.cols {
            if let Length::Pt(v) = source.col_width(c as u32) {
                if v > 0.0 && v < 49151.0 {
                    sheet.col_widths.insert(c, (v / 0.75).round() as u16);
                }
            }
        }
        for r in 0..sheet.rows {
            for c in 0..sheet.cols {
                let rs = source.row_span(r as u32, c as u32) as usize;
                let cs = source.col_span(r as u32, c as u32) as usize;
                if rs > 1 || cs > 1 {
                    let m = Range {
                        top: r,
                        left: c,
                        bottom: r + rs - 1,
                        right: c + cs - 1,
                    };
                    if m.valid(sheet) && !sheet.merges.iter().any(|x| x.overlaps(m)) {
                        sheet.merges.push(m)
                    }
                }
                if let Some(reference) = source.cellstyle(r as u32, c as u32) {
                    if let Some(style) = book.cellstyle(reference.as_ref()) {
                        let mut out = CellStyle::default();
                        for (key, value) in style.textstyle().iter() {
                            match key.as_ref() {
                                "fo:font-weight" => out.bold = value == "bold",
                                "fo:font-style" => out.italic = value == "italic",
                                "style:font-name" => out.font = value.into(),
                                "fo:font-size" => {
                                    out.font_size = value
                                        .strip_suffix("pt")
                                        .and_then(|v| v.parse::<f64>().ok())
                                        .unwrap_or(0.0)
                                        .clamp(0.0, u16::MAX as f64)
                                        as u16
                                }
                                "fo:color" => out.foreground = parse_rgb(value),
                                "style:text-underline-style" => out.underline = value != "none",
                                _ => {}
                            }
                        }
                        for (key, value) in style.cellstyle().iter() {
                            match key.as_ref() {
                                "fo:background-color" => out.background = parse_rgb(value),
                                "fo:border-top" => {
                                    if value != "none" {
                                        out.borders |= 1
                                    }
                                }
                                "fo:border-right" => {
                                    if value != "none" {
                                        out.borders |= 2
                                    }
                                }
                                "fo:border-bottom" => {
                                    if value != "none" {
                                        out.borders |= 4
                                    }
                                }
                                "fo:border-left" => {
                                    if value != "none" {
                                        out.borders |= 8
                                    }
                                }
                                "fo:border" => {
                                    if value != "none" {
                                        out.borders = 15
                                    }
                                }
                                _ => {}
                            }
                        }
                        let id = match state.styles.iter().position(|s| *s == out) {
                            Some(id) => id,
                            None => {
                                state.styles.push(out);
                                state.styles.len() - 1
                            }
                        };
                        if id != 0 {
                            sheet
                                .cells
                                .entry((r, c))
                                .or_insert_with(|| Cell {
                                    text: CellContent::default(),
                                    style: 0,
                                })
                                .style = id
                        }
                    }
                }
            }
        }
    }
    Ok(())
}
fn parse_rgb(s: &str) -> Option<u32> {
    let s = s.strip_prefix('#')?;
    if s.len() != 6 {
        return None;
    }
    u32::from_str_radix(s, 16).ok()
}
#[cfg(test)]
mod external_regression {
    use super::*;
    #[test]
    fn external_books_edit_values_preserving_other_parts() {
        let mut x = rust_xlsxwriter::Workbook::new();
        let w = x.add_worksheet();
        w.set_name("External").unwrap();
        w.write_number_with_format(
            1,
            1,
            42,
            &rust_xlsxwriter::Format::new()
                .set_bold()
                .set_background_color(rust_xlsxwriter::Color::RGB(0xff0000)),
        )
        .unwrap();
        w.merge_range(2, 0, 2, 1, "header", &rust_xlsxwriter::Format::new())
            .unwrap();
        w.write_formula(
            1,
            2,
            rust_xlsxwriter::Formula::new("=B2*2").set_result("84"),
        )
        .unwrap();
        let bytes = x.save_to_buffer().unwrap();
        let mut writer = zip::ZipWriter::new_append(Cursor::new(bytes)).unwrap();
        writer
            .start_file(
                "customXml/opaque.txt",
                zip::write::SimpleFileOptions::default(),
            )
            .unwrap();
        writer.write_all(b"retain me").unwrap();
        let bytes = writer.finish().unwrap().into_inner();
        let mut b = Workbook::from_office_bytes(&bytes, "xlsx").unwrap();
        assert!(!b.is_read_only());
        assert_eq!(b.cell(1, 1), Some("42"));
        assert!(b.style(1, 1).unwrap().bold);
        assert_eq!(b.style(1, 1).unwrap().background, Some(0xff0000));
        assert_eq!(
            b.merges(),
            [Range {
                top: 2,
                left: 0,
                bottom: 2,
                right: 1
            }]
        );
        assert_eq!(b.cell(1, 2), Some("=B2*2"));
        assert_eq!(b.display_grid()[1][2], "84");
        b.set_cell(0, 0, "new & <text>".into()).unwrap();
        b.set_cell(1, 1, "99".into()).unwrap();
        let mut style = b.style(1, 1).unwrap().clone();
        style.italic = true;
        style.background = Some(0x2277aa);
        style.number_format = "0.00".into();
        style.borders = 15;
        b.set_style(
            Range {
                top: 1,
                left: 1,
                bottom: 1,
                right: 1,
            },
            style,
        )
        .unwrap();
        let mut formula_style = b.style(1, 2).unwrap().clone();
        formula_style.underline = true;
        b.set_style(
            Range {
                top: 1,
                left: 2,
                bottom: 1,
                right: 2,
            },
            formula_style,
        )
        .unwrap();
        b.merge(Range {
            top: 4,
            left: 0,
            bottom: 4,
            right: 1,
        })
        .unwrap();
        let saved = b.xlsx_bytes().unwrap();
        let mut z = zip::ZipArchive::new(Cursor::new(saved.as_slice())).unwrap();
        let mut opaque = String::new();
        z.by_name("customXml/opaque.txt")
            .unwrap()
            .read_to_string(&mut opaque)
            .unwrap();
        assert_eq!(opaque, "retain me");
        let reopened = Workbook::from_office_bytes(&saved, "xlsx").unwrap();
        assert_eq!(reopened.cell(0, 0), Some("new & <text>"));
        assert_eq!(reopened.cell(1, 1), Some("99"));
        assert!(reopened.style(1, 1).unwrap().bold);
        assert!(reopened.style(1, 1).unwrap().italic);
        assert_eq!(reopened.style(1, 1).unwrap().background, Some(0x2277aa));
        assert_eq!(reopened.style(1, 1).unwrap().borders, 15);
        assert_eq!(reopened.style(1, 1).unwrap().number_format, "0.00");
        assert_eq!(reopened.cell(1, 2), Some("=B2*2"));
        assert!(reopened.style(1, 2).unwrap().underline);
        assert!(reopened.merges().contains(&Range {
            top: 4,
            left: 0,
            bottom: 4,
            right: 1
        }));
        assert!(b.add_sheet("no").is_err());
        assert!(b.project_bytes().is_err());
        assert!(b.is_dirty());
    }
    #[test]
    fn external_ods_preserves_visible_style_and_merges() {
        use spreadsheet_ods::{CellStyle as OdsStyle, Sheet, WorkBook};
        let mut o = WorkBook::default();
        let mut style = OdsStyle::new_empty();
        style.set_name("mybold");
        style.set_font_bold();
        let style = o.add_cellstyle(style);
        let mut sh = Sheet::new("Sheet1");
        sh.set_value(0, 0, "hello");
        sh.set_cellstyle(0, 0, &style);
        sh.set_row_span(0, 0, 2);
        sh.set_col_span(0, 0, 2);
        o.push_sheet(sh);
        let bytes = spreadsheet_ods::write_ods_buf(&mut o, Vec::new()).unwrap();
        let mut writer = zip::ZipWriter::new_append(Cursor::new(bytes)).unwrap();
        writer
            .start_file(
                "Pictures/opaque.bin",
                zip::write::SimpleFileOptions::default(),
            )
            .unwrap();
        writer.write_all(b"unparsed payload").unwrap();
        let bytes = writer.finish().unwrap().into_inner();
        let mut b = Workbook::from_office_bytes(&bytes, "ods").unwrap();
        assert!(!b.is_read_only());
        assert_eq!(b.cell(0, 0), Some("hello"));
        assert!(b.style(0, 0).unwrap().bold);
        b.set_cell(0, 0, "changed".into()).unwrap();
        let mut style = b.style(0, 0).unwrap().clone();
        style.italic = true;
        style.background = Some(0x35aadc);
        style.borders = 15;
        b.set_style(
            Range {
                top: 0,
                left: 0,
                bottom: 0,
                right: 0,
            },
            style,
        )
        .unwrap();
        b.merge(Range {
            top: 4,
            left: 0,
            bottom: 4,
            right: 1,
        })
        .unwrap();
        let saved = b.ods_bytes().unwrap();
        let mut z = zip::ZipArchive::new(Cursor::new(saved.as_slice())).unwrap();
        let mut data = String::new();
        z.by_name("Pictures/opaque.bin")
            .unwrap()
            .read_to_string(&mut data)
            .unwrap();
        assert_eq!(data, "unparsed payload");
        let reopened = Workbook::from_office_bytes(&saved, "ods").unwrap();
        assert_eq!(reopened.cell(0, 0), Some("changed"));
        assert!(reopened.style(0, 0).unwrap().bold);
        assert!(reopened.style(0, 0).unwrap().italic);
        assert_eq!(reopened.style(0, 0).unwrap().background, Some(0x35aadc));
        assert_eq!(reopened.style(0, 0).unwrap().borders, 15);
        assert!(reopened.merges().contains(&Range {
            top: 4,
            left: 0,
            bottom: 4,
            right: 1
        }));
        assert_eq!(
            b.merges(),
            [
                Range {
                    top: 0,
                    left: 0,
                    bottom: 1,
                    right: 1
                },
                Range {
                    top: 4,
                    left: 0,
                    bottom: 4,
                    right: 1
                }
            ]
        );
    }
}
fn zip_text(
    archive: &mut zip::ZipArchive<Cursor<&[u8]>>,
    path: &str,
) -> Result<Option<String>, Error> {
    let mut file = match archive.by_name(path) {
        Ok(f) => f,
        Err(_) => return Ok(None),
    };
    if file.size() > LIMIT as u64 {
        return Err(Error::Limit);
    }
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    Ok(Some(text))
}
pub(super) fn xml<'a>(text: &'a str) -> Result<roxmltree::Document<'a>, Error> {
    roxmltree::Document::parse(text).map_err(|_| Error::Invalid("invalid XLSX XML"))
}
fn child<'a, 'b>(node: roxmltree::Node<'a, 'b>, name: &str) -> Option<roxmltree::Node<'a, 'b>> {
    node.children().find(|n| n.has_tag_name(name))
}
fn attrs<'a, 'b>(node: roxmltree::Node<'a, 'b>, name: &str) -> Option<&'a str> {
    node.attribute(name)
}
fn xlsx_color(n: Option<roxmltree::Node<'_, '_>>) -> Option<u32> {
    let rgb = n?.attribute("rgb")?;
    let rgb = if rgb.len() == 8 { &rgb[2..] } else { rgb };
    parse_rgb(&format!("#{rgb}"))
}
fn a1(s: &str) -> Option<(usize, usize)> {
    let s = s.trim_matches('$');
    let idx = s.find(|ch: char| ch.is_ascii_digit())?;
    let mut col = 0usize;
    for c in s[..idx].bytes() {
        if !c.is_ascii_alphabetic() {
            return None;
        }
        col = col
            .checked_mul(26)?
            .checked_add((c.to_ascii_uppercase() - b'A' + 1) as usize)?
    }
    let row = s[idx..].replace('$', "").parse::<usize>().ok()?;
    Some((row.checked_sub(1)?, col.checked_sub(1)?))
}
fn import_xlsx_layout(bytes: &[u8], state: &mut State) -> Result<(), Error> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| Error::Invalid("invalid XLSX"))?;
    let (Some(workbook), Some(rels)) = (
        zip_text(&mut archive, "xl/workbook.xml")?,
        zip_text(&mut archive, "xl/_rels/workbook.xml.rels")?,
    ) else {
        return Ok(());
    };
    let workbook = xml(&workbook)?;
    let rels = xml(&rels)?;
    let mut targets = BTreeMap::new();
    for rel in rels
        .descendants()
        .filter(|n| n.has_tag_name("Relationship"))
    {
        if let (Some(id), Some(t)) = (attrs(rel, "Id"), attrs(rel, "Target")) {
            let path = if t.starts_with('/') {
                t.trim_start_matches('/').to_string()
            } else {
                format!("xl/{t}")
            };
            if !path.split('/').any(|s| s == "..") {
                targets.insert(id.to_owned(), path);
            }
        }
    }
    let mut formats = vec![CellStyle::default()];
    if let Some(styles) = zip_text(&mut archive, "xl/styles.xml")? {
        let d = xml(&styles)?;
        let root = d.root_element();
        let fonts: Vec<_> = child(root, "fonts")
            .map(|n| n.children().filter(|x| x.has_tag_name("font")).collect())
            .unwrap_or_default();
        let fills: Vec<_> = child(root, "fills")
            .map(|n| n.children().filter(|x| x.has_tag_name("fill")).collect())
            .unwrap_or_default();
        let borders: Vec<_> = child(root, "borders")
            .map(|n| n.children().filter(|x| x.has_tag_name("border")).collect())
            .unwrap_or_default();
        let mut numberformats = BTreeMap::new();
        if let Some(n) = child(root, "numFmts") {
            for fmt in n.children().filter(|n| n.has_tag_name("numFmt")) {
                if let (Some(id), Some(code)) = (
                    fmt.attribute("numFmtId")
                        .and_then(|s| s.parse::<usize>().ok()),
                    fmt.attribute("formatCode"),
                ) {
                    numberformats.insert(id, code.to_owned());
                }
            }
        }
        if let Some(xfs) = child(root, "cellXfs") {
            formats.clear();
            for xf in xfs.children().filter(|n| n.has_tag_name("xf")) {
                let mut style = CellStyle::default();
                let index = |name| {
                    xf.attribute(name)
                        .and_then(|x| x.parse::<usize>().ok())
                        .unwrap_or(0)
                };
                if let Some(font) = fonts.get(index("fontId")) {
                    style.bold = child(*font, "b").is_some_and(|n| n.attribute("val") != Some("0"));
                    style.italic =
                        child(*font, "i").is_some_and(|n| n.attribute("val") != Some("0"));
                    style.underline = child(*font, "u").is_some();
                    style.font = child(*font, "name")
                        .and_then(|n| n.attribute("val"))
                        .unwrap_or("")
                        .into();
                    style.font_size = child(*font, "sz")
                        .and_then(|n| n.attribute("val"))
                        .and_then(|x| x.parse::<f64>().ok())
                        .unwrap_or(0.0)
                        .clamp(0.0, u16::MAX as f64) as u16;
                    style.foreground = xlsx_color(child(*font, "color"));
                }
                if let Some(fill) = fills.get(index("fillId")) {
                    style.background =
                        xlsx_color(child(*fill, "patternFill").and_then(|n| child(n, "fgColor")))
                }
                if let Some(border) = borders.get(index("borderId")) {
                    for (side, bit) in [("top", 1), ("right", 2), ("bottom", 4), ("left", 8)] {
                        if child(*border, side)
                            .and_then(|n| n.attribute("style"))
                            .is_some_and(|s| s != "none")
                        {
                            style.borders |= bit
                        }
                    }
                }
                let n = index("numFmtId");
                style.number_format = numberformats.get(&n).cloned().unwrap_or_else(|| {
                    match n {
                        14 => "mm-dd-yy",
                        15 => "d-mmm-yy",
                        16 => "d-mmm",
                        17 => "mmm-yy",
                        18 => "h:mm AM/PM",
                        19 => "h:mm:ss AM/PM",
                        20 => "h:mm",
                        21 => "h:mm:ss",
                        22 => "m/d/yy h:mm",
                        _ => "",
                    }
                    .into()
                });
                formats.push(style)
            }
        }
    }
    let sheet_nodes: Vec<_> = workbook
        .descendants()
        .filter(|n| n.has_tag_name("sheet"))
        .collect();
    for node in sheet_nodes {
        let Some(name) = node.attribute("name") else {
            continue;
        };
        let Some(sheet) = state.sheets.iter_mut().find(|s| s.name == name) else {
            continue;
        };
        let Some(id) = node
            .attributes()
            .find(|a| a.name() == "id")
            .map(|a| a.value())
        else {
            continue;
        };
        let Some(path) = targets.get(id) else {
            continue;
        };
        let Some(text) = zip_text(&mut archive, path)? else {
            continue;
        };
        let d = xml(&text)?;
        for row in d.descendants().filter(|n| n.has_tag_name("row")) {
            if let (Some(r), Some(h)) = (
                row.attribute("r")
                    .and_then(|x| x.parse::<usize>().ok())
                    .and_then(|x| x.checked_sub(1)),
                row.attribute("ht").and_then(|x| x.parse::<f64>().ok()),
            ) {
                if r < sheet.rows && h > 0.0 && h < 49151.0 {
                    sheet.row_heights.insert(r, (h / 0.75).round() as u16);
                }
            }
        }
        for col in d.descendants().filter(|n| n.has_tag_name("col")) {
            if let (Some(min), Some(max), Some(width)) = (
                col.attribute("min").and_then(|x| x.parse::<usize>().ok()),
                col.attribute("max").and_then(|x| x.parse::<usize>().ok()),
                col.attribute("width").and_then(|x| x.parse::<f64>().ok()),
            ) {
                if min > 0 && min <= max && max <= MAX_COLS && width > 0.0 && width < 9000.0 {
                    for c in min - 1..max.min(sheet.cols) {
                        sheet.col_widths.insert(c, (width * 7.0).round() as u16);
                    }
                }
            }
        }
        for node in d.descendants().filter(|n| n.has_tag_name("c")) {
            let Some((r, c)) = node.attribute("r").and_then(a1) else {
                continue;
            };
            if r >= sheet.rows || c >= sheet.cols {
                continue;
            }
            let index = node
                .attribute("s")
                .and_then(|x| x.parse::<usize>().ok())
                .unwrap_or(0);
            if let Some(style) = formats.get(index) {
                let id = match state.styles.iter().position(|x| x == style) {
                    Some(id) => id,
                    None => {
                        state.styles.push(style.clone());
                        state.styles.len() - 1
                    }
                };
                if id != 0 {
                    sheet
                        .cells
                        .entry((r, c))
                        .or_insert_with(|| Cell {
                            text: CellContent::default(),
                            style: 0,
                        })
                        .style = id;
                }
            }
        }
        for node in d.descendants().filter(|n| n.has_tag_name("mergeCell")) {
            let Some((a, b)) = node.attribute("ref").and_then(|v| v.split_once(':')) else {
                continue;
            };
            if let (Some((top, left)), Some((bottom, right))) = (a1(a), a1(b)) {
                let m = Range {
                    top,
                    left,
                    bottom,
                    right,
                };
                if m.valid(sheet) && !sheet.merges.iter().any(|v| v.overlaps(m)) {
                    sheet.merges.push(m)
                }
            }
        }
    }
    Ok(())
}
fn changed_cells(
    old: &State,
    new: &State,
    allow_styles: bool,
) -> Result<Vec<Vec<((usize, usize), Option<Cell>)>>, Error> {
    if old.sheets.len() != new.sheets.len() || !new.styles.starts_with(&old.styles) {
        return Err(Error::Invalid(
            "This Office edit cannot preserve unsupported workbook content",
        ));
    }
    let mut all = Vec::new();
    for (a, b) in old.sheets.iter().zip(&new.sheets) {
        if a.id != b.id
            || a.name != b.name
            || a.rows != b.rows
            || a.cols != b.cols
            || a.row_heights != b.row_heights
            || a.col_widths != b.col_widths
            || a.protected != b.protected
            || a.filter != b.filter
            || a.print != b.print
        {
            return Err(Error::Invalid(
                "Structural Office edits cannot yet preserve references",
            ));
        }
        let mut keys = std::collections::BTreeSet::new();
        keys.extend(a.cells.keys().copied());
        keys.extend(b.cells.keys().copied());
        let mut changes = Vec::new();
        for key in keys {
            let before = a.cells.get(&key);
            let after = b.cells.get(&key);
            if before == after {
                continue;
            }
            if !allow_styles && before.map_or(0, |c| c.style) != after.map_or(0, |c| c.style) {
                return Err(Error::Invalid(
                    "Office formatting edits cannot yet be preserved",
                ));
            }
            changes.push((key, after.cloned()));
        }
        all.push(changes);
    }
    Ok(all)
}
impl Workbook {
    fn patch_external(&self, kind: &str) -> Result<Vec<u8>, Error> {
        if self.external_format.as_deref() != Some(kind) {
            return Err(Error::Invalid(
                "Conversion would discard unsupported Office content; save in the original format",
            ));
        }
        let bytes = self
            .external_source
            .as_ref()
            .ok_or(Error::Invalid("missing source"))?;
        let old = self
            .external_baseline
            .as_ref()
            .ok_or(Error::Invalid("missing source state"))?;
        let changes = changed_cells(old, self.history.current(), kind == "ods" || kind == "xlsx")?;
        if changes.iter().all(Vec::is_empty)
            && old
                .sheets
                .iter()
                .zip(&self.history.current().sheets)
                .all(|(a, b)| a.merges == b.merges)
        {
            return Ok(bytes.clone());
        }
        match kind {
            "xlsx" => patch_xlsx(bytes, old, self.history.current(), &changes),
            "ods" => patch_ods(bytes, old, self.history.current(), &changes),
            _ => Err(Error::Invalid("This Office format cannot yet be edited")),
        }
    }
}
fn patch_ods(
    bytes: &[u8],
    old: &State,
    current: &State,
    changes: &[Vec<((usize, usize), Option<Cell>)>],
) -> Result<Vec<u8>, Error> {
    use spreadsheet_ods::Value;
    let mut book = spreadsheet_ods::read_ods_buf(bytes)
        .map_err(|_| Error::Invalid("cannot read original ODS"))?;
    let mut style_seq = 0usize;
    for (i, (before, after)) in old.sheets.iter().zip(&current.sheets).enumerate() {
        for m in &before.merges {
            if !after.merges.contains(m) {
                let sheet = book.sheet_mut(i);
                sheet.set_row_span(m.top as u32, m.left as u32, 1);
                sheet.set_col_span(m.top as u32, m.left as u32, 1);
            }
        }
        for m in &after.merges {
            if !before.merges.contains(m) {
                let sheet = book.sheet_mut(i);
                sheet.set_row_span(m.top as u32, m.left as u32, (m.bottom - m.top + 1) as u32);
                sheet.set_col_span(m.top as u32, m.left as u32, (m.right - m.left + 1) as u32);
            }
        }
    }
    for (i, cells) in changes.iter().enumerate() {
        for &((row, col), ref value) in cells {
            let (r, c) = (row as u32, col as u32);
            let before = old.sheets[i].cells.get(&(row, col));
            let after = value.as_ref();
            let old_id = before.map_or(0, |v| v.style);
            let new_id = after.map_or(0, |v| v.style);
            let replacement_style = if old_id != new_id {
                let prior = &old.styles[old_id];
                let next = &current.styles[new_id];
                if prior.number_format != next.number_format {
                    return Err(Error::Invalid(
                        "ODS number-format editing is not yet supported",
                    ));
                }
                let source_ref = book.sheet(i).cellstyle(r, c).cloned();
                let mut style = source_ref
                    .as_ref()
                    .and_then(|s| book.cellstyle(s.as_ref()))
                    .cloned()
                    .unwrap_or_else(spreadsheet_ods::CellStyle::new_empty);
                loop {
                    style_seq += 1;
                    let name = format!("XLS42ExternalStyle{style_seq}");
                    if book.cellstyle(&name).is_none() {
                        style.set_name(name);
                        break;
                    }
                }
                style.set_origin(spreadsheet_ods::style::StyleOrigin::Content);
                style.set_styleuse(spreadsheet_ods::style::StyleUse::Automatic);
                update_ods_style(&mut style, prior, next);
                Some(book.add_cellstyle(style))
            } else {
                None
            };
            let sheet = book.sheet_mut(i);
            if let Some(ref style) = replacement_style {
                sheet.set_cellstyle(r, c, style)
            }
            let value_changed = before.map(|v| &v.text) != after.map(|v| &v.text);
            if !value_changed {
                continue;
            }
            sheet.clear_formula(r, c);
            match after.map(|v| &v.text) {
                None => sheet.set_value(r, c, Value::Empty),
                Some(CellContent::Text(v)) => sheet.set_value(r, c, v.raw()),
                Some(CellContent::Number(v)) => sheet.set_value(
                    r,
                    c,
                    v.raw()
                        .parse::<f64>()
                        .map_err(|_| Error::Invalid("invalid number"))?,
                ),
                Some(CellContent::Boolean(v)) => {
                    sheet.set_value(r, c, v.raw().eq_ignore_ascii_case("true"))
                }
                Some(CellContent::Formula(v)) => {
                    sheet.set_value(r, c, Value::Empty);
                    sheet.set_formula(r, c, ods_formula(v.raw())?)
                }
                _ => {
                    return Err(Error::Invalid(
                        "editing dates and errors in ODS is unsupported",
                    ))
                }
            }
        }
    }
    let generated = spreadsheet_ods::write_ods_buf(&mut book, Vec::new())
        .map_err(|_| Error::Invalid("cannot write ODS without loss"))?;
    verify_ods_untouched_styles(bytes, &generated, changes, old, current)?;
    let mut original =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| Error::Invalid("invalid ODS"))?;
    let mut generated = zip::ZipArchive::new(Cursor::new(generated.as_slice()))
        .map_err(|_| Error::Invalid("invalid ODS output"))?;
    let before =
        zip_text(&mut original, "content.xml")?.ok_or(Error::Invalid("missing ODS content"))?;
    verify_ods_repeated_styles(&before)?;
    let after = zip_text(&mut generated, "content.xml")?
        .ok_or(Error::Invalid("missing generated ODS content"))?;
    let after = preserve_ods_auto_styles(&before, &after)?;
    verify_ods_opaque_content(&before, &after)?;

    let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
    for i in 0..original.len() {
        let file = original
            .by_index(i)
            .map_err(|_| Error::Invalid("invalid ODS entry"))?;
        let name = file.name().to_owned();
        if name == EXTRA {
            continue;
        }
        if name == "content.xml" {
            let opts =
                zip::write::SimpleFileOptions::default().compression_method(file.compression());
            writer
                .start_file(name, opts)
                .map_err(|_| Error::Invalid("cannot write ODS content"))?;
            writer.write_all(after.as_bytes())?;
        } else {
            writer
                .raw_copy_file(file)
                .map_err(|_| Error::Invalid("cannot preserve ODS entry"))?;
        }
    }
    let out = writer
        .finish()
        .map_err(|_| Error::Invalid("cannot finish ODS"))?
        .into_inner();
    if out.len() > LIMIT {
        return Err(Error::Limit);
    }
    Ok(out)
}
pub(super) fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn col_name(mut c: usize) -> String {
    c += 1;
    let mut s = Vec::new();
    while c > 0 {
        c -= 1;
        s.push((b'A' + (c % 26) as u8) as char);
        c /= 26
    }
    s.iter().rev().collect()
}
fn cell_xml(
    prefix: &str,
    r: usize,
    c: usize,
    cell: Option<&Cell>,
    style: Option<&str>,
) -> Result<String, Error> {
    let pos = format!("{}{}", col_name(c), r + 1);
    let mut out = format!("<{prefix}c r=\"{pos}\"");
    if let Some(s) = style {
        out.push_str(&format!(" s=\"{}\"", escape_xml(s)))
    }
    let Some(cell) = cell else {
        out.push_str("/>");
        return Ok(out);
    };
    let raw = cell.text.raw();
    if raw
        .chars()
        .any(|c| !matches!(c, '\t' | '\n' | '\r') && (c as u32) < 32)
    {
        return Err(Error::Invalid("cell contains XML control characters"));
    }
    match &cell.text {
        CellContent::Text(_) => {
            out.push_str(&format!(" t=\"inlineStr\"><{prefix}is><{prefix}t xml:space=\"preserve\">{}</{prefix}t></{prefix}is></{prefix}c>",escape_xml(raw)));
        }
        CellContent::Number(_) => out.push_str(&format!(
            "><{prefix}v>{}</{prefix}v></{prefix}c>",
            escape_xml(raw)
        )),
        CellContent::Boolean(_) => out.push_str(&format!(
            " t=\"b\"><{prefix}v>{}</{prefix}v></{prefix}c>",
            if raw.eq_ignore_ascii_case("true") {
                "1"
            } else {
                "0"
            }
        )),
        CellContent::Formula(_) => out.push_str(&format!(
            "><{prefix}f>{}</{prefix}f></{prefix}c>",
            escape_xml(
                raw.strip_prefix('=')
                    .ok_or(Error::Invalid("invalid formula"))?
            )
        )),
        _ => {
            return Err(Error::Invalid(
                "editing dates or errors in XLSX is unsupported",
            ))
        }
    }
    Ok(out)
}
pub(super) fn prefix(raw: &str) -> &str {
    let Some(start) = raw.find('<') else {
        return "";
    };
    let name = raw[start + 1..]
        .split(|c: char| c.is_whitespace() || c == '>' || c == '/')
        .next()
        .unwrap_or("");
    if let Some(i) = name.find(':') {
        &name[..=i]
    } else {
        ""
    }
}
pub(super) fn apply_edits(mut text: String, mut edits: Vec<(usize, usize, String)>) -> String {
    edits.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    for (a, b, value) in edits {
        text.replace_range(a..b, &value)
    }
    text
}
fn patch_row(
    text: &str,
    row: roxmltree::Node<'_, '_>,
    changes: &[((usize, usize), Option<Cell>)],
    old: &Sheet,
    styles: &BTreeMap<(usize, usize), usize>,
) -> Result<String, Error> {
    let rr = row.range();
    let original = &text[rr.clone()];
    let p = prefix(original);
    let mut edits = Vec::new();
    let mut insertions: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    let existing: Vec<_> = row.children().filter(|n| n.has_tag_name("c")).collect();
    let closing = original.rfind("</");
    let self_closing = original.trim_end().ends_with("/>");
    for ((r, c), value) in changes {
        if let Some(node) = existing
            .iter()
            .copied()
            .find(|n| n.attribute("r").and_then(a1) == Some((*r, *c)))
        {
            let desired_style = styles.get(&(*r, *c)).map(usize::to_string);
            let value_changed =
                old.cells.get(&(*r, *c)).map(|v| &v.text) != value.as_ref().map(|v| &v.text);
            if !value_changed {
                if let Some(style) = desired_style {
                    let range = node.range();
                    let cell = crate::xlsx_styles::attrs(&text[range.clone()], &[("s", style)])?;
                    edits.push((range.start - rr.start, range.end - rr.start, cell));
                }
                continue;
            }
            if node
                .attributes()
                .any(|a| !matches!(a.name(), "r" | "s" | "t"))
                || node
                    .children()
                    .any(|n| n.is_element() && !matches!(n.tag_name().name(), "v" | "f" | "is"))
                || node
                    .children()
                    .filter(|n| n.has_tag_name("f"))
                    .any(|n| n.attributes().len() > 0)
                || node
                    .children()
                    .filter(|n| n.has_tag_name("is"))
                    .any(|is| is.descendants().any(|n| n.has_tag_name("r")))
            {
                return Err(Error::Invalid(
                    "This cell has rich or shared metadata that cannot yet be edited safely",
                ));
            }
            let range = node.range();
            edits.push((
                range.start - rr.start,
                range.end - rr.start,
                cell_xml(
                    p,
                    *r,
                    *c,
                    value.as_ref(),
                    desired_style.as_deref().or(node.attribute("s")),
                )?,
            ));
        } else if value.is_some() {
            let position = existing
                .iter()
                .find_map(|n| {
                    let (_, col) = n.attribute("r").and_then(a1)?;
                    if col > *c {
                        Some(n.range().start - rr.start)
                    } else {
                        None
                    }
                })
                .or(closing)
                .unwrap_or(original.len());
            insertions.entry(position).or_default().push(cell_xml(
                p,
                *r,
                *c,
                value.as_ref(),
                styles.get(&(*r, *c)).map(usize::to_string).as_deref(),
            )?);
        }
    }
    if self_closing && !insertions.is_empty() {
        let at = original.rfind("/>").ok_or(Error::Invalid("invalid row"))?;
        let values = insertions.into_values().flatten().collect::<String>();
        return Ok(format!("{}>{values}</{p}row>", &original[..at]));
    }
    for (pos, values) in insertions {
        edits.push((pos, pos, values.join("")))
    }
    Ok(apply_edits(original.to_owned(), edits))
}
fn patch_sheet(
    text: &str,
    changes: &[((usize, usize), Option<Cell>)],
    old: &Sheet,
    styles: &BTreeMap<(usize, usize), usize>,
) -> Result<String, Error> {
    if changes.is_empty() {
        return Ok(text.to_owned());
    }
    let d = xml(text)?;
    let data = d
        .descendants()
        .find(|n| n.has_tag_name("sheetData"))
        .ok_or(Error::Invalid("missing XLSX sheet data"))?;
    let dr = data.range();
    let original = &text[dr.clone()];
    let p = prefix(original);
    let rows: Vec<_> = data.children().filter(|n| n.has_tag_name("row")).collect();
    let mut grouped: BTreeMap<usize, Vec<_>> = BTreeMap::new();
    for v in changes {
        grouped.entry(v.0 .0).or_default().push(v.clone())
    }
    let mut edits = Vec::new();
    let mut inserts: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    for (row, items) in grouped {
        if let Some(node) = rows
            .iter()
            .copied()
            .find(|n| n.attribute("r").and_then(|x| x.parse::<usize>().ok()) == Some(row + 1))
        {
            let rr = node.range();
            edits.push((
                rr.start - dr.start,
                rr.end - dr.start,
                patch_row(text, node, &items, old, styles)?,
            ));
        } else {
            let mut cells = String::new();
            for ((r, c), cell) in items {
                if cell.is_some() {
                    cells.push_str(&cell_xml(
                        p,
                        r,
                        c,
                        cell.as_ref(),
                        styles.get(&(r, c)).map(usize::to_string).as_deref(),
                    )?);
                }
            }
            if cells.is_empty() {
                continue;
            }
            let element = format!("<{p}row r=\"{}\">{cells}</{p}row>", row + 1);
            let at = rows
                .iter()
                .find_map(|n| {
                    let nr = n.attribute("r")?.parse::<usize>().ok()?;
                    if nr > row + 1 {
                        Some(n.range().start - dr.start)
                    } else {
                        None
                    }
                })
                .or_else(|| original.rfind("</"))
                .unwrap_or(original.len());
            inserts.entry(at).or_default().push(element);
        }
    }
    let inner = if original.trim_end().ends_with("/>") && !inserts.is_empty() {
        let at = original.rfind("/>").unwrap();
        format!(
            "{}>{}</{p}sheetData>",
            &original[..at],
            inserts.into_values().flatten().collect::<String>()
        )
    } else {
        for (pos, values) in inserts {
            edits.push((pos, pos, values.join("")))
        }
        apply_edits(original.to_owned(), edits)
    };
    let mut out = text.to_owned();
    out.replace_range(dr, &inner);
    Ok(out)
}
fn patch_calc(text: &str) -> Result<String, Error> {
    let doc = xml(text)?;
    let root = doc.root_element();
    let p = prefix(&text[root.range().clone()]);
    let mut result = text.to_owned();
    if let Some(node) = root.children().find(|n| n.has_tag_name("calcPr")) {
        let range = node.range();
        let original = &text[range.clone()];
        let opening = original
            .find('>')
            .ok_or(Error::Invalid("invalid calculation settings"))?;
        let insert = if original.as_bytes().get(opening.wrapping_sub(1)) == Some(&b'/') {
            opening - 1
        } else {
            opening
        };
        let mut edits = Vec::new();
        for attr in node.attributes() {
            if matches!(attr.name(), "calcMode" | "fullCalcOnLoad" | "forceFullCalc") {
                let a = attr.range();
                edits.push((a.start - range.start, a.end - range.start, String::new()));
            }
        }
        edits.push((
            insert,
            insert,
            " calcMode=\"auto\" fullCalcOnLoad=\"1\" forceFullCalc=\"1\"".into(),
        ));
        let out = apply_edits(original.to_owned(), edits);
        result.replace_range(range, &out)
    } else {
        let end = root.range().end;
        let start = text[..end]
            .rfind("</")
            .ok_or(Error::Invalid("invalid workbook XML"))?;
        result.insert_str(
            start,
            &format!("<{p}calcPr calcMode=\"auto\" fullCalcOnLoad=\"1\" forceFullCalc=\"1\"/>"),
        )
    }
    Ok(result)
}
fn update_dimension(
    text: &str,
    changes: &[((usize, usize), Option<Cell>)],
) -> Result<String, Error> {
    let doc = xml(text)?;
    let Some(node) = doc.descendants().find(|n| n.has_tag_name("dimension")) else {
        return Ok(text.to_owned());
    };
    let Some(value) = node.attribute("ref") else {
        return Ok(text.to_owned());
    };
    let (a, b) = value.split_once(':').unwrap_or((value, value));
    let Some((mut top, mut left)) = a1(a) else {
        return Ok(text.to_owned());
    };
    let Some((mut bottom, mut right)) = a1(b) else {
        return Ok(text.to_owned());
    };
    for ((r, c), v) in changes {
        if v.is_some() {
            top = top.min(*r);
            left = left.min(*c);
            bottom = bottom.max(*r);
            right = right.max(*c)
        }
    }
    let Some(attr) = node.attributes().find(|a| a.name() == "ref") else {
        return Ok(text.to_owned());
    };
    let replacement = format!(
        "ref=\"{}{}:{}{}\"",
        col_name(left),
        top + 1,
        col_name(right),
        bottom + 1
    );
    let mut out = text.to_owned();
    out.replace_range(attr.range(), &replacement);
    Ok(out)
}
fn patch_xlsx(
    bytes: &[u8],
    old: &State,
    current: &State,
    changes: &[Vec<((usize, usize), Option<Cell>)>],
) -> Result<Vec<u8>, Error> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| Error::Invalid("invalid XLSX"))?;
    let workbook = zip_text(&mut archive, "xl/workbook.xml")?
        .ok_or(Error::Invalid("unsupported XLSX workbook location"))?;
    let relationships = zip_text(&mut archive, "xl/_rels/workbook.xml.rels")?
        .ok_or(Error::Invalid("missing workbook relationships"))?;
    let doc = xml(&workbook)?;
    let rel = xml(&relationships)?;
    let mut targets = BTreeMap::new();
    for n in rel.descendants().filter(|n| n.has_tag_name("Relationship")) {
        if let (Some(id), Some(target)) = (n.attribute("Id"), n.attribute("Target")) {
            let path = if target.starts_with('/') {
                target.trim_start_matches('/').to_owned()
            } else {
                format!("xl/{target}")
            };
            if !path.split('/').any(|part| part == "..") {
                targets.insert(id.to_string(), path);
            }
        }
    }
    let mut replacements = BTreeMap::new();
    let mut style_doc = zip_text(&mut archive, "xl/styles.xml")?;
    let mut style_cache: BTreeMap<(usize, usize, usize), usize> = BTreeMap::new();
    for (i, sheet) in old.sheets.iter().enumerate() {
        if changes[i].is_empty() && sheet.merges == current.sheets[i].merges {
            continue;
        }
        let node = doc
            .descendants()
            .find(|n| n.has_tag_name("sheet") && n.attribute("name") == Some(&sheet.name))
            .ok_or(Error::Invalid("missing XLSX sheet"))?;
        let id = node
            .attributes()
            .find(|a| a.name() == "id")
            .map(|a| a.value())
            .ok_or(Error::Invalid("missing XLSX sheet relationship"))?;
        let path = targets
            .get(id)
            .ok_or(Error::Invalid("unknown XLSX sheet relationship"))?;
        let text =
            zip_text(&mut archive, path)?.ok_or(Error::Invalid("missing XLSX sheet data"))?;
        let mut stylemap = BTreeMap::new();
        let sheet_doc = xml(&text)?;
        for (coord, after) in &changes[i] {
            let previous = sheet.cells.get(coord).map_or(0, |c| c.style);
            let next = after.as_ref().map_or(0, |c| c.style);
            if previous == next {
                continue;
            }
            if sheet_doc.descendants().any(|n| {
                n.has_tag_name("col") && n.attribute("style").is_some()
                    || n.has_tag_name("row") && n.attribute("s").is_some()
            }) {
                return Err(Error::Invalid(
                    "XLSX row or column styles cannot yet be safely edited",
                ));
            }
            let old_xf = sheet_doc
                .descendants()
                .find(|n| n.has_tag_name("c") && n.attribute("r").and_then(a1) == Some(*coord))
                .and_then(|n| n.attribute("s"))
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(0);
            let key = (old_xf, previous, next);
            let id = if let Some(id) = style_cache.get(&key) {
                *id
            } else {
                if style_cache.len() >= 1024 {
                    return Err(Error::Limit);
                }
                let doc = style_doc
                    .as_ref()
                    .ok_or(Error::Invalid("XLSX has no style definitions"))?;
                let (new_doc, id) = crate::xlsx_styles::clone_style(
                    doc,
                    old_xf,
                    &old.styles[previous],
                    &current.styles[next],
                )?;
                style_doc = Some(new_doc);
                style_cache.insert(key, id);
                id
            };
            stylemap.insert(*coord, id);
        }
        let patched = patch_sheet(&text, &changes[i], sheet, &stylemap)?;
        let patched = patch_xlsx_merges(&patched, &sheet.merges, &current.sheets[i].merges)?;
        replacements.insert(path.to_owned(), update_dimension(&patched, &changes[i])?);
    }
    if !style_cache.is_empty() {
        replacements.insert(
            "xl/styles.xml".into(),
            style_doc.ok_or(Error::Invalid("missing XLSX styles"))?,
        );
    }
    if archive.by_name("xl/calcChain.xml").is_ok() {
        for (i, group) in changes.iter().enumerate() {
            for (coord, new) in group {
                let old_formula = old.sheets[i]
                    .cells
                    .get(coord)
                    .is_some_and(|c| matches!(c.text, CellContent::Formula(_)));
                let new_formula = new
                    .as_ref()
                    .is_some_and(|c| matches!(c.text, CellContent::Formula(_)));
                let value_changed = old.sheets[i].cells.get(coord).map(|v| &v.text)
                    != new.as_ref().map(|v| &v.text);
                if value_changed && (old_formula || new_formula) {
                    return Err(Error::Invalid(
                        "Editing formulas with an existing calculation chain is not yet supported",
                    ));
                }
            }
        }
    }
    replacements.insert("xl/workbook.xml".into(), patch_calc(&workbook)?);
    let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|_| Error::Invalid("invalid XLSX entry"))?;
        let name = entry.name().to_owned();
        if name == EXTRA {
            continue;
        }
        if let Some(value) = replacements.remove(&name) {
            let opts =
                zip::write::SimpleFileOptions::default().compression_method(entry.compression());
            writer
                .start_file(name, opts)
                .map_err(|_| Error::Invalid("cannot write XLSX part"))?;
            writer.write_all(value.as_bytes())?;
        } else {
            writer
                .raw_copy_file(entry)
                .map_err(|_| Error::Invalid("cannot preserve XLSX part"))?;
        }
    }
    if !replacements.is_empty() {
        return Err(Error::Invalid("missing XLSX part"));
    }
    let out = writer
        .finish()
        .map_err(|_| Error::Invalid("cannot finish XLSX"))?
        .into_inner();
    if out.len() > LIMIT {
        return Err(Error::Limit);
    }
    Ok(out)
}

fn canonical_xml(node: roxmltree::Node<'_, '_>, out: &mut String) {
    if node.is_element() {
        out.push('<');
        out.push_str(node.tag_name().namespace().unwrap_or(""));
        out.push(':');
        out.push_str(node.tag_name().name());
        let mut attrs: Vec<_> = node
            .attributes()
            .map(|a| (a.namespace().unwrap_or(""), a.name(), a.value()))
            .collect();
        attrs.sort_unstable();
        for (ns, name, value) in attrs {
            out.push('|');
            out.push_str(ns);
            out.push(':');
            out.push_str(name);
            out.push('=');
            out.push_str(value)
        }
        out.push('>');
        for c in node.children() {
            canonical_xml(c, out)
        }
        out.push_str("</>")
    } else if node.is_text() {
        let t = node.text().unwrap_or("");
        if !t.trim().is_empty() {
            out.push_str(t)
        }
    }
}
fn verify_ods_opaque_content(before: &str, after: &str) -> Result<(), Error> {
    fn parts(text: &str) -> Result<Vec<String>, Error> {
        let d = xml(text)?;
        let mut all = Vec::new();
        for n in d.descendants().filter(|n| n.is_element()) {
            let name = n.tag_name().name();
            let ns = n.tag_name().namespace().unwrap_or("");
            let root = matches!(
                name,
                "annotation"
                    | "database-ranges"
                    | "named-expressions"
                    | "data-validations"
                    | "conditional-formats"
                    | "table-source"
            ) || ns.contains(":drawing:")
                || ns.contains(":chart:")
                || ns.contains(":form:");
            if root
                && !n.ancestors().skip(1).any(|a| {
                    a.is_element()
                        && (matches!(
                            a.tag_name().name(),
                            "annotation"
                                | "database-ranges"
                                | "named-expressions"
                                | "data-validations"
                                | "conditional-formats"
                                | "table-source"
                        ) || a.tag_name().namespace().is_some_and(|s| {
                            s.contains(":drawing:") || s.contains(":chart:") || s.contains(":form:")
                        }))
                })
            {
                let mut value = String::new();
                canonical_xml(n, &mut value);
                all.push(value)
            }
        }
        all.sort();
        Ok(all)
    }
    if parts(before)? != parts(after)? {
        return Err(Error::Invalid(
            "ODS contains unsupported content that could change during editing",
        ));
    }
    fn other_attributes(text: &str) -> Result<Vec<String>, Error> {
        let d = xml(text)?;
        let mut attrs = Vec::new();
        for n in d.descendants().filter(|n| n.is_element()) {
            if n.ancestors()
                .any(|a| a.is_element() && a.has_tag_name("automatic-styles"))
            {
                continue;
            }
            for a in n.attributes() {
                if a.name() == "style-name"
                    && (n.has_tag_name("table-cell") || n.has_tag_name("covered-table-cell"))
                {
                    continue;
                }
                if matches!(
                    a.name(),
                    "number-rows-spanned"
                        | "number-columns-spanned"
                        | "value-type"
                        | "value"
                        | "string-value"
                        | "boolean-value"
                        | "date-value"
                        | "time-value"
                        | "formula"
                        | "number-rows-repeated"
                        | "number-columns-repeated"
                ) {
                    continue;
                }
                attrs.push(format!(
                    "{}|{}|{}",
                    a.namespace().unwrap_or(""),
                    a.name(),
                    a.value()
                ));
            }
        }
        attrs.sort();
        Ok(attrs)
    }
    if other_attributes(before)? != other_attributes(after)? {
        return Err(Error::Invalid(
            "ODS contains cell or document metadata that cannot yet be preserved",
        ));
    }
    Ok(())
}

fn preserve_ods_auto_styles(before: &str, after: &str) -> Result<String, Error> {
    let a = xml(before)?;
    let b = xml(after)?;
    let left = a.descendants().find(|n| n.has_tag_name("automatic-styles"));
    let right = b.descendants().find(|n| n.has_tag_name("automatic-styles"));
    match (left, right) {
        (Some(l), Some(r)) => {
            let name = |n: roxmltree::Node<'_, '_>| {
                n.attributes()
                    .find(|a| a.name() == "name")
                    .map(|a| a.value().to_owned())
            };
            let names: std::collections::BTreeSet<_> = l
                .children()
                .filter(|n| n.is_element())
                .filter_map(name)
                .collect();
            let mut appended = String::new();
            for n in r.children().filter(|n| n.is_element()) {
                let Some(name) = name(n) else { continue };
                if !names.contains(&name) {
                    if !name.starts_with("XLS42ExternalStyle") {
                        return Err(Error::Invalid(
                            "ODS rewrite introduced unsupported automatic styles",
                        ));
                    }
                    appended.push_str(&after[n.range()]);
                }
            }
            let original = &before[l.range()];
            let mut merged = original.to_owned();
            if !appended.is_empty() {
                if original.trim_end().ends_with("/>") {
                    let i = original.rfind("/>").unwrap();
                    let p = prefix(original);
                    merged = format!("{}>{}</{p}automatic-styles>", &original[..i], appended);
                } else {
                    let i = original
                        .rfind("</")
                        .ok_or(Error::Invalid("invalid automatic styles"))?;
                    merged.insert_str(i, &appended)
                }
            }
            let mut result = after.to_owned();
            result.replace_range(r.range(), &merged);
            xml(&result)?;
            Ok(result)
        }
        (None, None) => Ok(after.to_owned()),
        _ => Err(Error::Invalid("ODS automatic styles cannot be preserved")),
    }
}

fn update_ods_style(out: &mut spreadsheet_ods::CellStyle, old: &CellStyle, new: &CellStyle) {
    use spreadsheet_ods::{
        color::Rgb,
        style::units::{Border, LineStyle},
        Length,
    };
    let rgb = |c: u32| Rgb::new((c >> 16) as u8, (c >> 8) as u8, c as u8);
    if old.bold != new.bold {
        out.textstyle_mut()
            .set_attr("fo:font-weight", if new.bold { "bold" } else { "normal" })
    }
    if old.italic != new.italic {
        out.textstyle_mut().set_attr(
            "fo:font-style",
            if new.italic { "italic" } else { "normal" },
        )
    }
    if old.underline != new.underline {
        out.set_text_underline_style(if new.underline {
            LineStyle::Solid
        } else {
            LineStyle::None
        })
    }
    if old.font != new.font {
        if new.font.is_empty() {
            out.textstyle_mut().clear_attr("style:font-name");
        } else {
            out.set_font_name(&new.font)
        }
    }
    if old.font_size != new.font_size {
        if new.font_size == 0 {
            out.textstyle_mut().clear_attr("fo:font-size");
        } else {
            out.set_font_size(Length::Pt(new.font_size as f64).into())
        }
    }
    if old.foreground != new.foreground {
        if let Some(c) = new.foreground {
            out.set_color(rgb(c))
        } else {
            out.textstyle_mut().clear_attr("fo:color");
        }
    }
    if old.background != new.background {
        if let Some(c) = new.background {
            out.set_background_color(rgb(c))
        } else {
            out.cellstyle_mut().clear_attr("fo:background-color");
        }
    }
    if old.borders != new.borders {
        for key in [
            "fo:border",
            "fo:border-top",
            "fo:border-right",
            "fo:border-bottom",
            "fo:border-left",
        ] {
            out.cellstyle_mut().clear_attr(key);
        }
        let black = Rgb::new(0, 0, 0);
        if new.borders & 1 != 0 {
            out.set_border_top(Length::Pt(1.0), Border::Solid, black)
        }
        if new.borders & 2 != 0 {
            out.set_border_right(Length::Pt(1.0), Border::Solid, black)
        }
        if new.borders & 4 != 0 {
            out.set_border_bottom(Length::Pt(1.0), Border::Solid, black)
        }
        if new.borders & 8 != 0 {
            out.set_border_left(Length::Pt(1.0), Border::Solid, black)
        }
    }
}

fn verify_ods_untouched_styles(
    original: &[u8],
    generated: &[u8],
    changes: &[Vec<((usize, usize), Option<Cell>)>],
    old: &State,
    current: &State,
) -> Result<(), Error> {
    let a = spreadsheet_ods::read_ods_buf(original)
        .map_err(|_| Error::Invalid("invalid ODS source"))?;
    let b = spreadsheet_ods::read_ods_buf(generated)
        .map_err(|_| Error::Invalid("invalid generated ODS"))?;
    for (i, sheet) in old.sheets.iter().enumerate() {
        let changed: std::collections::BTreeSet<_> = changes[i]
            .iter()
            .filter_map(|(coord, after)| {
                let previous = sheet.cells.get(coord).map_or(0, |c| c.style);
                let next = after.as_ref().map_or(0, |c| c.style);
                (previous != next).then_some(*coord)
            })
            .collect();
        let (ar, ac) = a.sheet(i).used_grid_size();
        let (br, bc) = b.sheet(i).used_grid_size();
        let rows = sheet.rows.max(ar as usize).max(br as usize);
        let cols = sheet.cols.max(ac as usize).max(bc as usize);
        if rows > MAX_ROWS || cols > MAX_COLS {
            return Err(Error::Invalid(
                "ODS style grid exceeds safe preservation limits",
            ));
        }
        for r in 0..rows {
            for c in 0..cols {
                let merge_changed = sheet
                    .merges
                    .iter()
                    .chain(current.sheets[i].merges.iter())
                    .any(|m| {
                        m.top == r
                            && m.left == c
                            && sheet.merges.contains(m) != current.sheets[i].merges.contains(m)
                    });
                if !merge_changed
                    && (a.sheet(i).row_span(r as u32, c as u32)
                        != b.sheet(i).row_span(r as u32, c as u32)
                        || a.sheet(i).col_span(r as u32, c as u32)
                            != b.sheet(i).col_span(r as u32, c as u32))
                {
                    return Err(Error::Invalid("ODS rewriting changed an unedited merge"));
                }
                if changed.contains(&(r, c)) {
                    continue;
                }
                let before = a.sheet(i).cellstyle(r as u32, c as u32).map(|v| v.as_ref());
                let after = b.sheet(i).cellstyle(r as u32, c as u32).map(|v| v.as_ref());
                if before != after {
                    return Err(Error::Invalid(
                        "ODS rewriting changed an unedited cell style",
                    ));
                }
            }
        }
    }
    Ok(())
}

fn verify_ods_repeated_styles(content: &str) -> Result<(), Error> {
    let d = xml(content)?;
    for n in d.descendants().filter(|n| n.is_element()) {
        let repeated = n
            .attributes()
            .find(|a| matches!(a.name(), "number-columns-repeated" | "number-rows-repeated"))
            .and_then(|a| a.value().parse::<usize>().ok())
            .unwrap_or(1);
        if repeated > 1
            && (n
                .attribute((
                    "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
                    "style-name",
                ))
                .is_some()
                || n.descendants().any(|d| {
                    d.is_element()
                        && d.attribute((
                            "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
                            "style-name",
                        ))
                        .is_some()
                }))
        {
            return Err(Error::Invalid(
                "ODS contains repeated styled cells that cannot yet be safely rewritten",
            ));
        }
    }
    Ok(())
}
fn patch_xlsx_merges(text: &str, old: &[Range], new: &[Range]) -> Result<String, Error> {
    if old == new {
        return Ok(text.to_owned());
    }
    let doc = xml(text)?;
    let root = doc.root_element();
    let element = root.children().find(|n| n.has_tag_name("mergeCells"));
    let prefix = prefix(&text[root.range()]);
    let format_ref = |r: &Range| {
        format!(
            "{}{}:{}{}",
            col_name(r.left),
            r.top + 1,
            col_name(r.right),
            r.bottom + 1
        )
    };
    let mut items = Vec::new();
    if let Some(el) = element {
        if el
            .children()
            .any(|n| n.is_element() && !n.has_tag_name("mergeCell"))
            || el.attributes().any(|a| a.name() != "count")
        {
            return Err(Error::Invalid(
                "extended XLSX merge metadata cannot yet be edited",
            ));
        }
        for node in el.children().filter(|n| n.has_tag_name("mergeCell")) {
            if node.attributes().any(|a| a.name() != "ref") {
                return Err(Error::Invalid(
                    "extended XLSX merge metadata cannot yet be edited",
                ));
            }
            let Some(reference) = node.attribute("ref") else {
                return Err(Error::Invalid("invalid XLSX merge"));
            };
            let parsed = reference
                .split_once(':')
                .and_then(|(a, b)| Some((a1(a)?, a1(b)?)))
                .map(|((top, left), (bottom, right))| Range {
                    top,
                    left,
                    bottom,
                    right,
                });
            if parsed.is_none_or(|r| !old.contains(&r) || new.contains(&r)) {
                items.push(text[node.range()].to_owned())
            }
        }
    }
    for m in new {
        if !old.contains(m) {
            items.push(format!("<{prefix}mergeCell ref=\"{}\"/>", format_ref(m)))
        }
    }
    let mut out = text.to_owned();
    let replacement = if items.is_empty() {
        String::new()
    } else {
        format!(
            "<{prefix}mergeCells count=\"{}\">{}</{prefix}mergeCells>",
            items.len(),
            items.join("")
        )
    };
    if let Some(el) = element {
        out.replace_range(el.range(), &replacement)
    } else if !replacement.is_empty() {
        let insert = root
            .children()
            .filter(|n| {
                n.is_element()
                    && matches!(
                        n.tag_name().name(),
                        "sheetData"
                            | "sheetCalcPr"
                            | "sheetProtection"
                            | "protectedRanges"
                            | "scenarios"
                            | "autoFilter"
                            | "sortState"
                            | "dataConsolidate"
                            | "customSheetViews"
                    )
            })
            .map(|n| n.range().end)
            .max()
            .ok_or(Error::Invalid("missing XLSX sheet data"))?;
        out.insert_str(insert, &replacement)
    }
    Ok(out)
}
