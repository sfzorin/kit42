#![cfg_attr(windows, windows_subsystem = "windows")]
use img42_core::ImageDocument;
use std::path::Path;
#[derive(Default)]
struct Img {
    doc: Option<ImageDocument>,
    zoom: Option<f64>,
}
impl win42::App for Img {
    fn name(&self) -> &'static str {
        "IMG42"
    }
    fn extension(&self) -> &'static str {
        "png"
    }
    fn format_name(&self) -> &'static str {
        "PNG / JPEG image"
    }
    fn open_filter(&self) -> String {
        "*.png;*.jpg;*.jpeg".into()
    }
    fn actions(&self) -> &'static [(u16, &'static str)] {
        &[
            (10, "Rotate &Left"),
            (11, "Rotate &Right"),
            (15, "Flip &Horizontal"),
            (16, "Flip &Vertical"),
            (17, "&Resize..."),
        ]
    }
    fn input_request(&self, id: u16) -> Option<win42::InputRequest> {
        let d = self.doc.as_ref()?;
        (id == 17).then(|| win42::InputRequest {
            title: "Resize image (nearest neighbour)",
            fields: vec![
                ("Width (pixels)", d.width().to_string()),
                ("Height (pixels)", d.height().to_string()),
            ],
        })
    }
    fn input_action(&mut self, id: u16, values: &[String]) -> Result<(), String> {
        if id != 17 || values.len() != 2 {
            return Err("Invalid resize request".into());
        }
        let width = values[0]
            .parse::<u32>()
            .map_err(|_| "Width must be a positive integer")?;
        let height = values[1]
            .parse::<u32>()
            .map_err(|_| "Height must be a positive integer")?;
        self.doc
            .as_mut()
            .ok_or("Open an image first")?
            .resize(width, height)
            .map_err(|e| e.to_string())
    }
    fn view_actions(&self) -> &'static [(u16, &'static str)] {
        &[(12, "Zoom &In"), (13, "Zoom &Out"), (14, "&Fit to Window")]
    }
    fn items(&self) -> Vec<String> {
        vec![]
    }
    fn list_visible(&self) -> bool {
        false
    }
    fn text(&self) -> String {
        "Open a PNG or JPEG image.".into()
    }
    fn text_readonly(&self) -> bool {
        true
    }
    fn image(&self) -> Option<(u32, u32, Vec<u8>)> {
        self.doc
            .as_ref()
            .map(|d| (d.width(), d.height(), d.pixels().to_vec()))
    }
    fn image_zoom(&self) -> Option<f64> {
        self.zoom
    }
    fn status(&self) -> String {
        self.doc
            .as_ref()
            .map(|d| {
                format!(
                    "{} × {} pixels | {}",
                    d.width(),
                    d.height(),
                    self.zoom
                        .map(|z| format!("{:.0}%", 100.0 * z))
                        .unwrap_or_else(|| "Fit".into())
                )
            })
            .unwrap_or_else(|| "Open a PNG or JPEG image".into())
    }
    fn dirty(&self) -> bool {
        self.doc.as_ref().is_some_and(|d| d.is_dirty())
    }
    fn can_undo(&self) -> bool {
        self.doc.as_ref().is_some_and(|d| d.can_undo())
    }
    fn can_redo(&self) -> bool {
        self.doc.as_ref().is_some_and(|d| d.can_redo())
    }
    fn can_save(&self) -> bool {
        self.doc.is_some()
    }
    fn enabled(&self, _: u16) -> bool {
        self.doc.is_some()
    }
    fn open(&mut self, p: &Path) -> Result<(), String> {
        self.doc = Some(ImageDocument::open(p).map_err(|e| e.to_string())?);
        self.zoom = None;
        Ok(())
    }
    fn save(&mut self, p: &Path) -> Result<(), String> {
        self.doc
            .as_mut()
            .ok_or("Open an image first")?
            .save_as_png(p)
            .map_err(|e| e.to_string())
    }
    fn edit(&mut self, _: String) -> Result<(), String> {
        Ok(())
    }
    fn select(&mut self, _: usize) {}
    fn action(&mut self, id: u16) -> Result<(), String> {
        let d = self.doc.as_mut().ok_or("Open an image first")?;
        match id {
            4 => {
                d.undo();
            }
            5 => {
                d.redo();
            }
            10 => d.rotate_ccw().map_err(|e| e.to_string())?,
            11 => d.rotate_cw().map_err(|e| e.to_string())?,
            15 => d.flip_horizontal().map_err(|e| e.to_string())?,
            16 => d.flip_vertical().map_err(|e| e.to_string())?,
            12 => self.zoom = Some((self.zoom.unwrap_or(1.0) * 1.25).min(16.0)),
            13 => self.zoom = Some((self.zoom.unwrap_or(1.0) * 0.8).max(0.05)),
            14 => self.zoom = None,
            _ => {}
        }
        Ok(())
    }
}
fn main() {
    win42::run(Box::new(Img::default()))
}
