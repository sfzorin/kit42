#!/usr/bin/env python3
"""Run Suite42's native UI regressions and capture windows in isolated app bundles.

Requires `swift build`, a logged-in macOS desktop, and access to WindowServer.
Results go to build/ui-audit. No physical scanner is used.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
APPS = ('PDF42', 'DOC42', 'XLS42', 'IMG42', 'PPT42', 'SCN42')
parser = argparse.ArgumentParser()
parser.add_argument('--mode', choices=('all', 'tests', 'screenshots'), default='all')
parser.add_argument('--app', choices=APPS)
args = parser.parse_args()
out = REPO / 'build/ui-audit'
out.mkdir(parents=True, exist_ok=True)
shots = out / 'screenshots'
shots.mkdir(exist_ok=True)


def prepare(app):
    bundle = out / 'apps' / f'{app}Audit.app'
    contents = bundle / 'Contents'
    (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
    (contents / 'Resources').mkdir(exist_ok=True)
    binary = contents / 'MacOS' / app
    shutil.copy2(REPO / '.build/debug' / app, binary)
    with (REPO / 'Resources' / app / 'Info.plist').open('rb') as f:
        info = plistlib.load(f)
    info['CFBundleIdentifier'] = f'com.sfzorin.uiaudit.{app.lower()}'
    info['CFBundleName'] = info['CFBundleDisplayName'] = app + ' Audit'
    with (contents / 'Info.plist').open('wb') as f:
        plistlib.dump(info, f)
    shutil.copy2(REPO / 'Resources' / app / 'AppIcon.icns', contents / 'Resources/AppIcon.icns')
    subprocess.run(['codesign', '--force', '-s', '-', str(bundle)], check=True, capture_output=True)
    return binary


binaries = {app: prepare(app) for app in APPS if not args.app or args.app == app}


def run(app, name, arguments=(), settings=None, marker=None, snapshot=False):
    env = {k: v for k, v in os.environ.items() if not k.startswith('K42_')}
    env.update(K42_APPEARANCE='light', K42_UI_TEST_DIR=str(shots), K42_SCAN_DIR=str(out / 'saved-scans'))
    env.update(settings or {})
    target = shots / (name + '.png')
    dialog_target = shots / (name + '-dialog.png') if app == 'XLS42' and env.get('K42_ACTION') else None
    if snapshot:
        target.unlink(missing_ok=True)
        if dialog_target:
            dialog_target.unlink(missing_ok=True)
        env['K42_SNAPSHOT'] = str(target)
    log = out / (name + '.log')
    try:
        result = subprocess.run([str(binaries[app]), *map(str, arguments)], env=env, cwd=REPO,
                                capture_output=True, timeout=60)
        text = (result.stdout + result.stderr).decode(errors='replace')
        log.write_text(text)
        ok = result.returncode == 0 and 'FAIL' not in text
        if marker:
            ok = ok and marker in text
        if snapshot:
            ok = ok and target.is_file() and target.stat().st_size > 1000
            if dialog_target:
                ok = ok and dialog_target.is_file() and dialog_target.stat().st_size > 1000
        print(f'{"PASS" if ok else "FAIL"} {name} (exit {result.returncode})', flush=True)
        if not ok:
            print(text[-3500:], flush=True)
        return ok
    except subprocess.TimeoutExpired as error:
        log.write_bytes((error.stdout or b'') + (error.stderr or b''))
        print(f'FAIL {name}: timeout; see {log}', flush=True)
        return False


def fixture(app, arguments):
    result = subprocess.run([str(REPO / '.build/debug' / app), *map(str, arguments)],
                            capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))


results = []
if args.mode in ('all', 'tests'):
    if 'DOC42' in binaries and not (out / 'sample.docx').exists():
        fixture('DOC42', ['--demo', out / 'sample.docx'])
    tests = [
        ('XLS42', 'xls-ui', ('--uitest',), {'K42_PASTEBOARD': '1'}, 'ALL PASSED', False),
        ('IMG42', 'img-ui', ('--uitest',), {}, 'IMG42 UI: 0 failures', False),
        ('SCN42', 'scn-ui', ('--uitest',), {}, 'SCN42 UI: 0 failures', False),
        ('DOC42', 'doc-panels', (), {'K42_NEW': '1', 'K42_SCRIPT': 'auditpanels', 'K42_AUDIT_RECENT': '1'}, 'DOC panel UI regressions: 16/16 passed', True),
        ('DOC42', 'doc-rulers', (), {'K42_NEW': '1', 'K42_SCRIPT': 'auditrulers'}, 'DOC ruler UI regressions:', True),
        ('DOC42', 'doc-editing', (), {'K42_NEW': '1', 'K42_SCRIPT': 'auditediting'}, 'DOC editing UI regressions:', True),
        ('DOC42', 'doc-document', (), {'K42_NEW': '1', 'K42_SCRIPT': 'auditdocument'}, 'DOC document UI regressions:', True),
        ('DOC42', 'doc-pagination', (out / 'sample.docx',), {'K42_SCRIPT': 'auditpagination'}, 'DOC pagination UI regressions:', True),
        ('PDF42', 'mark-samples', ('--mark-samples', out / 'marks'), {}, 'Mark samples: ', False),
        ('PDF42', 'mark-signature', (out / 'sample.pdf',), {'K42_OPEN_GENERATOR': 'signature', 'K42_SNAPSHOT_SHEET': '1'}, None, True),
        ('PDF42', 'mark-seal', (out / 'sample.pdf',), {'K42_OPEN_GENERATOR': 'seal', 'K42_SNAPSHOT_SHEET': '1'}, None, True),
        ('PPT42', 'ppt-notes', (), {'K42_NEW': '1', 'K42_DO': 'auditnotes', 'K42_AUDIT_RECENT': '1'}, 'PPT notes UI regressions: 6/6 passed', True),
        ('PPT42', 'ppt-editing', (), {'K42_NEW': '1', 'K42_DO': 'auditediting', 'K42_PASTEBOARD': '1'}, 'PPT editing UI regressions:', True),
        ('PPT42', 'ppt-text', (), {'K42_NEW': '1', 'K42_DO': 'audittext', 'K42_PASTEBOARD': '1'}, 'PPT text/table/show UI regressions:', True),
        ('PPT42', 'ppt-files', (), {'K42_NEW': '1', 'K42_DO': 'auditfiles'}, 'PPT document lifecycle regressions:', True),
        ('PPT42', 'ppt-inspector', (), {'K42_NEW': '1', 'K42_DO': 'auditinspector'}, 'PPT inspector UI regressions:', True),
    ]
    for app, name, arguments, settings, marker, snapshot in tests:
        if app in binaries:
            results.append(run(app, name, arguments, settings, marker, snapshot))

if args.mode in ('all', 'screenshots'):
    # Fixtures come from the apps' existing headless exporters, independent of UI hooks.
    if not (out / 'sample.docx').exists(): fixture('DOC42', ['--demo', out / 'sample.docx'])
    if not (out / 'sample.pdf').exists(): fixture('DOC42', ['--pdf', out / 'sample.docx', out / 'sample.pdf'])
    if not (out / 'sample.pptx').exists(): fixture('PPT42', ['--demo', out / 'sample.pptx'])
    if not (out / 'sample.xlsx').exists(): fixture('XLS42', ['--feature-demo', out / 'sample.xlsx'])
    if not (out / 'scans/feed-1.png').exists(): fixture('SCN42', ['--make-test-inputs', out / 'scans'])
    configs = {
        'PDF42': ([out / 'sample.pdf'], {'K42_MARKUP': '1'}, '900x650'),
        'DOC42': ([], {'K42_NEW': '1', 'K42_SCRIPT': 'type Interface audit — проверка интерфейса;findbar'}, '700x420'),
        'XLS42': ([], {'K42_OPEN': str(out / 'sample.xlsx')}, '900x600'),
        'IMG42': ([out / 'scans/feed-1.png'], {'K42_MARKUP': '1', 'K42_INFO': '1', 'K42_FILMSTRIP': '1'}, '800x600'),
        'PPT42': ([out / 'sample.pptx'], {'K42_INSPECTOR': 'text', 'K42_SELECT': '0'}, '820x520'),
        'SCN42': ([], {'K42_DEMO_PAGES': '3', 'K42_FAKE_SCANNER': str(out / 'scans')}, '860x560'),
    }
    for app, (arguments, settings, small) in configs.items():
        if app not in binaries: continue
        for appearance, size in [('light', '1180x780'), ('dark', small)]:
            options = dict(settings, K42_APPEARANCE=appearance, K42_SIZE=size, K42_AUDIT_RECENT='1')
            results.append(run(app, app.lower() + '-' + appearance, arguments, options, snapshot=True))
    if 'PDF42' in binaries:
        results.append(run('PDF42', 'pdf-properties', [out / 'sample.pdf'], {'K42_ACTION': 'propertiesAction'}, snapshot=True))
    if 'DOC42' in binaries:
        for name, script, appearance in [('doc-book', 'viewmode 1', 'light'),
                                          ('doc-columns', 'cols 2', 'dark'),
                                          ('doc-web', 'viewmode 3', 'light')]:
            results.append(run('DOC42', name, [out / 'sample.docx'],
                               {'K42_SCRIPT': script, 'K42_APPEARANCE': appearance, 'K42_SIZE': '1180x780'}, snapshot=True))
    if 'XLS42' in binaries:
        results.append(run('XLS42', 'xls-format', [], {'K42_OPEN': str(out / 'sample.xlsx'), 'K42_ACTION': 'formatCellsAction:'}, snapshot=True))
print(f'{sum(results)}/{len(results)} UI runs passed', flush=True)
sys.exit(0 if all(results) else 1)
