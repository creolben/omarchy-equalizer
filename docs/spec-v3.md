# Equalizer 3 — clean gain staging, a stereo graph, and the AudioREA features

Status: implemented on branch `clean-sound-audiorea` (2026-11-09), from the
AudioREA study of Audio Hijack 4.6 (a static, clean-room specification) and the
report that Audio Hijack's equalizer "sounds so clean". Every number below was
measured on this machine (PipeWire 1.6.9, the LSP limiter at plugin version
1.0.37, aarch64) by
`tests/dsp-check.sh`, which runs the generated graph on a private PipeWire.

## 1. Why it did not sound clean

Three things, in order of how much they mattered:

1. **Headroom cost loudness at every volume.** Automatic headroom cut the whole
   signal by the curve's biggest boost whatever the volume, so a +6 dB bass curve
   played 6 dB of everything else quieter even at half volume, where nothing could
   clip. Quieter reads as duller; the earlier review measured custom curves
   6–8 dB below Flat. Audio Hijack's equalizer leaves a boost a boost below full
   volume.
2. **The limiter distorted bass when it worked.** Holding a sine 3 dB over the
   ceiling (LSP Herm Thin, 5 ms lookahead, the old settings):

   | | 30 Hz | 50 Hz | 70 Hz | 100 Hz | 200 Hz | 1 kHz |
   | --- | --- | --- | --- | --- | --- | --- |
   | 5 ms lookahead (old) | 13.9 % | 9.7 % | 5.8 % | 0.9 % | 0.17 % | 0.00 % |
   | 20 ms lookahead/attack (new) | 0.85 % | 1.1 % | 0.08 % | 0.17 % | 0.02 % | 0.00 % |

   The release time made no difference (LSP clamps it to 20 ms); the wider
   envelope shapes and ALR all measured worse, and ALR also held a sustained
   overload ~7 dB under the ceiling.
3. **Each channel was limited and compressed on its own** (mono plugins
   duplicated per channel), so a loud hit on one side pulled the image across.

## 2. What changed

- **Layout v3**, one stereo graph for both band paths: preamp → channels
  (stereo/mono/swap, balance) → bands → leveler → boost → relief → volume →
  limiter, with explicit inputs/outputs and the LSP stereo builds.
- **Volume relief**: `relief = min(cut, −volume)`, a gain stage after the
  dynamics. The follower keeps it in step (draining an event burst for at most
  0.5 s, so a held volume key still gets passes); the limiter covers the moment
  between a fast volume change and the next pass, so there is no relief while
  the limiter is off or LSP is missing.
- **The volume in the graph** (`capture.volumes` on `vol_l/vol_r`): measured, it
  is applied after the bands and dynamics and before the limiter, and mute still
  silences.
- **Limiter**: Herm Thin, 20 ms lookahead and attack, stereo link 100 %, ALR off.
- **Dynamics**: the old one-character boost keeps its three strengths and gains
  Night and Voice; both channels are detected together from the louder (`ssplit
  0`, `scs_N 5`). Measured, a 30 dB step comes out 12.5 dB (Night) and 17.2 dB
  (Voice); Off is exactly 30.0 dB.
- **Leveler** (`autogain_stereo`, −18 LUFS, ≤ +12 dB): a −40 dBFS tone rises
  10.3 dB over 8 s; a −3 dBFS tone is held at −15 dBFS.

## 3. From the AudioREA catalogue

| Spec item | Here |
| --- | --- |
| Output Device block keeps a device identity (02 §2.2) | A curve per output device (`device-memory`, on by default) |
| Switch block, A/B inputs (02 §2.5) | `compare`: Flat at the curve's own loudness (pink/A-weighted level, the presets' own measure) |
| PEQ bands carry `enabled` and `slope` (02 §2.5) | Bypass, solo; slopes 1–4 as cascaded Butterworth slots |
| Balance, Channels (mono, swap) (02 §2.3) | Two builtin mixers ahead of the bands; the balance only ever turns a side down |
| Simple Compressor modes Music/Movie/Voice (02 §2.3) | Boost Low/Medium/High plus Night and Voice |
| System-wide source `excludedApps` (02 §2.1, 01 §4.2) | `exclude-app` / `include-app`, followed by the follower |
| Session version + round-trip of unknown keys (02 §3, §5) | `state.json` carries `version: 3`; unknown keys survive edits; a newer version is not written back down |
| Offline sweep/impulse/null harness first (00 §8) | `tests/dsp-check.sh` |
| Latency budget (00 §4) | The plugins add 22 ms on top of the quantum; the builtin chain adds 0 |
| Original names (00 §1, §6) | "Magic Boost" is now the boost under Dynamics; no other product's names in the UI |

Not taken: capture, recording, broadcast, transcription and AU hosting (01, 03,
04 §2) — PipeWire already routes, and the filter-chain already runs its LV2
plugins in a process of its own.

## 4. Findings the measurements made

- LSP's `s_N` slope control does nothing in the APO (DR) mode the pool runs: ×2
  and ×4 respond exactly like ×1. Slopes are therefore extra slots, which
  `Model.js` and the backend's awk model exactly (slope 2 at Q 0.707 is a true
  4th-order Butterworth, −3.01 dB at the corner).
- Every APO (DR) type matches the RBJ maths `Model.js` draws within 0.06 dB, on
  the pool and on the builtin biquads: the assumption the whole curve and the
  headroom rest on, measured for the first time.
- The filter-chain's reported ProcessLatency reads 0 on a private daemon even
  while playing, so latency is measured instead: one recording holds the graph's
  output and its input side by side.

## 5. Fixed in review

An independent review of the branch found these, each now covered by a test:

- A rebuild the follower starts restarts the follower with it (`PartOf`), so
  streams parked on the device during it were never returned. The parked ids
  are now written to `parked-streams` before the restart, and the next
  follower's first pass returns them.
- Solo computed its own headroom but played under the curve's; it now plays
  under the smaller of the two, and a bypassed band can be soloed.
- A preamp or headroom change during an A/B ended it in the state but left Flat
  playing; it now writes the bands back. The fragment carries the override, so a
  restart keeps sound and state in agreement.
- The relief could clip without a limiter to catch a fast volume change; it now
  needs the limiter.
- A curve picked while the equalizer was off was filed under the old device and
  replaced at enable by the new device's remembered curve; it is now the curve
  the next enable plays.
- A type change kept the old slope, which came back the next time the band was
  a pass filter again (and could overflow the slots); a type change now resets
  it.
- Smaller: an app excluded by its binary could not be put back by the name the
  panel shows; a manual device pick moved excluded apps onto the EQ for a moment.

## 6. Installed on the live session (2026-11-09, 16:32)

The plugin clone was switched to this branch and rebuilt once (`set-mode
graphic`): both units restarted cleanly with no control warnings, the running
node carries the v3 controls (mixers, the stereo pool, leveler, linked boost,
relief, in-graph volume, linked limiter), the EQ output feeds the J313 speakers,
and the shell hot-reloaded the plugin with no QML errors.

One finding: Omarchy's volume keys (`omarchy-audio-output-volume`) resolve
through DSP sinks, the equalizer included, to the device behind it, so the
equalizer's own volume stays at 100% and the relief stays at zero with them. The
relief cannot simply read the device's volume instead: a device's volume can be
in hardware (Bluetooth), where the signal must stay under full scale. Making the
relief work with the keys would need the device's volume to be known to be
software (the J313 DSP sink's is) and the relief to sit after the limiter --
a design for a later round, measured first. What does apply with the keys is the
cleaner, linked limiter: with boost High and the equalizer at full level, it was
limiting constantly.

## 7. Live-verified, and not

Verified read-only on the live session: `parec --monitor-stream` records the
EQ's output stream (the meter now shows what is heard, after the EQ).

Not verified on the live session (the installed plugin is a separate clone that
still runs 2.0.1):

- The volume keys driving the in-graph volume through WirePlumber (measured on
  the private daemon through `channelVolumes`, which is what pipewire-pulse sets).
- The per-device curves across a real earbud case-in/case-out cycle (tested on
  the stubs: connect, drop to the speakers, return under the other profile).
- The panel's new controls, by eye — the QML parses and the band row and curve
  have offscreen tests; `docs/panel.png` predates them.
- Night, Voice and the leveler by ear: the settings are measured for direction
  and size, not tuned by listening.
