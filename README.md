# Equalizer

An Omarchy bar plugin that puts a system-wide equalizer in front of any PipeWire
output: a 10-band graphic EQ, unlimited parametric bands, presets, AutoEq import,
automatic headroom, and an output stage (brickwall limiter plus a multiband
"Magic Boost" compressor).

Everything is driven from the panel; the same operations are available from the
command line.

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
  `~/.config/pipewire/omarchy-equalizer.conf.d/90-eq.conf` whenever the *shape*
  changes (band count, or a band's filter type). Gain, frequency and Q are values
  on filters that already exist, so those are written into the running graph with
  `pw-cli set-param` and never restart anything.
- State lives outside the plugin, in
  `${XDG_STATE_HOME:-~/.local/state}/omarchy-equalizer/`: `state.json`,
  `presets.json` for user presets, and a cached AutoEq index.
- Two user units: `omarchy-equalizer.service` (the filter-chain) and
  `omarchy-equalizer-follow.service`, which re-aims the equalizer when the output
  device changes — plugging in headphones otherwise leaves the equalizer playing
  into the old device while apps bypass it.
- The panel is QML (`Panel.qml`, `ResponseCurve.qml`, the slider and switch
  widgets). `Model.js` holds the biquad response maths; the response curve the
  panel draws and the automatic headroom the backend computes are the same
  formulas, in JS and `awk` respectively, and `tests/headroom-check.js` keeps
  them honest against each other.

## Requirements

- Omarchy (quickshell) with a systemd user session
- PipeWire and `pactl` (pipewire-pulse), `jq`, `awk`, coreutils
- `curl` for AutoEq import; `node` to run the test suite
- Optional: `lsp-plugins-lv2` for the output stage. Without it the equalizer runs
  as a pure EQ and the limiter/boost controls report the stage as inactive.

## Install

```sh
./install.sh                                    # symlink the backend into ~/.local/bin
omarchy plugin enable creolben.equalizer
omarchy-shell shell summon creolben.equalizer   # should print "ok"
```

The symlink (rather than a copy) is what keeps the installed command in step with
the checkout: editing `bin/omarchy-equalizer` takes effect immediately.

## Command line

```
status                          JSON state for the shell plugin
enable | disable | toggle       Switch the equalizer on or off
retarget                        Re-aim the EQ at the current output device
follow                          Watch for output changes (run by systemd)
set-mode <graphic|parametric>   Choose which band set is processed
set-gain <index> <dB>           Set one band's gain (live, no restart)
set-band <index> <gain|freq|q|type> <value>
add-band                        Append a parametric band
remove-band <index>             Drop a parametric band
apply-preset <name>             Load a preset
save-preset <name>              Save the current bands as a preset
delete-preset <name>            Delete a user preset
reset                           Flatten the current mode's gains
presets                         List preset names
set-preamp <dB>                 Whole-chain preamp (live, no restart)
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

- **Automatic headroom** (`headroom: auto`) recomputes the preamp from the peak of
  the whole curve on every band, mode, preset or import change, so a boost cannot
  clip. Moving the preamp by hand switches it to `manual`.
- **Limiter** — last node in the graph, true-peak, −1 dBFS ceiling. Switched by its
  `enabled` control, so it never restarts the chain.
- **Magic Boost** — `mb_compressor_mono` split into bass / mid / treble at 200 Hz
  and 4 kHz, Off / Low / Medium / High. Compresses and adds makeup gain. A
  single-band compressor would duck the whole spectrum on every bass hit.
- Both output nodes stay in the graph permanently; only their `enabled` control
  moves, because a graph-shape change is a unit restart and an audible dropout.

## Tests

```sh
bash tests/run-tests.sh     # 88 assertions, no real sink touched
node tests/curve-check.js   # Model.js response maths vs PipeWire's own biquads
```

The suite stubs `pactl`, `pw-cli`, `pw-dump`, `pw-metadata`, `systemctl` and
`curl` on a scratch PATH and points `XDG_CONFIG_HOME`/`XDG_STATE_HOME` at a
throwaway root, so fragments and state land in isolation and the machine keeps
playing. `systemctl` and `pw-cli` calls are logged, which is how "a frequency
edit does not restart the unit" is an assertion rather than an observation.

## Presets

Built-in presets are JSON in `presets/`. User presets live in `presets.json` under
the state directory. `import-autoeq` downloads a measured profile from
[AutoEq](https://github.com/jaakkopasanen/AutoEq) (MIT), applies it and saves it
as a preset. Profile names and the preset list are matched exactly, so check that
the model you import is the device you are listening on — an over-ear profile
applied to in-ear buds is a correction for the wrong acoustics.

## License

Not yet chosen. AutoEq profile data, when imported, comes from a MIT-licensed
project.
