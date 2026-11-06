//! Portable, deliberately limited image editing core.
//!
//! PNG and JPEG are decoded to straight RGBA8, applying EXIF orientation. Export
//! writes a new PNG only. Colour profiles, metadata, animation, high bit depth,
//! and lossless JPEG transforms are not preserved. Never use this as a metadata-
//! preserving editor. The destination must not already exist.
use image::{ImageFormat, ImageReader, Limits};
use std::{
    fmt,
    fs::File,
    io::{self, BufReader, Cursor, Read, Write},
    path::Path,
    sync::Arc,
};

const MAX_FILE_BYTES: u64 = 128 * 1024 * 1024;
const MAX_DIMENSION: u32 = 16_384;
const MAX_PIXELS: u64 = 16_000_000;
const HISTORY_LIMIT: usize = 4;

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Decode(image::ImageError),
    UnsupportedFormat,
    TooLarge,
    InvalidImage,
    DestinationExists,
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O: {e}"),
            Self::Decode(e) => write!(f, "image: {e}"),
            Self::UnsupportedFormat => write!(f, "only PNG and JPEG are supported"),
            Self::TooLarge => write!(f, "image exceeds size limits"),
            Self::InvalidImage => write!(f, "invalid image dimensions or pixels"),
            Self::DestinationExists => write!(f, "destination already exists"),
        }
    }
}
impl std::error::Error for Error {}
impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<image::ImageError> for Error {
    fn from(e: image::ImageError) -> Self {
        Self::Decode(e)
    }
}

#[derive(Clone, PartialEq, Eq)]
struct Raster {
    width: u32,
    height: u32,
    pixels: Arc<[u8]>,
}
impl Raster {
    fn new(width: u32, height: u32, pixels: Vec<u8>) -> Result<Self, Error> {
        let count = u64::from(width) * u64::from(height);
        if width == 0 || height == 0 {
            return Err(Error::InvalidImage);
        }
        if width > MAX_DIMENSION || height > MAX_DIMENSION || count > MAX_PIXELS {
            return Err(Error::TooLarge);
        }
        if pixels.len() as u64 != count * 4 {
            return Err(Error::InvalidImage);
        }
        Ok(Self {
            width,
            height,
            pixels: pixels.into(),
        })
    }
    fn orient(&self, orientation: u16) -> Self {
        let swap = (5..=8).contains(&orientation);
        let (w, h) = if swap {
            (self.height, self.width)
        } else {
            (self.width, self.height)
        };
        let mut out = vec![0; self.pixels.len()];
        for y in 0..self.height {
            for x in 0..self.width {
                let (dx, dy) = match orientation {
                    2 => (self.width - 1 - x, y),
                    3 => (self.width - 1 - x, self.height - 1 - y),
                    4 => (x, self.height - 1 - y),
                    5 => (y, x),
                    6 => (self.height - 1 - y, x),
                    7 => (self.height - 1 - y, self.width - 1 - x),
                    8 => (y, self.width - 1 - x),
                    _ => (x, y),
                };
                let src = ((y as usize * self.width as usize) + x as usize) * 4;
                let dst = ((dy as usize * w as usize) + dx as usize) * 4;
                out[dst..dst + 4].copy_from_slice(&self.pixels[src..src + 4]);
            }
        }
        Self {
            width: w,
            height: h,
            pixels: out.into(),
        }
    }
}

pub struct ImageDocument {
    current: Raster,
    saved: Raster,
    undo: Vec<Raster>,
    redo: Vec<Raster>,
}
impl ImageDocument {
    pub fn open(path: &Path) -> Result<Self, Error> {
        let file = File::open(path)?;
        if file.metadata()?.len() > MAX_FILE_BYTES {
            return Err(Error::TooLarge);
        }
        let mut bytes = Vec::new();
        file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(Error::TooLarge);
        }
        let format = image::guess_format(&bytes).map_err(|_| Error::UnsupportedFormat)?;
        if !matches!(format, ImageFormat::Png | ImageFormat::Jpeg) {
            return Err(Error::UnsupportedFormat);
        }
        let orientation = exif::Reader::new()
            .read_from_container(&mut BufReader::new(Cursor::new(&bytes)))
            .ok()
            .and_then(|e| {
                e.get_field(exif::Tag::Orientation, exif::In::PRIMARY)
                    .and_then(|v| v.value.get_uint(0))
            })
            .filter(|v| (1..=8).contains(v))
            .unwrap_or(1) as u16;
        let mut reader = ImageReader::with_format(Cursor::new(&bytes), format);
        let mut limits = Limits::default();
        limits.max_image_width = Some(MAX_DIMENSION);
        limits.max_image_height = Some(MAX_DIMENSION);
        limits.max_alloc = Some(MAX_PIXELS * 8);
        reader.limits(limits);
        let decoder = reader.into_decoder()?;
        use image::ImageDecoder;
        let (w, h) = decoder.dimensions();
        if u64::from(w) * u64::from(h) > MAX_PIXELS {
            return Err(Error::TooLarge);
        }
        let image = image::DynamicImage::from_decoder(decoder)?.into_rgba8();
        let raster = Raster::new(w, h, image.into_raw())?.orient(orientation);
        Ok(Self {
            saved: raster.clone(),
            current: raster,
            undo: Vec::new(),
            redo: Vec::new(),
        })
    }
    pub fn width(&self) -> u32 {
        self.current.width
    }
    pub fn height(&self) -> u32 {
        self.current.height
    }
    pub fn pixels(&self) -> &[u8] {
        &self.current.pixels
    }
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }
    pub fn is_dirty(&self) -> bool {
        self.current != self.saved
    }
    fn push(history: &mut Vec<Raster>, raster: Raster) {
        if history.len() == HISTORY_LIMIT {
            history.remove(0);
        }
        history.push(raster);
    }
    fn rotate(&mut self, orientation: u16) -> Result<(), Error> {
        let next = self.current.orient(orientation);
        if next != self.current {
            Self::push(&mut self.undo, self.current.clone());
            self.current = next;
            self.redo.clear();
        }
        Ok(())
    }
    pub fn flip_horizontal(&mut self) -> Result<(), Error> {
        self.rotate(2)
    }
    pub fn flip_vertical(&mut self) -> Result<(), Error> {
        self.rotate(4)
    }
    /// Resize using nearest-neighbour sampling, preserving straight RGBA samples.
    pub fn resize(&mut self, width: u32, height: u32) -> Result<(), Error> {
        if width == 0 || height == 0 {
            return Err(Error::InvalidImage);
        }
        if width > MAX_DIMENSION
            || height > MAX_DIMENSION
            || u64::from(width) * u64::from(height) > MAX_PIXELS
        {
            return Err(Error::TooLarge);
        }
        if (width, height) == (self.width(), self.height()) {
            return Ok(());
        }
        let image = image::RgbaImage::from_raw(self.width(), self.height(), self.pixels().to_vec())
            .ok_or(Error::InvalidImage)?;
        let pixels =
            image::imageops::resize(&image, width, height, image::imageops::FilterType::Nearest)
                .into_raw();
        let next = Raster::new(width, height, pixels)?;
        Self::push(&mut self.undo, self.current.clone());
        self.current = next;
        self.redo.clear();
        Ok(())
    }
    pub fn rotate_cw(&mut self) -> Result<(), Error> {
        self.rotate(6)
    }
    pub fn rotate_ccw(&mut self) -> Result<(), Error> {
        self.rotate(8)
    }
    pub fn undo(&mut self) -> bool {
        if let Some(previous) = self.undo.pop() {
            Self::push(&mut self.redo, self.current.clone());
            self.current = previous;
            true
        } else {
            false
        }
    }
    pub fn redo(&mut self) -> bool {
        if let Some(next) = self.redo.pop() {
            Self::push(&mut self.undo, self.current.clone());
            self.current = next;
            true
        } else {
            false
        }
    }
    /// Writes a new destination without replacing an existing file. The temporary file
    /// is created in the destination directory; publication uses tempfile’s no-clobber
    /// operation, whose atomicity depends on the platform and filesystem.
    /// On success the current pixels become the clean baseline.
    pub fn save_as_png(&mut self, path: &Path) -> Result<(), Error> {
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        {
            let encoder = image::codecs::png::PngEncoder::new(temp.as_file_mut());
            use image::ImageEncoder;
            encoder.write_image(
                self.pixels(),
                self.width(),
                self.height(),
                image::ExtendedColorType::Rgba8,
            )?;
        }
        temp.as_file_mut().flush()?;
        temp.as_file().sync_all()?;
        match temp.persist_noclobber(path) {
            Ok(_) => {
                self.saved = self.current.clone();
                Ok(())
            }
            Err(e) if e.error.kind() == io::ErrorKind::AlreadyExists => {
                Err(Error::DestinationExists)
            }
            Err(e) => Err(Error::Io(e.error)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::ImageEncoder;
    use std::fs;
    fn fixture() -> Raster {
        Raster::new(3, 2, (1..=6).flat_map(|v| [v, 0, 0, 255 - v]).collect()).unwrap()
    }
    fn values(r: &Raster) -> Vec<u8> {
        r.pixels.as_chunks::<4>().0.iter().map(|p| p[0]).collect()
    }
    fn document() -> ImageDocument {
        let r = fixture();
        ImageDocument {
            current: r.clone(),
            saved: r,
            undo: vec![],
            redo: vec![],
        }
    }
    #[test]
    fn all_orientation_mappings_and_alpha() {
        let original = fixture();
        let cases = [
            vec![1, 2, 3, 4, 5, 6],
            vec![3, 2, 1, 6, 5, 4],
            vec![6, 5, 4, 3, 2, 1],
            vec![4, 5, 6, 1, 2, 3],
            vec![1, 4, 2, 5, 3, 6],
            vec![4, 1, 5, 2, 6, 3],
            vec![6, 3, 5, 2, 4, 1],
            vec![3, 6, 2, 5, 1, 4],
        ];
        for (i, expected) in cases.iter().enumerate() {
            let r = original.orient((i + 1) as u16);
            assert_eq!(&values(&r), expected);
            assert_eq!((r.width, r.height), if i >= 4 { (2, 3) } else { (3, 2) });
            for p in r.pixels.as_chunks::<4>().0 {
                assert_eq!(p[3], 255 - p[0]);
            }
        }
    }
    #[test]
    fn limits_and_invalid_pixels() {
        assert!(matches!(
            Raster::new(0, 1, vec![]),
            Err(Error::InvalidImage)
        ));
        assert!(matches!(
            Raster::new(1, 1, vec![0]),
            Err(Error::InvalidImage)
        ));
        assert!(matches!(
            Raster::new(16_385, 1, vec![]),
            Err(Error::TooLarge)
        ));
        assert!(matches!(
            Raster::new(4001, 4000, vec![]),
            Err(Error::TooLarge)
        ));
    }
    #[test]
    fn history_clean_state_and_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("output.png");
        let mut d = document();
        let original = d.current.clone();
        d.rotate_cw().unwrap();
        let rotated = d.current.clone();
        assert!(d.is_dirty());
        assert!(d.undo());
        assert!(!d.is_dirty());
        assert_eq!(d.current.pixels, original.pixels);
        assert!(d.redo());
        assert_eq!(d.current.pixels, rotated.pixels);
        d.save_as_png(&path).unwrap();
        assert!(!d.is_dirty());
        let reopened = ImageDocument::open(&path).unwrap();
        assert!(reopened.current == rotated);
        assert!(d.undo());
        assert!(d.is_dirty());
        assert!(d.redo());
        assert!(!d.is_dirty());
        d.undo();
        d.rotate_ccw().unwrap();
        assert!(!d.can_redo());
    }
    #[test]
    fn save_failure_preserves_existing_destination_and_dirty_state() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("exists.png");
        fs::write(&path, b"original").unwrap();
        let mut d = document();
        d.rotate_cw().unwrap();
        assert!(matches!(
            d.save_as_png(&path),
            Err(Error::DestinationExists)
        ));
        assert_eq!(fs::read(&path).unwrap(), b"original");
        assert!(d.is_dirty());
        assert!(d
            .save_as_png(&dir.path().join("missing").join("out.png"))
            .is_err());
        assert!(d.is_dirty());
    }
    #[test]
    fn flips_resize_history_and_saved_pixels() {
        let mut d = document();
        d.flip_horizontal().unwrap();
        assert_eq!(values(&d.current), vec![3, 2, 1, 6, 5, 4]);
        d.flip_vertical().unwrap();
        assert_eq!(values(&d.current), vec![6, 5, 4, 3, 2, 1]);
        assert!(d.undo());
        assert_eq!(values(&d.current), vec![3, 2, 1, 6, 5, 4]);
        assert!(d.redo());
        d.resize(2, 1).unwrap();
        assert_eq!((d.width(), d.height()), (2, 1));
        let pixels = d.pixels().to_vec();
        assert!(d.resize(0, 1).is_err());
        assert!(d.resize(16385, 1).is_err());
        assert_eq!(d.pixels(), pixels);
        let path = tempfile::tempdir().unwrap();
        let output = path.path().join("out.png");
        d.save_as_png(&output).unwrap();
        let opened = ImageDocument::open(&output).unwrap();
        assert_eq!(opened.pixels(), pixels);
        assert!(!d.is_dirty());
        assert!(d.undo());
        assert!(d.is_dirty());
        assert!(d.redo());
        assert!(!d.is_dirty());
        d.undo();
        d.flip_vertical().unwrap();
        assert!(!d.can_redo());
    }
    #[test]
    fn jpeg_exif_orientation_is_applied_at_open() {
        let dir = tempfile::tempdir().unwrap();
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new(&mut jpeg)
            .write_image(
                &[
                    255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 127, 127, 127,
                ],
                3,
                2,
                image::ExtendedColorType::Rgb8,
            )
            .unwrap();
        for orientation in 1u8..=8 {
            // Little-endian TIFF with one SHORT orientation entry.
            let exif = [
                b'E',
                b'x',
                b'i',
                b'f',
                0,
                0,
                b'I',
                b'I',
                42,
                0,
                8,
                0,
                0,
                0,
                1,
                0,
                0x12,
                0x01,
                3,
                0,
                1,
                0,
                0,
                0,
                orientation,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            ];
            let mut bytes = vec![0xff, 0xd8, 0xff, 0xe1, 0, 34];
            bytes.extend(exif);
            bytes.extend(&jpeg[2..]);
            let path = dir.path().join(format!("{orientation}.jpg"));
            fs::write(&path, bytes).unwrap();
            let doc = ImageDocument::open(&path).unwrap();
            let base = ImageDocument::open(&{
                let p = dir.path().join("base.jpg");
                fs::write(&p, &jpeg).unwrap();
                p
            })
            .unwrap();
            let maps = [
                [0, 1, 2, 3, 4, 5],
                [2, 1, 0, 5, 4, 3],
                [5, 4, 3, 2, 1, 0],
                [3, 4, 5, 0, 1, 2],
                [0, 3, 1, 4, 2, 5],
                [3, 0, 4, 1, 5, 2],
                [5, 2, 4, 1, 3, 0],
                [2, 5, 1, 4, 0, 3],
            ];
            let expected: Vec<u8> = maps[orientation as usize - 1]
                .iter()
                .flat_map(|&i| base.pixels()[i * 4..i * 4 + 4].iter().copied())
                .collect();
            assert_eq!(doc.pixels(), expected);
            assert_eq!(
                (doc.width(), doc.height()),
                if orientation >= 5 { (2, 3) } else { (3, 2) }
            );
        }
    }
}
