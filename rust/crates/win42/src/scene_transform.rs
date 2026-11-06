use std::cell::Cell;

use windows_sys::Win32::Graphics::Gdi::{
    ModifyWorldTransform, RestoreDC, SaveDC, SetGraphicsMode, GM_ADVANCED, HDC, MWT_RIGHTMULTIPLY,
    XFORM,
};

use crate::{Point, Viewport};

thread_local! { static DEPTH: Cell<usize> = const { Cell::new(0) }; }
struct SavedDc(HDC, i32);
impl Drop for SavedDc {
    fn drop(&mut self) {
        unsafe {
            RestoreDC(self.0, self.1);
        }
    }
}
struct DepthGuard;
impl Drop for DepthGuard {
    fn drop(&mut self) {
        DEPTH.with(|depth| depth.set(depth.get() - 1));
    }
}

/// Apply a clockwise scene-space rotation to everything drawn by `draw`.
/// Invalid transforms, excessive nesting and unsupported device contexts draw nothing.
pub(crate) unsafe fn with_rotation(
    dc: HDC,
    viewport: Viewport,
    center: Point,
    degrees: f64,
    draw: impl FnOnce(),
) {
    if !degrees.is_finite()
        || !center.x.is_finite()
        || !center.y.is_finite()
        || !viewport.zoom.is_finite()
        || viewport.zoom <= 0.0
        || !viewport.pan.x.is_finite()
        || !viewport.pan.y.is_finite()
        || DEPTH.with(|depth| depth.get() >= 16)
    {
        return;
    }
    let center = viewport.document_to_view(center);
    if !center.x.is_finite()
        || !center.y.is_finite()
        || center.x.abs() > 1.0e7
        || center.y.abs() > 1.0e7
    {
        return;
    }
    let (sin, cos) = degrees.rem_euclid(360.0).to_radians().sin_cos();
    let transform = XFORM {
        eM11: cos as f32,
        eM12: sin as f32,
        eM21: -sin as f32,
        eM22: cos as f32,
        eDx: (center.x - cos * center.x + sin * center.y) as f32,
        eDy: (center.y - sin * center.x - cos * center.y) as f32,
    };
    let saved = SaveDC(dc);
    if saved == 0 {
        return;
    }
    let _saved = SavedDc(dc, saved);
    if SetGraphicsMode(dc, GM_ADVANCED) != 0
        && ModifyWorldTransform(dc, &transform, MWT_RIGHTMULTIPLY) != 0
    {
        DEPTH.with(|depth| depth.set(depth.get() + 1));
        let _depth = DepthGuard;
        draw();
    }
}

/// Render a bounded white page in a memory DIB, then copy opaque pixels to a
/// printer without depending on printer-driver alpha blending support.
pub(crate) unsafe fn print_flattened(
    dc: HDC,
    width_points: i32,
    height_points: i32,
    dpi: i32,
    draw: impl FnOnce(HDC, f64),
) -> Result<(), String> {
    use std::{
        mem::{size_of, zeroed},
        ptr::null_mut,
    };
    use windows_sys::Win32::Graphics::Gdi::*;
    let dpi = dpi.clamp(72, 200);
    let width = (i64::from(width_points) * i64::from(dpi) / 72) as i32;
    let height = (i64::from(height_points) * i64::from(dpi) / 72) as i32;
    if width <= 0
        || height <= 0
        || width > 8192
        || height > 8192
        || i64::from(width) * i64::from(height) > 40_000_000
    {
        return Err("Print page exceeds raster size limit".into());
    }
    let mut bmi: BITMAPINFO = zeroed();
    bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = -height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    let memory = CreateCompatibleDC(dc);
    if memory.is_null() {
        return Err("Could not create print buffer".into());
    }
    let mut bits = null_mut();
    let bitmap = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
    if bitmap.is_null() || bits.is_null() {
        if !bitmap.is_null() {
            DeleteObject(bitmap as _);
        }
        DeleteDC(memory);
        return Err("Could not allocate print buffer".into());
    }
    std::ptr::write_bytes(bits.cast::<u8>(), 255, width as usize * height as usize * 4);
    let old = SelectObject(memory, bitmap as _);
    draw(memory, f64::from(dpi) / 72.0);
    SelectObject(memory, old);
    let result = StretchDIBits(
        dc,
        0,
        0,
        width_points,
        height_points,
        0,
        0,
        width,
        height,
        bits,
        &bmi,
        DIB_RGB_COLORS,
        SRCCOPY,
    );
    DeleteObject(bitmap as _);
    DeleteDC(memory);
    if result == 0 || result == GDI_ERROR as i32 {
        Err("Could not print rasterized page".into())
    } else {
        Ok(())
    }
}
