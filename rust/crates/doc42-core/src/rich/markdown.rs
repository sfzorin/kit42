//! CommonMark/GFM text adapter. Unsupported model features fail before export.
use super::*;
use pulldown_cmark::{html, Options, Parser};
fn unsupported(s: &str) -> Error {
    Error::Unsupported(format!("Markdown {s}"))
}
pub(super) fn decode(bytes: &[u8]) -> Result<State, Error> {
    decode_with(bytes, None)
}
pub(super) fn decode_with(
    bytes: &[u8],
    resolver: Option<&dyn Fn(&str) -> Result<Vec<u8>, Error>>,
) -> Result<State, Error> {
    let input = std::str::from_utf8(bytes).map_err(|e| Error::Invalid(e.to_string()))?;
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH;
    let parser = Parser::new_ext(input, options);
    let mut body = String::new();
    html::push_html(&mut body, parser);
    let document = format!("<!doctype html><html><body>{body}</body></html>");
    super::html::decode_with(document.as_bytes(), resolver)
}
fn escaped(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        if matches!(
            c,
            '\\' | '`'
                | '*'
                | '_'
                | '{'
                | '}'
                | '['
                | ']'
                | '<'
                | '>'
                | '#'
                | '+'
                | '-'
                | '!'
                | '|'
                | '~'
        ) {
            out.push('\\')
        }
        out.push(c)
    }
    out
}
fn run(r: &Run) -> Result<String, Error> {
    let t = &r.style;
    if t.source_style.is_some()
        || !t.odt_extra.is_empty()
        || t.theme_color.is_some()
        || t.color.is_some()
        || t.highlight.is_some()
        || t.underline
        || t.size_half_points != 24
        || (!matches!(t.font.as_str(), "Arial" | "monospace"))
    {
        return Err(unsupported("character formatting"));
    }
    let raw = escaped(&r.text);
    let mut text = if t.font == "monospace" {
        if r.text.contains('`') {
            return Err(unsupported("inline code containing backtick"));
        }
        format!("`{}`", r.text)
    } else {
        raw
    };
    if t.strike {
        text = format!("~~{text}~~")
    }
    if t.italic {
        text = format!("*{text}*")
    }
    if t.bold {
        text = format!("**{text}**")
    }
    if let Some(url) = &r.link {
        if url.contains(['(', ')', '\n', '\r']) {
            return Err(unsupported("link target"));
        }
        text = format!("[{text}]({url})");
    }
    Ok(text)
}
fn paragraph(p: &Paragraph) -> Result<String, Error> {
    let mut plain = p.style.clone();
    plain.list = None;
    plain.outline_level = None;
    if plain != ParagraphStyle::default() {
        return Err(unsupported("paragraph formatting"));
    }
    let mut out = String::new();
    for r in &p.runs {
        out.push_str(&run(r)?)
    }
    Ok(out)
}
pub(super) fn encode(s: &State) -> Result<Vec<u8>, Error> {
    if s.sections.len() != 1
        || s.sections[0].page != PageSettings::default()
        || !s.sections[0].header.is_empty()
        || !s.sections[0].footer.is_empty()
        || !s.comments.is_empty()
        || !s.footnotes.is_empty()
        || !s.revisions.is_empty()
        || !s.fields.is_empty()
    {
        return Err(unsupported("page or review content"));
    }
    let mut out = String::new();
    let mut previous_list: Option<(u64, bool)> = None;
    for block in &s.blocks {
        match block {
            Block::Paragraph(p) => {
                let text = paragraph(p)?;
                if let Some(list) = &p.style.list {
                    if list.level > 8 {
                        return Err(unsupported("list depth"));
                    }
                    if previous_list
                        .is_some_and(|(id, kind)| id != list.id && kind == list.numbered)
                    {
                        return Err(unsupported("adjacent distinct lists"));
                    }
                    out.push_str(&"  ".repeat(list.level as usize));
                    out.push_str(if list.numbered { "1. " } else { "- " });
                    out.push_str(&text);
                    out.push('\n');
                    previous_list = Some((list.id, list.numbered));
                } else {
                    if previous_list.take().is_some() {
                        out.push('\n')
                    }
                    if let Some(level) = p.style.outline_level {
                        if level > 5 {
                            return Err(unsupported("heading level"));
                        }
                        out.push_str(&"#".repeat(level as usize + 1));
                        out.push(' ')
                    }
                    out.push_str(&text);
                    out.push_str("\n\n");
                }
            }
            Block::Table(table) => {
                if previous_list.take().is_some() {
                    out.push('\n')
                }
                if table.rows.is_empty() || table.rows[0].is_empty() {
                    return Err(unsupported("empty table"));
                }
                for (i, row) in table.rows.iter().enumerate() {
                    if row.len() != table.rows[0].len() {
                        return Err(unsupported("irregular table"));
                    }
                    out.push('|');
                    for cell in row {
                        if cell.row_span != 1
                            || cell.col_span != 1
                            || cell.border.is_some()
                            || cell.fill.is_some()
                            || cell.paragraphs.len() != 1
                        {
                            return Err(unsupported("complex table"));
                        }
                        let p = &cell.paragraphs[0];
                        if p.style.list.is_some() || p.style.outline_level.is_some() {
                            return Err(unsupported("table paragraph"));
                        }
                        out.push(' ');
                        out.push_str(&paragraph(p)?);
                        out.push_str(" |");
                    }
                    out.push('\n');
                    if i == 0 {
                        out.push('|');
                        for _ in row {
                            out.push_str(" --- |")
                        }
                        out.push('\n');
                    }
                }
                out.push('\n');
            }
            Block::Image(_) => {
                return Err(unsupported("embedded image; use an image-capable format"))
            }
            _ => return Err(unsupported("section break")),
        }
    }
    Ok(out.into_bytes())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn commonmark_gfm_paragraph_lists_table_round_trip() {
        let input=b"Hello **world** and *friend*.\n\n- first\n- second\n\n| A | B |\n|---|---|\n| x | y |\n";
        let state = decode(input).unwrap();
        assert_eq!(state.blocks.len(), 4);
        let encoded = encode(&state).unwrap();
        let reopened = decode(&encoded).unwrap();
        assert_eq!(reopened.blocks.len(), 4);
        let Block::Paragraph(p) = &reopened.blocks[0] else {
            panic!()
        };
        assert!(p.runs.iter().any(|r| r.text == "world" && r.style.bold));
    }
}
