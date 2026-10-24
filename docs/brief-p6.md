# Phase 6 — regression test for issue #3, then housekeeping

You are working in `/home/creolben/Projects/omarchy-equalizer-pr4` (branch
`pr-4-audit`). Phases 1–5 are landed: metrics memo, wheel policy, reorganised
panel (fixed instrument band + scrolling controls), waveform meter, categorised
searchable presets.

Read `docs/spec-v2.md` §1.6 and §4 Phase 6. The working tree is dirty on purpose;
do not revert, reformat or commit anything. No git operations beyond read-only
inspection.

## 1. The issue #3 regression test (required)

The bug that was fixed by hand before Phase 1: in `ResponseCurve.qml`'s press
handler, `dragIndex` was assigned **before** `bandFreqAt(index)` was read, and
`bandFreqAt()` returns `draftFreq` for the band being dragged. On the first drag
that made `draftFreq` 0, so the handle was drawn at the `xFor()` fallback of
1 kHz and the readout said `0 Hz`.

The test must fail on the old ordering and pass on the current one. Two
acceptable shapes, in order of preference:

**(a) A source-order test** — cheap, deterministic, no Qt:

- New `tests/press-order-check.js` (node, same PASS/FAIL/exit-code style as the
  other `tests/*.js`): read `ResponseCurve.qml`, locate the `onPressed` handler
  of the plot's `MouseArea`, and assert that the first assignment to
  `root.draftFreq` (or `draftFreq`) appears **before** the first assignment to
  `root.dragIndex` inside that block.
- Assert also that `bandFreqAt` still returns `draftFreq` for `index ===
  dragIndex` (read the function body, or — better — assert the ordering
  invariant and leave the function alone).
- Make the failure message explicit: "the press handler reads the band's
  frequency after marking it as dragged; the read returns draftFreq and the
  handle is drawn at the fallback frequency".

**(b) An offscreen QML test** — only if it is cheap here:

- `tests/qml/tst_responsecurve.qml` instantiating `ResponseCurve.qml` through
  the existing `tests/qml/imports` stubs, calling a press at band 2's handle, and
  asserting `draftFreq` equals `bands[2].freq` and `dragIndex === 2`.
- This needs `ResponseCurve` to expose a small seam (e.g. a `pressAt(x, y)`
  function that the internal `MouseArea` also calls, or the existing handler
  body moved into `beginDrag(x, y)`). Exposing a seam for tests is acceptable.
- If the component pulls in shell modules that cannot be stubbed without
  rewriting the plugin, stop and use (a) instead. Say which you did.

Either way, wire the test into `tests/run-tests.sh` in the established idiom.

## 2. Optional: the bar glyph pulse (only if step 1 is green and time remains)

`BarWidget.qml` draws a static glyph: it shows on/off but not level or clipping.
A subtle pulse driven by the widget's own `PwNodePeakMonitor` (opacity or a
1–2 px height wobble on the glyph) would tell the user something is playing
without opening the panel.

Requirements if you do it:

- Default **off**, behind a persisted setting the widget reads from the
  plugin's existing settings file, so nobody pays for the monitor unless they
  asked. Do not create a new settings file.
- The monitor must only run when the widget is enabled *and* the setting is on;
  a bar widget that repaints the whole panel process at 30 fps is not acceptable.
- No animation while the value is 0. Clipping should be the only colour change.
- If adding the setting requires touching the backend or the schema in a way
  that needs migration, skip it and say so.

## 3. Housekeeping (required)

- `README.md`: make the panel section describe what actually ships now —
  fixed instrument band, scrolling ADVANCED section, waveform meter, preset
  picker with categories and search, wheel/focus/Alt policy. Remove any sentence
  that names a section that no longer exists. Do not rewrite the CLI section.
- `docs/panel.png`: refresh from the running panel at 430 px width **if** the
  shell can be run here. If not, keep the current image and say plainly that it
  was not refreshed.
- `docs/spec-v2.md`: add a short "Landed" table at the top listing each phase
  with the commit-less state (file list + assertion count). Do not rewrite the
  critique.
- Confirm nothing else references removed things: `grep -rn` for `modeCaption`,
  `preampMarks`, `preampScale`, `contentColumn`, and any `PanelSlider` import
  that is now unused. Report what you found and fixed.

**Do not bump `manifest.json`'s version.** The spec owner does that at release.

## Verification

1. All node checks: `metrics-check.js`, `input-policy-check.js`, `wave-check.js`,
   `press-order-check.js`, `preset-levels.js`, `curve-check.js` → 0 failures.
2. `bash tests/run-tests.sh` → record the starting count, finish at
   `start + <new assertions>` with 0 failed (~200 s).
3. `git diff --check` clean.
4. Report the panel's actual section list after Phase 3 (paste it), so the
   README claim in step 3 can be checked against it.

## Hard rules

- No DSP, backend, graph-generator or preset-curve changes.
- Do not modify `/usr/share/omarchy/**`.
- No new runtime dependency, no version bump, no git operations.
- Everything you cannot verify (live rendering, screenshot, live picker) must be
  stated as unverified rather than assumed.

## Report back

- Which shape you used for the issue #3 test (a or b) and why, plus proof it
  fails on the old ordering (temporarily reorder in a scratch copy — never in
  the working tree — and paste the failing output).
- Whether the bar pulse shipped, and if not, why not.
- The final suite count, the section list, and the unverified list.
