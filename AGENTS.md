# Git authorship

Use `sfzorin <s.zorin@dannie.cc>` as the author and committer of all commits.
The project owner must be the only attributed author. Do not add assistants,
models, or agents as co-authors, and do not add generated-by footers, assistant
signatures, or session links to commit messages or pull request descriptions.

Preserve other agents' working changes. Do not commit or publish unrelated work.

# Documentation

Keep README.md aligned with user-visible behavior, CLI commands and limitations. Update DESIGN.md when shared UI
contracts or components change. Record audit/build/test evidence and publication state in STATUS.md with a date;
distinguish verified behavior from code-review findings and areas not exercised. Do not describe uncommitted local
fixes as a published release or claim that a passing check covers features it does not test.

# DOC42 verification

For changes to rulers, pagination, editing commands or document lifecycle, build DOC42 and run
`python3 scripts/audit-ui.py --app DOC42` on a logged-in macOS desktop. A screenshot or a successful panel toggle
does not establish that dragging, Undo/Redo, saving or complete-document layout works. Keep a regression scenario
for each reproduced functional defect; do not weaken assertions to make a failed run pass.

For changes to import/export or print layout, also run `python3 scripts/audit-documents-cli.py`.
Before installing a packaged DOC42, run the CLI checks against that bundle and verify its code signature.
Record the actual results and coverage in STATUS.md. Preserve the user's running app and open documents when
replacing an installed bundle, and retain a backup of the previous bundle.

# XLS42 verification

For changes to spreadsheet editing, formatting, formulas, protection, sheet commands or document lifecycle, build
XLS42, run `.build/debug/XLS42 --selftest`, and run `python3 scripts/audit-ui.py --app XLS42` on a logged-in macOS
desktop. Keep a regression scenario for every reproduced defect. Exercise values, complete write destinations,
Undo/Redo and saved/reopened state where relevant; a visible control or successful dialog toggle is insufficient.
Do not weaken assertions to make a failed run pass.

For changes to import/export, date handling or print layout, also run
`python3 scripts/audit-spreadsheets-cli.py --binary .build/debug/XLS42`. Record the tested binary, actual results,
scenario coverage and any skipped checks in STATUS.md; distinguish local fixes from published or installed builds.
Before installing a packaged XLS42, run its `--selftest`, run the CLI checks with
`--binary build/XLS42.app/Contents/MacOS/XLS42`, and verify that bundle's code signature. Preserve the user's running
app and open documents when replacing an installed bundle, and retain a backup of the previous bundle.

# PPT42 verification

For changes to presentation editing, text, tables, object geometry, inspector controls, document lifecycle or slide
shows, build PPT42, run `.build/debug/PPT42 --selftest`, and run `python3 scripts/audit-ui.py --app PPT42` on a logged-in
macOS desktop. Keep a regression scenario for each reproduced defect. Exercise native actions/event dispatch,
complete Undo/Redo state and rendered output where relevant; a screenshot or a successful control toggle alone does
not establish working behavior. Do not weaken assertions to make a failed run pass.

For changes to import/export, file layout or printing, also run
`python3 scripts/audit-presentations-cli.py --binary .build/debug/PPT42`. Record the tested binary, actual results,
coverage and skipped PDF/movie checks in STATUS.md. Before installing a packaged PPT42, run its `--selftest`, run the
CLI checks with `--binary build/PPT42.app/Contents/MacOS/PPT42`, and verify its code signature. Preserve running apps
and open documents when replacing an installed bundle, retain a backup, and distinguish local installation from a
published release.


# PDF42 verification

For changes to PDF markup, form controls, page commands, document lifecycle, navigation, geometry or metadata, build
PDF42, run `.build/debug/PDF42 --selftest`, and run `python3 scripts/audit-ui.py --app PDF42` on a logged-in macOS desktop.
Keep a regression scenario for each reproduced defect. Exercise actual controls/events, complete Undo/Redo state,
rendered results and saved/reopened data where relevant. A button opening a panel is not proof that its operation works;
do not weaken assertions to make a failed run pass.

For changes to saving, redaction, forms, import/export, compression, signing or print layout, also run
`python3 scripts/audit-pdf-cli.py --binary .build/debug/PDF42`. Record the binary identity, actual coverage and any skipped
signature checks in STATUS.md. Local self-signed fixtures do not establish trusted-certificate/TSA interoperability or
PDF/A conformance. Before installing a packaged PDF42, run its `--selftest`, the CLI checks with
`--binary build/PDF42.app/Contents/MacOS/PDF42`, the native UI checks with that same `--binary` and `--app PDF42`, and verify
its code signature. Preserve running apps and open documents, retain a backup of the previous bundle, and distinguish
local installation from a published release.

# IMG42 verification

For changes to image viewing/navigation, markup, selections, pixel operations, adjustments, resizing or document
lifecycle, build IMG42, run `.build/debug/IMG42 --selftest`, and run `python3 scripts/audit-ui.py --app IMG42` on a
logged-in macOS desktop. Keep a regression scenario for each reproduced defect. Exercise actual controls/events,
rendered pixels, complete Undo/Redo state and saved/reopened output where relevant. A screenshot or a panel opening
does not establish that its tools work; do not weaken assertions to make a failed run pass.

For changes to image import/export, orientation, metadata, encoding or printing, also run
`python3 scripts/audit-images-cli.py --binary .build/debug/IMG42`. Record actual scenario coverage, any codec/Vision
skips and the tested executable's SHA-256 in STATUS.md. Before installing a packaged IMG42, run its `--selftest`,
the native UI checks with `--app IMG42 --binary` and the CLI checks with `--binary` against that same packaged
executable, and verify its code signature. Check that the installed executable hash matches the tested binary.
Preserve running applications and open images, retain a backup of the previous bundle, and distinguish local
installation from a published or notarized release.
