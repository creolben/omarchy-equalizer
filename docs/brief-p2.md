# Phase 2 — one input policy: the wheel scrolls, it does not edit

You are working in `/home/creolben/Projects/omarchy-equalizer-pr4` (branch
`pr-4-audit`). Omarchy shell plugin: QML panel (`Panel.qml`, `ResponseCurve.qml`,
`Model.js`, slider widgets) over a bash backend (`bin/omarchy-equalizer`).

Read `docs/spec-v2.md` §1.1, §2.2 and §3 before starting. Phase 1 (metrics memo)
is already landed: `Model.metrics(bands, sampleRate)` exists and the panel reads
`metrics.peakDb` / `metrics.autoPreamp` from it. Do not redesign that.

The working tree is dirty on purpose (README, `ResponseCurve.qml`,
`presets/Zouk.json`, `presets/Kompa.json`, `docs/*.md`). Do not revert, reformat
or commit anything. No git operations beyond read-only inspection.

## The bug being fixed

`Panel.qml` builds the preamp slider from the shell's `PanelSlider`
(`/usr/share/omarchy/shell/Ui/PanelSlider.qml`, read-only, do not modify). Its
`MouseArea.onWheel` (line 140 there) adjusts the value and emits `moved` **and**
`released` on every tick. The panel wires `onMoved → commitPreamp` and
`onReleased → sendPreampNow`, and `sendPreampNow` writes `headroom: "manual"`.

So one accidental wheel tick while scrolling the panel moves the preamp 0.5 dB
**and silently turns automatic headroom off**. The user-visible report is
"scrolling up and down accidentally changes the preamp slide".

The band faders (`VerticalGainSlider.qml`, `HorizontalGainSlider.qml`) consume
the wheel too, and they cover most of the 372 px curve area — the plot is a
scroll trap.

## Target policy (the table is the contract)

| Control | Drag | Wheel | Keyboard |
| --- | --- | --- | --- |
| Preamp slider (horizontal) | yes | **never adjusts**; scrolls the panel | ←/→ 0.5 dB when focused |
| Band fader (vertical) | yes | adjusts **only** when it has active focus (clicked) or `Alt` is held; otherwise scrolls the panel | ↑/↓ 0.5 dB when focused |
| Parametric row fader | yes | same rule as the band fader | same |
| Everything else | unchanged | unchanged | unchanged |

A horizontal control under a vertical wheel is never a deliberate edit; a
vertical fader under a vertical wheel can be, but only when the user has aimed
at it (focus) or declared intent (Alt).

## Implementation

### 1. `Model.js` — the rule as a pure function

```js
// Which control, if any, a wheel event belongs to. One implementation, so the
// sliders cannot drift from each other or from tests/input-policy-check.js.
function wheelOwns(kind, modifiers, hasFocus) { … }
```

- `kind` is `"preamp"` or `"fader"`. `"preamp"` always returns `false`.
- `"fader"` returns `true` when `hasFocus` is true, or when `modifiers` has the
  `AltModifier` bit (Qt.AltModifier === 0x08000000; accept the numeric bit so
  node tests can pass it without Qt).
- Anything else (unknown kind, `kind` undefined, wheel with zero vertical
  delta) returns `false`.
- Keep no other state. Add it near the other small predicates.

### 2. Sliders — never rely on wheel propagation

Whether a declined wheel event reaches the enclosing `Flickable` could not be
verified in this environment (the Qt `mouseWheel` test helper is a no-op in this
build), so **do not depend on it**. Instead:

- Each slider gains `property var scrollBy: null` (a callable the panel injects)
  and, in `onWheel`, either adjusts (one `step`, then the usual moved+commit) or
  scrolls; in **both** branches set `wheel.accepted = true` so the event cannot
  also reach the Flickable:

```qml
onWheel: function(wheel) {
  if (!Model.wheelOwns("fader", wheel.modifiers, root.activeFocus)) {
    if (root.scrollBy) root.scrollBy(-wheel.angleDelta.y / 2)
    wheel.accepted = true
    return
  }
  root.nudge(wheel.angleDelta.y > 0 ? root.step : -root.step)
  wheel.accepted = true
}
```

- Focus is click-only: set `activeFocusOnTab: false` on the faders (ten tab
  stops through the plot is worse than none) and call
  `root.forceActiveFocus()` from the MouseArea's `onPressed`. Draw a visible
  focus state — 1–2 px `Color.accent` at ~40 % opacity around the fader track —
  so "focused" is not invisible. Arrow keys keep working as they do today.
- `Root.hot`/hover styling must not be confused with focus: hover is cosmetic,
  focus is what arms the wheel.

### 3. `PreampSlider.qml` — plugin-owned, wheel-free

The plugin already owns `VerticalGainSlider.qml` and `HorizontalGainSlider.qml`,
so owning a horizontal slider is consistent, and it is the only way to change
the wheel policy of a shell component we may not edit.

- Visual copy of `PanelSlider`'s track/fill/knob at the same metrics
  (`trackHeight`, `knobSize`, `implicitHeight` from `Style`), coloured from
  `bar` / `Color` exactly as today, so the panel still looks like the shell.
- API: `value`, `minimum`, `maximum`, `step`, `bar`, `moved(real)`,
  `released(real)`, `rightClicked()`, `scrollBy`.
- Wheel: never adjusts (call `scrollBy`, accept). Left-drag adjusts; right-click
  emits `rightClicked`; ←/→ nudge by `step` when focused; focus ring as above.
- Replace `PanelSlider` at the preamp in `Panel.qml` and delete the now-unused
  `import` if it was only for that.

### 4. `Panel.qml` — the scroll path

```qml
function scrollByDelta(dy) {
  var f = scrollArea.contentItem
  if (!f) return
  var max = Math.max(0, f.contentHeight - f.height)
  f.contentY = Math.max(0, Math.min(max, f.contentY + dy))
}
```

Inject `scrollBy: function(dy) { root.scrollByDelta(dy) }` into every plugin
slider the panel instantiates, including the ones inside `ResponseCurve`: add a
`property var scrollBy` passthrough on `ResponseCurve.qml` that forwards to its
own inner faders (a one-line property plus wiring — that file is otherwise out
of scope in this phase). If a fader ends up without a `scrollBy`, it must still
not adjust when unarmed; scrolling simply does nothing there.

Also fix the neighbouring foot-gun: `sendPreampNow` should not flip
`headroom` to `"manual"` when the requested value **equals** the current preamp
and headroom is already `"auto"` — a click that lands on the current value must
not silently disable automatic headroom.

### 5. Tests

New `tests/input-policy-check.js` (node, same style as the other `tests/*.js`:
`PASS`/`FAIL` lines, `N passed, M failed`, exit code):

1. `wheelOwns("preamp", 0, true) === false` (focused or not, with or without Alt).
2. `wheelOwns("fader", 0, false) === false`.
3. `wheelOwns("fader", 0, true) === true`.
4. `wheelOwns("fader", <Alt bit>, false) === true`.
5. `wheelOwns(undefined, …)`, `wheelOwns("fader", 0, undefined)` behave as `false`.
6. The other modifier bits alone (Shift, Ctrl, Meta) do not arm a fader.

Add to `tests/run-tests.sh`, following the existing idiom, plus these
structural guards (the suite already asserts QML invariants by grep):

```sh
echo "== the preamp slider is plugin-owned and cannot take the wheel =="
check "the preamp slider is the plugin's own component" "yes" \
  "$(grep -q 'PreampSlider' "$here/../Panel.qml" && echo yes || echo no)"
check "the shell's wheel-adjusting PanelSlider is no longer used" "0" \
  "$(grep -c 'PanelSlider' "$here/../Panel.qml")"
```

### 6. README

One short paragraph in the panel/interaction section: "The wheel scrolls the
panel. Over a band fader it nudges the band instead — hold Alt, or click the
fader first, to arm it. The preamp only moves by dragging or with the arrow
keys, because a vertical wheel over a horizontal control is never a deliberate
edit."

## Verification

1. `node tests/input-policy-check.js` → 0 failures.
2. `bash tests/run-tests.sh` → record the count printed at the start of the run
   (the pre-Phase-2 baseline: whatever Phase 1 left) and finish with
   `baseline + <new assertions>` and 0 failed. Allow ~200 s.
3. `node tests/preset-levels.js` and `node tests/headroom-check.js` unchanged.
4. Grep check: no `PanelSlider` remains in `Panel.qml`.

## Hard rules

- Never run the plugin's mutating commands or `pactl`/`systemctl` against the
  live session; the suite's stubs are the only sanctioned way to run the
  backend.
- Do not modify `/usr/share/omarchy/**`. Do not modify
  `host/omarchy-equalizer.conf` or `bin/omarchy-equalizer` in this phase.
- Do not touch `ResponseCurve.qml` beyond the `scrollBy` passthrough.
- If the brief disagrees with the code, trust the code, do the equivalent
  correct thing, and say what you changed in your report.

## Report back

- The policy function as shipped, and every file that now honours it.
- The exact wheel handler in the preamp slider.
- New assertion count from `run-tests.sh` and the grep results.
- **State plainly that the live check was not performed** (it needs the running
  Omarchy shell): with the panel open, wheel over the preamp row must scroll the
  panel and leave `omarchy-equalizer status | jq -r .headroom` at `auto`. Do not
  claim it passed.
