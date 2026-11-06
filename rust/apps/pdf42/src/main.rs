#![cfg_attr(windows, windows_subsystem = "windows")]
use pdf42_core::PdfDocument;
use std::path::Path;
#[cfg(windows)]
mod render;
#[cfg(windows)]
mod search;
#[derive(Default)]
struct Pdf {
    pending: Option<(u64, u64, pdf42_core::SaveState)>,
    past_documents: Vec<(u64, PdfDocument)>,
    future_documents: Vec<(u64, PdfDocument)>,
    current_epoch: u64,
    saved_epoch: u64,
    next_epoch: u64,
    next_save: u64,
    doc: Option<PdfDocument>,
    #[cfg(windows)]
    renderer: Option<render::Worker>,
    #[cfg(windows)]
    generation: u64,
    #[cfg(windows)]
    rendered: Option<(u32, u32, Vec<u8>)>,
    #[cfg(windows)]
    render_error: Option<String>,
    #[cfg(windows)]
    flatten_pending: Option<(
        std::sync::mpsc::Receiver<Result<render::FlattenedPages, String>>,
        Vec<u8>,
        u64,
        usize,
        std::sync::Arc<std::sync::atomic::AtomicBool>,
    )>,
    operation_error: Option<String>,
    #[cfg(windows)]
    print_pending: Option<(
        std::sync::mpsc::Receiver<Result<win42::PrintJob, String>>,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
        std::sync::Arc<std::sync::atomic::AtomicBool>,
        usize,
    )>,
    #[cfg(windows)]
    print_ready: Option<Result<win42::PrintJob, String>>,
    #[cfg(windows)]
    export_pending: Option<(
        std::sync::mpsc::Receiver<Result<(), String>>,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
        std::sync::Arc<std::sync::atomic::AtomicBool>,
        usize,
        std::path::PathBuf,
    )>,
    export_first: usize,
    export_last: usize,
    export_dpi: u32,
    zoom: f64,
    pan: win42::Point,
    pan_drag: Option<(win42::Point, win42::Point)>,
    tool: Option<pdf42_core::AnnotationKind>,
    annotation_drag: Option<win42::Point>,
    ink_points: Vec<win42::Point>,
    annotation_contents: String,
    select_annotations: bool,
    redact_tool: bool,
    selected_annotation: Option<pdf42_core::AnnotationSelection>,
    #[cfg(windows)]
    search_hits: Vec<search::Hit>,
    #[cfg(windows)]
    search_index: usize,
    search_query: String,
    select_text: bool,
    attachment_name: String,
    #[cfg(windows)]
    selected_text: Option<search::Selection>,
}
impl Pdf {
    #[cfg(windows)]
    fn page_point(&self, p: win42::Point) -> Result<[f64; 2], String> {
        let (width, height, _) = self
            .rendered
            .as_ref()
            .ok_or("Wait for the page to render")?;
        let doc = self.doc.as_ref().ok_or("Open a PDF first")?;
        let b = doc.page_box(doc.current())?;
        let u = (p.x / *width as f64).clamp(0., 1.);
        let v = (p.y / *height as f64).clamp(0., 1.);
        let (x, y) = match doc.rotation(doc.current())? {
            0 => (u, 1. - v),
            90 => (v, u),
            180 => (1. - u, v),
            270 => (1. - v, 1. - u),
            _ => return Err("Invalid page rotation".into()),
        };
        Ok([b[0] + x * (b[2] - b[0]), b[1] + y * (b[3] - b[1])])
    }
    fn install_flattened(
        &mut self,
        pages: Vec<pdf42_core::FlattenedPage>,
        page: usize,
    ) -> Result<(), String> {
        let replacement = PdfDocument::from_flattened_pages(pages, page)?;
        let mut previous = self.doc.take().ok_or("Open a PDF first")?;
        previous.discard_redo();
        self.past_documents.push((self.current_epoch, previous));
        if self.past_documents.len() > 20 {
            self.past_documents.remove(0);
        }
        self.future_documents.clear();
        self.next_epoch = self.next_epoch.wrapping_add(1);
        self.current_epoch = self.next_epoch;
        self.doc = Some(replacement);
        self.selected_annotation = None;
        self.pan = win42::Point::default();
        Ok(())
    }
    fn branch(&mut self) {
        self.future_documents.clear();
    }
    fn undo_document(&mut self) {
        if self.doc.as_ref().is_some_and(|d| d.can_undo()) {
            self.doc.as_mut().unwrap().undo();
        } else if let Some((epoch, previous)) = self.past_documents.pop() {
            if let Some(current) = self.doc.replace(previous) {
                self.future_documents.push((self.current_epoch, current));
                self.current_epoch = epoch;
            }
        }
    }
    fn redo_document(&mut self) {
        if self.doc.as_ref().is_some_and(|d| d.can_redo()) {
            self.doc.as_mut().unwrap().redo();
        } else if let Some((epoch, next)) = self.future_documents.pop() {
            if let Some(current) = self.doc.replace(next) {
                self.past_documents.push((self.current_epoch, current));
                self.current_epoch = epoch;
            }
        }
    }
    fn request_render(&mut self) -> Result<(), String> {
        #[cfg(windows)]
        {
            if let Some((_, _, _, _, cancel)) = self.flatten_pending.take() {
                cancel.store(true, std::sync::atomic::Ordering::Relaxed);
            }
            self.selected_text = None;
            let doc = self.doc.as_ref().ok_or("Open a PDF first")?;
            let (bytes, _) = doc.save_snapshot()?;
            self.generation = self.generation.wrapping_add(1);
            self.rendered = None;
            self.render_error = None;
            let scale = if self.zoom == 0.0 { 1.0 } else { self.zoom };
            self.renderer
                .get_or_insert_with(render::Worker::new)
                .submit(render::Request {
                    generation: self.generation,
                    bytes,
                    page: doc.current() as u32,
                    scale,
                })?;
        }
        Ok(())
    }
}
impl win42::App for Pdf {
    fn poll_background(&mut self) -> bool {
        #[cfg(windows)]
        {
            let mut changed = false;
            if let Some((rx, _, _, _, _)) = &self.export_pending {
                if let Ok(result) = rx.try_recv() {
                    let (_, _, _, _, path) = self.export_pending.take().unwrap();
                    self.operation_error = Some(match result {
                        Ok(()) => format!("Exported {}", path.display()),
                        Err(e) => e,
                    });
                    changed = true;
                } else {
                    changed = true;
                }
            }
            if let Some((rx, _, _, _)) = &self.print_pending {
                if let Ok(result) = rx.try_recv() {
                    self.print_pending = None;
                    self.print_ready = Some(result);
                    changed = true;
                } else {
                    changed = true;
                }
            }
            if let Some((rx, _, _, _, _)) = &self.flatten_pending {
                if let Ok(result) = rx.try_recv() {
                    let (_, source, generation, page, _) = self.flatten_pending.take().unwrap();
                    if generation == self.generation
                        && self
                            .doc
                            .as_ref()
                            .and_then(|d| d.save_snapshot().ok())
                            .is_some_and(|(bytes, _)| bytes == source)
                    {
                        let result = result.and_then(|pages| self.install_flattened(pages, page));
                        match result {
                            Ok(()) => {
                                self.search_hits.clear();
                                if let Err(e) = self.request_render() {
                                    self.operation_error = Some(e);
                                }
                            }
                            Err(e) => self.operation_error = Some(e),
                        }
                    } else {
                        self.operation_error = Some(
                            "Flattening cancelled because the document or view changed".into(),
                        );
                    }
                    changed = true;
                }
            }
            if let Some(worker) = &self.renderer {
                while let Ok(response) = worker.rx.try_recv() {
                    if response.generation == self.generation {
                        match response.result {
                            Ok(image) => self.rendered = Some(image),
                            Err(e) => self.render_error = Some(e),
                        }
                        changed = true;
                    }
                }
            }
            return changed;
        }
        #[cfg(not(windows))]
        {
            false
        }
    }
    fn take_pending_print_job(&mut self) -> Option<Result<win42::PrintJob, String>> {
        #[cfg(windows)]
        {
            self.print_ready.take()
        }
        #[cfg(not(windows))]
        {
            None
        }
    }
    fn canvas_scene(&self) -> Option<win42::CanvasScene> {
        #[cfg(windows)]
        {
            let (width, height, rgba) = self.rendered.as_ref()?;
            let mut items = vec![win42::SceneItem::Image {
                x: 0.,
                y: 0.,
                width: *width,
                height: *height,
                rgba: rgba.clone(),
            }];
            if let (Some(doc), Some(hit)) =
                (self.doc.as_ref(), self.search_hits.get(self.search_index))
            {
                if hit.page == doc.current() {
                    if let (Ok(b), Ok(rotation)) = (doc.page_box(hit.page), doc.rotation(hit.page))
                    {
                        let convert = |x: f64, y: f64| {
                            let x = (x - b[0]) / (b[2] - b[0]);
                            let y = (y - b[1]) / (b[3] - b[1]);
                            let (u, v) = match rotation {
                                90 => (y, x),
                                180 => (1. - x, y),
                                270 => (1. - y, 1. - x),
                                _ => (x, 1. - y),
                            };
                            win42::Point {
                                x: u * *width as f64,
                                y: v * *height as f64,
                            }
                        };
                        for rect in &hit.boxes {
                            items.push(win42::SceneItem::Path {
                                points: vec![
                                    convert(rect[0], rect[1]),
                                    convert(rect[2], rect[1]),
                                    convert(rect[2], rect[3]),
                                    convert(rect[0], rect[3]),
                                ],
                                color: [255, 0, 0],
                                closed: true,
                            });
                        }
                    }
                }
            }
            if let (Some(doc), Some(selection)) = (self.doc.as_ref(), self.selected_text.as_ref()) {
                if doc.current() == selection.page {
                    if let (Ok(b), Ok(rotation)) =
                        (doc.page_box(selection.page), doc.rotation(selection.page))
                    {
                        let cv = |x: f64, y: f64| {
                            let x = (x - b[0]) / (b[2] - b[0]);
                            let y = (y - b[1]) / (b[3] - b[1]);
                            let (u, v) = match rotation {
                                90 => (y, x),
                                180 => (1. - x, y),
                                270 => (1. - y, 1. - x),
                                _ => (x, 1. - y),
                            };
                            win42::Point {
                                x: u * *width as f64,
                                y: v * *height as f64,
                            }
                        };
                        for q in &selection.boxes {
                            items.push(win42::SceneItem::Path {
                                points: vec![
                                    cv(q[0], q[1]),
                                    cv(q[2], q[1]),
                                    cv(q[2], q[3]),
                                    cv(q[0], q[3]),
                                ],
                                color: [0, 80, 255],
                                closed: true,
                            });
                        }
                    }
                }
            }
            if self.ink_points.len() > 1 {
                items.push(win42::SceneItem::Path {
                    points: self.ink_points.clone(),
                    color: [255, 0, 0],
                    closed: false,
                });
            }
            Some(win42::CanvasScene {
                viewport: win42::Viewport {
                    zoom: 1.0,
                    pan: self.pan,
                },
                items,
            })
        }
        #[cfg(not(windows))]
        {
            None
        }
    }
    fn canvas_event(&mut self, event: win42::CanvasEvent) -> Result<(), String> {
        match event {
            win42::CanvasEvent::PointerDown(p) => {
                if self.tool.is_some()
                    || self.select_annotations
                    || self.redact_tool
                    || self.select_text
                {
                    self.annotation_drag = Some(p);
                    if self.tool == Some(pdf42_core::AnnotationKind::Ink) {
                        self.ink_points.clear();
                        self.ink_points.push(p);
                    }
                } else {
                    self.pan_drag = Some((p, self.pan));
                }
            }
            win42::CanvasEvent::PointerMove(p) => {
                if self.annotation_drag.is_some()
                    && self.tool == Some(pdf42_core::AnnotationKind::Ink)
                    && self.ink_points.len() < 100_000
                {
                    self.ink_points.push(p);
                }
                if let Some((anchor, _)) = self.pan_drag {
                    self.pan.x += p.x - anchor.x;
                    self.pan.y += p.y - anchor.y;
                }
            }
            win42::CanvasEvent::PointerUp(p) => {
                if let Some(anchor) = self.annotation_drag.take() {
                    #[cfg(windows)]
                    {
                        if self.redact_tool {
                            let (width, height, _) = self
                                .rendered
                                .as_ref()
                                .ok_or("Wait for the page to render")?;
                            let rect = [
                                anchor.x / *width as f64,
                                anchor.y / *height as f64,
                                p.x / *width as f64,
                                p.y / *height as f64,
                            ];
                            if (rect[0] - rect[2]).abs() < 0.001
                                || (rect[1] - rect[3]).abs() < 0.001
                            {
                                return Err("Drag a larger redaction area".into());
                            }
                            let doc = self.doc.as_ref().ok_or("Open a PDF first")?;
                            let page = doc.current();
                            let mut sizes = Vec::new();
                            for i in 0..doc.page_count() {
                                let b = doc.page_box(i)?;
                                let rotation = doc.rotation(i)?;
                                sizes.push(if rotation == 90 || rotation == 270 {
                                    (b[3] - b[1], b[2] - b[0])
                                } else {
                                    (b[2] - b[0], b[3] - b[1])
                                });
                            }
                            let (bytes, _) = doc.save_snapshot()?;
                            let cancel =
                                std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
                            let rx = render::flatten_async(
                                bytes.clone(),
                                sizes,
                                page,
                                rect,
                                cancel.clone(),
                            );
                            self.flatten_pending = Some((rx, bytes, self.generation, page, cancel));
                            self.operation_error = None;
                            self.redact_tool = false;
                            return Ok(());
                        }
                        let a = self.page_point(anchor)?;
                        let b = self.page_point(p)?;
                        if self.select_text {
                            let doc = self.doc.as_ref().ok_or("Open a PDF first")?;
                            let (bytes, _) = doc.save_snapshot()?;
                            self.selected_text = Some(search::select(
                                &bytes,
                                doc.current(),
                                [a[0], a[1], b[0], b[1]],
                            )?);
                            return Ok(());
                        }
                        if self.select_annotations {
                            let doc = self.doc.as_mut().ok_or("Open a PDF first")?;
                            self.selected_annotation = doc.hit_annotation(doc.current(), a);
                            if let Some(index) = self.selected_annotation {
                                if (a[0] - b[0]).abs() > 1. || (a[1] - b[1]).abs() > 1. {
                                    doc.move_annotation(index, [b[0] - a[0], b[1] - a[1]])?;
                                    self.branch();
                                    self.request_render()?;
                                }
                            }
                            return Ok(());
                        }
                        if self.tool == Some(pdf42_core::AnnotationKind::Ink) {
                            self.ink_points.push(p);
                            let points = self
                                .ink_points
                                .iter()
                                .map(|point| self.page_point(*point))
                                .collect::<Result<Vec<_>, _>>()?;
                            self.ink_points.clear();
                            let doc = self.doc.as_mut().ok_or("Open a PDF first")?;
                            doc.add_ink(doc.current(), &points)?;
                            self.search_hits.clear();
                            self.branch();
                            self.request_render()?;
                            return Ok(());
                        }
                        let kind = self.tool.ok_or("Select an annotation tool")?;
                        let doc = self.doc.as_mut().ok_or("Open a PDF first")?;
                        self.search_hits.clear();
                        doc.add_annotation(
                            doc.current(),
                            kind,
                            [a[0], a[1], b[0], b[1]],
                            &self.annotation_contents,
                        )?;
                        self.branch();
                        self.request_render()?;
                    }
                    #[cfg(not(windows))]
                    let _ = (anchor, p);
                }
                self.pan_drag = None;
            }
            win42::CanvasEvent::Cancel => {
                self.annotation_drag = None;
                self.ink_points.clear();
                if let Some((_, original)) = self.pan_drag.take() {
                    self.pan = original;
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn multiline_input(&self, id: u16) -> bool {
        matches!(id, 25 | 29 | 31)
    }
    fn input_request(&self, id: u16) -> Option<win42::InputRequest> {
        let doc = self.doc.as_ref()?;
        if id == 59 {
            return Some(win42::InputRequest {
                title: "Image export range",
                fields: vec![
                    ("First page", self.export_first.max(1).to_string()),
                    (
                        "Last page",
                        if self.export_last == 0 {
                            doc.page_count()
                        } else {
                            self.export_last
                        }
                        .to_string(),
                    ),
                    (
                        "DPI (72–300)",
                        if self.export_dpi == 0 {
                            150
                        } else {
                            self.export_dpi
                        }
                        .to_string(),
                    ),
                ],
            });
        }
        if (54..=58).contains(&id) {
            let names = doc.bookmarks().ok()?;
            let mut fields = Vec::new();
            if id == 54 {
                fields.push(("Title", String::new()));
            } else {
                fields.push(("Bookmark number", "1".into()));
                if id == 56 {
                    fields.push(("New title", names.first().cloned().unwrap_or_default()));
                }
                if id == 58 {
                    fields.push(("Move to number", "1".into()));
                }
                fields.push((
                    "Bookmarks",
                    names
                        .iter()
                        .enumerate()
                        .map(|(i, n)| format!("{}: {}", i + 1, n))
                        .collect::<Vec<_>>()
                        .join("; "),
                ));
            }
            return Some(win42::InputRequest {
                title: match id {
                    54 => "Add bookmark",
                    55 => "Go to bookmark",
                    56 => "Rename bookmark",
                    57 => "Delete bookmark",
                    _ => "Move bookmark",
                },
                fields,
            });
        }
        if id == 52 {
            return Some(win42::InputRequest {
                title: "Print PDF pages",
                fields: vec![
                    ("First page", "1".into()),
                    ("Last page", doc.page_count().to_string()),
                    ("DPI (72–300)", "150".into()),
                ],
            });
        }
        if id == 49 || id == 50 {
            let names = doc.attachments().ok()?;
            let first = names.first()?;
            let selected = if names.contains(&self.attachment_name) {
                self.attachment_name.clone()
            } else {
                first.clone()
            };
            let mut fields = vec![("Attachment name", selected.clone())];
            if id == 49 {
                fields.push(("Export path", selected));
            }
            fields.push(("Available attachments", names.join(", ")));
            return Some(win42::InputRequest {
                title: if id == 49 {
                    "Export attachment"
                } else {
                    "Delete attachment"
                },
                fields,
            });
        }
        if id == 36 {
            return Some(win42::InputRequest {
                title: "Find PDF text",
                fields: vec![("Search text", self.search_query.clone())],
            });
        }
        if id == 34 {
            let fields = doc.form_fields();
            let (name, _, value) = fields.first()?.clone();
            let kind = fields
                .iter()
                .map(|(n, k, _)| format!("{n} ({k})"))
                .collect::<Vec<_>>()
                .join(", ");
            return Some(win42::InputRequest {
                title: "Edit form field",
                fields: vec![
                    ("Field name", name),
                    ("Value", value),
                    ("Available fields", kind),
                ],
            });
        }
        if id == 31 {
            return Some(win42::InputRequest {
                title: "Edit note or text",
                fields: vec![(
                    "Text",
                    self.selected_annotation
                        .and_then(|a| doc.annotation_contents(a))
                        .unwrap_or_default(),
                )],
            });
        }
        if matches!(id, 25 | 26 | 29 | 30) {
            return Some(win42::InputRequest {
                title: match id {
                    25 => "Note text",
                    26 => "Link destination",
                    29 => "Text annotation",
                    _ => "Stamp text",
                },
                fields: vec![(
                    if id == 26 { "HTTP(S) URL" } else { "Text" },
                    self.annotation_contents.clone(),
                )],
            });
        }
        if id == 21 {
            let b = doc.page_box(doc.current()).ok()?;
            return Some(win42::InputRequest {
                title: "Crop page (PDF points)",
                fields: vec![
                    ("Left", b[0].to_string()),
                    ("Bottom", b[1].to_string()),
                    ("Right", b[2].to_string()),
                    ("Top", b[3].to_string()),
                ],
            });
        }
        if id != 14 {
            return None;
        }
        Some(win42::InputRequest {
            title: "Document properties",
            fields: vec![
                (
                    "Title",
                    doc.metadata("Title").ok().flatten().unwrap_or_default(),
                ),
                (
                    "Author",
                    doc.metadata("Author").ok().flatten().unwrap_or_default(),
                ),
                (
                    "Subject",
                    doc.metadata("Subject").ok().flatten().unwrap_or_default(),
                ),
                (
                    "Keywords",
                    doc.metadata("Keywords").ok().flatten().unwrap_or_default(),
                ),
            ],
        })
    }
    fn input_action(&mut self, id: u16, values: &[String]) -> Result<(), String> {
        if id == 59 && values.len() == 3 {
            let first: usize = values[0]
                .trim()
                .parse()
                .map_err(|_| "Enter a valid first page")?;
            let last: usize = values[1]
                .trim()
                .parse()
                .map_err(|_| "Enter a valid last page")?;
            let dpi: u32 = values[2].trim().parse().map_err(|_| "Enter a valid DPI")?;
            if first == 0
                || first > last
                || last > self.doc.as_ref().ok_or("Open a PDF first")?.page_count()
                || !(72..=300).contains(&dpi)
            {
                return Err("Enter a valid page range and DPI between 72 and 300".into());
            }
            self.export_first = first;
            self.export_last = last;
            self.export_dpi = dpi;
            return Ok(());
        }
        if (54..=58).contains(&id) {
            let doc = self.doc.as_mut().ok_or("Open a PDF first")?;
            if id == 54 {
                let title = values.first().ok_or("Enter a title")?;
                doc.add_bookmark(title)?;
            } else {
                let index: usize = values
                    .first()
                    .ok_or("Enter a bookmark number")?
                    .trim()
                    .parse()
                    .map_err(|_| "Enter a valid bookmark number")?;
                let index = index.checked_sub(1).ok_or("Bookmark numbers start at 1")?;
                match id {
                    55 => doc.select_bookmark(index)?,
                    56 => doc.rename_bookmark(index, values.get(1).ok_or("Enter a title")?)?,
                    57 => doc.delete_bookmark(index)?,
                    58 => {
                        let to: usize = values
                            .get(1)
                            .ok_or("Enter a destination")?
                            .trim()
                            .parse()
                            .map_err(|_| "Enter a valid destination")?;
                        doc.move_bookmark(
                            index,
                            to.checked_sub(1).ok_or("Bookmark numbers start at 1")?,
                        )?;
                    }
                    _ => {}
                }
            }
            if id != 55 {
                self.branch();
            }
            return self.request_render();
        }
        if id == 52 && values.len() == 3 {
            let first: usize = values[0]
                .trim()
                .parse()
                .map_err(|_| "Enter a valid first page")?;
            let last: usize = values[1]
                .trim()
                .parse()
                .map_err(|_| "Enter a valid last page")?;
            let dpi: u32 = values[2].trim().parse().map_err(|_| "Enter a valid DPI")?;
            if first == 0 || first > last || !(72..=300).contains(&dpi) {
                return Err("Enter an increasing page range and DPI between 72 and 300".into());
            }
            #[cfg(windows)]
            {
                let doc = self.doc.as_ref().ok_or("Open a PDF first")?;
                if last > doc.page_count() {
                    return Err("Page range exceeds the document".into());
                }
                let mut pages = Vec::new();
                for i in first - 1..last {
                    let b = doc.page_box(i)?;
                    let angle = doc.rotation(i)?;
                    let (w, h) = if angle == 90 || angle == 270 {
                        (b[3] - b[1], b[2] - b[0])
                    } else {
                        (b[2] - b[0], b[3] - b[1])
                    };
                    pages.push((i, w, h));
                }
                let (bytes, _) = doc.save_snapshot()?;
                let progress = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
                let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
                let total = pages.len();
                let rx = render::print_async(bytes, pages, dpi, progress.clone(), cancel.clone());
                self.print_pending = Some((rx, progress, cancel, total));
                return Ok(());
            }
            #[cfg(not(windows))]
            return Err("PDF printing requires Windows".into());
        }
        if (id == 49 && values.len() == 3) || (id == 50 && values.len() == 2) {
            self.attachment_name = values[0].clone();
            if id == 49 {
                return self
                    .doc
                    .as_ref()
                    .ok_or("Open a PDF first")?
                    .export_attachment(&values[0], Path::new(&values[1]));
            }
            self.doc
                .as_mut()
                .ok_or("Open a PDF first")?
                .delete_attachment(&values[0])?;
            self.branch();
            return self.request_render();
        }
        if id == 36 && values.len() == 1 {
            self.search_query = values[0].clone();
            #[cfg(windows)]
            {
                let doc = self.doc.as_ref().ok_or("Open a PDF first")?;
                let (bytes, _) = doc.save_snapshot()?;
                self.search_hits = search::find(&bytes, &self.search_query, doc.page_count())?;
                self.search_index = 0;
                let first = self
                    .search_hits
                    .first()
                    .ok_or("No matching text found")?
                    .page;
                self.doc.as_mut().unwrap().select(first)?;
                return self.request_render();
            }
            #[cfg(not(windows))]
            return Err("PDF text search is available on Windows with PDFium".into());
        }
        if id == 34 && values.len() == 3 {
            self.doc
                .as_mut()
                .ok_or("Open a PDF first")?
                .set_form_value(&values[0], &values[1])?;
            self.branch();
            return self.request_render();
        }
        if id == 31 && values.len() == 1 {
            let selected = self.selected_annotation.ok_or("Select a note first")?;
            self.doc
                .as_mut()
                .ok_or("Open a PDF first")?
                .set_note_text(selected, &values[0])?;
            self.branch();
            return self.request_render();
        }
        if matches!(id, 25 | 26 | 29 | 30) && values.len() == 1 {
            if values[0].trim().is_empty() {
                return Err("Enter a value".into());
            }
            if id == 26 && !(values[0].starts_with("https://") || values[0].starts_with("http://"))
            {
                return Err("Enter an http or https link".into());
            }
            self.annotation_contents = values[0].clone();
            self.select_text = false;
            self.select_annotations = false;
            self.redact_tool = false;
            self.selected_annotation = None;
            self.tool = Some(match id {
                25 => pdf42_core::AnnotationKind::Note,
                26 => pdf42_core::AnnotationKind::Link,
                29 => pdf42_core::AnnotationKind::FreeText,
                _ => pdf42_core::AnnotationKind::Stamp,
            });
            return Ok(());
        }
        if id == 21 && values.len() == 4 {
            let mut crop = [0.; 4];
            for (slot, value) in crop.iter_mut().zip(values) {
                *slot = value
                    .trim()
                    .parse()
                    .map_err(|_| "Enter numeric PDF point coordinates")?;
            }
            let doc = self.doc.as_mut().ok_or("Open a PDF first")?;
            doc.crop_page(doc.current(), crop)?;
            self.branch();
            return self.request_render();
        }
        if id != 14 || values.len() != 4 {
            return Err("Invalid properties".into());
        }
        let pairs = ["Title", "Author", "Subject", "Keywords"]
            .iter()
            .zip(values)
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .collect::<Vec<_>>();
        self.doc
            .as_mut()
            .ok_or("Open a PDF first")?
            .set_metadata(&pairs)?;
        self.branch();
        self.request_render()
    }
    fn file_actions(&self) -> &'static [win42::FileAction] {
        &[
            win42::FileAction {
                id: 60,
                title: "Export PNG Pages to ZIP…",
                save: true,
                extension: "zip",
                format: "ZIP archive",
                pattern: "*.zip",
            },
            win42::FileAction {
                id: 61,
                title: "Export JPEG Pages to ZIP…",
                save: true,
                extension: "zip",
                format: "ZIP archive",
                pattern: "*.zip",
            },
            win42::FileAction {
                id: 48,
                title: "Add Attachment…",
                save: false,
                extension: "",
                format: "All files",
                pattern: "*.*",
            },
            win42::FileAction {
                id: 33,
                title: "Extract Current Page…",
                save: true,
                extension: "pdf",
                format: "PDF document",
                pattern: "*.pdf",
            },
            win42::FileAction {
                id: 35,
                title: "Insert PDF Pages…",
                save: false,
                extension: "pdf",
                format: "PDF document",
                pattern: "*.pdf",
            },
        ]
    }
    fn file_action(&mut self, id: u16, path: &Path) -> Result<(), String> {
        let doc = self.doc.as_mut().ok_or("Open a PDF first")?;
        match id {
            60 | 61 => {
                #[cfg(windows)]
                {
                    let first = self.export_first.max(1);
                    let last = if self.export_last == 0 {
                        doc.page_count()
                    } else {
                        self.export_last
                    };
                    if first > last || last > doc.page_count() {
                        return Err("Choose an image export range for this document".into());
                    }
                    let dpi = if self.export_dpi == 0 {
                        150
                    } else {
                        self.export_dpi
                    };
                    let mut pages = Vec::new();
                    for i in first - 1..last {
                        let b = doc.page_box(i)?;
                        let angle = doc.rotation(i)?;
                        let (w, h) = if angle == 90 || angle == 270 {
                            (b[3] - b[1], b[2] - b[0])
                        } else {
                            (b[2] - b[0], b[3] - b[1])
                        };
                        pages.push((i, w, h));
                    }
                    let (bytes, _) = doc.save_snapshot()?;
                    let progress = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
                    let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
                    let total = pages.len();
                    let rx = render::export_async(
                        bytes,
                        pages,
                        dpi,
                        id == 61,
                        path.to_path_buf(),
                        progress.clone(),
                        cancel.clone(),
                    );
                    self.export_pending = Some((rx, progress, cancel, total, path.to_path_buf()));
                    self.operation_error = None;
                    return Ok(());
                }
                #[cfg(not(windows))]
                {
                    Err("PDF image export requires Windows".into())
                }
            }
            48 => {
                doc.add_attachment(path)?;
                self.branch();
                self.request_render()
            }
            33 => doc.extract_page(doc.current(), path),
            35 => {
                doc.insert_pdf_after(doc.current(), path)?;
                self.branch();
                self.request_render()
            }
            _ => Err("Unsupported file action".into()),
        }
    }
    fn clipboard_request(&self, id: u16) -> Option<win42::ClipboardRequest> {
        #[cfg(windows)]
        if id == 44 {
            return self
                .selected_text
                .as_ref()
                .map(|s| win42::ClipboardRequest::WriteText(s.text.clone()));
        }
        let _ = id;
        None
    }
    fn save_formats(&self) -> Vec<win42::FileFormat> {
        vec![win42::FileFormat {
            id: "pdf",
            title: "PDF document",
            extensions: &["pdf"],
        }]
    }
    fn save_snapshot(&mut self, format: &str) -> Result<Option<(u64, Vec<u8>)>, String> {
        if format != "pdf" {
            return Err("Unsupported save format".into());
        }
        let (bytes, state) = (self.doc.as_ref().ok_or("No document")?)
            .save_snapshot()
            .map_err(|e| e.to_string())?;
        self.next_save = self.next_save.wrapping_add(1);
        let revision = self.next_save;
        self.pending = Some((revision, self.current_epoch, state));
        Ok(Some((revision, bytes)))
    }
    fn saved_snapshot(&mut self, revision: u64) {
        if self
            .pending
            .as_ref()
            .is_some_and(|(r, _, _)| *r == revision)
        {
            if let Some((_, epoch, state)) = self.pending.take() {
                let target = if epoch == self.current_epoch {
                    self.doc.as_mut()
                } else {
                    self.past_documents
                        .iter_mut()
                        .chain(self.future_documents.iter_mut())
                        .find(|(e, _)| *e == epoch)
                        .map(|(_, d)| d)
                };
                if let Some(doc) = target {
                    doc.mark_saved_snapshot(state);
                    self.saved_epoch = epoch;
                }
            }
        }
    }

    fn name(&self) -> &'static str {
        "PDF42"
    }
    fn extension(&self) -> &'static str {
        "pdf"
    }
    fn format_name(&self) -> &'static str {
        "PDF document"
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[
            (10, "Rotate &Right"),
            (11, "&Delete Page"),
            (12, "Move Page &Up"),
            (13, "Move Page D&own"),
            (14, "Document &Properties…"),
            (15, "Zoom In"),
            (16, "Zoom Out"),
            (17, "Pan Tool"),
            (18, "Draw Rectangle"),
            (19, "Draw Ellipse"),
            (20, "Draw Line"),
            (39, "Draw Freehand Ink"),
            (40, "Select Text"),
            (41, "Highlight Selected Text"),
            (42, "Underline Selected Text"),
            (43, "Strike Out Selected Text"),
            (44, "Copy Selected Text"),
            (49, "Export Attachment…"),
            (50, "Delete Attachment…"),
            (52, "Print Pages…"),
            (53, "Cancel Print Preparation"),
            (54, "Add Bookmark…"),
            (55, "Go to Bookmark…"),
            (56, "Rename Bookmark…"),
            (57, "Delete Bookmark…"),
            (58, "Move Bookmark…"),
            (59, "Set Image Export Range…"),
            (62, "Cancel Image Export"),
            (63, "Compress PDF Streams"),
            (21, "Crop Page…"),
            (22, "Highlight Area"),
            (23, "Underline Area"),
            (24, "Strike Out Area"),
            (25, "Note…"),
            (26, "Link…"),
            (27, "Select Annotation"),
            (28, "Delete Selected Annotation"),
            (29, "Text…"),
            (30, "Stamp…"),
            (31, "Edit Selected Note or Text…"),
            (32, "Insert Blank Page"),
            (34, "Edit Form Field…"),
            (36, "Find Text…"),
            (37, "Next Search Result"),
            (
                38,
                "Flatten All Pages (removes text, forms, metadata) and Redact",
            ),
        ]
    }
    fn items(&self) -> Vec<String> {
        self.doc
            .as_ref()
            .map(|d| {
                (0..d.page_count())
                    .map(|i| format!("Page {} — {}°", i + 1, d.rotation(i).unwrap_or(0)))
                    .collect()
            })
            .unwrap_or_default()
    }
    fn text(&self) -> String {
        #[cfg(windows)]
        if let Some(error) = &self.render_error {
            return format!("Page rendering failed: {error}");
        }
        #[cfg(windows)]
        if self.doc.is_some() {
            return "Rendering page…".into();
        }
        "Open a PDF document.".into()
    }
    fn status(&self) -> String {
        if self.redact_tool {
            return "Drag the area to redact. All pages will be flattened at 150 DPI; text, forms, links and metadata will be removed.".into();
        }
        #[cfg(windows)]
        if let Some((_, progress, _, total)) = &self.print_pending {
            return format!(
                "Preparing print: {} of {} pages",
                progress.load(std::sync::atomic::Ordering::Relaxed),
                total
            );
        }
        #[cfg(windows)]
        if let Some((_, progress, _, total, _)) = &self.export_pending {
            return format!(
                "Exporting images: {} of {} pages",
                progress.load(std::sync::atomic::Ordering::Relaxed),
                total
            );
        }
        if let Some(error) = &self.operation_error {
            return error.clone();
        }
        #[cfg(windows)]
        if self.flatten_pending.is_some() {
            return "Flattening all pages at 150 DPI…".into();
        }
        match &self.doc {
            Some(d) => format!(
                "Page {} of {} | {}° | Title: {} | Author: {} | Tool: {} | {}",
                d.current() + 1,
                d.page_count(),
                d.rotation(d.current()).unwrap_or(0),
                d.metadata("Title").ok().flatten().unwrap_or_default(),
                d.metadata("Author").ok().flatten().unwrap_or_default(),
                match self.tool {
                    None => "Pan",
                    Some(pdf42_core::AnnotationKind::Rectangle) => "Rectangle",
                    Some(pdf42_core::AnnotationKind::Ellipse) => "Ellipse",
                    Some(pdf42_core::AnnotationKind::Line) => "Line",
                    Some(pdf42_core::AnnotationKind::Ink) => "Ink",
                    Some(pdf42_core::AnnotationKind::Highlight) => "Highlight",
                    Some(pdf42_core::AnnotationKind::Underline) => "Underline",
                    Some(pdf42_core::AnnotationKind::StrikeOut) => "Strike out",
                    Some(pdf42_core::AnnotationKind::Note) => "Note",
                    Some(pdf42_core::AnnotationKind::Link) => "Link",
                    Some(pdf42_core::AnnotationKind::FreeText) => "Text",
                    Some(pdf42_core::AnnotationKind::Stamp) => "Stamp",
                },
                self.selected_annotation
                    .and_then(|selection| d.annotation_contents(selection))
                    .unwrap_or_default()
            ),
            None => "Open a PDF document".into(),
        }
    }
    fn can_save(&self) -> bool {
        self.doc.is_some()
    }
    fn selected(&self) -> usize {
        self.doc.as_ref().map_or(0, |d| d.current())
    }
    fn enabled(&self, id: u16) -> bool {
        let Some(d) = self.doc.as_ref() else {
            return false;
        };
        let n = d.page_count();
        let index = d.current();
        match id {
            10 => index < n,
            11 => d.can_restructure() && n > 1 && index < n,
            12 => d.can_reorder() && index > 0 && index < n,
            13 => d.can_reorder() && index + 1 < n,
            28 | 31 => self.selected_annotation.is_some(),
            32 | 35 => d.can_reorder(),
            33 => d.can_restructure(),
            38 => true,
            34 => !d.form_fields().is_empty(),
            49 | 50 => d.attachments().is_ok_and(|v| !v.is_empty()),
            55..=58 => d.bookmarks().is_ok_and(|v| !v.is_empty()),
            60 | 61 => {
                #[cfg(windows)]
                {
                    self.export_pending.is_none()
                }
                #[cfg(not(windows))]
                {
                    false
                }
            }
            62 => {
                #[cfg(windows)]
                {
                    self.export_pending.is_some()
                }
                #[cfg(not(windows))]
                {
                    false
                }
            }
            52 => {
                #[cfg(windows)]
                {
                    self.print_pending.is_none()
                }
                #[cfg(not(windows))]
                {
                    false
                }
            }
            53 => {
                #[cfg(windows)]
                {
                    self.print_pending.is_some()
                }
                #[cfg(not(windows))]
                {
                    false
                }
            }
            41..=44 => {
                #[cfg(windows)]
                {
                    self.selected_text
                        .as_ref()
                        .is_some_and(|s| s.page == d.current())
                }
                #[cfg(not(windows))]
                {
                    false
                }
            }
            37 => {
                #[cfg(windows)]
                {
                    !self.search_hits.is_empty()
                }
                #[cfg(not(windows))]
                {
                    false
                }
            }
            _ => true,
        }
    }
    fn dirty(&self) -> bool {
        self.current_epoch != self.saved_epoch || self.doc.as_ref().is_some_and(|d| d.is_dirty())
    }
    fn can_undo(&self) -> bool {
        !self.past_documents.is_empty() || self.doc.as_ref().is_some_and(|d| d.can_undo())
    }
    fn can_redo(&self) -> bool {
        !self.future_documents.is_empty() || self.doc.as_ref().is_some_and(|d| d.can_redo())
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        let doc = PdfDocument::open(p)?;
        self.doc = Some(doc);
        self.past_documents.clear();
        self.future_documents.clear();
        self.current_epoch = 0;
        self.saved_epoch = 0;
        self.next_epoch = 0;
        self.pending = None;
        self.operation_error = None;
        #[cfg(windows)]
        {
            self.search_hits.clear();
        }
        self.selected_annotation = None;
        self.attachment_name.clear();
        self.export_first = 0;
        self.export_last = 0;
        self.export_dpi = 0;
        self.pan = win42::Point::default();
        self.request_render()
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.doc.as_mut().ok_or("Open a PDF first")?.save_as(p)?;
        self.saved_epoch = self.current_epoch;
        Ok(())
    }
    fn edit(&mut self, _: String) -> Result<(), String> {
        Ok(())
    }
    fn select(&mut self, i: usize) {
        self.selected_annotation = None;
        if let Some(d) = self.doc.as_mut() {
            let _ = d.select(i);
        }
        let _ = self.request_render();
    }
    fn text_readonly(&self) -> bool {
        true
    }
    fn action(&mut self, id: u16) -> Result<(), String> {
        if id >= 10 && !self.enabled(id) {
            return Err("Command unavailable".into());
        }
        if id == 37 {
            #[cfg(windows)]
            {
                self.search_index = (self.search_index + 1) % self.search_hits.len();
                let page = self.search_hits[self.search_index].page;
                self.doc.as_mut().ok_or("Open a PDF first")?.select(page)?;
                return self.request_render();
            }
            #[cfg(not(windows))]
            return Err("Search is unavailable".into());
        }
        if id == 62 {
            #[cfg(windows)]
            if let Some((_, _, cancel, _, _)) = &self.export_pending {
                cancel.store(true, std::sync::atomic::Ordering::Relaxed);
            }
            return Ok(());
        }
        if id == 53 {
            #[cfg(windows)]
            if let Some((_, _, cancel, _)) = &self.print_pending {
                cancel.store(true, std::sync::atomic::Ordering::Relaxed);
            }
            return Ok(());
        }
        if id == 40 {
            self.select_text = true;
            self.tool = None;
            self.select_annotations = false;
            self.redact_tool = false;
            return Ok(());
        }
        if (41..=43).contains(&id) {
            #[cfg(windows)]
            {
                let selection = self.selected_text.take().ok_or("Select text first")?;
                let kind = match id {
                    41 => pdf42_core::AnnotationKind::Highlight,
                    42 => pdf42_core::AnnotationKind::Underline,
                    _ => pdf42_core::AnnotationKind::StrikeOut,
                };
                self.doc
                    .as_mut()
                    .ok_or("Open a PDF first")?
                    .add_text_markup(selection.page, kind, &selection.boxes)?;
                self.branch();
                return self.request_render();
            }
            #[cfg(not(windows))]
            return Err("Text selection requires Windows and PDFium".into());
        }
        if id == 38 {
            self.operation_error = None;
            self.redact_tool = true;
            self.select_text = false;
            self.select_annotations = false;
            self.tool = None;
            self.selected_annotation = None;
            return Ok(());
        }
        if id == 27 {
            self.tool = None;
            self.select_text = false;
            self.redact_tool = false;
            self.select_annotations = true;
            self.selected_annotation = None;
            return Ok(());
        }
        if id == 28 {
            let selected = self
                .selected_annotation
                .take()
                .ok_or("Select an annotation first")?;
            self.doc
                .as_mut()
                .ok_or("Open a PDF first")?
                .delete_annotation(selected)?;
            self.branch();
            return self.request_render();
        }
        if (17..=20).contains(&id) || (22..=24).contains(&id) || id == 39 {
            self.select_annotations = false;
            self.select_text = false;
            self.redact_tool = false;
            self.selected_annotation = None;
            self.tool = match id {
                18 => Some(pdf42_core::AnnotationKind::Rectangle),
                19 => Some(pdf42_core::AnnotationKind::Ellipse),
                20 => Some(pdf42_core::AnnotationKind::Line),
                39 => Some(pdf42_core::AnnotationKind::Ink),
                22 => Some(pdf42_core::AnnotationKind::Highlight),
                23 => Some(pdf42_core::AnnotationKind::Underline),
                24 => Some(pdf42_core::AnnotationKind::StrikeOut),
                _ => None,
            };
            self.annotation_drag = None;
            return Ok(());
        }
        if id == 15 || id == 16 {
            let current = if self.zoom == 0.0 { 1.0 } else { self.zoom };
            self.zoom = (if id == 15 {
                current * 1.25
            } else {
                current / 1.25
            })
            .clamp(0.25, 3.0);
            self.pan = win42::Point::default();
            return self.request_render();
        }
        self.selected_annotation = None;
        #[cfg(windows)]
        {
            self.search_hits.clear();
        }
        if id == 4 {
            self.undo_document();
            return self.request_render();
        }
        if id == 5 {
            self.redo_document();
            return self.request_render();
        }
        let d = self.doc.as_mut().ok_or("Open a PDF first")?;
        let index = d.current();
        match id {
            10 => d.rotate(index, 90)?,
            11 => d.delete(index)?,
            12 => d.move_page(index, index - 1)?,
            13 => d.move_page(index, index + 1)?,
            32 => d.insert_blank_after(index)?,
            63 => d.compress_streams(),
            _ => {}
        }
        self.branch();
        self.request_render()
    }
}
fn main() {
    win42::run(Box::new(Pdf::default()))
}
#[cfg(test)]
mod tests {
    use super::*;
    use win42::App;
    #[test]
    fn flatten_becomes_editable_and_history_tracks_saved_document_identity() {
        use std::io::Write;
        let dir = std::env::temp_dir().join(format!("pdf42-flatten-ui-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("in.pdf");
        let mut scan = scn42_core::ScanDocument::new();
        scan.add_rgba(1, 1, vec![255, 255, 255, 255]).unwrap();
        scan.export_pdf(&input).unwrap();
        let mut source = lopdf::Document::load(&input).unwrap();
        source.catalog_mut().unwrap().set(
            "PrivateMarker",
            lopdf::Object::string_literal("SOURCE-SECRET-MARKER"),
        );
        source.save(&input).unwrap();
        let mut app = Pdf::default();
        app.open(&input).unwrap();
        assert!(!app.dirty());
        let mut encoder =
            flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(&vec![0; 300]).unwrap();
        let page = pdf42_core::FlattenedPage {
            width: 10,
            height: 10,
            compressed_rgb: encoder.finish().unwrap(),
            page_width: 100.,
            page_height: 100.,
        };
        app.install_flattened(vec![page], 0).unwrap();
        assert!(app.dirty());
        assert!(app.enabled(10));
        app.action(10).unwrap();
        assert_eq!(app.doc.as_ref().unwrap().rotation(0).unwrap(), 90);
        app.action(4).unwrap();
        assert_eq!(app.doc.as_ref().unwrap().rotation(0).unwrap(), 0);
        app.action(4).unwrap();
        assert!(!app.dirty());
        assert!(app.can_redo());
        app.action(5).unwrap();
        assert!(app.dirty());
        let (revision, bytes) = app.save_snapshot("pdf").unwrap().unwrap();
        app.saved_snapshot(revision);
        assert!(!app.dirty());
        app.action(4).unwrap();
        assert!(app.dirty());
        app.action(5).unwrap();
        assert!(!app.dirty());
        app.doc
            .as_mut()
            .unwrap()
            .add_annotation(
                0,
                pdf42_core::AnnotationKind::Rectangle,
                [1., 1., 10., 10.],
                "",
            )
            .unwrap();
        assert!(app.dirty());
        let (edited, _) = app.doc.as_ref().unwrap().save_snapshot().unwrap();
        let output = dir.join("out.pdf");
        std::fs::write(&output, edited).unwrap();
        let reopened = lopdf::Document::load(&output).unwrap();
        let p = *reopened.get_pages().values().next().unwrap();
        assert!(reopened.get_dictionary(p).unwrap().get(b"Annots").is_ok());
        assert!(!bytes
            .windows(b"SOURCE-SECRET-MARKER".len())
            .any(|v| v == b"SOURCE-SECRET-MARKER"));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn command_boundaries_and_unsafe_structure_refuse_dispatch() {
        let dir = std::env::temp_dir().join(format!("pdf42-ui-boundary-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.pdf");
        let unsafe_path = dir.join("unsafe.pdf");
        let _ = std::fs::remove_file(&input);
        let _ = std::fs::remove_file(&unsafe_path);
        let mut scan = scn42_core::ScanDocument::new();
        scan.add_rgba(1, 1, vec![255, 255, 255, 255]).unwrap();
        scan.add_rgba(1, 1, vec![0, 0, 0, 255]).unwrap();
        scan.export_pdf(&input).unwrap();
        let mut a = Pdf::default();
        for id in 10..=13 {
            assert!(!a.enabled(id));
            assert!(a.action(id).is_err());
        }
        a.open(&input).unwrap();
        assert!(!a.enabled(12));
        assert!(a.enabled(13));
        a.action(13).unwrap();
        assert!(a.can_undo());
        a.action(4).unwrap();
        assert_eq!(a.selected(), 0);
        assert!(a.can_redo());
        a.action(5).unwrap();
        assert_eq!(a.selected(), 1);
        assert!(!a.enabled(13));
        assert!(a.enabled(12));
        a.action(11).unwrap();
        assert!(!a.enabled(11));
        assert!(a.action(11).is_err());
        let mut doc = lopdf::Document::load(&input).unwrap();
        let page = *doc.get_pages().values().next().unwrap();
        doc.get_dictionary_mut(page)
            .unwrap()
            .set("Annots", lopdf::Object::Array(vec![]));
        doc.save(&unsafe_path).unwrap();
        let mut b = Pdf::default();
        b.open(&unsafe_path).unwrap();
        assert!(b.enabled(10));
        assert!(b.enabled(11));
        assert!(b.enabled(13));
        b.action(13).unwrap();
        assert_eq!(b.selected(), 1);
        b.action(4).unwrap();
        assert_eq!(b.selected(), 0);
        b.action(11).unwrap();
        assert_eq!(b.doc.as_ref().unwrap().page_count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
