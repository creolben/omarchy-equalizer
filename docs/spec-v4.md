# Equalizer 4 — adjustments you can hear, faders that mean what they show

Status: implemented on branch `clean-sound-audiorea` on top of `08036d9`
(2026-11-09), every phase. Where a measurement changed the design, the text
below says what was built and §9 says why; §9 also lists what is not verified.
Written 2026-11-09 against `08036d9`.

It follows the audit of the same day, whose question was why adjusting this
equalizer does not feel like adjusting Audio Hijack's. The reference for Audio
Hijack is the AudioREA study (02 §2: a 10-band block at ±12 dB per fader, a
parametric block with `preamp` and `bands: [{enabled, gain, freq, type,
slope}]`, and no automatic headroom anywhere).

Read §1 and §2 first. §1 is the evidence, §2 is the contract every phase in §4
is judged against. Each phase is written to be done and shipped on its own.

## 1. Evidence

Read from the code, modelled with `Model.js` at 48 kHz, or measured on this
machine (PipeWire 1.6.9, aarch64). Nothing here was judged by ear, and the
panel was not opened.

### 1.1 A drag is silent until the pointer stops

- `Panel.qml` `commitBand` restarts a 120 ms timer on every pointer move, so
  the write is debounced, not throttled: nothing reaches the graph while the
  pointer is moving. The comment above `pendingBandIndex` says "sends its own
  gains at 30 ms"; the code does not.
- One backend command then costs this much, on the test stubs (so before any
  real PipeWire call):

  | Command | Wall time |
  | --- | --- |
  | `set-gain` | 238 ms |
  | `set-band … freq` | 267 ms |
  | `set-preamp` | 209 ms |
  | `apply-preset` | 288 ms |
  | `status` | 114 ms |

- The PipeWire calls are not the cost. On the live session, read-only:
  `pw-cli info 0` takes 7 ms and `pw-dump` 41 ms. The time is bash and `jq`.
- So the sound follows a fader by 120 ms + about 250 ms after the hand stops,
  and not at all before that.

### 1.2 The drawing does not follow the drag either

- `ResponseCurve.drawCurve` computes the line from `bands`; only the handle
  uses `draftGain`/`draftFreq`. During a drag the handle leaves the line until
  the debounce fires and the panel echoes the value.
- In parametric mode the frequency has no local echo at all:
  `onBandFreqCommitted` calls `setBandProperty`, which only queues the command.
  On release the handle is drawn at the old frequency until the backend
  answers.
- The fader bank has the same gap: a fader's own `liveGain` moves, the curve
  above it does not.

### 1.3 A boost costs the whole signal its size

With the volume keys the relief stays at zero (spec-v3 §6), so automatic
headroom always applies its full cut:

| Faders (classic bells) | Curve peak | Auto preamp | Level vs Flat | Pink power gain |
| --- | --- | --- | --- | --- |
| +8/+6/+4 at 31/62/125 Hz | +9.3 dB | −9.5 dB | −8.3 dB | +3.5 dB |
| Smile: 6, 4, 2, 0, −2, −2, 0, 2, 4, 6 | +6.8 dB | −7.0 dB | −5.4 dB | +2.7 dB |
| +10 at 16 kHz only | +10.0 dB | −10.0 dB | −9.4 dB | +1.2 dB |
| +6 at 1 kHz only | +6.0 dB | −6.0 dB | −4.7 dB | +1.1 dB |
| All ten at +6 | +8.8 dB | −9.0 dB | −1.6 dB | +7.4 dB |

"Pink power gain" is how much louder pink noise leaves the bands than it went
in. It is the gap between what the cut assumes (a full-scale tone at the
curve's peak) and what programme material does. The cut also moves with every
edit, so pushing a bass fader up audibly pulls everything else down while the
fader is still moving.

### 1.4 The faders do not set what they show

Ten octave bells at Q 1.41 overlap:

| Faders | Response at the band centres |
| --- | --- |
| All at +6 | +6.5 to +8.8 dB |
| Alternating ±6 | about ±4 dB (±5.6 at the ends) |
| +6 at 1 kHz only | +6.0 dB, and +1.1 dB at 500 Hz and 2 kHz |

The overlap also costs headroom: all ten at +6 is cut by 9 dB, not 6.

A prototype of the fix (§3.3) converges in three iterations to under 0.01 dB
for every case above. All ten at +6 then needs bell gains of 4.1 to 5.6 dB and
peaks at +6.04 dB. Alternating ±12 needs bell gains up to ±19.8 dB, inside the
backend's −30…+20 range.

### 1.5 What the platform allows

- Quickshell's `Process` has `stdinEnabled` and `write(data)`
  (`quickshell-io.qmltypes`), so the panel can hold a helper open and feed it.
- A piped `pw-cli` does not exit at end of input (it had to be killed), and
  whether it runs piped commands was not established. The helper therefore
  calls one-shot `pw-cli set-param`, which costs 7 ms.
- `pactl list sinks` tells software volume from hardware volume: the Bluetooth
  sink carries `HW_VOLUME_CTRL`, the J313 speaker sink and the equalizer do
  not.

### 1.6 Smaller findings

- `r` flattens the active band set with one keystroke, and there is no undo
  anywhere.
- The preset marker says `EDITED` but offers no way back to the preset and no
  way to save over it.
- Bypass is a click on a band's number badge and solo a right-click on it;
  neither is visible.
- The curve cannot change Q, cannot add a band, and gives a pass filter no
  handle. A new band always appears at 1 kHz.
- The panel clamps gains to ±12 dB (`commitBand`, `sendBandNow`), the backend
  holds −30…+20 dB, and AutoEq profiles use the difference. Touching an
  imported band at −15 dB silently makes it −12.
- The frequency field takes digits only: no `2.5k`.
- The console's top line carries the peak, the level against Flat and the
  limiter warning, elided, beside the A/B button and the mode control in
  430 px.
- The fixed band above the curve holds the hero, an animated meter and a
  permanent save row. The meter's bars follow a looped animation scaled by the
  signal, not the spectrum's shape.
- With LSP a preset is one whole-set write with no fade; whether a gain step
  on a low band clicks was never measured.

## 2. Contract

Every phase is done when its own lines hold, and no phase may break another's.

1. **Hearing.** While a gain, frequency, Q, preamp or balance control is being
   dragged, the graph receives the new value within 50 ms of the pointer move
   that produced it, at least 20 times a second while the value keeps
   changing.
2. **Seeing.** The curve, the handle, the fader and the readouts show the same
   value on every frame of a drag and after its release. Nothing snaps back.
3. **Faders.** In 10-band mode the curve passes through every fader's value at
   its centre frequency within 0.1 dB, unless a bell gain reached the
   backend's range, in which case the fader shows the value achieved.
4. **Loudness.** An edit never moves the preamp while the control is held.
   Under the Balanced policy the bass curve of §1.3 plays at most 5 dB below
   Flat at full volume.
5. **Safety.** Nothing this spec adds can put a sample over full scale where
   the device converts it, with the one stated exception of §3.5.3. Safe
   remains the default policy.
6. **Reversibility.** Every command that changes the curve can be undone, a
   drag as one step.
7. **No sound changes on upgrade.** After upgrading, every existing state,
   user preset and built-in preset plays exactly as before until the user
   changes something.
8. **Fallback.** If the live helper is missing, fails or exits, every control
   still works through the existing command queue.
9. **The suite stays green**, and each phase adds the tests named for it. The
   clipboard rule (no native text input in any shipped `.qml`) still holds.

## 3. Design

### 3.1 The live path

#### 3.1.1 `omarchy-equalizer live`

A long-running command the panel keeps open while it is open, the equalizer is
on and its sink is present. It reads lines on stdin and writes control values
straight into the running graph. It does not touch `state.json` until told to
commit.

Start-up, once:

- Read the state with one `jq` call into shell variables: mode, the active
  band list (type, freq, q, gain, enabled, slope per band), preamp, relief,
  headroom, limiter, balance, channels.
- Resolve the node id once (`find_node_id`), and read the running layout
  (`running_layout`).
- Build the band → slot map from the same expansion `stages_tsv` uses, so a
  pass filter with a slope addresses all of its slots.
- Print `ready <signature>` on stdout, where the signature is
  `mode:bandcount:slots`. If the sink is missing, or an A/B or solo is in
  force, print `unavailable <reason>` and exit 3.

Lines in (space-separated, one per line):

| Line | Effect |
| --- | --- |
| `gain <i> <dB>` | Band `i`'s gain |
| `gains <g0> … <gN-1>` | Every band's gain at once (the 10-band fit of §3.3) |
| `freq <i> <Hz>` | Band `i`'s frequency, on every slot it occupies |
| `q <i> <Q>` | Band `i`'s Q, scaled per stage for a slope as `bandStages` does |
| `preamp <dB>` | The preamp, clamped to the ceiling in force at start-up |
| `balance <v>` | The two mixers' gains, from `mixer_values` |
| `commit` | Write everything received since the last commit into the state |
| `cancel` | Write the state's own values back into the graph, forget the edits |

Per line:

- Validate with the ranges of `state_problem` (the same constants), drop a
  line that fails, and print `error <message>` on stdout. Never interpolate an
  unvalidated token into the parameter list.
- Before acting, drain whatever else is already waiting on stdin and keep only
  the last line per key (`gain:<i>`, `freq:<i>`, `q:<i>`, `gains`, `preamp`,
  `balance`). `commit` and `cancel` are never dropped and keep their order.
- Write only the controls that changed, in one `pw-cli set-param`:
  - pool: `para:g_<slot>` (linear), `para:f_<slot>`, `para:q_<slot>`;
  - biquads: `g<k>_l:Gain`/`Freq`/`Q` and the `_r` twin;
  - preamp: `pre_l:Mult`, `pre_r:Mult`;
  - balance: the four mixer gains.
- No `jq` and no state read between `ready` and `commit`. dB → linear and the
  stage Qs come from one persistent `awk` coprocess, or bash arithmetic.
- The preamp is not recomputed during a session (§3.5.1), unless the limiter
  is off or LSP is missing: then every `gain`/`gains`/`q` line recomputes the
  automatic preamp and writes it with the bands, because nothing else would
  catch the clip.

`commit`:

- Take the state lock, re-read the state, and compare its signature with the
  one from start-up. If it changed (the follower switched device curves, a
  terminal edited the bands), apply nothing, print `stale`, write the state's
  own values back to the graph, and re-run start-up.
- Otherwise apply the session's edits to the state in one update, run
  `apply_headroom`, `state_write` and `sync_fragment` exactly as `cmd_set_band`
  does, push one undo entry (§3.4), ramp the preamp to its new value
  (§3.5.1), release the lock, and print `status <json>` with the same document
  `status` prints.
- A failed `pw-cli` re-resolves the node id once and retries. A second failure
  prints `error …` and exits 1; the panel falls back (contract 8).

End of input without `commit` is `cancel`.

The follower never needs the session's lock: the helper holds none between
commits. A follower pass in the middle of a drag writes only what it owns (the
relief, routing), and a device-curve switch is caught by the signature.

#### 3.1.2 The panel's side

- `Process { id: liveProc; stdinEnabled: true }` runs
  `[helper, "live"]` while `opened && enabled && sinkPresent`. Its stdout is
  read line by line: `ready` arms it, `status` goes to `applyStatus`, `error`
  to `reportError`, `stale` triggers `refresh()`.
- One function, `liveSend(key, line)`, replaces the two settle timers. It
  keeps the latest line per key and flushes all pending keys on a 16 ms
  repeating timer that runs only while something is pending. A line is sent
  only when its snapped value differs from the last one sent for that key.
- Press: nothing is sent. Move: local echo (§3.2), then `liveSend`. Release,
  double-click reset, arrow-key nudge, wheel nudge: flush, then `commit`.
- While `liveProc` is not armed, or `comparing`/`soloIndex >= 0`, the same
  call sites use today's `run([...])` path with a 60 ms throttle in place of
  the 120 ms debounce. That path also ends an A/B or solo as it does now.
- `bandCommitTimer`, `preampCommitTimer`, `pendingBandIndex`,
  `pendingBandGain` and `bandDirty` are removed.
- The 4 s status poll is skipped while a drag is in progress.

#### 3.1.3 Clicks

Measured in `tests/dsp-check.sh` before deciding anything: a 50 Hz tone at
−12 dBFS, the largest sample-to-sample jump against what the tone itself can
do at its local amplitude; more than 6 dB above it is a click. Measured:

| What changed | Click |
| --- | --- |
| A 62 Hz bell on the pool, 0.5 dB every 50 ms | 0.12 dB: none |
| The same bell, 1 dB at once, on the pool and on the biquads | 0.00 dB |
| The preamp (a flat gain), 0.5 / 0.25 / 0.1 dB at once | 13.3 / 7.9 / 2.6 dB |
| A preset switch on the pool, one write | 10.5 dB |
| A band on the builtin biquads, written repeatedly | 35–37 dB |

So the filters do not click and the flat gains do. What was built:

- Band edits are written as they come; nothing is split.
- The flat gains -- preamp, relief, device relief -- walk in steps of at most
  0.1 dB, one per 20 ms, in the background, whenever the limiter is on, and
  without it whenever the cut gets smaller (less cut cannot clip on the way).
  A deeper cut without a limiter is written at once. Any newer write of them
  cancels a walk in progress (a token file the walk reads before every step).
- A preset, a reset, an undo or a redo of the same shape is cross-faded on the
  pool: the bands in eight steps under the old gains, then the gains walked.
  Measured afterwards: 2.7 dB.
- PipeWire's builtin biquad clears its history on every update: the output
  drops to the unfiltered input at the quantum boundary and recovers. Every
  write clicks once whatever its size, so smaller steps would only add clicks.
  On the biquad chain a curve change is therefore one write (the old
  eight-step cross-fade there made eight clicks), and the live editor writes
  at most every 100 ms. LSP keeps its filters' state; it is recommended.

### 3.2 Local echo

- `Panel.echoBand(index, key, value)` copies the band, sets the field and
  reassigns `status` (what `setBandField` does today). It is called on every
  move for gain, frequency and Q, not only on commit. `Model.metrics` is
  memoised on content, so an unchanged value costs nothing, and a changed one
  is one 401-point sweep.
- `ResponseCurve` keeps `dragIndex` for hit-testing and styling but no longer
  holds draft values the curve does not use: `draftGain` and `draftFreq` are
  removed, and `bandGainAt`/`bandFreqAt` read `bands` only. The handle and the
  line therefore come from one array.
- `bandFreqMoved(index, freq)` and `bandQMoved(index, q)` join
  `bandGainMoved`, so the panel echoes and streams all three.
- The tests in `tests/qml/tst_responsecurve.qml` that read `handleXFor` and
  `handleYFor` gain a case: after a simulated drag move, the curve's value at
  the handle's frequency equals the handle's gain, and after release the
  handle's x is the released frequency.

### 3.3 Faders that fit

The state and the presets keep bell gains. Nothing the backend computes
changes meaning. The fit is how the 10-band console reads and edits them.

- `Model.graphicResponse(bands, rate)` returns the response at each band's
  centre. That is what a fader, its number and its handle show, to one
  decimal.
- `Model.fitGraphic(bands, targets, rate)` returns bell gains whose response
  at the centres equals `targets`:
  1. Build the 10×10 matrix of each band's response at every centre for a
     1 dB bell, and invert it once per rate (memoised).
  2. Start from the current bell gains. Repeat up to six times: compute the
     response, multiply the error by the inverse, add it to the gains, clamp
     to −30…+20 dB. Stop early when the largest error is under 0.02 dB.
  3. Round the bell gains to 0.01 dB.
- Dragging fader `i` sets `targets[i]` to the fader's snapped value and leaves
  every other target at its current (unrounded) response, so the other faders
  do not move. The result is sent as `gains …` on the live path and committed
  as one edit.
- New backend command `set-gains <g0> … <gN-1>`: every active band's gain in
  one state write and one live write. It is the command-queue fallback and is
  useful from a terminal. `set-gain` is unchanged and still means a bell gain.
- If a bell gain is clamped, the fader shows the response achieved, and the
  status strip says once: "Neighbouring faders this far apart cannot be fully
  reached."
- A preset or an existing curve needs no conversion: its faders simply read
  what it has always played. They will show values such as +7.4 instead of
  +6.0, which is the truth.
- `shapedCount` and `strongestBand` keep reading bell gains.
- Parametric mode is untouched.

Not addressed: between two fully raised neighbours the response still dips
about 1.1 dB (all ten at +6 reads 4.9 dB between centres). That is the bells'
Q; changing it would change every preset (contract 7).

### 3.4 Undo, revert, update

- A history file, `history.json` in the state directory: two stacks (undo,
  redo) of at most 30 snapshots. A snapshot is the curve and nothing else:
  `mode`, `preset`, `preamp`, `headroom`, `graphic`, `parametric`.
- Every command that passes through `apply_headroom`, plus `set-preamp`,
  pushes the state as it was before the edit and clears the redo stack. A
  live session pushes once per `commit`. Two pushes by the same command on the
  same band within one second replace each other, so a scripted burst of
  `set-gain` is one step.
- `undo` and `redo` swap the snapshot into the state and apply it like a
  preset (live when the layout allows). They end an A/B or solo.
- A device-curve switch by the follower clears both stacks: undoing across it
  would put one device's curve on another.
- `status` gains `canUndo` and `canRedo`.
- `revert-preset` applies the preset the state names. It fails with a message
  when the name resolves to nothing.
- Panel:
  - `u` or Ctrl+Z undoes, Shift+U or Ctrl+Shift+Z redoes.
  - After `r`, the status strip reads "Flattened · press u to undo" for its
    8 s.
  - While `presetDirty`, two icon buttons appear in the picker row: Revert
    (`revert-preset`) and, for a user preset only, Update (`save-preset` under
    the loaded name). Delete keeps its place.

### 3.5 Headroom

#### 3.5.1 Hold during a drag, settle on release

While a control is held the preamp stays where it was (§3.1.1), and the
limiter covers the difference. On commit the preamp walks to its new value in
steps of at most 0.1 dB, one per 20 ms (§3.1.3 measured eight steps to click
for any change over about 1 dB), writing the flat gains only (`gain_walk`, no
band parameters, no `jq` per step); measured afterwards, 2.3 dB under a 50 Hz
tone for a 6 dB settle. With the limiter off or LSP missing the preamp
deepens with every boost at once, is not given back during the drag, and
walks up at the commit.

The preamp row's readout shows the value in force. While it differs from the
value the curve will settle at, it shows both: `−3.0 → −5.5 dB`.

#### 3.5.2 A third policy: Balanced

`headroom` takes `auto` (shown as **Safe**), `balanced` or `manual`.

- `Model.programGainDb(series)`: 10·log10 of the mean of 10^(H/10) over the
  401-point sweep, the "pink power gain" column of §1.3. The backend's awk
  gets the same function as a third mode of `biquad_curve`, and
  `tests/headroom-check.js` holds the two equal as it does for the peak.
- Balanced preamp = −min(peak cut, ceil to 0.5 dB of
  (max(0, programGain) + margin)). The margin the gate below settled on is
  3.5 dB:

  | Curve of §1.3 | Programme gain | Safe | Balanced | Over full scale at worst |
  | --- | --- | --- | --- | --- |
  | Bass | +3.52 dB | −9.5 | −7.5 | 1.8 dB |
  | Smile | +2.71 dB | −7.0 | −6.5 | 0.3 dB |
  | +10 at 16 kHz | +1.15 dB | −10.0 | −5.0 | 5.0 dB |
  | +6 at 1 kHz | +1.11 dB | −6.0 | −5.0 | 1.0 dB |
  | All ten at +6 | +7.36 dB | −9.0 | −9.0 | 0 |

- Balanced needs the limiter: with it off, or without LSP, the state keeps
  the value but plays as Safe, and the panel says so (the rule the relief
  already follows).
- The preamp ceiling for manual stays the Safe value.
- The volume relief applies to whatever cut is in force.
- The "LIMITER −x dB" warning uses the preamp in force, so under Balanced it
  reads the worst case honestly; its threshold for turning red stays 2 dB only
  under Manual. Under Balanced it is shown without the alarm colour.
- Panel: the `Auto · on/off` button becomes a three-cell control, Safe /
  Balanced / Manual, with the tooltip of each cell saying what it trades.

Gate, in `tests/dsp-check.sh`, before Balanced ships at all. Signal: pink
noise at a 12 dB crest factor normalised to −0.1 dBFS peak, a 50 Hz burst (four
cycles, full scale) every 500 ms, and a −30 dBFS 1 kHz pilot. Through the bass
curve of §1.3 under Balanced:

- THD of the 50 Hz burst at most 2 %;
- the pilot's level moves at most 1.5 dB during a burst (pumping);
- the output never exceeds the limiter's ceiling.

If a line fails, raise `margin` in 0.5 dB steps until it holds and record the
value here. Then it is heard by the user on the speakers and the earbuds
before it is offered as anything but an option. Safe stays the default either
way (contract 5).

Recorded (bass shelf; THD of the bursts, pilot movement, largest sample):

| Margin | Preamp | THD | Pilot | Peak |
| --- | --- | --- | --- | --- |
| Safe | −9.5 | 0.63 % | 0.08 dB | −1.07 dBFS |
| 1.5 dB | −5.5 | 2.14 % | 3.27 dB | −1.00 dBFS |
| 2.0 dB | −6.0 | 1.90 % | 2.63 dB | −1.00 dBFS |
| 2.5 dB | −6.5 | 2.07 % | 2.05 dB | −1.00 dBFS |
| 3.0 dB | −7.0 | 1.88 % | 1.56 dB | −1.00 dBFS |
| **3.5 dB** | **−7.5** | **1.61 %** | **1.18 dB** | **−1.00 dBFS** |

The smile holds from 2.5 dB. Balanced is offered as an option; it has not
been heard.

#### 3.5.3 Relief that follows the device's volume

The volume keys move the device's volume, so today's relief never applies
(spec-v3 §6). Where that volume is applied in software, the cut can be given
back after the limiter:

- Layout v4: a `drelief_l`/`drelief_r` pair of `linear` nodes after `limit`
  (after `vol_*` without LSP, where it stays at unity). One rebuild on
  upgrade, by the existing layout rule.
- `device relief = min(cut − relief, −deviceVolume)`, floored to 0.1 dB, and
  zero unless all of these hold: the user switched it on
  (`set-device-relief on`, off by default -- on, it changes what is heard
  below full device volume, which contract 7 forbids an upgrade to do);
  automatic or balanced headroom; limiter on and LSP present; the target sink
  is not muted; its `Flags` line has no `HW_VOLUME_CTRL`; its base volume is
  100 %.
- The follower handles a `'change' on sink #<target>` event before draining
  the burst: read the volume, write `drelief` (one `pw-cli`, no state write
  when only the relief moved by less than 0.05 dB), then drain. A volume going
  up is therefore answered within one event, not after the 0.5 s drain.
- `status` gains `deviceRelief` and `deviceVolumeDb`; `appliedPreamp` adds
  it. The caption under the preamp row covers both reliefs in one sentence.

The stated exception to contract 5: between a volume-up event and the write
that answers it (expected under 30 ms) the signal after the device's volume
can pass full scale by at most the step of one key press, and nothing after
the limiter catches it.

Gate, on the live session and only with the user's go-ahead, because it plays
through the real device: with a +6 dB curve and the speakers at −12 dB, a
full-scale 1 kHz tone must come out of the J313 sink's monitor undistorted
(THD under 0.1 %), which proves that sink applies its volume before anything
that clips. If it fails, this section is dropped for that sink class and the
flag test becomes an allow-list.

### 3.6 Parametric editing on the curve

#### 3.6.1 Gestures

| Gesture | Effect |
| --- | --- |
| Drag a handle | Gain and frequency (as now), streamed live |
| Shift while dragging | Fine steps: 0.1 dB, and frequency at a quarter of the pointer's travel |
| Wheel over a handle that is selected, or with Alt held | Q, one sixth of an octave of bandwidth per notch (`Model.wheelOwns("handle", …)`) |
| Wheel anywhere else on the plot | Scrolls the panel (as now) |
| Double-click a handle | Gain to 0 (as now) |
| Double-click empty plot | Adds a peaking band at that frequency and gain, Q 1.0, and selects it |
| ←/→ | Select the previous/next band (as now) |
| ↑/↓ | Gain ±0.5 dB, with Shift ±0.1 dB |
| Shift+←/→ | Frequency by 1/24 octave |
| `[` / `]` | Q down/up by a sixth of an octave of bandwidth |
| `b`, `s`, Delete | Bypass, solo, remove the selected band |

- The wheel rule is the faders' own: a handle takes it only when it was
  clicked or Alt is held, so scrolling the panel across the plot edits
  nothing. `tests/input-policy-check.js` gains the `"handle"` kind.
- A pass filter gets a handle on the 0 dB line at its corner, drawn as a
  diamond, dragged horizontally only. Notch, band-pass and all-pass get the
  same.
- A bypassed band keeps a hollow, dimmed handle that can be selected and
  dragged; it shapes nothing until switched on.
- `add-band` takes optional `[freq] [gain] [q] [type]`, validated by the
  state's ranges. With none it behaves as now.
- Graphic mode keeps frequency fixed; of the table it takes the gain rows and
  nothing else.

#### 3.6.2 The selected band's strip

Under the plot in parametric mode, one row for the selected band, so a band
can be edited completely without leaving Response:

`[3]  Peaking ▾   1.2k Hz   Q 1.41   +3.5 dB   Bypass   Solo   Remove`

It reuses the Bands row's parts (type dropdown, the two `KeyField`s, the gain
chip) and adds labelled Bypass and Solo buttons. With nothing selected it
reads "Click a band, or double-click the curve to add one." The Bands tab
stays as the list of all bands, and each of its rows gains the same two
labelled buttons in place of the badge's hidden clicks (the badge keeps them
as shortcuts).

#### 3.6.3 Ranges and fields

- The panel never clamps a value it did not produce: `echoBand` and the send
  paths clamp to the backend's ranges, not to ±12.
- A gain control's range is ±12 dB, or ±24 dB for a band whose stored gain is
  outside ±12. The plot's scale is ±18 dB, or ±30 dB while any band or the
  curve is outside ±18.
- Frequency fields accept `k` (`2.5k` = 2500) and show the abbreviated form
  when unfocused. Frequency and Q fields take ↑/↓ as a nudge (1/24 octave; a
  sixth of an octave of bandwidth). `KeyField` gets `allowedCharacters`
  `/[0-9.kK]/` for frequency.

### 3.7 The panel's layout

- **Spectrum behind the curve.** The 24 levels the spectrum helper already
  prints (40 Hz to 11 kHz, log-spaced) are drawn as a soft filled shape behind
  the response curve, on the plot's own frequency axis, in a layer of its own
  so the curve's canvas is not repainted 40 times a second. Its scale is the
  helper's relative one, so it shows the shape of what is playing and carries
  no dB labels.
- **The meter row goes.** `LevelWave` and its Lottie tables leave the hero;
  the peak readout and the CLIP hold move to the right of the hero's summary
  line. (This removes work a whole earlier phase built. See §6.)
- **The console's top line is two.** Line one: the A/B button and the mode
  control. Line two: the peak, the level against Flat and the limiter figure,
  with room to be read in full.
- **Saving folds away.** The permanent name field and Save button become one
  "Save as…" button in the picker row, which opens the field in place. The
  preset's description stays.
- **Contrast.** Secondary text uses one helper, `Model.dimColor(fg, bg)`,
  that returns the dimmest blend still at 4.5:1 against the background, in
  place of the scattered `Qt.darker(fg, 1.4)` and `1.6`. A node test checks
  the ratio for a light and a dark pair.

## 4. Phases

Each is one piece of work with its own tests. Order matters only where a line
says so.

| Phase | Contents | Depends on |
| --- | --- | --- |
| 1 | §3.2 local echo; the 60 ms throttle on the command path | — |
| 2 | §3.1 the live helper and the panel's use of it; §3.1.3 measurements | 1 |
| 3 | §3.3 fitted faders, `set-gains` | 1 (2 for live) |
| 4 | §3.4 undo, revert, update | — |
| 5 | §3.5.1 preamp hold and ramp | 2 |
| 6 | §3.6 curve gestures, the strip, ranges, fields | 1 |
| 7 | §3.5.2 Balanced, behind its gate | 5 |
| 8 | §3.5.3 device relief, behind its gate | 5 |
| 9 | §3.7 layout | — |
| 10 | README, screenshots, manifest 3.0.0 | all |

Phases 1 to 3 are the Audio Hijack feel and carry no risk to the sound. Phases
7 and 8 are the only ones that change what is heard at rest, and each waits on
a measurement and on the user's ears.

## 5. Interfaces

### 5.1 Commands

```
live                            Streamed edits on stdin (run by the panel)
set-gains <dB> ...              Every active band's gain at once
add-band [freq] [gain] [q] [type]
undo | redo                     Step the curve's history
revert-preset                   Back to the loaded preset as saved
set-headroom <auto|balanced|manual>
```

`live`, like `status`, takes no lock at start; it takes it per `commit`.

### 5.2 State

- `headroom` gains `balanced`. Because 3.x refuses that value, `state_version`
  becomes 4; a version-3 backend already leaves a newer state alone.
- `deviceRelief` (number, default 0) beside `relief`.
- `history.json` is a new file; `state.json` gains nothing for undo.
- `layout_version` becomes 4 for `drelief` (phase 8 only).

### 5.3 Status

New fields: `canUndo`, `canRedo`, `deviceRelief`, `deviceVolumeDb`,
`programGainDb`, and `settlePreamp` (the preamp the curve will settle at,
equal to `preamp` outside a drag).

## 6. Decisions for the user

1. **Dropping the animated meter** for the spectrum behind the curve (§3.7).
   The alternative keeps both and gives the curve less height.
2. **Balanced as an option only**, or as the default once it passes its gate
   and a listening check. This spec assumes option only.
3. **Device relief** needs one live measurement that plays a test tone through
   the speakers (§3.5.3).
4. **Fader numbers will change on existing curves** in 10-band mode (+7.4
   where the fader was set to +6.0). The sound does not. The alternative is a
   Classic/Fitted switch, which this spec leaves out.

## 7. Not in this round

- Changing the graphic bells' Q or count, or a 31-band mode.
- Per-channel (left/right or mid/side) bands.
- Linear-phase or oversampled filters.
- Rewriting the backend out of bash. The live helper removes the cost where it
  is felt; one-shot commands stay at about 250 ms.
- An absolute, calibrated analyzer. The backdrop is a shape, not a
  measurement.

## 8. Tests

| Phase | Test | What it asserts |
| --- | --- | --- |
| 1 | `tests/qml/tst_responsecurve.qml` | Handle on the line during and after a drag; frequency echo on release |
| 1 | `tests/queue-check.js` | The throttle sends at 60 ms intervals and always sends the last value |
| 2 | `tests/run-tests.sh`, "live" section | 50 lines in, at most 25 ms each on the stubs; one `pw-cli` call per coalesced line; only changed controls in each call; no `jq` between `ready` and `commit`; a bad token is refused and never reaches `pw-cli`; `commit` writes the state and one undo entry; a changed signature answers `stale`; end of input restores the graph |
| 2 | `tests/dsp-check.sh` | The click measurement of §3.1.3, pool and biquads; a streamed gain lands in the real graph within 50 ms |
| 3 | `tests/fit-check.js` | Every case of §1.4 within 0.1 dB at the centres; untouched faders do not move; clamping reports the achieved value; a preset round-trips unchanged |
| 3 | `tests/run-tests.sh` | `set-gains` is one state write and one live write; wrong count or a non-number is refused |
| 4 | `tests/run-tests.sh` | Undo/redo across gain, preset, reset, mode and import; a burst is one step; a device switch clears the stacks; `revert-preset` on a deleted preset fails cleanly |
| 5 | `tests/run-tests.sh`, `tests/dsp-check.sh` | No `pre_*` write between `ready` and `commit` with the limiter on; eight ramp steps after it; with the limiter off the preamp follows each line; the real output never passes the ceiling during a streamed +12 dB sweep |
| 6 | `tests/input-policy-check.js`, `tests/qml/` | The `"handle"` wheel rule; double-click adds at the pointer; pass-filter handle moves frequency only; a −15 dB band survives a touch; `2.5k` parses |
| 7 | `tests/headroom-check.js`, `tests/dsp-check.sh` | JS and awk agree on `programGainDb` and the Balanced preamp; the gate of §3.5.2 |
| 8 | `tests/run-tests.sh` | The flag, mute and base-volume conditions; zero for a `HW_VOLUME_CTRL` sink; the event is answered before the drain |
| 9 | `tests/qml/`, a node contrast check | The backdrop draws from 24 levels and from none; `dimColor` holds 4.5:1 |

`tests/wave-check.js` and the `LevelWave` parts of `Model.js` are removed in
phase 9 if decision 1 goes that way.

## 9. As built

All ten phases are in. The suite (607 checks) and the real-graph harness (58)
pass (§8's tests,
plus the panel's own edit path offscreen, `tests/qml/tst_panel.qml`, against
stand-ins for Quickshell's Process and the shell kit).

Where the build departs from the text above, and why:

1. **The flat gains walk; they do not step.** §3.1.3 and §3.5.1: the
   measurements found that the bands never click and the preamp does, so the
   eight-step ramps became 0.1 dB walks, and the pool cross-fades a preset.
2. **The biquad chain changes in one write.** PipeWire's builtin biquad
   resets its history on every update (§3.1.3); the live editor writes it at
   most every 100 ms. This is a property of PipeWire, recorded as INFO by the
   harness so a fix upstream shows up.
3. **Balanced's margin is 3.5 dB**, the gate's own result (§3.5.2). For a
   bass shelf it gives back 2 dB of the 9.5 dB Safe takes; for a treble lift
   or a narrow bell, 1 to 5 dB.
4. **Device relief is opt-in** (`set-device-relief on`, a switch on the
   Output tab). The text in §3.5.3 would have switched it on by itself for the
   speakers, against contract 7.
5. **The settings key is `followDeviceVolume`**; `deviceRelief` is the number
   in dB, as §5.3 has it.
6. **The press-order check is retired.** It held the order of two
   assignments to the curve's draft values, which no longer exist: the curve
   draws from the bands alone, and the QML test holds the handle on the line.

An independent review of the branch found nine problems, each fixed and now
covered by a test:

- A commit that came back stale sent no status, and the panel waited on it
  for good; every commit now answers with the status.
- A walk of the flat gains could overwrite the follower's device relief, or
  be stopped halfway by a relief-only write and strand the preamp. A walk now
  records its targets and position; a write of only some of the gains takes
  it over and writes its targets for the others in the same call, and a new
  walk starts from where the last one got to.
- A drag begun on the command queue could finish through the live editor
  ahead of its own queued commands, and a preset's cross-fade could overwrite
  a live edit: a gesture keeps the path it started on, the live editor is used
  only while nothing else is running or queued, and a commit re-sends the
  session's own controls.
- After an upgrade the live editor could stay off until the shell restarted:
  the panel tries it again when the state moves on, and the queue path walks
  the preamp too.
- A drag the panel lost (Escape mid-drag) left it "editing": cancelled drags
  end like releases, and closing the panel ends a gesture.
- Undo merged any two presets (or any two live commits) within a second; only
  a burst of one command on one band merges now.
- A volume step that landed while a retarget pass ran waited for the whole
  pass: the device relief now has the follower's own listener, which writes
  the graph without the state lock (a small lock of its own orders it against
  the pass's relief write, so the later write read the later volume).
- A follow-up check found three more, also fixed: a commit decided in the
  same turn as closing the panel could be written after the editor's input
  ended; the A/B had started to walk its level match (a comparison now
  switches at once); and a walk's step was not atomic against a takeover (the
  token check and the write now share the walk's lock).

Installed on the live session (2026-11-09, 19:58): the plugin clone was
fast-forwarded to this branch (the state before it is kept as
`state.json.3.0.0-pre-backup`), the shell reloaded the panel with no QML
warning or error, and re-applying the current mode rebuilt the running graph
into layout v4 once. Checked afterwards, read-only: both units active, the
running node carries the device relief's controls, the output stream aims at
the device (HUAWEI FreeBuds Pro 3), the app stream parked for the rebuild is
back on the equalizer, the follower runs the new code with its volume
listener, and `omarchy-equalizer live` arms on the real graph
(`ready graphic:10:10`, then end of input with nothing written).

Not verified:

- **Nothing here has been seen or heard by the user yet**: the panel by eye,
  a drag by ear, the fitted faders, undo. The panel's edit path was tested
  offscreen against stand-ins for the shell kit, and the backend on stubs and
  on a private PipeWire.
- **Device relief's live gate** (§3.5.3) plays a tone through the real
  speakers and was not run.
- **Balanced has not been heard.**
- **The screenshots** (`docs/panel.png`, `docs/presets.png`) predate this
  round.
