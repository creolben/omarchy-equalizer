# Equalizer

An Omarchy shell plugin that puts a system-wide equalizer in front of any PipeWire
output: a 10-band graphic EQ, up to 16 parametric bands, level-matched presets,
AutoEq headphone import, automatic headroom, and an output stage (brickwall
limiter plus a multiband "Magic Boost" compressor).

<p align="center">
  <img src="docs/panel.png" width="430" alt="The equalizer panel: power switch and level meter, the preset picker, and the Response tab with the curve, ten faders and the preamp">
</p>

The panel keeps the power switch, the level meter and the preset picker fixed at
the top; below them a tab bar switches between **Response** (the curve, the
10-band faders or the parametric handles, the mode switch and the preamp),
**Bands** (one row per band, parametric mode only), **Output** (limiter and
Magic Boost) and **AutoEq**.

Everything is driven from the panel; the same operations are available from the
command line.

## Install

```sh
omarchy plugin add https://github.com/creolben/omarchy-equalizer.git --enable
```

That is the whole install. The plugin carries its own backend
(`bin/omarchy-equalizer`) and the panel addresses it inside the plugin directory,
so nothing has to be put on `PATH`. It appears in the bar as an equalizer icon;
click it, or run `omarchy-shell shell summon io.github.creolben.equalizer`.

To work on the plugin instead, clone it in place:

```sh
git clone https://github.com/creolben/omarchy-equalizer.git \
  ~/.config/omarchy/plugins/io.github.creolben.equalizer
omarchy plugin enable io.github.creolben.equalizer
./install.sh    # optional: puts the `omarchy-equalizer` CLI on your PATH
```

### Requirements

- Omarchy (quickshell) with a systemd user session
- PipeWire and `pactl`/`parec` (pipewire-pulse, libpulse), `jq`, `awk`,
  coreutils and `flock` (util-linux)
- `python3` for the panel's level meter (`bin/omarchy-equalizer-spectrum`). It
  reads the equalizer sink's monitor -- the audio being played -- through `parec`,
  turns it into 24 band levels in memory and prints them to the panel; it writes
  no files, uses no network, and runs only while the panel is open and the
  equalizer is on.
- `curl` for AutoEq import; `node` to run the test suite
- Optional: `lsp-plugins-lv2` for the output stage. Without it the equalizer runs
  as a pure EQ and the limiter/boost controls report the stage as inactive.
- Optional but recommended: with `lsp-plugins-lv2`, both modes run on a resident
  16-slot LSP equalizer, so every edit -- a preset of either mode, a mode switch,
  a band's type, adding/removing bands, an AutoEq import -- is a live `pw-cli`
  write rather than a filter-chain restart. Without it, a shape change still
  restarts the chain (players may pause for it).

Enabling makes the equalizer the default sink and moves application streams onto
it; disabling restores the output you had selected. While it is on, the volume
keys control its level, which is applied before the bands.

### Uninstall

Take the equalizer out of the audio path **first** — that restores the output
device you had selected and stops both units, so removing the plugin afterwards
cannot leave your machine pointing at a sink that no longer exists:

```sh
~/.config/omarchy/plugins/io.github.creolben.equalizer/bin/omarchy-equalizer disable
omarchy plugin disable io.github.creolben.equalizer
omarchy plugin remove io.github.creolben.equalizer --yes
```

Then delete what the plugin wrote outside its own directory:

```sh
rm -f  ~/.local/bin/omarchy-equalizer                       # only if you ran install.sh
rm -f  ~/.config/pipewire/omarchy-equalizer.conf
rm -rf ~/.config/pipewire/omarchy-equalizer.conf.d          # the generated graph
rm -f  ~/.config/systemd/user/omarchy-equalizer.service \
       ~/.config/systemd/user/omarchy-equalizer-follow.service
rm -rf ~/.local/state/omarchy-equalizer                     # state, user presets, AutoEq cache
systemctl --user daemon-reload
```

The state directory holds your bands, your saved presets and your settings; keep
it if you plan to install the plugin again.

## How it fits together

- `bin/omarchy-equalizer` — a bash script that owns the state, generates the
  filter-chain fragment, and drives the systemd unit. All the DSP configuration
  lives here.
- `host/omarchy-equalizer.conf` — the filter-chain host, copied to
  `~/.config/pipewire/omarchy-equalizer.conf` on enable. This plugin runs its own
  PipeWire client (`pipewire -c omarchy-equalizer.conf`) rather than using the
  stock `filter-chain.conf`, which would merge every unrelated user fragment, and
  rather than `pipewire.conf.d`, which would need a `pipewire.service` restart —
  that drops every PulseAudio client connection.
- The graph itself is regenerated at
  `~/.config/pipewire/omarchy-equalizer.conf.d/90-eq.conf` when the mode changes
  and on enable/retarget, and is kept in step (values only) after a live edit.
  With `lsp-plugins-lv2` the band set of either mode runs on one resident
  16-slot `para_equalizer_x16_mono` node, so gain, frequency, Q, type, band count
  and the mode itself are all values, written with one `pw-cli set-param`.
  Without LSP each band is a builtin biquad: values are still live (a graphic
  preset crossfades), but a shape change (type, count, mode) rebuilds and
  restarts the unit, and the app streams are parked on the output device for
  the moment that takes so players keep playing. Whether a write can be live is
  decided from the graph actually running (the fragment it was built from), so
  the first command after installing or removing LSP rebuilds once.
- State lives outside the plugin, in
  `${XDG_STATE_HOME:-~/.local/state}/omarchy-equalizer/`: `state.json`,
  `presets.json` for user presets, and a cached AutoEq index.
- Two user units: `omarchy-equalizer.service` (the filter-chain) and
  `omarchy-equalizer-follow.service`, which re-aims the equalizer when the output
  device changes — plugging in headphones otherwise leaves the equalizer playing
  into the old device while apps bypass it. Each pass re-validates the
  remembered target and the aim of the EQ's own output stream against it: a
  Bluetooth device that is switched off, sleeps, or errors out vanishes from
  pactl while the EQ stays the default sink, and a live `pactl move` pins
  nothing, so WirePlumber is free to relink the stream again — a vanished target
  is first given a short grace period (`OMARCHY_EQ_VANISH_GRACE`, 5 s — a Bluetooth
  profile switch re-creates its sink, and a sibling profile sink is adopted at
  once), then replaced by the sink the stream is already on (or a live one; kept
  when nothing else is live, so the device's return can still be aimed at), and a drifted aim is moved back
  onto the remembered target. Two exceptions keep a connecting headset from being
  pulled back to the speakers: the device the user picked is aimed at again as
  soon as it (or its other Bluetooth profile) is back, and an output that
  connects after the target was picked and that WirePlumber puts the stream on
  becomes the target. An output that was already there is not followed, which is
  what keeps issue #2's relink to the highest-priority sink from winning. A later
  disable still restores the device the user actually chose. Every command that
  changes the state takes a lock (`flock` on the state directory), and the
  follower takes it per pass, so concurrent edits are not lost and the follower
  never acts halfway through a restart.
- The panel is QML (`Panel.qml`, `ResponseCurve.qml`, the slider and switch
  widgets). Its text and number fields (`presetNameField`, the AutoEq query,
  the band frequency and Q) are drawn from key events (`KeyField.qml`): an
  editable native Qt text input reads another application's clipboard offer on
  each clipboard change, unbounded, inside the shell process the panel runs in,
  so the fields never instantiate one. Paste is unavailable by design; Return
  or leaving a field commits, and Ctrl+U clears it. `Model.js` holds the biquad
  response maths; the response curve the panel draws and the automatic headroom
  the backend computes are the same formulas, in JS and `awk` respectively, and
  `tests/headroom-check.js` keeps them honest against each other.

The card has a fixed band and a tabbed one. The fixed band never moves: hero,
the meter (a row of bars driven by the output's loudness, beats and spectrum,
that goes quiet when the signal does), and the
preset picker with its reset/delete actions. Below it a tab bar picks one page:
**Response** (the curve, the faders in 10-band mode, the mode control and the
preamp row directly under them), **Bands** (one row per band, parametric mode
only), **Output** (limiter and Magic Boost) and **AutoEq**. Every open starts on
Response. A page only scrolls when it is taller than the card can fit -- the
Response page on a short (768 px) screen, or a long parametric band list.
Errors and AutoEq feedback appear in a one-line status strip pinned at the
bottom, which clears 8 s after the last message. The `e`, `m` and `r` shortcuts
are named in the tooltips of the power switch, the mode control and the preset
reset.

The preset picker filters as you type, on each preset's name, category and
description ("compas" finds Kompa). Its search box is drawn from key events like
the panel's other fields, so the picker never creates a native text input.

The wheel scrolls the panel. Over a band fader it nudges the band instead — hold
Alt, or click the fader first, to arm it. The preamp only moves by dragging or
with the arrow keys, because a vertical wheel over a horizontal control is never
a deliberate edit. The curve ignores the wheel too. Click the curve (or Tab to
it) and the keyboard drives it: ←/→ pick a band, ↑/↓ move it 0.5 dB, `0`
flattens it.

## Command line

```
status                          JSON state for the shell plugin
enable | disable | toggle       Switch the equalizer on or off
retarget                        Re-aim the EQ at the current output device, replacing a target
                                that vanished and converging an aim that drifted
follow                          Watch for output changes (run by systemd)
set-mode <graphic|parametric>   Choose which band set is processed
set-gain <index> <dB>           Set one band's gain (live, no restart)
set-band <index> <gain|freq|q|type> <value>
                                Set one parametric/graphic band property
add-band                        Append a parametric band (16 max)
remove-band <index>             Drop a parametric band
apply-preset <name>             Load a preset
save-preset <name>              Save the current bands as a preset
delete-preset <name>            Delete a user preset
reset                           Flatten the current mode's gains
presets                         List preset names
set-preamp <dB>                 Whole-chain preamp (clamped to the curve's ceiling)
set-headroom <auto|manual>      Auto-track the preamp to the band peaks
set-limiter <on|off>            Brickwall output limiter (live, no restart)
set-boost <off|low|medium|high> Magic Boost compressor (live, no restart)
autoeq-search [--json] <name>   Search AutoEq headphone profiles
import-autoeq <name|file> [index-path]
                                Import an AutoEq profile, saved as a preset
```

Enabling makes the equalizer the default sink and moves application streams onto
it; disabling restores the output you had selected. While it is on, the volume
keys control its level, which is applied before the bands.

## Gain staging

- **Every band value is range-checked**: gain −30…+20 dB, frequency 10 Hz…24 kHz,
  Q 0.05…30, preamp −60…+20 dB, and the filter type must be one the graph knows.
  A value outside that is refused with a message, whether it comes from the CLI, a
  preset or an AutoEq profile, so a well-formed but extreme profile cannot turn
  the chain into an amplifier. A refused command leaves the state as it was.
- **Automatic headroom** (`headroom: auto`) recomputes the preamp from the peak of
  the whole curve on every band, mode, preset or import change, so a boost cannot
  clip. Moving the preamp by hand switches it to `manual`.
- **The ceiling** — manual headroom is not a volume control: the preamp may cut
  below the curve's own peak but never go past it, so the most gain it can hold is
  the value `auto` would have picked. The backend clamps there (with a line on
  stderr saying so) on every command that touches the bands, and the panel's preamp
  slider tops out at the same number, marked on its scale. The point is that the
  limiter stays a safety net: gain stacked above the ceiling is removed from every
  sample, which sounds loud and flat rather than clipped, so nothing else would
  report it.
- **Preamp changes rewrite the fragment.** The preamp is a live control, so the
  fragment on disk would otherwise keep the value from the last rebuild and a later
  restart would come up on a different chain than the one that was tuned.
- **A selected DSP sink is chained in front of, not resolved past.** Resolving
  through it to the hardware (which is what `physical_output` and
  `omarchy-audio-output-sink` do) would silently drop that correction; on an Asahi
  laptop the J313 speaker tuning is the largest single part of how the speakers
  sound.
- **Limiter** — last node in the graph, true-peak, −1 dBFS ceiling. Switched by its
  `enabled` control, so it never restarts the chain.
- **Magic Boost** — `mb_compressor_mono` split into bass / mid / treble at 200 Hz
  and 4 kHz, Off / Low / Medium / High. Compresses and adds makeup gain. A
  single-band compressor would duck the whole spectrum on every bass hit.
- **Bands are resident with LSP.** With `lsp-plugins-lv2` the bands of either
  mode run through one `para_equalizer_x16_mono` node whose 16 slots are always
  in the graph; unused slots are `Off`. Every edit — gain, frequency, Q, type,
  add and remove, a preset, a mode switch — is therefore a control write, sent
  as one `pw-cli set-param` call and never a restart, and the band count is capped
  at 16. The node runs the plugin's `APO (DR)` mode at slope x1, whose bell, shelf
  and pass shapes and `Q` meaning match the RBJ biquads `Model.js` draws and the
  backend's automatic headroom assumes.
- Both output nodes — and the band pool when LSP is installed — stay in the
  graph permanently; only their controls move, because a graph-shape change is a
  unit restart and an audible dropout (a browser pauses its media for it).

## Tests

```sh
bash tests/run-tests.sh     # 346 assertions, no real sink touched
```

The suite also runs `tests/curve-check.js` (the response maths against
PipeWire's own biquads) and the other `tests/*.js` checks.

The suite stubs `pactl`, `pw-cli`, `pw-dump`, `pw-metadata`, `systemctl` and
`curl` on a scratch PATH and points `XDG_CONFIG_HOME`/`XDG_STATE_HOME` at a
throwaway root, so fragments and state land in isolation and the machine keeps
playing. `systemctl` and `pw-cli` calls are logged, which is how "a frequency
edit does not restart the unit" is an assertion rather than an observation.

`node tests/preset-levels.js` also runs inside the suite: it measures every
built-in preset's applied curve with the plugin's own model (at each graph rate
the chain can run at) and enforces the level-matching rules described under
[Presets](#presets), plus that each file names itself, describes itself, and
declares a category that agrees with its order band.

The suite also scans every shipped `.qml` (comments stripped) for Qt's native
text-input types and for the clipboard — the panel must never give the shell a
reason to read a foreign clipboard — and, when `qmltestrunner` is installed,
runs `tests/qml/tst_keyfield.qml` offscreen against stand-ins for the shell kit
(`tests/qml/imports`). Without the runner that part is skipped, not failed.

## Presets

Built-in presets are JSON in `presets/`, one file each, and every file names and
describes itself:

```json
{
  "name": "Rock",
  "description": "Scooped low mids with a 3-4 kHz presence lift",
  "order": 30,
  "category": "genre",
  "mode": "graphic",
  "preamp": -0.5,
  "graphic": [ { "type": "peaking", "freq": 31, "q": 1.41, "gain": 0 }, … ]
}
```

`name` is what the panel lists and what `apply-preset` takes; it has to match the
filename, and the test suite checks that. `description` is the line the searchable
picker shows under a preset's row, and it filters on both the category-prefixed
name and this description — typing "zou" finds Zouk, "compas" finds Kompa through
its description. `order` sorts the list, and the explicit `category` groups it:
Flat is `reference`, the tone controls are `tone`, the genres are `genre`, the
speech presets are `speech`, and the situations are `situation`. The suite holds
`category` to that closed set and to the `order` band (`10`–`19` reference, `20`–`29`
tone, `30`–`39` genre, `40`–`49` speech, `50`–`59` situation), so the two encodings
cannot drift. The user's own presets follow the built-ins and read as `Yours`. A
file without a `name` is not listed at all, so a half-written preset cannot
appear as a nameless entry.

<p align="center">
  <img src="docs/presets.png" width="430" alt="The preset section: category, picker with reset and delete, the preset's description, and the save field">
</p>

### Presets are level-matched

Every built-in is designed so that applying it changes the *tone*, not the
loudness. This is the point of the set, and it is not how EQ presets are usually
built:

- A preset's shape is applied under the automatic preamp, so its **peak** always
  lands at 0 dBFS. What is left to choose is the **level** the rest of the curve
  sits at, and a curve built from boosts therefore plays several dB below Flat —
  at the same volume setting, with nothing left to turn up once the volume is
  already at the end of its travel.
- So the character lives in the *shape* instead: bass-forward presets roll the
  top off rather than lifting the bottom, and speech presets cut the rumble
  rather than adding presence on top of a full-range curve. Every built-in now
  lands within about 2 dB of Flat (the old set ran 3.2–7.2 dB below it, and
  differed from *each other* by 4 dB, which made the list a loudness comparison
  instead of a tone one).
- Anything that genuinely needs to be louder is what **Magic Boost** is for.
- `tests/preset-levels.js` measures each preset's applied curve with the plugin's
  own model, at more than one graph rate, and fails if a preset drifts more than
  2.5 dB from Flat, if the set spreads more than the same, if a curve runs over
  0 dBFS, or if a file stops describing itself. Adding a preset means it has to
  land in the same place.

A preset's `preamp` is written from the backend's own `auto_preamp_db` for its
bands — never by hand — so the file and the code cannot disagree, and applying a
preset under *manual* headroom never trips the clamp. The suite asserts the
equality for every file.

The set, in list order:

| Order | Category | Preset | Mode | What it does |
| --- | --- | --- | --- | --- |
| 10 | reference | Flat | graphic | The neutral reference. |
| 20 | tone | Bass Boost | graphic | Bass plateaus, top rolled off ~5 dB. |
| 21 | tone | Treble Boost | graphic | The mirror: bass trimmed ~5 dB, top open. |
| 22 | tone | Loudness | graphic | Equal-loudness smiley, ~3 dB dip at 1 kHz. |
| 23 | tone | Warm Speakers | parametric | Low shelf up, treble down — warm and forward. |
| 30 | genre | Rock | graphic | Scooped low mids, presence lift at 3–4 kHz. |
| 31 | genre | Pop | graphic | Gentle and vocal-forward with a smooth top. |
| 32 | genre | Dance | graphic | Bass plateau, broad 300 Hz–2 kHz scoop. |
| 33 | genre | Jazz | graphic | Warm and smooth, top octaves rolled off. |
| 34 | genre | Classical | graphic | Near-flat, soft 500 Hz dip, a touch of air. |
| 35 | genre | Vocal | graphic | Bass trimmed, presence lifted. |
| 36 | genre | Zouk | graphic | Round low-mid warmth, kick forward, soft top. |
| 37 | genre | Kompa | graphic | Forward horns and guitars, tight bass, gentle top. |
| 40 | speech | Podcast | graphic | Rumble cut below 125 Hz, speech band at unity. |
| 41 | speech | Speech Clarity | parametric | 55 Hz high-pass, 3 kHz intelligibility lift. |
| 50 | situation | Late Night | graphic | Quiet hours: bass and treble trimmed, presence kept. |
| 51 | situation | Gaming | graphic | Low-mid boom cut, 3–4 kHz footsteps lift. |
| 52 | situation | Small Speakers | parametric | 55 Hz high-pass, boxiness cut, 3 kHz lift. |

The two high-pass presets are the only ones that deliberately sit ~2 dB below
Flat: a pink-noise sweep still has energy under the corner, while the speech and
small-speaker material they are for does not.

Graphic presets are all ten ISO bands as peaking filters, which is what lets a
preset switch crossfade live on a machine without LSP instead of restarting the
chain (see the ramp in `bin/omarchy-equalizer`). Keep that shape when adding one.

User presets live in `presets.json` under the state directory; they have no
description and no order, so the picker labels them `Yours` and the loaded-preset
line falls back to their band count. `import-autoeq` downloads a measured profile from
[AutoEq](https://github.com/jaakkopasanen/AutoEq) (MIT), applies it and saves it
as a preset. Profile names and the preset list are matched exactly, so check that
the model you import is the device you are listening on — an over-ear profile
applied to in-ear buds is a correction for the wrong acoustics.

## License

MIT — see [LICENSE](LICENSE).

The AutoEq headphone profiles this plugin can import come from
[jaakkopasanen/AutoEq](https://github.com/jaakkopasanen/AutoEq), also MIT.