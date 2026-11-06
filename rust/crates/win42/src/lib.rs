use std::path::{Path, PathBuf};

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

#[derive(Clone)]
pub struct InputRequest {
    pub title: &'static str,
    pub fields: Vec<(&'static str, String)>,
}
#[derive(Clone, Copy)]
pub struct FileAction {
    pub id: u16,
    pub title: &'static str,
    pub save: bool,
    pub extension: &'static str,
    pub format: &'static str,
    pub pattern: &'static str,
}

/// Portable contract between a document model and the native Windows host.
pub trait App {
    /// Native top-level window handle, when a Windows host is available.
    fn set_native_window(&mut self, _window: usize) {}
    /// Poll completed background work on the UI thread; return true when the view changed.
    /// Request an ordinary document replacement after an app command.
    fn take_pending_open(&mut self) -> Option<PathBuf> {
        None
    }
    fn poll_background(&mut self) -> bool {
        false
    }
    /// Consume a finished background print render on the UI thread.
    fn take_pending_print_job(&mut self) -> Option<Result<PrintJob, String>> {
        None
    }
    /// Opt-in serialized snapshot for host-managed, conflict-aware saves.
    /// Legacy adapters retain their existing save-as-only behavior.
    fn save_snapshot(&mut self, _format: &str) -> Result<Option<(u64, Vec<u8>)>, String> {
        Ok(None)
    }
    /// Whether ordinary Save may overwrite the current session source.
    fn can_save_in_place(&self) -> bool {
        true
    }
    /// Encode with the concrete destination; `is_current` means the session source path.
    fn save_snapshot_to(
        &mut self,
        format: &str,
        _path: &Path,
        _is_current: bool,
    ) -> Result<Option<(u64, Vec<u8>)>, String> {
        self.save_snapshot(format)
    }
    /// Mark precisely the published revision as saved, even if editing continued.
    fn saved_snapshot(&mut self, _revision: u64) {}
    fn open_formats(&self) -> Vec<FileFormat> {
        vec![]
    }
    fn save_formats(&self) -> Vec<FileFormat> {
        vec![]
    }
    fn command_specs(&self) -> Vec<CommandSpec> {
        vec![]
    }
    fn command_state(&self, id: u16) -> CommandState {
        CommandState {
            enabled: self.enabled(id),
            checked: false,
        }
    }
    fn canvas_scene(&self) -> Option<CanvasScene> {
        None
    }
    /// Logical scene dimensions while presenting fullscreen, or None in editing mode.
    fn presentation_size(&self) -> Option<(f64, f64)> {
        None
    }
    fn canvas_event(&mut self, _event: CanvasEvent) -> Result<(), String> {
        Ok(())
    }
    fn name(&self) -> &'static str;
    fn extension(&self) -> &'static str;
    fn format_name(&self) -> &'static str;
    fn actions(&self) -> &'static [(u16, &'static str)];
    fn supports_new(&self) -> bool {
        false
    }
    fn new_document(&mut self) -> Result<(), String> {
        Err("New document unavailable".into())
    }
    fn file_actions(&self) -> &'static [FileAction] {
        &[]
    }
    fn file_action(&mut self, _id: u16, _path: &Path) -> Result<(), String> {
        Err("Unsupported file action".into())
    }
    /// A command may supply pre-rendered pages for the native print dialog.
    fn clipboard_request(&self, _id: u16) -> Option<ClipboardRequest> {
        None
    }
    fn clipboard_data(&mut self, _id: u16, _bytes: Vec<u8>) -> Result<(), String> {
        Err("Clipboard action unavailable".into())
    }
    fn clipboard_text(&mut self, _id: u16, _text: String) -> Result<(), String> {
        Err("Clipboard action unavailable".into())
    }
    /// Print using explicit paper geometry. Scene coordinates are points from the content origin.
    /// Ask the native host for a paginated RichEdit preview; geometry is in twips.
    fn rich_preview(&self, _id: u16) -> Option<RichPrint> {
        None
    }
    fn print_job(&self, _id: u16) -> Option<PrintJob> {
        None
    }
    fn dialog_request(&self, _id: u16) -> Option<DialogRequest> {
        None
    }
    fn dialog_result(&mut self, _id: u16, _result: DialogResult) -> Result<(), String> {
        Err("Unsupported dialog action".into())
    }
    /// Use a multiline first field in the native input dialog.
    fn multiline_input(&self, _id: u16) -> bool {
        false
    }
    fn input_request(&self, _id: u16) -> Option<InputRequest> {
        None
    }
    fn input_action(&mut self, _id: u16, _values: &[String]) -> Result<(), String> {
        Err("Unsupported input action".into())
    }
    fn supports_find_replace(&self) -> bool {
        false
    }
    fn find_next(
        &self,
        _query: &str,
        _start_utf16: usize,
    ) -> Result<Option<(usize, usize)>, String> {
        Err("Find unavailable".into())
    }
    fn replace_all(&mut self, _query: &str, _replacement: &str) -> Result<usize, String> {
        Err("Replace unavailable".into())
    }
    fn view_actions(&self) -> &'static [(u16, &'static str)] {
        &[]
    }
    fn items(&self) -> Vec<String>;
    fn text(&self) -> String;
    fn status(&self) -> String;
    fn dirty(&self) -> bool;
    fn can_undo(&self) -> bool;
    fn can_redo(&self) -> bool;
    fn open(&mut self, path: &Path) -> Result<(), String>;
    fn save(&mut self, path: &Path) -> Result<(), String>;
    fn edit(&mut self, text: String) -> Result<(), String>;
    fn select(&mut self, index: usize);
    fn action(&mut self, id: u16) -> Result<(), String>;
    fn open_filter(&self) -> String {
        format!("*.{}", self.extension())
    }
    fn open_is_add(&self) -> bool {
        false
    }
    fn selected(&self) -> usize {
        0
    }
    fn enabled(&self, _id: u16) -> bool {
        true
    }
    /// Sheet names and selected index for grid-based applications.
    fn grid_sheets(&self) -> Option<(Vec<String>, usize)> {
        None
    }
    fn select_grid_sheet(&mut self, _index: usize) {}
    fn grid_selection(&self) -> Option<GridRange> {
        None
    }
    fn select_grid_range(&mut self, _range: GridRange) {}
    fn grid_cell_style(&self, _row: usize, _column: usize) -> Option<GridCellStyle> {
        None
    }
    fn table(&self) -> Option<Vec<Vec<String>>> {
        None
    }
    fn select_cell(&mut self, _row: usize, _col: usize) {}
    fn selected_cell(&self) -> Option<(usize, usize)> {
        None
    }
    fn image_zoom(&self) -> Option<f64> {
        None
    }
    fn can_save(&self) -> bool {
        true
    }
    fn image(&self) -> Option<(u32, u32, Vec<u8>)> {
        None
    }
    fn list_visible(&self) -> bool {
        true
    }
    /// Page and paragraph ruler geometry, in twips; None disables rulers.
    fn rich_ruler(&self) -> Option<RichRuler> {
        None
    }
    fn rich_ruler_action(&mut self, _action: RichRulerAction) -> Result<(), String> {
        Err("Ruler action unavailable".into())
    }
    fn uses_rich_edit(&self) -> bool {
        false
    }
    fn rich_text(&self) -> Option<Vec<u8>> {
        None
    }
    fn edit_rich_text(
        &mut self,
        _rtf: &[u8],
        _selection_utf16: (usize, usize),
    ) -> Result<(), String> {
        Err("Rich text editing unavailable".into())
    }
    fn set_rich_selection(&mut self, _selection_utf16: (usize, usize)) {}
    /// Selection captured by the document history, restored after Undo or Redo.
    fn rich_selection_to_restore(&self) -> Option<(usize, usize)> {
        None
    }
    fn text_readonly(&self) -> bool {
        false
    }
}
#[cfg(windows)]
mod clipboard;
#[cfg(windows)]
mod dialogs;
#[cfg(windows)]
mod native;
#[cfg(windows)]
mod prompt;
#[cfg(windows)]
mod rich_edit;
#[cfg(windows)]
mod rich_preview;
#[cfg(windows)]
mod rich_print;
#[cfg(windows)]
mod rich_ruler;
#[cfg(windows)]
pub use native::run;
#[cfg(not(windows))]
pub fn run(app: Box<dyn App>) {
    eprintln!("{} requires Windows.", app.name());
}

/// Convert between a model string and the CRLF representation used by EDIT.
/// Mixed newlines, lone CR and NUL cannot be represented reversibly here.
pub fn validate_editable(text: &str) -> Result<(), String> {
    let canonical = text.replace("\r\n", "\n");
    if text.contains('\0')
        || canonical.contains('\r')
        || (text.contains("\r\n") && text.replace("\r\n", "").contains('\n'))
    {
        return Err("Text contains NUL, lone CR, or mixed newline styles that this editor cannot preserve. File was not opened.".into());
    }
    if canonical.encode_utf16().count() + canonical.matches('\n').count() > 16_777_216 {
        return Err("Text exceeds the native editor limit. File was not opened.".into());
    }
    Ok(())
}
pub fn to_native_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\n', "\r\n")
}
pub fn from_native_text(text: &str) -> String {
    text.replace("\r\n", "\n")
}
#[cfg(test)]
mod tests {
    #[test]
    fn native_text_round_trip_and_rejections() {
        for s in ["first\nsecond 😀", "first\r\nsecond 😀", "one line"] {
            assert!(super::validate_editable(s).is_ok());
            assert_eq!(
                super::from_native_text(&super::to_native_text(s)),
                s.replace("\r\n", "\n")
            );
        }
        assert!(super::validate_editable("a\0b").is_err());
        assert!(super::validate_editable("a\rb").is_err());
        assert!(super::validate_editable("a\r\nb\nc").is_err());
        assert!(super::validate_editable(&"x".repeat(16_777_217)).is_err());
    }
}

/// Native table operations needed to move between two rectangular presentations.
#[derive(Debug, PartialEq, Eq)]
pub enum GridTransition {
    Rebuild { selection: Option<(usize, usize)> },
    Update { cells: Vec<(usize, usize)> },
}
/// Compare presentations once, leaving unchanged native controls and view state intact.
pub fn grid_transition(
    old: Option<&[Vec<String>]>,
    new: &[Vec<String>],
    selection: Option<(usize, usize)>,
) -> GridTransition {
    let cols = new.first().map_or(0, Vec::len);
    let shape_matches = old.is_some_and(|rows| {
        rows.len() == new.len() && rows.iter().zip(new).all(|(a, b)| a.len() == b.len())
    });
    if !shape_matches {
        let selection = selection.and_then(|(row, col)| {
            if new.is_empty() || cols == 0 {
                None
            } else {
                Some((row.min(new.len() - 1), col.min(cols - 1)))
            }
        });
        return GridTransition::Rebuild { selection };
    }
    let old = old.unwrap();
    let cells = old
        .iter()
        .zip(new)
        .enumerate()
        .flat_map(|(r, (a, b))| {
            a.iter()
                .zip(b)
                .enumerate()
                .filter_map(move |(c, (x, y))| (x != y).then_some((r, c)))
        })
        .collect();
    GridTransition::Update { cells }
}
#[cfg(test)]
mod grid_tests {
    use super::*;
    #[test]
    fn selection_events_keep_the_model_authoritative() {
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(5), None, false),
            Some((5, 3))
        );
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(4), Some(1), false),
            Some((4, 1))
        );
        assert_eq!(grid_selection_event(Some((4, 3)), None, None, false), None);
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(4), None, false),
            None
        );
        assert_eq!(
            grid_selection_event(Some((4, 3)), Some(1), None, true),
            None
        );
    }
    #[test]
    fn sparse_changes_and_structure_selection() {
        let old = vec![vec![String::new(); 100]; 1000];
        let mut next = old.clone();
        next[0][0] = "1".into();
        next[999][99] = "2".into();
        assert_eq!(
            grid_transition(Some(&old), &next, Some((999, 99))),
            GridTransition::Update {
                cells: vec![(0, 0), (999, 99)]
            }
        );
        next.truncate(3);
        next.iter_mut().for_each(|r| r.truncate(2));
        assert_eq!(
            grid_transition(Some(&old), &next, Some((999, 99))),
            GridTransition::Rebuild {
                selection: Some((2, 1))
            }
        );
        assert_eq!(
            grid_transition(Some(&old), &[], Some((0, 0))),
            GridTransition::Rebuild { selection: None }
        );
    }
}

/// Resolve a selected native row or clicked cell against the current model selection.
/// Deselect-only and programmatic notifications are ignored.
pub fn grid_selection_event(
    current: Option<(usize, usize)>,
    row: Option<usize>,
    clicked_col: Option<usize>,
    programmatic: bool,
) -> Option<(usize, usize)> {
    if programmatic {
        return None;
    }
    let row = row?;
    let col = clicked_col.or_else(|| current.map(|(_, col)| col))?;
    let next = (row, col);
    (Some(next) != current).then_some(next)
}

/// Format offered by an Open, Save As, Import or Export dialog.
#[derive(Clone, Debug)]
pub struct FileFormat {
    pub id: &'static str,
    pub title: &'static str,
    pub extensions: &'static [&'static str],
}
/// One definition shared by menus, toolbars and accelerators.
#[derive(Clone, Debug)]
pub struct CommandSpec {
    pub id: u16,
    pub title: &'static str,
    pub accelerator: Option<&'static str>,
    pub group: &'static str,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CommandState {
    pub enabled: bool,
    pub checked: bool,
}
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Viewport {
    pub zoom: f64,
    pub pan: Point,
}
impl Default for Viewport {
    fn default() -> Self {
        Self {
            zoom: 1.0,
            pan: Point::default(),
        }
    }
}
impl Viewport {
    pub fn document_to_view(self, p: Point) -> Point {
        Point {
            x: p.x * self.zoom + self.pan.x,
            y: p.y * self.zoom + self.pan.y,
        }
    }
    pub fn view_to_document(self, p: Point) -> Option<Point> {
        if !self.zoom.is_finite() || self.zoom <= 0.0 {
            return None;
        }
        Some(Point {
            x: (p.x - self.pan.x) / self.zoom,
            y: (p.y - self.pan.y) / self.zoom,
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CanvasEvent {
    PointerDown(Point),
    PointerMove(Point),
    PointerUp(Point),
    Cancel,
    Key { code: u32, modifiers: u32 },
}

/// Device-independent scene in document coordinates. Colors are RGB bytes.
#[derive(Clone, Debug)]
pub enum SceneItem {
    Rect {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        fill: [u8; 3],
        stroke: [u8; 3],
    },
    Ellipse {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        fill: Option<[u8; 3]>,
        stroke: Option<[u8; 3]>,
    },
    Text {
        x: f64,
        y: f64,
        text: String,
        color: [u8; 3],
    },
    TextBox {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        text: String,
        color: [u8; 3],
        font: SceneFont,
        align: TextAlign,
        wrap: bool,
    },
    Path {
        points: Vec<Point>,
        color: [u8; 3],
        closed: bool,
    },
    Image {
        x: f64,
        y: f64,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    },
    /// Pixel dimensions are independent from the destination rectangle in scene units.
    ImageScaled {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        pixel_width: u32,
        pixel_height: u32,
        rgba: Vec<u8>,
    },
}
#[derive(Clone, Debug)]
pub struct SceneFont {
    pub family: String,
    pub points: f64,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextAlign {
    Left,
    Center,
    Right,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParagraphRuler {
    pub left_twips: i32,
    pub right_twips: i32,
    pub first_line_twips: i32,
    pub tabs_twips: Vec<i32>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RichRuler {
    pub page: PrintGeometry,
    pub zoom_percent: u16,
    pub paragraph: Option<ParagraphRuler>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RichRulerAction {
    LeftMargin(i32),
    RightMargin(i32),
    TopMargin(i32),
    BottomMargin(i32),
    LeftIndent(i32),
    RightIndent(i32),
    FirstIndent(i32),
    AddTab(i32),
    MoveTab { from: i32, to: i32 },
    RemoveTab(i32),
}
/// Paper dimensions and margins in twips (1/1440 inch), independent of printer DPI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PrintGeometry {
    pub width_twips: i32,
    pub height_twips: i32,
    pub margin_left_twips: i32,
    pub margin_top_twips: i32,
    pub margin_right_twips: i32,
    pub margin_bottom_twips: i32,
}
impl PrintGeometry {
    pub fn valid(self) -> bool {
        self.width_twips > 0
            && self.height_twips > 0
            && [
                self.margin_left_twips,
                self.margin_top_twips,
                self.margin_right_twips,
                self.margin_bottom_twips,
            ]
            .iter()
            .all(|x| *x >= 0)
            && i64::from(self.margin_left_twips) + i64::from(self.margin_right_twips)
                < i64::from(self.width_twips)
            && i64::from(self.margin_top_twips) + i64::from(self.margin_bottom_twips)
                < i64::from(self.height_twips)
    }
}
#[derive(Clone, Debug)]
pub struct PrintPage {
    pub geometry: PrintGeometry,
    pub scene: CanvasScene,
}
#[derive(Clone, Debug)]
pub enum PrintText {
    Literal(String),
    PageNumber,
    PageCount,
}
#[derive(Clone, Debug)]
pub struct PrintFragment {
    pub text: PrintText,
    pub font: SceneFont,
    pub color: [u8; 3],
}
#[derive(Clone, Debug)]
pub struct PrintParagraph {
    pub align: TextAlign,
    pub fragments: Vec<PrintFragment>,
}
#[derive(Clone, Debug)]
pub struct RichPrint {
    pub geometry: PrintGeometry,
    pub header_distance_twips: i32,
    pub footer_distance_twips: i32,
    pub header: Vec<PrintParagraph>,
    pub footer: Vec<PrintParagraph>,
}
#[derive(Clone, Debug)]
pub enum PrintJob {
    Scenes(Vec<PrintPage>),
    RichText(RichPrint),
}
#[derive(Clone, Debug, Default)]
pub struct CanvasScene {
    pub viewport: Viewport,
    pub items: Vec<SceneItem>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GridRange {
    pub top: usize,
    pub left: usize,
    pub bottom: usize,
    pub right: usize,
}
#[derive(Clone, Debug, Default)]
pub struct GridCellStyle {
    pub foreground: Option<[u8; 3]>,
    pub background: Option<[u8; 3]>,
    pub bold: bool,
    pub italic: bool,
    pub merged: Option<GridRange>,
    pub borders: u8,
}

#[derive(Clone, Debug)]
pub struct FontChoice {
    pub family: String,
    pub points: f64,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub color: [u8; 3],
}
#[derive(Clone, Debug)]
pub enum DialogRequest {
    Color([u8; 3]),
    Font,
    PageSetup(PageMargins),
}
#[derive(Clone, Debug)]
pub enum DialogResult {
    Color([u8; 3]),
    Font(FontChoice),
    PageSetup(PageMargins),
}

#[derive(Clone, Debug)]
pub enum ClipboardRequest {
    ReadText,
    WriteText(String),
    ReadData(String),
    WriteData { format: String, bytes: Vec<u8> },
}

/// Paper and margins in hundredths of a millimetre.
#[derive(Clone, Copy, Debug, Default)]
pub struct PageMargins {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
    pub paper_width: i32,
    pub paper_height: i32,
}
