use crate::{wide, App};
use std::{
    cell::{Cell, RefCell},
    ffi::OsString,
    mem::{size_of, zeroed},
    os::windows::ffi::OsStringExt,
    path::PathBuf,
    ptr::{null, null_mut},
};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    System::LibraryLoader::{GetModuleHandleW, LoadLibraryW},
    UI::{
        Controls::{Dialogs::*, *},
        HiDpi::*,
        Input::KeyboardAndMouse::{
            EnableWindow, GetKeyState, ReleaseCapture, SetCapture, SetFocus, VK_SHIFT,
        },
        WindowsAndMessaging::*,
    },
};
const OPEN: u16 = 1;
const SAVE: u16 = 2;
const SAVE_AS: u16 = 18;
const EXIT: u16 = 3;
const UNDO: u16 = 4;
const REDO: u16 = 5;
const ABOUT: u16 = 6;
const FIND: u16 = 7;
const REPLACE: u16 = 8;
const NEW: u16 = 9;
const LIST: usize = 100;
const EDIT: usize = 101;
const TABLE: usize = 102;
const TOOLBAR_MORE: u16 = 65520;
struct State {
    app: Box<dyn App>,
    path: Option<PathBuf>,
    session: suite42_core::session::DocumentSession,
    hwnd: HWND,
    list: HWND,
    table: HWND,
    edit: HWND,
    canvas: HWND,
    status: HWND,
    menu: HMENU,
    grid_cache: Option<Vec<Vec<String>>>,
    toolbar: Vec<(u16, HWND)>,
    toolbar_more: HWND,
    ruler_horizontal: HWND,
    ruler_vertical: HWND,
    ruler_format: Option<(crate::PrintGeometry, u16, i32, i32, i32)>,
    fullscreen: Option<(isize, WINDOWPLACEMENT)>,
}
thread_local! { static STATE:RefCell<Option<State>>=const { RefCell::new(None) }; static REFRESHING:Cell<bool>=const {Cell::new(false)}; static DRAGGING:Cell<bool>=const {Cell::new(false)}; }

unsafe fn msg(hwnd: HWND, s: &str, flags: MESSAGEBOX_STYLE) -> MESSAGEBOX_RESULT {
    MessageBoxW(hwnd, wide(s).as_ptr(), wide("Suite42").as_ptr(), flags)
}
unsafe fn dialog(
    hwnd: HWND,
    save: bool,
    ext: &str,
    format: &str,
    pattern: &str,
) -> Option<PathBuf> {
    let mut buf = vec![0u16; 32768];
    let filter: Vec<u16> = format!("{format}\0{pattern}\0\0").encode_utf16().collect();
    let extw = wide(ext);
    let mut f: OPENFILENAMEW = zeroed();
    f.lStructSize = size_of::<OPENFILENAMEW>() as u32;
    f.hwndOwner = hwnd;
    f.lpstrFilter = filter.as_ptr();
    f.lpstrFile = buf.as_mut_ptr();
    f.nMaxFile = buf.len() as u32;
    f.lpstrDefExt = extw.as_ptr();
    f.Flags = OFN_EXPLORER
        | OFN_NOCHANGEDIR
        | OFN_PATHMUSTEXIST
        | if save { 0 } else { OFN_FILEMUSTEXIST };
    if (if save {
        GetSaveFileNameW(&mut f)
    } else {
        GetOpenFileNameW(&mut f)
    }) == 0
    {
        return None;
    }
    let n = buf.iter().position(|&x| x == 0).unwrap_or(buf.len());
    Some(PathBuf::from(OsString::from_wide(&buf[..n])))
}
unsafe fn format_dialog(
    hwnd: HWND,
    formats: &[crate::FileFormat],
    save: bool,
) -> Option<(PathBuf, usize)> {
    let mut buf = vec![0u16; 32768];
    let mut filter = Vec::new();
    for format in formats {
        let pattern = format
            .extensions
            .iter()
            .map(|e| format!("*.{e}"))
            .collect::<Vec<_>>()
            .join(";");
        filter.extend(format.title.encode_utf16());
        filter.push(0);
        filter.extend(pattern.encode_utf16());
        filter.push(0);
    }
    filter.push(0);
    let mut f: OPENFILENAMEW = zeroed();
    f.lStructSize = size_of::<OPENFILENAMEW>() as u32;
    f.hwndOwner = hwnd;
    f.lpstrFilter = filter.as_ptr();
    f.nFilterIndex = 1;
    f.lpstrFile = buf.as_mut_ptr();
    f.nMaxFile = buf.len() as u32;
    f.Flags = OFN_EXPLORER
        | OFN_NOCHANGEDIR
        | OFN_PATHMUSTEXIST
        | if save { 0 } else { OFN_FILEMUSTEXIST };
    if (if save {
        GetSaveFileNameW(&mut f)
    } else {
        GetOpenFileNameW(&mut f)
    }) == 0
    {
        return None;
    }
    let index = (f.nFilterIndex as usize)
        .saturating_sub(1)
        .min(formats.len() - 1);
    let n = buf.iter().position(|&x| x == 0).unwrap_or(buf.len());
    let mut path = PathBuf::from(OsString::from_wide(&buf[..n]));
    if save && path.extension().is_none() {
        if let Some(ext) = formats[index].extensions.first() {
            path.set_extension(ext);
        }
    }
    Some((path, index))
}
unsafe fn save(hwnd: HWND) -> bool {
    save_mode(hwnd, false)
}
unsafe fn save_mode(hwnd: HWND, save_as: bool) -> bool {
    let opt_in = STATE.with(|s| !s.borrow().as_ref().unwrap().app.save_formats().is_empty());
    if opt_in {
        return save_snapshot(hwnd, save_as);
    }
    legacy_save(hwnd)
}
unsafe fn save_snapshot(hwnd: HWND, save_as: bool) -> bool {
    use suite42_core::session::{publish, FileIdentity};
    let (formats, existing) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (s.app.save_formats(), s.session.location().cloned())
    });
    if formats.is_empty() {
        return false;
    }
    let can_save_in_place = STATE.with(|s| s.borrow().as_ref().unwrap().app.can_save_in_place());
    let selected = if !save_as && can_save_in_place {
        existing
            .as_ref()
            .and_then(|l| formats.iter().position(|f| f.id == l.format))
    } else {
        None
    };
    let (path, index) = if let (Some(location), Some(index)) = (&existing, selected) {
        (location.path.clone(), index)
    } else {
        match format_dialog(hwnd, &formats, true) {
            Some(v) => v,
            None => return false,
        }
    };
    let format = &formats[index];
    if !path
        .extension()
        .and_then(|v| v.to_str())
        .is_some_and(|e| format.extensions.iter().any(|v| e.eq_ignore_ascii_case(v)))
    {
        msg(
            hwnd,
            "The file extension does not match the selected format.",
            MB_OK | MB_ICONWARNING,
        );
        return false;
    }
    let is_current = existing.as_ref().is_some_and(|l| l.path == path);
    let expected = if is_current {
        existing.as_ref().map(|l| l.identity.clone())
    } else {
        None
    };
    let expected = if path.exists() {
        let actual = match FileIdentity::read(&path) {
            Ok(i) => i,
            Err(e) => {
                msg(hwnd, &e.to_string(), MB_OK | MB_ICONERROR);
                return false;
            }
        };
        if expected.as_ref() != Some(&actual) {
            if msg(
                hwnd,
                "This file exists or has changed since it was opened. Replace it?",
                MB_YESNO | MB_ICONWARNING,
            ) != IDYES
            {
                return false;
            }
            Some(actual)
        } else {
            expected
        }
    } else if expected.is_some() {
        if msg(
            hwnd,
            "The original file was removed. Recreate it?",
            MB_YESNO | MB_ICONWARNING,
        ) != IDYES
        {
            return false;
        }
        None
    } else {
        None
    };
    let snapshot = STATE.with(|s| {
        s.borrow_mut()
            .as_mut()
            .unwrap()
            .app
            .save_snapshot_to(format.id, &path, is_current)
    });
    let (revision, bytes) = match snapshot {
        Ok(Some(v)) => v,
        Ok(None) => {
            msg(
                hwnd,
                "This document cannot be saved in that format.",
                MB_OK | MB_ICONERROR,
            );
            return false;
        }
        Err(e) => {
            msg(hwnd, &e, MB_OK | MB_ICONERROR);
            return false;
        }
    };
    if let Err(e) = publish(&path, &bytes, expected.as_ref()) {
        msg(hwnd, &e.to_string(), MB_OK | MB_ICONERROR);
        return false;
    }
    let result = STATE.with(|s| {
        let mut s = s.borrow_mut();
        let s = s.as_mut().unwrap();
        let result = s
            .session
            .published(path.clone(), format.id.into(), revision);
        if result.is_ok() {
            s.app.saved_snapshot(revision);
            s.path = Some(path);
        }
        result
    });
    if let Err(e) = result {
        msg(hwnd, &e.to_string(), MB_OK | MB_ICONERROR);
        return false;
    }
    true
}
unsafe fn legacy_save(hwnd: HWND) -> bool {
    let (ext, fmt) = STATE.with(|s| {
        let s = s.borrow();
        let a = &s.as_ref().unwrap().app;
        (a.extension(), a.format_name())
    });
    loop {
        let Some(p) = dialog(hwnd, true, ext, fmt, &format!("*.{ext}")) else {
            return false;
        };
        if p.extension()
            .and_then(|x| x.to_str())
            .is_none_or(|x| !x.eq_ignore_ascii_case(ext))
        {
            msg(
                hwnd,
                &format!("Choose a .{ext} file name."),
                MB_OK | MB_ICONWARNING,
            );
            continue;
        }
        if p.exists() {
            msg(
                hwnd,
                "Choose a new file name; existing files cannot be overwritten.",
                MB_OK | MB_ICONWARNING,
            );
            continue;
        }
        let r = STATE.with(|s| {
            let mut s = s.borrow_mut();
            let s = s.as_mut().unwrap();
            let r = s.app.save(&p);
            if r.is_ok() {
                s.path = Some(p)
            }
            r
        });
        match r {
            Ok(()) => return true,
            Err(e) => {
                msg(hwnd, &e, MB_OK | MB_ICONERROR);
                return false;
            }
        }
    }
}
unsafe fn confirm(hwnd: HWND) -> bool {
    if !STATE.with(|s| s.borrow().as_ref().unwrap().app.dirty()) {
        return true;
    }
    match msg(
        hwnd,
        "Save changes before continuing?",
        MB_YESNOCANCEL | MB_ICONWARNING,
    ) {
        IDYES => save(hwnd),
        IDNO => true,
        _ => false,
    }
}
unsafe fn refresh() {
    let (
        hwnd,
        list,
        table,
        edit,
        canvas,
        status,
        menu,
        title,
        items,
        text,
        info,
        undo,
        redo,
        visible,
        readonly,
        image,
        grid,
    ) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (
            s.hwnd,
            s.list,
            s.table,
            s.edit,
            s.canvas,
            s.status,
            s.menu,
            format!(
                "{}{} - {}",
                s.path
                    .as_ref()
                    .and_then(|p| p.file_name())
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "Untitled".into()),
                if s.app.dirty() { " *" } else { "" },
                s.app.name()
            ),
            s.app
                .grid_sheets()
                .map(|v| v.0)
                .unwrap_or_else(|| s.app.items()),
            s.app.text(),
            s.app.status(),
            s.app.can_undo(),
            s.app.can_redo(),
            s.app.list_visible(),
            s.app.text_readonly(),
            s.app.image().is_some() || s.app.canvas_scene().is_some(),
            s.app.table(),
        )
    });
    REFRESHING.with(|x| x.set(true));
    SetWindowTextW(hwnd, wide(&title).as_ptr());
    SetWindowTextW(status, wide(&info).as_ptr());
    let rich = STATE.with(|s| s.borrow().as_ref().unwrap().app.rich_text());
    if let Some(rtf) = rich {
        let selection = crate::rich_edit::selection(edit);
        let _ = crate::rich_edit::load(edit, &rtf);
        crate::rich_edit::set_selection(edit, selection);
    } else {
        SetWindowTextW(edit, wide(&text).as_ptr());
    }
    SendMessageW(edit, EM_SETREADONLY, readonly as usize, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    for item in items {
        SendMessageW(list, LB_ADDSTRING, 0, wide(&item).as_ptr() as isize);
    }
    let (selected, actions, can_save) = STATE.with(|s| {
        let s = s.borrow();
        let a = &s.as_ref().unwrap().app;
        (
            a.grid_sheets().map(|v| v.1).unwrap_or_else(|| a.selected()),
            a.actions()
                .iter()
                .chain(a.view_actions().iter())
                .map(|&(id, _)| (id, a.command_state(id)))
                .chain(
                    a.command_specs()
                        .into_iter()
                        .map(|c| (c.id, a.command_state(c.id))),
                )
                .collect::<Vec<_>>(),
            a.can_save(),
        )
    });
    let file_enabled = STATE.with(|s| {
        let s = s.borrow();
        let a = &s.as_ref().unwrap().app;
        a.file_actions()
            .iter()
            .map(|f| (f.id, a.enabled(f.id)))
            .collect::<Vec<_>>()
    });
    for (id, enabled) in file_enabled {
        EnableMenuItem(
            menu,
            id as u32,
            MF_BYCOMMAND | if enabled { MF_ENABLED } else { MF_GRAYED },
        );
    }
    EnableMenuItem(
        menu,
        SAVE as u32,
        MF_BYCOMMAND | if can_save { MF_ENABLED } else { MF_GRAYED },
    );
    SendMessageW(list, LB_SETCURSEL, selected, 0);
    for (id, state) in actions {
        STATE.with(|s| {
            if let Some((_, button)) = s
                .borrow()
                .as_ref()
                .unwrap()
                .toolbar
                .iter()
                .find(|(key, _)| *key == id)
            {
                EnableWindow(*button, state.enabled as i32);
            }
        });
        EnableMenuItem(
            menu,
            id as u32,
            MF_BYCOMMAND | if state.enabled { MF_ENABLED } else { MF_GRAYED },
        );
        CheckMenuItem(
            menu,
            id as u32,
            MF_BYCOMMAND
                | if state.checked {
                    MF_CHECKED
                } else {
                    MF_UNCHECKED
                },
        );
    }
    update_table(table, grid.as_deref());
    ShowWindow(table, if grid.is_some() { SW_SHOW } else { SW_HIDE });
    ShowWindow(
        list,
        if visible
            && (grid.is_none()
                || STATE.with(|s| s.borrow().as_ref().unwrap().app.grid_sheets().is_some()))
        {
            SW_SHOW
        } else {
            SW_HIDE
        },
    );
    ShowWindow(edit, if image { SW_HIDE } else { SW_SHOW });
    ShowWindow(canvas, if image { SW_SHOW } else { SW_HIDE });
    InvalidateRect(canvas, null(), 1);
    EnableMenuItem(
        menu,
        UNDO as u32,
        MF_BYCOMMAND | if undo { MF_ENABLED } else { MF_GRAYED },
    );
    EnableMenuItem(
        menu,
        REDO as u32,
        MF_BYCOMMAND | if redo { MF_ENABLED } else { MF_GRAYED },
    );
    REFRESHING.with(|x| x.set(false));
    sync_presentation(hwnd);
    DrawMenuBar(hwnd);
    layout(hwnd);
}
unsafe fn sync_presentation(hwnd: HWND) {
    let (presenting, active) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (s.app.presentation_size().is_some(), s.fullscreen.is_some())
    });
    if presenting && !active {
        let mut placement: WINDOWPLACEMENT = zeroed();
        placement.length = size_of::<WINDOWPLACEMENT>() as u32;
        if GetWindowPlacement(hwnd, &mut placement) == 0 {
            return;
        }
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        let mut info: MONITORINFO = zeroed();
        info.cbSize = size_of::<MONITORINFO>() as u32;
        if GetMonitorInfoW(monitor, &mut info) == 0 {
            return;
        }
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        STATE.with(|s| s.borrow_mut().as_mut().unwrap().fullscreen = Some((style, placement)));
        SetMenu(hwnd, null_mut());
        SetWindowLongPtrW(hwnd, GWL_STYLE, (WS_POPUP | WS_VISIBLE) as isize);
        SetWindowPos(
            hwnd,
            HWND_TOP,
            info.rcMonitor.left,
            info.rcMonitor.top,
            info.rcMonitor.right - info.rcMonitor.left,
            info.rcMonitor.bottom - info.rcMonitor.top,
            SWP_FRAMECHANGED | SWP_SHOWWINDOW,
        );
    } else if !presenting && active {
        let (style, placement, menu) = STATE.with(|s| {
            let mut s = s.borrow_mut();
            let s = s.as_mut().unwrap();
            let (style, placement) = s.fullscreen.take().unwrap();
            (style, placement, s.menu)
        });
        SetWindowLongPtrW(hwnd, GWL_STYLE, style);
        SetMenu(hwnd, menu);
        SetWindowPlacement(hwnd, &placement);
        SetWindowPos(
            hwnd,
            null_mut(),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED,
        );
    }
}
unsafe fn scene_for_canvas(
    hwnd: HWND,
    mut scene: crate::CanvasScene,
    size: Option<(f64, f64)>,
) -> crate::CanvasScene {
    if let Some((width, height)) = size {
        if width > 0.0 && height > 0.0 {
            let mut r: RECT = zeroed();
            GetClientRect(hwnd, &mut r);
            let zoom = (r.right as f64 / width).min(r.bottom as f64 / height);
            if zoom.is_finite() && zoom > 0.0 {
                scene.viewport = crate::Viewport {
                    zoom,
                    pan: crate::Point {
                        x: (r.right as f64 - width * zoom) / 2.0,
                        y: (r.bottom as f64 - height * zoom) / 2.0,
                    },
                };
            }
        }
    }
    scene
}
unsafe fn layout(hwnd: HWND) {
    let (
        list,
        table,
        edit,
        canvas,
        status,
        visible,
        grid,
        toolbar,
        toolbar_more,
        ruler_horizontal,
        ruler_vertical,
        has_ruler,
    ) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (
            s.list,
            s.table,
            s.edit,
            s.canvas,
            s.status,
            s.app.list_visible(),
            s.grid_cache.is_some(),
            s.toolbar.clone(),
            s.toolbar_more,
            s.ruler_horizontal,
            s.ruler_vertical,
            s.app.rich_ruler().is_some()
                && s.app.canvas_scene().is_none()
                && s.app.image().is_none(),
        )
    });
    let mut r: RECT = zeroed();
    GetClientRect(hwnd, &mut r);
    let presenting = STATE.with(|s| {
        s.borrow()
            .as_ref()
            .unwrap()
            .app
            .presentation_size()
            .is_some()
    });
    if presenting {
        for control in [list, table, edit, status] {
            ShowWindow(control, SW_HIDE);
        }
        for (_, button) in &toolbar {
            ShowWindow(*button, SW_HIDE);
        }
        ShowWindow(toolbar_more, SW_HIDE);
        if !ruler_horizontal.is_null() {
            ShowWindow(ruler_horizontal, SW_HIDE);
            ShowWindow(ruler_vertical, SW_HIDE);
        }
        ShowWindow(canvas, SW_SHOW);
        MoveWindow(canvas, 0, 0, r.right.max(0), r.bottom.max(0), 1);
        SetFocus(canvas);
        return;
    }
    ShowWindow(status, SW_SHOW);
    let dpi = GetDpiForWindow(hwnd) as i32;
    let sh = 24 * dpi / 96;
    let row_height = (32 * dpi / 96).max(1);
    let button_width = (105 * dpi / 96).max(1);
    let columns = (r.right.max(1) / button_width).max(1) as usize;
    let max_rows =
        ((r.bottom - sh - (80 * dpi / 96)).max(row_height) / row_height).clamp(1, 3) as usize;
    let capacity = columns.saturating_mul(max_rows);
    let overflow = toolbar.len() > capacity;
    let visible_count = if overflow {
        capacity.saturating_sub(1)
    } else {
        toolbar.len()
    };
    let occupied = visible_count + usize::from(overflow);
    let rows = if occupied == 0 {
        0
    } else {
        occupied.div_ceil(columns)
    };
    let bar_height = rows as i32 * row_height;
    for (index, (_, button)) in toolbar.iter().enumerate() {
        if index < visible_count {
            let row = index / columns;
            let col = index % columns;
            MoveWindow(
                *button,
                col as i32 * button_width,
                row as i32 * row_height,
                button_width.min((r.right - col as i32 * button_width).max(1)),
                row_height,
                1,
            );
            ShowWindow(*button, SW_SHOW);
        } else {
            ShowWindow(*button, SW_HIDE);
        }
    }
    if overflow {
        let index = visible_count;
        MoveWindow(
            toolbar_more,
            (index % columns) as i32 * button_width,
            (index / columns) as i32 * row_height,
            button_width.min((r.right - (index % columns) as i32 * button_width).max(1)),
            row_height,
            1,
        );
        ShowWindow(toolbar_more, SW_SHOW);
    } else {
        ShowWindow(toolbar_more, SW_HIDE);
    }
    if grid {
        if !ruler_horizontal.is_null() {
            ShowWindow(ruler_horizontal, SW_HIDE);
            ShowWindow(ruler_vertical, SW_HIDE);
        }
        let height = (r.bottom - sh - bar_height).max(0);
        let top = height * 3 / 4;
        let sheet_width =
            if STATE.with(|s| s.borrow().as_ref().unwrap().app.grid_sheets().is_some()) {
                (180 * dpi / 96).min(r.right / 3)
            } else {
                0
            };
        MoveWindow(list, 0, bar_height, sheet_width, height, 1);
        MoveWindow(
            table,
            sheet_width,
            bar_height,
            r.right - sheet_width,
            top,
            1,
        );
        MoveWindow(
            edit,
            sheet_width,
            bar_height + top,
            r.right - sheet_width,
            height - top,
            1,
        );
        MoveWindow(status, 0, r.bottom - sh, r.right, sh, 1);
        return;
    }
    let left = if visible {
        (240 * dpi / 96).min(r.right / 2)
    } else {
        0
    };
    MoveWindow(
        list,
        0,
        bar_height,
        left,
        (r.bottom - sh - bar_height).max(0),
        1,
    );
    let rw = if has_ruler {
        (26 * dpi / 96).max(16)
    } else {
        0
    };
    let rh = if has_ruler {
        (28 * dpi / 96).max(16)
    } else {
        0
    };
    if !ruler_horizontal.is_null() {
        ShowWindow(ruler_horizontal, if has_ruler { SW_SHOW } else { SW_HIDE });
        ShowWindow(ruler_vertical, if has_ruler { SW_SHOW } else { SW_HIDE });
        if has_ruler {
            MoveWindow(
                ruler_horizontal,
                left + rw,
                bar_height,
                (r.right - left - rw).max(0),
                rh,
                1,
            );
            MoveWindow(
                ruler_vertical,
                left,
                bar_height + rh,
                rw,
                (r.bottom - sh - bar_height - rh).max(0),
                1,
            );
        }
    }
    MoveWindow(
        edit,
        left + rw,
        bar_height + rh,
        (r.right - left - rw).max(0),
        (r.bottom - sh - bar_height - rh).max(0),
        1,
    );
    MoveWindow(
        canvas,
        left,
        bar_height,
        (r.right - left).max(0),
        (r.bottom - sh - bar_height).max(0),
        1,
    );
    MoveWindow(status, 0, (r.bottom - sh).max(0), r.right, sh, 1);
    if has_ruler {
        sync_rulers(hwnd);
    }
}
/// Synchronize the document page rectangle with the edit control and both rulers.
unsafe fn sync_rulers(_hwnd: HWND) {
    let (edit, horizontal, vertical) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (s.edit, s.ruler_horizontal, s.ruler_vertical)
    });
    if edit.is_null() || horizontal.is_null() {
        return;
    }
    let selection = crate::rich_edit::selection(edit);
    let ruler = STATE.with(|s| {
        let mut s = s.borrow_mut();
        let app = &mut s.as_mut().unwrap().app;
        app.set_rich_selection(selection);
        app.rich_ruler()
    });
    let Some(data) = ruler else { return };
    if !data.page.valid() || data.zoom_percent == 0 {
        return;
    }
    let mut rect: RECT = zeroed();
    GetClientRect(edit, &mut rect);
    let dpi = (GetDpiForWindow(edit) as i32).max(1);
    let px = |v: i32| {
        ((i64::from(v) * i64::from(dpi) * i64::from(data.zoom_percent)) / 144_000)
            .clamp(0, i64::from(i32::MAX)) as i32
    };
    let page_width = px(data.page.width_twips);
    let page_left = ((rect.right - page_width) / 2).max(0);
    let key = (data.page, data.zoom_percent, rect.right, rect.bottom, dpi);
    let changed = STATE.with(|s| {
        let mut s = s.borrow_mut();
        let s = s.as_mut().unwrap();
        if s.ruler_format == Some(key) {
            false
        } else {
            s.ruler_format = Some(key);
            true
        }
    });
    if changed {
        let mut a = u32::from(data.zoom_percent);
        let mut b = 100u32;
        let (mut x, mut y) = (a, b);
        while y != 0 {
            let t = x % y;
            x = y;
            y = t
        }
        a /= x;
        b /= x;
        SendMessageW(edit, WM_USER + 225, a as usize, b as isize);
        let left = page_left.saturating_add(px(data.page.margin_left_twips));
        let right = page_left
            .saturating_add(page_width)
            .saturating_sub(px(data.page.margin_right_twips))
            .max(left.saturating_add(1));
        let top = px(data.page.margin_top_twips);
        let bottom = rect
            .bottom
            .saturating_sub(px(data.page.margin_bottom_twips))
            .max(top.saturating_add(1));
        let format = RECT {
            left,
            top,
            right,
            bottom,
        };
        SendMessageW(edit, EM_SETRECT, 0, &format as *const _ as isize);
    }
    let mut scroll: POINT = zeroed();
    SendMessageW(edit, WM_USER + 221, 0, &mut scroll as *mut _ as isize);
    crate::rich_ruler::update(horizontal, data.clone(), page_left - scroll.x);
    crate::rich_ruler::update(vertical, data, -scroll.y);
}
unsafe fn open_document_path(path: PathBuf) -> Result<(), String> {
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        let s = s.as_mut().unwrap();
        let result = s.app.open(&path);
        if result.is_ok() && !s.app.open_is_add() {
            s.session = Default::default();
            let formats = s.app.save_formats();
            let extension = path.extension().and_then(|v| v.to_str());
            if let Some(format) = formats.iter().find(|f| {
                extension.is_some_and(|e| f.extensions.iter().any(|v| e.eq_ignore_ascii_case(v)))
            }) {
                if let Ok(Some((revision, _))) = s.app.save_snapshot(format.id) {
                    if let Ok(session) = suite42_core::session::DocumentSession::opened(
                        path.clone(),
                        format.id.into(),
                        revision,
                    ) {
                        s.session = session;
                    }
                }
            }
            s.path = Some(path);
        }
        result
    })
}
unsafe fn command(hwnd: HWND, id: u16, notify: u16) {
    if id == TOOLBAR_MORE {
        let (button, items) = STATE.with(|s| {
            let s = s.borrow();
            let s = s.as_ref().unwrap();
            let specs = s.app.command_specs();
            let items = s
                .toolbar
                .iter()
                .filter(|(_, h)| IsWindowVisible(*h) == 0)
                .filter_map(|(id, _)| {
                    specs
                        .iter()
                        .find(|spec| spec.id == *id)
                        .map(|spec| (*id, spec.title, s.app.command_state(*id)))
                })
                .collect::<Vec<_>>();
            (s.toolbar_more, items)
        });
        if !items.is_empty() {
            let menu = CreatePopupMenu();
            for (id, title, state) in items {
                let flags = MF_STRING
                    | if state.enabled { MF_ENABLED } else { MF_GRAYED }
                    | if state.checked {
                        MF_CHECKED
                    } else {
                        MF_UNCHECKED
                    };
                AppendMenuW(menu, flags, id as usize, wide(title).as_ptr());
            }
            let mut r: RECT = zeroed();
            GetWindowRect(button, &mut r);
            let selected = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_NONOTIFY,
                r.left,
                r.bottom,
                0,
                hwnd,
                null(),
            );
            DestroyMenu(menu);
            if selected != 0 {
                command(hwnd, selected as u16, 0);
            }
        }
        return;
    }
    if REFRESHING.with(|x| x.get()) {
        return;
    }
    if id == EDIT as u16 && notify == EN_CHANGE as u16 {
        let h = STATE.with(|s| s.borrow().as_ref().unwrap().edit);
        let rich = STATE.with(|s| s.borrow().as_ref().unwrap().app.uses_rich_edit());
        if rich {
            let result = crate::rich_edit::extract(h).and_then(|bytes| {
                let selection = crate::rich_edit::selection(h);
                STATE.with(|s| {
                    s.borrow_mut()
                        .as_mut()
                        .unwrap()
                        .app
                        .edit_rich_text(&bytes, selection)
                })
            });
            if let Err(e) = result {
                msg(hwnd, &e, MB_OK | MB_ICONERROR);
                refresh();
            } else {
                update_caption();
            }
            return;
        }
        let n = GetWindowTextLengthW(h) as usize;
        let mut b = vec![0u16; n + 1];
        GetWindowTextW(h, b.as_mut_ptr(), b.len() as i32);
        let result = match String::from_utf16(&b[..n]) {
            Ok(text) => STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.edit(text)),
            Err(_) => Err("Invalid UTF-16 input cannot be saved.".into()),
        };
        if let Err(e) = result {
            msg(hwnd, &e, MB_OK | MB_ICONERROR);
            refresh()
        } else {
            let (table, grid, cell, list, items, selected) = STATE.with(|s| {
                let s = s.borrow();
                let s = s.as_ref().unwrap();
                (
                    s.table,
                    s.app.table(),
                    s.app.selected_cell(),
                    s.list,
                    s.app.items(),
                    s.app.selected(),
                )
            });
            let _ = cell;
            update_table(table, grid.as_deref());
            if !items.is_empty() {
                REFRESHING.with(|x| x.set(true));
                SendMessageW(list, LB_RESETCONTENT, 0, 0);
                for item in items {
                    SendMessageW(list, LB_ADDSTRING, 0, wide(&item).as_ptr() as isize);
                }
                SendMessageW(list, LB_SETCURSEL, selected, 0);
                REFRESHING.with(|x| x.set(false));
            }
            update_caption()
        }
        return;
    }
    if id == LIST as u16 && notify == LBN_SELCHANGE as u16 {
        let l = STATE.with(|s| s.borrow().as_ref().unwrap().list);
        let i = SendMessageW(l, LB_GETCURSEL, 0, 0);
        if i >= 0 {
            STATE.with(|s| {
                let mut s = s.borrow_mut();
                let a = &mut s.as_mut().unwrap().app;
                if a.grid_sheets().is_some() {
                    a.select_grid_sheet(i as usize);
                } else {
                    a.select(i as usize);
                }
            });
            refresh();
            SendMessageW(l, LB_SETCURSEL, i as usize, 0);
        }
        return;
    }
    match id {
        NEW => {
            if !STATE.with(|s| s.borrow().as_ref().unwrap().app.supports_new()) || !confirm(hwnd) {
                return;
            }
            let r = STATE.with(|s| {
                let mut s = s.borrow_mut();
                let s = s.as_mut().unwrap();
                let result = s.app.new_document();
                if result.is_ok() {
                    s.path = None;
                    s.session = Default::default();
                }
                result
            });
            if let Err(e) = r {
                msg(hwnd, &e, MB_OK | MB_ICONERROR);
            }
        }
        OPEN => {
            if !STATE.with(|s| s.borrow().as_ref().unwrap().app.open_is_add()) && !confirm(hwnd) {
                return;
            }
            let (e, f, pattern) = STATE.with(|s| {
                let s = s.borrow();
                let a = &s.as_ref().unwrap().app;
                (a.extension(), a.format_name(), a.open_filter())
            });
            let formats = STATE.with(|s| s.borrow().as_ref().unwrap().app.open_formats());
            let selected = if formats.is_empty() {
                dialog(hwnd, false, e, f, &pattern)
            } else {
                format_dialog(hwnd, &formats, false).map(|v| v.0)
            };
            if let Some(p) = selected {
                let r = open_document_path(p);
                if let Err(e) = r {
                    msg(hwnd, &e, MB_OK | MB_ICONERROR);
                }
            }
        }
        SAVE => {
            save(hwnd);
        }
        SAVE_AS => {
            save_mode(hwnd, true);
        }
        EXIT => {
            SendMessageW(hwnd, WM_CLOSE, 0, 0);
            return;
        }
        FIND | REPLACE => {
            if !STATE.with(|s| s.borrow().as_ref().unwrap().app.supports_find_replace()) {
                return;
            }
            let req = if id == FIND {
                crate::InputRequest {
                    title: "Find next",
                    fields: vec![("Find", String::new())],
                }
            } else {
                crate::InputRequest {
                    title: "Replace all",
                    fields: vec![("Find", String::new()), ("Replace with", String::new())],
                }
            };
            if let Some(values) = crate::prompt::show(hwnd, &req) {
                if id == FIND {
                    let edit = STATE.with(|s| s.borrow().as_ref().unwrap().edit);
                    let mut end: u32 = 0;
                    SendMessageW(edit, EM_GETSEL, 0, &mut end as *mut _ as isize);
                    let result = STATE.with(|s| {
                        s.borrow()
                            .as_ref()
                            .unwrap()
                            .app
                            .find_next(&values[0], end as usize)
                    });
                    match result {
                        Ok(Some((start, end))) => {
                            SetFocus(edit);
                            SendMessageW(edit, EM_SETSEL, start, end as isize);
                            SendMessageW(edit, EM_SCROLLCARET, 0, 0);
                        }
                        Ok(None) => {
                            msg(hwnd, "Text not found.", MB_OK);
                        }
                        Err(e) => {
                            msg(hwnd, &e, MB_OK | MB_ICONERROR);
                        }
                    }
                    return;
                }
                let result = STATE.with(|s| {
                    s.borrow_mut()
                        .as_mut()
                        .unwrap()
                        .app
                        .replace_all(&values[0], &values[1])
                });
                match result {
                    Ok(n) => {
                        refresh();
                        msg(hwnd, &format!("Replaced {n} occurrence(s)."), MB_OK);
                    }
                    Err(e) => {
                        msg(hwnd, &e, MB_OK | MB_ICONERROR);
                    }
                }
            }
            return;
        }
        ABOUT => {
            let text = STATE.with(|s| {
                format!(
                    "{}\n\n{}",
                    s.borrow().as_ref().unwrap().app.name(),
                    s.borrow().as_ref().unwrap().app.status()
                )
            });
            msg(hwnd, &text, MB_OK | MB_ICONINFORMATION);
        }
        _ => {
            let (file_action, request, enabled) = STATE.with(|s| {
                let s = s.borrow();
                let a = &s.as_ref().unwrap().app;
                (
                    a.file_actions().iter().find(|a| a.id == id).copied(),
                    a.input_request(id),
                    a.command_state(id).enabled,
                )
            });
            if !enabled {
                return;
            }
            if let Some(a) = file_action {
                if let Some(p) = dialog(hwnd, a.save, a.extension, a.format, a.pattern) {
                    if a.save
                        && (p.exists()
                            || p.extension()
                                .and_then(|x| x.to_str())
                                .is_none_or(|x| !x.eq_ignore_ascii_case(a.extension)))
                    {
                        msg(
                            hwnd,
                            "Choose a new file name with the required extension.",
                            MB_OK | MB_ICONWARNING,
                        );
                        return;
                    }
                    let r =
                        STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.file_action(id, &p));
                    if let Err(e) = r {
                        msg(hwnd, &e, MB_OK | MB_ICONERROR);
                    }
                }
                refresh();
                return;
            }
            let clipboard_request =
                STATE.with(|s| s.borrow().as_ref().unwrap().app.clipboard_request(id));
            if let Some(request) = clipboard_request {
                let result = match request {
                    crate::ClipboardRequest::WriteText(text) => {
                        crate::clipboard::write_text(hwnd, &text)
                    }
                    crate::ClipboardRequest::WriteData { format, bytes } => {
                        crate::clipboard::write_data(hwnd, &format, &bytes)
                    }
                    crate::ClipboardRequest::ReadData(format) => {
                        crate::clipboard::read_data(hwnd, &format).and_then(|bytes| {
                            STATE.with(|s| {
                                s.borrow_mut()
                                    .as_mut()
                                    .unwrap()
                                    .app
                                    .clipboard_data(id, bytes)
                            })
                        })
                    }
                    crate::ClipboardRequest::ReadText => crate::clipboard::read_text(hwnd)
                        .and_then(|text| {
                            STATE.with(|s| {
                                s.borrow_mut()
                                    .as_mut()
                                    .unwrap()
                                    .app
                                    .clipboard_text(id, text)
                            })
                        }),
                };
                if let Err(e) = result {
                    msg(hwnd, &e, MB_OK | MB_ICONERROR);
                }
                refresh();
                return;
            }
            let preview = STATE.with(|s| s.borrow().as_ref().unwrap().app.rich_preview(id));
            if let Some(geometry) = preview {
                let edit = STATE.with(|s| s.borrow().as_ref().unwrap().edit);
                if let Err(e) = crate::rich_preview::open(hwnd, edit, geometry) {
                    msg(hwnd, &e, MB_OK | MB_ICONERROR);
                }
                return;
            }
            let job = STATE.with(|s| s.borrow().as_ref().unwrap().app.print_job(id));
            if let Some(job) = job {
                if let Err(e) = print_job(hwnd, &job) {
                    msg(hwnd, &e, MB_OK | MB_ICONERROR);
                }
                return;
            }
            let dialog_request =
                STATE.with(|s| s.borrow().as_ref().unwrap().app.dialog_request(id));
            if let Some(request) = dialog_request {
                let result = match request {
                    crate::DialogRequest::Color(c) => {
                        crate::dialogs::color(hwnd, c).map(crate::DialogResult::Color)
                    }
                    crate::DialogRequest::Font => {
                        crate::dialogs::font(hwnd).map(crate::DialogResult::Font)
                    }
                    crate::DialogRequest::PageSetup(margins) => {
                        crate::dialogs::page_setup(hwnd, margins)
                            .map(crate::DialogResult::PageSetup)
                    }
                };
                if let Some(result) = result {
                    if let Err(e) = STATE.with(|s| {
                        s.borrow_mut()
                            .as_mut()
                            .unwrap()
                            .app
                            .dialog_result(id, result)
                    }) {
                        msg(hwnd, &e, MB_OK | MB_ICONERROR);
                    }
                }
                refresh();
                return;
            }
            if let Some(req) = request {
                let multiline =
                    STATE.with(|s| s.borrow().as_ref().unwrap().app.multiline_input(id));
                if let Some(values) = crate::prompt::show_multiline(hwnd, &req, multiline) {
                    let r = STATE.with(|s| {
                        s.borrow_mut()
                            .as_mut()
                            .unwrap()
                            .app
                            .input_action(id, &values)
                    });
                    if let Err(e) = r {
                        msg(hwnd, &e, MB_OK | MB_ICONERROR);
                    }
                }
                refresh();
                return;
            }
            let (edit, rich) = STATE.with(|s| {
                let s = s.borrow();
                let s = s.as_ref().unwrap();
                (s.edit, s.app.uses_rich_edit())
            });
            if rich {
                let selection = crate::rich_edit::selection(edit);
                STATE.with(|s| {
                    s.borrow_mut()
                        .as_mut()
                        .unwrap()
                        .app
                        .set_rich_selection(selection)
                });
            }
            let r = STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.action(id));
            if let Err(e) = r {
                msg(hwnd, &e, MB_OK | MB_ICONERROR);
            } else {
                let pending =
                    STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.take_pending_open());
                if let Some(path) = pending {
                    if confirm(hwnd) {
                        if let Err(e) = open_document_path(path) {
                            msg(hwnd, &e, MB_OK | MB_ICONERROR);
                        }
                    }
                }
            }
        }
    }
    refresh();
    if id == UNDO || id == REDO {
        let (edit, selection) = STATE.with(|s| {
            let s = s.borrow();
            let s = s.as_ref().unwrap();
            (s.edit, s.app.rich_selection_to_restore())
        });
        if let Some(selection) = selection {
            crate::rich_edit::set_selection(edit, selection);
        }
    }
}
unsafe fn update_caption() {
    let (h, status, menu, title, info, u, r, actions) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (
            s.hwnd,
            s.status,
            s.menu,
            format!(
                "{}{} - {}",
                s.path
                    .as_ref()
                    .and_then(|p| p.file_name())
                    .map(|x| x.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "Untitled".into()),
                if s.app.dirty() { " *" } else { "" },
                s.app.name()
            ),
            s.app.status(),
            s.app.can_undo(),
            s.app.can_redo(),
            s.app
                .actions()
                .iter()
                .chain(s.app.view_actions().iter())
                .map(|&(id, _)| (id, s.app.command_state(id)))
                .chain(
                    s.app
                        .command_specs()
                        .into_iter()
                        .map(|c| (c.id, s.app.command_state(c.id))),
                )
                .collect::<Vec<_>>(),
        )
    });
    for (id, state) in actions {
        EnableMenuItem(
            menu,
            id as u32,
            MF_BYCOMMAND | if state.enabled { MF_ENABLED } else { MF_GRAYED },
        );
        CheckMenuItem(
            menu,
            id as u32,
            MF_BYCOMMAND
                | if state.checked {
                    MF_CHECKED
                } else {
                    MF_UNCHECKED
                },
        );
        STATE.with(|s| {
            if let Some((_, button)) = s
                .borrow()
                .as_ref()
                .unwrap()
                .toolbar
                .iter()
                .find(|(key, _)| *key == id)
            {
                EnableWindow(*button, state.enabled as i32);
            }
        });
    }
    SetWindowTextW(h, wide(&title).as_ptr());
    SetWindowTextW(status, wide(&info).as_ptr());
    EnableMenuItem(
        menu,
        UNDO as u32,
        MF_BYCOMMAND | if u { MF_ENABLED } else { MF_GRAYED },
    );
    EnableMenuItem(
        menu,
        REDO as u32,
        MF_BYCOMMAND | if r { MF_ENABLED } else { MF_GRAYED },
    );
    DrawMenuBar(h);
}
unsafe fn select_grid_cell(row: usize, col: Option<usize>) {
    let next = STATE.with(|s| {
        crate::grid_selection_event(
            s.borrow().as_ref().unwrap().app.selected_cell(),
            Some(row),
            col,
            REFRESHING.with(|x| x.get()),
        )
    });
    if let Some((row, col)) = next {
        STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.select_cell(row, col));
        let (edit, text) = STATE.with(|s| {
            let s = s.borrow();
            let s = s.as_ref().unwrap();
            (s.edit, s.app.text())
        });
        let previous = REFRESHING.with(|x| x.replace(true));
        SetWindowTextW(edit, wide(&text).as_ptr());
        REFRESHING.with(|x| x.set(previous));
        update_caption();
    }
}
unsafe extern "system" fn proc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    match m {
        WM_TIMER if w == 42 => {
            let changed = STATE.with(|s| {
                s.borrow_mut()
                    .as_mut()
                    .is_some_and(|s| s.app.poll_background())
            });
            if changed {
                refresh();
            }
            sync_rulers(h);
            let pending = STATE.with(|s| {
                s.borrow_mut()
                    .as_mut()
                    .and_then(|s| s.app.take_pending_print_job())
            });
            if let Some(result) = pending {
                match result {
                    Ok(job) => {
                        if let Err(e) = print_job(h, &job) {
                            msg(h, &e, MB_OK | MB_ICONERROR);
                        }
                    }
                    Err(e) => {
                        msg(h, &e, MB_OK | MB_ICONERROR);
                    }
                }
            }
            0
        }
        WM_COMMAND => {
            command(h, (w & 0xffff) as u16, (w >> 16) as u16);
            0
        }
        WM_NOTIFY => {
            if !REFRESHING.with(|x| x.get()) && !l.eq(&0) {
                let header = &*(l as *const NMHDR);
                if header.idFrom == TABLE {
                    if header.code == NM_CUSTOMDRAW {
                        let draw = &mut *(l as *mut NMLVCUSTOMDRAW);
                        if draw.nmcd.dwDrawStage == CDDS_PREPAINT {
                            return CDRF_NOTIFYITEMDRAW as isize;
                        }
                        if draw.nmcd.dwDrawStage == CDDS_ITEMPREPAINT {
                            return CDRF_NOTIFYSUBITEMDRAW as isize;
                        }
                        if draw.nmcd.dwDrawStage == (CDDS_ITEMPREPAINT | CDDS_SUBITEM) {
                            let row = draw.nmcd.dwItemSpec;
                            let col = draw.iSubItem.max(0) as usize;
                            let (style, selection) = STATE.with(|s| {
                                let s = s.borrow();
                                let a = &s.as_ref().unwrap().app;
                                (a.grid_cell_style(row, col), a.grid_selection())
                            });
                            let rgb =
                                |c: [u8; 3]| c[0] as u32 | (c[1] as u32) << 8 | (c[2] as u32) << 16;
                            if let Some(style) = style {
                                if style.bold
                                    || style.italic
                                    || style.merged.is_some()
                                    || style.borders != 0
                                {
                                    if let Some(merged) = style.merged {
                                        if row != merged.top || col != merged.left {
                                            return CDRF_SKIPDEFAULT as isize;
                                        }
                                    }
                                    let mut rect = RECT {
                                        left: LVIR_BOUNDS as i32,
                                        top: col as i32,
                                        right: 0,
                                        bottom: 0,
                                    };
                                    if SendMessageW(
                                        header.hwndFrom,
                                        LVM_GETSUBITEMRECT,
                                        row,
                                        &mut rect as *mut _ as isize,
                                    ) != 0
                                    {
                                        if let Some(merged) = style.merged {
                                            let mut last = RECT {
                                                left: LVIR_BOUNDS as i32,
                                                top: merged.right as i32,
                                                right: 0,
                                                bottom: 0,
                                            };
                                            if SendMessageW(
                                                header.hwndFrom,
                                                LVM_GETSUBITEMRECT,
                                                merged.bottom,
                                                &mut last as *mut _ as isize,
                                            ) != 0
                                            {
                                                rect.right = last.right;
                                                rect.bottom = last.bottom;
                                            }
                                        }
                                        let selected = selection.is_some_and(|r| {
                                            row >= r.top
                                                && row <= r.bottom
                                                && col >= r.left
                                                && col <= r.right
                                        });
                                        let bg = if selected {
                                            [190, 215, 245]
                                        } else {
                                            style.background.unwrap_or([255, 255, 255])
                                        };
                                        let brush = CreateSolidBrush(rgb(bg));
                                        FillRect(draw.nmcd.hdc, &rect, brush);
                                        DeleteObject(brush as _);
                                        if style.borders != 0 {
                                            let pen = CreatePen(PS_SOLID, 1, rgb([0, 0, 0]));
                                            let old = SelectObject(draw.nmcd.hdc, pen as _);
                                            let line = |x1, y1, x2, y2| {
                                                MoveToEx(draw.nmcd.hdc, x1, y1, null_mut());
                                                LineTo(draw.nmcd.hdc, x2, y2);
                                            };
                                            if style.borders & 1 != 0 {
                                                line(rect.left, rect.top, rect.right, rect.top);
                                            }
                                            if style.borders & 2 != 0 {
                                                line(
                                                    rect.right - 1,
                                                    rect.top,
                                                    rect.right - 1,
                                                    rect.bottom,
                                                );
                                            }
                                            if style.borders & 4 != 0 {
                                                line(
                                                    rect.left,
                                                    rect.bottom - 1,
                                                    rect.right,
                                                    rect.bottom - 1,
                                                );
                                            }
                                            if style.borders & 8 != 0 {
                                                line(rect.left, rect.top, rect.left, rect.bottom);
                                            }
                                            SelectObject(draw.nmcd.hdc, old);
                                            DeleteObject(pen as _);
                                        }
                                        let text = STATE.with(|s| {
                                            s.borrow()
                                                .as_ref()
                                                .unwrap()
                                                .grid_cache
                                                .as_ref()
                                                .and_then(|g| g.get(row))
                                                .and_then(|r| r.get(col))
                                                .cloned()
                                                .unwrap_or_default()
                                        });
                                        let mut lf: LOGFONTW = zeroed();
                                        GetObjectW(
                                            GetStockObject(DEFAULT_GUI_FONT),
                                            size_of::<LOGFONTW>() as i32,
                                            &mut lf as *mut _ as _,
                                        );
                                        if style.bold {
                                            lf.lfWeight = 700;
                                        }
                                        if style.italic {
                                            lf.lfItalic = 1;
                                        }
                                        let font = CreateFontIndirectW(&lf);
                                        let old = SelectObject(draw.nmcd.hdc, font as _);
                                        SetBkMode(draw.nmcd.hdc, TRANSPARENT as i32);
                                        SetTextColor(
                                            draw.nmcd.hdc,
                                            rgb(style.foreground.unwrap_or([0, 0, 0])),
                                        );
                                        let text: Vec<u16> = text.encode_utf16().collect();
                                        ExtTextOutW(
                                            draw.nmcd.hdc,
                                            rect.left + 3,
                                            rect.top + 2,
                                            ETO_CLIPPED,
                                            &rect,
                                            text.as_ptr(),
                                            text.len() as u32,
                                            null(),
                                        );
                                        SelectObject(draw.nmcd.hdc, old);
                                        DeleteObject(font as _);
                                        return CDRF_SKIPDEFAULT as isize;
                                    }
                                }
                                if let Some(c) = style.foreground {
                                    draw.clrText = rgb(c);
                                }
                                if let Some(c) = style.background {
                                    draw.clrTextBk = rgb(c);
                                }
                            }
                            if selection.is_some_and(|r| {
                                row >= r.top && row <= r.bottom && col >= r.left && col <= r.right
                            }) {
                                draw.clrTextBk = rgb([190, 215, 245]);
                            }
                            return CDRF_DODEFAULT as isize;
                        }
                    }
                    if header.code == NM_CLICK {
                        let n = &*(l as *const NMITEMACTIVATE);
                        if n.iItem >= 0 && n.iSubItem >= 0 {
                            let row = n.iItem as usize;
                            let col = n.iSubItem as usize;
                            let anchor =
                                STATE.with(|s| s.borrow().as_ref().unwrap().app.selected_cell());
                            if GetKeyState(VK_SHIFT as i32) < 0 {
                                if let Some((ar, ac)) = anchor {
                                    STATE.with(|s| {
                                        s.borrow_mut().as_mut().unwrap().app.select_grid_range(
                                            crate::GridRange {
                                                top: ar.min(row),
                                                left: ac.min(col),
                                                bottom: ar.max(row),
                                                right: ac.max(col),
                                            },
                                        )
                                    });
                                }
                            } else {
                                select_grid_cell(row, Some(col));
                                STATE.with(|s| {
                                    s.borrow_mut().as_mut().unwrap().app.select_grid_range(
                                        crate::GridRange {
                                            top: row,
                                            left: col,
                                            bottom: row,
                                            right: col,
                                        },
                                    )
                                });
                            }
                            InvalidateRect(header.hwndFrom, null(), 0);
                        }
                    } else if header.code == LVN_ITEMCHANGED {
                        if GetKeyState(VK_SHIFT as i32) < 0 {
                            return 0;
                        }
                        let n = &*(l as *const NMLISTVIEW);
                        if n.iItem >= 0
                            && n.uChanged & LVIF_STATE != 0
                            && n.uNewState & LVIS_SELECTED != 0
                            && n.uOldState & LVIS_SELECTED == 0
                        {
                            select_grid_cell(n.iItem as usize, None);
                        }
                    }
                }
            }
            0
        }
        crate::rich_ruler::BEGIN => {
            let edit = STATE.with(|s| s.borrow().as_ref().unwrap().edit);
            let selection = crate::rich_edit::selection(edit);
            STATE.with(|s| {
                s.borrow_mut()
                    .as_mut()
                    .unwrap()
                    .app
                    .set_rich_selection(selection)
            });
            0
        }
        crate::rich_ruler::APPLY => {
            if l == 0 {
                return 0;
            }
            let command = &*(l as *const crate::rich_ruler::Command);
            let action = STATE.with(|s| {
                let s = s.borrow();
                let ruler = s.as_ref().unwrap().app.rich_ruler()?;
                let page = ruler.page;
                let paragraph = ruler.paragraph;
                let value = command.position;
                Some(match command.kind {
                    0 => crate::RichRulerAction::LeftMargin(value),
                    1 => crate::RichRulerAction::RightMargin(page.width_twips - value),
                    2 => crate::RichRulerAction::TopMargin(value),
                    3 => crate::RichRulerAction::BottomMargin(page.height_twips - value),
                    4 => crate::RichRulerAction::LeftIndent(value - page.margin_left_twips),
                    5 => crate::RichRulerAction::RightIndent(
                        page.width_twips - page.margin_right_twips - value,
                    ),
                    6 => crate::RichRulerAction::FirstIndent(
                        value - page.margin_left_twips - paragraph?.left_twips,
                    ),
                    7 => crate::RichRulerAction::AddTab(value - page.margin_left_twips),
                    8 => crate::RichRulerAction::MoveTab {
                        from: command.from,
                        to: value - page.margin_left_twips,
                    },
                    9 => crate::RichRulerAction::RemoveTab(command.from),
                    _ => return None,
                })
            });
            if let Some(action) = action {
                let result = STATE.with(|s| {
                    s.borrow_mut()
                        .as_mut()
                        .unwrap()
                        .app
                        .rich_ruler_action(action)
                });
                if let Err(e) = result {
                    msg(h, &e, MB_OK | MB_ICONERROR);
                }
                refresh();
            }
            0
        }
        WM_SIZE => {
            if STATE.with(|s| s.borrow().as_ref().is_some_and(|s| !s.edit.is_null())) {
                layout(h)
            }
            0
        }
        WM_DPICHANGED => {
            let r = &*(l as *const RECT);
            SetWindowPos(
                h,
                null_mut(),
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            0
        }
        WM_CLOSE => {
            if confirm(h) {
                DestroyWindow(h);
            }
            0
        }
        WM_DESTROY => {
            KillTimer(h, 42);
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(h, m, w, l),
    }
}
unsafe fn item(m: HMENU, id: u16, t: &str) {
    AppendMenuW(m, MF_STRING, id as usize, wide(t).as_ptr());
}
pub fn run(app: Box<dyn App>) {
    unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let instance = GetModuleHandleW(null());
        let class = wide("Suite42Native");
        let wc = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(proc),
            hInstance: instance,
            hCursor: LoadCursorW(null_mut(), IDC_ARROW),
            hbrBackground: (COLOR_WINDOW + 1) as HBRUSH,
            lpszClassName: class.as_ptr(),
            ..zeroed()
        };
        if RegisterClassW(&wc) == 0 {
            return;
        }
        let canvas_class = wide("Suite42Canvas");
        let cc = WNDCLASSW {
            lpfnWndProc: Some(canvas_proc),
            hInstance: instance,
            hbrBackground: (COLOR_WINDOW + 1) as HBRUSH,
            lpszClassName: canvas_class.as_ptr(),
            ..zeroed()
        };
        RegisterClassW(&cc);
        let bar = CreateMenu();
        let file = CreatePopupMenu();
        if app.supports_new() {
            item(file, NEW, "&New\tCtrl+N");
        }
        item(file, OPEN, "&Open...\tCtrl+O");
        item(file, SAVE, "&Save\tCtrl+S");
        item(file, SAVE_AS, "Save &As...\tCtrl+Shift+S");
        for a in app.file_actions() {
            item(file, a.id, a.title);
        }
        item(file, EXIT, "E&xit");
        AppendMenuW(bar, MF_POPUP, file as usize, wide("&File").as_ptr());
        let editmenu = CreatePopupMenu();
        item(editmenu, UNDO, "&Undo\tCtrl+Z");
        item(editmenu, REDO, "&Redo\tCtrl+Y");
        if app.supports_find_replace() {
            item(editmenu, FIND, "&Find...\tCtrl+F");
            item(editmenu, REPLACE, "&Replace All...\tCtrl+H");
        }
        for &(id, t) in app.actions() {
            item(editmenu, id, t)
        }
        AppendMenuW(bar, MF_POPUP, editmenu as usize, wide("&Edit").as_ptr());
        if !app.view_actions().is_empty() {
            let view = CreatePopupMenu();
            for &(id, title) in app.view_actions() {
                item(view, id, title);
            }
            AppendMenuW(bar, MF_POPUP, view as usize, wide("&View").as_ptr());
        }
        let specs = app.command_specs();
        let mut groups: Vec<(&str, HMENU)> = Vec::new();
        for spec in &specs {
            let menu = if let Some((_, menu)) = groups.iter().find(|(name, _)| *name == spec.group)
            {
                *menu
            } else {
                let menu = CreatePopupMenu();
                groups.push((spec.group, menu));
                menu
            };
            let title = match spec.accelerator {
                Some(key) => format!("{}\t{}", spec.title, key),
                None => spec.title.to_string(),
            };
            item(menu, spec.id, &title);
        }
        for (name, menu) in groups {
            AppendMenuW(bar, MF_POPUP, menu as usize, wide(name).as_ptr());
        }
        let help = CreatePopupMenu();
        item(help, ABOUT, "&About");
        AppendMenuW(bar, MF_POPUP, help as usize, wide("&Help").as_ptr());
        STATE.with(|s| {
            *s.borrow_mut() = Some(State {
                app,
                path: None,
                session: Default::default(),
                hwnd: null_mut(),
                list: null_mut(),
                table: null_mut(),
                edit: null_mut(),
                canvas: null_mut(),
                status: null_mut(),
                menu: bar,
                grid_cache: None,
                toolbar: Vec::new(),
                toolbar_more: null_mut(),
                ruler_horizontal: null_mut(),
                ruler_vertical: null_mut(),
                ruler_format: None,
                fullscreen: None,
            })
        });
        let h = CreateWindowExW(
            0,
            class.as_ptr(),
            wide("Suite42").as_ptr(),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1000,
            700,
            null_mut(),
            bar,
            instance,
            null(),
        );
        if h.is_null() {
            return;
        }
        let mut toolbar = Vec::new();
        for spec in &specs {
            let button = CreateWindowExW(
                0,
                wide("BUTTON").as_ptr(),
                wide(spec.title).as_ptr(),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                0,
                0,
                0,
                0,
                h,
                spec.id as HMENU,
                instance,
                null(),
            );
            toolbar.push((spec.id, button));
        }
        let toolbar_more = CreateWindowExW(
            0,
            wide("BUTTON").as_ptr(),
            wide("More…").as_ptr(),
            WS_CHILD | WS_TABSTOP,
            0,
            0,
            0,
            0,
            h,
            TOOLBAR_MORE as HMENU,
            instance,
            null(),
        );
        let icc = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES,
        };
        InitCommonControlsEx(&icc);
        let table = CreateWindowExW(
            WS_EX_CLIENTEDGE,
            wide("SysListView32").as_ptr(),
            null(),
            WS_CHILD | WS_TABSTOP | WS_VISIBLE | LVS_REPORT | LVS_SHOWSELALWAYS | LVS_SINGLESEL,
            0,
            0,
            0,
            0,
            h,
            TABLE as HMENU,
            instance,
            null(),
        );
        let list = CreateWindowExW(
            WS_EX_CLIENTEDGE,
            wide("LISTBOX").as_ptr(),
            null(),
            WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_TABSTOP | LBS_NOTIFY as u32,
            0,
            0,
            0,
            0,
            h,
            LIST as HMENU,
            instance,
            null(),
        );
        let rich = STATE.with(|s| s.borrow().as_ref().unwrap().app.uses_rich_edit());
        if rich {
            LoadLibraryW(wide("Msftedit.dll").as_ptr());
        }
        let edit = CreateWindowExW(
            WS_EX_CLIENTEDGE,
            wide(if rich { "RICHEDIT50W" } else { "EDIT" }).as_ptr(),
            null(),
            WS_CHILD
                | WS_VISIBLE
                | WS_TABSTOP
                | WS_VSCROLL
                | ES_MULTILINE as u32
                | ES_AUTOVSCROLL as u32
                | ES_WANTRETURN as u32,
            0,
            0,
            0,
            0,
            h,
            EDIT as HMENU,
            instance,
            null(),
        );
        let canvas = CreateWindowExW(
            0,
            canvas_class.as_ptr(),
            null(),
            WS_CHILD,
            0,
            0,
            0,
            0,
            h,
            null_mut(),
            instance,
            null(),
        );
        SendMessageW(edit, EM_SETLIMITTEXT, 16777216, 0);
        if rich {
            crate::rich_edit::disable_undo(edit);
        }
        let status = CreateWindowExW(
            0,
            wide("STATIC").as_ptr(),
            null(),
            WS_CHILD | WS_VISIBLE,
            0,
            0,
            0,
            0,
            h,
            null_mut(),
            instance,
            null(),
        );
        let font = GetStockObject(DEFAULT_GUI_FONT) as usize;
        for control in [list, table, edit, status] {
            SendMessageW(control, WM_SETFONT, font, 1);
        }
        let ruler_horizontal = if rich {
            crate::rich_ruler::create(h, false)
        } else {
            null_mut()
        };
        let ruler_vertical = if rich {
            crate::rich_ruler::create(h, true)
        } else {
            null_mut()
        };
        STATE.with(|s| {
            let mut s = s.borrow_mut();
            let s = s.as_mut().unwrap();
            s.hwnd = h;
            s.app.set_native_window(h as usize);
            s.list = list;
            s.table = table;
            s.edit = edit;
            s.canvas = canvas;
            s.status = status;
            s.toolbar = toolbar;
            s.toolbar_more = toolbar_more;
            s.ruler_horizontal = ruler_horizontal;
            s.ruler_vertical = ruler_vertical;
        });
        let mut acc = vec![
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'N' as u16,
                cmd: NEW,
            },
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'F' as u16,
                cmd: FIND,
            },
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'H' as u16,
                cmd: REPLACE,
            },
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'O' as u16,
                cmd: OPEN,
            },
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'S' as u16,
                cmd: SAVE,
            },
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL | FSHIFT,
                key: b'S' as u16,
                cmd: SAVE_AS,
            },
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'Z' as u16,
                cmd: UNDO,
            },
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'Y' as u16,
                cmd: REDO,
            },
        ];
        for spec in &specs {
            if let Some(key) = spec.accelerator {
                let parts: Vec<_> = key.split('+').collect();
                if let Some(last) = parts.last() {
                    if last.len() == 1 {
                        let mut flags = FVIRTKEY;
                        if parts.iter().any(|p| p.eq_ignore_ascii_case("ctrl")) {
                            flags |= FCONTROL;
                        }
                        if parts.iter().any(|p| p.eq_ignore_ascii_case("shift")) {
                            flags |= FSHIFT;
                        }
                        if parts.iter().any(|p| p.eq_ignore_ascii_case("alt")) {
                            flags |= FALT;
                        }
                        acc.push(ACCEL {
                            fVirt: flags,
                            key: last.as_bytes()[0].to_ascii_uppercase() as u16,
                            cmd: spec.id,
                        });
                    }
                }
            }
        }
        let a = CreateAcceleratorTableW(acc.as_ptr(), acc.len() as i32);
        refresh();
        SetTimer(h, 42, 100, None);
        ShowWindow(h, SW_SHOW);
        let mut m: MSG = zeroed();
        while GetMessageW(&mut m, null_mut(), 0, 0) > 0 {
            if TranslateAcceleratorW(h, a, &m) == 0 && IsDialogMessageW(h, &m) == 0 {
                TranslateMessage(&m);
                DispatchMessageW(&m);
            }
        }
        DestroyAcceleratorTable(a);
    }
}

unsafe extern "system" fn canvas_proc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    if m == WM_CAPTURECHANGED || m == WM_CANCELMODE {
        if DRAGGING.with(|d| d.replace(false)) {
            let _ = STATE.with(|s| {
                s.borrow_mut()
                    .as_mut()
                    .unwrap()
                    .app
                    .canvas_event(crate::CanvasEvent::Cancel)
            });
        }
        InvalidateRect(h, null(), 0);
        return 0;
    }
    if m == WM_KEYDOWN {
        let was_presenting = STATE.with(|s| {
            s.borrow()
                .as_ref()
                .unwrap()
                .app
                .presentation_size()
                .is_some()
        });
        let result = STATE.with(|s| {
            s.borrow_mut()
                .as_mut()
                .unwrap()
                .app
                .canvas_event(crate::CanvasEvent::Key {
                    code: w as u32,
                    modifiers: 0,
                })
        });
        if let Err(e) = result {
            msg(h, &e, MB_OK | MB_ICONERROR);
        }
        if was_presenting {
            refresh();
        } else {
            update_caption();
        }
        InvalidateRect(h, null(), 0);
        return 0;
    }
    if matches!(m, WM_LBUTTONDOWN | WM_MOUSEMOVE | WM_LBUTTONUP) {
        if m == WM_LBUTTONDOWN {
            DRAGGING.with(|d| d.set(true));
            SetCapture(h);
            SetFocus(h);
        }
        let (image, zoom, scene, presentation) = STATE.with(|s| {
            let s = s.borrow();
            let a = &s.as_ref().unwrap().app;
            (
                a.image(),
                a.image_zoom(),
                a.canvas_scene(),
                a.presentation_size(),
            )
        });
        if let Some(scene) = scene {
            let scene = scene_for_canvas(h, scene, presentation);
            let p = crate::Point {
                x: (l as u32 & 0xffff) as u16 as i16 as f64,
                y: ((l as u32 >> 16) & 0xffff) as u16 as i16 as f64,
            };
            if let Some(point) = scene.viewport.view_to_document(p) {
                let event = match m {
                    WM_LBUTTONDOWN => crate::CanvasEvent::PointerDown(point),
                    WM_LBUTTONUP => crate::CanvasEvent::PointerUp(point),
                    _ => crate::CanvasEvent::PointerMove(point),
                };
                let result =
                    STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.canvas_event(event));
                if let Err(e) = result {
                    msg(h, &e, MB_OK | MB_ICONERROR);
                }
                update_caption();
                InvalidateRect(h, null(), 0);
            }
        }
        if let Some((width, height, _)) = image {
            if width > 0 && height > 0 {
                let mut rect: RECT = zeroed();
                GetClientRect(h, &mut rect);
                let scale = zoom.unwrap_or_else(|| {
                    (rect.right as f64 / width as f64).min(rect.bottom as f64 / height as f64)
                });
                if scale > 0.0 {
                    let point = crate::Point {
                        x: ((l as u32 & 0xffff) as u16 as i16 as f64
                            - (rect.right as f64 - width as f64 * scale) / 2.0)
                            / scale,
                        y: (((l as u32 >> 16) & 0xffff) as u16 as i16 as f64
                            - (rect.bottom as f64 - height as f64 * scale) / 2.0)
                            / scale,
                    };
                    let event = match m {
                        WM_LBUTTONDOWN => crate::CanvasEvent::PointerDown(point),
                        WM_LBUTTONUP => crate::CanvasEvent::PointerUp(point),
                        _ => crate::CanvasEvent::PointerMove(point),
                    };
                    let result =
                        STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.canvas_event(event));
                    if let Err(e) = result {
                        msg(h, &e, MB_OK | MB_ICONERROR);
                    }
                    InvalidateRect(h, null(), 0);
                }
            }
        }
        if m == WM_LBUTTONUP {
            DRAGGING.with(|d| d.set(false));
            ReleaseCapture();
        }
        return 0;
    }
    if m != WM_PAINT {
        return DefWindowProcW(h, m, w, l);
    }
    let mut ps: PAINTSTRUCT = zeroed();
    let dc = BeginPaint(h, &mut ps);
    let mut rect: RECT = zeroed();
    GetClientRect(h, &mut rect);
    FillRect(dc, &rect, (COLOR_WINDOW + 1) as HBRUSH);
    let (image, zoom, scene, presentation) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (
            s.app.image(),
            s.app.image_zoom(),
            s.app.canvas_scene(),
            s.app.presentation_size(),
        )
    });
    if let Some(scene) = scene {
        draw_scene(dc, &scene_for_canvas(h, scene, presentation));
    }
    if let Some((width, height, pixels)) = image {
        if width > 0 && height > 0 {
            let scale = zoom.unwrap_or_else(|| {
                (rect.right as f64 / width as f64).min(rect.bottom as f64 / height as f64)
            });
            let dw = (width as f64 * scale).max(1.0) as i32;
            let dh = (height as f64 * scale).max(1.0) as i32;
            let mut bgra = Vec::with_capacity(pixels.len());
            for (i, p) in pixels.as_chunks::<4>().0.iter().enumerate() {
                let a = p[3] as u16;
                let bg = if (i % (width as usize) / 8 + i / (width as usize) / 8).is_multiple_of(2)
                {
                    255u16
                } else {
                    204u16
                };
                for c in [p[2], p[1], p[0]] {
                    bgra.push(((c as u16 * a + bg * (255 - a) + 127) / 255) as u8)
                }
                bgra.push(255)
            }
            let mut bmi: BITMAPINFO = zeroed();
            bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
            bmi.bmiHeader.biWidth = width as i32;
            bmi.bmiHeader.biHeight = -(height as i32);
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB;
            SetStretchBltMode(dc, HALFTONE);
            StretchDIBits(
                dc,
                (rect.right - dw) / 2,
                (rect.bottom - dh) / 2,
                dw,
                dh,
                0,
                0,
                width as i32,
                height as i32,
                bgra.as_ptr().cast(),
                &bmi,
                DIB_RGB_COLORS,
                SRCCOPY,
            );
        }
    }
    EndPaint(h, &ps);
    0
}

unsafe fn update_table(table: HWND, rows: Option<&[Vec<String>]>) {
    let Some(rows) = rows else {
        STATE.with(|s| s.borrow_mut().as_mut().unwrap().grid_cache = None);
        return;
    };
    let (transition, selected) = STATE.with(|s| {
        let mut s = s.borrow_mut();
        let s = s.as_mut().unwrap();
        let selected = s.app.selected_cell();
        let transition = crate::grid_transition(s.grid_cache.as_deref(), rows, selected);
        s.grid_cache = Some(rows.to_vec());
        (transition, selected)
    });
    let was_refreshing = REFRESHING.with(|x| x.replace(true));
    match transition {
        crate::GridTransition::Rebuild { selection } => {
            populate_table(table, rows);
            if let Some((row, col)) = selection {
                if Some((row, col)) != selected {
                    STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.select_cell(row, col));
                }
            }
        }
        crate::GridTransition::Update { cells } => {
            for (row, col) in cells {
                let mut text = wide(&rows[row][col]);
                let item = LVITEMW {
                    mask: LVIF_TEXT,
                    iItem: row as i32,
                    iSubItem: col as i32,
                    pszText: text.as_mut_ptr(),
                    ..zeroed()
                };
                SendMessageW(table, LVM_SETITEMTEXTW, row, &item as *const _ as isize);
            }
        }
    }
    let selected = STATE.with(|s| s.borrow().as_ref().unwrap().app.selected_cell());
    let actual = SendMessageW(table, LVM_GETNEXTITEM, usize::MAX, LVNI_SELECTED as isize);
    if let Some((row, _)) = selected {
        if actual != row as isize {
            let clear = LVITEMW {
                stateMask: LVIS_SELECTED | LVIS_FOCUSED,
                state: 0,
                ..zeroed()
            };
            SendMessageW(
                table,
                LVM_SETITEMSTATE,
                usize::MAX,
                &clear as *const _ as isize,
            );
            let item = LVITEMW {
                stateMask: LVIS_SELECTED | LVIS_FOCUSED,
                state: LVIS_SELECTED | LVIS_FOCUSED,
                ..zeroed()
            };
            SendMessageW(table, LVM_SETITEMSTATE, row, &item as *const _ as isize);
            SendMessageW(table, LVM_ENSUREVISIBLE, row, 0);
        }
    }
    REFRESHING.with(|x| x.set(was_refreshing));
}

unsafe fn populate_table(table: HWND, rows: &[Vec<String>]) {
    SendMessageW(table, LVM_DELETEALLITEMS, 0, 0);
    while SendMessageW(table, LVM_DELETECOLUMN, 0, 0) != 0 {}
    let cols = rows.first().map_or(0, Vec::len);
    for col in 0..cols {
        let mut title = wide(&format!("Column {}", col + 1));
        let column = LVCOLUMNW {
            mask: LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM,
            cx: 140,
            pszText: title.as_mut_ptr(),
            iSubItem: col as i32,
            ..zeroed()
        };
        SendMessageW(table, LVM_INSERTCOLUMNW, col, &column as *const _ as isize);
    }
    for (row, cells) in rows.iter().enumerate() {
        for (col, text) in cells.iter().enumerate() {
            let mut text = wide(text);
            let item = LVITEMW {
                mask: LVIF_TEXT,
                iItem: row as i32,
                iSubItem: col as i32,
                pszText: text.as_mut_ptr(),
                ..zeroed()
            };
            SendMessageW(
                table,
                if col == 0 {
                    LVM_INSERTITEMW
                } else {
                    LVM_SETITEMTEXTW
                },
                if col == 0 { 0 } else { row },
                &item as *const _ as isize,
            );
        }
    }
}

unsafe fn draw_scene(dc: HDC, scene: &crate::CanvasScene) {
    use crate::{Point, SceneItem};
    let cv = |p: Point| scene.viewport.document_to_view(p);
    let rgb = |c: [u8; 3]| c[0] as u32 | (c[1] as u32) << 8 | (c[2] as u32) << 16;
    for item in &scene.items {
        match item {
            SceneItem::Rect {
                x,
                y,
                width,
                height,
                fill,
                stroke,
            } => {
                let a = cv(Point { x: *x, y: *y });
                let b = cv(Point {
                    x: x + width,
                    y: y + height,
                });
                let brush = CreateSolidBrush(rgb(*fill));
                let pen = CreatePen(PS_SOLID, 1, rgb(*stroke));
                let oldb = SelectObject(dc, brush as _);
                let oldp = SelectObject(dc, pen as _);
                Rectangle(dc, a.x as i32, a.y as i32, b.x as i32, b.y as i32);
                SelectObject(dc, oldb);
                SelectObject(dc, oldp);
                DeleteObject(brush as _);
                DeleteObject(pen as _);
            }
            SceneItem::Ellipse {
                x,
                y,
                width,
                height,
                fill,
                stroke,
            } => {
                let a = cv(Point { x: *x, y: *y });
                let b = cv(Point {
                    x: x + width,
                    y: y + height,
                });
                let brush = fill
                    .map(|c| CreateSolidBrush(rgb(c)))
                    .unwrap_or_else(|| GetStockObject(NULL_BRUSH) as _);
                let pen = stroke
                    .map(|c| CreatePen(PS_SOLID, 1, rgb(c)))
                    .unwrap_or_else(|| GetStockObject(NULL_PEN) as _);
                let oldb = SelectObject(dc, brush as _);
                let oldp = SelectObject(dc, pen as _);
                Ellipse(dc, a.x as i32, a.y as i32, b.x as i32, b.y as i32);
                SelectObject(dc, oldb);
                SelectObject(dc, oldp);
                if fill.is_some() {
                    DeleteObject(brush as _);
                }
                if stroke.is_some() {
                    DeleteObject(pen as _);
                }
            }
            SceneItem::Text { x, y, text, color } => {
                let p = cv(Point { x: *x, y: *y });
                let t: Vec<u16> = text.encode_utf16().collect();
                SetBkMode(dc, TRANSPARENT as i32);
                SetTextColor(dc, rgb(*color));
                TextOutW(dc, p.x as i32, p.y as i32, t.as_ptr(), t.len() as i32);
            }
            SceneItem::TextBox {
                x,
                y,
                width,
                height,
                text,
                color,
                font,
                align,
                wrap,
            } => {
                let a = cv(Point { x: *x, y: *y });
                let b = cv(Point {
                    x: x + width,
                    y: y + height,
                });
                if b.x <= a.x || b.y <= a.y || !font.points.is_finite() || font.points <= 0.0 {
                    continue;
                }
                let family = wide(&font.family);
                let size = (font.points * scene.viewport.zoom)
                    .round()
                    .clamp(1.0, 32767.0) as i32;
                let handle = CreateFontW(
                    -size,
                    0,
                    0,
                    0,
                    if font.bold { 700 } else { 400 },
                    font.italic as u32,
                    font.underline as u32,
                    0,
                    DEFAULT_CHARSET as u32,
                    OUT_DEFAULT_PRECIS as u32,
                    CLIP_DEFAULT_PRECIS as u32,
                    DEFAULT_QUALITY as u32,
                    DEFAULT_PITCH as u32,
                    family.as_ptr(),
                );
                if handle.is_null() {
                    continue;
                }
                let old = SelectObject(dc, handle as _);
                let saved = SaveDC(dc);
                SetBkMode(dc, TRANSPARENT as i32);
                SetTextColor(dc, rgb(*color));
                let mut rect = RECT {
                    left: a.x as i32,
                    top: a.y as i32,
                    right: b.x as i32,
                    bottom: b.y as i32,
                };
                let t: Vec<u16> = text.encode_utf16().collect();
                let flags = DT_NOPREFIX
                    | match align {
                        crate::TextAlign::Left => DT_LEFT,
                        crate::TextAlign::Center => DT_CENTER,
                        crate::TextAlign::Right => DT_RIGHT,
                    }
                    | if *wrap { DT_WORDBREAK } else { DT_SINGLELINE };
                DrawTextW(
                    dc,
                    t.as_ptr(),
                    t.len().min(i32::MAX as usize) as i32,
                    &mut rect,
                    flags,
                );
                if saved != 0 {
                    RestoreDC(dc, saved);
                }
                SelectObject(dc, old);
                DeleteObject(handle as _);
            }
            SceneItem::Path {
                points,
                color,
                closed,
            } => {
                if let Some(first) = points.first() {
                    let pen = CreatePen(PS_SOLID, 1, rgb(*color));
                    let old = SelectObject(dc, pen as _);
                    let a = cv(*first);
                    MoveToEx(dc, a.x as i32, a.y as i32, null_mut());
                    for point in &points[1..] {
                        let p = cv(*point);
                        LineTo(dc, p.x as i32, p.y as i32);
                    }
                    if *closed {
                        LineTo(dc, a.x as i32, a.y as i32);
                    }
                    SelectObject(dc, old);
                    DeleteObject(pen as _);
                }
            }
            SceneItem::Image {
                x,
                y,
                width,
                height,
                rgba,
            } => {
                let p = cv(Point { x: *x, y: *y });
                draw_rgba(
                    dc,
                    p.x,
                    p.y,
                    *width as f64 * scene.viewport.zoom,
                    *height as f64 * scene.viewport.zoom,
                    *width,
                    *height,
                    rgba,
                );
            }
            SceneItem::ImageScaled {
                x,
                y,
                width,
                height,
                pixel_width,
                pixel_height,
                rgba,
            } => {
                let p = cv(Point { x: *x, y: *y });
                draw_rgba(
                    dc,
                    p.x,
                    p.y,
                    *width * scene.viewport.zoom,
                    *height * scene.viewport.zoom,
                    *pixel_width,
                    *pixel_height,
                    rgba,
                );
            }
        }
    }
}

/// Draw an RGBA raster into a logical destination rect, compositing transparency on white.
unsafe fn draw_rgba(
    dc: HDC,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    pixel_width: u32,
    pixel_height: u32,
    rgba: &[u8],
) {
    let expected = (pixel_width as usize)
        .checked_mul(pixel_height as usize)
        .and_then(|n| n.checked_mul(4));
    if expected != Some(rgba.len())
        || pixel_width == 0
        || pixel_height == 0
        || pixel_width > i32::MAX as u32
        || pixel_height > i32::MAX as u32
        || !x.is_finite()
        || !y.is_finite()
        || !width.is_finite()
        || !height.is_finite()
        || width <= 0.0
        || height <= 0.0
        || width > i32::MAX as f64
        || height > i32::MAX as f64
    {
        return;
    }
    let mut pixels = Vec::with_capacity(rgba.len());
    for p in rgba.chunks_exact(4) {
        let a = p[3] as u16;
        for v in [p[2], p[1], p[0]] {
            pixels.push(((v as u16 * a + 255 * (255 - a) + 127) / 255) as u8);
        }
        pixels.push(255);
    }
    let mut bmi: BITMAPINFO = zeroed();
    bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = pixel_width as i32;
    bmi.bmiHeader.biHeight = -(pixel_height as i32);
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    let old_mode = SetStretchBltMode(dc, HALFTONE);
    StretchDIBits(
        dc,
        x as i32,
        y as i32,
        width.round().max(1.0) as i32,
        height.round().max(1.0) as i32,
        0,
        0,
        pixel_width as i32,
        pixel_height as i32,
        pixels.as_ptr() as _,
        &bmi,
        DIB_RGB_COLORS,
        SRCCOPY,
    );
    if old_mode != 0 {
        SetStretchBltMode(dc, old_mode);
    }
}

/// Print explicit page coordinates against the selected printer's physical geometry.
unsafe fn print_job(hwnd: HWND, job: &crate::PrintJob) -> Result<(), String> {
    use windows_sys::Win32::Storage::Xps::{
        AbortDoc, EndDoc, EndPage, StartDocW, StartPage, DOCINFOW,
    };
    let geometries: Vec<crate::PrintGeometry> = match job {
        crate::PrintJob::Scenes(pages) => pages.iter().map(|p| p.geometry).collect(),
        crate::PrintJob::RichText(g) => vec![g.geometry],
    };
    if geometries.is_empty() || geometries.iter().any(|g| !g.valid()) {
        return Err("Invalid or empty print page geometry".into());
    }
    let mut dialog: PRINTDLGW = zeroed();
    dialog.lStructSize = size_of::<PRINTDLGW>() as u32;
    dialog.hwndOwner = hwnd;
    dialog.Flags = PD_RETURNDC | PD_NOSELECTION | PD_NOPAGENUMS;
    dialog.nCopies = 1;
    let accepted = PrintDlgW(&mut dialog) != 0;
    if !dialog.hDevMode.is_null() {
        GlobalFree(dialog.hDevMode);
    }
    if !dialog.hDevNames.is_null() {
        GlobalFree(dialog.hDevNames);
    }
    if !accepted {
        return Ok(());
    }
    let dc = dialog.hDC;
    if dc.is_null() {
        return Err("Printer did not return a device context".into());
    }
    let caps = |v| GetDeviceCaps(dc, v as i32);
    let (dpi_x, dpi_y) = (caps(LOGPIXELSX), caps(LOGPIXELSY));
    let (width, height) = (caps(PHYSICALWIDTH), caps(PHYSICALHEIGHT));
    let (offset_x, offset_y) = (caps(PHYSICALOFFSETX), caps(PHYSICALOFFSETY));
    let (print_w, print_h) = (caps(HORZRES), caps(VERTRES));
    let geometry_error = if dpi_x <= 0
        || dpi_y <= 0
        || width <= 0
        || height <= 0
        || offset_x < 0
        || offset_y < 0
        || print_w <= 0
        || print_h <= 0
    {
        Some("Printer reported invalid dimensions")
    } else if geometries.iter().any(|g| {
        let twips = |pixels: i32, dpi: i32| i64::from(pixels) * 1440 / i64::from(dpi);
        let physical_w = twips(width, dpi_x);
        let physical_h = twips(height, dpi_y);
        (physical_w - i64::from(g.width_twips)).abs() > 60
            || (physical_h - i64::from(g.height_twips)).abs() > 60
            || i64::from(g.margin_left_twips) < twips(offset_x, dpi_x)
            || i64::from(g.margin_top_twips) < twips(offset_y, dpi_y)
            || i64::from(g.margin_right_twips) < twips((width - offset_x - print_w).max(0), dpi_x)
            || i64::from(g.margin_bottom_twips) < twips((height - offset_y - print_h).max(0), dpi_y)
    }) {
        Some("Select the document's paper size and printable margins in the printer dialog")
    } else {
        None
    };
    if let Some(error) = geometry_error {
        DeleteDC(dc);
        return Err(error.into());
    }
    let title = wide("Suite42 document");
    let info = DOCINFOW {
        cbSize: size_of::<DOCINFOW>() as i32,
        lpszDocName: title.as_ptr(),
        ..zeroed()
    };
    if StartDocW(dc, &info) <= 0 {
        DeleteDC(dc);
        return Err("Could not start print job".into());
    }
    let result: Result<(), String> = (|| match job {
        crate::PrintJob::Scenes(pages) => {
            for page in pages {
                if StartPage(dc) <= 0 {
                    return Err("Could not start print page".into());
                }
                let saved = SaveDC(dc);
                if saved == 0 {
                    return Err("Could not save print device state".into());
                }
                SetMapMode(dc, MM_ANISOTROPIC);
                SetWindowExtEx(dc, 72, 72, null_mut());
                SetViewportExtEx(dc, dpi_x, dpi_y, null_mut());
                let ox = (i64::from(page.geometry.margin_left_twips) * i64::from(dpi_x) / 1440)
                    as i32
                    - offset_x;
                let oy = (i64::from(page.geometry.margin_top_twips) * i64::from(dpi_y) / 1440)
                    as i32
                    - offset_y;
                SetViewportOrgEx(dc, ox, oy, null_mut());
                let clip_w = (page.geometry.width_twips
                    - page.geometry.margin_left_twips
                    - page.geometry.margin_right_twips)
                    / 20;
                let clip_h = (page.geometry.height_twips
                    - page.geometry.margin_top_twips
                    - page.geometry.margin_bottom_twips)
                    / 20;
                IntersectClipRect(dc, 0, 0, clip_w, clip_h);
                let mut scene = page.scene.clone();
                scene.viewport = crate::Viewport::default();
                draw_scene(dc, &scene);
                RestoreDC(dc, saved);
                if EndPage(dc) <= 0 {
                    return Err("Could not finish print page".into());
                }
            }
            Ok(())
        }
        crate::PrintJob::RichText(job) => {
            let edit = STATE.with(|s| s.borrow().as_ref().unwrap().edit);
            let ox = (i64::from(offset_x) * 1440 / i64::from(dpi_x)) as i32;
            let oy = (i64::from(offset_y) * 1440 / i64::from(dpi_y)) as i32;
            let pages = crate::rich_print::paginate(edit, dc, job.geometry, (ox, oy))?;
            let mut result = Ok(());
            for (page, (start, end)) in pages.iter().copied().enumerate() {
                if StartPage(dc) <= 0 {
                    result = Err("Could not start print page".into());
                    break;
                }
                let next = crate::rich_print::body(edit, dc, job.geometry, (ox, oy), start);
                if next != end {
                    result = Err("Print pagination changed while rendering".into());
                    break;
                }
                if let Err(e) =
                    crate::rich_print::decorations(dc, job, (offset_x, offset_y), page, pages.len())
                {
                    result = Err(e);
                    break;
                }
                if EndPage(dc) <= 0 {
                    result = Err("Could not finish print page".into());
                    break;
                }
            }
            crate::rich_print::release(edit);
            result
        }
    })();
    let final_result = match result {
        Ok(()) => {
            if EndDoc(dc) > 0 {
                Ok(())
            } else {
                Err("Could not finish print job".into())
            }
        }
        Err(e) => {
            AbortDoc(dc);
            Err(e)
        }
    };
    DeleteDC(dc);
    final_result
}
