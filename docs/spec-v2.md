# Equalizer 2.0 — panel UX, input policy, presets

Status: working spec, written 2026-10-23 against `main` at `e51e67b` (+ the two
small fixes landed with this document, see §0).
Audience: an executing agent (DeepSeek Harness, `dsh --profile headless`). Each
phase in §4 is written as a self-contained brief; run one phase per invocation.

Read §1 and §2 before touching anything. §1 is the evidence for §2, and §2 is the
contract every phase is judged against.

## Landed (all six phases, verified on this machine after each run)

| Phase | What it changed | New tests | Suite |
| --- | --- | --- | --- |
| 1 | `Model.metrics()` — one memoised peak/preamp per band change, `chainCoefficients` + `responseSeries`; `Panel.qml` reads it from a single property | `tests/metrics-check.js` (20) | 248 → 249 |
| 2 | Input policy in `Model.wheelOwns`; plugin-owned `PreampSlider.qml` (wheel scrolls, drag/arrows edit); faders armed by click or Alt; `sendPreampNow` cannot flip headroom on a no-op click | `tests/input-policy-check.js` (17) | 249 → 252 |
| 3 | Fixed instrument band + scrolling controls; mode into the RESPONSE header; preamp row under the faders; OUTPUT + AutoEq folded into ADVANCED; pinned status strip | — | 252 |
| 4 | `Model.waveSeries` + `LevelWave.qml`: mirrored ribbon, attack/release ballistics, idle hairline, timer stops when quiet | `tests/wave-check.js` (22) | 252 → 253 |
| 6 | Issue #3 regression test, written with this spec and landed before phase 5 so no run could regress it: it **fails** on the pre-fix handler. README/spec housekeeping came with phases 3–5 | `tests/press-order-check.js` (6) | 253 → 254 |
| 5 | `category` on all 18 presets with an order-band guard; `presetDirty` in `status`; `SearchableDropdown` picker with `· EDITED` | `preset-levels.js` 109 → 148 | 254 → 264 |

Verified independently after each phase: bit-identical `peakDb`/`autoPreampDb`
across 60 band set / rate / preamp combinations versus the pre-phase `Model.js`;
all `.qml` files parse (`qmlformat`); the meter rendered offscreen and inspected
pixel by pixel and by eye; `presetDirty` checked against a real `apply-preset`
round trip. Not verified anywhere: live panel behaviour, and the two screenshots.

### Audit, 2026-10-23 (after all six phases)

Fixed:

- **Faders could not be pressed in 10-band mode.** The plot's `MouseArea` covered
  the bank and accepted every press, so drag, click-to-arm and double-click reset
  on the faders were dead (pre-existing, but it made §2.2's "focused (clicked)"
  unreachable). `faderLayer` now sits above it; the plot also scrolls the panel
  on wheel itself instead of relying on propagation.
- **The preset picker brought back the clipboard read.** The shell's
  `SearchableDropdown` embeds a native `TextField`, which undoes the 1.2.0
  marketplace fix. `PresetPicker.qml` is the same control with a `KeyField`
  search box; the suite now rejects kit components that wrap text inputs.
- **Curve keyboard (§2.2) and the crowded-handle hit radius (§1.6)** were not
  implemented. They are now: ←/→ select, ↑/↓ ±0.5 dB, `0` resets, with a focus
  ring, and the radius shrinks to half the closest handle gap.
- Parametric gain slider: right-click reset never fired (left button only).
- Alt+wheel reported as horizontal is still an Alt arm (`Model.wheelDelta`).
- Meter: the phase wrap at 1 jumped the 1.7× partial every ~0.7 s (now wraps at
  10); the idle and timer thresholds disagreed at exactly 0.01.
- Status strip: a repeated identical message now gets its full 8 s, a running
  AutoEq search is not cleared, and a queued action no longer wipes an error.
- Restored the manual-headroom line, the `dB` on the LIMITER warning, and
  `metrics().shapedCount`.
- Tests: `tests/qml/tst_responsecurve.qml` is the behavioural issue #3 test
  Phase 6 asked for (it fails on the pre-fix order and with the bank under the
  plot); `tst_presetpicker.qml` covers the picker; `press-order-check.js` can no
  longer be fooled by a decoy assignment; `metrics-check.js` compares against the
  independent per-point sweep for every set.

Shipped differently from this spec, still open:

- §2.1 layout: the panel ships a **tab bar** (Response / Bands / Output /
  AutoEq) under a fixed hero, meter and preset row, not the fixed instrument plus
  a folded ADVANCED section. There is no `advancedCollapsed` key. On a 768 px
  screen the Response page scrolls.
- The PRESET header meta shows the category (`GENRE · EDITED`), not the name,
  because the trigger right below already shows the name.
- The idle meter is a dashed line at 40 %, not a solid hairline at 35 %.
- `status` reports `presetDirty`, not a `presetSignature`.
- `docs/panel.png` and `docs/presets.png` predate the tabbed layout.

---

## 0. Baseline (verified on this machine, 2026-10-23)

| Check | Command | Result |
| --- | --- | --- |
| Full suite | `bash tests/run-tests.sh` | **248 passed, 0 failed** (~150 s) |
| Preset shapes | `node tests/preset-levels.js` | **109 passed, 0 failed**, set spread 2.3 dB of 2.5 allowed |
| Curve parity | `node tests/curve-check.js` | pass |
| Backend/Curve headroom parity | `node tests/headroom-check.js` | pass |
| `status` cost | `time (for i in $(seq 10); do ./bin/omarchy-equalizer status >/dev/null; done)` | ~112 ms per call |

Landed with this document (do not re-do; verify instead):

- `presets/Zouk.json` (order 36, level −2.0 dB) and `presets/Kompa.json`
  (order 37, level −1.2 dB), both inside every preset-levels bound, set spread
  unchanged at 2.3 dB. README table updated.
- `ResponseCurve.qml` press handler: `draftFreq` is now read **before**
  `dragIndex` is set, which fixes GitHub issue #3 (handle/fader drawn at 1 kHz
  with a `0 Hz` readout on the first drag). No regression test yet — Phase 5
  adds one.

Environment facts the executor needs:

- Panel QML runs inside the Omarchy shell (Quickshell, Qt 6.12); the shell's
  widget kit lives in `/usr/share/omarchy/shell/Ui/` and is **read-only** for
  this plugin. `PanelSlider.qml` there is shell-owned.
- `qmltestrunner` lives at `/usr/lib/qt6/bin/qmltestrunner`; the suite already
  runs it offscreen with stub modules under `tests/qml/imports/`.
- `TestCase.mouseWheel` is listed in the Qt 6.11 `plugins.qmltypes` but is a
  no-op in this build (probed: zero deliveries, `undefined` return). **Do not
  write wheel-delivery tests that depend on it.** Test the *decision* as a pure
  function instead (Phase 2).
- Anything that touches audio must go through `tests/run-tests.sh` and its
  stubs (`tests/bin/*`). Never run `enable`, `set-*`, `apply-preset`,
  `systemctl` or `pactl` against the live session while developing.

---

## 1. Critique — what is actually wrong, with evidence

### 1.1 The preamp slider steals the scroll wheel, and takes headroom with it

`Panel.qml:945` uses the shell's `PanelSlider`. That component's `MouseArea`
adjusts on wheel without asking (`/usr/share/omarchy/shell/Ui/PanelSlider.qml:140`),
and it emits `moved` **and** `released` on every tick. The panel wires
`onMoved → commitPreamp` and `onReleased → sendPreampNow` (`Panel.qml:960-961`),
and `sendPreampNow` writes `headroom: "manual"` (`Panel.qml:309`).

So one accidental wheel tick over the preamp row does two things:

1. moves the preamp by `step` (0.5 dB), and
2. silently switches headroom from **auto** to **manual**, which stops the
   preamp from tracking the curve from then on.

The user-visible bug ("scrolling up and down accidentally changes the preamp
slide") is the first half; the second half is the worse half, because nothing on
screen says automatic headroom was just turned off. The same wheel also never
reaches the `ScrollView`, so the panel does not scroll at that moment — the
wheel disappears into the slider.

The ten band faders (`VerticalGainSlider.qml:207`, `HorizontalGainSlider.qml:147`)
do the same over the biggest target in the panel: the curve is 372 px tall
(`ResponseCurve.qml:86`) and its fader bank covers most of it, so the plot area
is a scroll trap too. There the wheel *is* a plausible gesture (vertical control,
vertical wheel), so the fix is not "remove it" but "arm it".

### 1.2 Every drag re-runs the whole response sweep three to four times

`Model.peakDb` (`Model.js:214`) walks 401 frequency points and calls
`responseDb` per point, which rebuilds every band's coefficients **per point** —
4010 coefficient builds for the ten-band case. Measured on this machine:

| Call | Time |
| --- | --- |
| `Model.peakDb(bands, 0, 48000)` | **11.9 ms** |
| `Model.autoPreampDb(bands, 48000)` | **11.8 ms** |
| `Model.responseSeries(chainCoefficients(…), …, 430)` | 2.0 ms |
| `chainCoefficients` + `responseSeries(…, 401)` (drop-in replacement for `peakDb`) | **1.9 ms**, bit-identical peak and frequency |

The panel reads `Model.peakDb` from `peakSummary` (`Panel.qml:100`), from
`postPreampPeak` (`Panel.qml:81`) and again through `limiterDucking` (`Panel.qml:89`),
and `autoPreampDb` through `autoPreamp` (`Panel.qml:314`). Every `withStatus(...)`
call clones the status object and reassigns it (`Panel.qml:289-295`), which
invalidates all of those bindings at once. A drag emits one local echo per
pointer move, so a single drag runs on the order of **35–46 ms of JavaScript per
pointer move** before the Canvas is even repainted. That is the stutter GitHub
issue #3 reports ("fader and handle animations lag noticeably and stutter while
dragging"), and it is not a rendering problem.

Fix is small and provable: compute the curve peak from `chainCoefficients` once,
cache the metrics on a band signature, and read the cache from the bindings.
Budget: **< 4 ms per drag tick**.

### 1.3 The panel is 8 sections and ~1100 px of content in a 760 px card

In graphic mode the column is: hero, meter, MODE, RESPONSE (372 px curve), the
folded-away BANDS section, PREAMPLIFIER, OUTPUT, PRESET, AUTOEQ
(`Panel.qml:644-1299`). Only two of those are the instrument; the rest are
setup. Consequences:

- The panel always scrolls, so §1.1's trap is always reachable.
- Mode is stated three times: hero summary "10-BAND · 10 BANDS ACTIVE"
  (`Panel.qml:153`), MODE section meta + segmented control
  (`Panel.qml:763,777`), and the mode caption ("31 Hz – 16 kHz, one octave per
  band", `Panel.qml:160`). The screenshot in `docs/panel.png` reads as
  repetitive for exactly this reason.
- PREAMPLIFIER is a whole collapsible section, separator and three-line
  wrapped caption (`Panel.qml:920-997`) for one 22 px slider that exists to
  serve the curve above it.
- AUTOEQ is a whole section (`Panel.qml:1214`) whose only output is a preset,
  yet it sits below the preset list, out of sight.
- Errors render at the very bottom of the scroll container (`Panel.qml:1298`),
  so a failed "Save preset" reports itself ~1100 px below the control that
  failed.
- The `e` / `m` / `r` shortcuts (`Panel.qml:621-625`) are undocumented in the
  panel and in the README; nothing announces them.

### 1.4 The level meter is a 5 px straight bar with no ballistics

`Panel.qml:718-755`: a track and a width-animated fill, one `Behavior on width
{ duration: 90 }`, plus a dB number. Peak-only, no decay, no scale, no zero
reference. At this size it reads as a progress bar — an outside reader of
`docs/panel.png` described it as "an unlabeled scrollbar". It also carries no
information the dB number does not, so the decoration earns nothing.

A waveform envelope of the same peak data carries the same number plus a sense
of dynamics, and it stops looking like a progress bar. See Phase 4.

### 1.5 Presets are 16 flat names ordered by a magic number

`bin/omarchy-equalizer:362` emits `{name, description, order, builtin}` from the
preset files. `order` (10, 20, …, 50) is a private encoding of a category that
exists only in the README prose (`README.md:274`). The panel renders a plain
`Dropdown` (`Panel.qml:1119`), so the user gets seventeen names in a menu with
no grouping, no filter, no favourites, and no indication that a user preset is
user-made beyond its position at the end. `description` is shown for the loaded
preset only (`Panel.qml:1170`), so auditioning means applying blind.

The shell ships `SearchableDropdown.qml`, which renders an option's
`description` under its label and filters as you type — it is the right control
for this list and needs no new code in the shell.

Adding to the list is also where the level-matching test bites: the set already
spans 2.3 dB of the 2.5 dB allowed (`tests/preset-levels.js:35`). A new preset
must land between −2.2 and −1.3 dB, not merely "within bounds".

### 1.6 Smaller items worth folding into the same work

- The ResponseCurve hit test uses a fixed 18–27 px radius
  (`ResponseCurve.qml:130`); two adjacent handles are ~40 px apart at 430 px
  wide, so a press can pick the neighbour. Prefer the nearer handle and shrink
  the radius when handles are closer than 2× it.
- Nothing on the curve is keyboard-reachable; `VerticalGainSlider` supports
  arrows only after a Tab focus it never advertises.
- The bar widget (`BarWidget.qml`) is a static glyph. It shows on/off but not
  clipping, and it cannot show level because `PwNodePeakMonitor` is only enabled
  while the panel is open (`Panel.qml:593`).
- `docs/presets.png` and `docs/panel.png` are stale against any layout change;
  the README embeds `docs/panel.png`.
- GitHub issue #1 (parametric edits restarting the graph) is implemented in the
  backend (`bin/omarchy-equalizer:643` LSP pool path) but the issue is still
  open; closing it needs the live rig in that issue, not this spec.

---

## 2. Target design

### 2.1 Panel layout (graphic mode, 430 × ≤760)

```
┌ Equalizer     10-BAND · 3 BANDS ACTIVE            [⏻] ┐  hero, fixed
│ ▁▂▅▃▂▁▃▅▇▅▃▂▁▂▄▆▅▃▂▁▂▃▅▄▂▁  (waveform envelope)  −14 dB │  meter, fixed
├──────────────────────────────────────────────────────┤
│ PRESET  [ Genre · Zouk                        ⌄ ] ⇄ ✕ │  1 row, fixed
├──────────────────────────────────────────────────────┤
│ RESPONSE   +5.8 dB PEAK AT 32 HZ      [10-band|Para] │  fixed
│                                                        │
│                  the curve + faders                    │  fixed (372 px)
│                                                        │
│  PREAMP  ──────●──────────────────  −3.0 dB   [auto]  │  fixed, one row
├──────────── scrolling controls below ────────────────┤
│ OUTPUT   LIMITER ON · BOOST OFF                       │
│ ADVANCED  Limiter · Magic boost · AutoEq import       │
└──────────────────────────────────────────────────────┘
```

Rules:

- **Fixed band** (never scrolls): hero, meter, preset row, response console,
  preamp row. In graphic mode this is the entire instrument.
- **Scrolling band**: OUTPUT and ADVANCED, both folded by default the first
  time; fold state keeps persisting to
  `~/.local/state/omarchy/settings/equalizer-panel.json` (existing mechanism,
  `Panel.qml:182-229`). Parametric mode's BANDS list joins the scrolling band.
- Section count: 3 visible headers (PRESET, RESPONSE, and one of
  OUTPUT/ADVANCED) instead of 6. MODE disappears as a section entirely: its
  control becomes a two-item `SegmentedControl` on the RESPONSE header line,
  its caption becomes the curve's tooltip.
- PREAMPLIFIER stops being a section: label + slider + value + `auto` button on
  one row inside RESPONSE, directly under the faders. The three-line caption
  becomes a `PanelToolTip` on the `auto` button plus one short line shown only
  when headroom is manual.
- AUTOEQ moves inside ADVANCED, next to the output stage (both are "set and
  forget").
- Errors and command feedback render in a fixed one-line status strip at the
  bottom of the panel, outside the scroll area, replacing `Panel.qml:1298`.
- Shortcut hints (`e` `m` `r`) appear in the tooltips of the controls they
  affect; no new hint row.

### 2.2 Input policy (one rule, everywhere)

| Control | Drag | Wheel | Keyboard |
| --- | --- | --- | --- |
| Preamp slider (horizontal) | yes | **never adjusts** — it scrolls the panel instead | ←/→ 0.5 dB when focused |
| Band fader (vertical) | yes | adjusts **only when focused** (clicked) or with `Alt` held; otherwise scrolls the panel | ↑/↓ 0.5 dB when focused |
| Curve handle | yes | n/a (the plot ignores wheel) | ←/→ select band, ↑/↓ 0.5 dB, `0` resets the selected band |
| Dropdown / fields | n/a | scrolls the panel | unchanged |

Mechanism (do not rely on wheel propagation: whether a declined wheel event
reaches the enclosing `Flickable` was not verifiable in this environment — see
the `mouseWheel` note in §0, and Qt's delivery order is not worth betting the
UX on):

- The panel exposes `scrollByDelta(dy)` which clamps and moves
  `scrollArea.contentItem.contentY` (respecting `originY`/`contentHeight`).
- Every plugin-owned slider takes `property var scrollBy` plus a pure
  `wheelOwns(angleDeltaY, modifiers, hasFocus)` predicate; on wheel it either
  adjusts (and accepts) or calls `scrollBy(dy)` (and accepts). Accepting in both
  branches keeps the event away from the Flickable, so nothing double-scrolls.
- The preamp slider stops using the shell's `PanelSlider`; ship
  `PreampSlider.qml` (visual copy of its track/knob, plugin-owned) so the policy
  is ours. Keep the shell's colours from `bar`/`Color` so it still matches.

### 2.3 Meter

Replace the straight bar with a symmetric waveform envelope drawn from the
existing `PwNodePeakMonitor` peak:

- `Model.waveSeries(peak, phase, count)` — pure, returns `count` values in
  `[-1, 1]`: `sin(2π(1.0·u + phase)) · 0.7 + sin(2π(2.7·u + 1.7·phase)) · 0.3`,
  windowed by `1 − 0.55·(2u − 1)²` so the ends taper, scaled by `peak`.
- `LevelWave.qml`: Canvas, height ~18–22 px, polyline mirrored about the
  midline into a filled ribbon. Colour: `barForeground` at 0.85, `Color.urgent`
  on clip hold. Right-aligned dB text stays exactly as today.
- Ballistics: attack instant, release `peakSmooth -= (peakSmooth − peak) * 0.18`
  per frame (≈250 ms to fall 90 %). Idle (`peakSmooth < 0.01`) draws a flat
  hairline at 35 % opacity and **stops the animation timer** — no fake motion,
  no idle CPU.
- Phase advances 0.045 per frame at 33 ms while open and audible. Timer runs
  only when `root.opened && root.enabled && peakSmooth > 0.01`.
- Optional (Phase 6, default off): the same series in the bar widget's icon
  area, 16 px tall, driven by the widget's own peak monitor.

---

## 3. Guardrails for every phase

- **Allowed to modify**: `Panel.qml`, `ResponseCurve.qml`, `Model.js`,
  `VerticalGainSlider.qml`, `HorizontalGainSlider.qml`, `CollapsibleSection.qml`,
  `SegmentedControl.qml`, `BarWidget.qml`, `presets/*.json`,
  `bin/omarchy-equalizer`, `tests/*`, `docs/*.png`, `README.md`, plus new files
  listed in the phase.
- **Never modify** `/usr/share/omarchy/**` (shell kit), or any file under
  `~/.config`, `~/.local/state`, `~/.config/pipewire`.
- **Never** `git commit`, `git push`, branch, stash, restore, or rebase.
- **Never** run the plugin against real audio. The only permitted commands are
  `bash tests/run-tests.sh`, `node tests/*.js`, and read-only `git`/`grep`.
- No new runtime dependency. QML stays on Qt Quick + `qs.*`; scripts stay
  bash/jq/awk/node.
- Keep the panel usable at `contentWidth` 430 and at the `availableCardHeight`
  of a 1366×768 screen (~560 px).
- Every phase ends with: (a) `bash tests/run-tests.sh` passing with the new
  count, (b) the phase's own acceptance check, (c) a "could not verify" list if
  anything needed a live shell.

---

## 4. Phases

The five phase briefs are pre-cut in `docs/brief-p1.md` … `docs/brief-p5.md`.
Run each phase as its own `dsh` invocation, from
`/home/creolben/Projects/omarchy-equalizer-pr4`:

```sh
dsh --profile headless "$(cat docs/brief-p1.md)"
```

### Phase 1 — take the sweep off the drag path (smallest, do first)

**Files:** `Model.js`, `Panel.qml`, `tests/run-tests.sh`, `tests/headroom-check.js`.

1. Add to `Model.js`:
   - `peakFromCoefficients(coeffs, rate, from, to, steps)` — same sweep grid as
     `peakDb` (401 points, 20–20000 Hz), same return shape `{db, freq}`, but
     built from `chainCoefficients` and `responseSeries` so coefficients are
     built once. `peakDb` must keep its signature and delegate to it, so
     `headroom-check.js` and `curve-check.js` stay valid and the values stay
     bit-identical (verified 2026-10-23: 1.6072 dB at 7736.2 Hz both ways).
     Add a test that asserts `peakDb` and `peakFromCoefficients` agree to 1e-9
     over three band sets (flat, one boost, shelves + high-pass).
   - `metrics(bands, sampleRate)` returning
     `{ peakDb, peakFreq, autoPreamp, shapedCount, signature }`, memoised on
     `signature` = type/freq/q/gain of every band plus the rate. The panel calls
     this once per status change instead of binding four separate sweeps.
     `Model.js` is stateless today; keep the cache a single-slot memo with an
     explicit `resetMetricsCache()` exported for tests.
2. In `Panel.qml`, replace the direct `Model.peakDb` / `Model.autoPreampDb` reads
   in `postPreampPeak` (`:81`), `preampMax` (`:62`), `peakSummary` (`:93`),
   `autoPreamp` (`:314`) with reads from one `readonly property var metrics:
   Model.metrics(bands, sampleRate)`.
3. Keep every displayed number identical; this phase changes no behaviour.
4. Add a measurement to `tests/run-tests.sh` (node, not a wall-clock gate):
   assert `metrics()` on the ten active bands takes < 3 ms per call averaged
   over 50 calls on a hot cache miss, and print the measured value. A hard
   wall-clock gate is fragile across machines — print, and gate only on the
   algorithmic count (`chainCoefficients` must be called exactly once per
   metrics computation; expose a counter for tests).

**Acceptance:** `bash tests/run-tests.sh` green with the new assertions;
`node tests/headroom-check.js` unchanged; paste the printed metrics timing in
the final answer.

### Phase 2 — input policy

**Files:** `Panel.qml`, `VerticalGainSlider.qml`, `HorizontalGainSlider.qml`,
new `PreampSlider.qml`, new `tests/input-policy-check.js`, `tests/run-tests.sh`,
`README.md` (one paragraph).

1. Add `wheelOwns(angleDeltaY, modifiers, hasFocus)` to `Model.js`-adjacent
   policy or as a `function` in each slider — one implementation, imported from
   `Model.js` (`Model.wheelOwns(kind, modifiers, hasFocus)`), returning `true`
   only when `kind === "fader"` and (`hasFocus` or `modifiers & Qt.AltModifier`).
   `kind === "preamp"` always returns `false`.
2. All three sliders: on wheel, if `wheelOwns` is false call
   `scrollBy(-angleDelta.y / 2)` and accept; otherwise adjust by one `step` and
   commit (no `released` on every tick for the preamp — the preamp no longer
   takes wheel at all).
3. `Panel.qml`: add `scrollByDelta(dy)` and inject it into the sliders it owns;
   keep the ScrollView's own wheel scrolling for the rest of the surface.
4. New `PreampSlider.qml`: track + fill + knob matching `PanelSlider`'s look at
   `bar.foreground` colours, `value/minimum/maximum/step`, `moved`/`released`/
   `rightClicked` signals, arrow keys when focused, and the policy from (2).
   Replace `PanelSlider` at `Panel.qml:945`. It must show a visible focus ring
   (2 px `Color.accent` at 40 %) and only then accept arrow keys.
5. `tests/input-policy-check.js` (node, no Qt): load `Model.js`, assert the rule
   table in §2.2 exactly — preamp never owns; fader owns only with focus or Alt;
   zero/negative deltas behave; unknown kinds return false.
6. README: document the policy in the panel section ("the wheel scrolls the
   panel; hold Alt over a fader, or click it first, to nudge a band").

**Acceptance:** policy test green; suite green; and a **manual** live check
recorded in the final answer: with the panel open, wheel over the preamp row
scrolls the panel and leaves `headroom` at `auto` (`omarchy-equalizer status |
jq .headroom` before/after). That check is the one thing that cannot be
automated here — if the agent cannot run the live shell, say so instead of
claiming it.

### Phase 3 — reorganise the panel

**Files:** `Panel.qml`, `ResponseCurve.qml` (header only), `CollapsibleSection.qml`
(only if a header accessory slot is missing), `README.md`, `docs/panel.png`.

Do this in the order below; each numbered item is independently testable by eye
against the acceptance list.

1. **Fixed header + scrolling body.** Inside `PanelKeyCatcher`, wrap in a
   `Column`: `Item { id: instrument }` holding hero, meter, preset row, RESPONSE
   section and the preamp row; then `ScrollView` holding OUTPUT, BANDS
   (parametric), ADVANCED. `contentHeight` becomes
   `panel.fittedContentHeight(instrument.implicitHeight + controlColumn.implicitHeight + spacing, Style.space(760))`
   and the ScrollView gets `height: Math.max(0, contentHeight - instrument.implicitHeight - spacing)`
   so the card still shrinks when content is short. Keep
   `ScrollBar.vertical.policy` and the `interactive` binding in step with the
   new scroll area.
2. **Mode into the RESPONSE header.** Remove the MODE `CollapsibleSection`.
   Put a compact two-item `SegmentedControl` (labels "10-band" / "Parametric")
   right-aligned on the RESPONSE header row, and move `modeMeta` into a
   `PanelToolTip` on it. Delete the duplicated mode label in the hero summary
   (`Panel.qml:153`) — hero keeps "N BANDS ACTIVE" / "FLAT" / "BYPASSED".
3. **Preamp into the RESPONSE body.** One row under the faders: caption
   "PREAMP", `PreampSlider`, right-aligned `−3.0 dB`, and the existing `auto`
   button. Delete the PREAMPLIFIER section, its separator, its scale repeater
   and its three-line caption; keep `preampMarks` only if the scale still has a
   place in the one-row form (it does not — drop it and keep the ceiling in the
   slider tooltip).
4. **OUTPUT + AutoEq into one ADVANCED section** below the scroll line, folded
   by default on a fresh install (`advancedCollapsed: true` in the default UI
   state, and migrate an existing settings file that lacks the key).
5. **Fixed status strip.** One-line strip pinned at the panel bottom, outside
   the scroll area, showing `error` (urgent) or the last `autoeqMessage`;
   auto-clears after 8 s. Remove the bottom-of-scroll error text.
6. **Discoverability.** Tooltips: power switch "Bypass (e)", mode control
   "Mode (m)", reset "Flatten bands (r)".
7. Refresh `docs/panel.png` with the new layout at 430 px width; update the
   README's panel paragraph if it names sections.

**Acceptance:** at 430 px width in graphic mode, with ADVANCED folded, the panel
shows hero, meter, preset row, curve, faders and preamp **without scrolling**
(verify by asserting in code that `instrument.implicitHeight + preset row +
slack ≤ 760`, and eyeball the screenshot). Curve, faders and preamp do not move
when the body scrolls. Parametric mode scrolls to its band rows. No text is
truncated at 430 px. Panel height on a 768 px-tall screen leaves the card
inside the screen.

### Phase 4 — waveform meter

**Files:** `Model.js`, new `LevelWave.qml`, `Panel.qml`, `tests/wave-check.js`,
`tests/run-tests.sh`, `docs/panel.png`.

1. `Model.waveSeries(peak, phase, count)` per §2.3, plus
   `Model.waveEnvelope(peakSmooth, previous, attack, release)` if a helper keeps
   the QML binding thin. Pure numbers only; no Qt.
2. `LevelWave.qml`: `property real peak`, `property bool active`
   (`opened && enabled`), `property color foreground`, `property color urgent`,
   `property bool clipped`. Canvas repaint on phase/peak; animation Timer 33 ms,
   `running: active && peakSmooth > 0.01`. Height 20 px, full width. Tapers to
   the hairline when idle. Mirrored filled ribbon, not a stroke, so it reads at
   20 px.
3. `Panel.qml`: replace the meter row (`:718-755`) with `LevelWave` + the
   existing dB text. Keep `clipHeld` logic; feed `clipped: clipHeld ||
   peak > 0.98`.
4. `tests/wave-check.js`: bounds (`|v| ≤ peak` for every sample), silence →
   all zeros, monotonic in `peak`, phase changes the series but not the
   envelope bounds, `count` clamped to ≥ 8, determinism for fixed inputs. Add
   to `run-tests.sh`.
5. Consider a QML test for `LevelWave` in `tests/qml/` only if it can avoid
   importing shell modules that are not stubbed; otherwise skip and say so.

**Acceptance:** wave tests green; suite green; `docs/panel.png` shows the wave
at rest and (manually) while audio plays. Report the measured CPU cost of one
second of animation if measurable (`qmlprofiler` optional).

### Phase 5 — preset organisation

**Files:** `presets/*.json` (add `category`), `bin/omarchy-equalizer`
(`preset_list_json`), `Panel.qml`, `tests/preset-levels.js`, `README.md`,
`docs/presets.png`.

1. Add `"category"` to every built-in preset: `reference` (Flat), `tone`
   (Bass Boost, Treble Boost, Loudness, Warm Speakers), `genre` (Rock, Pop,
   Dance, Jazz, Classical, Vocal, Zouk, Kompa), `speech` (Podcast, Speech
   Clarity), `situation` (Late Night, Gaming, Small Speakers). Validate it in
   `tests/preset-levels.js` against that closed set and against the `order`
   band (10 → reference, 2x → tone, 3x → genre, 4x → speech, 5x → situation) so
   the two can never drift.
2. `preset_list_json` (`bin/omarchy-equalizer:362`) adds `category` to each
   entry, and keeps emitting `order`.
3. `Panel.qml`: `Dropdown` → `SearchableDropdown` for the preset picker.
   Options become `{ value: name, label: categoryLabel + " · " + name,
   description: preset.description }`. `presetOptions()` already exists; extend
   it. Keep the delete button, keep the loaded-preset description line.
4. Add an "edited" cue: when `bands` differ from the loaded preset's bands,
   the section meta reads `ZOUK · EDITED`. Compute it in the panel from a
   `presetSignature` the backend includes in `status` (add it: a hash of the
   applied preset's bands) — if that is too much, compare against nothing and
   skip the cue rather than guessing.
5. `tests/preset-levels.js` gains: category presence/validity, category↔order
   agreement, unique names, and a guard that the set still contains exactly one
   `reference`. Keep the spread gate.
6. README: preset table gains a Category column; the prose stops explaining
   `order` as a category proxy. Refresh `docs/presets.png`.

**Acceptance:** preset-levels green with the new assertions and the spread still
≤ 2.5 dB; the picker filters on typing ("zou" finds Zouk, "compas" finds Kompa
via its description) — verify by reading `SearchableDropdown`'s filter code,
which matches label and description; suite green.

### Phase 6 — regression test for issue #3, then optional extras

**Files:** `tests/qml/tst_responsecurve.qml` (new), `tests/run-tests.sh`,
optional `BarWidget.qml`, `docs/spec-v2.md` (mark done).

1. Issue #3 test: instantiate `ResponseCurve` offscreen with the existing
   `tests/qml/imports` stubs (add whatever `qs.*` stubs it needs — `Color`,
   `Style`, `BorderSurface`, and a `PanelToolTip` stub), set a ten-band array,
   call the press path with a synthetic press at band 2's handle, and assert the
   drawn handle's x maps to `bands[2].freq` (expose a small read-only helper
   such as `handleXFor(index)` if needed — exposing a pure getter for tests is
   allowed and preferred over asserting on Canvas pixels). This test must fail
   on the pre-fix ordering and pass after it.
2. Optional, only if 1–5 are green and time remains: bar-widget peak pulse
   behind a setting, default off.

---

## 5. Deliberately out of scope

- GitHub issue #1's live rig (parametric edits without a restart) — backend
  already implements the 16-slot pool; closing the issue needs real playback
  measurement on the user's machine, not a code change.
- A/B compare, undo, per-output preset binding, EQ presets from a remote
  catalogue — all reasonable, none of them this spec. Do not invent them.
- Any change to `host/omarchy-equalizer.conf`, the filter-chain fragment
  generator, or the follow service. This spec is panel, model, presets and docs.

---

## 6. Definition of done for the whole spec

- Suite green, assertion count reported, preset spread ≤ 2.5 dB.
- Dragging a band at 60 Hz pointer movement spends < 4 ms of JavaScript per
  event (measured via the counter from Phase 1, reported).
- Wheel over the preamp row never changes `preamp` and never changes `headroom`.
- Panel shows the instrument without scrolling in graphic mode and fits a
  768 px screen.
- Meter is a waveform that stops animating when silent.
- Zouk and Kompa are in the list with categories, searchable, level-matched.
- README and `docs/*.png` match the shipped panel.
