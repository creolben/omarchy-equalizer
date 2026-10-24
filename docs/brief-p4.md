# Phase 4 — replace the straight meter with a waveform

You are working in `/home/creolben/Projects/omarchy-equalizer-pr4` (branch
`pr-4-audit`). Omarchy shell plugin: QML panel over a bash backend. Phases 1–3
are landed (metrics memo, wheel policy, panel reorganised around a fixed
instrument band).

Read `docs/spec-v2.md` §1.4 and §2.3 first. The working tree is dirty on
purpose; do not revert, reformat or commit anything. No git operations.

## Why

The level meter today is a 5 px track with a width-animated fill and a dB number
(`Panel.qml`, the meter block above the preset row). It reads as a progress bar
— an outside reader of `docs/panel.png` described it as "an unlabeled
scrollbar" — and carries nothing the number does not.

A mirrored waveform envelope of the same peak data carries the same number plus
a sense of dynamics, and it stops looking like a progress bar. It must not be
fake motion: when nothing is playing the meter is a hairline and the animation
stops.

## 1. `Model.js` — the series as pure math

```js
// The meter's waveform. Pure numbers so it can be tested without Qt: the panel
// draws what this returns, and the shape is defined here rather than in Canvas.
//
// There is no sample data to draw -- the monitor reports a peak -- so this is a
// synthetic envelope scaled by that peak: two partials inside a window that
// tapers to the midline at both ends. Amplitude is linear in peak (the dB text
// beside the meter stays the precise number); the shape is what tells the eye
// that something is playing.
function waveSeries(peak, phase, count) {
  var n = Math.round(Number(count))
  if (!(n >= 8)) n = 8
  if (n > 512) n = 512
  var p = clamp(Number(peak) || 0, 0, 1)
  var ph = Number(phase) || 0
  var out = []
  for (var i = 0; i < n; i++) {
    var u = i / (n - 1)
    var body = Math.sin(2 * Math.PI * (u + ph)) * 0.7 +
               Math.sin(2 * Math.PI * (2.7 * u + 1.7 * ph)) * 0.3
    var window = 1 - 0.55 * Math.pow(2 * u - 1, 2)
    out.push(body * window * p)
  }
  return out
}
```

This exact body was validated offline against the assertions in §4 (bounds for
peak ∈ {0, 0.01, 0.5, 1} × phase ∈ {0, 0.13, 0.7}, silence, linearity, phase
motion, clamps, determinism, taper, interior peak at u ≈ 0.66, mean |v| ≈ 0.40
at full peak). Implement it as written; if you change the constants, the tests
below must still pass and the report must say what changed.

- Returns an array of `count` numbers in `[-1, 1] * peak` (i.e. `|v| <= peak`).
- Shape: two partials, `sin(2π(1.0·u + phase)) * 0.7 + sin(2π(2.7·u + 1.7·phase)) * 0.3`
  where `u` runs 0..1 across the series, windowed by `1 - 0.55 * (2u - 1)^2` so
  the ends taper and the ribbon does not look cut off, then scaled by `peak`.
- `count` is clamped to an integer in `[8, 512]`; `peak` is clamped to `[0, 1]`;
  `phase` is used as given (wrapped to `[0, 1)` is fine, but wraparound must not
  change the amplitude bounds).
- No state, no cache. Keep the file's no-semicolon style.
- Document in a comment why the amplitude is `peak` and not a dB conversion —
  the dB text beside the meter stays the precise number.

## 2. `LevelWave.qml` — the drawing

New component, plugin-owned:

```qml
Item {
  property real peak: 0          // 0..1, from the peak monitor
  property bool active: false    // panel open and equalizer enabled
  property bool clipped: false   // clip hold or peak > 0.98
  property color foreground: …
  property color urgent: …
  implicitHeight: Style.space(20)
}
```

- `Canvas` filling the item, `renderStrategy: Canvas.Immediate` if the shell's
  other Canvases do; sample `count = Math.max(8, Math.min(96, Math.round(width / 6)))`.
- Draw a **filled, mirrored ribbon**: top edge left→right, bottom edge
  right→left, close, fill. One path per frame, no per-sample styling.
- Colour: `foreground` at ~0.85 opacity; `urgent` (with the existing CLIP text)
  when `clipped`. A faint midline (1 px, 0.12 opacity) gives the zero reference
  the straight bar never had.
- Ballistics: keep `property real level` inside the component. Attack is
  instant (`level = Math.max(level, peak)`); release decays toward `peak`:
  `level += (peak - level) * 0.18` per 33 ms frame. Falling to a hairline in
  ~300–400 ms, not a flicker.
- Idle: when `level < 0.01` draw a flat hairline at 35 % opacity. No motion.
- Animation: `Timer { interval: 33; repeat: true; running: root.active && root.level > 0.01 }`
  advancing `phase` by 0.045 per tick and calling `requestPaint()`. The timer
  must stop when the panel closes or the equalizer is disabled — this runs in
  the shell process.
- Respect `prefers-reduced-motion` if the shell exposes it; if it does not, do
  not invent a setting.

## 3. `Panel.qml`

- The meter is the `Row { visible: root.enabled }` inside `instrumentColumn`,
  above the PRESET section — a 5 px track whose fill's width animates, plus the
  `Text { id: levelText }` dB/CLIP readout and a `Behavior on width`.
- Replace the track and its fill with `LevelWave` **inside that Row**, keeping the
  Row, its `visible: root.enabled` binding and `levelText` exactly as they are.
  The dB text and the `clipHeld`/CLIP logic are correct and stay.
- Delete the now-unused `Behavior on width` meter animation and any meter-only
  properties that lose their last reader (update grep assertions in
  `tests/run-tests.sh` if they name them).
- The instrument band is height-sensitive: Phase 3 measured it at 631 px against
  a 760 px card. Report the new instrument height as `631 + (new row − 13)` and
  confirm the total still fits with ADVANCED folded.

## 4. `tests/wave-check.js`

New node test, same style as the others (`PASS`/`FAIL`, final count, exit code):

1. Bounds: for `peak` in {0, 0.01, 0.5, 1} and `phase` in {0, 0.13, 0.7}, every
   sample satisfies `|v| <= peak + 1e-12`.
2. Silence: `peak = 0` → every sample exactly 0.
3. Amplitude scales linearly with `peak` at fixed phase.
4. Phase changes the series (series at 0.1 differs from 0.2) but not the bounds.
5. `count` is clamped: `waveSeries(0.5, 0, 1).length === 8`, `waveSeries(0.5, 0, 9999).length === 512`,
   non-integer counts round.
6. Determinism: two calls with identical arguments are deeply equal.
7. Taper: the first and last samples are strictly smaller in magnitude than the
   largest sample for `peak = 1` (the window works).
8. Print the measured time for 10 000 series of 96 points (information only).

Wire into `tests/run-tests.sh` in the established idiom
(`node "$here/wave-check.js" > "$T/wave-check.log" 2>&1` … `check`).

## 5. Docs

`docs/panel.png` must show the new meter. If the shell cannot be run here, keep
the old image and say so plainly — do not fabricate a screenshot. Mention the
meter in the README's panel paragraph in one clause ("the meter is a waveform
envelope that goes quiet when the signal does").

## Verification

1. `node tests/wave-check.js` → 0 failures.
2. `bash tests/run-tests.sh` → record the pre-change count and finish with
   `count + 1`, 0 failed. Allow ~200 s.
3. `node tests/preset-levels.js`, `node tests/input-policy-check.js`,
   `node tests/metrics-check.js`, `node tests/headroom-check.js` → green.
4. Report whether the panel still fits without scrolling in graphic mode with
   ADVANCED folded (Phase 3's acceptance), with the new meter height in the
   arithmetic.

## Hard rules

- Do not touch DSP, `bin/omarchy-equalizer`, the graph generator, or the
  preset files. This phase is the meter only.
- Do not modify `/usr/share/omarchy/**`.
- The meter must never animate while the panel is closed; verify the timer's
  `running` expression binds to the panel's `opened` and `enabled`, and say so.
- If the shell cannot render for you, the Canvas code still has to be reviewed
  line by line against the API actually used elsewhere in this plugin
  (`ResponseCurve.qml` is the reference for Canvas usage in the shell).

## Report back

- `waveSeries` as shipped, and the exact drawing/ballistics constants.
- Test results and the panel-height arithmetic.
- What you could not verify (live rendering, screenshot), stated plainly.
