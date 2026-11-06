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
    System::LibraryLoader::GetModuleHandleW,
    UI::{
        Controls::{Dialogs::*, *},
        HiDpi::*,
        Input::KeyboardAndMouse::SetFocus,
        WindowsAndMessaging::*,
    },
};
const OPEN: u16 = 1;
const SAVE: u16 = 2;
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
struct State {
    app: Box<dyn App>,
    path: Option<PathBuf>,
    hwnd: HWND,
    list: HWND,
    table: HWND,
    edit: HWND,
    canvas: HWND,
    status: HWND,
    menu: HMENU,
    grid_cache: Option<Vec<Vec<String>>>,
}
thread_local! { static STATE:RefCell<Option<State>>=const { RefCell::new(None) }; static REFRESHING:Cell<bool>=const {Cell::new(false)}; }

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
unsafe fn save(hwnd: HWND) -> bool {
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
            s.app.items(),
            s.app.text(),
            s.app.status(),
            s.app.can_undo(),
            s.app.can_redo(),
            s.app.list_visible(),
            s.app.text_readonly(),
            s.app.image().is_some(),
            s.app.table(),
        )
    });
    REFRESHING.with(|x| x.set(true));
    SetWindowTextW(hwnd, wide(&title).as_ptr());
    SetWindowTextW(status, wide(&info).as_ptr());
    SetWindowTextW(edit, wide(&text).as_ptr());
    SendMessageW(edit, EM_SETREADONLY, readonly as usize, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    for item in items {
        SendMessageW(list, LB_ADDSTRING, 0, wide(&item).as_ptr() as isize);
    }
    let (selected, actions, can_save) = STATE.with(|s| {
        let s = s.borrow();
        let a = &s.as_ref().unwrap().app;
        (
            a.selected(),
            a.actions()
                .iter()
                .chain(a.view_actions().iter())
                .map(|&(id, _)| (id, a.enabled(id)))
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
    for (id, enabled) in actions {
        EnableMenuItem(
            menu,
            id as u32,
            MF_BYCOMMAND | if enabled { MF_ENABLED } else { MF_GRAYED },
        );
    }
    update_table(table, grid.as_deref());
    ShowWindow(table, if grid.is_some() { SW_SHOW } else { SW_HIDE });
    ShowWindow(
        list,
        if visible && grid.is_none() {
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
    DrawMenuBar(hwnd);
    layout(hwnd);
}
unsafe fn layout(hwnd: HWND) {
    let (list, table, edit, canvas, status, visible, grid) = STATE.with(|s| {
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
        )
    });
    let mut r: RECT = zeroed();
    GetClientRect(hwnd, &mut r);
    let dpi = GetDpiForWindow(hwnd) as i32;
    let sh = 24 * dpi / 96;
    if grid {
        let height = (r.bottom - sh).max(0);
        let top = height * 3 / 4;
        MoveWindow(table, 0, 0, r.right, top, 1);
        MoveWindow(edit, 0, top, r.right, height - top, 1);
        MoveWindow(status, 0, height, r.right, sh, 1);
        return;
    }
    let left = if visible {
        (240 * dpi / 96).min(r.right / 2)
    } else {
        0
    };
    MoveWindow(list, 0, 0, left, (r.bottom - sh).max(0), 1);
    MoveWindow(
        edit,
        left,
        0,
        (r.right - left).max(0),
        (r.bottom - sh).max(0),
        1,
    );
    MoveWindow(
        canvas,
        left,
        0,
        (r.right - left).max(0),
        (r.bottom - sh).max(0),
        1,
    );
    MoveWindow(status, 0, (r.bottom - sh).max(0), r.right, sh, 1);
}
unsafe fn command(hwnd: HWND, id: u16, notify: u16) {
    if REFRESHING.with(|x| x.get()) {
        return;
    }
    if id == EDIT as u16 && notify == EN_CHANGE as u16 {
        let h = STATE.with(|s| s.borrow().as_ref().unwrap().edit);
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
            STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.select(i as usize));
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
            if let Some(p) = dialog(hwnd, false, e, f, &pattern) {
                let r = STATE.with(|s| {
                    let mut s = s.borrow_mut();
                    let s = s.as_mut().unwrap();
                    let r = s.app.open(&p);
                    if r.is_ok() && !s.app.open_is_add() {
                        s.path = Some(p)
                    }
                    r
                });
                if let Err(e) = r {
                    msg(hwnd, &e, MB_OK | MB_ICONERROR);
                }
            }
        }
        SAVE => {
            save(hwnd);
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
                    a.enabled(id),
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
            if let Some(req) = request {
                if let Some(values) = crate::prompt::show(hwnd, &req) {
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
            let r = STATE.with(|s| s.borrow_mut().as_mut().unwrap().app.action(id));
            if let Err(e) = r {
                msg(hwnd, &e, MB_OK | MB_ICONERROR);
            }
        }
    }
    refresh();
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
                .map(|&(id, _)| (id, s.app.enabled(id)))
                .collect::<Vec<_>>(),
        )
    });
    for (id, enabled) in actions {
        EnableMenuItem(
            menu,
            id as u32,
            MF_BYCOMMAND | if enabled { MF_ENABLED } else { MF_GRAYED },
        );
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
        WM_COMMAND => {
            command(h, (w & 0xffff) as u16, (w >> 16) as u16);
            0
        }
        WM_NOTIFY => {
            if !REFRESHING.with(|x| x.get()) && !l.eq(&0) {
                let header = &*(l as *const NMHDR);
                if header.idFrom == TABLE {
                    if header.code == NM_CLICK {
                        let n = &*(l as *const NMITEMACTIVATE);
                        if n.iItem >= 0 && n.iSubItem >= 0 {
                            select_grid_cell(n.iItem as usize, Some(n.iSubItem as usize));
                        }
                    } else if header.code == LVN_ITEMCHANGED {
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
        item(file, SAVE, "Save &As...\tCtrl+Shift+S");
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
        let help = CreatePopupMenu();
        item(help, ABOUT, "&About");
        AppendMenuW(bar, MF_POPUP, help as usize, wide("&Help").as_ptr());
        STATE.with(|s| {
            *s.borrow_mut() = Some(State {
                app,
                path: None,
                hwnd: null_mut(),
                list: null_mut(),
                table: null_mut(),
                edit: null_mut(),
                canvas: null_mut(),
                status: null_mut(),
                menu: bar,
                grid_cache: None,
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
        let edit = CreateWindowExW(
            WS_EX_CLIENTEDGE,
            wide("EDIT").as_ptr(),
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
        STATE.with(|s| {
            let mut s = s.borrow_mut();
            let s = s.as_mut().unwrap();
            s.hwnd = h;
            s.list = list;
            s.table = table;
            s.edit = edit;
            s.canvas = canvas;
            s.status = status
        });
        let acc = [
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
                cmd: SAVE,
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
        let a = CreateAcceleratorTableW(acc.as_ptr(), acc.len() as i32);
        refresh();
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
    if m != WM_PAINT {
        return DefWindowProcW(h, m, w, l);
    }
    let mut ps: PAINTSTRUCT = zeroed();
    let dc = BeginPaint(h, &mut ps);
    let mut rect: RECT = zeroed();
    GetClientRect(h, &mut rect);
    FillRect(dc, &rect, (COLOR_WINDOW + 1) as HBRUSH);
    let (image, zoom) = STATE.with(|s| {
        let s = s.borrow();
        let s = s.as_ref().unwrap();
        (s.app.image(), s.app.image_zoom())
    });
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
