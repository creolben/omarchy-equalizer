# Phase 5 — presets you can find: categories, search, edited cue

You are working in `/home/creolben/Projects/omarchy-equalizer-pr4` (branch
`pr-4-audit`). Omarchy shell plugin: QML panel + bash backend
(`bin/omarchy-equalizer`). Phases 1–4 are landed (metrics memo, wheel policy,
reorganised panel, waveform meter).

Read `docs/spec-v2.md` §1.5 and §3 first. The working tree is dirty on purpose;
do not revert, reformat or commit anything. No git operations.

## Why

`bin/omarchy-equalizer`'s `preset_list_json` emits `{name, description, order,
builtin}`. `order` (10, 20, …, 50) encodes a category that exists only in README
prose. The panel renders a plain `Dropdown`, so the user gets seventeen
ungrouped names, no filter, and a description only for the loaded preset —
auditioning means applying blind. User presets land at the end with no marker.

The shell already ships `SearchableDropdown.qml` (read-only): it filters on both
label and description, and renders `description` under each label. Use it.

## 1. Preset files gain an explicit category

Add `"category"` to every file in `presets/`, placed after `"order"`:

| Category | Order band | Presets |
| --- | --- | --- |
| `reference` | 10–19 | Flat |
| `tone` | 20–29 | Bass Boost, Treble Boost, Loudness, Warm Speakers |
| `genre` | 30–39 | Rock, Pop, Dance, Jazz, Classical, Vocal, Zouk, Kompa |
| `speech` | 40–49 | Podcast, Speech Clarity |
| `situation` | 50–59 | Late Night, Gaming, Small Speakers |

Do not change any gain, preamp, description or order value. This is metadata
only; applying a preset must behave identically.

## 2. `tests/preset-levels.js` validates the new field

Extend the per-file checks (it already validates name/description/order):

- `category` is present and one of the five values above.
- The category agrees with the order band (`Math.floor(order / 10)` → 1, 2, 3,
  4, 5 maps to the table). This is the guard that stops the two encodings
  drifting apart.
- Exactly one preset is `reference`, and it is Flat.
- Names are unique across a directory run.
- Print the category in the per-preset line so the table is visible when the
  test runs.

Keep every existing bound (level, peak, range, spread ≤ 2.5 dB) and the current
109-assertion behaviour otherwise.

## 3. Backend: `category` in the preset list

In `preset_list_json` (`bin/omarchy-equalizer`, the `jq -c -s` map that builds
`builtin_json`), emit `category: (.category // "other")`. Leave the sort key
`(.order, .name)`. User presets get `category: "user"` in the same shape.

Then add `presetDirty` to the `status` document:

- `true` when the active band set differs from the bands of the preset named in
  `state.preset` (compare as JSON: active bands for the current mode vs the
  preset's `graphic`/`parametric` array), `false` otherwise.
- `false` for a preset that no longer resolves (deleted file, `"Custom"`), so a
  missing preset never reads as "edited".
- `false` when the preset **does not define** bands for the active mode (a
  graphic-only preset viewed in parametric mode says nothing about that mode, and
  must not read as edited). Handle the absent key explicitly — an absent array
  compared against a non-empty one is a false "edited" on every poll.
- Compare values, not formatting: use `jq` equality on parsed arrays, and
  ignore `order`/`description`.
- `cmd_status` already has the state (`$s`) and the preset list (`$p`) in one `jq`;
  add the resolved preset's bands as another `--argjson` argument (one
  `preset_read` call, not one per band) rather than a second pass over the list.
- Cover it in `tests/run-tests.sh`: apply a preset → `presetDirty == false`;
  change one band gain → `true`; change it back → `false`; delete the preset →
  `false`; a graphic preset while `mode == "parametric"` → `false`.

## 4. Panel: searchable, grouped picker

- Swap the preset `Dropdown` for `SearchableDropdown` (import it the same way
  the shell's panels do — `import qs.Ui` is already in `Panel.qml`).
  Its surface, so you do not have to guess: `label`, `value`, `options`,
  `triggerLabel`, `placeholderText` (default "Search..."), `emptyText`,
  `foreground`, `background`, `popupBorder`, `accent`, `fontFamily`,
  `rowHeight`, `popupRowHeight`, `popupMinHeight`, `showLabel`, and
  `signal changed(string value)`. Options are read through
  `optionValue(o)`, `optionLabel(o)`, `optionDescription(o)`; the filter matches
  value, label and description case-insensitively.
- `triggerLabel` is how the trigger shows the bare preset name while the popup
  rows show the prefixed labels — use it rather than a second options array.
- `presetOptions()` returns `{ value: name, label: "<Category> · <Name>",
  description: <preset.description> }`:
  - Category label capitalised from the backend's `category`
    (`genre` → "Genre", `user` → "Yours").
  - `value` stays the bare preset name — everything downstream (apply, delete,
    status comparisons) uses it.
- The trigger should show the loaded preset's name without the category prefix
  (the category is a scanning aid, not part of the identity); the popup shows
  the prefixed labels.
- Keep the delete button, the reset button and the save field exactly as they
  are, but re-check their enable/disable logic still reads `value` correctly.
- With `presetDirty === true`, the PRESET row's meta shows `· EDITED` after the
  name. With `false`, nothing extra.

## 5. Docs

- README: the preset table gains a Category column; the paragraph that explains
  `order` as a stand-in for categories is rewritten to describe the explicit
  field. Mention that the picker filters on name and description.
- `docs/presets.png` refresh if the panel can be rendered here; otherwise say it
  was not.

## Verification

1. `node tests/preset-levels.js` → 0 failures, new assertions counted, spread
   still ≤ 2.5 dB, and the per-preset lines show categories.
2. `bash tests/run-tests.sh` → record the starting count, finish with
   `start + <new assertions>` and 0 failed (~200 s). This suite also asserts
   that each preset declares the preamp its own curve needs — it must stay
   green, which proves the metadata edit did not disturb the curves.
3. `run status | jq -r '.presets[] | "\(.category)\t\(.name)"'` under the suite's
   stubs (not the live session) shows every preset with its category.
4. `node tests/metrics-check.js`, `node tests/wave-check.js`,
   `node tests/input-policy-check.js` → green.

## Hard rules

- Never run `apply-preset`, `save-preset`, `import-autoeq` or anything else
  mutating against the live session; the suite's stubs are the only sanctioned
  path. Do not touch `~/.local/state` or `~/.config`.
- Do not change preset curves, preamps or the level-matching bounds. If a
  category edit makes a test fail, the metadata is wrong, not the test.
- Do not modify `/usr/share/omarchy/**`.
- User presets must keep working: a `presets.json` entry with no `category` is
  valid and shows as "Yours".

## Report back

- The category table as shipped, and the assertion count before/after.
- The exact `presetDirty` rule, including what happens for `"Custom"` and for a
  preset whose file was deleted.
- What you could not verify (screenshot, live picker interaction), stated
  plainly.
