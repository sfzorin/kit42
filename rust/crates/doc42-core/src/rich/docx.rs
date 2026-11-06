//! Strict WordprocessingML subset: paragraphs, direct run formatting and page geometry.
use super::*;
mod headers;
mod images;
mod numbering;
mod styles;
use std::io::{Cursor, Read, Write};
use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};
const W: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
fn bad(e: impl std::fmt::Display) -> Error {
    Error::Invalid(e.to_string())
}
fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn package(files: &std::collections::BTreeMap<String, Vec<u8>>) -> Result<Vec<u8>, Error> {
    let mut out = ZipWriter::new(Cursor::new(Vec::new()));
    for (name, content) in files {
        out.start_file(
            name,
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated),
        )
        .map_err(bad)?;
        out.write_all(content).map_err(bad)?;
    }
    Ok(out.finish().map_err(bad)?.into_inner())
}
pub(super) fn encode(s: &State) -> Result<Vec<u8>, Error> {
    if s.sections.len() != 1
        || !s.comments.is_empty()
        || !s.footnotes.is_empty()
        || !s.revisions.is_empty()
        || s.blocks
            .iter()
            .any(|b| !matches!(b, Block::Paragraph(_) | Block::Table(_) | Block::Image(_)))
    {
        return Err(Error::Unsupported(
            "DOCX tables, images, section breaks and annotations".into(),
        ));
    }
    let header_ids: std::collections::HashSet<_> = s.sections[0]
        .header
        .iter()
        .chain(&s.sections[0].footer)
        .map(|p| p.id)
        .collect();
    if s.fields.iter().any(|f| {
        !header_ids.contains(&f.at.paragraph)
            || !matches!(f.kind, FieldKind::PageNumber | FieldKind::PageCount)
    }) {
        return Err(Error::Unsupported("DOCX body or custom field".into()));
    }
    let mut body = String::new();
    for b in &s.blocks {
        match b {
            Block::Paragraph(p) => write_paragraph(&mut body, p, &s.fields)?,
            Block::Table(t) => {
                body.push_str("<w:tbl>");
                for row in &t.rows {
                    body.push_str("<w:tr>");
                    for cell in row {
                        if cell.row_span != 1
                            || cell.col_span != 1
                            || cell.border.is_some()
                            || cell.fill.is_some()
                            || cell.paragraphs.is_empty()
                        {
                            return Err(Error::Unsupported(
                                "DOCX merged, bordered, shaded or empty table cells".into(),
                            ));
                        }
                        body.push_str("<w:tc>");
                        for p in &cell.paragraphs {
                            write_paragraph(&mut body, p, &s.fields)?;
                        }
                        body.push_str("</w:tc>");
                    }
                    body.push_str("</w:tr>");
                }
                body.push_str("</w:tbl>");
            }
            Block::Image(image) => body.push_str(&images::paragraph(image)?),
            _ => return Err(Error::Unsupported("DOCX section break".into())),
        }
    }
    let p = &s.sections[0].page;
    if p.columns != 1 {
        return Err(Error::Unsupported("DOCX columns".into()));
    }
    let mut parts = s.docx_parts.clone();
    let refs = headers::write(&mut parts, &s.sections[0], &s.fields)?;
    body.push_str(&format!("<w:sectPr>{refs}<w:pgSz w:w=\"{}\" w:h=\"{}\"/><w:pgMar w:left=\"{}\" w:right=\"{}\" w:top=\"{}\" w:bottom=\"{}\" w:header=\"{}\" w:footer=\"{}\"/></w:sectPr>",p.width_twips,p.height_twips,p.margin_left,p.margin_right,p.margin_top,p.margin_bottom,p.header_distance_twips,p.footer_distance_twips));
    let doc=format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"{W}\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>{body}</w:body></w:document>");
    let ct="<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".to_owned();
    let rel="<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".to_owned();
    for name in parts.keys() {
        if !safe_part_name(name) {
            return Err(Error::Unsupported(format!("DOCX package part {name}")));
        }
    }
    parts
        .entry("[Content_Types].xml".into())
        .or_insert_with(|| ct.into_bytes());
    parts
        .entry("_rels/.rels".into())
        .or_insert_with(|| rel.into_bytes());
    numbering::add_parts(&mut parts, &s.blocks)?;
    images::add_parts(&mut parts, &s.blocks)?;
    parts.insert("word/document.xml".into(), doc.into_bytes());
    package(&parts)
}
fn write_paragraph(body: &mut String, p: &Paragraph, fields: &[Field]) -> Result<(), Error> {
    if !p.style.odt_extra.is_empty() || p.runs.iter().any(|r| !r.style.odt_extra.is_empty()) {
        return Err(Error::Unsupported(
            "DOCX cannot preserve OpenDocument style attributes".into(),
        ));
    }
    let list_ref = p
        .style
        .list
        .as_ref()
        .map(|list| {
            format!(
                "<w:numPr><w:ilvl w:val=\"{}\"/><w:numId w:val=\"{}\"/></w:numPr>",
                list.level, list.id
            )
        })
        .unwrap_or_default();
    let a = match p.style.alignment {
        Alignment::Left => "left",
        Alignment::Center => "center",
        Alignment::Right => "right",
        Alignment::Justify => "both",
    };
    let style_ref = p
        .style
        .source_style
        .as_ref()
        .map(|name| format!("<w:pStyle w:val=\"{}\"/>", esc(name)))
        .unwrap_or_default();
    let extras = format!(
        "<w:keepNext w:val=\"{}\"/><w:keepLines w:val=\"{}\"/><w:pageBreakBefore w:val=\"{}\"/>{}",
        u8::from(p.style.keep_with_next),
        u8::from(p.style.keep_lines),
        u8::from(p.style.page_break_before),
        p.style
            .outline_level
            .map(|v| format!("<w:outlineLvl w:val=\"{v}\"/>"))
            .unwrap_or_default()
    );
    let tabs = if p.style.tabs_twips.is_empty() {
        String::new()
    } else {
        format!(
            "<w:tabs>{}</w:tabs>",
            p.style
                .tabs_twips
                .iter()
                .map(|n| format!("<w:tab w:val=\"left\" w:pos=\"{n}\"/>"))
                .collect::<String>()
        )
    };
    let first = if p.style.first_line_twips < 0 {
        format!(
            "w:hanging=\"{}\"",
            i64::from(p.style.first_line_twips).unsigned_abs()
        )
    } else {
        format!("w:firstLine=\"{}\"", p.style.first_line_twips)
    };
    body.push_str(&format!("<w:p><w:pPr>{style_ref}{list_ref}{extras}{tabs}<w:jc w:val=\"{a}\"/><w:ind w:left=\"{}\" w:right=\"{}\" {first}/><w:spacing w:before=\"{}\" w:after=\"{}\" w:line=\"{}\"/></w:pPr>",p.style.left_twips,p.style.right_twips,p.style.before_twips,p.style.after_twips,p.style.line_twips));
    let mut markers = fields
        .iter()
        .filter(|f| f.at.paragraph == p.id)
        .collect::<Vec<_>>();
    markers.sort_by_key(|f| f.at.offset);
    let mut index = 0;
    let mut base = 0;
    for r in &p.runs {
        let end = base + r.text.len();
        let mut cursor = base;
        while index < markers.len() && markers[index].at.offset <= end {
            let field = markers[index];
            let piece = r
                .text
                .get(cursor - base..field.at.offset - base)
                .ok_or_else(|| bad("DOCX field boundary"))?;
            write_run(body, r, piece)?;
            write_field(body, &field.kind)?;
            cursor = field.at.offset;
            index += 1;
        }
        write_run(
            body,
            r,
            r.text
                .get(cursor - base..)
                .ok_or_else(|| bad("DOCX field boundary"))?,
        )?;
        base = end;
    }
    while index < markers.len() {
        if markers[index].at.offset != base {
            return Err(bad("DOCX field position"));
        }
        write_field(body, &markers[index].kind)?;
        index += 1;
    }
    body.push_str("</w:p>");
    Ok(())
}
fn write_field(body: &mut String, kind: &FieldKind) -> Result<(), Error> {
    let instruction = match kind {
        FieldKind::PageNumber => "PAGE",
        FieldKind::PageCount => "NUMPAGES",
        _ => return Err(Error::Unsupported("DOCX field".into())),
    };
    body.push_str(&format!(
        "<w:fldSimple w:instr=\"{instruction}\"><w:r><w:t>1</w:t></w:r></w:fldSimple>"
    ));
    Ok(())
}
fn write_run(body: &mut String, r: &Run, text: &str) -> Result<(), Error> {
    if text.is_empty() {
        return Ok(());
    }
    if r.link.is_some() || r.style.highlight.is_some() {
        return Err(Error::Unsupported("DOCX links or highlighting".into()));
    }
    if r.text
        .chars()
        .any(|c| c == '\0' || (c.is_control() && !matches!(c, '\t' | '\n' | '\r')))
    {
        return Err(Error::Unsupported("XML control character".into()));
    }
    let t = &r.style;
    let style_ref = t
        .source_style
        .as_ref()
        .map(|name| format!("<w:rStyle w:val=\"{}\"/>", esc(name)))
        .unwrap_or_default();
    let color = if let Some(value) = t.color {
        format!(
            "<w:color w:val=\"{value:06X}\"{}{}{} />",
            t.theme_color
                .as_ref()
                .map(|v| format!(" w:themeColor=\"{}\"", esc(v)))
                .unwrap_or_default(),
            t.theme_tint
                .as_ref()
                .map(|v| format!(" w:themeTint=\"{}\"", esc(v)))
                .unwrap_or_default(),
            t.theme_shade
                .as_ref()
                .map(|v| format!(" w:themeShade=\"{}\"", esc(v)))
                .unwrap_or_default()
        )
    } else {
        String::new()
    };
    body.push_str(&format!("<w:r><w:rPr>{style_ref}<w:rFonts w:ascii=\"{}\" w:hAnsi=\"{}\"/><w:sz w:val=\"{}\"/><w:b w:val=\"{}\"/><w:i w:val=\"{}\"/><w:u w:val=\"{}\"/><w:strike w:val=\"{}\"/>{color}</w:rPr><w:t xml:space=\"preserve\">{}</w:t></w:r>",esc(&t.font),esc(&t.font),t.size_half_points,u8::from(t.bold),u8::from(t.italic),if t.underline {"single"} else {"none"},u8::from(t.strike),esc(text)));
    Ok(())
}
fn val<'a>(n: roxmltree::Node<'a, 'a>, name: &str) -> Option<&'a str> {
    n.attribute((W, name))
}
fn num<T: std::str::FromStr>(
    n: roxmltree::Node<'_, '_>,
    name: &str,
    default: T,
) -> Result<T, Error> {
    match val(n, name) {
        Some(x) => x.parse().map_err(|_| bad("invalid Word number")),
        None => Ok(default),
    }
}
fn allowed(n: roxmltree::Node<'_, '_>, names: &[&str]) -> Result<(), Error> {
    for c in n.children().filter(|x| x.is_element()) {
        if c.tag_name().namespace() != Some(W) || !names.contains(&c.tag_name().name()) {
            return Err(Error::Unsupported(format!(
                "DOCX element {}",
                c.tag_name().name()
            )));
        }
    }
    Ok(())
}
fn safe_part_name(name: &str) -> bool {
    !name.contains("..")
        && !name.starts_with('/')
        && ([
            "[Content_Types].xml",
            "_rels/.rels",
            "word/document.xml",
            "word/styles.xml",
            "word/stylesWithEffects.xml",
            "word/numbering.xml",
            "word/settings.xml",
            "word/fontTable.xml",
            "word/webSettings.xml",
            "word/_rels/document.xml.rels",
        ]
        .contains(&name)
            || name.starts_with("docProps/")
            || name.starts_with("word/theme/")
            || name.starts_with("word/media/")
            || ((name.starts_with("word/header") || name.starts_with("word/footer"))
                && name.ends_with(".xml")
                && !name[5..].contains('/')))
}
pub(super) fn decode(bytes: &[u8]) -> Result<State, Error> {
    let mut z = ZipArchive::new(Cursor::new(bytes)).map_err(bad)?;
    if z.len() > 128 {
        return Err(Error::Limit);
    }
    let mut parts = std::collections::BTreeMap::new();
    let mut total = 0u64;
    for i in 0..z.len() {
        let f = z.by_index(i).map_err(bad)?;
        let name = f.name().to_owned();
        if f.is_dir() {
            continue;
        }
        if !safe_part_name(&name) {
            return Err(Error::Unsupported(format!("DOCX package part {name}")));
        }
        total = total.checked_add(f.size()).ok_or(Error::Limit)?;
        if total > MAX_BYTES as u64 || parts.contains_key(&name) {
            return Err(Error::Limit);
        }
        let mut content = Vec::new();
        f.take((MAX_BYTES + 1) as u64)
            .read_to_end(&mut content)
            .map_err(bad)?;
        parts.insert(name, content);
    }
    let xml = String::from_utf8(
        parts
            .remove("word/document.xml")
            .ok_or_else(|| bad("missing document"))?,
    )
    .map_err(bad)?;
    if let Some(rels) = parts.get("word/_rels/document.xml.rels") {
        let text = std::str::from_utf8(rels).map_err(bad)?;
        let d = roxmltree::Document::parse(text).map_err(bad)?;
        for r in d
            .descendants()
            .filter(|n| n.is_element() && n.tag_name().name() == "Relationship")
        {
            let t = r.attribute("Type").unwrap_or("");
            if ![
                "/styles",
                "/settings",
                "/fontTable",
                "/webSettings",
                "/theme",
                "/numbering",
                "/image",
                "/header",
                "/footer",
                "/stylesWithEffects",
            ]
            .iter()
            .any(|suffix| t.ends_with(suffix))
                || r.attribute("TargetMode").is_some()
            {
                return Err(Error::Unsupported(format!("DOCX relationship {t}")));
            }
        }
    }
    let doc = roxmltree::Document::parse(&xml).map_err(bad)?;
    for n in doc.descendants().filter(|n| n.is_element()) {
        if n.has_tag_name((W, "drawing")) || n.ancestors().any(|a| a.has_tag_name((W, "drawing"))) {
            continue;
        }
        let accepted: &[&str] = match n.tag_name().name() {
            "document" | "body" | "p" | "pPr" | "r" | "rPr" | "sectPr" | "tbl" | "tr" | "tc"
            | "numPr" | "tabs" => &[],
            "headerReference" | "footerReference" => &["type", "id"],
            "fldSimple" => &["instr"],
            "jc" | "sz" | "b" | "i" | "u" | "strike" | "pStyle" | "rStyle" | "ilvl" | "numId"
            | "keepNext" | "keepLines" | "pageBreakBefore" | "outlineLvl" => &["val"],
            "tab" => &["val", "pos"],
            "color" => &["val", "themeColor", "themeTint", "themeShade"],
            "ind" => &["left", "right", "firstLine", "hanging"],
            "spacing" => &["before", "after", "line"],
            "rFonts" => &["ascii", "hAnsi", "asciiTheme", "hAnsiTheme"],
            "pgSz" => &["w", "h"],
            "pgMar" => &["left", "right", "top", "bottom", "header", "footer"],
            "t" => &["space"],
            _ => {
                return Err(Error::Unsupported(format!(
                    "DOCX element {}",
                    n.tag_name().name()
                )))
            }
        };
        for a in n.attributes() {
            let word_revision = a.namespace() == Some(W)
                && matches!(
                    a.name(),
                    "rsidR" | "rsidRDefault" | "rsidP" | "rsidRPr" | "rsidSect"
                );
            let compat = a.namespace()
                == Some("http://schemas.openxmlformats.org/markup-compatibility/2006")
                && a.name() == "Ignorable"
                && n.has_tag_name((W, "document"));
            let tracking = a.namespace()
                == Some("http://schemas.microsoft.com/office/word/2010/wordml")
                && matches!(a.name(), "paraId" | "textId");
            if word_revision || compat || tracking {
                continue;
            }
            let expected_ns =
                if matches!(n.tag_name().name(), "headerReference" | "footerReference")
                    && a.name() == "id"
                {
                    Some("http://schemas.openxmlformats.org/officeDocument/2006/relationships")
                } else if n.tag_name().name() == "t" && a.name() == "space" {
                    Some("http://www.w3.org/XML/1998/namespace")
                } else {
                    Some(W)
                };
            if a.namespace() != expected_ns || !accepted.contains(&a.name()) {
                return Err(Error::Unsupported(format!("DOCX attribute {}", a.name())));
            }
        }
        if n.has_tag_name((W, "rFonts")) && val(n, "ascii") != val(n, "hAnsi") {
            return Err(Error::Unsupported("different script fonts".into()));
        }
        if n.has_tag_name((W, "u"))
            && !matches!(val(n, "val"), None | Some("single" | "none" | "0"))
        {
            return Err(Error::Unsupported("underline type".into()));
        }
    }
    let numbering = numbering::Numbering::read(&parts)?;
    let styles = styles::Styles::new(&parts, &numbering)?;
    let root = doc.root_element();
    if root.tag_name().namespace() != Some(W) || root.tag_name().name() != "document" {
        return Err(bad("not WordprocessingML"));
    }
    allowed(root, &["body"])?;
    let body = root
        .children()
        .find(|n| n.is_element())
        .ok_or_else(|| bad("missing body"))?;
    allowed(body, &["p", "tbl", "sectPr"])?;
    let mut s = State {
        docx_parts: parts,
        ..State::default()
    };
    s.blocks.clear();
    let mut markers: Vec<(u64, usize, FieldKind)> = Vec::new();
    for node in body.children().filter(|n| n.is_element()) {
        match node.tag_name().name() {
            "p" if node.descendants().any(|n| n.has_tag_name((W, "drawing"))) => {
                let id = s.next_id;
                s.next_id += 1;
                s.blocks
                    .push(Block::Image(images::read(node, id, &s.docx_parts)?));
            }
            "p" => {
                let id = s.next_id;
                s.next_id += 1;
                s.blocks.push(Block::Paragraph(read_paragraph(
                    node,
                    id,
                    &styles,
                    &numbering,
                    &mut markers,
                )?));
            }
            "tbl" => {
                allowed(node, &["tr"])?;
                let id = s.next_id;
                s.next_id += 1;
                let mut rows = Vec::new();
                for row in node.children().filter(|n| n.is_element()) {
                    allowed(row, &["tc"])?;
                    let mut cells = Vec::new();
                    for cell in row.children().filter(|n| n.is_element()) {
                        allowed(cell, &["p"])?;
                        let mut paragraphs = Vec::new();
                        for p in cell.children().filter(|n| n.is_element()) {
                            let pid = s.next_id;
                            s.next_id += 1;
                            paragraphs.push(read_paragraph(
                                p,
                                pid,
                                &styles,
                                &numbering,
                                &mut markers,
                            )?);
                        }
                        if paragraphs.is_empty() {
                            return Err(bad("empty table cell"));
                        }
                        cells.push(Cell {
                            paragraphs,
                            row_span: 1,
                            col_span: 1,
                            border: None,
                            fill: None,
                        });
                    }
                    rows.push(cells);
                }
                s.blocks.push(Block::Table(Table { id, rows }));
            }
            "sectPr" => {}
            _ => unreachable!(),
        }
    }
    if s.blocks.is_empty() {
        return Err(bad("empty body"));
    }
    if let Some(sec) = body.children().find(|n| n.has_tag_name((W, "sectPr"))) {
        allowed(
            sec,
            &["pgSz", "pgMar", "headerReference", "footerReference"],
        )?;
        for x in sec.children().filter(|n| n.is_element()) {
            let p = &mut s.sections[0].page;
            match x.tag_name().name() {
                "pgSz" => {
                    p.width_twips = num(x, "w", p.width_twips)?;
                    p.height_twips = num(x, "h", p.height_twips)?
                }
                "pgMar" => {
                    p.margin_left = num(x, "left", p.margin_left)?;
                    p.margin_right = num(x, "right", p.margin_right)?;
                    p.margin_top = num(x, "top", p.margin_top)?;
                    p.margin_bottom = num(x, "bottom", p.margin_bottom)?;
                    p.header_distance_twips = num(x, "header", p.header_distance_twips)?;
                    p.footer_distance_twips = num(x, "footer", p.footer_distance_twips)?
                }
                "headerReference" | "footerReference" => {}
                _ => unreachable!(),
            }
        }
        for reference in sec.children().filter(|n| {
            n.has_tag_name((W, "headerReference")) || n.has_tag_name((W, "footerReference"))
        }) {
            if val(reference, "type") != Some("default") {
                return Err(Error::Unsupported("DOCX alternate header/footer".into()));
            }
            let rid = reference
                .attribute((
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
                    "id",
                ))
                .ok_or_else(|| bad("missing header relation"))?;
            let footer = reference.has_tag_name((W, "footerReference"));
            let bytes = headers::read(&s.docx_parts, rid, footer)?;
            let text = std::str::from_utf8(&bytes).map_err(bad)?;
            let hdr = roxmltree::Document::parse(text).map_err(bad)?;
            let root = hdr.root_element();
            let name = if footer { "ftr" } else { "hdr" };
            if !root.has_tag_name((W, name)) {
                return Err(bad("invalid header/footer part"));
            }
            allowed(root, &["p"])?;
            let mut paras = Vec::new();
            for p in root.children().filter(|n| n.is_element()) {
                let id = s.next_id;
                s.next_id += 1;
                paras.push(read_paragraph(p, id, &styles, &numbering, &mut markers)?);
            }
            if footer {
                s.sections[0].footer = paras
            } else {
                s.sections[0].header = paras
            }
        }
    }
    for (paragraph, offset, kind) in markers {
        let id = s.next_id;
        s.next_id += 1;
        s.fields.push(Field {
            id,
            at: Position { paragraph, offset },
            kind,
        });
    }
    Ok(s)
}

fn read_paragraph(
    p: roxmltree::Node<'_, '_>,
    id: u64,
    styles: &styles::Styles,
    numbering: &numbering::Numbering,
    markers: &mut Vec<(u64, usize, FieldKind)>,
) -> Result<Paragraph, Error> {
    allowed(p, &["pPr", "r", "fldSimple"])?;
    let props = p.children().find(|n| n.has_tag_name((W, "pPr")));
    if let Some(n) = props {
        allowed(
            n,
            &[
                "pStyle",
                "jc",
                "ind",
                "spacing",
                "numPr",
                "keepNext",
                "keepLines",
                "pageBreakBefore",
                "outlineLvl",
                "tabs",
            ],
        )?;
    }
    let (base, mut style) = styles.paragraph(props, numbering)?;
    if let Some(numpr) = props.and_then(|n| n.children().find(|c| c.has_tag_name((W, "numPr")))) {
        allowed(numpr, &["ilvl", "numId"])?;
        let level = numpr
            .children()
            .find(|c| c.has_tag_name((W, "ilvl")))
            .map(|c| num(c, "val", 0u8))
            .transpose()?
            .unwrap_or(0);
        if let Some(id) = numpr
            .children()
            .find(|c| c.has_tag_name((W, "numId")))
            .map(|c| num(c, "val", 0u64))
            .transpose()?
        {
            if id != 0 {
                style.list = Some(numbering.marker(id, level)?);
            }
        }
    }
    let mut runs = Vec::new();
    for r in p
        .children()
        .filter(|n| n.is_element() && !n.has_tag_name((W, "pPr")))
    {
        if r.has_tag_name((W, "fldSimple")) {
            let instruction = val(r, "instr").unwrap_or("").trim().to_ascii_uppercase();
            let kind = match instruction.as_str() {
                "PAGE" => FieldKind::PageNumber,
                "NUMPAGES" => FieldKind::PageCount,
                _ => return Err(Error::Unsupported("DOCX field instruction".into())),
            };
            let offset = runs.iter().map(|r: &Run| r.text.len()).sum();
            markers.push((id, offset, kind));
            continue;
        }
        allowed(r, &["rPr", "t"])?;
        let rp = r.children().find(|n| n.has_tag_name((W, "rPr")));
        if let Some(n) = rp {
            allowed(
                n,
                &["rStyle", "rFonts", "sz", "b", "i", "u", "strike", "color"],
            )?;
        }
        let style = styles.run(rp, &base)?;
        let text = r
            .children()
            .filter(|n| n.has_tag_name((W, "t")))
            .map(|n| n.text().unwrap_or(""))
            .collect::<String>();
        runs.push(Run {
            text,
            style,
            link: None,
        });
    }
    Ok(Paragraph { id, style, runs })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn independently_authored_word_xml_with_metadata_opens() {
        let xml=br#"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="w14"><w:body><w:p w:rsidR="00112233"><w:r><w:t>Hello external</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:bottom="1440" w:left="1440" w:right="1440"/></w:sectPr></w:body></w:document>"#;
        let mut parts = std::collections::BTreeMap::new();
        parts.insert("[Content_Types].xml".into(), br#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#.to_vec());
        parts.insert("_rels/.rels".into(), br#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#.to_vec());
        parts.insert("word/document.xml".into(), xml.to_vec());
        parts.insert("docProps/core.xml".into(), b"<core/>".to_vec());
        let state = decode(&package(&parts).unwrap()).unwrap();
        let Block::Paragraph(p) = &state.blocks[0] else {
            panic!()
        };
        assert_eq!(p.runs[0].text, "Hello external");
        assert!(state.docx_parts.contains_key("docProps/core.xml"));
    }
    #[test]
    fn inline_png_round_trip() {
        let mut state = State::default();
        state.blocks.push(Block::Image(Image {
            id: 2,
            mime: "image/png".into(),
            data: vec![
                137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
                1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248,
                207, 192, 240, 31, 0, 5, 0, 1, 255, 137, 153, 61, 29, 0, 0, 0, 0, 73, 69, 78, 68,
                174, 66, 96, 130,
            ],
            width_twips: 1440,
            height_twips: 720,
            alt: "A picture".into(),
        }));
        state.next_id = 3;
        let reopened = decode(&encode(&state).unwrap()).unwrap();
        let Block::Image(p) = &reopened.blocks[1] else {
            panic!()
        };
        assert_eq!(p.width_twips, 1440);
        assert_eq!(p.height_twips, 720);
        assert_eq!(p.alt, "A picture");
        assert!(p.data.starts_with(b"\x89PNG\r\n\x1a\n"));
        assert!(p.data.len() > 50);
        let next = decode(&encode(&reopened).unwrap()).unwrap();
        assert!(decode(&encode(&next).unwrap()).is_ok());
    }
    #[test]
    fn numbered_list_round_trip() {
        let mut state = State::default();
        let Block::Paragraph(p) = &mut state.blocks[0] else {
            panic!()
        };
        p.runs[0].text = "List item".into();
        p.style.list = Some(ListMarker {
            id: 7,
            level: 1,
            numbered: true,
        });
        let reopened = decode(&encode(&state).unwrap()).unwrap();
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
        assert!(decode(&encode(&reopened).unwrap()).is_ok());
    }
    #[test]
    fn theme_color_reference_survives_projection() {
        let mut state = State::default();
        let Block::Paragraph(p) = &mut state.blocks[0] else {
            panic!()
        };
        p.runs[0].text = "theme".into();
        p.runs[0].style.color = Some(0x336699);
        p.runs[0].style.theme_color = Some("accent1".into());
        p.runs[0].style.theme_tint = Some("80".into());
        let mut doc = RichDocument::decode(&encode(&state).unwrap(), Format::Docx).unwrap();
        let projection = doc.rich_edit_projection().unwrap();
        doc.apply_rich_edit_projection(&projection, (0, 0)).unwrap();
        let Block::Paragraph(p) = &doc.state().blocks[0] else {
            panic!()
        };
        assert_eq!(p.runs[0].style.theme_color.as_deref(), Some("accent1"));
        assert_eq!(p.runs[0].style.theme_tint.as_deref(), Some("80"));
        assert_eq!(p.runs[0].style.color, Some(0x336699));
    }
    #[test]
    fn inherited_styles_and_theme_fonts_round_trip() {
        let xml=br#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:pPr><w:pStyle w:val="Heading"/></w:pPr><w:r><w:rPr><w:rStyle w:val="Emphasis"/></w:rPr><w:t>Styled</w:t></w:r></w:p><w:sectPr/></w:body></w:document>"#;
        let styles=br#"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme="minorHAnsi"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:styleId="Base"><w:rPr><w:b/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading"><w:basedOn w:val="Base"/><w:pPr><w:jc w:val="center"/></w:pPr></w:style><w:style w:type="character" w:styleId="Emphasis"><w:rPr><w:i/></w:rPr></w:style></w:styles>"#;
        let theme=br#"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:fontScheme><a:majorFont><a:latin typeface="Cambria"/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/></a:minorFont></a:fontScheme></a:themeElements></a:theme>"#;
        let mut parts = std::collections::BTreeMap::new();
        parts.insert("word/document.xml".into(), xml.to_vec());
        parts.insert("word/styles.xml".into(), styles.to_vec());
        parts.insert("word/theme/theme1.xml".into(), theme.to_vec());
        let state = decode(&package(&parts).unwrap()).unwrap();
        let Block::Paragraph(p) = &state.blocks[0] else {
            panic!()
        };
        assert_eq!(p.style.source_style.as_deref(), Some("Heading"));
        assert_eq!(p.style.alignment, Alignment::Center);
        assert_eq!(p.runs[0].style.font, "Calibri");
        assert_eq!(p.runs[0].style.size_half_points, 22);
        assert!(p.runs[0].style.bold && p.runs[0].style.italic);
        assert_eq!(p.runs[0].style.source_style.as_deref(), Some("Emphasis"));
        let reopened = decode(&encode(&state).unwrap()).unwrap();
        let Block::Paragraph(p) = &reopened.blocks[0] else {
            panic!()
        };
        assert_eq!(p.style.source_style.as_deref(), Some("Heading"));
        assert_eq!(p.runs[0].style.source_style.as_deref(), Some("Emphasis"));
        assert!(p.runs[0].style.bold && p.runs[0].style.italic);
    }
    #[test]
    fn simple_table_round_trip() {
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
        let decoded = decode(&encode(&s).unwrap()).unwrap();
        let Block::Table(t) = &decoded.blocks[1] else {
            panic!()
        };
        assert_eq!(t.rows[0][0].paragraphs[0].runs[0].text, "cell");
    }
    #[test]
    fn styled_document_and_preserved_parts_round_trip() {
        let mut s = State::default();
        if let Block::Paragraph(p) = &mut s.blocks[0] {
            p.runs[0].text = "Hello & 世界".into();
            p.runs[0].style.bold = true;
            p.runs[0].style.color = Some(0x336699);
            p.style.alignment = Alignment::Center;
        }
        s.docx_parts
            .insert("docProps/core.xml".into(), b"<core/>".to_vec());
        let bytes = encode(&s).unwrap();
        let decoded = decode(&bytes).unwrap();
        assert_eq!(
            decoded.docx_parts.get("docProps/core.xml").unwrap(),
            b"<core/>"
        );
        let (Block::Paragraph(a), Block::Paragraph(b)) = (&s.blocks[0], &decoded.blocks[0]) else {
            panic!()
        };
        assert_eq!(a.runs, b.runs);
        assert_eq!(a.style, b.style);
        assert_eq!(s.sections[0].page, decoded.sections[0].page);
        assert!(decode(&encode(&decoded).unwrap()).is_ok());
    }
}
