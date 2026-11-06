use std::{ptr, slice};
use windows_sys::Win32::{
    Foundation::{GlobalFree, HWND},
    System::{DataExchange::*, Memory::*},
};
const CF_UNICODETEXT: u32 = 13;
struct Clipboard;
impl Drop for Clipboard {
    fn drop(&mut self) {
        unsafe {
            CloseClipboard();
        }
    }
}
unsafe fn open(owner: HWND) -> Result<Clipboard, String> {
    if OpenClipboard(owner) == 0 {
        Err("Unable to open clipboard".into())
    } else {
        Ok(Clipboard)
    }
}
pub unsafe fn write_text(owner: HWND, text: &str) -> Result<(), String> {
    if text.contains('\0') {
        return Err("Clipboard text contains NUL".into());
    }
    let encoded: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    let mem = GlobalAlloc(GMEM_MOVEABLE, encoded.len() * 2);
    if mem.is_null() {
        return Err("Clipboard allocation failed".into());
    }
    let data = GlobalLock(mem);
    if data.is_null() {
        GlobalFree(mem);
        return Err("Clipboard lock failed".into());
    }
    ptr::copy_nonoverlapping(encoded.as_ptr(), data as *mut u16, encoded.len());
    GlobalUnlock(mem);
    let _clipboard = match open(owner) {
        Ok(c) => c,
        Err(e) => {
            GlobalFree(mem);
            return Err(e);
        }
    };
    if EmptyClipboard() == 0 || SetClipboardData(CF_UNICODETEXT, mem).is_null() {
        GlobalFree(mem);
        return Err("Clipboard write failed".into());
    }
    Ok(())
}
pub unsafe fn read_text(owner: HWND) -> Result<String, String> {
    let _clipboard = open(owner)?;
    let mem = GetClipboardData(CF_UNICODETEXT);
    if mem.is_null() {
        return Err("Clipboard has no Unicode text".into());
    }
    let size = GlobalSize(mem);
    if size > 64 * 1024 * 1024 || size % 2 != 0 {
        return Err("Invalid clipboard text size".into());
    }
    let data = GlobalLock(mem);
    if data.is_null() {
        return Err("Clipboard lock failed".into());
    }
    let words = slice::from_raw_parts(data as *const u16, size / 2);
    let end = words.iter().position(|v| *v == 0);
    let result = end
        .ok_or("Clipboard text is not terminated".to_string())
        .and_then(|n| {
            String::from_utf16(&words[..n]).map_err(|_| "Invalid clipboard UTF-16".into())
        });
    GlobalUnlock(mem);
    result
}

pub unsafe fn write_data(owner: HWND, format: &str, bytes: &[u8]) -> Result<(), String> {
    if format.contains('\0') || bytes.is_empty() || bytes.len() > 64 * 1024 * 1024 {
        return Err("Invalid clipboard data".into());
    }
    let name = crate::wide(format);
    let id = RegisterClipboardFormatW(name.as_ptr());
    if id == 0 {
        return Err("Clipboard format registration failed".into());
    }
    let mem = GlobalAlloc(GMEM_MOVEABLE, bytes.len());
    if mem.is_null() {
        return Err("Clipboard allocation failed".into());
    }
    let data = GlobalLock(mem);
    if data.is_null() {
        GlobalFree(mem);
        return Err("Clipboard lock failed".into());
    }
    ptr::copy_nonoverlapping(bytes.as_ptr(), data as *mut u8, bytes.len());
    GlobalUnlock(mem);
    let _clipboard = match open(owner) {
        Ok(c) => c,
        Err(e) => {
            GlobalFree(mem);
            return Err(e);
        }
    };
    if EmptyClipboard() == 0 || SetClipboardData(id, mem).is_null() {
        GlobalFree(mem);
        return Err("Clipboard write failed".into());
    }
    Ok(())
}
pub unsafe fn read_data(owner: HWND, format: &str) -> Result<Vec<u8>, String> {
    if format.contains('\0') {
        return Err("Invalid clipboard format".into());
    }
    let name = crate::wide(format);
    let id = RegisterClipboardFormatW(name.as_ptr());
    if id == 0 {
        return Err("Clipboard format registration failed".into());
    }
    let _clipboard = open(owner)?;
    let mem = GetClipboardData(id);
    if mem.is_null() {
        return Err("Clipboard format is unavailable".into());
    }
    let size = GlobalSize(mem);
    if size == 0 || size > 64 * 1024 * 1024 {
        return Err("Invalid clipboard data size".into());
    }
    let data = GlobalLock(mem);
    if data.is_null() {
        return Err("Clipboard lock failed".into());
    }
    let result = slice::from_raw_parts(data as *const u8, size).to_vec();
    GlobalUnlock(mem);
    Ok(result)
}
