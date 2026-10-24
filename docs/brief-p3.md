# Phase 3 — reorganise the panel around the instrument

You are working in `/home/creolben/Projects/omarchy-equalizer-pr4` (branch
`pr-4-audit`). Omarchy shell plugin: QML panel (`Panel.qml`, `ResponseCurve.qml`,
`Model.js`, `CollapsibleSection.qml`, `SegmentedControl.qml`, sliders) over a bash
backend (`bin/omarchy-equalizer`).

Read `docs/spec-v2.md` §1.3, §2.1 and §3 first. Phases 1 and 2 are landed:
`Model.metrics()` exists and every slider obeys the wheel policy from §2.2
(including a `scrollBy` passthrough). Keep both intact.

The working tree is dirty on purpose. Do not revert, reformat, or commit
anything. No git operations beyond read-only inspection.

## Why

The panel is eight sections and roughly 1100 px of content in a 760 px card, so
it always scrolls and the instrument (curve + faders) drifts away while the user
is adjusting setup. Mode is stated three times (hero meta, MODE meta, mode
caption). PREAMPLIFIER is a whole section for one slider that exists to serve the
curve. AUTOEQ is a section whose only product is a preset, placed below the
preset list. Errors surface at the bottom of the scroll container.

## Target

Fixed band, never scrolls, in this order:

1. hero (title, summary, power switch)
2. level meter (the existing one until Phase 4 replaces it — do not redesign it
   here)
3. PRESET row: picker (still `Dropdown` in this phase; Phase 5 makes it
   searchable), reset, save, delete. The **picker must never scroll away**; the
   save-name field and its button are allowed to live in a folded secondary row
   (or stay in the section body) if the one-row form does not fit the arithmetic
   in step 4. Reset and delete stay on the picker row.
4. RESPONSE console: header line "RESPONSE | <peak summary> | [10-band |
   Parametric]" with the auto-headroom button as the section accessory, then the
   curve and faders, then one PREAMP row under them

Scrolling band below:

5. BANDS (parametric mode only)
6. OUTPUT (limiter, Magic boost)
7. ADVANCED (AutoEq import), folded by default

Plus a one-line status strip pinned at the very bottom, outside the scroll area.

Section headers drop from six to three visible ones.

## Do it in this order, verifying each step

### Step 1 — split the card into a fixed band and a scrolling band

Current structure: `PanelKeyCatcher` → `ScrollView` → `Column { id: contentColumn }`
holding everything, with `contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(760))`.

Restructure to (names are suggestions, keep the file's comment style):

```qml
PanelKeyCatcher {
  Column {
    id: card
    anchors.fill: parent
    spacing: Style.spacing.lg

    Item {
      id: instrument
      width: parent.width
      implicitHeight: instrumentColumn.implicitHeight
      Column { id: instrumentColumn; width: parent.width; spacing: /* the spacings the sections had */ }
    }

    ScrollView {
      id: scrollArea
      width: parent.width
      // Deterministic, no binding loop: bounded by what the fixed band leaves.
      height: Math.min(controlColumn.implicitHeight,
                       Math.max(0, Style.space(760) - instrument.implicitHeight - card.spacing))
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      Column { id: controlColumn; width: scrollArea.availableWidth; spacing: … }
    }

    /* status strip */
  }
}
```

`panel.contentHeight: panel.fittedContentHeight(instrument.implicitHeight +
scrollArea.height + strip.height + card.spacing * (strip visible ? 2 : 1),
Style.space(760))`.

Careful points, all of which will bite if missed:

- `scrollArea.availableWidth` keeps the full 430 px content width; do not let a
  scrollbar inset shrink the instrument band relative to the controls.
- Keep the existing `ScrollBar.vertical.policy` binding and the `interactive`
  binding attached to the new `scrollArea`.
- The preamp slider's `scrollBy` injection must point at `scrollByDelta`, which
  now clamps against `scrollArea.contentItem`.
- Anything that used `contentColumn` by id (keyboard cursor state, fold state
  writes, `Component.onCompleted`) must be updated, not left dangling.

**Acceptance for this step:** the panel still opens, all controls still work,
`bash tests/run-tests.sh` unchanged.

### Step 2 — mode into the RESPONSE header, MODE section deleted

- Delete the MODE `CollapsibleSection` and its caption/segmented control.
- Put a compact `SegmentedControl` with two options
  `[{ value: "graphic", label: "10-band" }, { value: "parametric", label: "Parametric" }]`
  on the RESPONSE header line, right-aligned, next to the peak summary. Use the
  section's existing accessory slot if it fits, otherwise place it in the header
  `Row` — `CollapsibleSection` exposes `accessory` for exactly this.
- `modeMeta` ("31 Hz – 16 kHz, one octave per band") becomes a `PanelToolTip` on
  that control, not a body caption.
- Hero summary drops the leading "10-BAND · " (`Panel.qml`, the `summary` /
  hero meta binding). Hero keeps the band count / FLAT / BYPASSED text.
- The `m` shortcut must still toggle the mode, and the section must not lose its
  header meta.

**Acceptance:** mode switches from the header; no text says the mode twice;
parametric band rows still appear in the scrolling band.

### Step 3 — preamp becomes one row inside RESPONSE

Replace the PREAMPLIFIER section with a single row directly under the faders:

```
PREAMP   [──────●────────────]   −3.0 dB   [auto]
```

- Keep `commitPreamp` / `sendPreampNow` / the auto button's existing semantics
  and tooltips; keep the `headroom === "manual"` short hint as a one-line caption
  **only when manual** (auto shows nothing).
- Delete the PREAMPLIFIER section, its `PanelSeparator`, its `preampScale`
  repeater and the three-line wrapped caption. If `preampMarks` loses its last
  reader, delete it too (and any test that names it in `run-tests.sh` grep
  assertions — update, do not silently break).
- The ceiling number must remain discoverable: the slider's tooltip and the auto
  button's tooltip both state it.

**Acceptance:** the preamp still moves by drag and arrows, still cannot exceed
the curve's ceiling, still flips to manual on a deliberate drag, and the fixed
band grows shorter by roughly 90–110 px.

### Step 4 — OUTPUT and AutoEq into one ADVANCED section

- Move the AutoEq block (query field, import button, message) into the OUTPUT
  section, rename that section `ADVANCED`, and fold it by default on a fresh
  install: add `advancedCollapsed` to the persisted UI state defaults **and**
  migrate an existing settings file that lacks the key (read the existing state
  file shape first; an unknown key must default to `true`, not `false`).
- OUTPUT's current meta text ("LIMITER ON · BOOST OFF") stays as the collapsed
  summary — it is the whole point of a folded section.
- If the section no longer fits one foldable body cleanly, keep OUTPUT's two
  controls in the body and AutoEq as a compact third row; do not create a fourth
  section.

**Acceptance:** with ADVANCED folded the panel shows hero, meter, preset row,
curve, faders and preamp **without any scrolling** at 430 px width in graphic
mode. Verify by arithmetic on the implicit heights and state the numbers in the
report (instrument height + one folded header must be < 760).

### Step 5 — status strip

A one-line `Item` pinned below `scrollArea`, height 0 when empty (no reserved
gap), showing `root.error` in `Color.urgent` or the last `autoeqMessage` in dim
foreground, auto-clearing after 8 s. Remove the error `Text` that currently sits
at the bottom of the scrolling column. Do not swallow errors: a failed command
must still be visible while the panel is open.

### Step 6 — discoverability

Tooltips (the kit's `PanelToolTip`): power switch "Bypass (e)", mode control
"Mode (m)", preset reset "Flatten bands (r)". No hint row, no new text in the
body.

### Step 7 — docs

- Refresh `docs/panel.png` from the running panel at 430 px width (the README
  embeds it). If the shell cannot be run in this environment, keep the old
  image and say so — do not fake a screenshot.
- Update the README's panel paragraph if it names sections that no longer exist.

## Verification

1. `bash tests/run-tests.sh` → record the starting baseline count, finish with
   `baseline ± <changes>` and 0 failed. Allow ~200 s.
2. `node tests/metrics-check.js`, `node tests/input-policy-check.js`,
   `node tests/preset-levels.js`, `node tests/headroom-check.js` → all green.
3. Arithmetic check for the no-scroll acceptance in step 4, printed.
4. No QML warnings in the shell's log when the panel opens (if you can run the
   shell; otherwise say you could not).

## Hard rules

- Do not change DSP behaviour, `bin/omarchy-equalizer`, `host/*.conf`, or
  `ResponseCurve.qml`'s drawing code. This phase is layout only.
- Do not modify `/usr/share/omarchy/**`.
- No git operations. No new dependencies.
- If a step would require redesigning more than the brief describes, stop after
  the last completed step, leave the tree consistent and tests green, and report
  where you stopped and why. A green step 3 is worth more than a broken step 5.

## Report back

- What each step changed, with the section list before and after.
- The measured/arithmetic panel heights for step 4.
- Every id or binding that had to move, so the next phase knows where things are.
- Anything not verified (screenshot, live shell), stated plainly.
