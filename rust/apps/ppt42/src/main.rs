#![cfg_attr(windows, windows_subsystem = "windows")]
use ppt42_core::Presentation;
use std::path::Path;
fn decode_image(bytes: &[u8]) -> Result<image::DynamicImage, String> {
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    reader.decode().map_err(|e| e.to_string())
}
struct Ppt {
    pending: Option<(u64, ppt42_core::SaveState)>,
    next_save: u64,
    deck: Presentation,
    pptx_source: Option<ppt42_core::pptx::Source>,
    odp_source: Option<ppt42_core::odp::Source>,
    selected_object: Option<u64>,
    drag: Option<(win42::Point, ppt42_core::SlideObject)>,
    presenting: bool,
}
impl Ppt {
    fn new(deck: Presentation) -> Self {
        Self {
            deck,
            pptx_source: None,
            odp_source: None,
            pending: None,
            next_save: 0,
            selected_object: None,
            drag: None,
            presenting: false,
        }
    }
}
impl Ppt {
    fn scene_for(&self, index: usize, show_selection: bool) -> Option<win42::CanvasScene> {
        use win42::{CanvasScene, Point, SceneItem};
        let slide = &self.deck.slides()[index];
        let background = self
            .pptx_source
            .as_ref()
            .and_then(|s| s.background(slide.source_identity()))
            .unwrap_or([255, 255, 255]);
        let decorations = self
            .pptx_source
            .as_ref()
            .map(|s| s.decorations(slide.source_identity()))
            .unwrap_or(&[]);
        let mut items = vec![
            SceneItem::Rect {
                x: 0.0,
                y: 0.0,
                width: 720.0,
                height: 405.0,
                fill: background,
                stroke: [80, 80, 80],
            },
            SceneItem::TextBox {
                x: 35.0,
                y: 30.0,
                width: 650.0,
                height: 40.0,
                text: slide.title.clone(),
                color: [0, 0, 0],
                font: win42::SceneFont {
                    family: "Arial".into(),
                    points: 28.0,
                    bold: true,
                    italic: false,
                    underline: false,
                },
                align: win42::TextAlign::Left,
                wrap: true,
            },
            SceneItem::TextBox {
                x: 35.0,
                y: 75.0,
                width: 650.0,
                height: 290.0,
                text: slide.body.clone(),
                color: [0, 0, 0],
                font: win42::SceneFont {
                    family: "Arial".into(),
                    points: 18.0,
                    bold: false,
                    italic: false,
                    underline: false,
                },
                align: win42::TextAlign::Left,
                wrap: true,
            },
        ];
        for (editable, original) in decorations
            .iter()
            .map(|o| (false, o))
            .chain(slide.objects.iter().map(|o| (true, o)))
        {
            let o = self
                .drag
                .as_ref()
                .filter(|(_, o)| {
                    editable
                        && show_selection
                        && index == self.deck.current()
                        && o.id == original.id
                })
                .map(|(_, o)| o)
                .unwrap_or(original);
            let stroke = if editable && show_selection && self.selected_object == Some(o.id) {
                [0, 100, 220]
            } else {
                o.stroke
            };
            match o.kind {
                ppt42_core::ObjectKind::Rectangle | ppt42_core::ObjectKind::Text => {
                    if o.fill_visible {
                        items.push(SceneItem::Rect {
                            x: o.x,
                            y: o.y,
                            width: o.width,
                            height: o.height,
                            fill: o.fill,
                            stroke: if o.stroke_visible
                                || (editable
                                    && show_selection
                                    && self.selected_object == Some(o.id))
                            {
                                stroke
                            } else {
                                o.fill
                            },
                        })
                    } else if o.stroke_visible
                        || (editable && show_selection && self.selected_object == Some(o.id))
                    {
                        items.push(SceneItem::Path {
                            points: vec![
                                Point { x: o.x, y: o.y },
                                Point {
                                    x: o.x + o.width,
                                    y: o.y,
                                },
                                Point {
                                    x: o.x + o.width,
                                    y: o.y + o.height,
                                },
                                Point {
                                    x: o.x,
                                    y: o.y + o.height,
                                },
                            ],
                            color: stroke,
                            closed: true,
                        });
                    }
                }
                ppt42_core::ObjectKind::Line => items.push(SceneItem::Path {
                    points: vec![
                        Point { x: o.x, y: o.y },
                        Point {
                            x: o.x + o.width,
                            y: o.y + o.height,
                        },
                    ],
                    color: stroke,
                    closed: false,
                }),
                ppt42_core::ObjectKind::Ellipse => {
                    items.push(SceneItem::Ellipse {
                        x: o.x,
                        y: o.y,
                        width: o.width,
                        height: o.height,
                        fill: o.fill_visible.then_some(o.fill),
                        stroke: (o.stroke_visible
                            || (editable && show_selection && self.selected_object == Some(o.id)))
                        .then_some(stroke),
                    });
                }
                ppt42_core::ObjectKind::Picture => {
                    if let Ok(image) = decode_image(&o.media) {
                        let pixels = image.to_rgba8();
                        items.push(SceneItem::ImageScaled {
                            x: o.x,
                            y: o.y,
                            width: o.width,
                            height: o.height,
                            pixel_width: pixels.width(),
                            pixel_height: pixels.height(),
                            rgba: pixels.into_raw(),
                        });
                        if editable && show_selection && self.selected_object == Some(o.id) {
                            items.push(SceneItem::Path {
                                points: vec![
                                    Point { x: o.x, y: o.y },
                                    Point {
                                        x: o.x + o.width,
                                        y: o.y,
                                    },
                                    Point {
                                        x: o.x + o.width,
                                        y: o.y + o.height,
                                    },
                                    Point {
                                        x: o.x,
                                        y: o.y + o.height,
                                    },
                                ],
                                color: stroke,
                                closed: true,
                            });
                        }
                    }
                }
                ppt42_core::ObjectKind::Table => {
                    let rows = o.cells.len();
                    let cols = o.cells.first().map_or(0, Vec::len);
                    if rows > 0 && cols > 0 {
                        let w = o.width / cols as f64;
                        let h = o.height / rows as f64;
                        for (r, row) in o.cells.iter().enumerate() {
                            for (c, value) in row.iter().enumerate() {
                                let x = o.x + c as f64 * w;
                                let y = o.y + r as f64 * h;
                                items.push(SceneItem::Rect {
                                    x,
                                    y,
                                    width: w,
                                    height: h,
                                    fill: o.fill,
                                    stroke,
                                });
                                items.push(SceneItem::TextBox {
                                    x: x + 4.0,
                                    y: y + 4.0,
                                    width: (w - 8.0).max(1.0),
                                    height: (h - 8.0).max(1.0),
                                    text: value.clone(),
                                    color: [0, 0, 0],
                                    font: win42::SceneFont {
                                        family: "Arial".into(),
                                        points: 12.0,
                                        bold: false,
                                        italic: false,
                                        underline: false,
                                    },
                                    align: win42::TextAlign::Left,
                                    wrap: true,
                                });
                            }
                        }
                    }
                }
            }
            if !o.text.is_empty() {
                let style = &o.text_style;
                items.push(SceneItem::TextBox {
                    x: o.x + 5.0,
                    y: o.y + 5.0,
                    width: (o.width - 10.0).max(1.0),
                    height: (o.height - 10.0).max(1.0),
                    text: o.text.clone(),
                    color: style.color,
                    font: win42::SceneFont {
                        family: style.family.clone(),
                        points: style.points,
                        bold: style.bold,
                        italic: style.italic,
                        underline: style.underline,
                    },
                    align: match style.align {
                        ppt42_core::TextAlign::Left => win42::TextAlign::Left,
                        ppt42_core::TextAlign::Center => win42::TextAlign::Center,
                        ppt42_core::TextAlign::Right => win42::TextAlign::Right,
                    },
                    wrap: true,
                });
            }
        }
        Some(CanvasScene {
            viewport: win42::Viewport::default(),
            items,
        })
    }
}
impl win42::App for Ppt {
    fn presentation_size(&self) -> Option<(f64, f64)> {
        self.presenting.then_some((720.0, 405.0))
    }
    fn print_job(&self, id: u16) -> Option<win42::PrintJob> {
        if id != 40 {
            return None;
        }
        let (width, height) = if let Some(source) = &self.odp_source {
            source.size_points()?
        } else {
            self.pptx_source
                .as_ref()
                .map(|s| s.size_points())
                .unwrap_or((720.0, 405.0))
        };
        if !width.is_finite()
            || !height.is_finite()
            || width <= 0.0
            || height <= 0.0
            || width > 100000.0
            || height > 100000.0
        {
            return None;
        }
        let geometry = win42::PrintGeometry {
            width_twips: (width * 20.0).round() as i32,
            height_twips: (height * 20.0).round() as i32,
            margin_left_twips: 0,
            margin_top_twips: 0,
            margin_right_twips: 0,
            margin_bottom_twips: 0,
        };
        let sx = width / 720.0;
        let sy = height / 405.0;
        let mut pages = Vec::new();
        for index in 0..self.deck.slides().len() {
            let mut scene = self.scene_for(index, false)?;
            for item in &mut scene.items {
                match item {
                    win42::SceneItem::Rect {
                        x,
                        y,
                        width,
                        height,
                        ..
                    } => {
                        *x *= sx;
                        *y *= sy;
                        *width *= sx;
                        *height *= sy;
                    }
                    win42::SceneItem::Ellipse {
                        x,
                        y,
                        width,
                        height,
                        ..
                    } => {
                        *x *= sx;
                        *y *= sy;
                        *width *= sx;
                        *height *= sy;
                    }
                    win42::SceneItem::Text { x, y, .. } => {
                        *x *= sx;
                        *y *= sy;
                    }
                    win42::SceneItem::TextBox {
                        x,
                        y,
                        width,
                        height,
                        font,
                        ..
                    } => {
                        *x *= sx;
                        *y *= sy;
                        *width *= sx;
                        *height *= sy;
                        font.points *= sy;
                    }
                    win42::SceneItem::Path { points, .. } => {
                        for p in points {
                            p.x *= sx;
                            p.y *= sy;
                        }
                    }
                    win42::SceneItem::Image {
                        x,
                        y,
                        width,
                        height,
                        rgba,
                    } => {
                        *x *= sx;
                        *y *= sy;
                        let nw = ((*width as f64 * sx).round() as u32).clamp(1, 4096);
                        let nh = ((*height as f64 * sy).round() as u32).clamp(1, 4096);
                        let image =
                            image::RgbaImage::from_raw(*width, *height, std::mem::take(rgba))?;
                        *rgba = image::imageops::resize(
                            &image,
                            nw,
                            nh,
                            image::imageops::FilterType::Triangle,
                        )
                        .into_raw();
                        *width = nw;
                        *height = nh;
                    }
                    win42::SceneItem::ImageScaled {
                        x,
                        y,
                        width,
                        height,
                        ..
                    } => {
                        *x *= sx;
                        *y *= sy;
                        *width *= sx;
                        *height *= sy;
                    }
                }
            }
            pages.push(win42::PrintPage { geometry, scene });
        }
        Some(win42::PrintJob::Scenes(pages))
    }
    fn open_formats(&self) -> Vec<win42::FileFormat> {
        vec![
            win42::FileFormat {
                id: "pptx",
                title: "PowerPoint presentation",
                extensions: &["pptx"],
            },
            win42::FileFormat {
                id: "odp",
                title: "OpenDocument presentation",
                extensions: &["odp"],
            },
            win42::FileFormat {
                id: "json",
                title: "Suite42 slides JSON",
                extensions: &["json"],
            },
        ]
    }
    fn file_actions(&self) -> &'static [win42::FileAction] {
        &[win42::FileAction {
            id: 32,
            title: "Insert Image…",
            save: false,
            extension: "png",
            format: "Images",
            pattern: "*.png;*.jpg;*.jpeg",
        }]
    }
    fn file_action(&mut self, id: u16, path: &Path) -> Result<(), String> {
        if id != 32 {
            return Err("Unknown file action".into());
        }
        let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
        if bytes.len() > 16 * 1024 * 1024 {
            return Err("Image exceeds size limit".into());
        }
        decode_image(&bytes)?;
        self.selected_object = Some(self.deck.insert_picture(bytes)?);
        Ok(())
    }
    fn dialog_request(&self, id: u16) -> Option<win42::DialogRequest> {
        let object = self.selected_object.and_then(|id| {
            self.deck.slides()[self.deck.current()]
                .objects
                .iter()
                .find(|o| o.id == id)
        })?;
        match id {
            30 => Some(win42::DialogRequest::Color(object.fill)),
            31 => Some(win42::DialogRequest::Color(object.stroke)),
            42 => Some(win42::DialogRequest::Font),
            _ => None,
        }
    }
    fn dialog_result(&mut self, id: u16, result: win42::DialogResult) -> Result<(), String> {
        let object_id = self.selected_object.ok_or("Select an object")?;
        let mut object = self.deck.slides()[self.deck.current()]
            .objects
            .iter()
            .find(|o| o.id == object_id)
            .cloned()
            .ok_or("Object no longer exists")?;
        match (id, result) {
            (30, win42::DialogResult::Color(color)) => object.fill = color,
            (31, win42::DialogResult::Color(color)) => object.stroke = color,
            (42, win42::DialogResult::Font(font)) => {
                let style = &mut object.text_style;
                style.family = font.family;
                style.points = font.points;
                style.bold = font.bold;
                style.italic = font.italic;
                style.underline = font.underline;
                style.color = font.color;
            }
            _ => return Err("Unknown color action".into()),
        }
        self.deck.update_object(object)
    }
    fn input_request(&self, id: u16) -> Option<win42::InputRequest> {
        let slide = &self.deck.slides()[self.deck.current()];
        match id {
            24 => Some(win42::InputRequest {
                title: "Edit slide text",
                fields: vec![("Title", slide.title.clone()), ("Body", slide.body.clone())],
            }),
            25 => self
                .selected_object
                .and_then(|id| slide.objects.iter().find(|o| o.id == id))
                .map(|o| win42::InputRequest {
                    title: "Edit object text",
                    fields: vec![("Text", o.text.clone())],
                }),
            26 => self
                .selected_object
                .and_then(|id| slide.objects.iter().find(|o| o.id == id))
                .map(|o| win42::InputRequest {
                    title: "Object geometry",
                    fields: vec![
                        ("X", o.x.to_string()),
                        ("Y", o.y.to_string()),
                        ("Width", o.width.to_string()),
                        ("Height", o.height.to_string()),
                    ],
                }),
            33 => Some(win42::InputRequest {
                title: "Insert table",
                fields: vec![("Rows", "3".into()), ("Columns", "3".into())],
            }),
            34 => self
                .selected_object
                .and_then(|id| {
                    slide
                        .objects
                        .iter()
                        .find(|o| o.id == id && matches!(o.kind, ppt42_core::ObjectKind::Table))
                })
                .map(|_| win42::InputRequest {
                    title: "Edit table cell",
                    fields: vec![
                        ("Row (1-based)", "1".into()),
                        ("Column (1-based)", "1".into()),
                        ("Text", String::new()),
                    ],
                }),
            _ => None,
        }
    }
    fn input_action(&mut self, id: u16, values: &[String]) -> Result<(), String> {
        match id {
            33 if values.len() == 2 => {
                let rows = values[0].parse().map_err(|_| "Invalid row count")?;
                let cols = values[1].parse().map_err(|_| "Invalid column count")?;
                self.selected_object = Some(self.deck.insert_table(rows, cols)?);
                Ok(())
            }
            34 if values.len() == 3 => {
                let row: usize = values[0]
                    .parse::<usize>()
                    .map_err(|_| "Invalid row")?
                    .checked_sub(1)
                    .ok_or("Invalid row")?;
                let column: usize = values[1]
                    .parse::<usize>()
                    .map_err(|_| "Invalid column")?
                    .checked_sub(1)
                    .ok_or("Invalid column")?;
                let id = self.selected_object.ok_or("Select a table")?;
                if let Some(source) = &self.pptx_source {
                    if values[2].contains('\n')
                        || !source.can_edit_cell(
                            self.deck.slides()[self.deck.current()].source_identity(),
                            id,
                            row,
                            column,
                        )
                    {
                        return Err("This PPTX cell cannot be edited without changing unsupported text structure".into());
                    }
                }
                if let Some(source) = &self.odp_source {
                    if values[2].contains('\n')
                        || !source.can_edit_cell(
                            self.deck.slides()[self.deck.current()].source_identity(),
                            id,
                            row,
                            column,
                        )
                    {
                        return Err("This ODP cell cannot be edited without changing unsupported text structure".into());
                    }
                }
                let mut object = self.deck.slides()[self.deck.current()]
                    .objects
                    .iter()
                    .find(|o| o.id == id)
                    .cloned()
                    .ok_or("Object no longer exists")?;
                *object
                    .cells
                    .get_mut(row)
                    .and_then(|r| r.get_mut(column))
                    .ok_or("Cell out of range")? = values[2].clone();
                self.deck.update_object(object)
            }
            24 if values.len() == 2 => self.deck.edit(values[0].clone(), values[1].clone()),
            25 if values.len() == 1 => {
                if (self.pptx_source.is_some() || self.odp_source.is_some())
                    && values[0].contains('\n')
                {
                    return Err("Multiline PPTX text edits are not supported yet".into());
                }
                let id = self.selected_object.ok_or("Select an object")?;
                let mut object = self.deck.slides()[self.deck.current()]
                    .objects
                    .iter()
                    .find(|o| o.id == id)
                    .cloned()
                    .ok_or("Object no longer exists")?;
                object.text = values[0].clone();
                self.deck.update_object(object)
            }
            26 if values.len() == 4 => {
                let id = self.selected_object.ok_or("Select an object")?;
                let mut object = self.deck.slides()[self.deck.current()]
                    .objects
                    .iter()
                    .find(|o| o.id == id)
                    .cloned()
                    .ok_or("Object no longer exists")?;
                let parsed = values
                    .iter()
                    .map(|v| v.parse::<f64>().map_err(|_| "Invalid geometry".to_string()))
                    .collect::<Result<Vec<_>, _>>()?;
                object.x = parsed[0];
                object.y = parsed[1];
                object.width = parsed[2];
                object.height = parsed[3];
                self.deck.update_object(object)
            }
            _ => Err("Invalid text input".into()),
        }
    }
    fn canvas_scene(&self) -> Option<win42::CanvasScene> {
        self.scene_for(self.deck.current(), !self.presenting)
    }
    fn canvas_event(&mut self, event: win42::CanvasEvent) -> Result<(), String> {
        use win42::CanvasEvent::*;
        if self.presenting {
            match event {
                Key { code: 27, .. } => self.presenting = false,
                Key {
                    code: 39 | 40 | 32 | 34,
                    ..
                }
                | PointerUp(_) => {
                    let i = self.deck.current();
                    if i + 1 < self.deck.slides().len() {
                        self.deck.select(i + 1)?;
                    }
                }
                Key {
                    code: 37 | 38 | 33, ..
                } => {
                    let i = self.deck.current();
                    if i > 0 {
                        self.deck.select(i - 1)?;
                    }
                }
                _ => {}
            }
            return Ok(());
        }
        match event {
            PointerDown(p) => {
                let object = self.deck.slides()[self.deck.current()]
                    .objects
                    .iter()
                    .rev()
                    .find(|o| {
                        p.x >= o.x && p.x <= o.x + o.width && p.y >= o.y && p.y <= o.y + o.height
                    })
                    .cloned();
                self.selected_object = object.as_ref().map(|o| o.id);
                self.drag = object.map(|o| (p, o));
            }
            PointerMove(p) => {
                if let Some((start, ref mut object)) = self.drag {
                    object.x += p.x - start.x;
                    object.y += p.y - start.y;
                    self.drag.as_mut().unwrap().0 = p;
                }
            }
            PointerUp(p) => {
                if let Some((start, mut object)) = self.drag.take() {
                    object.x += p.x - start.x;
                    object.y += p.y - start.y;
                    self.deck.update_object(object)?;
                }
            }
            Cancel => self.drag = None,
            Key { code: 46, .. } => {
                if self.enabled(27) {
                    if let Some(id) = self.selected_object.take() {
                        self.deck.delete_object(id)?;
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn save_formats(&self) -> Vec<win42::FileFormat> {
        if self.odp_source.is_some() {
            return vec![win42::FileFormat {
                id: "odp",
                title: "OpenDocument presentation",
                extensions: &["odp"],
            }];
        }
        if self.pptx_source.is_some() {
            return vec![win42::FileFormat {
                id: "pptx",
                title: "PowerPoint presentation",
                extensions: &["pptx"],
            }];
        }
        vec![
            win42::FileFormat {
                id: "json",
                title: "Suite42 slides JSON",
                extensions: &["json"],
            },
            win42::FileFormat {
                id: "odp",
                title: "OpenDocument presentation",
                extensions: &["odp"],
            },
            win42::FileFormat {
                id: "pptx",
                title: "PowerPoint presentation",
                extensions: &["pptx"],
            },
        ]
    }
    fn save_snapshot(&mut self, format: &str) -> Result<Option<(u64, Vec<u8>)>, String> {
        let (native_bytes, state) = (&self.deck).save_snapshot().map_err(|e| e.to_string())?;
        let bytes = match (format, self.pptx_source.as_ref()) {
            ("json", None) if self.odp_source.is_none() => native_bytes,
            ("pptx", Some(source)) => ppt42_core::pptx::export(&self.deck, source)?,
            ("pptx", None) if self.odp_source.is_none() => {
                ppt42_core::pptx::export_new(&self.deck)?
            }
            ("odp", None) if self.odp_source.is_some() => {
                ppt42_core::odp::export_overlay(&self.deck, self.odp_source.as_ref().unwrap())?
            }
            ("odp", None) => ppt42_core::odp::export(&self.deck)?,
            _ => return Err("Unsupported save format".into()),
        };
        self.next_save = self.next_save.wrapping_add(1);
        let revision = self.next_save;
        self.pending = Some((revision, state));
        Ok(Some((revision, bytes)))
    }
    fn saved_snapshot(&mut self, revision: u64) {
        if self.pending.as_ref().is_some_and(|(r, _)| *r == revision) {
            if let Some((_, state)) = self.pending.take() {
                if let Some(doc) = Some(&mut self.deck) {
                    doc.mark_saved_snapshot(state);
                }
            }
        }
    }

    fn name(&self) -> &'static str {
        "PPT42"
    }
    fn extension(&self) -> &'static str {
        if self.odp_source.is_some() {
            "odp"
        } else if self.pptx_source.is_some() {
            "pptx"
        } else {
            "json"
        }
    }
    fn format_name(&self) -> &'static str {
        if self.odp_source.is_some() {
            "OpenDocument presentation"
        } else if self.pptx_source.is_some() {
            "PowerPoint presentation"
        } else {
            "Suite42 slides JSON"
        }
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[
            (10, "&Add Slide"),
            (11, "&Delete Slide"),
            (12, "Move Slide &Up"),
            (13, "Move Slide D&own"),
            (14, "D&uplicate Slide"),
            (20, "Insert Rectangle"),
            (21, "Insert Ellipse"),
            (22, "Insert Line"),
            (23, "Insert Text Box"),
            (24, "Edit Slide Text…"),
            (25, "Edit Object Text…"),
            (26, "Object Geometry…"),
            (27, "Delete Object"),
            (28, "Bring to Front"),
            (29, "Send to Back"),
            (30, "Fill Color…"),
            (31, "Line Color…"),
            (33, "Insert Table…"),
            (34, "Edit Table Cell…"),
            (40, "Print Slides…"),
            (41, "Start Slide Show"),
            (42, "Text Font…"),
            (43, "Align Text Left"),
            (44, "Align Text Center"),
            (45, "Align Text Right"),
        ]
    }
    fn items(&self) -> Vec<String> {
        self.deck
            .slides()
            .iter()
            .enumerate()
            .map(|(i, s)| format!("{}: {}", i + 1, s.title))
            .collect()
    }
    fn text(&self) -> String {
        let s = &self.deck.slides()[self.deck.current()];
        format!("{}\r\n{}", s.title, win42::to_native_text(&s.body))
    }
    fn status(&self) -> String {
        if self.odp_source.is_some() {
            return format!("Slide {} of {} | ODP: supported objects editable; other content preserved but may not be displayed",self.deck.current()+1,self.deck.slides().len());
        }
        if self.pptx_source.is_some() {
            return format!("Slide {} of {} | PPTX: supported shapes editable; other content preserved but may not be displayed", self.deck.current()+1,self.deck.slides().len());
        }
        format!(
            "Slide {} of {} | first line is title; remaining text is body | Suite42 JSON",
            self.deck.current() + 1,
            self.deck.slides().len()
        )
    }
    fn dirty(&self) -> bool {
        self.deck.is_dirty()
    }
    fn can_undo(&self) -> bool {
        self.deck.can_undo()
    }
    fn can_redo(&self) -> bool {
        self.deck.can_redo()
    }
    fn selected(&self) -> usize {
        self.deck.current()
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        if p.extension()
            .and_then(|s| s.to_str())
            .is_some_and(|s| s.eq_ignore_ascii_case("odp"))
        {
            let bytes = std::fs::read(p).map_err(|e| e.to_string())?;
            let (deck, source) = ppt42_core::odp::import_with_source(&bytes)?;
            *self = Ppt::new(deck);
            self.odp_source = Some(source);
            return Ok(());
        }
        if p.extension()
            .and_then(|s| s.to_str())
            .is_some_and(|s| s.eq_ignore_ascii_case("pptx"))
        {
            let bytes = std::fs::read(p).map_err(|e| e.to_string())?;
            let (deck, source) = ppt42_core::pptx::import(&bytes)?;
            *self = Ppt::new(deck);
            self.pptx_source = Some(source);
            return Ok(());
        }
        let presentation = Presentation::open(p)?;
        for slide in presentation.slides() {
            win42::validate_editable(&slide.title)?;
            win42::validate_editable(&slide.body)?;
            if slide.title.contains('\n') {
                return Err("Slide titles containing line breaks cannot be preserved by this editor. File was not opened.".into());
            }
        }
        *self = Ppt::new(presentation);
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        if let Some(source) = &self.odp_source {
            use std::io::Write;
            let bytes = ppt42_core::odp::export_overlay(&self.deck, source)?;
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(p)
                .and_then(|mut f| f.write_all(&bytes))
                .map_err(|e| e.to_string())?;
            return Ok(());
        }
        if let Some(source) = &self.pptx_source {
            use std::io::Write;
            let bytes = ppt42_core::pptx::export(&self.deck, source)?;
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(p)
                .and_then(|mut f| f.write_all(&bytes))
                .map_err(|e| e.to_string())?;
            return Ok(());
        }
        self.deck.save_as(p)
    }
    fn edit(&mut self, s: String) -> Result<(), String> {
        let text = win42::from_native_text(&s);
        let (title, body) = text.split_once('\n').unwrap_or((&text, ""));
        self.deck.edit(title.into(), body.into())
    }
    fn select(&mut self, i: usize) {
        let _ = self.deck.select(i);
        self.selected_object = None;
    }
    fn enabled(&self, id: u16) -> bool {
        if self.pptx_source.is_some() && matches!(id, 24 | 28 | 29) {
            return false;
        }
        if id == 10 && self.pptx_source.as_ref().is_some_and(|s| !s.can_add()) {
            return false;
        }
        if id == 14
            && self.pptx_source.as_ref().is_some_and(|s| {
                !s.can_duplicate(self.deck.slides()[self.deck.current()].source_identity())
            })
        {
            return false;
        }
        if id == 11 && self.pptx_source.is_some() {
            let current = self.deck.slides()[self.deck.current()].id;
            if self
                .deck
                .slides()
                .iter()
                .any(|s| s.id != current && s.source_identity() == current)
            {
                return false;
            }
        }
        if self.pptx_source.is_some()
            && matches!(id, 27 | 30 | 31)
            && self.selected_object.is_some_and(|object| {
                self.pptx_source.as_ref().unwrap().is_original_object(
                    self.deck.slides()[self.deck.current()].source_identity(),
                    object,
                )
            })
        {
            return false;
        }
        if self.odp_source.is_some() && matches!(id, 24 | 28 | 29) {
            return false;
        }
        if self.odp_source.is_some()
            && matches!(id, 27 | 30 | 31)
            && self.selected_object.is_some_and(|object| {
                self.odp_source.as_ref().unwrap().is_original_object(
                    self.deck.slides()[self.deck.current()].source_identity(),
                    object,
                )
            })
        {
            return false;
        }
        if id == 11
            && self.odp_source.as_ref().is_some_and(|s| {
                !s.can_delete_slide(self.deck.slides()[self.deck.current()].source_identity())
            })
        {
            return false;
        }
        if id == 11 && self.pptx_source.as_ref().is_some_and(|s| !s.can_delete()) {
            return false;
        }
        let i = self.deck.current();
        let n = self.deck.slides().len();
        match id {
            42..=45 => {
                self.selected_object.is_some_and(|id| {
                    self.deck.slides()[i].objects.iter().any(|o| {
                        o.id == id
                            && !o.text.is_empty()
                            && !matches!(
                                o.kind,
                                ppt42_core::ObjectKind::Picture | ppt42_core::ObjectKind::Table
                            )
                    })
                }) && self.pptx_source.as_ref().is_none_or(|s| {
                    s.can_edit_text(
                        self.deck.slides()[i].source_identity(),
                        self.selected_object.unwrap(),
                    )
                }) && self.odp_source.as_ref().is_none_or(|s| {
                    s.can_edit_text(
                        self.deck.slides()[i].source_identity(),
                        self.selected_object.unwrap(),
                    )
                })
            }
            40 => self
                .odp_source
                .as_ref()
                .is_none_or(|s| s.size_points().is_some()),
            10 => self.deck.can_add(),
            11 => n > 1,
            12 => i > 0,
            13 => i + 1 < n,
            14 => self.deck.can_duplicate(),
            25 if self.pptx_source.is_some() => self.selected_object.is_some_and(|id| {
                self.pptx_source
                    .as_ref()
                    .unwrap()
                    .can_edit_text(self.deck.slides()[i].source_identity(), id)
            }),
            25 if self.odp_source.is_some() => self.selected_object.is_some_and(|id| {
                self.odp_source
                    .as_ref()
                    .unwrap()
                    .can_edit_text(self.deck.slides()[i].source_identity(), id)
            }),
            25..=29 | 31 => self
                .selected_object
                .is_some_and(|id| self.deck.slides()[i].objects.iter().any(|o| o.id == id)),
            30 => self.selected_object.is_some_and(|id| {
                self.deck.slides()[i].objects.iter().any(|o| {
                    o.id == id
                        && matches!(
                            o.kind,
                            ppt42_core::ObjectKind::Rectangle | ppt42_core::ObjectKind::Text
                        )
                })
            }),
            34 => self.selected_object.is_some_and(|id| {
                self.deck.slides()[i]
                    .objects
                    .iter()
                    .any(|o| o.id == id && matches!(o.kind, ppt42_core::ObjectKind::Table))
            }),
            _ => true,
        }
    }
    fn action(&mut self, id: u16) -> Result<(), String> {
        if id >= 10 && !self.enabled(id) {
            return Err("Command unavailable".into());
        }
        let i = self.deck.current();
        match id {
            4 => {
                self.deck.undo();
                Ok(())
            }
            5 => {
                self.deck.redo();
                Ok(())
            }
            10 => self.deck.add(),
            11 => self.deck.delete(),
            12 => self.deck.move_slide(i, i - 1),
            13 => self.deck.move_slide(i, i + 1),
            14 => self.deck.duplicate(),
            41 => {
                self.presenting = true;
                self.selected_object = None;
                self.drag = None;
                Ok(())
            }
            43..=45 => {
                let object_id = self.selected_object.ok_or("Select an object")?;
                let mut object = self.deck.slides()[i]
                    .objects
                    .iter()
                    .find(|o| o.id == object_id)
                    .cloned()
                    .ok_or("Object no longer exists")?;
                object.text_style.align = match id {
                    43 => ppt42_core::TextAlign::Left,
                    44 => ppt42_core::TextAlign::Center,
                    _ => ppt42_core::TextAlign::Right,
                };
                self.deck.update_object(object)
            }
            27 => {
                let id = self.selected_object.take().ok_or("Select an object")?;
                self.deck.delete_object(id)
            }
            28 | 29 => self
                .deck
                .arrange_object(self.selected_object.ok_or("Select an object")?, id == 28),
            20..=23 => {
                let kind = match id {
                    20 => ppt42_core::ObjectKind::Rectangle,
                    21 => ppt42_core::ObjectKind::Ellipse,
                    22 => ppt42_core::ObjectKind::Line,
                    _ => ppt42_core::ObjectKind::Text,
                };
                self.selected_object = Some(self.deck.insert_object(
                    kind,
                    if id == 23 {
                        "Text".into()
                    } else {
                        String::new()
                    },
                )?);
                Ok(())
            }
            _ => Ok(()),
        }
    }
}
fn main() {
    win42::run(Box::new(Ppt::new(Presentation::new())))
}
#[cfg(test)]
mod tests {
    use super::*;
    use win42::App;
    #[test]
    fn duplicate_menu_dispatch_tracks_history() {
        let mut app = Ppt::new(Presentation::new());
        app.edit("Title\r\nBody".into()).unwrap();
        assert!(app.enabled(14));
        app.action(14).unwrap();
        assert_eq!(app.selected(), 1);
        assert_eq!(app.text(), "Title\r\nBody");
        assert_ne!(app.deck.slides()[0].id, app.deck.slides()[1].id);
        app.action(4).unwrap();
        assert_eq!(app.selected(), 0);
        app.action(5).unwrap();
        assert_eq!(app.selected(), 1);
    }
    #[test]
    fn slide_editor_preserves_crlf() {
        let mut p = Presentation::new();
        p.edit_raw("title".into(), "a\r\nb".into()).unwrap();
        let mut a = Ppt::new(p);
        assert_eq!(a.text(), "title\r\na\r\nb");
        a.edit("title\r\na".into()).unwrap();
        a.select(0);
        a.edit("title\r\na\r\nc".into()).unwrap();
        assert_eq!(a.deck.slides()[0].body, "a\r\nc");
    }
}
#[cfg(test)]
mod regression {
    use super::*;
    use win42::App;
    #[test]
    fn policy_survives_reorder_undo_redo_and_context_switch() {
        let mut d = Presentation::new();
        d.edit_raw("one".into(), "a\r\nb".into()).unwrap();
        d.add().unwrap();
        d.edit("two".into(), "x\ny".into()).unwrap();
        let path = std::env::temp_dir().join(format!("ppt42-policy-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        d.save_as(&path).unwrap();
        let mut a = Ppt::new(Presentation::open(&path).unwrap());
        a.select(0);
        a.edit("one\r\na".into()).unwrap();
        a.action(13).unwrap();
        a.action(4).unwrap();
        a.action(5).unwrap();
        a.select(0);
        a.select(1);
        a.edit("one\r\na\r\nc".into()).unwrap();
        assert_eq!(a.deck.slides()[1].body, "a\r\nc");
        assert_eq!(a.deck.slides()[0].body, "x\ny");
        let out =
            std::env::temp_dir().join(format!("ppt42-policy-out-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&out);
        a.save(&out).unwrap();
        let re = Presentation::open(&out).unwrap();
        assert_eq!(re.slides()[1].body, "a\r\nc");
        assert_eq!(re.slides()[0].body, "x\ny");
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(out).unwrap();
    }
    #[test]
    fn rejected_and_noop_edit_do_not_desynchronize_policy_history() {
        let mut d = Presentation::new();
        d.edit_raw("one".into(), "a\r\nb".into()).unwrap();
        let path = std::env::temp_dir().join(format!("ppt42-branch-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        d.save_as(&path).unwrap();
        let mut a = Ppt::new(Presentation::open(&path).unwrap());
        a.edit("one\r\na".into()).unwrap();
        assert!(a.edit(format!("one\r\n{}", "x".repeat(32769))).is_err());
        a.edit("one\r\na".into()).unwrap();
        a.action(4).unwrap();
        assert_eq!(a.deck.slides()[0].body, "a\r\nb");
        a.edit("one\r\nbranch".into()).unwrap();
        assert!(!a.can_redo());
        a.edit("one\r\nbranch\r\nnext".into()).unwrap();
        assert_eq!(a.deck.slides()[0].body, "branch\r\nnext");
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn bounded_policy_history_stays_aligned() {
        let mut d = Presentation::new();
        d.edit_raw("one".into(), "a\r\nb".into()).unwrap();
        let p = std::env::temp_dir().join(format!("ppt42-limit-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&p);
        d.save_as(&p).unwrap();
        let mut a = Ppt::new(Presentation::open(&p).unwrap());
        for i in 0..15 {
            a.edit(format!("one\r\nvalue{i}")).unwrap();
        }
        for _ in 0..10 {
            a.action(4).unwrap();
        }
        assert!(!a.can_undo());
        a.edit("one\r\nlast\r\nline".into()).unwrap();
        assert_eq!(a.deck.slides()[0].body, "last\r\nline");
        assert!(!a.can_redo());
        std::fs::remove_file(p).unwrap();
    }
    #[test]
    fn boundary_commands_are_refused() {
        let mut a = Ppt::new(Presentation::new());
        for id in [11, 12, 13] {
            assert!(!a.enabled(id));
            assert!(a.action(id).is_err());
        }
        a.action(10).unwrap();
        assert!(a.enabled(12));
        assert!(!a.enabled(13));
        a.action(12).unwrap();
        assert!(!a.enabled(12));
        assert!(a.enabled(13));
    }
}
#[cfg(test)]
mod identity_regression {
    use super::*;
    use win42::App;
    #[test]
    fn identical_visible_slides_keep_identity_and_newlines_through_reorder_history_and_save() {
        let mut deck = Presentation::new();
        deck.edit_raw("same".into(), "a\r\nb".into()).unwrap();
        deck.add().unwrap();
        deck.edit_raw("same".into(), "a\nb".into()).unwrap();
        let crlf_id = deck.slides()[0].id;
        let lf_id = deck.slides()[1].id;
        let mut app = Ppt::new(deck);
        app.select(0);
        app.edit("same\r\none".into()).unwrap();
        app.select(1);
        app.edit("same\r\none".into()).unwrap();
        assert_eq!(app.deck.slides()[0].body, app.deck.slides()[1].body);
        app.select(0);
        app.action(13).unwrap();
        assert_eq!(app.deck.slides()[1].id, crlf_id);
        app.action(4).unwrap();
        assert_eq!(app.deck.slides()[0].id, crlf_id);
        app.action(5).unwrap();
        assert_eq!(app.deck.slides()[0].id, lf_id);
        let path = std::env::temp_dir().join(format!("ppt42-identity-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        app.save(&path).unwrap();
        let mut reopened = Ppt::new(Presentation::open(&path).unwrap());
        reopened.select(0);
        reopened.edit("same\r\none\r\nmore".into()).unwrap();
        reopened.select(1);
        reopened.edit("same\r\none\r\nmore".into()).unwrap();
        assert_eq!(
            (
                reopened.deck.slides()[0].id,
                reopened.deck.slides()[0].body.as_str()
            ),
            (lf_id, "one\nmore")
        );
        assert_eq!(
            (
                reopened.deck.slides()[1].id,
                reopened.deck.slides()[1].body.as_str()
            ),
            (crlf_id, "one\r\nmore")
        );
        reopened.action(4).unwrap();
        reopened.action(5).unwrap();
        reopened.action(4).unwrap();
        reopened.edit("same\r\nbranch\r\nend".into()).unwrap();
        assert!(!reopened.can_redo());
        assert_eq!(reopened.deck.slides()[1].body, "branch\r\nend");
        std::fs::remove_file(path).unwrap();
    }
}
