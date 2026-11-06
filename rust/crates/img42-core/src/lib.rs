//! Portable raster editor. PNG, JPEG and BMP decode to straight RGBA8, applying
//! EXIF orientation when present. Snapshot exports support PNG, JPEG and BMP;
//! JPEG and BMP composite transparency over white. Metadata, colour profiles,
//! animation and high bit depth are not preserved.
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
    MultiframeRequiresGif,
    MultipageTiffUnsupported,
    MultiframeRequiresNavigation,
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O: {e}"),
            Self::Decode(e) => write!(f, "image: {e}"),
            Self::UnsupportedFormat => write!(f, "unsupported image format"),
            Self::TooLarge => write!(f, "image exceeds size limits"),
            Self::InvalidImage => write!(f, "invalid image dimensions or pixels"),
            Self::MultiframeRequiresNavigation => write!(
                f,
                "Animated image requires frame navigation; import its frames separately"
            ),
            Self::MultipageTiffUnsupported => write!(
                f,
                "Multi-page TIFF is not yet supported; the file was not opened"
            ),
            Self::MultiframeRequiresGif => write!(
                f,
                "Multi-frame images require GIF export; other formats would discard frames"
            ),
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
    dpi: Option<(u32, u32)>,
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
            dpi: None,
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
            dpi: if swap {
                self.dpi.map(|(x, y)| (y, x))
            } else {
                self.dpi
            },
        }
    }
}

#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub enum AnimationLoop {
    #[default]
    Once,
    Finite(u16),
    Infinite,
}
pub struct SaveState(Raster);

pub struct ImageDocument {
    icc: Option<Vec<u8>>,
    current: Raster,
    saved: Raster,
    undo: Vec<Raster>,
    redo: Vec<Raster>,
}
impl ImageDocument {
    pub fn from_rgba(
        width: u32,
        height: u32,
        pixels: Vec<u8>,
        dpi: Option<(u32, u32)>,
    ) -> Result<Self, Error> {
        if dpi.is_some_and(|(x, y)| !(1..=9600).contains(&x) || !(1..=9600).contains(&y)) {
            return Err(Error::InvalidImage);
        }
        let mut raster = Raster::new(width, height, pixels)?;
        raster.dpi = dpi;
        Ok(Self {
            icc: None,
            saved: raster.clone(),
            current: raster,
            undo: Vec::new(),
            redo: Vec::new(),
        })
    }
    pub fn dpi(&self) -> Option<(u32, u32)> {
        self.current.dpi
    }
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
        if format == ImageFormat::Tiff {
            let decoder = tiff::decoder::Decoder::new(Cursor::new(&bytes))
                .map_err(|_| Error::InvalidImage)?;
            if decoder.more_images() {
                return Err(Error::MultipageTiffUnsupported);
            }
        }
        if !matches!(
            format,
            ImageFormat::Png
                | ImageFormat::Jpeg
                | ImageFormat::Bmp
                | ImageFormat::Tiff
                | ImageFormat::Gif
                | ImageFormat::WebP
        ) {
            return Err(Error::UnsupportedFormat);
        }
        // Single-raster callers must never silently discard animation.
        if format == ImageFormat::Gif {
            use image::AnimationDecoder;
            let mut frames =
                image::codecs::gif::GifDecoder::new(Cursor::new(&bytes))?.into_frames();
            if let Some(frame) = frames.next() {
                frame?;
            }
            if let Some(frame) = frames.next() {
                frame?;
                return Err(Error::MultiframeRequiresNavigation);
            }
        }
        if format == ImageFormat::WebP
            && image::codecs::webp::WebPDecoder::new(Cursor::new(&bytes))?.has_animation()
        {
            return Err(Error::MultiframeRequiresNavigation);
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
        let mut decoder = reader.into_decoder()?;
        use image::ImageDecoder;
        let icc = decoder.icc_profile()?;
        let (w, h) = decoder.dimensions();
        if u64::from(w) * u64::from(h) > MAX_PIXELS {
            return Err(Error::TooLarge);
        }
        let image = image::DynamicImage::from_decoder(decoder)?.into_rgba8();
        let mut raster = Raster::new(w, h, image.into_raw())?.orient(orientation);
        raster.dpi = Self::source_dpi(path)?;
        Ok(Self {
            icc,
            saved: raster.clone(),
            current: raster,
            undo: Vec::new(),
            redo: Vec::new(),
        })
    }
    /// Read physical resolution where encoded; absent/invalid density remains unknown.
    pub fn source_dpi(path: &Path) -> Result<Option<(u32, u32)>, Error> {
        let file = File::open(path)?;
        if file.metadata()?.len() > MAX_FILE_BYTES {
            return Err(Error::TooLarge);
        }
        let mut bytes = Vec::new();
        file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
        let format = image::guess_format(&bytes).map_err(|_| Error::UnsupportedFormat)?;
        let mut dpi = None;
        let exif = exif::Reader::new()
            .read_from_container(&mut BufReader::new(Cursor::new(&bytes)))
            .ok();
        if let Some(ref exif) = exif {
            let rational = |tag| {
                exif.get_field(tag, exif::In::PRIMARY)
                    .and_then(|f| match &f.value {
                        exif::Value::Rational(v) => {
                            v.first().filter(|r| r.denom != 0).map(|r| r.to_f64())
                        }
                        _ => None,
                    })
            };
            if let (Some(x), Some(y)) = (
                rational(exif::Tag::XResolution),
                rational(exif::Tag::YResolution),
            ) {
                let unit = exif
                    .get_field(exif::Tag::ResolutionUnit, exif::In::PRIMARY)
                    .and_then(|f| f.value.get_uint(0));
                let factor = match unit {
                    Some(2) => 1.0,
                    Some(3) => 2.54,
                    _ => 0.0,
                };
                if factor > 0.0 {
                    dpi = Some(((x * factor).round() as u32, (y * factor).round() as u32));
                }
            }
        }
        if dpi.is_none() && format == ImageFormat::Png {
            let mut p = 8usize;
            while p + 12 <= bytes.len() {
                let n = u32::from_be_bytes(bytes[p..p + 4].try_into().unwrap()) as usize;
                let Some(end) = p.checked_add(12).and_then(|v| v.checked_add(n)) else {
                    break;
                };
                if end > bytes.len() {
                    break;
                }
                if &bytes[p + 4..p + 8] == b"pHYs" && n == 9 && bytes[p + 16] == 1 {
                    let x = u32::from_be_bytes(bytes[p + 8..p + 12].try_into().unwrap());
                    let y = u32::from_be_bytes(bytes[p + 12..p + 16].try_into().unwrap());
                    dpi = Some((
                        (x as f64 * 0.0254).round() as u32,
                        (y as f64 * 0.0254).round() as u32,
                    ));
                    break;
                }
                p = end;
            }
        }
        if dpi.is_none() && format == ImageFormat::Jpeg {
            if let Some(i) = bytes.windows(5).position(|v| v == b"JFIF\0") {
                if i + 12 <= bytes.len() {
                    let unit = bytes[i + 7];
                    let x = u16::from_be_bytes([bytes[i + 8], bytes[i + 9]]) as f64;
                    let y = u16::from_be_bytes([bytes[i + 10], bytes[i + 11]]) as f64;
                    let f = match unit {
                        1 => 1.0,
                        2 => 2.54,
                        _ => 0.0,
                    };
                    if f > 0.0 {
                        dpi = Some(((x * f).round() as u32, (y * f).round() as u32));
                    }
                }
            }
        }
        if exif
            .as_ref()
            .and_then(|e| e.get_field(exif::Tag::Orientation, exif::In::PRIMARY))
            .and_then(|f| f.value.get_uint(0))
            .is_some_and(|v| (5..=8).contains(&v))
        {
            dpi = dpi.map(|(x, y)| (y, x));
        }
        Ok(dpi.filter(|(x, y)| (1..=9600).contains(x) && (1..=9600).contains(y)))
    }
    pub fn source_page_dpi(path: &Path) -> Result<Vec<Option<(u32, u32)>>, Error> {
        let file = File::open(path)?;
        if file.metadata()?.len() > MAX_FILE_BYTES {
            return Err(Error::TooLarge);
        }
        let mut bytes = Vec::new();
        file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
        if image::guess_format(&bytes).map_err(|_| Error::UnsupportedFormat)? != ImageFormat::Tiff {
            return Ok(vec![Self::source_dpi(path)?]);
        }
        use tiff::{
            decoder::{ifd::Value, Decoder},
            tags::Tag,
        };
        let mut d = Decoder::new(Cursor::new(&bytes)).map_err(|_| Error::InvalidImage)?;
        let mut result = Vec::new();
        loop {
            let rational = |v| match v {
                Ok(Value::Rational(n, d)) if d > 0 => Some(n as f64 / d as f64),
                _ => None,
            };
            let x = rational(d.get_tag(Tag::XResolution));
            let y = rational(d.get_tag(Tag::YResolution));
            let unit = d.get_tag_unsigned::<u16>(Tag::ResolutionUnit).unwrap_or(1);
            let factor = match unit {
                2 => 1.0,
                3 => 2.54,
                _ => 0.0,
            };
            let mut dpi = x
                .zip(y)
                .filter(|_| factor > 0.0)
                .map(|(x, y)| ((x * factor).round() as u32, (y * factor).round() as u32))
                .filter(|(x, y)| (1..=9600).contains(x) && (1..=9600).contains(y));
            let orientation = d.get_tag_unsigned::<u16>(Tag::Orientation).unwrap_or(1);
            if (5..=8).contains(&orientation) {
                dpi = dpi.map(|(x, y)| (y, x));
            }
            result.push(dpi);
            if result.len() > 256 {
                return Err(Error::TooLarge);
            }
            if !d.more_images() {
                break;
            }
            d.next_image().map_err(|_| Error::InvalidImage)?;
        }
        Ok(result)
    }
    /// Detect source properties that the current 8-bit encoders cannot preserve.
    pub fn has_conversion_risk(path: &Path) -> Result<bool, Error> {
        use image::ImageDecoder;
        let file = File::open(path)?;
        if file.metadata()?.len() > MAX_FILE_BYTES {
            return Err(Error::TooLarge);
        }
        let mut bytes = Vec::new();
        file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
        let format = image::guess_format(&bytes).map_err(|_| Error::UnsupportedFormat)?;
        if format == ImageFormat::Tiff {
            let mut d = tiff::decoder::Decoder::new(Cursor::new(&bytes))
                .map_err(|_| Error::InvalidImage)?;
            loop {
                let color = d.colortype().map_err(|_| Error::InvalidImage)?;
                if color.bit_depth() > 8 {
                    return Ok(true);
                }
                use tiff::tags::Tag;
                if [
                    Tag::ImageDescription,
                    Tag::Artist,
                    Tag::DateTime,
                    Tag::Software,
                ]
                .iter()
                .any(|tag| d.get_tag(*tag).is_ok())
                {
                    return Ok(true);
                }
                if !d.more_images() {
                    break;
                }
                d.next_image().map_err(|_| Error::InvalidImage)?;
            }
        }
        if format == ImageFormat::Gif {
            use image::AnimationDecoder;
            let mut frames =
                image::codecs::gif::GifDecoder::new(Cursor::new(&bytes))?.into_frames();
            if let Some(frame) = frames.next() {
                frame?;
            }
            if let Some(frame) = frames.next() {
                frame?;
                return Ok(true);
            }
        }
        if format == ImageFormat::WebP
            && image::codecs::webp::WebPDecoder::new(Cursor::new(&bytes))?.has_animation()
        {
            return Ok(true);
        }
        let mut reader = ImageReader::with_format(Cursor::new(&bytes), format);
        let mut limits = Limits::default();
        limits.max_image_width = Some(MAX_DIMENSION);
        limits.max_image_height = Some(MAX_DIMENSION);
        limits.max_alloc = Some(MAX_PIXELS * 8);
        reader.limits(limits);
        let mut d = reader.into_decoder()?;
        if d.exif_metadata()?.is_some()
            || (!matches!(
                format,
                ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::Tiff
            ) && d.icc_profile()?.is_some())
        {
            return Ok(true);
        }
        Ok(false)
    }
    /// Decode all GIF or animated WebP frames with bounded aggregate memory.
    pub fn open_frames(path: &Path) -> Result<(Vec<Self>, Vec<image::Delay>), Error> {
        use image::AnimationDecoder;
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
        if format == ImageFormat::Tiff {
            use tiff::{
                decoder::{Decoder, DecodingResult},
                tags::Tag,
                ColorType,
            };
            let mut decoder = Decoder::new(Cursor::new(&bytes)).map_err(|_| Error::InvalidImage)?;
            let mut docs = Vec::new();
            let page_dpi = Self::source_page_dpi(path)?;
            let mut total = 0u64;
            loop {
                let (w, h) = decoder.dimensions().map_err(|_| Error::InvalidImage)?;
                if w == 0
                    || h == 0
                    || w > MAX_DIMENSION
                    || h > MAX_DIMENSION
                    || u64::from(w) * u64::from(h) > MAX_PIXELS
                {
                    return Err(Error::TooLarge);
                }
                total += u64::from(w) * u64::from(h) * 4;
                if total > MAX_PIXELS * 4 || docs.len() >= 256 {
                    return Err(Error::TooLarge);
                }
                let color = decoder.colortype().map_err(|_| Error::InvalidImage)?;
                let icc = decoder.get_tag_u8_vec(Tag::IccProfile).ok();
                let orientation = decoder
                    .get_tag_unsigned::<u16>(Tag::Orientation)
                    .unwrap_or(1);
                let samples = match decoder.read_image().map_err(|_| Error::InvalidImage)? {
                    DecodingResult::U8(v) => v,
                    DecodingResult::U16(v) => v.into_iter().map(|n| (n >> 8) as u8).collect(),
                    _ => return Err(Error::UnsupportedFormat),
                };
                let channels = match color {
                    ColorType::Gray(8 | 16) => 1,
                    ColorType::GrayA(8 | 16) => 2,
                    ColorType::RGB(8 | 16) => 3,
                    ColorType::RGBA(8 | 16) => 4,
                    _ => return Err(Error::UnsupportedFormat),
                };
                if samples.len() != w as usize * h as usize * channels {
                    return Err(Error::InvalidImage);
                }
                let mut rgba = Vec::with_capacity(w as usize * h as usize * 4);
                for p in samples.chunks_exact(channels) {
                    match channels {
                        1 => rgba.extend_from_slice(&[p[0], p[0], p[0], 255]),
                        2 => rgba.extend_from_slice(&[p[0], p[0], p[0], p[1]]),
                        3 => rgba.extend_from_slice(&[p[0], p[1], p[2], 255]),
                        _ => rgba.extend_from_slice(p),
                    }
                }
                let mut raster =
                    Raster::new(w, h, rgba)?.orient(if (1..=8).contains(&orientation) {
                        orientation
                    } else {
                        1
                    });
                raster.dpi = page_dpi.get(docs.len()).copied().flatten();
                docs.push(Self {
                    icc,
                    saved: raster.clone(),
                    current: raster,
                    undo: Vec::new(),
                    redo: Vec::new(),
                });
                if !decoder.more_images() {
                    break;
                }
                decoder.next_image().map_err(|_| Error::InvalidImage)?;
            }
            let delays = vec![image::Delay::from_numer_denom_ms(0, 1); docs.len()];
            return Ok((docs, delays));
        }
        let frames = match format {
            ImageFormat::Gif => {
                Some(image::codecs::gif::GifDecoder::new(Cursor::new(&bytes))?.into_frames())
            }
            ImageFormat::WebP => {
                let decoder = image::codecs::webp::WebPDecoder::new(Cursor::new(&bytes))?;
                if decoder.has_animation() {
                    Some(decoder.into_frames())
                } else {
                    None
                }
            }
            _ => None,
        };
        if let Some(frames) = frames {
            let mut docs = Vec::new();
            let mut delays = Vec::new();
            let mut total = 0u64;
            for frame in frames {
                let frame = frame?;
                let delay = frame.delay();
                let image = frame.into_buffer();
                let raster = Raster::new(image.width(), image.height(), image.into_raw())?;
                total += raster.pixels.len() as u64;
                if total > MAX_PIXELS * 4 || docs.len() >= 256 {
                    return Err(Error::TooLarge);
                }
                docs.push(Self {
                    icc: None,
                    saved: raster.clone(),
                    current: raster,
                    undo: Vec::new(),
                    redo: Vec::new(),
                });
                delays.push(delay);
            }
            if docs.is_empty() {
                return Err(Error::InvalidImage);
            }
            Ok((docs, delays))
        } else {
            Ok((
                vec![Self::open(path)?],
                vec![image::Delay::from_numer_denom_ms(0, 1)],
            ))
        }
    }
    /// Read animation playback count. GIF stores repetitions; WebP stores total plays.
    pub fn animation_loop(path: &Path) -> Result<AnimationLoop, Error> {
        let file = File::open(path)?;
        if file.metadata()?.len() > MAX_FILE_BYTES {
            return Err(Error::TooLarge);
        }
        let mut bytes = Vec::new();
        file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
        let format = image::guess_format(&bytes).map_err(|_| Error::UnsupportedFormat)?;
        match format {
            ImageFormat::Gif => {
                let mut decoder = gif::DecodeOptions::new()
                    .read_info(Cursor::new(&bytes))
                    .map_err(|_| Error::InvalidImage)?;
                while decoder
                    .read_next_frame()
                    .map_err(|_| Error::InvalidImage)?
                    .is_some()
                {}
                Ok(match decoder.repeat() {
                    gif::Repeat::Infinite => AnimationLoop::Infinite,
                    gif::Repeat::Finite(0) => AnimationLoop::Once,
                    gif::Repeat::Finite(n) => AnimationLoop::Finite(n),
                })
            }
            ImageFormat::WebP => {
                let decoder = image_webp::WebPDecoder::new(Cursor::new(&bytes))
                    .map_err(|_| Error::InvalidImage)?;
                Ok(match decoder.loop_count() {
                    image_webp::LoopCount::Forever => AnimationLoop::Infinite,
                    image_webp::LoopCount::Times(n) if n.get() == 1 => AnimationLoop::Once,
                    image_webp::LoopCount::Times(n) => AnimationLoop::Finite(n.get() - 1),
                })
            }
            _ => Ok(AnimationLoop::Once),
        }
    }
    /// Encode each page independently into a lossless RGBA TIFF.
    pub fn save_tiff_pages(pages: &[&Self]) -> Result<(Vec<u8>, Vec<SaveState>), Error> {
        if pages.is_empty() {
            return Err(Error::InvalidImage);
        }
        let mut output = Cursor::new(Vec::new());
        {
            let mut encoder =
                tiff::encoder::TiffEncoder::new(&mut output).map_err(|_| Error::InvalidImage)?;
            for page in pages {
                let r = &page.current;
                let mut image = encoder
                    .new_image::<tiff::encoder::colortype::RGBA8>(r.width, r.height)
                    .map_err(|_| Error::InvalidImage)?;
                if let Some((x, y)) = r.dpi {
                    use tiff::encoder::Rational;
                    image
                        .encoder()
                        .write_tag(tiff::tags::Tag::XResolution, Rational { n: x, d: 1 })
                        .map_err(|_| Error::InvalidImage)?;
                    image
                        .encoder()
                        .write_tag(tiff::tags::Tag::YResolution, Rational { n: y, d: 1 })
                        .map_err(|_| Error::InvalidImage)?;
                    image
                        .encoder()
                        .write_tag(tiff::tags::Tag::ResolutionUnit, 2u16)
                        .map_err(|_| Error::InvalidImage)?;
                }
                if let Some(icc) = &page.icc {
                    image
                        .encoder()
                        .write_tag(tiff::tags::Tag::IccProfile, icc.as_slice())
                        .map_err(|_| Error::InvalidImage)?;
                }
                image
                    .write_data(&r.pixels)
                    .map_err(|_| Error::InvalidImage)?;
            }
        }
        Ok((
            output.into_inner(),
            pages.iter().map(|p| SaveState(p.current.clone())).collect(),
        ))
    }
    /// Encode every composited frame; GIF may quantize colors and timing.
    pub fn save_gif_frames(
        frames: &[&Self],
        delays: &[image::Delay],
        repeat: AnimationLoop,
    ) -> Result<(Vec<u8>, Vec<SaveState>), Error> {
        if frames.is_empty() || frames.len() != delays.len() {
            return Err(Error::InvalidImage);
        }
        if frames
            .iter()
            .any(|d| d.width() != frames[0].width() || d.height() != frames[0].height())
        {
            return Err(Error::InvalidImage);
        }
        let mut bytes = Vec::new();
        {
            let mut encoder = image::codecs::gif::GifEncoder::new(&mut bytes);
            match repeat {
                AnimationLoop::Once => {}
                AnimationLoop::Finite(n) if n > 0 => {
                    encoder.set_repeat(image::codecs::gif::Repeat::Finite(n))?
                }
                AnimationLoop::Finite(_) => {}
                AnimationLoop::Infinite => {
                    encoder.set_repeat(image::codecs::gif::Repeat::Infinite)?
                }
            }
            for (doc, delay) in frames.iter().zip(delays) {
                let r = &doc.current;
                let image = image::RgbaImage::from_raw(r.width, r.height, r.pixels.to_vec())
                    .ok_or(Error::InvalidImage)?;
                encoder.encode_frame(image::Frame::from_parts(image, 0, 0, *delay))?;
            }
        }
        Ok((
            bytes,
            frames
                .iter()
                .map(|d| SaveState(d.current.clone()))
                .collect(),
        ))
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
        self.resize_quality(width, height, "nearest")
    }
    pub fn resize_quality(&mut self, width: u32, height: u32, quality: &str) -> Result<(), Error> {
        let filter = match quality {
            "nearest" => image::imageops::FilterType::Nearest,
            "linear" => image::imageops::FilterType::Triangle,
            "cubic" => image::imageops::FilterType::CatmullRom,
            "lanczos" => image::imageops::FilterType::Lanczos3,
            _ => return Err(Error::InvalidImage),
        };
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
        let pixels = image::imageops::resize(&image, width, height, filter).into_raw();
        let mut next = Raster::new(width, height, pixels)?;
        next.dpi = self.current.dpi;
        Self::push(&mut self.undo, self.current.clone());
        self.current = next;
        self.redo.clear();
        Ok(())
    }
    fn apply_raster(&mut self, mut next: Raster) {
        next.dpi = self.current.dpi;
        if next != self.current {
            Self::push(&mut self.undo, self.current.clone());
            self.current = next;
            self.redo.clear();
        }
    }
    /// Crop to a rectangle in image pixels. Reject out-of-bounds rectangles.
    pub fn crop(&mut self, x: u32, y: u32, width: u32, height: u32) -> Result<(), Error> {
        if width == 0
            || height == 0
            || x.checked_add(width).is_none_or(|v| v > self.width())
            || y.checked_add(height).is_none_or(|v| v > self.height())
        {
            return Err(Error::InvalidImage);
        }
        let mut pixels = Vec::with_capacity((width as usize) * (height as usize) * 4);
        for row in y..y + height {
            let start = ((row * self.width() + x) as usize) * 4;
            pixels.extend_from_slice(&self.pixels()[start..start + width as usize * 4]);
        }
        self.apply_raster(Raster::new(width, height, pixels)?);
        Ok(())
    }
    /// Apply brightness (-255..255), contrast (-100..100) and saturation (-100..100).
    pub fn adjust(&mut self, brightness: i32, contrast: i32, saturation: i32) -> Result<(), Error> {
        if !(-255..=255).contains(&brightness)
            || !(-100..=100).contains(&contrast)
            || !(-100..=100).contains(&saturation)
        {
            return Err(Error::InvalidImage);
        }
        let mut pixels = self.pixels().to_vec();
        let c = (100.0 + contrast as f32) / 100.0;
        let sat = (100.0 + saturation as f32) / 100.0;
        for p in pixels.chunks_exact_mut(4) {
            let gray = 0.2126 * p[0] as f32 + 0.7152 * p[1] as f32 + 0.0722 * p[2] as f32;
            for v in &mut p[..3] {
                let value = gray + (*v as f32 - gray) * sat;
                *v = ((value - 127.5) * c + 127.5 + brightness as f32)
                    .round()
                    .clamp(0.0, 255.0) as u8;
            }
        }
        self.apply_raster(Raster::new(self.width(), self.height(), pixels)?);
        Ok(())
    }
    /// Draw a freehand gesture as one undoable edit.
    /// Apply exposure (stops ×100), gamma (×100), temperature and tonal recovery.
    pub fn develop(
        &mut self,
        exposure: i32,
        gamma: i32,
        temperature: i32,
        shadows: i32,
        highlights: i32,
        sharpness: i32,
    ) -> Result<(), Error> {
        if !(-400..=400).contains(&exposure)
            || !(10..=400).contains(&gamma)
            || !(-100..=100).contains(&temperature)
            || !(-100..=100).contains(&shadows)
            || !(-100..=100).contains(&highlights)
            || !(0..=100).contains(&sharpness)
        {
            return Err(Error::InvalidImage);
        }
        let mut pixels = self.pixels().to_vec();
        let exposure = 2f32.powf(exposure as f32 / 100.0);
        let gamma = 100.0 / gamma as f32;
        for p in pixels.chunks_exact_mut(4) {
            let lum = (0.2126 * p[0] as f32 + 0.7152 * p[1] as f32 + 0.0722 * p[2] as f32) / 255.0;
            let shadow = shadows as f32 / 100.0 * (1.0 - lum).powi(2) * 0.35;
            let highlight = highlights as f32 / 100.0 * lum.powi(2) * 0.35;
            for (c, sample) in p[..3].iter_mut().enumerate() {
                let tint = match c {
                    0 => temperature as f32 / 500.0,
                    2 => -temperature as f32 / 500.0,
                    _ => 0.0,
                };
                let value = ((*sample as f32 / 255.0 * exposure)
                    .clamp(0.0, 1.0)
                    .powf(gamma)
                    + shadow
                    + highlight
                    + tint)
                    .clamp(0.0, 1.0);
                *sample = (value * 255.0).round() as u8;
            }
        }
        if sharpness > 0 {
            let image = image::RgbaImage::from_raw(self.width(), self.height(), pixels)
                .ok_or(Error::InvalidImage)?;
            let blurred = image::imageops::blur(&image, 1.0);
            let mut out = image.into_raw();
            for (p, b) in out
                .chunks_exact_mut(4)
                .zip(blurred.as_raw().chunks_exact(4))
            {
                for c in 0..3 {
                    p[c] = (p[c] as f32 + (p[c] as f32 - b[c] as f32) * sharpness as f32 / 50.0)
                        .round()
                        .clamp(0.0, 255.0) as u8;
                }
            }
            pixels = out;
        }
        self.apply_raster(Raster::new(self.width(), self.height(), pixels)?);
        Ok(())
    }
    pub fn erase_mask(&mut self, mask: &[bool]) -> Result<(), Error> {
        if mask.len() != (self.width() as usize) * (self.height() as usize) {
            return Err(Error::InvalidImage);
        }
        let mut pixels = self.pixels().to_vec();
        for (p, selected) in pixels.chunks_exact_mut(4).zip(mask) {
            if *selected {
                p.fill(0);
            }
        }
        self.apply_raster(Raster::new(self.width(), self.height(), pixels)?);
        Ok(())
    }
    pub fn masked_png(&self, mask: &[bool]) -> Result<Vec<u8>, Error> {
        use image::ImageEncoder;
        if mask.len() != (self.width() as usize) * (self.height() as usize) {
            return Err(Error::InvalidImage);
        }
        let mut pixels = self.pixels().to_vec();
        for (p, selected) in pixels.chunks_exact_mut(4).zip(mask) {
            if !*selected {
                p.fill(0);
            }
        }
        let mut out = Vec::new();
        image::codecs::png::PngEncoder::new(&mut out).write_image(
            &pixels,
            self.width(),
            self.height(),
            image::ExtendedColorType::Rgba8,
        )?;
        Ok(out)
    }
    /// Shape and rasterize text into image pixels using the bundled OFL Noto Sans font.
    pub fn draw_text(
        &mut self,
        x: u32,
        y: u32,
        size: u32,
        text: &str,
        color: [u8; 3],
    ) -> Result<(), Error> {
        use cosmic_text::{Attrs, Buffer, Color, Family, FontSystem, Metrics, Shaping, SwashCache};
        if x >= self.width()
            || y >= self.height()
            || !(4..=512).contains(&size)
            || text.is_empty()
            || text.len() > 4096
        {
            return Err(Error::InvalidImage);
        }
        let mut db = cosmic_text::fontdb::Database::new();
        db.load_font_data(
            include_bytes!("../../doc42-layout-probe/fixtures/NotoSans.ttf").to_vec(),
        );
        let mut fs = FontSystem::new_with_locale_and_db("en-US".into(), db);
        let mut buffer = Buffer::new(&mut fs, Metrics::new(size as f32, size as f32 * 1.3));
        buffer.set_size(
            &mut fs,
            Some((self.width() - x) as f32),
            Some((self.height() - y) as f32),
        );
        buffer.set_text(
            &mut fs,
            text,
            &Attrs::new().family(Family::Name("Noto Sans")),
            Shaping::Advanced,
        );
        buffer.shape_until_scroll(&mut fs, false);
        let mut pixels = self.pixels().to_vec();
        let mut cache = SwashCache::new();
        let mut missing = false;
        let width = self.width();
        let height = self.height();
        for run in buffer.layout_runs() {
            for glyph in run.glyphs {
                if glyph.glyph_id == 0 {
                    missing = true;
                    continue;
                }
                let p = glyph.physical((x as f32, 0.0), 1.0);
                cache.with_pixels(
                    &mut fs,
                    p.cache_key,
                    Color::rgb(color[0], color[1], color[2]),
                    |dx, dy, c| {
                        let px = p.x + dx;
                        let py = y as i32 + run.line_y as i32 + p.y + dy;
                        if px < 0 || py < 0 || px >= width as i32 || py >= height as i32 {
                            return;
                        }
                        let i = (py as usize * width as usize + px as usize) * 4;
                        let a = c.a() as u32;
                        let old_a = pixels[i + 3] as u32;
                        let out_a = a + (old_a * (255 - a) + 127) / 255;
                        if out_a > 0 {
                            for k in 0..3 {
                                pixels[i + k] = ((color[k] as u32 * a
                                    + pixels[i + k] as u32 * old_a * (255 - a) / 255
                                    + out_a / 2)
                                    / out_a)
                                    .min(255) as u8;
                            }
                            pixels[i + 3] = out_a as u8;
                        }
                    },
                );
            }
        }
        if missing {
            return Err(Error::UnsupportedFormat);
        }
        self.apply_raster(Raster::new(width, height, pixels)?);
        Ok(())
    }
    pub fn draw_stroke(
        &mut self,
        points: &[(u32, u32)],
        color: [u8; 4],
        width: u32,
    ) -> Result<(), Error> {
        if points.is_empty()
            || width == 0
            || width > 100
            || points
                .iter()
                .any(|&(x, y)| x >= self.width() || y >= self.height())
        {
            return Err(Error::InvalidImage);
        }
        let mut pixels = self.pixels().to_vec();
        let w = self.width() as i32;
        let h = self.height() as i32;
        let paint = |pixels: &mut [u8], x: i32, y: i32| {
            let left = (width as i32 - 1) / 2;
            let right = width as i32 / 2;
            for yy in (y - left).max(0)..=(y + right).min(h - 1) {
                for xx in (x - left).max(0)..=(x + right).min(w - 1) {
                    let i = ((yy * w + xx) * 4) as usize;
                    pixels[i..i + 4].copy_from_slice(&color);
                }
            }
        };
        paint(&mut pixels, points[0].0 as i32, points[0].1 as i32);
        for pair in points.windows(2) {
            let (mut x, mut y) = (pair[0].0 as i32, pair[0].1 as i32);
            let (tx, ty) = (pair[1].0 as i32, pair[1].1 as i32);
            let dx = (tx - x).abs();
            let sx = if x < tx { 1 } else { -1 };
            let dy = -(ty - y).abs();
            let sy = if y < ty { 1 } else { -1 };
            let mut err = dx + dy;
            loop {
                paint(&mut pixels, x, y);
                if x == tx && y == ty {
                    break;
                }
                let e = 2 * err;
                if e >= dy {
                    err += dy;
                    x += sx;
                }
                if e <= dx {
                    err += dx;
                    y += sy;
                }
            }
        }
        self.apply_raster(Raster::new(self.width(), self.height(), pixels)?);
        Ok(())
    }
    /// Paint a line on the raster, in image coordinates.
    pub fn draw_line(
        &mut self,
        x0: u32,
        y0: u32,
        x1: u32,
        y1: u32,
        color: [u8; 4],
    ) -> Result<(), Error> {
        if x0 >= self.width() || x1 >= self.width() || y0 >= self.height() || y1 >= self.height() {
            return Err(Error::InvalidImage);
        }
        let mut pixels = self.pixels().to_vec();
        let (mut x, mut y) = (x0 as i32, y0 as i32);
        let (tx, ty) = (x1 as i32, y1 as i32);
        let dx = (tx - x).abs();
        let sx = if x < tx { 1 } else { -1 };
        let dy = -(ty - y).abs();
        let sy = if y < ty { 1 } else { -1 };
        let mut err = dx + dy;
        loop {
            let i = ((y as u32 * self.width() + x as u32) * 4) as usize;
            pixels[i..i + 4].copy_from_slice(&color);
            if x == tx && y == ty {
                break;
            }
            let e = 2 * err;
            if e >= dy {
                err += dy;
                x += sx;
            }
            if e <= dx {
                err += dx;
                y += sy;
            }
        }
        self.apply_raster(Raster::new(self.width(), self.height(), pixels)?);
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
    pub fn save_snapshot(&self) -> Result<(Vec<u8>, SaveState), Error> {
        self.save_snapshot_format("png")
    }
    /// Encode a snapshot. JPEG composites transparency against white; metadata is not preserved.
    pub fn save_snapshot_format(&self, format: &str) -> Result<(Vec<u8>, SaveState), Error> {
        let state = self.current.clone();
        let mut bytes = Vec::new();
        if format == "jpeg" || format == "bmp" {
            use image::ImageEncoder;
            let mut rgb = Vec::with_capacity(state.pixels.len() / 4 * 3);
            for p in state.pixels.chunks_exact(4) {
                let a = u32::from(p[3]);
                for c in &p[..3] {
                    rgb.push(((u32::from(*c) * a + 255 * (255 - a) + 127) / 255) as u8);
                }
            }
            if format == "jpeg" {
                let mut encoder =
                    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 90);
                if let Some((x, y)) = state.dpi {
                    encoder.set_pixel_density(image::codecs::jpeg::PixelDensity {
                        density: (x as u16, y as u16),
                        unit: image::codecs::jpeg::PixelDensityUnit::Inches,
                    });
                }
                if let Some(icc) = &self.icc {
                    encoder
                        .set_icc_profile(icc.clone())
                        .map_err(|_| Error::UnsupportedFormat)?;
                }
                encoder.write_image(
                    &rgb,
                    state.width,
                    state.height,
                    image::ExtendedColorType::Rgb8,
                )?;
            } else {
                image::codecs::bmp::BmpEncoder::new(&mut bytes).write_image(
                    &rgb,
                    state.width,
                    state.height,
                    image::ExtendedColorType::Rgb8,
                )?;
            }
            return Ok((bytes, SaveState(state)));
        }
        if format == "tiff" {
            let (bytes, mut states) = Self::save_tiff_pages(&[self])?;
            return Ok((bytes, states.remove(0)));
        }
        if matches!(format, "gif" | "webp") {
            let image =
                image::RgbaImage::from_raw(state.width, state.height, state.pixels.to_vec())
                    .ok_or(Error::InvalidImage)?;
            let target = match format {
                "tiff" => ImageFormat::Tiff,
                "gif" => ImageFormat::Gif,
                _ => ImageFormat::WebP,
            };
            let mut output = Cursor::new(Vec::new());
            image::DynamicImage::ImageRgba8(image).write_to(&mut output, target)?;
            return Ok((output.into_inner(), SaveState(state)));
        }
        if format != "png" {
            return Err(Error::UnsupportedFormat);
        }
        use image::ImageEncoder;
        let mut encoder = image::codecs::png::PngEncoder::new(&mut bytes);
        if let Some(icc) = &self.icc {
            encoder
                .set_icc_profile(icc.clone())
                .map_err(|_| Error::UnsupportedFormat)?;
        }
        encoder.write_image(
            &state.pixels,
            state.width,
            state.height,
            image::ExtendedColorType::Rgba8,
        )?;
        if let Some((x, y)) = state.dpi {
            let mut data = Vec::with_capacity(9);
            data.extend_from_slice(&((x as f64 / 0.0254).round() as u32).to_be_bytes());
            data.extend_from_slice(&((y as f64 / 0.0254).round() as u32).to_be_bytes());
            data.push(1);
            let mut chunk = Vec::new();
            chunk.extend_from_slice(&9u32.to_be_bytes());
            chunk.extend_from_slice(b"pHYs");
            chunk.extend_from_slice(&data);
            let mut crc = crc32fast::Hasher::new();
            crc.update(b"pHYs");
            crc.update(&data);
            chunk.extend_from_slice(&crc.finalize().to_be_bytes());
            bytes.splice(33..33, chunk);
        }
        Ok((bytes, SaveState(state)))
    }
    pub fn mark_saved_snapshot(&mut self, state: SaveState) {
        self.saved = state.0;
    }
    pub fn save_as_png(&mut self, path: &Path) -> Result<(), Error> {
        let (bytes, state) = self.save_snapshot()?;
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        temp.write_all(&bytes)?;
        temp.flush()?;
        temp.as_file().sync_all()?;
        match temp.persist_noclobber(path) {
            Ok(_) => {
                self.mark_saved_snapshot(state);
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
            icc: None,
            current: r.clone(),
            saved: r,
            undo: vec![],
            redo: vec![],
        }
    }
    #[test]
    fn density_roundtrips_and_rotates_with_history() {
        let mut d = ImageDocument::from_rgba(3, 2, vec![255; 24], Some((300, 150))).unwrap();
        let dir = tempfile::tempdir().unwrap();
        for (fmt, ext) in [("png", "png"), ("jpeg", "jpg"), ("tiff", "tif")] {
            let (bytes, _) = d.save_snapshot_format(fmt).unwrap();
            let path = dir.path().join(ext);
            std::fs::write(&path, bytes).unwrap();
            assert_eq!(
                ImageDocument::source_dpi(&path).unwrap(),
                Some((300, 150)),
                "{fmt}"
            );
        }
        d.rotate_cw().unwrap();
        assert_eq!(d.dpi(), Some((150, 300)));
        d.undo();
        assert_eq!(d.dpi(), Some((300, 150)));
        d.redo();
        assert_eq!(d.dpi(), Some((150, 300)));
    }
    #[test]
    fn icc_and_mask_export_roundtrip() {
        let mut d = document();
        let original = d.pixels().to_vec();
        d.icc = Some(vec![1, 2, 3, 4]);
        let (png, _) = d.save_snapshot_format("png").unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("icc.png");
        std::fs::write(&path, png).unwrap();
        assert_eq!(
            ImageDocument::open(&path).unwrap().icc,
            Some(vec![1, 2, 3, 4])
        );
        let mask = vec![true, false, true, false, true, false];
        let png = d.masked_png(&mask).unwrap();
        let path = dir.path().join("mask.png");
        std::fs::write(&path, png).unwrap();
        let exported = ImageDocument::open(&path).unwrap();
        assert_eq!(exported.pixels()[7], 0);
        assert_eq!(exported.pixels()[3], original[3]);
        d.erase_mask(&mask).unwrap();
        assert_eq!(d.pixels()[3], 0);
        d.undo();
        assert_eq!(d.pixels(), original);
    }
    #[test]
    fn cyrillic_text_is_rendered_and_undoable() {
        let raster = Raster::new(180, 60, vec![255; 180 * 60 * 4]).unwrap();
        let mut d = ImageDocument {
            icc: None,
            current: raster.clone(),
            saved: raster,
            undo: vec![],
            redo: vec![],
        };
        d.draw_text(2, 2, 24, "Привет", [0, 0, 0]).unwrap();
        assert!(d.is_dirty());
        assert!(d.pixels().chunks_exact(4).any(|p| p[0] < 128));
        d.undo();
        assert!(!d.is_dirty());
        d.redo();
        assert!(d.is_dirty());
    }
    #[test]
    fn multipage_tiff_roundtrip_and_per_page_history() {
        let a = document();
        let mut b = document();
        b.rotate(6).unwrap();
        let (bytes, _) = ImageDocument::save_tiff_pages(&[&a, &b]).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pages.tif");
        std::fs::write(&path, bytes).unwrap();
        let (mut pages, _) = ImageDocument::open_frames(&path).unwrap();
        assert_eq!(pages.len(), 2);
        assert_eq!(pages[0].pixels(), a.pixels());
        assert_eq!(
            (pages[1].width(), pages[1].height()),
            (b.width(), b.height())
        );
        let before = pages[1].pixels().to_vec();
        pages[1].develop(50, 100, 0, 0, 0, 0).unwrap();
        assert!(pages[1].is_dirty());
        assert!(!pages[0].is_dirty());
        pages[1].undo();
        assert_eq!(pages[1].pixels(), before);
    }
    #[test]
    fn animated_gif_roundtrip_retains_frames_and_delays() {
        let mut a = document();
        let mut pixels = a.current.pixels.to_vec();
        for pixel in pixels.chunks_exact_mut(4) {
            pixel[3] = 255;
        }
        a.current = Raster::new(a.width(), a.height(), pixels).unwrap();
        let mut b = document();
        b.current = a.current.clone();
        b.rotate(3).unwrap();
        let delays = vec![
            image::Delay::from_numer_denom_ms(120, 1),
            image::Delay::from_numer_denom_ms(230, 1),
        ];
        let (bytes, _) =
            ImageDocument::save_gif_frames(&[&a, &b], &delays, AnimationLoop::Finite(3)).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("animation.gif");
        std::fs::write(&path, bytes).unwrap();
        let (frames, decoded_delays) = ImageDocument::open_frames(&path).unwrap();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].pixels(), a.pixels());
        assert_eq!(frames[1].pixels(), b.pixels());
        assert_eq!(decoded_delays, delays);
        assert_eq!(
            ImageDocument::animation_loop(&path).unwrap(),
            AnimationLoop::Finite(3)
        );
    }
    #[test]
    fn stroke_is_one_history_entry() {
        let mut d = document();
        let before = d.pixels().to_vec();
        d.draw_stroke(&[(0, 0), (1, 0), (2, 1)], [255, 0, 0, 255], 1)
            .unwrap();
        let after = d.pixels().to_vec();
        assert_ne!(before, after);
        assert!(d.undo());
        assert_eq!(d.pixels(), before);
        assert!(d.redo());
        assert_eq!(d.pixels(), after);
    }
    #[test]
    fn crop_adjust_markup_and_export_history() {
        let mut d = document();
        d.crop(1, 0, 2, 2).unwrap();
        assert_eq!(values(&d.current), vec![2, 3, 5, 6]);
        d.adjust(10, 0, 0).unwrap();
        d.draw_line(0, 0, 1, 1, [255, 0, 0, 255]).unwrap();
        let marked = d.pixels().to_vec();
        assert!(d.undo());
        assert!(d.undo());
        assert!(d.undo());
        assert_eq!(values(&d.current), vec![1, 2, 3, 4, 5, 6]);
        assert!(d.redo());
        assert!(d.redo());
        assert!(d.redo());
        assert_eq!(d.pixels(), marked);
        for format in ["png", "jpeg", "bmp", "tiff", "gif", "webp"] {
            let (bytes, _) = d.save_snapshot_format(format).unwrap();
            let decoded = image::load_from_memory(&bytes).unwrap();
            assert_eq!((decoded.width(), decoded.height()), (2, 2));
        }
    }
    #[test]
    fn published_snapshot_does_not_clean_a_later_edit() {
        let mut d = document();
        d.rotate_cw().unwrap();
        let (_, snapshot) = d.save_snapshot().unwrap();
        d.flip_horizontal().unwrap();
        d.mark_saved_snapshot(snapshot);
        assert!(d.is_dirty());
        assert!(d.undo());
        assert!(!d.is_dirty());
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
