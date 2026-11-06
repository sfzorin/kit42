//! Image-page workflow with project/PDF export and optional external Tesseract OCR.
use lopdf::{dictionary, Document, Object, Stream};
use std::{io::Read, path::Path};
use suite42_core::{write_new, SnapshotHistory};
const MAX_PAGES: usize = 32;
const MAX_BYTES: usize = 16 * 1024 * 1024;
#[derive(Clone, Debug, PartialEq)]
pub struct OcrWord {
    pub text: String,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub width: u32,
    pub height: u32,
    pub dpi_x: u32,
    pub dpi_y: u32,
    pub pixels: Vec<u8>,
    pub words: Vec<OcrWord>,
}
pub struct SaveState(Vec<Page>);

pub struct ScanDocument {
    history: SnapshotHistory<Vec<Page>>,
}
impl Default for ScanDocument {
    fn default() -> Self {
        Self::new()
    }
}
impl ScanDocument {
    pub fn new() -> Self {
        Self {
            history: SnapshotHistory::new(Vec::new(), 5),
        }
    }
    pub fn pages(&self) -> &[Page] {
        self.history.current()
    }
    pub fn add_rgba(&mut self, width: u32, height: u32, pixels: Vec<u8>) -> Result<(), String> {
        let len = (width as usize)
            .checked_mul(height as usize)
            .and_then(|v| v.checked_mul(4))
            .ok_or("invalid dimensions")?;
        if width == 0
            || height == 0
            || width > 10000
            || height > 10000
            || pixels.len() != len
            || len > MAX_BYTES
            || self.pages().len() >= MAX_PAGES
            || self.pages().iter().map(|p| p.pixels.len()).sum::<usize>() + len > MAX_BYTES
        {
            return Err("invalid image or page/memory limit exceeded".into());
        }
        let mut pages = self.pages().to_vec();
        pages.push(Page {
            width,
            height,
            dpi_x: 150,
            dpi_y: 150,
            pixels,
            words: Vec::new(),
        });
        self.history.apply(pages);
        Ok(())
    }
    /// Validate and add acquired pages as one history entry.
    pub fn add_pages(&mut self, pages: Vec<(u32, u32, Vec<u8>)>) -> Result<(), String> {
        let mut candidate = Self {
            history: SnapshotHistory::new(self.pages().to_vec(), 5),
        };
        for (width, height, pixels) in pages {
            candidate.add_rgba(width, height, pixels)?;
        }
        self.history.apply(candidate.pages().to_vec());
        Ok(())
    }
    /// Import pages and their physical resolutions as a single undoable transaction.
    pub fn add_pages_with_dpi(
        &mut self,
        pages: Vec<(u32, u32, Vec<u8>, u32, u32)>,
    ) -> Result<(), String> {
        let mut candidate = Self {
            history: SnapshotHistory::new(self.pages().to_vec(), 5),
        };
        for (w, h, pixels, x, y) in pages {
            candidate.add_rgba(w, h, pixels)?;
            let i = candidate.pages().len() - 1;
            candidate.set_dpi(i, x, y)?;
        }
        self.history.apply(candidate.pages().to_vec());
        Ok(())
    }
    /// Set physical resolution without changing pixels; part of undoable project state.
    pub fn set_dpi(&mut self, index: usize, x: u32, y: u32) -> Result<(), String> {
        if !(1..=9600).contains(&x) || !(1..=9600).contains(&y) {
            return Err("Resolution must be 1–9600 DPI".into());
        }
        let mut pages = self.pages().to_vec();
        let page = pages.get_mut(index).ok_or("page index out of range")?;
        page.dpi_x = x;
        page.dpi_y = y;
        self.history.apply(pages);
        Ok(())
    }
    pub fn delete(&mut self, index: usize) -> Result<(), String> {
        if index >= self.pages().len() {
            return Err("page index out of range".into());
        }
        let mut p = self.pages().to_vec();
        p.remove(index);
        self.history.apply(p);
        Ok(())
    }
    pub fn move_page(&mut self, from: usize, to: usize) -> Result<(), String> {
        if from >= self.pages().len() || to >= self.pages().len() {
            return Err("page index out of range".into());
        }
        let mut p = self.pages().to_vec();
        let x = p.remove(from);
        p.insert(to, x);
        self.history.apply(p);
        Ok(())
    }
    pub fn rotate(&mut self, index: usize) -> Result<(), String> {
        let mut p = self.pages().to_vec();
        let page = p.get_mut(index).ok_or("page index out of range")?;
        let (w, h) = (page.width as usize, page.height as usize);
        let mut out = vec![0; page.pixels.len()];
        for y in 0..h {
            for x in 0..w {
                let a = (y * w + x) * 4;
                let b = (x * h + (h - 1 - y)) * 4;
                out[b..b + 4].copy_from_slice(&page.pixels[a..a + 4]);
            }
        }
        page.width = h as u32;
        page.height = w as u32;
        std::mem::swap(&mut page.dpi_x, &mut page.dpi_y);
        page.pixels = out;
        page.words.clear();
        self.history.apply(p);
        Ok(())
    }
    pub fn undo(&mut self) -> bool {
        self.history.undo()
    }
    pub fn redo(&mut self) -> bool {
        self.history.redo()
    }
    pub fn can_undo(&self) -> bool {
        self.history.can_undo()
    }
    pub fn can_redo(&self) -> bool {
        self.history.can_redo()
    }
    pub fn is_dirty(&self) -> bool {
        self.history.is_dirty()
    }
    /// Save an editable, versioned project to a new destination.
    pub fn save_snapshot(&self) -> (Vec<u8>, SaveState) {
        let state = self.history.snapshot();
        let mut bytes = b"SCN42\0\x03\0".to_vec();
        bytes.extend_from_slice(&(self.pages().len() as u32).to_le_bytes());
        for page in self.pages() {
            bytes.extend_from_slice(&page.width.to_le_bytes());
            bytes.extend_from_slice(&page.height.to_le_bytes());
            bytes.extend_from_slice(&page.dpi_x.to_le_bytes());
            bytes.extend_from_slice(&page.dpi_y.to_le_bytes());
            bytes.extend_from_slice(&page.pixels);
            bytes.extend_from_slice(&(page.words.len() as u32).to_le_bytes());
            for word in &page.words {
                for n in [
                    word.x,
                    word.y,
                    word.width,
                    word.height,
                    word.text.len() as u32,
                ] {
                    bytes.extend_from_slice(&n.to_le_bytes());
                }
                bytes.extend_from_slice(word.text.as_bytes());
            }
        }
        (bytes, SaveState(state))
    }
    pub fn mark_saved_snapshot(&mut self, state: SaveState) {
        self.history.mark_saved_snapshot(state.0);
    }
    pub fn save_project(&mut self, path: &Path) -> Result<(), String> {
        let (bytes, state) = self.save_snapshot();
        write_new(path, &bytes).map_err(|e| e.to_string())?;
        self.mark_saved_snapshot(state);
        Ok(())
    }
    /// Validate the complete input before returning a new clean document.
    pub fn open_project(path: &Path) -> Result<Self, String> {
        const LIMIT: u64 = (MAX_BYTES * 2 + MAX_PAGES * 12 + 12) as u64;
        let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
        let mut bytes = Vec::new();
        file.take(LIMIT + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > LIMIT
            || bytes.len() < 12
            || !matches!(
                &bytes[..8],
                b"SCN42\0\x01\0" | b"SCN42\0\x02\0" | b"SCN42\0\x03\0"
            )
        {
            return Err("invalid or oversized SCN42 project".into());
        }
        let read_u32 = |pos: usize| -> Result<u32, String> {
            Ok(u32::from_le_bytes(
                bytes
                    .get(pos..pos + 4)
                    .ok_or("truncated project")?
                    .try_into()
                    .unwrap(),
            ))
        };
        let version = bytes[6];
        let count = read_u32(8)? as usize;
        if count > MAX_PAGES {
            return Err("page limit exceeded".into());
        }
        let mut pos = 12usize;
        let mut doc = Self::new();
        for _ in 0..count {
            let width = read_u32(pos)?;
            let height = read_u32(pos + 4)?;
            pos += 8;
            let (dpi_x, dpi_y) = if version >= 3 {
                let x = read_u32(pos)?;
                let y = read_u32(pos + 4)?;
                pos += 8;
                (x, y)
            } else {
                (150, 150)
            };
            if !(1..=9600).contains(&dpi_x) || !(1..=9600).contains(&dpi_y) {
                return Err("invalid page resolution".into());
            }
            let len = (width as usize)
                .checked_mul(height as usize)
                .and_then(|n| n.checked_mul(4))
                .ok_or("invalid dimensions")?;
            if len > MAX_BYTES {
                return Err("page limit exceeded".into());
            }
            let end = pos.checked_add(len).ok_or("invalid length")?;
            let pixels = bytes.get(pos..end).ok_or("truncated project")?.to_vec();
            doc.add_rgba(width, height, pixels)?;
            doc.set_dpi(doc.pages().len() - 1, dpi_x, dpi_y)?;
            pos = end;
            if version >= 2 {
                let count = read_u32(pos)? as usize;
                pos += 4;
                if count > 100_000 {
                    return Err("OCR word limit exceeded".into());
                }
                let mut words = Vec::with_capacity(count);
                for _ in 0..count {
                    let x = read_u32(pos)?;
                    let y = read_u32(pos + 4)?;
                    let w = read_u32(pos + 8)?;
                    let h = read_u32(pos + 12)?;
                    let n = read_u32(pos + 16)? as usize;
                    pos += 20;
                    let end = pos.checked_add(n).ok_or("invalid OCR length")?;
                    let text = std::str::from_utf8(bytes.get(pos..end).ok_or("truncated OCR")?)
                        .map_err(|e| e.to_string())?
                        .to_string();
                    if w == 0
                        || h == 0
                        || x.checked_add(w).is_none_or(|v| v > width)
                        || y.checked_add(h).is_none_or(|v| v > height)
                    {
                        return Err("invalid OCR geometry".into());
                    }
                    words.push(OcrWord {
                        text,
                        x,
                        y,
                        width: w,
                        height: h,
                    });
                    pos = end;
                }
                let mut pages = doc.pages().to_vec();
                pages.last_mut().unwrap().words = words;
                doc.history.apply(pages);
            }
        }
        if pos != bytes.len() {
            return Err("trailing project data".into());
        }
        doc.history = SnapshotHistory::new(doc.pages().to_vec(), 5);
        Ok(doc)
    }
    pub fn flip(&mut self, index: usize, horizontal: bool) -> Result<(), String> {
        let mut pages = self.pages().to_vec();
        let page = pages.get_mut(index).ok_or("page index out of range")?;
        let (w, h) = (page.width as usize, page.height as usize);
        let mut pixels = vec![0; page.pixels.len()];
        for y in 0..h {
            for x in 0..w {
                let (dx, dy) = if horizontal {
                    (w - 1 - x, y)
                } else {
                    (x, h - 1 - y)
                };
                let src = (y * w + x) * 4;
                let dst = (dy * w + dx) * 4;
                pixels[dst..dst + 4].copy_from_slice(&page.pixels[src..src + 4]);
            }
        }
        page.pixels = pixels;
        page.words.clear();
        self.history.apply(pages);
        Ok(())
    }
    /// Apply a page crop in pixel coordinates as one undoable operation.
    pub fn crop(
        &mut self,
        index: usize,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        let mut pages = self.pages().to_vec();
        let p = pages.get_mut(index).ok_or("page index out of range")?;
        if width == 0
            || height == 0
            || x.checked_add(width).is_none_or(|v| v > p.width)
            || y.checked_add(height).is_none_or(|v| v > p.height)
        {
            return Err("invalid crop rectangle".into());
        }
        let mut pixels = Vec::with_capacity(width as usize * height as usize * 4);
        for row in y..y + height {
            let start = ((row * p.width + x) * 4) as usize;
            pixels.extend_from_slice(&p.pixels[start..start + width as usize * 4]);
        }
        p.width = width;
        p.height = height;
        p.pixels = pixels;
        p.words.clear();
        self.history.apply(pages);
        Ok(())
    }
    /// Rectify a quadrilateral given clockwise source corners (top-left first).
    pub fn perspective(
        &mut self,
        index: usize,
        corners: [(f64, f64); 4],
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        let other_bytes: usize = self
            .pages()
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != index)
            .map(|(_, p)| p.pixels.len())
            .sum();
        let mut pages = self.pages().to_vec();
        let page = pages.get_mut(index).ok_or("page index out of range")?;
        if u64::from(width) * u64::from(height) * 4 + other_bytes as u64 > MAX_BYTES as u64 {
            return Err("Page memory limit exceeded".into());
        }
        if width < 2
            || height < 2
            || u64::from(width) * u64::from(height) * 4 > MAX_BYTES as u64
            || corners.iter().any(|(x, y)| {
                !x.is_finite()
                    || !y.is_finite()
                    || *x < 0.0
                    || *y < 0.0
                    || *x > (page.width - 1) as f64
                    || *y > (page.height - 1) as f64
            })
        {
            return Err("Invalid correction bounds".into());
        }
        // Solve destination-to-source projective transform with h22=1.
        let dest = [
            (0.0, 0.0),
            ((width - 1) as f64, 0.0),
            ((width - 1) as f64, (height - 1) as f64),
            (0.0, (height - 1) as f64),
        ];
        let mut a = [[0.0f64; 9]; 8];
        for i in 0..4 {
            let (x, y) = dest[i];
            let (u, v) = corners[i];
            a[2 * i] = [x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y, u];
            a[2 * i + 1] = [0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y, v];
        }
        for i in 0..8 {
            let pivot = (i..8)
                .max_by(|&j, &k| a[j][i].abs().total_cmp(&a[k][i].abs()))
                .unwrap();
            if a[pivot][i].abs() < 1e-9 {
                return Err("Degenerate correction quadrilateral".into());
            }
            a.swap(i, pivot);
            let v = a[i][i];
            for k in i..9 {
                a[i][k] /= v;
            }
            for j in 0..8 {
                if j != i {
                    let v = a[j][i];
                    for k in i..9 {
                        a[j][k] -= v * a[i][k];
                    }
                }
            }
        }
        let h: Vec<f64> = a.iter().map(|r| r[8]).collect();
        let mut pixels = vec![255u8; width as usize * height as usize * 4];
        for y in 0..height {
            for x in 0..width {
                let (x, y) = (x as f64, y as f64);
                let d = h[6] * x + h[7] * y + 1.0;
                if d.abs() < 1e-9 {
                    continue;
                }
                let sx = (h[0] * x + h[1] * y + h[2]) / d;
                let sy = (h[3] * x + h[4] * y + h[5]) / d;
                if sx < 0.0
                    || sy < 0.0
                    || sx > (page.width - 1) as f64
                    || sy > (page.height - 1) as f64
                {
                    continue;
                }
                let x0 = sx.floor() as u32;
                let y0 = sy.floor() as u32;
                let x1 = (x0 + 1).min(page.width - 1);
                let y1 = (y0 + 1).min(page.height - 1);
                let fx = sx - x0 as f64;
                let fy = sy - y0 as f64;
                let out = (y as usize * width as usize + x as usize) * 4;
                for c in 0..4 {
                    let v = |xx: u32, yy: u32| {
                        page.pixels[((yy * page.width + xx) * 4) as usize + c] as f64
                    };
                    pixels[out + c] = ((v(x0, y0) * (1.0 - fx) + v(x1, y0) * fx) * (1.0 - fy)
                        + (v(x0, y1) * (1.0 - fx) + v(x1, y1) * fx) * fy)
                        .round()
                        .clamp(0.0, 255.0) as u8;
                }
            }
        }
        page.width = width;
        page.height = height;
        page.pixels = pixels;
        page.words.clear();
        self.history.apply(pages);
        Ok(())
    }
    /// Rotate around the page centre, expanding to fit the existing page dimensions.
    pub fn deskew(&mut self, index: usize, degrees: f64) -> Result<(), String> {
        if !degrees.is_finite() || !(-45.0..=45.0).contains(&degrees) {
            return Err("Deskew angle must be between -45 and 45 degrees".into());
        }
        let p = self.pages().get(index).ok_or("page index out of range")?;
        if p.width < 2 || p.height < 2 {
            return Err("Page is too small".into());
        }
        let (w, h) = ((p.width - 1) as f64, (p.height - 1) as f64);
        let (cx, cy) = (w / 2.0, h / 2.0);
        let angle = degrees.to_radians();
        let (sin, cos) = angle.sin_cos();
        // Largest centred inscribed rectangle keeps all sampling coordinates valid.
        let scale = (w / (w * cos.abs() + h * sin.abs())).min(h / (h * cos.abs() + w * sin.abs()));
        let map = |x: f64, y: f64| {
            let (x, y) = ((x - cx) * scale, (y - cy) * scale);
            (cx + x * cos - y * sin, cy + x * sin + y * cos)
        };
        let corners = [map(0.0, 0.0), map(w, 0.0), map(w, h), map(0.0, h)];
        self.perspective(index, corners, p.width, p.height)
    }
    /// Convert a page to grayscale or thresholded black and white.
    pub fn document_cleanup(&mut self, index: usize, threshold: Option<u8>) -> Result<(), String> {
        let mut pages = self.pages().to_vec();
        let page = pages.get_mut(index).ok_or("page index out of range")?;
        page.words.clear();
        for p in page.pixels.chunks_exact_mut(4) {
            let gray =
                ((u32::from(p[0]) * 2126 + u32::from(p[1]) * 7152 + u32::from(p[2]) * 722 + 5000)
                    / 10000) as u8;
            let gray = threshold.map_or(gray, |t| if gray >= t { 255 } else { 0 });
            p[0] = gray;
            p[1] = gray;
            p[2] = gray;
        }
        self.history.apply(pages);
        Ok(())
    }
    /// Apply recognition only to the exact page that was submitted.
    pub fn apply_ocr(
        &mut self,
        index: usize,
        source: &Page,
        words: Vec<OcrWord>,
    ) -> Result<(), String> {
        let mut pages = self.pages().to_vec();
        let page = pages.get_mut(index).ok_or("page no longer exists")?;
        if page.width != source.width
            || page.height != source.height
            || page.pixels != source.pixels
        {
            return Err("page changed while recognition was running".into());
        }
        page.words = words;
        self.history.apply(pages);
        Ok(())
    }
    pub fn recognized_text(&self) -> String {
        self.pages()
            .iter()
            .map(|p| {
                p.words
                    .iter()
                    .map(|w| w.text.as_str())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    }
    /// Execute Tesseract with cancellation and return validated word geometry.
    pub fn recognize_page(
        page: &Page,
        executable: &str,
        language: &str,
        cancel: &std::sync::atomic::AtomicBool,
    ) -> Result<Vec<OcrWord>, String> {
        use std::io::Write;
        use std::process::{Command, Stdio};
        if language.is_empty()
            || !language
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '+')
        {
            return Err("Invalid Tesseract language".into());
        }
        if executable.trim().is_empty() {
            return Err("Enter the path to the installed Tesseract executable".into());
        }
        let mut child = Command::new(executable)
            .args(["stdin", "stdout", "-l", language, "tsv"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Cannot start Tesseract at {executable}: {e}. Install Tesseract with the required language data, then enter its executable path."))?;
        let mut ppm = format!("P6\n{} {}\n255\n", page.width, page.height).into_bytes();
        for p in page.pixels.chunks_exact(4) {
            let a = u32::from(p[3]);
            for c in &p[..3] {
                ppm.push(((u32::from(*c) * a + 255 * (255 - a) + 127) / 255) as u8);
            }
        }
        let mut stdin = child.stdin.take().ok_or("OCR input unavailable")?;
        let mut stdout = child.stdout.take().ok_or("OCR output unavailable")?;
        let mut stderr = child.stderr.take().ok_or("OCR diagnostics unavailable")?;
        let writer = std::thread::spawn(move || stdin.write_all(&ppm));
        let reader = std::thread::spawn(move || {
            let mut data = Vec::new();
            stdout.read_to_end(&mut data).map(|_| data)
        });
        let errors = std::thread::spawn(move || {
            let mut data = Vec::new();
            stderr.read_to_end(&mut data).map(|_| data)
        });
        let start = std::time::Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                break status;
            }
            if cancel.load(std::sync::atomic::Ordering::Relaxed)
                || start.elapsed() >= std::time::Duration::from_secs(60)
            {
                let _ = child.kill();
                let _ = child.wait();
                let _ = writer.join();
                let _ = reader.join();
                let _ = errors.join();
                return Err("OCR cancelled or timed out".into());
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        let written = writer.join().map_err(|_| "OCR input worker failed")?;
        let output = reader
            .join()
            .map_err(|_| "OCR output worker failed")?
            .map_err(|e| e.to_string())?;
        let diagnostics = errors
            .join()
            .map_err(|_| "OCR diagnostics worker failed")?
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(format!(
                "Tesseract failed: {}",
                String::from_utf8_lossy(&diagnostics)
            ));
        }
        written.map_err(|e| e.to_string())?;
        let text = String::from_utf8(output).map_err(|e| e.to_string())?;
        let mut words = Vec::new();
        for line in text.lines().skip(1) {
            let fields: Vec<_> = line.splitn(12, '\t').collect();
            if fields.len() != 12 || fields[0] != "5" || fields[11].trim().is_empty() {
                continue;
            }
            let parse = |i: usize| {
                fields[i]
                    .parse::<u32>()
                    .map_err(|_| "Invalid Tesseract geometry".to_string())
            };
            let (x, y, w, h) = (parse(6)?, parse(7)?, parse(8)?, parse(9)?);
            if w == 0
                || h == 0
                || x.checked_add(w).is_none_or(|v| v > page.width)
                || y.checked_add(h).is_none_or(|v| v > page.height)
            {
                return Err("Invalid Tesseract geometry".into());
            }
            words.push(OcrWord {
                text: fields[11].to_string(),
                x,
                y,
                width: w,
                height: h,
            });
            if words.len() > 100_000 {
                return Err("OCR word limit exceeded".into());
            }
        }
        Ok(words)
    }
    pub fn export_pdf(&self, path: &Path) -> Result<(), String> {
        self.export_pdf_compressed(path, false)
    }
    pub fn export_pdf_compressed(&self, path: &Path, compressed: bool) -> Result<(), String> {
        if self.pages().is_empty() {
            return Err("cannot export an empty scan".into());
        }
        let mut doc = Document::with_version("1.5");
        let text: String = self
            .pages()
            .iter()
            .flat_map(|p| p.words.iter())
            .map(|w| w.text.as_str())
            .collect();
        let embedded = suite42_pdf_text::PdfFont::embed(&mut doc, &text)?;
        let chars = &embedded.chars;
        let font = embedded.id;
        let pages_id = doc.new_object_id();
        let mut kids = Vec::new();
        for page in self.pages() {
            let mut rgb = Vec::with_capacity(page.pixels.len() / 4 * 3);
            for p in page.pixels.as_chunks::<4>().0 {
                let a = p[3] as u32;
                for &c in &p[..3] {
                    rgb.push(((c as u32 * a + 255 * (255 - a) + 127) / 255) as u8)
                }
            }
            let image=doc.add_object(Stream::new(dictionary!{"Type"=>"XObject","Subtype"=>"Image","Width"=>page.width as i64,"Height"=>page.height as i64,"ColorSpace"=>"DeviceRGB","BitsPerComponent"=>8},rgb));
            let w = page.width as f32 * 72.0 / page.dpi_x as f32;
            let h = page.height as f32 * 72.0 / page.dpi_y as f32;
            let mut commands = format!("q {w} 0 0 {h} 0 0 cm /Im0 Do Q\n");
            for word in &page.words {
                let x = word.x as f32 * 72.0 / page.dpi_x as f32;
                let y = (page.height - word.y - word.height) as f32 * 72.0 / page.dpi_y as f32;
                let size = word.height as f32 * 72.0 / page.dpi_y as f32;
                let hex: String = word
                    .text
                    .chars()
                    .map(|c| format!("{:04X}", chars[&c].0))
                    .collect();
                let advance: u32 = word.text.chars().map(|c| chars[&c].2).sum();
                let target = word.width as f32 * 72.0 / page.dpi_x as f32;
                let scale = if advance == 0 {
                    100.0
                } else {
                    target * 100000.0 / (advance as f32 * size)
                };
                commands.push_str(&format!(
                    "BT /F1 {size} Tf {scale} Tz 3 Tr 1 0 0 1 {x} {y} Tm <{hex}> Tj ET\n"
                ));
            }
            let content = doc.add_object(Stream::new(dictionary! {}, commands.into_bytes()));
            let resources =
                dictionary! {"XObject"=>dictionary!{"Im0"=>image}, "Font"=>dictionary!{"F1"=>font}};
            let id=doc.add_object(dictionary!{"Type"=>"Page","Parent"=>pages_id,"MediaBox"=>vec![0.into(),0.into(),w.into(),h.into()],"Resources"=>resources,"Contents"=>content});
            kids.push(Object::Reference(id));
        }
        doc.objects.insert(
            pages_id,
            Object::Dictionary(
                dictionary! {"Type"=>"Pages","Count"=>kids.len() as i64,"Kids"=>kids},
            ),
        );
        let catalog = doc.add_object(dictionary! {"Type"=>"Catalog","Pages"=>pages_id});
        doc.trailer.set("Root", catalog);
        if compressed {
            doc.compress();
        }
        let mut bytes = Vec::new();
        doc.save_to(&mut bytes).map_err(|e| e.to_string())?;
        write_new(path, &bytes).map_err(|e| e.to_string())?;
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn compressed_pdf_keeps_page_and_text() {
        let dir = tempfile::tempdir().unwrap();
        let mut d = ScanDocument::new();
        d.add_rgba(20, 20, vec![255; 1600]).unwrap();
        let source = d.pages()[0].clone();
        d.apply_ocr(
            0,
            &source,
            vec![OcrWord {
                text: "Привет".into(),
                x: 0,
                y: 0,
                width: 10,
                height: 10,
            }],
        )
        .unwrap();
        let path = dir.path().join("compressed.pdf");
        d.export_pdf_compressed(&path, true).unwrap();
        let doc = lopdf::Document::load(&path).unwrap();
        assert_eq!(doc.get_pages().len(), 1);
        if std::process::Command::new("pdftotext")
            .arg("-v")
            .output()
            .is_ok()
        {
            let output = std::process::Command::new("pdftotext")
                .args(["-enc", "UTF-8"])
                .arg(&path)
                .arg("-")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(
                String::from_utf8_lossy(&output.stdout).contains("Привет"),
                "{:?}",
                output.stdout
            );
        }
    }
    #[test]
    fn dpi_and_perspective_roundtrip_undo() {
        let mut d = ScanDocument::new();
        d.add_rgba(3, 2, vec![255; 24]).unwrap();
        d.set_dpi(0, 300, 150).unwrap();
        d.perspective(0, [(0.0, 0.0), (2.0, 0.0), (2.0, 1.0), (0.0, 1.0)], 3, 2)
            .unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("p.scn42");
        d.save_project(&path).unwrap();
        let mut reopened = ScanDocument::open_project(&path).unwrap();
        assert_eq!(
            (reopened.pages()[0].dpi_x, reopened.pages()[0].dpi_y),
            (300, 150)
        );
        reopened.rotate(0).unwrap();
        assert_eq!(
            (reopened.pages()[0].dpi_x, reopened.pages()[0].dpi_y),
            (150, 300)
        );
        assert!(reopened.undo());
        assert_eq!(
            (reopened.pages()[0].dpi_x, reopened.pages()[0].dpi_y),
            (300, 150)
        );
    }
    #[test]
    fn ocr_roundtrip_and_stale_page_history() {
        let dir = tempfile::tempdir().unwrap();
        let mut d = ScanDocument::new();
        d.add_rgba(2, 2, vec![255; 16]).unwrap();
        let source = d.pages()[0].clone();
        let words = vec![OcrWord {
            text: "Привет".into(),
            x: 0,
            y: 0,
            width: 2,
            height: 1,
        }];
        d.apply_ocr(0, &source, words.clone()).unwrap();
        let project = dir.path().join("ocr.scn42");
        d.save_project(&project).unwrap();
        let mut reopened = ScanDocument::open_project(&project).unwrap();
        assert_eq!(reopened.pages()[0].words, words);
        reopened
            .export_pdf(&dir.path().join("searchable.pdf"))
            .unwrap();
        if std::process::Command::new("pdftotext")
            .arg("-v")
            .output()
            .is_ok()
        {
            let extracted = std::process::Command::new("pdftotext")
                .args(["-enc", "UTF-8"])
                .arg(dir.path().join("searchable.pdf"))
                .arg("-")
                .output()
                .unwrap();
            assert!(
                extracted.status.success(),
                "pdftotext failed: status={} stderr={}",
                extracted.status,
                String::from_utf8_lossy(&extracted.stderr)
            );
            assert!(
                String::from_utf8_lossy(&extracted.stdout).contains("Привет"),
                "Unicode extraction mismatch: stdout={:?}, bytes={:02x?}, stderr={}",
                String::from_utf8_lossy(&extracted.stdout),
                extracted.stdout,
                String::from_utf8_lossy(&extracted.stderr)
            );
        }
        reopened.rotate(0).unwrap();
        assert!(reopened.pages()[0].words.is_empty());
        assert!(reopened.undo());
        assert_eq!(reopened.pages()[0].words, words);
        reopened.document_cleanup(0, Some(128)).unwrap();
        assert!(reopened
            .apply_ocr(
                0,
                &Page {
                    pixels: vec![0; 16],
                    ..source
                },
                words
            )
            .is_err());
    }
    #[test]
    fn project_roundtrip_export_and_validation() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("project.scn42");
        let mut d = ScanDocument::new();
        d.add_rgba(2, 1, vec![1, 2, 3, 4, 5, 6, 7, 8]).unwrap();
        d.add_rgba(1, 1, vec![9, 10, 11, 12]).unwrap();
        d.move_page(1, 0).unwrap();
        d.flip(1, true).unwrap();
        let expected = d.pages().to_vec();
        d.save_project(&project).unwrap();
        assert!(!d.is_dirty());
        let mut reopened = ScanDocument::open_project(&project).unwrap();
        assert_eq!(reopened.pages(), expected);
        assert!(!reopened.is_dirty());
        reopened.flip(1, true).unwrap();
        assert!(reopened.is_dirty());
        reopened.export_pdf(&dir.path().join("out.pdf")).unwrap();
        assert!(reopened.is_dirty());
        assert!(reopened.undo());
        assert!(!reopened.is_dirty());
        assert!(reopened.redo());
        assert!(reopened.is_dirty());
        assert!(reopened.save_project(&project).is_err());
        assert!(reopened.is_dirty());
        let raw = fs::read(&project).unwrap();
        for bytes in [
            raw[..raw.len() - 1].to_vec(),
            [raw.clone(), vec![0]].concat(),
            b"SCN42\0\x04\0\0\0\0\0".to_vec(),
        ] {
            let bad = dir.path().join("bad.scn42");
            fs::write(&bad, bytes).unwrap();
            assert!(ScanDocument::open_project(&bad).is_err());
        }
    }
    #[test]
    fn crop_cleanup_history() {
        let mut d = ScanDocument::new();
        d.add_rgba(2, 1, vec![255, 0, 0, 255, 255, 255, 255, 255])
            .unwrap();
        d.crop(0, 0, 0, 1, 1).unwrap();
        d.document_cleanup(0, Some(128)).unwrap();
        assert_eq!(d.pages()[0].pixels, vec![0, 0, 0, 255]);
        assert!(d.undo());
        assert_eq!(d.pages()[0].pixels, vec![255, 0, 0, 255]);
        assert!(d.undo());
        assert_eq!(d.pages()[0].width, 2);
        assert!(d.redo());
        assert!(d.redo());
        assert_eq!(d.pages()[0].pixels, vec![0, 0, 0, 255]);
    }
    #[test]
    fn pages_history_and_pdf() {
        let mut d = ScanDocument::new();
        assert!(d.add_rgba(2, 1, vec![0; 7]).is_err());
        d.add_rgba(2, 1, vec![255, 0, 0, 255, 0, 0, 255, 0])
            .unwrap();
        d.add_rgba(1, 1, vec![1, 2, 3, 255]).unwrap();
        d.rotate(0).unwrap();
        assert_eq!((d.pages()[0].width, d.pages()[0].height), (1, 2));
        assert!(d.undo());
        assert_eq!(d.pages()[0].width, 2);
        assert!(d.redo());
        d.move_page(1, 0).unwrap();
        let path = std::env::temp_dir().join(format!("scn42-test-{}.pdf", std::process::id()));
        let _ = fs::remove_file(&path);
        d.export_pdf(&path).unwrap();
        assert!(d.is_dirty());
        let pdf = Document::load(&path).unwrap();
        assert_eq!(pdf.get_pages().len(), 2);
        let first = *pdf.get_pages().values().next().unwrap();
        let media = pdf
            .get_dictionary(first)
            .unwrap()
            .get(b"MediaBox")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(media[2].as_float().unwrap(), 0.48);
        assert_eq!(media[3].as_float().unwrap(), 0.48);
        let images: Vec<_> = pdf
            .objects
            .values()
            .filter_map(|o| o.as_stream().ok())
            .filter(|s| {
                s.dict.get(b"Subtype").ok().and_then(|v| v.as_name().ok()) == Some(b"Image")
            })
            .collect();
        assert_eq!(images.len(), 2);
        assert!(images
            .iter()
            .any(|s| s.content == vec![255, 0, 0, 255, 255, 255]));
        assert!(d.export_pdf(&path).is_err());
        fs::remove_file(path).unwrap();
        d.delete(0).unwrap();
        assert!(d.is_dirty());
        assert!(d.undo());
        assert!(d.is_dirty());
    }
}
