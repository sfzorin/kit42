//! OpenDocument Text package adapter for common text, styles, lists, tables and pictures.
use super::*;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    io::{Cursor, Read, Write},
};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipArchive, ZipWriter};
const O: &str = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
const T: &str = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
const S: &str = "urn:oasis:names:tc:opendocument:xmlns:style:1.0";
const F: &str = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0";
const TB: &str = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
const D: &str = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0";
const SVG: &str = "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0";
const XL: &str = "http://www.w3.org/1999/xlink";
const MIME: &str = "application/vnd.oasis.opendocument.text";
const NS:&str="xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"";
fn bad(e: impl std::fmt::Display) -> Error {
    Error::Invalid(e.to_string())
}
fn unsupported(s: impl Into<String>) -> Error {
    Error::Unsupported(s.into())
}
fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn attr<'a>(n: roxmltree::Node<'a, 'a>, ns: &str, name: &str) -> Option<&'a str> {
    n.attribute((ns, name))
}
fn length(value: &str) -> Result<i32, Error> {
    let s = value.trim();
    let (n, factor) = if let Some(v) = s.strip_suffix("pt") {
        (v, 20.0)
    } else if let Some(v) = s.strip_suffix("cm") {
        (v, 1440.0 / 2.54)
    } else if let Some(v) = s.strip_suffix("mm") {
        (v, 1440.0 / 25.4)
    } else if let Some(v) = s.strip_suffix("in") {
        (v, 1440.0)
    } else if let Some(v) = s.strip_suffix("px") {
        (v, 15.0)
    } else if s == "0" {
        ("0", 1.0)
    } else {
        return Err(unsupported("ODT length unit"));
    };
    let n = n.parse::<f64>().map_err(bad)? * factor;
    if !n.is_finite() || !(-2_000_000.0..=2_000_000.0).contains(&n) {
        return Err(bad("ODT length"));
    }
    Ok(n.round() as i32)
}
fn nonnegative(v: &str) -> Result<u32, Error> {
    u32::try_from(length(v)?).map_err(|_| bad("negative ODT length"))
}
fn color(v: &str) -> Result<u32, Error> {
    let h = v
        .strip_prefix('#')
        .ok_or_else(|| unsupported("ODT color"))?;
    if h.len() != 6 {
        return Err(unsupported("ODT color"));
    }
    u32::from_str_radix(h, 16).map_err(bad)
}
#[derive(Clone, Default)]
struct Def {
    parent: Option<String>,
    run: RunPatch,
    para: ParaPatch,
}
#[derive(Clone, Default)]
struct RunPatch {
    font: Option<String>,
    size: Option<u16>,
    bold: Option<bool>,
    italic: Option<bool>,
    underline: Option<bool>,
    strike: Option<bool>,
    color: Option<u32>,
    highlight: Option<u32>,
    extra: BTreeMap<String, String>,
}
#[derive(Clone, Default)]
struct ParaPatch {
    align: Option<Alignment>,
    left: Option<i32>,
    right: Option<i32>,
    first: Option<i32>,
    before: Option<u32>,
    after: Option<u32>,
    line: Option<i32>,
    tabs: Option<Vec<i32>>,
    extra: BTreeMap<String, String>,
}
struct Styles {
    defs: HashMap<(String, String), Def>,
    list_types: HashMap<(String, u8), bool>,
    default_paragraph: Def,
    default_text: Def,
    named: HashSet<(String, String)>,
}
impl Styles {
    fn new(docs: &[&roxmltree::Document<'_>]) -> Result<Self, Error> {
        let mut out = Self {
            defs: HashMap::new(),
            list_types: HashMap::new(),
            default_paragraph: Def::default(),
            default_text: Def::default(),
            named: HashSet::new(),
        };
        let mut fonts = HashMap::new();
        for doc in docs {
            for n in doc
                .descendants()
                .filter(|n| n.has_tag_name((S, "font-face")))
            {
                if let (Some(name), Some(face)) = (attr(n, S, "name"), attr(n, SVG, "font-family"))
                {
                    fonts.insert(name.to_owned(), face.trim_matches(['\'', '"']).to_owned());
                }
            }
        }
        for doc in docs {
            for n in doc
                .descendants()
                .filter(|n| n.has_tag_name((S, "default-style")))
            {
                let family = attr(n, S, "family").unwrap_or("");
                let mut d = Def::default();
                for p in n.children().filter(|n| n.is_element()) {
                    match p.tag_name().name() {
                        "text-properties" => d.run = run_patch(p)?,
                        "paragraph-properties" => d.para = para_patch(p)?,
                        _ => {}
                    }
                }
                match family {
                    "paragraph" => out.default_paragraph = d,
                    "text" => out.default_text = d,
                    _ => {}
                }
            }
            for n in doc.descendants().filter(|n| n.has_tag_name((S, "style"))) {
                let Some(name) = attr(n, S, "name") else {
                    continue;
                };
                let family = attr(n, S, "family").unwrap_or("");
                if !matches!(family, "paragraph" | "text") {
                    continue;
                }
                if n.parent().is_some_and(|p| p.has_tag_name((O, "styles"))) {
                    out.named.insert((family.into(), name.into()));
                }
                let mut d = Def {
                    parent: attr(n, S, "parent-style-name").map(str::to_owned),
                    ..Def::default()
                };
                for p in n.children().filter(|n| n.is_element()) {
                    match p.tag_name().name() {
                        "text-properties" => d.run = run_patch(p)?,
                        "paragraph-properties" => d.para = para_patch(p)?,
                        _ => {}
                    }
                }
                out.defs.insert((family.into(), name.into()), d);
            }
            for n in doc
                .descendants()
                .filter(|n| n.has_tag_name((T, "list-style")))
            {
                if let Some(name) = attr(n, S, "name") {
                    for child in n.children().filter(|c| c.is_element()) {
                        let numbered = match child.tag_name().name() {
                            "list-level-style-number" => true,
                            "list-level-style-bullet" => false,
                            _ => return Err(unsupported("ODT list level style")),
                        };
                        let level = attr(child, T, "level")
                            .unwrap_or("1")
                            .parse::<u8>()
                            .map_err(bad)?;
                        out.list_types.insert((name.into(), level), numbered);
                    }
                }
            }
        }
        for d in out
            .defs
            .values_mut()
            .chain([&mut out.default_paragraph, &mut out.default_text])
        {
            if let Some(font) = &d.run.font {
                if let Some(face) = fonts.get(font) {
                    d.run.font = Some(face.clone());
                }
            }
        }
        Ok(out)
    }
    fn defaults(&self, run: &mut TextStyle, para: &mut ParagraphStyle) {
        apply_run(run, &self.default_text.run);
        apply_run(run, &self.default_paragraph.run);
        apply_para(para, &self.default_paragraph.para);
    }
    fn resolve(
        &self,
        family: &str,
        name: &str,
        run: &mut TextStyle,
        para: &mut ParagraphStyle,
        seen: &mut HashSet<String>,
    ) -> Result<(), Error> {
        if !seen.insert(name.into()) {
            return Err(bad("cyclic ODT style"));
        }
        let d = self
            .defs
            .get(&(family.into(), name.into()))
            .ok_or_else(|| unsupported(format!("ODT style {name}")))?;
        if let Some(parent) = &d.parent {
            self.resolve(family, parent, run, para, seen)?
        }
        apply_run(run, &d.run);
        apply_para(para, &d.para);
        Ok(())
    }
    fn named_source(&self, family: &str, name: Option<&str>) -> Option<String> {
        let mut current = name?;
        let mut seen = HashSet::new();
        loop {
            if !seen.insert(current.to_owned()) {
                return None;
            }
            if self.named.contains(&(family.into(), current.into())) {
                return Some(current.into());
            }
            current = self
                .defs
                .get(&(family.into(), current.into()))?
                .parent
                .as_deref()?;
        }
    }
    fn apply(
        &self,
        family: &str,
        name: Option<&str>,
        run: &mut TextStyle,
        para: &mut ParagraphStyle,
    ) -> Result<(), Error> {
        if let Some(name) = name {
            self.resolve(family, name, run, para, &mut HashSet::new())?;
        }
        Ok(())
    }
}
fn attr_key(a: roxmltree::Attribute<'_, '_>) -> Result<String, Error> {
    let prefix = match a.namespace() {
        Some(F) => "fo",
        Some(S) => "style",
        Some(T) => "text",
        Some(SVG) => "svg",
        _ => return Err(unsupported("unknown ODT style namespace")),
    };
    Ok(format!("{prefix}:{}", a.name()))
}
fn extra_attrs(extra: &BTreeMap<String, String>) -> Result<String, Error> {
    let mut out = String::new();
    for (k, v) in extra {
        let (prefix, local) = k.split_once(':').ok_or_else(|| bad("ODT attribute name"))?;
        if !matches!(prefix, "fo" | "style" | "text" | "svg")
            || local.is_empty()
            || !local
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        {
            return Err(bad("ODT attribute name"));
        }
        out.push_str(&format!(" {k}=\"{}\"", esc(v)));
    }
    Ok(out)
}
fn run_patch(n: roxmltree::Node<'_, '_>) -> Result<RunPatch, Error> {
    let mut p = RunPatch::default();
    for a in n.attributes() {
        match (a.namespace(), a.name()) {
            (Some(S), "font-name") => p.font = Some(a.value().into()),
            (Some(F), "font-family") => p.font = Some(a.value().trim_matches(['\'', '"']).into()),
            (Some(F), "font-size") => {
                let n = length(a.value())?;
                p.size = Some(u16::try_from((n + 5) / 10).map_err(|_| bad("ODT font size"))?)
            }
            (Some(F), "font-weight") => {
                p.bold = Some(matches!(a.value(), "bold" | "700" | "800" | "900"))
            }
            (Some(F), "font-style") => p.italic = Some(matches!(a.value(), "italic" | "oblique")),
            (Some(S), "text-underline-style") => p.underline = Some(a.value() != "none"),
            (Some(S), "text-line-through-style") => p.strike = Some(a.value() != "none"),
            (Some(F), "color") => p.color = Some(color(a.value())?),
            (Some(F), "background-color") if a.value() != "transparent" => {
                p.highlight = Some(color(a.value())?)
            }
            _ => {
                p.extra.insert(attr_key(a)?, a.value().into());
            }
        }
    }
    Ok(p)
}
fn para_patch(n: roxmltree::Node<'_, '_>) -> Result<ParaPatch, Error> {
    let mut p = ParaPatch::default();
    for a in n.attributes() {
        match (a.namespace(), a.name()) {
            (Some(F), "text-align") => {
                p.align = Some(match a.value() {
                    "start" | "left" => Alignment::Left,
                    "center" => Alignment::Center,
                    "end" | "right" => Alignment::Right,
                    "justify" => Alignment::Justify,
                    _ => return Err(unsupported("ODT alignment")),
                })
            }
            (Some(F), "margin-left") => p.left = Some(length(a.value())?),
            (Some(F), "margin-right") => p.right = Some(length(a.value())?),
            (Some(F), "text-indent") => p.first = Some(length(a.value())?),
            (Some(F), "margin-top") => p.before = Some(nonnegative(a.value())?),
            (Some(F), "margin-bottom") => p.after = Some(nonnegative(a.value())?),
            (Some(F), "line-height") => {
                if a.value().ends_with('%') {
                    p.extra.insert(attr_key(a)?, a.value().into());
                } else {
                    p.line = Some(length(a.value())?)
                }
            }
            _ => {
                p.extra.insert(attr_key(a)?, a.value().into());
            }
        }
    }
    if let Some(stops) = n.children().find(|c| c.has_tag_name((S, "tab-stops"))) {
        let mut tabs = Vec::new();
        for tab in stops.children().filter(|c| c.is_element()) {
            if !tab.has_tag_name((S, "tab-stop"))
                || !matches!(attr(tab, S, "type"), None | Some("left"))
            {
                return Err(unsupported("ODT tab type"));
            }
            tabs.push(length(
                attr(tab, S, "position").ok_or_else(|| bad("ODT tab position"))?,
            )?);
        }
        tabs.sort_unstable();
        tabs.dedup();
        p.tabs = Some(tabs);
    }
    Ok(p)
}
fn apply_run(t: &mut TextStyle, p: &RunPatch) {
    t.odt_extra.extend(p.extra.clone());
    if let Some(v) = &p.font {
        t.font = v.clone()
    }
    if let Some(v) = p.size {
        t.size_half_points = v
    }
    if let Some(v) = p.bold {
        t.bold = v
    }
    if let Some(v) = p.italic {
        t.italic = v
    }
    if let Some(v) = p.underline {
        t.underline = v
    }
    if let Some(v) = p.strike {
        t.strike = v
    }
    if let Some(v) = p.color {
        t.color = Some(v)
    }
    if let Some(v) = p.highlight {
        t.highlight = Some(v)
    }
}
fn apply_para(t: &mut ParagraphStyle, p: &ParaPatch) {
    if let Some(v) = &p.tabs {
        t.tabs_twips = v.clone();
    }
    t.odt_extra.extend(p.extra.clone());
    if let Some(v) = p.align {
        t.alignment = v
    }
    if let Some(v) = p.left {
        t.left_twips = v
    }
    if let Some(v) = p.right {
        t.right_twips = v
    }
    if let Some(v) = p.first {
        t.first_line_twips = v
    }
    if let Some(v) = p.before {
        t.before_twips = v
    }
    if let Some(v) = p.after {
        t.after_twips = v
    }
    if let Some(v) = p.line {
        t.line_twips = v
    }
}
fn read_parts(bytes: &[u8]) -> Result<BTreeMap<String, Vec<u8>>, Error> {
    let mut z = ZipArchive::new(Cursor::new(bytes)).map_err(bad)?;
    if z.len() > 1024 {
        return Err(Error::Limit);
    }
    let mut total = 0u64;
    let mut out = BTreeMap::new();
    for i in 0..z.len() {
        let f = z.by_index(i).map_err(bad)?;
        if f.is_dir() {
            continue;
        }
        let name = f.name().to_owned();
        if name.starts_with('/')
            || name.contains('\\')
            || name.split('/').any(|x| x == ".." || x.is_empty())
            || out.contains_key(&name)
        {
            return Err(bad("invalid ODT package path"));
        }
        total = total.checked_add(f.size()).ok_or(Error::Limit)?;
        if total > MAX_BYTES as u64 {
            return Err(Error::Limit);
        }
        let mut data = Vec::new();
        f.take((MAX_BYTES + 1) as u64)
            .read_to_end(&mut data)
            .map_err(bad)?;
        if data.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
        out.insert(name, data);
    }
    if out.get("mimetype").map(Vec::as_slice) != Some(MIME.as_bytes()) {
        return Err(bad("not an ODT package"));
    }
    Ok(out)
}
struct Reader<'a> {
    styles: Styles,
    parts: &'a BTreeMap<String, Vec<u8>>,
    state: State,
    next: u64,
    pending_fields: Vec<(usize, FieldKind)>,
}
impl Reader<'_> {
    fn id(&mut self) -> u64 {
        let id = self.next;
        self.next += 1;
        id
    }
    fn inline(
        &mut self,
        n: roxmltree::Node<'_, '_>,
        run: &TextStyle,
        para: &ParagraphStyle,
        link: Option<String>,
        out: &mut Vec<Run>,
    ) -> Result<(), Error> {
        if n.is_text() {
            let text = n.text().unwrap_or("");
            if !text.is_empty() {
                out.push(Run {
                    text: text.into(),
                    style: run.clone(),
                    link,
                })
            }
            return Ok(());
        }
        if !n.is_element() {
            return Ok(());
        }
        match n.tag_name().name() {
            "span" => {
                let mut t = run.clone();
                let mut p = para.clone();
                self.styles
                    .apply("text", attr(n, T, "style-name"), &mut t, &mut p)?;
                t.source_style = self.styles.named_source("text", attr(n, T, "style-name"));
                for c in n.children() {
                    self.inline(c, &t, &p, link.clone(), out)?
                }
                Ok(())
            }
            "a" => {
                let target = attr(n, XL, "href")
                    .ok_or_else(|| bad("ODT link"))?
                    .to_owned();
                for c in n.children() {
                    self.inline(c, run, para, Some(target.clone()), out)?
                }
                Ok(())
            }
            "s" => {
                let count = attr(n, T, "c")
                    .unwrap_or("1")
                    .parse::<usize>()
                    .map_err(bad)?;
                if count > 1_000_000 {
                    return Err(Error::Limit);
                }
                out.push(Run {
                    text: " ".repeat(count),
                    style: run.clone(),
                    link,
                });
                Ok(())
            }
            "tab" => {
                out.push(Run {
                    text: "\t".into(),
                    style: run.clone(),
                    link,
                });
                Ok(())
            }
            "page-number" | "page-count" if n.tag_name().namespace() == Some(T) => {
                if n.tag_name().name() == "page-number"
                    && !matches!(attr(n, T, "select-page"), None | Some("current"))
                {
                    return Err(unsupported("ODT page field selection"));
                }
                let offset = out.iter().map(|r| r.text.len()).sum();
                self.pending_fields.push((
                    offset,
                    if n.tag_name().name() == "page-number" {
                        FieldKind::PageNumber
                    } else {
                        FieldKind::PageCount
                    },
                ));
                Ok(())
            }
            "line-break" => Err(unsupported("ODT line break inside paragraph")),
            name => Err(unsupported(format!("ODT inline element {name}"))),
        }
    }
    fn para(
        &mut self,
        n: roxmltree::Node<'_, '_>,
        list: Option<ListMarker>,
    ) -> Result<Paragraph, Error> {
        let mut run = TextStyle::default();
        let mut para = ParagraphStyle::default();
        self.styles.defaults(&mut run, &mut para);
        let name = attr(n, T, "style-name");
        self.styles.apply("paragraph", name, &mut run, &mut para)?;
        para.source_style = self.styles.named_source("paragraph", name);
        if n.tag_name().name() == "h" {
            let l = attr(n, T, "outline-level")
                .unwrap_or("1")
                .parse::<u8>()
                .map_err(bad)?;
            para.outline_level = Some(l.saturating_sub(1));
        }
        para.list = list;
        let mut runs = Vec::new();
        for c in n.children() {
            self.inline(c, &run, &para, None, &mut runs)?
        }
        let id = self.id();
        for (offset, kind) in std::mem::take(&mut self.pending_fields) {
            let field_id = self.id();
            self.state.fields.push(Field {
                id: field_id,
                at: Position {
                    paragraph: id,
                    offset,
                },
                kind,
            });
        }
        Ok(Paragraph {
            id,
            style: para,
            runs,
        })
    }
    fn blocks(
        &mut self,
        parent: roxmltree::Node<'_, '_>,
        level: u8,
        active: Option<(u64, bool)>,
    ) -> Result<(), Error> {
        for n in parent.children().filter(|n| n.is_element()) {
            match n.tag_name().name() {
                "p" | "h" => {
                    if let Some(frame) = n.children().find(|c| c.has_tag_name((D, "frame"))) {
                        if n.children()
                            .any(|c| c.is_text() && !c.text().unwrap_or("").trim().is_empty())
                            || n.children().filter(|c| c.is_element()).count() != 1
                        {
                            return Err(unsupported("ODT inline image mixed with text"));
                        }
                        let image = self.image(frame)?;
                        self.state.blocks.push(Block::Image(image));
                    } else {
                        let list = active.map(|(id, numbered)| ListMarker {
                            id,
                            numbered,
                            level,
                        });
                        let p = self.para(n, list)?;
                        self.state.blocks.push(Block::Paragraph(p));
                    }
                }
                "list" => {
                    let name = attr(n, T, "style-name").unwrap_or("");
                    let actual_level = if active.is_some() {
                        level.checked_add(1).ok_or(Error::Limit)?
                    } else {
                        level
                    };
                    let numbered = self
                        .styles
                        .list_types
                        .get(&(name.into(), actual_level + 1))
                        .copied()
                        .or(active.map(|v| v.1))
                        .unwrap_or(false);
                    let id = self.id();
                    for item in n.children().filter(|n| n.is_element()) {
                        if !item.has_tag_name((T, "list-item")) {
                            return Err(unsupported("ODT list item"));
                        }
                        self.blocks(item, actual_level, Some((id, numbered)))?;
                    }
                }
                "sequence-decls" if n.tag_name().namespace() == Some(T) => {}
                "table" if n.tag_name().namespace() == Some(TB) => {
                    let table = self.table(n)?;
                    self.state.blocks.push(Block::Table(table));
                }
                _ => {
                    return Err(unsupported(format!(
                        "ODT content element {}",
                        n.tag_name().name()
                    )))
                }
            }
        }
        Ok(())
    }
    fn image(&mut self, frame: roxmltree::Node<'_, '_>) -> Result<Image, Error> {
        let image = frame
            .children()
            .find(|c| c.has_tag_name((D, "image")))
            .ok_or_else(|| unsupported("ODT frame"))?;
        let href = attr(image, XL, "href")
            .ok_or_else(|| bad("ODT image href"))?
            .trim_start_matches("./");
        if href.starts_with('/') || href.contains(':') || href.split('/').any(|x| x == "..") {
            return Err(unsupported("external ODT image"));
        }
        let data = self
            .parts
            .get(href)
            .ok_or_else(|| bad("missing ODT image"))?
            .clone();
        let mime = if data.starts_with(b"\x89PNG\r\n\x1a\n") {
            "image/png"
        } else if data.starts_with(&[0xff, 0xd8, 0xff]) {
            "image/jpeg"
        } else {
            return Err(unsupported("ODT image format"));
        };
        let width = nonnegative(attr(frame, SVG, "width").ok_or_else(|| bad("ODT image width"))?)?;
        let height =
            nonnegative(attr(frame, SVG, "height").ok_or_else(|| bad("ODT image height"))?)?;
        let alt = frame
            .children()
            .find(|n| n.has_tag_name((SVG, "desc")))
            .and_then(|n| n.text())
            .unwrap_or("")
            .to_owned();
        Ok(Image {
            id: self.id(),
            mime: mime.into(),
            data,
            width_twips: width,
            height_twips: height,
            alt,
        })
    }
    fn table(&mut self, n: roxmltree::Node<'_, '_>) -> Result<Table, Error> {
        let mut rows = Vec::new();
        for r in n.children().filter(|c| c.has_tag_name((TB, "table-row"))) {
            let repeat = attr(r, TB, "number-rows-repeated")
                .unwrap_or("1")
                .parse::<usize>()
                .map_err(bad)?;
            if repeat != 1 {
                return Err(unsupported("repeated ODT table rows"));
            }
            let mut cells = Vec::new();
            for c in r.children().filter(|c| c.is_element()) {
                if !c.has_tag_name((TB, "table-cell")) {
                    return Err(unsupported("ODT covered table cell"));
                }
                if attr(c, TB, "number-columns-spanned").is_some()
                    || attr(c, TB, "number-rows-spanned").is_some()
                {
                    return Err(unsupported("ODT merged table cell"));
                }
                let repeats = attr(c, TB, "number-columns-repeated")
                    .unwrap_or("1")
                    .parse::<usize>()
                    .map_err(bad)?;
                if repeats != 1 {
                    return Err(unsupported("repeated ODT table cells"));
                }
                let mut paragraphs = Vec::new();
                for p in c.children().filter(|n| n.is_element()) {
                    if !p.has_tag_name((T, "p")) {
                        return Err(unsupported("ODT table cell content"));
                    }
                    paragraphs.push(self.para(p, None)?)
                }
                cells.push(Cell {
                    paragraphs,
                    row_span: 1,
                    col_span: 1,
                    border: None,
                    fill: None,
                });
            }
            if cells.is_empty()
                || rows
                    .first()
                    .is_some_and(|x: &Vec<Cell>| x.len() != cells.len())
            {
                return Err(unsupported("irregular ODT table"));
            }
            rows.push(cells);
        }
        if rows.is_empty() {
            return Err(unsupported("empty ODT table"));
        }
        Ok(Table {
            id: self.id(),
            rows,
        })
    }
}
pub(super) fn decode(bytes: &[u8]) -> Result<State, Error> {
    let mut parts = read_parts(bytes)?;
    let content = parts
        .remove("content.xml")
        .ok_or_else(|| bad("missing ODT content"))?;
    let styles_bytes = parts
        .get("styles.xml")
        .ok_or_else(|| bad("missing ODT styles"))?;
    let content = std::str::from_utf8(&content).map_err(bad)?;
    let styles_str = std::str::from_utf8(styles_bytes).map_err(bad)?;
    let content_doc = roxmltree::Document::parse(content).map_err(bad)?;
    let styles_doc = roxmltree::Document::parse(styles_str).map_err(bad)?;
    let style_map = Styles::new(&[&styles_doc, &content_doc])?;
    let master = styles_doc
        .descendants()
        .find(|n| n.has_tag_name((S, "master-page")) && attr(*n, S, "name") == Some("Standard"))
        .or_else(|| {
            styles_doc
                .descendants()
                .find(|n| n.has_tag_name((S, "master-page")))
        });
    let layout_name = master.and_then(|n| attr(n, S, "page-layout-name"));
    let layout = styles_doc.descendants().find(|n| {
        n.has_tag_name((S, "page-layout"))
            && (layout_name.is_none() || attr(*n, S, "name") == layout_name)
    });
    let mut page = PageSettings::default();
    if let Some(p) = layout.and_then(|n| {
        n.children()
            .find(|c| c.has_tag_name((S, "page-layout-properties")))
    }) {
        if let Some(v) = attr(p, F, "margin") {
            let v = nonnegative(v)?;
            page.margin_left = v;
            page.margin_right = v;
            page.margin_top = v;
            page.margin_bottom = v;
        }
        for (name, target) in [
            ("page-width", &mut page.width_twips),
            ("page-height", &mut page.height_twips),
            ("margin-left", &mut page.margin_left),
            ("margin-right", &mut page.margin_right),
            ("margin-top", &mut page.margin_top),
            ("margin-bottom", &mut page.margin_bottom),
        ] {
            if let Some(v) = attr(p, F, name) {
                *target = nonnegative(v)?;
            }
        }
    }
    let body = content_doc
        .descendants()
        .find(|n| n.has_tag_name((O, "text")))
        .ok_or_else(|| bad("missing ODT text"))?;
    let mut r = Reader {
        styles: style_map,
        parts: &parts,
        state: State::default(),
        next: 1,
        pending_fields: vec![],
    };
    r.state.blocks.clear();
    r.blocks(body, 0, None)?;
    if r.state.blocks.is_empty() {
        return Err(bad("empty ODT document"));
    }
    if let Some(master) = master {
        let mut header = Vec::new();
        let mut footer = Vec::new();
        for section in master
            .children()
            .filter(|n| n.is_element() && matches!(n.tag_name().name(), "header" | "footer"))
        {
            let target = if section.has_tag_name((S, "header")) {
                &mut header
            } else {
                &mut footer
            };
            for p in section.children().filter(|n| n.is_element()) {
                if !p.has_tag_name((T, "p")) {
                    return Err(unsupported("ODT header content"));
                }
                target.push(r.para(p, None)?);
            }
        }
        r.state.sections[0].header = header.clone();
        r.state.sections[0].footer = footer.clone();
        let header_ids: HashSet<_> = header.iter().chain(&footer).map(|p| p.id).collect();
        r.state.odt_source_header_fields = Some(
            r.state
                .fields
                .iter()
                .filter(|f| header_ids.contains(&f.at.paragraph))
                .cloned()
                .collect(),
        );
        r.state.odt_source_headers = Some((header, footer));
    }
    r.state.next_id = r.next;
    r.state.sections[0].page = page.clone();
    r.state.odt_source_page = Some(page);
    let mut state = r.state;
    state.odt_parts = parts;
    Ok(state)
}
struct Writer {
    automatic: String,
    next: usize,
    pictures: Vec<(String, String, Vec<u8>)>,
    used: HashSet<String>,
    fields: Vec<Field>,
}
impl Writer {
    fn name(&mut self, prefix: &str) -> String {
        self.next += 1;
        format!("DOC42{prefix}{}", self.next)
    }
    fn paragraph(&mut self, p: &Paragraph) -> Result<String, Error> {
        let name = self.name("P");
        let align = match p.style.alignment {
            Alignment::Left => "left",
            Alignment::Center => "center",
            Alignment::Right => "right",
            Alignment::Justify => "justify",
        };
        let parent = p
            .style
            .source_style
            .as_ref()
            .map(|s| format!(" style:parent-style-name=\"{}\"", esc(s)))
            .unwrap_or_default();
        let keep = if p.style.keep_with_next {
            " fo:keep-with-next=\"always\""
        } else {
            ""
        };
        let together = if p.style.keep_lines {
            " fo:keep-together=\"always\""
        } else {
            ""
        };
        let pagebreak = if p.style.page_break_before {
            " fo:break-before=\"page\""
        } else {
            ""
        };
        let line = if p.style.line_twips == 0 {
            String::new()
        } else {
            format!(" fo:line-height=\"{}pt\"", p.style.line_twips as f64 / 20.0)
        };
        let extra = extra_attrs(&p.style.odt_extra)?;
        let tabs = if p.style.tabs_twips.is_empty() {
            String::new()
        } else {
            format!(
                "<style:tab-stops>{}</style:tab-stops>",
                p.style
                    .tabs_twips
                    .iter()
                    .map(|n| format!(
                        "<style:tab-stop style:position=\"{}pt\" style:type=\"left\"/>",
                        *n as f64 / 20.0
                    ))
                    .collect::<String>()
            )
        };
        self.automatic.push_str(&format!("<style:style style:name=\"{name}\" style:family=\"paragraph\"{parent}><style:paragraph-properties fo:text-align=\"{align}\" fo:margin-left=\"{}pt\" fo:margin-right=\"{}pt\" fo:text-indent=\"{}pt\" fo:margin-top=\"{}pt\" fo:margin-bottom=\"{}pt\"{line}{keep}{together}{pagebreak}{extra}>{tabs}</style:paragraph-properties></style:style>",p.style.left_twips as f64/20.0,p.style.right_twips as f64/20.0,p.style.first_line_twips as f64/20.0,p.style.before_twips as f64/20.0,p.style.after_twips as f64/20.0));
        let (tag, outline) = if let Some(l) = p.style.outline_level {
            if l >= 10 {
                return Err(unsupported("ODT outline level"));
            }
            ("h", format!(" text:outline-level=\"{}\"", l + 1))
        } else {
            ("p", String::new())
        };
        let mut out = format!("<text:{tag} text:style-name=\"{name}\"{outline}>");
        let mut markers = self
            .fields
            .iter()
            .filter(|f| f.at.paragraph == p.id)
            .cloned()
            .collect::<Vec<_>>();
        markers.sort_by_key(|f| f.at.offset);
        let mut marker_index = 0;
        let mut base = 0usize;
        for run in &p.runs {
            if run.style.theme_color.is_some() {
                return Err(unsupported("ODT theme color"));
            }
            let style = self.name("T");
            let t = &run.style;
            let parent = t
                .source_style
                .as_ref()
                .map(|s| format!(" style:parent-style-name=\"{}\"", esc(s)))
                .unwrap_or_default();
            let c = t
                .color
                .map(|c| format!(" fo:color=\"#{:06x}\"", c & 0xffffff))
                .unwrap_or_default();
            let h = t
                .highlight
                .map(|c| format!(" fo:background-color=\"#{:06x}\"", c & 0xffffff))
                .unwrap_or_default();
            let extra = extra_attrs(&t.odt_extra)?;
            self.automatic.push_str(&format!("<style:style style:name=\"{style}\" style:family=\"text\"{parent}><style:text-properties fo:font-family=\"{}\" fo:font-size=\"{}pt\" fo:font-weight=\"{}\" fo:font-style=\"{}\" style:text-underline-style=\"{}\" style:text-line-through-style=\"{}\"{c}{h}{extra}/></style:style>",esc(&t.font),t.size_half_points as f64/2.0,if t.bold{"bold"}else{"normal"},if t.italic{"italic"}else{"normal"},if t.underline{"solid"}else{"none"},if t.strike{"solid"}else{"none"}));
            let end = base + run.text.len();
            let mut cursor = base;
            let mut inner = String::new();
            while marker_index < markers.len() && markers[marker_index].at.offset <= end {
                let field = &markers[marker_index];
                let piece = run
                    .text
                    .get(cursor - base..field.at.offset - base)
                    .ok_or_else(|| bad("ODT field boundary"))?;
                inner.push_str(&odt_text(piece));
                inner.push_str(odt_field(&field.kind)?);
                cursor = field.at.offset;
                marker_index += 1;
            }
            inner.push_str(&odt_text(
                run.text
                    .get(cursor - base..)
                    .ok_or_else(|| bad("ODT field boundary"))?,
            ));
            base = end;
            let content = format!("<text:span text:style-name=\"{style}\">{inner}</text:span>");
            if let Some(link) = &run.link {
                out.push_str(&format!(
                    "<text:a xlink:href=\"{}\">{content}</text:a>",
                    esc(link)
                ))
            } else {
                out.push_str(&content)
            }
        }
        while marker_index < markers.len() {
            if markers[marker_index].at.offset != base {
                return Err(bad("ODT field position"));
            }
            out.push_str(odt_field(&markers[marker_index].kind)?);
            marker_index += 1;
        }
        out.push_str(&format!("</text:{tag}>"));
        Ok(out)
    }
    fn image(&mut self, i: &Image) -> Result<String, Error> {
        let ext = match i.mime.as_str() {
            "image/png" => "png",
            "image/jpeg" => "jpg",
            _ => return Err(unsupported("ODT image format")),
        };
        let mut n = 0;
        let path = loop {
            let candidate = format!("Pictures/DOC42-{}-{n}.{ext}", i.id);
            if self.used.insert(candidate.clone()) {
                break candidate;
            }
            n += 1;
        };
        self.pictures
            .push((path.clone(), i.mime.clone(), i.data.clone()));
        Ok(format!("<text:p><draw:frame text:anchor-type=\"paragraph\" svg:width=\"{}pt\" svg:height=\"{}pt\"><draw:image xlink:href=\"{}\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/><svg:desc>{}</svg:desc></draw:frame></text:p>",i.width_twips as f64/20.0,i.height_twips as f64/20.0,esc(&path),esc(&i.alt)))
    }
    fn table(&mut self, t: &Table) -> Result<String, Error> {
        let mut out = String::from("<table:table>");
        for row in &t.rows {
            out.push_str("<table:table-row>");
            for cell in row {
                if cell.row_span != 1
                    || cell.col_span != 1
                    || cell.border.is_some()
                    || cell.fill.is_some()
                    || cell.paragraphs.is_empty()
                {
                    return Err(unsupported("ODT merged or styled table cells"));
                }
                out.push_str("<table:table-cell>");
                for p in &cell.paragraphs {
                    if p.style.list.is_some() {
                        return Err(unsupported("ODT list inside table"));
                    }
                    out.push_str(&self.paragraph(p)?);
                }
                out.push_str("</table:table-cell>");
            }
            out.push_str("</table:table-row>");
        }
        out.push_str("</table:table>");
        Ok(out)
    }
}
fn odt_field(kind: &FieldKind) -> Result<&'static str, Error> {
    match kind {
        FieldKind::PageNumber => {
            Ok("<text:page-number text:select-page=\"current\">1</text:page-number>")
        }
        FieldKind::PageCount => Ok("<text:page-count>1</text:page-count>"),
        _ => Err(unsupported("ODT field")),
    }
}
fn odt_text(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        match c {
            ' ' => out.push_str("<text:s/>"),
            '\t' => out.push_str("<text:tab/>"),
            _ => out.push_str(&esc(&c.to_string())),
        }
    }
    out
}
fn close_lists(out: &mut String, stack: &mut Vec<(u64, bool)>) {
    while stack.pop().is_some() {
        out.push_str("</text:list-item></text:list>")
    }
}
fn xml_insert(xml: &mut String, addition: &str) -> Result<(), Error> {
    let i = xml.rfind("</").ok_or_else(|| bad("invalid ODT manifest"))?;
    xml.insert_str(i, addition);
    Ok(())
}
pub(super) fn encode(s: &State) -> Result<Vec<u8>, Error> {
    if s.sections.len() != 1
        || s.sections[0].page.columns != 1
        || !s.comments.is_empty()
        || !s.footnotes.is_empty()
        || !s.revisions.is_empty()
    {
        return Err(unsupported("ODT sections, columns or review content"));
    }
    let header_ids: HashSet<_> = s.sections[0]
        .header
        .iter()
        .chain(&s.sections[0].footer)
        .map(|p| p.id)
        .collect();
    if s.fields.iter().any(|f| {
        !header_ids.contains(&f.at.paragraph)
            || !matches!(f.kind, FieldKind::PageNumber | FieldKind::PageCount)
    }) {
        return Err(unsupported("ODT body or custom fields"));
    }
    if let Some(source) = &s.odt_source_header_fields {
        let current: Vec<_> = s
            .fields
            .iter()
            .filter(|f| header_ids.contains(&f.at.paragraph))
            .cloned()
            .collect();
        if *source != current {
            return Err(unsupported("editing fields in imported ODT header"));
        }
    }
    if let Some(original) = &s.odt_source_page {
        if original != &s.sections[0].page {
            return Err(unsupported("editing page setup in an imported ODT"));
        }
    }
    if let Some((header, footer)) = &s.odt_source_headers {
        if header != &s.sections[0].header || footer != &s.sections[0].footer {
            return Err(unsupported("editing headers in an imported ODT"));
        }
    }
    let mut parts = s.odt_parts.clone();
    if parts
        .keys()
        .any(|k| k.to_ascii_lowercase().contains("signature"))
    {
        return Err(unsupported("signed ODT package"));
    }
    parts.remove("mimetype");
    parts.remove("content.xml");
    let mut w = Writer {
        automatic: String::new(),
        next: 0,
        pictures: vec![],
        used: parts.keys().cloned().collect(),
        fields: s.fields.clone(),
    };
    let mut lists = String::new();
    let mut seen = HashSet::new();
    for p in s.blocks.iter().filter_map(|b| {
        if let Block::Paragraph(p) = b {
            Some(p)
        } else {
            None
        }
    }) {
        if let Some(l) = &p.style.list {
            if l.level > 8 {
                return Err(unsupported("ODT list depth"));
            }
            if seen.insert((l.id, l.numbered)) {
                let kind = if l.numbered { "number" } else { "bullet" };
                lists.push_str(&format!(
                    "<text:list-style style:name=\"DOC42L{}{}\">",
                    l.id,
                    if l.numbered { "N" } else { "B" }
                ));
                for level in 1..=9 {
                    let extra = if l.numbered {
                        " style:num-format=\"1\""
                    } else {
                        " text:bullet-char=\"•\""
                    };
                    lists.push_str(&format!(
                        "<text:list-level-style-{kind} text:level=\"{level}\"{extra}/>"
                    ));
                }
                lists.push_str("</text:list-style>");
            }
        }
    }
    let mut body = String::new();
    let mut stack: Vec<(u64, bool)> = Vec::new();
    for block in &s.blocks {
        if let Block::Paragraph(p) = block {
            if let Some(list) = &p.style.list {
                let level = list.level as usize;
                while stack.len() > level + 1 {
                    stack.pop();
                    body.push_str("</text:list-item></text:list>");
                }
                if stack.len() == level + 1 {
                    if stack[level] == (list.id, list.numbered) {
                        body.push_str("</text:list-item>")
                    } else {
                        stack.pop();
                        body.push_str("</text:list-item></text:list>");
                    }
                }
                if stack.len() < level {
                    return Err(unsupported("discontinuous ODT list depth"));
                }
                if stack.len() == level {
                    body.push_str(&format!(
                        "<text:list text:style-name=\"DOC42L{}{}\">",
                        list.id,
                        if list.numbered { "N" } else { "B" }
                    ));
                    stack.push((list.id, list.numbered));
                }
                body.push_str("<text:list-item>");
                body.push_str(&w.paragraph(p)?);
                continue;
            }
        }
        close_lists(&mut body, &mut stack);
        match block {
            Block::Paragraph(p) => body.push_str(&w.paragraph(p)?),
            Block::Image(i) => body.push_str(&w.image(i)?),
            Block::Table(t) => body.push_str(&w.table(t)?),
            Block::SectionBreak => return Err(unsupported("ODT section break")),
        }
    }
    close_lists(&mut body, &mut stack);
    let content=format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content {NS} office:version=\"1.3\"><office:automatic-styles>{lists}{}</office:automatic-styles><office:body><office:text>{body}</office:text></office:body></office:document-content>",w.automatic);
    parts.insert("content.xml".into(), content.into_bytes());
    if !parts.contains_key("styles.xml") {
        let p = &s.sections[0].page;
        let header = if s.sections[0].header.is_empty() {
            String::new()
        } else {
            let mut out = String::from("<style:header>");
            for paragraph in &s.sections[0].header {
                out.push_str(&w.paragraph(paragraph)?)
            }
            out.push_str("</style:header>");
            out
        };
        let footer = if s.sections[0].footer.is_empty() {
            String::new()
        } else {
            let mut out = String::from("<style:footer>");
            for paragraph in &s.sections[0].footer {
                out.push_str(&w.paragraph(paragraph)?)
            }
            out.push_str("</style:footer>");
            out
        };
        let styles=format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-styles {NS} office:version=\"1.3\"><office:styles/><office:automatic-styles>{}<style:page-layout style:name=\"DOC42Page\"><style:page-layout-properties fo:page-width=\"{}pt\" fo:page-height=\"{}pt\" fo:margin-left=\"{}pt\" fo:margin-right=\"{}pt\" fo:margin-top=\"{}pt\" fo:margin-bottom=\"{}pt\"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name=\"Standard\" style:page-layout-name=\"DOC42Page\">{header}{footer}</style:master-page></office:master-styles></office:document-styles>",w.automatic,p.width_twips as f64/20.0,p.height_twips as f64/20.0,p.margin_left as f64/20.0,p.margin_right as f64/20.0,p.margin_top as f64/20.0,p.margin_bottom as f64/20.0);
        parts.insert("styles.xml".into(), styles.into_bytes());
    }
    let mut manifest = if let Some(bytes) = parts.remove("META-INF/manifest.xml") {
        let text = String::from_utf8(bytes).map_err(bad)?;
        if text.contains("encryption-data") {
            return Err(unsupported("encrypted ODT package"));
        }
        text
    } else {
        format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"{MIME}\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>")
    };
    for (path, mime, data) in w.pictures {
        xml_insert(
            &mut manifest,
            &format!(
                "<manifest:file-entry manifest:full-path=\"{}\" manifest:media-type=\"{}\"/>",
                esc(&path),
                esc(&mime)
            ),
        )?;
        parts.insert(path, data);
    }
    parts.insert("META-INF/manifest.xml".into(), manifest.into_bytes());
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    zip.start_file(
        "mimetype",
        SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
    )
    .map_err(bad)?;
    zip.write_all(MIME.as_bytes()).map_err(bad)?;
    for (name, data) in parts {
        zip.start_file(
            name,
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        )
        .map_err(bad)?;
        zip.write_all(&data).map_err(bad)?;
    }
    let out = zip.finish().map_err(bad)?.into_inner();
    if out.len() > MAX_BYTES {
        return Err(Error::Limit);
    }
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn paragraph(id: u64, text: &str) -> Paragraph {
        Paragraph {
            id,
            style: ParagraphStyle::default(),
            runs: vec![Run {
                text: text.into(),
                style: TextStyle::default(),
                link: None,
            }],
        }
    }
    #[test]
    fn retained_style_attributes_survive_rich_projection_and_save() {
        let mut s = State::default();
        let Block::Paragraph(p) = &mut s.blocks[0] else {
            panic!()
        };
        p.runs[0].text = "hello".into();
        p.runs[0]
            .style
            .odt_extra
            .insert("fo:language".into(), "en".into());
        p.style
            .odt_extra
            .insert("fo:line-height".into(), "120%".into());
        let bytes = encode(&s).unwrap();
        let mut d = RichDocument::decode(&bytes, Format::Odt).unwrap();
        let projection = d.rich_edit_projection().unwrap();
        d.apply_rich_edit_projection(&projection, (0, 0)).unwrap();
        let output = d.encode(Format::Odt).unwrap();
        let reopened = RichDocument::decode(&output, Format::Odt).unwrap();
        let Block::Paragraph(p) = &reopened.state().blocks[0] else {
            panic!()
        };
        assert_eq!(
            p.style.odt_extra.get("fo:line-height").map(String::as_str),
            Some("120%")
        );
        assert_eq!(
            p.runs[0]
                .style
                .odt_extra
                .get("fo:language")
                .map(String::as_str),
            Some("en")
        );
    }
    #[test]
    fn styled_list_table_image_page_and_header_round_trip() {
        let mut s = State::default();
        let Block::Paragraph(p) = &mut s.blocks[0] else {
            panic!()
        };
        p.runs[0].text = "Hello world".into();
        p.runs[0].style.bold = true;
        p.runs[0].style.color = Some(0x336699);
        p.style.alignment = Alignment::Center;
        s.sections[0].page.margin_top = 1000;
        let mut list = paragraph(2, "first");
        list.style.list = Some(ListMarker {
            id: 3,
            level: 0,
            numbered: true,
        });
        s.blocks.push(Block::Paragraph(list));
        let mut child = paragraph(4, "nested");
        child.style.list = Some(ListMarker {
            id: 5,
            level: 1,
            numbered: false,
        });
        s.blocks.push(Block::Paragraph(child));
        s.blocks.push(Block::Table(Table {
            id: 6,
            rows: vec![vec![Cell {
                paragraphs: vec![paragraph(7, "cell")],
                row_span: 1,
                col_span: 1,
                border: None,
                fill: None,
            }]],
        }));
        s.blocks.push(Block::Image(Image {
            id: 8,
            mime: "image/png".into(),
            data: vec![137, 80, 78, 71, 13, 10, 26, 10, 0, 0],
            width_twips: 1440,
            height_twips: 720,
            alt: "picture".into(),
        }));
        s.sections[0].header.push(paragraph(9, "header"));
        s.next_id = 10;
        let bytes = encode(&s).unwrap();
        let decoded = decode(&bytes).unwrap();
        assert_eq!(decoded.blocks.len(), 5);
        let Block::Paragraph(p) = &decoded.blocks[0] else {
            panic!()
        };
        assert!(p.runs[0].style.bold);
        assert_eq!(p.runs[0].style.color, Some(0x336699));
        assert_eq!(p.style.alignment, Alignment::Center);
        let Block::Paragraph(child) = &decoded.blocks[2] else {
            panic!()
        };
        assert_eq!(child.style.list.as_ref().unwrap().level, 1);
        let Block::Table(table) = &decoded.blocks[3] else {
            panic!()
        };
        assert_eq!(table.rows[0][0].paragraphs[0].runs[0].text, "cell");
        let Block::Image(image) = &decoded.blocks[4] else {
            panic!()
        };
        assert_eq!(image.alt, "picture");
        assert_eq!(decoded.sections[0].page.margin_top, 1000);
        assert_eq!(decoded.sections[0].header[0].runs[0].text, "header");
        let reopened = decode(&encode(&decoded).unwrap()).unwrap();
        assert_eq!(reopened.blocks.len(), 5);
    }
}
