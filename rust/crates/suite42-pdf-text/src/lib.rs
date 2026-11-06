//! Embedded Noto Sans Type0 font shared by PDF-producing applications.
use lopdf::{dictionary, Document, Object, ObjectId, Stream};
use std::collections::BTreeMap;

pub struct PdfFont {
    pub id: ObjectId,
    pub chars: BTreeMap<char, (u16, u16, u32)>,
}
impl PdfFont {
    pub fn validate(text: &str) -> Result<(), String> {
        let data = include_bytes!("../../doc42-layout-probe/fixtures/NotoSans.ttf");
        let face =
            ttf_parser::Face::parse(data, 0).map_err(|e| format!("Invalid bundled font: {e:?}"))?;
        for ch in text.chars() {
            if face.glyph_index(ch).is_none() {
                return Err(format!("Bundled font lacks character {ch:?}"));
            }
        }
        Ok(())
    }
    pub fn embed(doc: &mut Document, text: &str) -> Result<Self, String> {
        // Noto Sans is distributed under OFL 1.1 alongside the bundled font.
        let font_data = include_bytes!("../../doc42-layout-probe/fixtures/NotoSans.ttf");
        let face = ttf_parser::Face::parse(font_data, 0)
            .map_err(|e| format!("Invalid bundled font: {e:?}"))?;
        let mut chars = std::collections::BTreeMap::new();
        for ch in text.chars() {
            if !chars.contains_key(&ch) {
                let glyph = face
                    .glyph_index(ch)
                    .ok_or_else(|| format!("Bundled font lacks character {ch:?}"))?;
                let cid =
                    u16::try_from(chars.len() + 1).map_err(|_| "Too many distinct characters")?;
                let width = u32::from(face.glyph_hor_advance(glyph).unwrap_or(face.units_per_em()))
                    * 1000
                    / u32::from(face.units_per_em());
                chars.insert(ch, (cid, glyph.0, width));
            }
        }
        // Reuse only an actual identical embedded font stream. CID maps and
        // ToUnicode remain separate for each independently encoded character set.
        let existing = doc
            .objects
            .iter()
            .filter_map(|(id, obj)| obj.as_stream().ok().map(|s| (*id, s)))
            .take(10_000)
            .find_map(|(id, stream)| {
                if stream
                    .dict
                    .get(b"Length1")
                    .ok()
                    .and_then(|v| v.as_i64().ok())
                    != Some(font_data.len() as i64)
                {
                    return None;
                }
                if stream.dict.get(b"Filter").is_ok() {
                    stream
                        .decompressed_content_with_limit(font_data.len() + 1)
                        .ok()
                        .filter(|bytes| bytes.as_slice() == font_data)
                        .map(|_| id)
                } else if stream.content.as_slice() == font_data {
                    Some(id)
                } else {
                    None
                }
            });
        let font_stream = existing.unwrap_or_else(|| {
            doc.add_object(Stream::new(
                dictionary! {"Length1"=>font_data.len() as i64},
                font_data.to_vec(),
            ))
        });
        let descriptor = doc.add_object(dictionary! {"Type"=>"FontDescriptor", "FontName"=>"NotoSans", "Flags"=>32, "FontBBox"=>vec![(-1000).into(),(-1000).into(),3000.into(),3000.into()], "ItalicAngle"=>0, "Ascent"=>1100, "Descent"=>-300, "CapHeight"=>750, "StemV"=>80, "FontFile2"=>font_stream});
        let mut cid_to_gid = vec![0u8; (chars.len() + 1) * 2];
        let mut widths = vec![Object::Integer(0); chars.len() + 1];
        let mut cmap = String::from("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /SCN42Unicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        for chunk in chars.iter().collect::<Vec<_>>().chunks(100) {
            cmap.push_str(&format!("{} beginbfchar\n", chunk.len()));
            for (ch, &(cid, glyph, width)) in chunk {
                cid_to_gid[usize::from(cid) * 2..usize::from(cid) * 2 + 2]
                    .copy_from_slice(&glyph.to_be_bytes());
                widths[usize::from(cid)] = Object::Integer(width.into());
                let mut units = [0u16; 2];
                let utf16: String = ch
                    .encode_utf16(&mut units)
                    .iter()
                    .map(|v| format!("{v:04X}"))
                    .collect();
                cmap.push_str(&format!("<{cid:04X}> <{utf16}>\n"));
            }
            cmap.push_str("endbfchar\n");
        }
        cmap.push_str("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        let map = doc.add_object(Stream::new(dictionary! {}, cid_to_gid));
        let unicode = doc.add_object(Stream::new(dictionary! {}, cmap.into_bytes()));
        let cidfont = doc.add_object(dictionary! {"Type"=>"Font", "Subtype"=>"CIDFontType2", "BaseFont"=>"NotoSans", "CIDSystemInfo"=>dictionary! {"Registry"=>Object::string_literal("Adobe"), "Ordering"=>Object::string_literal("Identity"), "Supplement"=>0}, "FontDescriptor"=>descriptor, "CIDToGIDMap"=>map, "W"=>vec![Object::Integer(0), Object::Array(widths)]});
        let font = doc.add_object(dictionary! {"Type"=>"Font", "Subtype"=>"Type0", "BaseFont"=>"NotoSans", "Encoding"=>"Identity-H", "DescendantFonts"=>vec![Object::Reference(cidfont)], "ToUnicode"=>unicode});
        Ok(Self { id: font, chars })
    }
    pub fn encode(&self, text: &str) -> Result<String, String> {
        text.chars()
            .map(|c| {
                self.chars
                    .get(&c)
                    .map(|v| format!("{:04X}", v.0))
                    .ok_or_else(|| format!("Font lacks character {c:?}"))
            })
            .collect()
    }
}
