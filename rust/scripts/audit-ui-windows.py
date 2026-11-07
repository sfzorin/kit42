#!/usr/bin/env python3
"""Exercise native windows and production dialogs through their normal commands."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time

if os.name != "nt":
    raise SystemExit("Run this audit on Windows.")

u = c.WinDLL("user32", use_last_error=True)
u.EnumWindows.argtypes = [c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM), w.LPARAM]
u.EnumChildWindows.argtypes = u.EnumWindows.argtypes
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.GetWindowTextLengthW.argtypes = [w.HWND]
u.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.GetDlgCtrlID.argtypes = [w.HWND]
u.IsWindowVisible.argtypes = [w.HWND]
u.IsWindowEnabled.argtypes = [w.HWND]
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = w.LPARAM
WM_COMMAND, WM_SETTEXT, WM_CLOSE = 0x111, 0xC, 0x10


def text(hwnd):
    value = c.create_unicode_buffer(u.GetWindowTextLengthW(hwnd) + 1)
    u.GetWindowTextW(hwnd, value, len(value))
    return value.value


def classname(hwnd):
    value = c.create_unicode_buffer(256)
    u.GetClassNameW(hwnd, value, len(value))
    return value.value


def windows(pid, parent=None):
    found = []
    @c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    def collect(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(owner))
        if owner.value == pid and u.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True
    if parent:
        u.EnumChildWindows(parent, collect, 0)
    else:
        u.EnumWindows(collect, 0)
    return found


def wait_for(predicate, description, process, timeout=25):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = predicate()
        if result:
            return result
        if process.poll() is not None:
            raise AssertionError(f"App exited while waiting for {description}, code {process.returncode}")
        time.sleep(0.05)
    snapshot = [(classname(h), text(h)) for h in windows(process.pid)]
    raise AssertionError(f"Timed out waiting for {description}. Windows: {snapshot}")


def modal(process, title=None, native_class=None):
    return wait_for(lambda: next((h for h in windows(process.pid)
        if u.IsWindowEnabled(h) and (title is None or text(h) == title)
        and (native_class is None or classname(h) == native_class)), None),
        title or native_class or "modal", process)


def command(hwnd, identifier):
    assert u.PostMessageW(hwnd, WM_COMMAND, identifier, 0)


def set_text(hwnd, value):
    data = c.create_unicode_buffer(value)
    u.SendMessageW(hwnd, WM_SETTEXT, 0, c.cast(data, c.c_void_p).value)
    assert text(hwnd) == value


def fill_prompt(process, main, identifier, title, values):
    command(main, identifier)
    dialog = modal(process, title=title, native_class="Suite42InputDialog")
    for index, value in enumerate(values):
        control = u.GetDlgItem(dialog, 100 + index)
        assert control, f"Missing field {index} in {title}"
        set_text(control, value)
    command(dialog, 1)
    return dialog


def choose_file(process, path):
    dialog = modal(process, native_class="#32770")
    children = windows(process.pid, dialog)
    edits = [h for h in children if classname(h).lower() == "edit"]
    control = next((h for h in edits if u.GetDlgCtrlID(h) in (1148, 1001)), None)
    if control is None:
        assert len(edits) == 1, [(classname(h), u.GetDlgCtrlID(h), text(h)) for h in children]
        control = edits[0]
    set_text(control, str(path))
    command(dialog, 1)


def output_ready(process, main, path, signature):
    wait_for(lambda: path.is_file() and path.stat().st_size > 32 and u.IsWindowEnabled(main), str(path), process)
    assert path.read_bytes().startswith(signature), path


def minimal_pdf(path):
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>", b"<< /Length 0 >>\nstream\n\nendstream"]
    data = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{number} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Root 1 0 R /Size {len(offsets)} >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(data)


def audit(binary, output):
    process = subprocess.Popen([str(binary)])
    results = {"app": binary.name, "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "checks": []}
    try:
        main = modal(process, native_class="Suite42Native")
        results["checks"].append("native main window visible")
        command(main, 6)
        about = modal(process, native_class="#32770")
        content = " ".join(text(h) for h in windows(process.pid, about))
        assert binary.stem.upper() in content, content
        command(about, 1)
        wait_for(lambda: u.IsWindowEnabled(main), "About closed", process)
        results["checks"].append("About command identifies app and closes")
        if binary.stem.lower() not in {"doc42", "pdf42", "xls42"}:
            return results
        if binary.stem.lower() == "pdf42":
            source = output / "input.pdf"
            minimal_pdf(source)
            command(main, 1)
            choose_file(process, source)
            wait_for(lambda: source.name in text(main) and u.IsWindowEnabled(main), "PDF open", process)
        elif binary.stem.lower() == "xls42":
            source = output / "input.csv"
            source.write_text("Name,Code\nBoard 0007,PCB-0007\nBoard 0008,PCB-0008\n", encoding="utf-8")
            command(main, 1)
            choose_file(process, source)
            wait_for(lambda: source.name in text(main) and u.IsWindowEnabled(main), "CSV open", process)
            fill_prompt(process, main, 25, "Range (1-based)", ["1", "1", "3", "2"])
            wait_for(lambda: u.IsWindowEnabled(main), "range selected", process)
        png = output / f"{binary.stem}-barcode.png"
        fill_prompt(process, main, 65517, "Create Barcode", ["PCB-0007", "Code 128", "55"])
        choose_file(process, png)
        output_ready(process, main, png, b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack_from(">II", png.read_bytes(), 16)
        assert width > 100 and height > 20
        results["checks"].append("barcode created through native dialog and saved as PNG")
        pdf = output / f"{binary.stem}-labels.pdf"
        fields = (["1", "2, 0, 1", "Code 128", "100, 140, 2, 2", "1, 4"]
            if binary.stem.lower() == "xls42" else
            ["Board 0007", "PCB-0007", "Code 128", "100, 140, 2, 2", "2, 4"])
        fill_prompt(process, main, 65518, "Create Label Sheet", fields)
        choose_file(process, pdf)
        output_ready(process, main, pdf, b"%PDF-")
        results["checks"].append("label sheet created through native dialog and saved as PDF")
        return results
    finally:
        if process.poll() is None:
            for hwnd in windows(process.pid):
                if classname(hwnd) == "Suite42Native":
                    u.PostMessageW(hwnd, WM_CLOSE, 0, 0)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.bin_dir = args.bin_dir.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        for app in ["DOC42", "XLS42", "PDF42", "IMG42", "PPT42", "SCN42"]:
            results.append(audit(args.bin_dir / (app + ".exe"), args.output))
            print(json.dumps(results[-1]), flush=True)
    finally:
        (args.output / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
