

## Signature bench and fluent timing — 2026-11-06

`PDF42 --signature-bench DIR [designs copies] [--check]` (Kit42 `SignatureBench`): for 4 names × 5 forms, metrics on
the pen's captured path and timing — normalized jerk (Teulings), velocity peaks per 100 px, hesitation (time under 8 %
of the stroke's peak speed, ends excluded), line wobble (RMS deviation from the line smoothed over 13 px), DTW between
copies (intra) and between styles (inter), and Vision handwriting recognition for legible forms. Calibration on one
garland of loops (130 px): fluent — jerk 5 065, hesitation 5.2 %, wobble 0.28 px; slow with stops — 31 814, 49.3 %,
0.30 px; slow with a 10 Hz 3 px tremor — 28 867, 46.4 %, 0.68 px. No real-signature reference is used.

Results (debug build, 6 designs × 5 copies per name and form):

| Version | Norm. jerk | Hesitation | Wobble | Intra DTW | Inter DTW | Vision reads |
|---|---:|---:|---:|---:|---:|---:|
| Before (8087d00: overlap 0.4–0.6, corners 0.15, smaller overlap for short movements) | 55 918 | 35.6 % | 0.34 px | 0.067 | 0.384 | 36 % |
| Overlap 0.6–0.78, corners 0.35, no size scaling | 15 780 | 13.5 % | 0.35 px | 0.067 | 0.380 | 32 % |
| Overlap 0.68–0.82, corners 0.5 (kept) | 10 584 | 7.9 % | 0.35 px | 0.067 | 0.381 | 39 % |

The bench confirmed the owner's observation that signatures read as slowly written: timing was close to the laboured
reference while the line itself was smooth. With the line shape coming from the spline, overlap only affects timing,
so it was raised; learned signatures use 0.6–0.68 and corners 0.3. `--check` thresholds: hesitation ≤ 15 %, wobble ≤
0.5 px, intra ≥ 0.02, inter/intra ≥ 3 — passed on a 4 × 4 run. Vision legibility uses 72 images per run, so ±10 points
is noise; it reads Latin full names best and Cyrillic signatures poorly. Not done: comparison with real signature data
(research datasets need licences), human blind test.

## SCN42 signatures and stamps printed into pages — 2026-11-06

- New: Tools › Signature or Stamp… (⇧⌘K, optional toolbar item). A mark from the shared library/generator is placed
  over the shown page (drag, corner resize with fixed proportions, arrow nudge; it can be grabbed in a background
  window), then Return / Print into Page multiplies it into the page pixels — the shown image and the
  geometry-corrected original, so clean-up, colour changes and Crop and Straighten Again keep it. Gray pages stay gray,
  B&W pages stay 1-bit. One Undo step. Saved files carry the mark inside the page image; PDFs get no annotation.
  The six new strings are translated into all 20 languages.
- Checked on this commit's tree (`.build/debug/SCN42`, SHA-256
  `aeb67f5250a5f78cfdf00733b41dd78de66d3b26e6d049217fff035919bca0ac`): `--selftest` 0 failures; `--uitest` 0 failures,
  including 20/20 mark checks — native command opens the library popover; disabled on the scanner glass; drag, corner
  resize, click outside, Esc and Return through `NSWindow.sendEvent`; multiply pixels (paper turns blue, text under
  the mark stays black, outside untouched) in the image and in the original; clean-up re-run keeps the mark; Undo and
  Redo to the identical pixel objects; saved PDF rendered back with the mark and no annotations; gray and 1-bit pages;
  switching page drops an unfinished placement.
- The same scenario also passed (20/20, plus 9/9 `audit-ui.py --app SCN42` runs) on a newer local SCN42 tree whose
  document model also clears the unsaved marker on Undo; this commit's older document model keeps the marker after
  Undo, so the shared check asserts restored pixels only.
- Not run: `audit-scans-cli.py` (no import/export code changed). Not checked: clicking an item inside the library
  popover (the audit calls the same placement entry its callback uses) and visual review of the placement bar.

## Signatures: ink, diacritics, legibility decay, rise, learned pen width, blind test — 2026-11-06

- Ink: ballpoint line about 30 % wider (0.026–0.034 of cap height), denser (smaller speed fade, shorter lift fade,
  full-width touch-down, rarer and shorter skips, weaker pressure/paper texture), wider and darker downstrokes for
  ballpoint and gel; per-copy ink shade no longer lightens by more than 2 %.
- Letters: breve of й/ğ and two dots (or a dash) of ё/ö/ü as delayed strokes (styles with `dots == 0` omit them);
  later letters of a word get smaller, flatter and lose interior turns; baselines climb 2–8° in about 7 of 8 styles
  (one random draw, so saved design seeds keep their other parameters — the styles on the sample page look as before);
  copy variation moved from letter shapes (narrower ranges) to layout (rise ±0.025 per copy, run-out 0.6–1.4);
  strike-through flourish limited to the foot of the capital (through its middle З read as Б).
- Learning from pictures: tracing at 360 px instead of 260, spur filter relative to line width (min 8 px instead of
  14), measured line width (ink area ÷ centre line) stored in the sample and used as the copies' pen width.
- New `--signature-blindtest` / `--signature-blindtest-score` (sheet with equalised grey ink and darkness, key, d′).
- Checked on the commit tree (`.build/debug/PDF42`, SHA-256 `8979378e1c80600007a924a4b1cc16bf85e30b8d2f6247b84ddc594810e0fa4c`):
  `--selftest` 57/57; `--signature-bench 6 4 --check` passed — hesitation 7.1 % (before 7.9 %), wobble 0.34 px (0.35),
  intra 0.065 (0.066), inter 0.390 (0.381), Vision 32 % (39 %; ±10 points is noise at this sample size);
  `audit-ui.py --mode tests --app PDF42 --binary …` mark-samples, mark-signature, mark-seal, mark-learn 4/4.
  Blind test mechanics: sheet, key and scoring (all correct → 100 %, d′ 2.80; inverted → 0 %).
- Not established: realism for people. The blind test was run only with generated stand-ins for "real" pictures;
  a real test needs the owner's own signatures and several testers. Its first run showed that copies learned from a
  picture lose small letters inside a large loop (Yılmaz → Y, i, l and a line) — improved by the finer tracing, not
  solved. Visual review of the sample page only; other apps (DOC42, IMG42, PPT42, XLS42, SCN42) use the same Kit42
  renderer but their own UI audits were not re-run.
