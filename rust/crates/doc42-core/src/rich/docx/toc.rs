//! Normalize a supported Word TOC field for the ordinary paragraph reader.
use super::*;
use std::collections::{BTreeMap, BTreeSet};

pub(super) struct Scan {
    pub tables: Vec<Vec<(usize, String)>>,
    pub bookmarks: BTreeMap<String, usize>,
}

pub(super) fn normalize(xml: &str) -> Result<(String, Option<Scan>), Error> {
    let doc = roxmltree::Document::parse(xml).map_err(bad)?;
    if !doc.descendants().any(|n| {
        n.has_tag_name((W, "instrText")) && n.text().unwrap_or("").trim_start().starts_with("TOC ")
    }) {
        return Ok((xml.to_owned(), None));
    }
    let body = doc
        .descendants()
        .find(|n| n.has_tag_name((W, "body")))
        .ok_or_else(|| bad("DOCX body"))?;
    let mut ranges = Vec::new();
    let mut tables: Vec<Vec<(usize, String)>> = Vec::new();
    let mut state = 0u8;
    let mut instruction = String::new();
    let mut all_bookmarks: BTreeMap<String, (String, usize, std::ops::Range<usize>)> =
        BTreeMap::new();
    let mut ends = BTreeMap::new();
    for (index, p) in body.children().filter(|n| n.is_element()).enumerate() {
        if !p.has_tag_name((W, "p")) {
            if state != 0 {
                return Err(Error::Unsupported("non-paragraph Word TOC".into()));
            }
            continue;
        }
        for child in p.children().filter(|n| n.is_element()) {
            if child.has_tag_name((W, "bookmarkStart")) {
                if child
                    .attributes()
                    .any(|a| a.namespace() != Some(W) || !["id", "name"].contains(&a.name()))
                    || child.children().any(|n| n.is_element())
                {
                    return Err(Error::Unsupported("Word bookmark attributes".into()));
                }
                let id = val(child, "id").ok_or_else(|| bad("bookmark id"))?;
                let name = val(child, "name").ok_or_else(|| bad("bookmark name"))?;
                if all_bookmarks
                    .insert(name.to_owned(), (id.to_owned(), index, child.range()))
                    .is_some()
                {
                    return Err(bad("duplicate bookmark"));
                }
            } else if child.has_tag_name((W, "bookmarkEnd")) {
                if child
                    .attributes()
                    .any(|a| a.namespace() != Some(W) || a.name() != "id")
                    || child.children().any(|n| n.is_element())
                {
                    return Err(Error::Unsupported("Word bookmark end attributes".into()));
                }
                let id = val(child, "id").ok_or_else(|| bad("bookmark end"))?;
                if ends.insert(id.to_owned(), child.range()).is_some() {
                    return Err(bad("duplicate bookmark end"));
                }
            } else if child.has_tag_name((W, "r")) {
                let children: Vec<_> = child.children().filter(|n| n.is_element()).collect();
                if children.len() == 1 && children[0].has_tag_name((W, "fldChar")) {
                    if children[0]
                        .attributes()
                        .any(|a| a.namespace() != Some(W) || a.name() != "fldCharType")
                        || children[0].children().any(|n| n.is_element())
                    {
                        return Err(Error::Unsupported("Word TOC field attributes".into()));
                    }
                    match val(children[0], "fldCharType") {
                        Some("begin") if state == 0 => {
                            state = 1;
                            instruction.clear();
                            ranges.push(child.range());
                        }
                        Some("separate")
                            if state == 1 && instruction.trim_start().starts_with("TOC ") =>
                        {
                            let words = instruction.split_whitespace().collect::<Vec<_>>();
                            if words != ["TOC", "\\o", "\"1-9\"", "\\h", "\\z", "\\u"] {
                                return Err(Error::Unsupported("Word TOC field switches".into()));
                            }
                            state = 2;
                            tables.push(Vec::new());
                            ranges.push(child.range());
                        }
                        Some("end") if state == 2 => {
                            state = 0;
                            ranges.push(child.range());
                        }
                        _ if state != 0 => {
                            return Err(Error::Unsupported("complex Word TOC field".into()))
                        }
                        _ => {}
                    }
                } else if state == 1
                    && children.len() == 1
                    && children[0].has_tag_name((W, "instrText"))
                {
                    instruction.push_str(children[0].text().unwrap_or(""));
                    ranges.push(child.range());
                } else if state != 0 {
                    return Err(Error::Unsupported("Word TOC field result".into()));
                }
            } else if child.has_tag_name((W, "hyperlink")) && state == 2 {
                let target = val(child, "anchor")
                    .ok_or_else(|| Error::Unsupported("external Word TOC link".into()))?;
                if child
                    .attributes()
                    .any(|a| a.namespace() != Some(W) || a.name() != "anchor")
                {
                    return Err(Error::Unsupported("Word TOC link attributes".into()));
                }
                let range = child.range();
                let text = &xml[range.clone()];
                let open = text.find('>').ok_or_else(|| bad("Word TOC link"))? + 1;
                let close = text.rfind('<').ok_or_else(|| bad("Word TOC link"))?;
                ranges.push(range.start..range.start + open);
                ranges.push(range.start + close..range.end);
                tables.last_mut().unwrap().push((index, target.to_owned()));
            } else if state != 0 && !child.has_tag_name((W, "pPr")) {
                return Err(Error::Unsupported("Word TOC content".into()));
            }
        }
    }
    if state != 0 || tables.is_empty() || tables.iter().any(Vec::is_empty) {
        return Err(Error::Unsupported("incomplete Word TOC".into()));
    }
    let wanted: BTreeSet<_> = tables
        .iter()
        .flatten()
        .map(|(_, name)| name.clone())
        .collect();
    let mut bookmarks = BTreeMap::new();
    for name in wanted {
        let (id, index, start) = all_bookmarks
            .get(&name)
            .ok_or_else(|| Error::Unsupported("unresolved Word TOC bookmark".into()))?;
        let end = ends.get(id).ok_or_else(|| bad("unclosed bookmark"))?;
        ranges.push(start.clone());
        ranges.push(end.clone());
        bookmarks.insert(name, *index);
    }
    ranges.sort_by_key(|r| r.start);
    if ranges.windows(2).any(|w| w[0].end > w[1].start) {
        return Err(bad("overlapping Word field ranges"));
    }
    let mut output = xml.to_owned();
    for range in ranges.into_iter().rev() {
        output.replace_range(range, "");
    }
    Ok((output, Some(Scan { tables, bookmarks })))
}
