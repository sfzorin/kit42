//! Strict RTF reader for plain/styled paragraphs and page settings.
use super::*;
use std::collections::HashMap;
#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum Destination {
    #[default]
    Body,
    Header,
    Footer,
}
#[derive(Clone, Default)]
struct Group {
    destination: Destination,
    style: TextStyle,
    link: Option<String>,
    font_table: bool,
    font_id: Option<i32>,
    color_table: bool,
    skip: bool,
    optional_destination: bool,
    uc: usize,
}
fn fail(s: &str) -> Error {
    Error::Invalid(s.into())
}
struct Reader {
    groups: Vec<Group>,
    fonts: HashMap<i32, String>,
    font_text: Vec<u16>,
    pending: Vec<u16>,
    runs: Vec<Run>,
    blocks: Vec<Block>,
    para: ParagraphStyle,
    page: PageSettings,
    next_id: u64,
    colors: Vec<Option<u32>>,
    color: u32,
    color_set: bool,
    encoding: &'static encoding_rs::Encoding,
    fallback: usize,
    projection: bool,
    default_font: i32,
    image_pending: bool,
    lists: std::collections::BTreeMap<u64, Vec<bool>>,
    list_overrides: std::collections::BTreeMap<u64, u64>,
    list_index: Option<u64>,
    list_level: u8,
    marker_text: bool,
    in_table: bool,
    table_rows: Vec<Vec<Cell>>,
    table_cells: Vec<Cell>,
    cell_paragraphs: Vec<Paragraph>,
    header: Vec<Paragraph>,
    footer: Vec<Paragraph>,
    fields: Vec<Field>,
    pending_fields: Vec<(usize, FieldKind)>,
}
impl Reader {
    fn flush(&mut self) -> Result<(), Error> {
        if !self.pending.is_empty() {
            let text =
                String::from_utf16(&self.pending).map_err(|_| fail("invalid RTF Unicode"))?;
            self.pending.clear();
            self.runs.push(Run {
                text,
                style: self
                    .groups
                    .last()
                    .ok_or_else(|| fail("unbalanced RTF"))?
                    .style
                    .clone(),
                link: self.groups.last().and_then(|g| g.link.clone()),
            });
        }
        Ok(())
    }
    fn emit(&mut self, u: u16) -> Result<(), Error> {
        let g = self
            .groups
            .last()
            .ok_or_else(|| fail("RTF outside group"))?;
        if g.skip {
            return Ok(());
        }
        if g.color_table {
            if u == b';' as u16 {
                self.colors.push(if self.color_set {
                    Some(self.color)
                } else {
                    None
                });
                self.color = 0;
                self.color_set = false;
            } else if !(u as u8).is_ascii_whitespace() {
                return Err(fail("invalid color table"));
            }
            return Ok(());
        }
        if g.font_table {
            if u == b';' as u16 {
                let id = g.font_id.ok_or_else(|| fail("font without id"))?;
                let name =
                    String::from_utf16(&self.font_text).map_err(|_| fail("invalid font name"))?;
                self.font_text.clear();
                self.fonts.insert(id, name);
            } else {
                self.font_text.push(u);
            }
        } else {
            self.pending.push(u);
        }
        Ok(())
    }
    fn field(&mut self, kind: FieldKind) -> Result<(), Error> {
        let prefix: usize = self.runs.iter().map(|r| r.text.len()).sum();
        let pending =
            String::from_utf16(&self.pending).map_err(|_| fail("invalid field position"))?;
        self.pending_fields.push((prefix + pending.len(), kind));
        Ok(())
    }
    fn flush_table(&mut self) {
        if !self.table_rows.is_empty() {
            let id = self.next_id;
            self.next_id += 1;
            self.blocks.push(Block::Table(Table {
                id,
                rows: std::mem::take(&mut self.table_rows),
            }));
        }
    }
    fn paragraph(&mut self) -> Result<(), Error> {
        self.flush()?;
        if self.image_pending {
            self.image_pending = false;
            if !self.runs.is_empty() {
                return Err(Error::Unsupported("picture mixed with text".into()));
            }
            return Ok(());
        }
        if self.marker_text && self.para.list.is_none() {
            return Err(Error::Unsupported("RTF legacy list marker".into()));
        }
        self.marker_text = false;
        let id = self.next_id;
        self.next_id += 1;
        let paragraph = Paragraph {
            id,
            style: self.para.clone(),
            runs: std::mem::take(&mut self.runs),
        };
        for (offset, kind) in std::mem::take(&mut self.pending_fields) {
            let field_id = self.next_id;
            self.next_id += 1;
            self.fields.push(Field {
                id: field_id,
                at: Position {
                    paragraph: id,
                    offset,
                },
                kind,
            });
        }
        match self
            .groups
            .last()
            .map(|g| g.destination)
            .unwrap_or_default()
        {
            Destination::Header => self.header.push(paragraph),
            Destination::Footer => self.footer.push(paragraph),
            Destination::Body => {
                if self.in_table {
                    self.cell_paragraphs.push(paragraph)
                } else {
                    self.flush_table();
                    self.blocks.push(Block::Paragraph(paragraph))
                }
            }
        };
        Ok(())
    }
    fn update_list(&mut self) -> Result<(), Error> {
        self.para.list = if let Some(ls) = self.list_index {
            let id = *self
                .list_overrides
                .get(&ls)
                .ok_or_else(|| fail("unknown list override"))?;
            let numbered = *self
                .lists
                .get(&id)
                .and_then(|v| v.get(self.list_level as usize))
                .ok_or_else(|| fail("unknown list level"))?;
            Some(ListMarker {
                id,
                level: self.list_level,
                numbered,
            })
        } else {
            None
        };
        Ok(())
    }
    fn control(&mut self, word: &str, arg: Option<i32>) -> Result<(), Error> {
        if self.groups.last().ok_or_else(|| fail("group"))?.skip {
            return Ok(());
        }
        if self.groups.last().unwrap().optional_destination {
            if matches!(word, "generator" | "info" | "xmlnstbl" | "fldinst") {
                let g = self.groups.last_mut().unwrap();
                g.skip = true;
                g.optional_destination = false;
                return Ok(());
            }
            return Err(Error::Unsupported(format!(
                "RTF optional destination {word}"
            )));
        }
        if matches!(word, "generator" | "info") {
            self.groups.last_mut().unwrap().skip = true;
            return Ok(());
        }
        if word == "colortbl" {
            self.groups.last_mut().unwrap().color_table = true;
            return Ok(());
        }
        if self.groups.last().unwrap().color_table {
            let n = u32::try_from(arg.ok_or_else(|| fail("color"))?).map_err(|_| fail("color"))?;
            if n > 255 {
                return Err(fail("color"));
            }
            match word {
                "red" => self.color = (self.color & 0x00ffff) | (n << 16),
                "green" => self.color = (self.color & 0xff00ff) | (n << 8),
                "blue" => self.color = (self.color & 0xffff00) | n,
                _ => return Err(Error::Unsupported(format!("RTF color control {word}"))),
            }
            self.color_set = true;
            return Ok(());
        }
        if word == "fonttbl" {
            self.groups
                .last_mut()
                .ok_or_else(|| fail("group"))?
                .font_table = true;
            return Ok(());
        }
        if self.groups.last().ok_or_else(|| fail("group"))?.font_table {
            if word == "f" {
                self.groups.last_mut().unwrap().font_id = arg;
            } else if word == "fcharset" && !matches!(arg, Some(0 | 1)) {
                return Err(Error::Unsupported("RTF font-specific codepage".into()));
            } else if !matches!(
                word,
                "fnil"
                    | "froman"
                    | "fswiss"
                    | "fmodern"
                    | "fscript"
                    | "fdecor"
                    | "ftech"
                    | "fbidi"
                    | "fcharset"
                    | "fprq"
                    | "cpg"
            ) {
                return Err(Error::Unsupported(format!("RTF font control {word}")));
            }
            return Ok(());
        }
        match word {
            "header" => self.groups.last_mut().unwrap().destination = Destination::Header,
            "footer" => self.groups.last_mut().unwrap().destination = Destination::Footer,
            "chpgn" => self.field(FieldKind::PageNumber)?,
            "rtf" if arg == Some(1) => {}
            "ansi" => {}
            "field" | "fldrslt" | "flddirty" => {}
            "uc" => {
                let n = usize::try_from(arg.ok_or_else(|| fail("uc"))?).map_err(|_| fail("uc"))?;
                if n > 16 {
                    return Err(fail("uc"));
                }
                self.groups.last_mut().unwrap().uc = n;
            }
            "ansicpg" => {
                let n = arg.ok_or_else(|| fail("codepage"))?;
                let name = format!("windows-{n}");
                self.encoding = encoding_rs::Encoding::for_label(name.as_bytes())
                    .ok_or_else(|| Error::Unsupported(format!("RTF codepage {n}")))?;
            }
            "deff" => self.default_font = arg.ok_or_else(|| fail("default font"))?,
            "deflang" | "viewkind" | "viewscale" | "nouicompat" | "fet" => {}
            "lang" | "langfe" if self.projection => {}
            "cf" | "highlight" => {
                self.flush()?;
                let n = usize::try_from(arg.ok_or_else(|| fail("color index"))?)
                    .map_err(|_| fail("color index"))?;
                let c = *self.colors.get(n).ok_or_else(|| fail("unknown color"))?;
                let t = &mut self.groups.last_mut().unwrap().style;
                if word == "cf" {
                    t.color = c
                } else {
                    t.highlight = c
                }
            }
            "plain" => {
                self.flush()?;
                let mut style = TextStyle::default();
                if let Some(font) = self.fonts.get(&self.default_font) {
                    style.font = font.clone();
                }
                self.groups.last_mut().unwrap().style = style;
            }
            "f" => {
                self.flush()?;
                let n = arg.ok_or_else(|| fail("font index"))?;
                self.groups.last_mut().unwrap().style.font = self
                    .fonts
                    .get(&n)
                    .ok_or_else(|| fail("unknown font"))?
                    .clone();
            }
            "fs" => {
                self.flush()?;
                self.groups.last_mut().unwrap().style.size_half_points =
                    u16::try_from(arg.ok_or_else(|| fail("font size"))?)
                        .map_err(|_| fail("font size"))?;
            }
            "b" | "i" | "ul" | "strike" => {
                self.flush()?;
                let on = arg.unwrap_or(1) != 0;
                let t = &mut self.groups.last_mut().unwrap().style;
                match word {
                    "b" => t.bold = on,
                    "i" => t.italic = on,
                    "ul" => t.underline = on,
                    _ => t.strike = on,
                }
            }
            "trowd" => {
                if self.in_table {
                    return Err(fail("nested table"));
                }
                self.in_table = true;
                self.table_cells.clear();
                self.cell_paragraphs.clear();
            }
            "cellx" if self.in_table => {}
            "intbl" if self.in_table => {}
            "cell" if self.in_table => {
                self.flush()?;
                if !self.runs.is_empty() || self.cell_paragraphs.is_empty() {
                    self.paragraph()?;
                }
                self.table_cells.push(Cell {
                    paragraphs: std::mem::take(&mut self.cell_paragraphs),
                    row_span: 1,
                    col_span: 1,
                    border: None,
                    fill: None,
                });
            }
            "row" if self.in_table => {
                if !self.runs.is_empty()
                    || !self.cell_paragraphs.is_empty()
                    || self.table_cells.is_empty()
                {
                    return Err(fail("incomplete table row"));
                }
                self.table_rows.push(std::mem::take(&mut self.table_cells));
                self.in_table = false;
            }
            "tab" => self.emit(9)?,
            "par" => self.paragraph()?,
            "pard" => {
                self.para = ParagraphStyle::default();
                self.list_index = None;
                self.list_level = 0;
            }
            "ls" => {
                let n = u64::try_from(arg.ok_or_else(|| fail("list index"))?)
                    .map_err(|_| fail("list index"))?;
                self.list_index = if n == 0 { None } else { Some(n) };
                self.update_list()?;
            }
            "ilvl" => {
                self.list_level = u8::try_from(arg.ok_or_else(|| fail("list level"))?)
                    .map_err(|_| fail("list level"))?;
                self.update_list()?;
            }
            "keepn" => self.para.keep_with_next = arg.unwrap_or(1) != 0,
            "keep" => self.para.keep_lines = arg.unwrap_or(1) != 0,
            "pagebb" => self.para.page_break_before = arg.unwrap_or(1) != 0,
            "outlinelevel" => {
                self.para.outline_level = Some(
                    u8::try_from(arg.ok_or_else(|| fail("outline level"))?)
                        .map_err(|_| fail("outline level"))?,
                )
            }
            "ql" => self.para.alignment = Alignment::Left,
            "qc" => self.para.alignment = Alignment::Center,
            "qr" => self.para.alignment = Alignment::Right,
            "qj" => self.para.alignment = Alignment::Justify,
            "tx" => {
                let n = arg.ok_or_else(|| fail("tab stop"))?;
                if n < 0 {
                    return Err(fail("tab stop"));
                }
                self.para.tabs_twips.push(n);
            }
            "li" => self.para.left_twips = arg.ok_or_else(|| fail("indent"))?,
            "ri" => self.para.right_twips = arg.ok_or_else(|| fail("indent"))?,
            "fi" => self.para.first_line_twips = arg.ok_or_else(|| fail("indent"))?,
            "sb" => {
                self.para.before_twips = u32::try_from(arg.ok_or_else(|| fail("spacing"))?)
                    .map_err(|_| fail("spacing"))?
            }
            "sa" => {
                self.para.after_twips = u32::try_from(arg.ok_or_else(|| fail("spacing"))?)
                    .map_err(|_| fail("spacing"))?
            }
            "sl" => self.para.line_twips = arg.ok_or_else(|| fail("spacing"))?,
            "paperw" | "paperh" | "margl" | "margr" | "margt" | "margb" | "headery" | "footery" => {
                let n = u32::try_from(arg.ok_or_else(|| fail("page geometry"))?)
                    .map_err(|_| fail("page geometry"))?;
                match word {
                    "paperw" => self.page.width_twips = n,
                    "paperh" => self.page.height_twips = n,
                    "margl" => self.page.margin_left = n,
                    "margr" => self.page.margin_right = n,
                    "margt" => self.page.margin_top = n,
                    "margb" => self.page.margin_bottom = n,
                    "headery" => self.page.header_distance_twips = n,
                    _ => self.page.footer_distance_twips = n,
                }
            }
            _ => return Err(Error::Unsupported(format!("RTF control {word}"))),
        }
        Ok(())
    }
}
pub(super) fn decode(bytes: &[u8]) -> Result<State, Error> {
    decode_inner(bytes, false)
}
pub(super) fn decode_projection(bytes: &[u8]) -> Result<State, Error> {
    decode_inner(bytes, true)
}
fn decode_inner(bytes: &[u8], projection: bool) -> Result<State, Error> {
    if !bytes.starts_with(b"{\\rtf1") {
        return Err(fail("missing RTF header"));
    }
    let mut r = Reader {
        groups: vec![],
        fonts: HashMap::new(),
        font_text: vec![],
        pending: vec![],
        runs: vec![],
        blocks: vec![],
        para: ParagraphStyle::default(),
        page: PageSettings::default(),
        next_id: 1,
        colors: vec![],
        color: 0,
        color_set: false,
        encoding: encoding_rs::WINDOWS_1252,
        fallback: 0,
        projection,
        default_font: 0,
        image_pending: false,
        lists: Default::default(),
        list_overrides: Default::default(),
        list_index: None,
        list_level: 0,
        marker_text: false,
        in_table: false,
        table_rows: vec![],
        table_cells: vec![],
        cell_paragraphs: vec![],
        header: vec![],
        footer: vec![],
        fields: vec![],
        pending_fields: vec![],
    };
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        i += 1;
        match b {
            b'{' => {
                if bytes[i..].starts_with(b"\\*\\listtable") {
                    let start = i - 1;
                    let end = super::rtf_lists::group_end(bytes, start)?;
                    r.lists = super::rtf_lists::definitions(&bytes[start..end])?;
                    i = end;
                    continue;
                }
                if bytes[i..].starts_with(b"\\*\\listoverridetable") {
                    let start = i - 1;
                    let end = super::rtf_lists::group_end(bytes, start)?;
                    r.list_overrides = super::rtf_lists::overrides(&bytes[start..end])?;
                    i = end;
                    continue;
                }
                if bytes[i..].starts_with(b"\\pntext") {
                    let start = i - 1;
                    let end = super::rtf_lists::group_end(bytes, start)?;
                    r.marker_text = true;
                    i = end;
                    continue;
                }
                if bytes[i..].starts_with(b"\\pict") {
                    r.flush()?;
                    if !r.runs.is_empty() || r.image_pending {
                        return Err(Error::Unsupported("picture mixed with text".into()));
                    }
                    let start = i - 1;
                    let end = bytes[i..]
                        .iter()
                        .position(|b| *b == b'}')
                        .map(|n| i + n + 1)
                        .ok_or_else(|| fail("unterminated picture"))?;
                    let image = super::rtf_picture::parse(&bytes[start..end], r.next_id)?;
                    r.next_id += 1;
                    r.blocks.push(Block::Image(image));
                    r.image_pending = true;
                    i = end;
                    continue;
                }
                if !r.groups.is_empty() {
                    r.flush()?;
                }
                let mut g = r.groups.last().cloned().unwrap_or_else(|| Group {
                    uc: 1,
                    ..Group::default()
                });
                if bytes[i..].starts_with(b"\\field") {
                    let start = i - 1;
                    let end = super::rtf_lists::group_end(bytes, start)?;
                    match super::rtf_field::parse(&bytes[start..end])? {
                        super::rtf_field::Parsed::Hyperlink(url) => g.link = Some(url),
                        super::rtf_field::Parsed::PageNumber => {
                            r.field(FieldKind::PageNumber)?;
                            i = end;
                            continue;
                        }
                        super::rtf_field::Parsed::PageCount => {
                            r.field(FieldKind::PageCount)?;
                            i = end;
                            continue;
                        }
                    }
                }
                r.groups.push(g)
            }
            b'}' => {
                r.flush()?;
                let ended = r.groups.pop().ok_or_else(|| fail("unbalanced RTF"))?;
                if ended.font_table && r.groups.last().is_some_and(|g| !g.font_table) {
                    if let Some(font) = r.fonts.get(&r.default_font) {
                        r.groups.last_mut().unwrap().style.font = font.clone();
                    }
                }
                if r.groups.is_empty() {
                    if bytes[i..].iter().any(|b| !b.is_ascii_whitespace()) {
                        return Err(fail("trailing RTF data"));
                    }
                    break;
                }
            }
            b'\\' => {
                if i >= bytes.len() {
                    return Err(fail("truncated RTF escape"));
                }
                let c = bytes[i];
                i += 1;
                if c == b'*' {
                    r.groups
                        .last_mut()
                        .ok_or_else(|| fail("group"))?
                        .optional_destination = true;
                    continue;
                }
                if c == b'\'' {
                    if i + 2 > bytes.len() {
                        return Err(fail("hex escape"));
                    }
                    let hex =
                        std::str::from_utf8(&bytes[i..i + 2]).map_err(|_| fail("hex escape"))?;
                    let v = u8::from_str_radix(hex, 16).map_err(|_| fail("hex escape"))?;
                    i += 2;
                    if r.fallback > 0 {
                        r.fallback -= 1;
                        continue;
                    }
                    let data = [v];
                    let (decoded, _, bad) = r.encoding.decode(&data);
                    if bad {
                        return Err(fail("invalid codepage byte"));
                    }
                    for u in decoded.encode_utf16() {
                        r.emit(u)?
                    }
                    continue;
                }
                if matches!(c, b'\\' | b'{' | b'}') {
                    if r.fallback > 0 {
                        r.fallback -= 1;
                    } else {
                        r.emit(c as u16)?;
                    }
                    continue;
                }
                if !c.is_ascii_alphabetic() {
                    return Err(Error::Unsupported("RTF control symbol".into()));
                }
                let start = i - 1;
                while i < bytes.len() && bytes[i].is_ascii_alphabetic() {
                    i += 1
                }
                let word = std::str::from_utf8(&bytes[start..i]).map_err(|_| fail("control"))?;
                let begin = i;
                if i < bytes.len() && bytes[i] == b'-' {
                    i += 1
                }
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1
                }
                let arg = if i > begin {
                    Some(
                        std::str::from_utf8(&bytes[begin..i])
                            .map_err(|_| fail("number"))?
                            .parse::<i32>()
                            .map_err(|_| fail("number"))?,
                    )
                } else {
                    None
                };
                if i < bytes.len() && bytes[i] == b' ' {
                    i += 1
                }
                if word == "u" {
                    let n = arg.ok_or_else(|| fail("Unicode control"))?;
                    if !(-32768..=32767).contains(&n) {
                        return Err(fail("Unicode value"));
                    }
                    r.emit(n as i16 as u16)?;
                    r.fallback = r.groups.last().ok_or_else(|| fail("group"))?.uc;
                } else {
                    r.control(word, arg)?;
                }
            }
            b'\r' | b'\n' => {}
            b => {
                if r.fallback > 0 {
                    r.fallback -= 1;
                    continue;
                }
                if b.is_ascii() {
                    r.emit(b as u16)?
                } else {
                    let data = [b];
                    let (decoded, _, bad) = r.encoding.decode(&data);
                    if bad {
                        return Err(fail("invalid codepage byte"));
                    }
                    for u in decoded.encode_utf16() {
                        r.emit(u)?
                    }
                }
            }
        }
    }
    if r.in_table {
        return Err(fail("unterminated table"));
    }
    r.flush_table();
    if !r.groups.is_empty() {
        return Err(fail("unbalanced RTF"));
    }
    if !r.pending.is_empty() || !r.runs.is_empty() {
        return Err(Error::Unsupported("RTF unterminated paragraph".into()));
    }
    if r.blocks.is_empty() {
        return Err(fail("no paragraphs"));
    }
    Ok(State {
        blocks: r.blocks,
        sections: vec![Section {
            start_block: 0,
            page: r.page,
            header: r.header,
            footer: r.footer,
        }],
        next_id: r.next_id,
        fields: r.fields,
        ..State::default()
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn table_rows_and_cells_round_trip() {
        let mut s = State::default();
        let p = Paragraph {
            id: 3,
            style: ParagraphStyle::default(),
            runs: vec![Run {
                text: "cell".into(),
                style: TextStyle::default(),
                link: None,
            }],
        };
        s.blocks.push(Block::Table(Table {
            id: 2,
            rows: vec![vec![Cell {
                paragraphs: vec![p],
                row_span: 1,
                col_span: 1,
                border: None,
                fill: None,
            }]],
        }));
        s.next_id = 4;
        let bytes = super::super::rtf::rtf_export(&s).unwrap();
        let reopened = decode(&bytes).unwrap();
        let Block::Table(t) = &reopened.blocks[1] else {
            panic!()
        };
        assert_eq!(t.rows[0][0].paragraphs[0].runs[0].text, "cell");
    }
    #[test]
    fn list_table_and_override_round_trip() {
        let mut s = State::default();
        let Block::Paragraph(p) = &mut s.blocks[0] else {
            panic!()
        };
        p.runs[0].text = "item".into();
        p.style.list = Some(ListMarker {
            id: 7,
            level: 1,
            numbered: true,
        });
        let bytes = super::super::rtf::rtf_export(&s).unwrap();
        let reopened = decode(&bytes).unwrap();
        let Block::Paragraph(p) = &reopened.blocks[0] else {
            panic!()
        };
        assert_eq!(
            p.style.list,
            Some(ListMarker {
                id: 7,
                level: 1,
                numbered: true
            })
        );
    }
    #[test]
    fn picture_destination_round_trip() {
        let mut s = State::default();
        s.blocks.push(Block::Image(Image {
            id: 2,
            mime: "image/png".into(),
            data: vec![137, 80, 78, 71, 13, 10, 26, 10, 0, 0],
            width_twips: 1440,
            height_twips: 720,
            alt: String::new(),
        }));
        s.next_id = 3;
        let bytes = super::super::rtf::rtf_export(&s).unwrap();
        let reopened = decode(&bytes).unwrap();
        let Block::Image(i) = &reopened.blocks[1] else {
            panic!()
        };
        assert_eq!((i.width_twips, i.height_twips), (1440, 720));
        assert_eq!(i.data, vec![137, 80, 78, 71, 13, 10, 26, 10, 0, 0]);
    }
    #[test]
    fn windows_rtf_header_colors_and_codepage() {
        let bytes=br"{\rtf1\ansi\ansicpg1252\deff0\deflang1033{\fonttbl{\f0\fnil\fcharset0 Arial;}}{\colortbl;\red51\green102\blue153;}{\*\generator Test;}\viewkind4\uc1\pard\cf1\f0\fs24 Caf\'e9 \u1046?\par}";
        let s = decode(bytes).unwrap();
        let Block::Paragraph(p) = &s.blocks[0] else {
            panic!()
        };
        assert_eq!(
            p.runs.iter().map(|r| r.text.as_str()).collect::<String>(),
            "Café Ж"
        );
        assert_eq!(p.runs.last().unwrap().style.color, Some(0x336699));
    }
    #[test]
    fn read_own_styled_unicode_export() {
        let mut s = State::default();
        if let Block::Paragraph(p) = &mut s.blocks[0] {
            p.runs[0].text = "é 😀".into();
            p.runs[0].style.bold = true;
            p.style.alignment = Alignment::Center;
        }
        let bytes = super::super::rtf::rtf_export(&s).unwrap();
        let reopened = decode(&bytes).unwrap();
        let (Block::Paragraph(a), Block::Paragraph(b)) = (&s.blocks[0], &reopened.blocks[0]) else {
            panic!()
        };
        assert_eq!(a.runs, b.runs);
        assert_eq!(a.style, b.style);
        assert_eq!(s.sections[0].page, reopened.sections[0].page);
    }
}
