

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
