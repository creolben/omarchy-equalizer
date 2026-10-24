#!/bin/bash
# Backend tests for omarchy-equalizer.
#
# They run against stubbed pactl / pw-cli / pw-dump / systemctl / curl (tests/bin,
# first on PATH) and against a throwaway XDG_CONFIG_HOME / XDG_STATE_HOME, so no
# real sink, fragment or systemd unit is touched -- the machine's audio keeps
# playing while these run. The systemctl stub logs its arguments so "this edit did
# not restart the unit" is an assertion rather than an observation; the pw-cli stub
# does the same so the cross-fade's step count and final values are asserted too.
#
# Run: bash tests/run-tests.sh
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# Prefer the platform's temp dir, but fall back to /tmp when TMPDIR points at a
# read-only location (some sandboxes do). Exported so the backend's own mktemp
# uses the same writable place.
tmp_root="${TMPDIR:-/tmp}"
[[ -w $tmp_root ]] || tmp_root=/tmp
export TMPDIR="$tmp_root"
T="$tmp_root/omarchy-equalizer-tests.$$"
E="$here/../bin/omarchy-equalizer"
export PATH="$here/bin:/usr/bin:/bin"
export XDG_CONFIG_HOME="$T/config"
export XDG_STATE_HOME="$T/state"
export SYSTEMCTL_LOG="$T/systemctl.log"
export CURL_LOG="$T/curl.log"
export PWCLI_LOG="$T/pw-cli.log"
# Most tests care that a change reaches the graph live, not how it fades there;
# collapsing the ramp to one write keeps them fast and free of sleeps. The ramp
# section unsets this so it can count the steps.
export OMARCHY_EQ_NO_RAMP=1
# A vanished output target is normally given a grace period before the fallback
# replaces it; the routing tests exercise the replacement itself, and the grace
# section turns it back on.
export OMARCHY_EQ_VANISH_GRACE=0
mkdir -p "$T"
rm -rf "$T/config" "$T/state"
: >"$SYSTEMCTL_LOG"; : >"$CURL_LOG"; : >"$PWCLI_LOG"

# The output stage checks for the two LSP mono plugins under this root. Empty
# TTLs are enough -- lsp_available only needs the files to exist -- and the
# missing-plugin section swaps in a root without them.
export OMARCHY_EQ_LV2_DIR="$T/lv2"
mkdir -p "$OMARCHY_EQ_LV2_DIR/lsp-plugins.lv2"
: >"$OMARCHY_EQ_LV2_DIR/lsp-plugins.lv2/mb_compressor_mono.ttl"
: >"$OMARCHY_EQ_LV2_DIR/lsp-plugins.lv2/limiter_mono.ttl"

pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s -- %s\n' "$1" "$2"; fail=$((fail+1)); }
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
run() { "$E" "$@" 2>&1; }

# Put an arbitrary band set into the state and read back the backend's automatic
# preamp. This is the comparison point for the awk port of Model.autoPreampDb: it
# needs no backend mutation, only the state the status command reads.
backend_auto_preamp() { # mode bands-json
  local mode="$1" bands="$2"
  mkdir -p "$XDG_STATE_HOME/omarchy-equalizer"
  jq -c -n --arg m "$mode" --argjson b "$bands" '
    { enabled: false, mode: $m, preset: "Test", preamp: 0, headroom: "auto",
      graphic: [], parametric: [] }
    | if $m == "graphic" then .graphic = $b else .parametric = $b end' \
    >"$XDG_STATE_HOME/omarchy-equalizer/state.json"
  run status | jq -r '.autoPreamp'
}

mkdir -p "$T"

echo "== validation =="
out="$(run set-gain 0 abc)"; rc=$?
check "set-gain rejects a non-number" "1|'abc' is not a number." "$rc|$out"
out="$(run set-preamp nope)"; rc=$?
check "set-preamp rejects a non-number" "1|'nope' is not a number." "$rc|$out"
out="$(run set-band 0 freq xyz)"; rc=$?
check "set-band rejects a non-number" "1|'xyz' is not a number." "$rc|$out"
out="$(run remove-band 99)"; rc=$?
check "remove-band rejects an out-of-range index" "1|Band 99 does not exist." "$rc|$out"
out="$(run remove-band zz)"; rc=$?
check "remove-band rejects a non-number" "1|Band index must be a plain number." "$rc|$out"

echo "== band values are range-checked, and a failure never empties the state =="
# A well-formed profile can still be dangerous: "Gain 120 dB" with a negative Q is
# about +96 dB through auto headroom's -24 dB floor. And any jq or awk failure
# upstream of the write used to leave a 0-byte state.json, losing the bands and
# both remembered sinks.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-gain 0 3 >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
before="$(cat "$st")"
out="$(run set-band 0 gain 120)"; rc=$?
check "an out-of-range gain is refused" "1|Band 0 gain 120 is outside -30..20 (graphic set)." "$rc|$out"
out="$(run set-band 0 q -0.5)"; rc=$?
check "a negative Q is refused" "1" "$rc"
out="$(run set-band 0 freq 90000)"; rc=$?
check "an out-of-range freq is refused" "1" "$rc"
out="$(run set-band 0 type "a b c d e")"; rc=$?
check "an unknown filter type is refused" "1" "$rc"
check "the refusal names the type" "1" "$(grep -c 'is not one of' <<<"$out")"
out="$(run set-gain 18446744073709551615 5)"; rc=$?
check "an overflowing band index is refused" "1" "$rc"
out="$(run set-gain 010 5)"; rc=$?
check "a leading-zero band index is refused (bash reads it as octal)" "1" "$rc"
check "the refusals leave the state intact" "$before" "$(cat "$st")"
check "the graphic set still has 10 bands" "10" "$(jq '.graphic | length' "$st")"
mkdir -p "$XDG_STATE_HOME/omarchy-equalizer"
jq -c '. + { "Nan Preamp": { mode: "graphic", preamp: "+nan", graphic: [] } }' \
  "$XDG_STATE_HOME/omarchy-equalizer/presets.json" 2>/dev/null >"$T/p.json" ||
  printf '{"Nan Preamp":{"mode":"graphic","preamp":"+nan","graphic":[]}}\n' >"$T/p.json"
mv "$T/p.json" "$XDG_STATE_HOME/omarchy-equalizer/presets.json"
out="$(run apply-preset "Nan Preamp")"; rc=$?
check "a non-numeric preset preamp is refused" "1" "$rc"
check "the nan preamp never reaches the state" "$before" "$(cat "$st")"
check "the state file is never left empty" "yes" "$([[ -s $st ]] && echo yes || echo no)"
printf 'Preamp: -6 dB\nFilter 1: ON PK Fc 1000 Hz Gain 120 dB Q -0.5\n' >"$T/Loud ParametricEQ.txt"
out="$(run import-autoeq "$T/Loud ParametricEQ.txt")"; rc=$?
check "an out-of-range AutoEq profile is refused" "1" "$rc"
check "the profile refusal says why" "1" "$(grep -c 'The profile is out of range: Band 0 gain 120' <<<"$out")"
check "the refused profile saves no preset" "0" "$(run presets | grep -c '^Loud$')"
jq -c 'del(.["Nan Preamp"])' "$XDG_STATE_HOME/omarchy-equalizer/presets.json" >"$T/p.json" &&
  mv "$T/p.json" "$XDG_STATE_HOME/omarchy-equalizer/presets.json"
rm -f "$st"

echo "== graph rate =="
check "the status carries the graph rate, not a hardcoded one" "44100" "$(run status | jq -r '.sampleRate')"

echo "== headroom =="
check "default status reports headroom auto" "auto" "$(run status | jq -r '.headroom')"
run set-mode graphic >/dev/null
run reset >/dev/null
run set-gain 5 6 >/dev/null
check "the preamp tracks the automatic value" "true" \
  "$(jq -cn --argjson a "$(run status | jq -r '.preamp')" --argjson b "$(run status | jq -r '.autoPreamp')" '($a - $b) == 0')"
preamp="$(run status | jq -r '.preamp')"
check "a +6 dB band gets a preamp between -6.5 and -6" "yes" \
  "$(LC_ALL=C awk -v p="$preamp" 'BEGIN { print (p <= -6 && p >= -6.5) ? "yes" : "no" }')"
run reset >/dev/null
run set-gain 5 -6 >/dev/null
check "a cut-only curve needs no preamp" "0" "$(run status | jq -r '.preamp')"
run set-preamp -3 >/dev/null
check "set-preamp switches headroom to manual" "manual" "$(run status | jq -r '.headroom')"
run set-gain 5 6 >/dev/null
check "a boost lowers the ceiling to the value Auto would pick" "true" \
  "$(jq -cn --argjson a "$(run status | jq -r '.preampCeiling')" --argjson b "$(run status | jq -r '.autoPreamp')" '($a - $b) == 0')"
check "a hand-set preamp above the ceiling is clamped to it" "-6.0" "$(run status | jq -r '.preamp')"
run set-headroom auto >/dev/null
check "set-headroom auto recomputes the preamp" "true" \
  "$(jq -cn --argjson a "$(run status | jq -r '.preamp')" --argjson b "$(run status | jq -r '.autoPreamp')" '($a - $b) == 0')"
out="$(run set-headroom bogus)"; rc=$?
check "set-headroom rejects anything else" "1|Headroom must be auto or manual." "$rc|$out"

echo "== headroom on a state written before the field =="
run set-mode graphic >/dev/null
state="$XDG_STATE_HOME/omarchy-equalizer/state.json"
jq 'del(.headroom)' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
check "a state without headroom reads as auto" "auto" "$(run status | jq -r '.headroom')"

echo "== automatic headroom matches Model.js =="
rate="$(run status | jq -r '.sampleRate')"
set1="$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000]
  | map({ type: "peaking", freq: ., q: 1.41, gain: (if . == 1000 then 6 else 0 end) })')"
set2='[{"type":"lowshelf","freq":80,"q":0.71,"gain":8},{"type":"highshelf","freq":8000,"q":0.71,"gain":4}]'
set3='[{"type":"lowshelf","freq":105,"q":0.70,"gain":6.4},{"type":"peaking","freq":8800,"q":1.42,"gain":5.1},{"type":"highshelf","freq":10000,"q":0.70,"gain":-2.1},{"type":"peaking","freq":1000,"q":1.0,"gain":-3.2},{"type":"peaking","freq":3000,"q":1.4,"gain":2.4}]'
jq -cn --argjson a "$set1" --argjson b "$set2" --argjson c "$set3" '[$a, $b, $c]' >"$T/headroom-sets.json"
model="$(node "$here/headroom-check.js" "$rate" "$T/headroom-sets.json")"
modes=(graphic parametric parametric)
for i in 0 1 2; do
  bands="$(jq -c ".[$i]" "$T/headroom-sets.json")"
  got="$(backend_auto_preamp "${modes[$i]}" "$bands")"
  want="$(jq -r ".[$i]" <<<"$model")"
  check "auto headroom matches Model.autoPreampDb for set $((i + 1))" "true" \
    "$(jq -cn --argjson a "$got" --argjson b "$want" '($a - $b) == 0')"
done
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== live vs rebuild =="
# In parametric mode with LSP the 16-slot pool is resident, so a type change is a
# values write: no restart, and the whole slot set goes out in one pw-cli call.
run set-mode parametric >/dev/null
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 3 type lowshelf >/dev/null
check "a parametric type change does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a parametric type change is one pw-cli call" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "the type change writes the pool slot" "yes" "$(grep -q '"para:ft_3" 5' "$PWCLI_LOG" && echo yes || echo no)"
check "the type change keeps the fragment's pool slot in step" "yes" \
  "$(grep -q '"ft_3" = 5' "$frag" && echo yes || echo no)"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 3 freq 300 >/dev/null
check "a frequency change does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "and reaches the pool live" "yes" "$(grep -q '"para:f_3" 300' "$PWCLI_LOG" && echo yes || echo no)"
run set-band 3 q 2.5 >/dev/null
check "a Q change does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
run set-gain 3 -4.5 >/dev/null
check "a gain change does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a gain change reaches the pool live" "yes" "$(grep -q '"para:g_3" 0.595662' "$PWCLI_LOG" && echo yes || echo no)"
check "the frequency edit was persisted" "300" "$(run status | jq -r '.bands[3].freq')"
check "the type edit was persisted" "lowshelf" "$(run status | jq -r '.bands[3].type')"

echo "== empty band list =="
for i in $(seq 1 8); do run remove-band 0 >/dev/null; done
check "every parametric band can be removed" "0" "$(run status | jq -r '.bands | length')"
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "the fragment has no link to a missing node" "0" "$(grep -c 'g0:In' "$frag")"
check "the fragment still hosts the preamp" "1" "$(grep -c 'name = pre' "$frag")"
out="$(run remove-band 0)"; rc=$?
check "removing from an empty set is refused" "1|Band 0 does not exist." "$rc|$out"
run add-band >/dev/null
check "a band can be added back" "1" "$(run status | jq -r '.bands | length')"

echo "== headroom ceiling =="
# A hand-set preamp is headroom, not a volume control: it may never hold more gain
# than the curve's own peak, or the limiter removes the difference from every
# sample and the panel reports nothing wrong. The ceiling is enforced in the stored
# state, in the running graph and in the fragment on disk.
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
run set-mode graphic >/dev/null
run reset >/dev/null
run set-gain 5 6 >/dev/null
run set-headroom manual >/dev/null
: >"$PWCLI_LOG"
out="$(run set-preamp 10 2>&1)"
check "set-preamp above the ceiling says so" "1" "$(grep -c 'above the headroom ceiling' <<<"$out")"
check "the ceiling is stored instead of the value asked for" "-6.0" "$(run status | jq -r '.preamp')"
check "the ceiling reaches the running graph" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"pre:Mult" 0.501187' && echo yes || echo no)"
check "the fragment follows the live preamp" "1" "$(grep -c '"Mult" = 0.501187' "$frag")"
out="$(run set-preamp -8 2>&1)"
check "a preamp below the ceiling is left alone" "0" "$(grep -c 'above the headroom ceiling' <<<"$out")"
check "and is what the graph and the state hold" "-8" "$(run status | jq -r '.preamp')"
check "and is what the fragment holds" "1" "$(grep -c '"Mult" = 0.398107' "$frag")"

echo "== built-in presets carry their own headroom =="
# A preset's preamp has to be exactly what the backend computes for its own curve.
# "asks for no clamp" is the weaker half of that: the clamp only stops a preset
# asking for MORE gain than its curve can take, so a preset declaring less than it
# needs still plays quieter than Flat for no reason. The numbers in the files are
# generated from auto_preamp_db, and this is what keeps them from drifting.
run set-mode graphic >/dev/null
for f in "$here/../presets"/*.json; do
  name="$(basename "$f" .json)"
  mode="$(jq -r '.mode' "$f")"
  bands="$(jq -c --arg m "$mode" 'if $m == "graphic" then .graphic else .parametric end' "$f")"
  out="$(run apply-preset "$name" 2>&1)"
  check "applying '$name' asks for no clamp" "0" "$(grep -c 'above the headroom ceiling' <<<"$out")"
  check "'$name' declares the preamp its own curve needs" \
    "$(backend_auto_preamp "$mode" "$bands")" "$(jq -r '.preamp' "$f")"
done
# backend_auto_preamp writes its own state to read status back, and the last one
# leaves a state with an empty band array. Drop it so the next section starts from
# the defaults rather than from a chain with nothing in it.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== built-in presets are level-matched =="
# Clicking through the preset list is a loudness comparison as much as a tone one:
# a set built from boosts plays 3-7 dB below Flat, so every comparison is really
# "quieter" versus "quieter still" and the missing loudness cannot be won back at
# full volume. tests/preset-levels.js measures the applied curve with the plugin's
# own model and holds every preset inside a couple of dB of Flat.
node "$here/preset-levels.js" >"$T/preset-levels.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/preset-levels.log"
check "every built-in preset is level-matched, in range, and describes itself" "0" "$rc"

echo "== the panel's response metrics are computed once per band change =="
node "$here/metrics-check.js" >"$T/metrics-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/metrics-check.log"
check "the metrics memo is correct and builds coefficients once" "0" "$rc"

echo "== the meter: spectrum parsing, the Lottie bar motion, and beats =="
node "$here/wave-check.js" >"$T/wave-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/wave-check.log"
check "the meter functions are pure, bounded, and parse only real frames" "0" "$rc"

echo "== one input policy: the wheel scrolls, it does not edit =="
node "$here/input-policy-check.js" >"$T/input-policy-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/input-policy-check.log"
check "the wheel policy follows the rule table exactly" "0" "$rc"

echo "== a band's first drag starts from its own frequency =="
# The press handler must read the band's frequency before it marks the band as
# dragged: bandFreqAt() answers with draftFreq for the dragged band, so the other
# order reads back the previous drag -- 0 on the first one -- and the handle is
# drawn at the 1 kHz fallback. tests/press-order-check.js holds the order, and
# fails against the pre-fix handler.
node "$here/press-order-check.js" >"$T/press-order-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/press-order-check.log"
check "the press handler reads the frequency before it marks the drag" "0" "$rc"

echo "== the preamp slider is plugin-owned and cannot take the wheel =="
check "the preamp slider is the plugin's own component" "yes" \
  "$(grep -q 'PreampSlider' "$here/../Panel.qml" && echo yes || echo no)"
check "the shell's wheel-adjusting PanelSlider is no longer used" "0" \
  "$(grep -c 'PanelSlider' "$here/../Panel.qml")"

echo "== the panel queue keeps distinct edits apart =="
node "$here/queue-check.js" >"$T/queue-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/queue-check.log"
check "queue keys and the band settle timer hold" "0" "$rc"

echo "== the curve maths matches PipeWire's biquads =="
node "$here/curve-check.js" >"$T/curve-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/curve-check.log"
check "curve-check.js passes" "0" "$rc"

echo "== concurrent commands do not lose edits =="
# Each command reads, edits and writes the whole state; without the lock ten
# parallel gain changes kept one.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode graphic >/dev/null
for i in 0 1 2 3 4 5 6 7 8 9; do run set-gain "$i" 2 >/dev/null & done; wait
check "ten parallel gain changes all land" "10" \
  "$(jq '[.graphic[] | select(.gain == 2)] | length' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== preset list =="
check "every preset file is listed" \
  "$(ls "$here/../presets"/*.json | wc -l)" "$(run status | jq '[.presets[] | select(.builtin)] | length')"
check "the list is in the order the files declare" "Flat,Bass Boost,Treble Boost" \
  "$(run status | jq -r '[.presets[] | select(.builtin) | .name] | .[0:3] | join(",")')"
check "the list carries a description for the selected preset" "yes" \
  "$(run status | jq -r '[.presets[] | select(.name == "Rock")][0].description | if . == null then "no" else "yes" end')"
check "a built-in is marked as one" "true" \
  "$(run status | jq -r '[.presets[] | select(.name == "Rock")][0].builtin')"
check "every built-in preset carries a category" \
  "$(ls "$here/../presets"/*.json | wc -l)" \
  "$(run status | jq '[.presets[] | select(.builtin) | select(.category != null and .category != "other")] | length')"
check "the list carries the category the file declares" "genre" \
  "$(run status | jq -r '[.presets[] | select(.name == "Rock")][0].category')"

echo "== the panel can tell an edited preset from the loaded one =="
run set-mode graphic >/dev/null
run apply-preset Rock >/dev/null
check "a freshly applied preset is not marked edited" "false" \
  "$(run status | jq -r '.presetDirty')"
rock_gain="$(run status | jq -r '.bands[5].gain')"
run set-gain 5 -1 >/dev/null
check "changing one band marks the preset edited" "true" \
  "$(run status | jq -r '.presetDirty')"
run set-gain 5 "$rock_gain" >/dev/null
check "restoring the band clears the edited mark" "false" \
  "$(run status | jq -r '.presetDirty')"
# A user preset is compared the same way, and a deleted one must not look
# edited: the state still names it ("Custom" after deletion), but no preset
# document resolves, so there is nothing to compare against.
run save-preset ScratchDirty >/dev/null
run apply-preset ScratchDirty >/dev/null
check "a user preset is categorised as user" "user" \
  "$(run status | jq -r '[.presets[] | select(.name == "ScratchDirty")][0].category')"
check "a freshly saved preset is not marked edited" "false" \
  "$(run status | jq -r '.presetDirty')"
run delete-preset ScratchDirty >/dev/null
check "a preset whose file is gone does not read as edited" "false" \
  "$(run status | jq -r '.presetDirty')"
check "and its label falls back to Custom" "Custom" \
  "$(run status | jq -r '.preset')"
# A graphic-only preset says nothing about parametric mode: the absent array
# must read as not edited, since there is no preset shape to differ from.
run apply-preset Flat >/dev/null
run set-mode parametric >/dev/null
check "a graphic preset viewed in parametric mode is not edited" "false" \
  "$(run status | jq -r '.presetDirty')"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== routing: a DSP output is chained in front of, not resolved past ==
# WirePlumber resolves a DSP sink's stream down to the hardware it feeds. Chaining
# the equalizer in front of the DSP sink keeps the speaker tuning in the path; a
# target of the hardware underneath would silently drop it for as long as the EQ
# was on, which on an Asahi laptop is the biggest single part of how the speakers
# sound."
run disable >/dev/null
export PACTL_DEFAULT_SINK=audio_effect.stub-dsp
export PACTL_DEVICE_SINK=audio_effect.stub-dsp
run enable >/dev/null
check "the chain plays into the DSP sink" "1" \
  "$(grep -c 'target.object = "audio_effect.stub-dsp"' "$frag")"
check "the hardware under it is not the target" "0" "$(grep -c 'alsa_output.stub' "$frag")"
check "the DSP sink is remembered as the previous default" "audio_effect.stub-dsp" \
  "$(jq -r '.previousDefaultSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK
run enable >/dev/null
run disable >/dev/null

echo "== a restart parks the app streams instead of dropping them =="
# With LSP nothing here restarts (both modes run in the pool), so this is the
# biquad chain of a machine without it, where a mode change still rebuilds.
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"; mkdir -p "$OMARCHY_EQ_LV2_DIR"
# A graph-shape change restarts the chain, and the EQ sink vanishes for a moment.
# A browser playing into it takes that as its device going away and pauses the
# song. The streams are parked on the device the EQ plays into for the restart and
# brought back to the new sink after it.
run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC
export PACTL_DEFAULT_SINK=bluez_output.12_34_56_78_9A.BC
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
run set-mode graphic >/dev/null
export PACTL_APP_STREAM=1 PACTL_LOG="$T/pactl-park.log"; : >"$PACTL_LOG"; : >"$SYSTEMCTL_LOG"
run apply-preset "Small Speakers" >/dev/null
check "the mode-changing preset still restarts the chain" "1" "$(grep -c '^--user restart' "$SYSTEMCTL_LOG")"
check "the app stream is parked on the device, then returned to the EQ" \
  "move-sink-input 42 bluez_output.12_34_56_78_9A.BC|set-default-sink omarchy_equalizer|move-sink-input 42 omarchy_equalizer" \
  "$(grep -E '^(move-sink-input|set-default-sink)' "$PACTL_LOG" | paste -sd'|')"
run set-mode graphic >/dev/null
unset PACTL_APP_STREAM PACTL_LOG PACTL_DEFAULT_SINK PACTL_DEVICE_SINK
run disable >/dev/null
run enable >/dev/null

echo "== a restart that does not come back leaves the parked streams for the follower =="
# If the sink never returns, the streams parked on the device would play there
# unequalized for good. They are remembered in the state, and the follower's
# next pass -- once systemd has brought the sink back -- returns them.
run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC
export PACTL_DEFAULT_SINK=bluez_output.12_34_56_78_9A.BC
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
run set-mode graphic >/dev/null
export PACTL_APP_STREAM=1 PACTL_LOG="$T/pactl-fail.log" OMARCHY_EQ_RESTART_TIMEOUT=1
export SYSTEMCTL_RESTART_FAILS="$T/eq-gone" PACTL_NO_EQ_SINK="$T/eq-gone"
rm -f "$T/eq-gone"; : >"$PACTL_LOG"
run apply-preset "Small Speakers" >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
check "the stream was parked on the device" "1" \
  "$(grep -c '^move-sink-input 42 bluez_output.12_34_56_78_9A.BC$' "$PACTL_LOG")"
check "nothing is moved back onto a sink that is not there" "0" \
  "$(grep -c '^move-sink-input 42 omarchy_equalizer$' "$PACTL_LOG")"
check "the parked stream is remembered" "[42]" "$(jq -c '.parkedStreams' "$st")"
# systemd brings the sink back; the follower's pass returns the stream.
rm -f "$T/eq-gone"; unset SYSTEMCTL_RESTART_FAILS; : >"$PACTL_LOG"
run retarget >/dev/null
check "the follower returns the parked stream" "1" \
  "$(grep -c '^move-sink-input 42 omarchy_equalizer$' "$PACTL_LOG")"
check "and takes the default back" "1" "$(grep -c '^set-default-sink omarchy_equalizer$' "$PACTL_LOG")"
check "the parked record is cleared" "null" "$(jq -c '.parkedStreams // null' "$st")"
unset PACTL_APP_STREAM PACTL_LOG OMARCHY_EQ_RESTART_TIMEOUT PACTL_NO_EQ_SINK
run set-mode graphic >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK
run disable >/dev/null
export OMARCHY_EQ_LV2_DIR="$T/lv2"
run enable >/dev/null

echo "== routing: a vanished target is replaced, not trusted =="
# A Bluetooth device that is switched off, sleeps, or errors out disappears from
# pactl entirely. While the EQ is on the default sink is the EQ itself, so the
# removed device never appears as a changed default and the manual retarget path
# below never fires; the remembered target simply dangles, the graph stays
# healthy-looking, and sound stops everywhere. The follower re-validates the
# target on the removal event: a dead one is replaced by a device that still
# exists, and with nothing else live it is kept for the device's return.

run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC
export PACTL_DEFAULT_SINK=bluez_output.12_34_56_78_9A.BC
run enable >/dev/null
check "enable remembers the device that was default" "bluez_output.12_34_56_78_9A.BC" \
  "$(jq -r '.targetSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"

# The device is switched off: it drops from pactl and the EQ takes the default.
unset PACTL_DEVICE_SINK
export PACTL_DEFAULT_SINK=omarchy_equalizer
: >"$SYSTEMCTL_LOG"
frag_before="$(cat "$frag")"
out="$(run retarget)"; rc=$?
check "retargeting with a dead target and no live output succeeds" "0" "$rc"
check "a dead target with nothing to fall back to is kept" \
  "bluez_output.12_34_56_78_9A.BC" "$(jq -r '.targetSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
check "keeping a dead target does not rewrite the fragment" "$frag_before" "$(cat "$frag")"
check "keeping a dead target does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"

# A device appears while the EQ still owns the default -- the real-device tug of
# war a BT speaker logging back in, or the user plugging in USB -- and the aim
# moves to it without any user gesture.
export PACTL_DEVICE_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
out="$(run retarget)"; rc=$?
check "retargeting onto a live device succeeds" "0" "$rc"
check "the aim moves to the live device" "alsa_output.pci-0000_00_1f.3.analog-stereo" \
  "$(jq -r '.targetSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
check "the fragment names the live device" "1" \
  "$(grep -c 'target.object = "alsa_output.pci-0000_00_1f.3.analog-stereo"' "$frag")"
check "the re-aim is a live move, not a restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "the previous default is left as the user's device of record" \
  "bluez_output.12_34_56_78_9A.BC" "$(jq -r '.previousDefaultSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"

# A default that points at a real device is the user's own gesture, and keeps the
# manual path -- not the fallback.
export PACTL_DEFAULT_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
state_before="$(jq -c '.targetSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
out="$(run retarget)"; rc=$?
check "a user's device pick still re-aims through the manual path" "0" "$rc"
check "the manual path keeps the same aim for the live device" "$state_before" \
  "$(jq -c '.targetSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK

echo "== routing: the stream's aim is converged onto the remembered target =="
# A pactl move is a one-shot redirect: no target.object lands on the stream, so
# WirePlumber is free to relink it right after, and one second after the user
# picks a device their stream can be on the highest-priority sink while state
# and fragment name what they chose -- issue #2's one-second swing. A retarget
# pass therefore reads the EQ output stream's actual sink back and moves it over
# whenever the two disagree, instead of assuming the last move stuck.
run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC
export PACTL_DEFAULT_SINK=bluez_output.12_34_56_78_9A.BC
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
export PACTL_LOG="$T/pactl-reconverge.log"
: >"$SYSTEMCTL_LOG"
: >"$PACTL_LOG"

# The stream has drifted back onto the EQ itself: the convergence pass pushes it
# at the remembered device.
export PACTL_EQ_AIM=drifted
export PACTL_EQ_AIM_SINK_ID=1
out="$(run retarget)"; rc=$?
check "retargeting a drifted stream succeeds" "0" "$rc"
check "a drifted stream is moved onto the remembered target" "1" \
  "$(grep -c 'move-sink-input 99 bluez_output.12_34_56_78_9A.BC' "$PACTL_LOG")"
check "the convergence pass is a live move, not a restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"

# The stream now sits on the remembered device: a converged pass must not keep
# moving it, nor chase its own tail.
export PACTL_EQ_AIM_SINK_ID=2
out="$(run retarget)"; rc=$?
check "a converged stream is left where it is" "1" \
  "$(grep -c 'move-sink-input 99 bluez_output.12_34_56_78_9A.BC' "$PACTL_LOG")"

# The dead-target replacement and a drifted stream land in one pass: the
# fallback picks the live device, and the stream is pushed at it immediately.
export PACTL_DEVICE_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
export PACTL_EQ_AIM_SINK_ID=1
out="$(run retarget)"; rc=$?
check "a dead target plus a drifted stream is one pass" "0" "$rc"
check "the replacement re-aims the drifted stream at the live device" "1" \
  "$(grep -c 'move-sink-input 99 alsa_output.pci-0000_00_1f.3.analog-stereo' "$PACTL_LOG")"
check "the fallback target lands in the state" "alsa_output.pci-0000_00_1f.3.analog-stereo" \
  "$(jq -r '.targetSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
check "the replacement names the live device in the fragment" "1" \
  "$(grep -c 'target.object = "alsa_output.pci-0000_00_1f.3.analog-stereo"' "$frag")"
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID PACTL_LOG

echo "== follow: a move that does not stick backs off =="
run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC
export PACTL_DEFAULT_SINK=$PACTL_DEVICE_SINK
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
export PACTL_LOG="$T/pactl-follow.log"; : >"$PACTL_LOG"
export PACTL_EQ_AIM=drifted PACTL_EQ_AIM_SINK_ID=1   # the stream never stays put
export PACTL_SUBSCRIBE_COUNT=6
out="$(run follow)"
# Start + 4 events = 5 passes, then the backoff; the 2 events that arrive during
# it are drained as one pass.
check "events during the backoff coalesce into one pass" "6" \
  "$(grep -c 'move-sink-input 99 bluez_output.12_34_56_78_9A.BC' "$PACTL_LOG")"
check "a stream that keeps drifting is logged" "1" "$(grep -c 'keeps drifting; backing off' <<<"$out")"
check "each convergence move is logged" "6" "$(grep -c 'moving it to bluez_output' <<<"$out")"
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID PACTL_LOG PACTL_SUBSCRIBE_COUNT

echo "== routing: a vanished target adopts the sink WirePlumber chose, not listing order =="
run disable >/dev/null
unset PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID
export PACTL_DEVICE_SINK=alsa_output.platform-sound.HiFi__Headphones__sink
export PACTL_DEVICE_SINK2=audio_effect.j313-convolver
export PACTL_DEFAULT_SINK=bluez_output.12_34_56_78_9A.BC
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
export PACTL_LOG="$T/pactl-adopt.log"; : >"$PACTL_LOG"
export PACTL_EQ_AIM=1 PACTL_EQ_AIM_SINK_ID=3
run retarget >/dev/null
check "a vanished target adopts the stream's live aim" "audio_effect.j313-convolver" \
  "$(jq -r '.targetSink' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
check "adopting the aim moves nothing" "0" "$(grep -c 'move-sink-input' "$PACTL_LOG")"
check "the fragment names the adopted sink" "1" \
  "$(grep -c 'target.object = "audio_effect.j313-convolver"' "$frag")"
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK PACTL_DEVICE_SINK2 PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID PACTL_LOG

echo "== follow: which subscribe events wake the retarget pass =="
eval "$(sed -n '/^follow_event_wanted()/,/^}/p' "$E")"
for ev in "Event 'change' on sink #5" "Event 'change' on sink-input #7" "Event 'new' on sink #2" \
  "Event 'remove' on sink #2" "Event 'change' on server #0"; do
  follow_event_wanted "$ev" && r=wake || r=ignore
  check "wakes on: $ev" wake "$r"
done
follow_event_wanted "Event 'change' on client #3" && r=wake || r=ignore
check "ignores client events" ignore "$r"

echo "== routing: a vanished target gets a grace period =="
run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC.1
export PACTL_DEFAULT_SINK=$PACTL_DEVICE_SINK
run enable >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
export PACTL_DEVICE_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
export PACTL_DEFAULT_SINK=omarchy_equalizer
export OMARCHY_EQ_VANISH_GRACE=5
run retarget >/dev/null
check "within the grace period the target is kept" "bluez_output.12_34_56_78_9A.BC.1" "$(jq -r '.targetSink' "$st")"
check "the vanished target is remembered" "bluez_output.12_34_56_78_9A.BC.1" "$(jq -r '.vanishedTargetSink' "$st")"
# The same device back under a new profile suffix is adopted without waiting.
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC.2
run retarget >/dev/null
check "a sibling profile sink is adopted at once" "bluez_output.12_34_56_78_9A.BC.2" "$(jq -r '.targetSink' "$st")"
check "adopting it clears the vanish record" "null" "$(jq -r '.vanishedTargetSink // "null"' "$st")"
# An unrelated device only replaces the target once the grace has run out.
export PACTL_DEVICE_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
run retarget >/dev/null
check "a fresh vanish is still inside its grace" "bluez_output.12_34_56_78_9A.BC.2" "$(jq -r '.targetSink' "$st")"
jq -c '.targetMissingSince = 1' "$st" >"$st.x" && mv "$st.x" "$st"
run retarget >/dev/null
check "after the grace the fallback replaces the target" "alsa_output.pci-0000_00_1f.3.analog-stereo" "$(jq -r '.targetSink' "$st")"
check "the fallback clears the vanish record" "null" "$(jq -r '.vanishedTargetSink // "null"' "$st")"
export OMARCHY_EQ_VANISH_GRACE=0
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK

echo "== routing: the picked device coming back after the grace wins over the fallback =="
# The grace ran out and the fallback took over; then the headset returns.
# WirePlumber relinks the EQ stream to it, and convergence used to drag it back
# to the fallback. The pick (previousDefaultSink) is live again, so it is the
# target again.
run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.12_34_56_78_9A.BC.1
export PACTL_DEFAULT_SINK=$PACTL_DEVICE_SINK
run enable >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
export PACTL_DEVICE_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
export PACTL_DEFAULT_SINK=omarchy_equalizer
run retarget >/dev/null
check "with the headset gone the fallback is the target" "alsa_output.pci-0000_00_1f.3.analog-stereo" "$(jq -r '.targetSink' "$st")"
check "the pick is still remembered" "bluez_output.12_34_56_78_9A.BC.1" "$(jq -r '.previousDefaultSink' "$st")"
export PACTL_DEVICE_SINK2=bluez_output.12_34_56_78_9A.BC.1
export PACTL_EQ_AIM=1 PACTL_EQ_AIM_SINK_ID=3 PACTL_LOG="$T/pactl-return.log"; : >"$PACTL_LOG"
run retarget >/dev/null
check "the returning headset is the target again" "bluez_output.12_34_56_78_9A.BC.1" "$(jq -r '.targetSink' "$st")"
check "the stream already on it is not moved away" "0" "$(grep -c 'move-sink-input' "$PACTL_LOG")"
check "the fragment names the headset" "1" "$(grep -c 'target.object = "bluez_output.12_34_56_78_9A.BC.1"' "$frag")"
# Back under a new profile suffix counts as the same device.
export PACTL_DEVICE_SINK2=
export PACTL_DEVICE_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
run retarget >/dev/null
jq -c '.targetMissingSince = 1' "$st" >"$st.x" && mv "$st.x" "$st"
run retarget >/dev/null
export PACTL_DEVICE_SINK2=bluez_output.12_34_56_78_9A.BC.2
run retarget >/dev/null
check "a sibling profile of the pick is adopted on return" "bluez_output.12_34_56_78_9A.BC.2" "$(jq -r '.targetSink' "$st")"
unset PACTL_DEVICE_SINK2 PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID PACTL_LOG
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK

echo "== routing: a headset that connects and carries the stream is followed =="
# Seen live: a different headset than the remembered one connects, WirePlumber
# relinks the EQ stream to it, the default stays the EQ -- and convergence used to
# drag the stream back to the speakers ("connected, but the sound is still on the
# speakers"). A sink that appeared after the target was picked and carries the
# stream is the new device; one that was already there (issue #2) is not.
run disable >/dev/null
export PACTL_DEVICE_SINK=audio_effect.stub-dsp PACTL_DEFAULT_SINK=audio_effect.stub-dsp
run enable >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
export PACTL_DEFAULT_SINK=omarchy_equalizer
run retarget >/dev/null
check "the first pass records the outputs as already there" "0" "$(jq -r '.seenSinks["audio_effect.stub-dsp"]' "$st")"
# The pick happened a while ago; then the headset connects.
jq -c '.targetPickedAt = 100' "$st" >"$st.x" && mv "$st.x" "$st"
export PACTL_DEVICE_SINK2=bluez_output.AA_BB_CC_DD_EE_FF.1
run retarget >/dev/null
check "the new output is timestamped when it appears" "yes" \
  "$( (( $(jq -r '.seenSinks["bluez_output.AA_BB_CC_DD_EE_FF.1"]' "$st") > 100 )) && echo yes || echo no)"
export PACTL_EQ_AIM=1 PACTL_EQ_AIM_SINK_ID=3 PACTL_LOG="$T/pactl-new.log"; : >"$PACTL_LOG"
run retarget >/dev/null
check "a new headset carrying the stream becomes the target" "bluez_output.AA_BB_CC_DD_EE_FF.1" "$(jq -r '.targetSink' "$st")"
check "and the device of record" "bluez_output.AA_BB_CC_DD_EE_FF.1" "$(jq -r '.previousDefaultSink' "$st")"
check "the stream is left on it" "0" "$(grep -c 'move-sink-input' "$PACTL_LOG")"
check "the fragment names it" "1" "$(grep -c 'target.object = "bluez_output.AA_BB_CC_DD_EE_FF.1"' "$frag")"
# Issue #2 still holds: an output that was there before the pick is not adopted.
: >"$PACTL_LOG"
export PACTL_EQ_AIM_SINK_ID=2
run retarget >/dev/null
check "a relink to an output older than the pick is moved back" "1" \
  "$(grep -c '^move-sink-input 99 bluez_output.AA_BB_CC_DD_EE_FF.1$' "$PACTL_LOG")"
check "and the target is kept" "bluez_output.AA_BB_CC_DD_EE_FF.1" "$(jq -r '.targetSink' "$st")"
unset PACTL_DEVICE_SINK2 PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID PACTL_LOG
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK

echo "== routing: earbuds that connect, drop and reconnect (the WF-1000XM6 sequence) =="
# Seen live, every time the earbuds leave the case: they connect on a fallback
# endpoint, drop about 40 s later ("No matching connection for device"), and
# reconnect 4-6 s after that. The sound must end on the earbuds each time, never
# be pulled to the speakers once they are back.
run disable >/dev/null
export PACTL_DEVICE_SINK=audio_effect.j313-convolver PACTL_DEFAULT_SINK=audio_effect.j313-convolver
run enable >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
export PACTL_DEFAULT_SINK=omarchy_equalizer PACTL_LOG="$T/pactl-buds.log"
run retarget >/dev/null
jq -c '.targetPickedAt = 100' "$st" >"$st.x" && mv "$st.x" "$st"
buds=bluez_output.58_18_62_91_BB_8F.1
# 1. Out of the case: the earbuds appear and WirePlumber puts the stream on them.
export PACTL_DEVICE_SINK2=$buds; run retarget >/dev/null
export PACTL_EQ_AIM=1 PACTL_EQ_AIM_SINK_ID=3; : >"$PACTL_LOG"; run retarget >/dev/null
check "buds out: the earbuds are the target" "$buds" "$(jq -r '.targetSink' "$st")"
check "buds out: the stream is not moved off them" "0" "$(grep -c move-sink-input "$PACTL_LOG")"
# 2. The link drops; WirePlumber parks the stream on the speakers meanwhile.
export PACTL_DEVICE_SINK2= PACTL_EQ_AIM_SINK_ID=2 OMARCHY_EQ_VANISH_GRACE=5
run retarget >/dev/null
check "drop: inside the grace the earbuds stay the target" "$buds" "$(jq -r '.targetSink' "$st")"
# 3. Back within the grace.
export PACTL_DEVICE_SINK2=$buds PACTL_EQ_AIM_SINK_ID=3; : >"$PACTL_LOG"; run retarget >/dev/null
check "back within the grace: still the earbuds" "$buds" "$(jq -r '.targetSink' "$st")"
check "back within the grace: nothing moved" "0" "$(grep -c move-sink-input "$PACTL_LOG")"
# 4. Another drop that outlasts the grace: the speakers take over ...
export PACTL_DEVICE_SINK2= PACTL_EQ_AIM_SINK_ID=2; run retarget >/dev/null
jq -c '.targetMissingSince = 1' "$st" >"$st.x" && mv "$st.x" "$st"; run retarget >/dev/null
check "a long drop falls back to the speakers" "audio_effect.j313-convolver" "$(jq -r '.targetSink' "$st")"
# ... and the earbuds coming back win again, whether WirePlumber has already
# put the stream on them or not.
export PACTL_DEVICE_SINK2=$buds; : >"$PACTL_LOG"; run retarget >/dev/null
check "reconnect after a long drop: the earbuds again" "$buds" "$(jq -r '.targetSink' "$st")"
check "the stream is moved onto them" "1" "$(grep -c "^move-sink-input 99 $buds\$" "$PACTL_LOG")"
unset PACTL_DEVICE_SINK2 PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID PACTL_LOG
export OMARCHY_EQ_VANISH_GRACE=0
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK

echo "== preset delete =="
run save-preset ScratchPreset >/dev/null
run apply-preset ScratchPreset >/dev/null
check "applying a user preset sets the label" "ScratchPreset" "$(run status | jq -r '.preset')"
check "a user preset sorts after the built-ins" "ScratchPreset" "$(run status | jq -r '.presets[-1].name')"
check "a user preset carries no description of its own" "null" "$(run status | jq -r '.presets[-1].description')"
run delete-preset ScratchPreset >/dev/null; rc=$?
check "deleting a user preset succeeds" "0" "$rc"
check "the deleted preset is gone from the list" "0" "$(run presets | grep -c '^ScratchPreset$')"
check "the dangling label falls back to Custom" "Custom" "$(run status | jq -r '.preset')"
out="$(run delete-preset ScratchPreset)"; rc=$?
check "deleting a missing preset is refused" "1|No user preset named 'ScratchPreset'." "$rc|$out"
out="$(run delete-preset Flat)"; rc=$?
check "deleting a built-in is refused" "1|'Flat' is a built-in preset and cannot be deleted." "$rc|$out"

echo "== autoeq =="
out="$(run import-autoeq 'Test HP' 'oratory1990/over-ear/Test%20HP')"
check "an explicit index path imports that profile" "Test HP" "$(jq -r '.preset' <<<"$out")"
check "the imported profile keeps its preamp" "-6.5" "$(jq -r '.preamp' <<<"$out")"
check "the import becomes a preset" "yes" "$(run presets | grep -q '^Test HP$' && echo yes || echo no)"
check "no profile index was fetched" "0" "$(grep -c 'INDEX.md' "$CURL_LOG")"
check "the profile path asked for is the one downloaded" "1" "$(grep -c 'Test%20HP/Test%20HP%20ParametricEQ.txt' "$CURL_LOG")"
: >"$CURL_LOG"
out="$(run import-autoeq 'Test HP (velour)')"
check "a name import still searches the index" "1" "$(grep -c 'INDEX.md' "$CURL_LOG")"
check "a name import resolves the variant asked for" "Test HP (velour)" "$(jq -r '.preset' <<<"$out")"

# Index paths are untrusted too: "../" leaves the AutoEq tree, brackets glob.
: >"$CURL_LOG"
out="$(run import-autoeq 'X' './../../../evil/repo/main/X')"; rc=$?
check "a profile path with ../ is refused" "1" "$rc"
out="$(run import-autoeq 'X' 'oratory1990/over-ear/X[1-9999]')"; rc=$?
check "a profile path with a curl glob is refused" "1" "$rc"
check "neither is downloaded" "0" "$(wc -l <"$CURL_LOG" | tr -d ' ')"

# A profile is untrusted input and its fields land unquoted in the fragment. A
# JSON string carrying an escaped brace and newline -- awk splits on whitespace,
# so the token has no literal space -- used to survive --argjson and be decoded
# by jq -r, closing the control braces and appending configuration (context.exec
# among it) to the graph. The import must refuse it before anything is written.
run set-mode graphic >/dev/null
state_before="$(cat "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
frag_before="$(cat "$frag")"
printf '%s\n' 'Filter 1: ON PK Fc "\u007d\u000a" Hz Gain 6.0 dB Q 0.7' >"$T/Evil ParametricEQ.txt"
out="$(run import-autoeq "$T/Evil ParametricEQ.txt")"; rc=$?
check "a crafted Fc is refused" "1" "$rc"
check "the refusal names the field" "1" "$(grep -c 'Profile Fc' <<<"$out")"
check "the crafted import saves no preset" "0" "$(run presets | grep -c '^Evil$')"
check "the crafted import leaves the state alone" "$state_before" \
  "$(cat "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
check "the crafted import does not rewrite the fragment" "$frag_before" "$(cat "$frag")"

# The same injection already in a band -- from a hand edit or a saved preset -- must
# be refused by the fragment writer too, and the marker must not reach the file. The
# value keeps a numeric prefix so auto_preamp_db's awk reads it as a number and
# survives to the guard; a leading brace makes that awk divide by zero first.
mkdir -p "$XDG_STATE_HOME/omarchy-equalizer"
jq -c -n '{ enabled: false, mode: "graphic", preset: "Test", preamp: 0, headroom: "auto",
  parametric: [],
  graphic: [ { type: "peaking", freq: 1000, q: "0.7}\nINJECTED_MARKER", gain: 0 } ] }' \
  >"$XDG_STATE_HOME/omarchy-equalizer/state.json"
out="$(run set-mode graphic)"; rc=$?
check "the fragment writer refuses a string band value" "1" "$rc"
check "the fragment refusal names the band" "1" "$(grep -c 'Band 0 Q must be a number' <<<"$out")"
check "nothing is injected into the fragment" "0" "$(grep -c 'INJECTED_MARKER' "$frag")"

# And the live path -- bands straight to pw-cli, no fragment in between -- must
# refuse it before a single parameter reaches the graph.
jq -c -n '{ enabled: false, mode: "graphic", preset: "Test", preamp: 0, headroom: "auto",
  parametric: [],
  graphic: [ { type: "peaking", freq: 1000, q: "0.7}\nINJECTED_MARKER", gain: 0 } ] }' \
  >"$XDG_STATE_HOME/omarchy-equalizer/state.json"
: >"$PWCLI_LOG"
out="$(run set-gain 0 1)"; rc=$?
check "the live path refuses a string band value" "1" "$rc"
check "the live refusal names the band" "1" "$(grep -c 'Band 0 Q must be a number' <<<"$out")"
check "the live path sends nothing to the graph" "0" "$(grep -c 'INJECTED_MARKER' "$PWCLI_LOG")"
# Drop the crafted state so the sections after this start from the defaults.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== crafted mode and targetSink =="
# A preset's mode is copied into the state unchecked, and write_fragment prints it
# into the header comment. A newline in it ends the comment, so the line after is
# read as configuration -- context.exec among it -- which is what a crafted preset
# mode used to write into the loaded config. It must be refused before the state
# is touched.
run set-mode graphic >/dev/null
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
jq -c -n '{ EvilMode: {
  mode: "graphic\ncontext.exec = [ { command = \"touch /tmp/eq-mode-pwned\" } ] #",
  graphic: [ { type: "peaking", freq: 1000, q: 1.0, gain: 0 } ],
  parametric: [], preamp: 0 } }' >"$XDG_STATE_HOME/omarchy-equalizer/presets.json"
state_before="$(cat "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
frag_before="$(cat "$frag")"
out="$(run apply-preset EvilMode)"; rc=$?
check "a crafted preset mode is refused" "1" "$rc"
check "the mode refusal names the valid modes" "1" "$(grep -c 'graphic or parametric' <<<"$out")"
check "the crafted mode reaches no fragment" "0" "$(grep -c 'eq-mode-pwned' "$frag")"
check "the crafted mode leaves the state alone" "$state_before" \
  "$(cat "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
check "the crafted mode does not rewrite the fragment" "$frag_before" "$(cat "$frag")"

# The guard's positive half: a normal preset still applies and switches the mode.
out="$(run apply-preset Flat)"; rc=$?
check "a normal preset still applies" "0" "$rc"
check "and it still switches the mode" "graphic" "$(run status | jq -r '.mode')"

# The state's targetSink lands between double quotes in playback.props, and it
# comes from pactl, where any client can register a node. A quote closes the
# string and the rest is read as configuration; the fragment writer must refuse it
# rather than write it.
jq -c -n '{ enabled: false, mode: "graphic", preset: "Test", preamp: 0, headroom: "auto",
  targetSink: "evil\" }\ncontext.exec = [ { command = \"touch /tmp/eq-sink-pwned\" } ] #",
  parametric: [],
  graphic: [ { type: "peaking", freq: 1000, q: 1.0, gain: 0 } ] }' \
  >"$XDG_STATE_HOME/omarchy-equalizer/state.json"
frag_before="$(cat "$frag")"
out="$(run set-mode graphic)"; rc=$?
check "a crafted targetSink is refused" "1" "$rc"
check "the sink refusal names the offending character" "1" \
  "$(grep -c 'contains a quote, backslash or control character' <<<"$out")"
check "the crafted sink reaches no fragment" "0" "$(grep -c 'eq-sink-pwned' "$frag")"
check "the crafted sink does not rewrite the fragment" "$frag_before" "$(cat "$frag")"

# An ordinary node name -- dashes and dots, no quotes -- is what the guard is
# meant to let through.
jq -c -n '{ enabled: false, mode: "graphic", preset: "Test", preamp: 0, headroom: "auto",
  targetSink: "alsa_output.pci-0000_00_1f.3.analog-stereo", parametric: [],
  graphic: [ { type: "peaking", freq: 1000, q: 1.0, gain: 0 } ] }' \
  >"$XDG_STATE_HOME/omarchy-equalizer/state.json"
out="$(run set-mode graphic)"; rc=$?
check "an ordinary sink name is not refused" "0" "$rc"
check "and it reaches the fragment" "1" \
  "$(grep -c 'target.object = "alsa_output.pci-0000_00_1f.3.analog-stereo"' "$frag")"

# The source guard: a pathological default sink is refused before it is
# remembered, rather than being stored and caught only by the writer.
run disable >/dev/null
export PACTL_DEFAULT_SINK='evil" } #'
out="$(run enable)"; rc=$?
check "a pathological pactl sink is refused at enable" "1" "$rc"
check "the enable refusal names the offending character" "1" \
  "$(grep -c 'contains a quote, backslash or control character' <<<"$out")"
check "the pathological sink is not remembered" "0" \
  "$(grep -c 'evil' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
unset PACTL_DEFAULT_SINK
# Clean the crafted state and preset so the sections after start from defaults.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/presets.json"

echo "== preset ramp =="
# The crossfade belongs to the biquad chain, i.e. a machine without LSP.
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"; mkdir -p "$OMARCHY_EQ_LV2_DIR"
# Get into graphic mode with a flat graphic set, then clear the logs so only the
# preset application is measured. The ramp is enabled here; every other test
# collapses it with OMARCHY_EQ_NO_RAMP.
run set-mode graphic >/dev/null
run reset >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
unset OMARCHY_EQ_NO_RAMP
run apply-preset "Bass Boost" >/dev/null
export OMARCHY_EQ_NO_RAMP=1
check "a shape-compatible preset does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a shape-compatible preset writes the graph more than once" "yes" \
  "$( (( $(wc -l <"$PWCLI_LOG") > 1)) && echo yes || echo no )"
check "the last ramp step carries the preset's final gains" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"g9:Gain" -5.5' && echo yes || echo no)"
: >"$SYSTEMCTL_LOG"
run apply-preset "Speech Clarity" >/dev/null
check "a parametric preset rebuilds the graph" "yes" \
  "$(grep -c restart "$SYSTEMCTL_LOG" | sed 's/^0$/no/;s/^[1-9].*/yes/')"
# Back to LSP: the first command finds the biquad chain still running and
# rebuilds it into the pool once; after that the pool is written live.
export OMARCHY_EQ_LV2_DIR="$T/lv2"
: >"$SYSTEMCTL_LOG"
run set-mode parametric >/dev/null
check "a biquad graph left running is rebuilt into the pool once" "1" "$(grep -c restart "$SYSTEMCTL_LOG")"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run add-band >/dev/null
check "adding a band to a running pool does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "adding a band to the pool is one live write" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"

echo "== output stage defaults =="
check "the limiter defaults on" "on" "$(run status | jq -r '.limiter')"
check "the boost defaults off" "off" "$(run status | jq -r '.boost')"
check "the output stage is active" "true" "$(run status | jq -r '.outputStage')"

echo "== output stage in the fragment =="
# With LSP the graphic set runs in the pool too, so the bands are one node.
run set-mode graphic >/dev/null
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "the fragment hosts the multiband compressor" "1" "$(grep -c 'lv2/mb_compressor_mono' "$frag")"
check "the fragment no longer hosts the single-band compressor" "0" "$(grep -c 'lv2/compressor_mono' "$frag")"
check "the fragment hosts the limiter" "1" "$(grep -c 'limiter_mono' "$frag")"
check "the compressor splits the bass from the mid at 200 Hz" "1" "$(grep -c '"sf_1" = 200' "$frag")"
check "the compressor splits the mid from the treble at 4 kHz" "1" "$(grep -c '"sf_2" = 4000' "$frag")"
check "no control is written that the plugin reports as an output" "0" \
  "$(grep -c '"fre_[0-9]" =' "$frag")"
check "the compressor's bass band is enabled" "1" "$(grep -c '"ce_0" = 1' "$frag")"
check "the compressor's fourth band is disabled" "1" "$(grep -c '"ce_3" = 0' "$frag")"
check "the mid band's split is switched on (defaults would leave it off)" "1" \
  "$(grep -c '"cbe_1" = 1' "$frag")"
check "the treble band's split is switched on" "1" "$(grep -c '"cbe_2" = 1' "$frag")"
check "the fourth band's split stays off" "1" "$(grep -c '"cbe_3" = 0' "$frag")"
check "the limiter oversamples to catch true peaks" "1" \
  "$(grep 'name = limit' "$frag" | grep -c '"ovs" = 12')"
check "the band pool feeds the compressor" "1" \
  "$(grep -c 'para:out" input = "boost:in"' "$frag")"
check "the compressor feeds the limiter" "1" \
  "$(grep -c 'boost:out" input = "limit:in"' "$frag")"
check "the limiter is the graph output" "0" "$(grep -c 'limit:out' "$frag")"
# With no bands the preamp is the whole head of the chain and feeds the pool,
# which then feeds the stage.
run set-mode parametric >/dev/null
while [[ $(run status | jq -r '.bands | length') -gt 0 ]]; do run remove-band 0 >/dev/null; done
check "with no bands the preamp feeds the pool" "1" \
  "$(grep -c 'pre:Out" input = "para:in"' "$frag")"
check "with no bands the pool feeds the compressor" "1" \
  "$(grep -c 'para:out" input = "boost:in"' "$frag")"
check "with no bands there is still no g0 link" "0" "$(grep -c 'g0:In' "$frag")"

echo "== output stage live control =="
run set-mode graphic >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-limiter off >/dev/null
check "set-limiter does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "set-limiter off writes the limiter enabled control" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"limit:enabled" 0' && echo yes || echo no)"
run set-limiter on >/dev/null
check "set-limiter on writes enabled 1" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"limit:enabled" 1' && echo yes || echo no)"
check "set-limiter keeps the fragment in step" "1" \
  "$(grep 'name = limit' "$frag" | grep -c '"enabled" = 1')"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-boost high >/dev/null
check "set-boost does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "set-boost writes all its controls in one call" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "set-boost high enables the multiband compressor" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:enabled" 1' && echo yes || echo no)"
check "set-boost writes the envelope boost off" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:envb" 0' && echo yes || echo no)"
check "set-boost high switches the mid band's split on" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:cbe_1" 1' && echo yes || echo no)"
check "set-boost high keeps the fourth band's split off" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:cbe_3" 0' && echo yes || echo no)"
check "set-boost high writes +10 dB makeup to all three bands" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:mk_0" 3.162278.*"boost:mk_1" 3.162278.*"boost:mk_2" 3.162278' && echo yes || echo no)"
check "set-boost high keeps the treble band's ratio at 4" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:cr_2" 4' && echo yes || echo no)"
run set-boost off >/dev/null
check "set-boost off disables the compressor" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:enabled" 0' && echo yes || echo no)"
check "set-boost off leaves medium's makeup in place" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:mk_0" 2.238721.*"boost:mk_1" 2.238721.*"boost:mk_2" 2.238721' && echo yes || echo no)"
check "set-boost off leaves medium's bass threshold in place" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:al_0" 0.063096' && echo yes || echo no)"
check "set-boost keeps the fragment in step" "1" \
  "$(grep 'name = boost' "$frag" | grep -c '"mk_0" = 2.238721')"
check "the boost node carries the envelope boost off" "1" \
  "$(grep 'name = boost' "$frag" | grep -c '"envb" = 0')"

echo "== output stage validation =="
out="$(run set-limiter maybe)"; rc=$?
check "set-limiter rejects anything else" "1|Limiter must be on or off." "$rc|$out"
out="$(run set-boost loud)"; rc=$?
check "set-boost rejects anything else" "1|Boost must be off, low, medium or high." "$rc|$out"
check "a rejected value is not stored" "on" "$(run status | jq -r '.limiter')"

echo "== output stage on a state written before the fields =="
state="$XDG_STATE_HOME/omarchy-equalizer/state.json"
jq 'del(.limiter, .boost)' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
check "a state without limiter reads as on" "on" "$(run status | jq -r '.limiter')"
check "a state without boost reads as off" "off" "$(run status | jq -r '.boost')"

echo "== output stage without LSP =="
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"
mkdir -p "$OMARCHY_EQ_LV2_DIR"
run set-mode graphic >/dev/null
check "the fragment omits the output stage" "0" "$(grep -c 'type = lv2' "$frag")"
check "status reports the output stage inactive" "false" "$(run status | jq -r '.outputStage')"
out="$(run set-boost medium)"; rc=$?
check "set-boost still succeeds without LSP" "0" "$rc"
check "set-boost warns that the stage is inactive" \
  "LSP plugins are not installed; the output stage is inactive." "$out"
check "set-boost stores the value without LSP" "medium" "$(run status | jq -r '.boost')"
export OMARCHY_EQ_LV2_DIR="$T/lv2"

echo "== output stage survives a pool edit =="
run set-mode parametric >/dev/null
: >"$SYSTEMCTL_LOG"
run add-band >/dev/null
check "a live pool edit does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "the synced fragment keeps the compressor" "1" "$(grep -c 'lv2/mb_compressor_mono' "$frag")"
check "the synced fragment keeps the limiter" "1" "$(grep -c 'limiter_mono' "$frag")"

echo "== parametric pool fragment =="
# The type map, APO (DR) mode and Off unused slots are the contract the panel's
# curve and the backend's headroom rest on, so they are asserted, not assumed.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode parametric >/dev/null
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "the fragment hosts the 16-slot pool" "1" "$(grep -c 'lv2/para_equalizer_x16_mono' "$frag")"
check "the pool runs APO (DR)" "1" "$(grep -c '"fm_0" = 6' "$frag")"
check "the pool runs slope x1" "1" "$(grep -c '"s_0" = 0' "$frag")"
check "a low shelf maps to Lo-shelf (ft 5)" "1" "$(grep -c '"ft_0" = 5' "$frag")"
check "a high shelf maps to Hi-shelf (ft 3)" "1" "$(grep -c '"ft_7" = 3' "$frag")"
check "a peaking band maps to Bell (ft 1)" "1" "$(grep -c '"ft_1" = 1' "$frag")"
check "the unused slots are Off (ft 0)" "8" \
  "$(grep -oE '"ft_(8|9|1[0-5])" = 0' "$frag" | wc -l | tr -d ' ')"
check "the pool keeps linear gain" "1" "$(grep -c '"g_0" = 1.000000' "$frag")"
check "the pool pins g_in/g_out" "yes" \
  "$(grep -q '"g_in" = 1.*"g_out" = 1' "$frag" && echo yes || echo no)"
check "the pool turns the FFT displays off" "yes" \
  "$(grep -q '"ife" = 0.*"ofe" = 0' "$frag" && echo yes || echo no)"
check "the preamp feeds the pool" "1" "$(grep -c 'pre:Out" input = "para:in"' "$frag")"
check "the pool feeds the compressor" "1" "$(grep -c 'para:out" input = "boost:in"' "$frag")"
check "the compressor still feeds the limiter" "1" "$(grep -c 'boost:out" input = "limit:in"' "$frag")"
check "no biquad band nodes remain in parametric mode" "0" \
  "$(grep -c 'type = builtin name = g' "$frag")"

echo "== parametric pool live edits =="
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 1 type highpass >/dev/null
check "a pool type change does not restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a pool type change is one pw-cli call" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "the type change writes Hi-pass (ft 2) live" "yes" \
  "$(grep -q '"para:ft_1" 2' "$PWCLI_LOG" && echo yes || echo no)"
check "the fragment follows the type change" "yes" \
  "$(grep -q '"ft_1" = 2' "$frag" && echo yes || echo no)"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run add-band >/dev/null
check "a pool add does not restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a pool add is one pw-cli call" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "the add enables the first free slot" "yes" \
  "$(grep -q '"para:ft_8" 1' "$PWCLI_LOG" && echo yes || echo no)"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run remove-band 0 >/dev/null
check "a pool remove does not restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a pool remove is one pw-cli call" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "the freed slot is written Off" "yes" \
  "$(grep -q '"para:ft_8" 0' "$PWCLI_LOG" && echo yes || echo no)"

echo "== with LSP a preset of any mode or shape is live, never a rebuild =="
# A rebuild drops the sink, and a browser playing into it pauses (Warm Speakers
# from a graphic preset did). Both modes run in the pool, so a parametric preset
# from graphic mode, and back, is one values write.
run set-mode graphic >/dev/null
run apply-preset Rock >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run apply-preset "Warm Speakers" >/dev/null
check "graphic -> Warm Speakers does not restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "it is one live write to the pool" "1" "$(grep -c 'para:ft_0' "$PWCLI_LOG")"
check "the low shelf lands live (ft 5)" "1" "$(grep -c '"para:ft_0" 5' "$PWCLI_LOG")"
check "the fragment stays the pool" "1" "$(grep -c 'name = para plugin' "$frag")"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run apply-preset Rock >/dev/null
check "Warm Speakers -> a graphic preset does not restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
: >"$SYSTEMCTL_LOG"
run set-mode parametric >/dev/null
run set-mode graphic >/dev/null
check "a mode switch does not restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
: >"$SYSTEMCTL_LOG"
for p in "Bass Boost" "Small Speakers" "Speech Clarity" "Flat" "Warm Speakers" "Zouk"; do
  run apply-preset "$p" >/dev/null
done
check "six presets across both modes: no restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
run set-mode parametric >/dev/null

echo "== parametric band cap =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode parametric >/dev/null
while [[ $(run status | jq -r '.bands | length') -lt 16 ]]; do run add-band >/dev/null; done
check "the pool can hold 16 bands" "16" "$(run status | jq -r '.parametricCount')"
out="$(run add-band)"; rc=$?
check "add-band past 16 is refused" "1|Parametric mode holds at most 16 bands." "$rc|$out"
check "the refused add leaves the count at 16" "16" "$(run status | jq -r '.parametricCount')"

echo "== a hand-edited over-cap state =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
mkdir -p "$XDG_STATE_HOME/omarchy-equalizer"
jq -c -n '{ enabled: false, mode: "parametric", preset: "Test", preamp: 0, headroom: "auto",
  graphic: [], parametric: [ range(0; 18) | { type: "peaking", freq: 1000, q: 1.0, gain: 0 } ] }' \
  >"$XDG_STATE_HOME/omarchy-equalizer/state.json"
out="$("$E" status 2>"$T/trunc.err")"
check "an over-cap state loads truncated to 16" "16" "$(jq -r '.parametricCount' <<<"$out")"
check "the truncation says so on stderr" "1" "$(grep -c 'keeping the first 16' "$T/trunc.err")"
check "the truncation is persisted" "16" \
  "$(jq '.parametric | length' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"

echo "== a graphic type change is live in the pool, a rebuild on biquads =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode graphic >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 0 type lowshelf >/dev/null
check "a graphic type change in the pool does not restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a graphic type change in the pool is one live write" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"
run set-band 0 type peaking >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 0 type lowshelf >/dev/null
check "a graphic type change on biquads restarts" "1" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a graphic type change on biquads writes no live param" "0" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
run set-band 0 type peaking >/dev/null
export OMARCHY_EQ_LV2_DIR="$T/lv2"

echo "== no-LSP parametric stays the biquad path =="
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"
mkdir -p "$OMARCHY_EQ_LV2_DIR"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode parametric >/dev/null
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "without LSP the fragment stays biquads" "0" "$(grep -c 'type = lv2 name = para' "$frag")"
check "without LSP the fragment has biquad bands" "yes" \
  "$(grep -q 'type = builtin name = g0' "$frag" && echo yes || echo no)"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 3 type lowshelf >/dev/null
check "without LSP a parametric type change restarts" "1" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "without LSP a parametric type change writes no live param" "0" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
: >"$SYSTEMCTL_LOG"
run add-band >/dev/null
check "without LSP add-band restarts" "1" "$(grep -c restart "$SYSTEMCTL_LOG")"
export OMARCHY_EQ_LV2_DIR="$T/lv2"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== panel fields never use a native Qt text input =="
# Every editable Qt text input reads another application's clipboard offer on
# each clipboard change, unbounded, inside the shell process the panel runs in
# (marketplace review, issue 11753). The fields are drawn from key events
# instead, and this scan keeps it that way -- the comments may name the types
# the code avoids, so they are stripped before scanning.
strip_qml_comments() { perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//.*$}{}gm' "$1"; }
native=0
clipboard=0
for qml in "$here"/../*.qml; do
  native=$((native + $(strip_qml_comments "$qml" | grep -cE '\b(TextInput|TextField|TextEdit|TextArea|SpinBox|NumberField)\b')))
  clipboard=$((clipboard + $(strip_qml_comments "$qml" | grep -ci 'clipboard')))
done
check "no native text-input type in shipped QML" "0" "$native"
# The shell kit's own pickers and fields wrap those types too: SearchableDropdown
# and MultiSelect lead their popups with a TextField, NumberField is a TextInput.
# Using one brings the clipboard read back without naming a text input here.
kit_inputs=0
for qml in "$here"/../*.qml; do
  kit_inputs=$((kit_inputs + $(strip_qml_comments "$qml" | grep -cE '\b(SearchableDropdown|MultiSelect|NumberField)[[:space:]]*\{')))
done
check "no shell component that wraps a native text input" "0" "$kit_inputs"
check "the preset picker searches through a KeyField" "1" "$(strip_qml_comments "$here/../PresetPicker.qml" | grep -c 'KeyField {')"
check "no clipboard reference in shipped QML" "0" "$clipboard"
check "the preset name and AutoEq query are KeyFields" "2" "$(grep -c 'KeyField {' "$here/../Panel.qml")"
check "the frequency and Q fields are KeyFields" "2" "$(grep -c 'KeyField {' "$here/../ParametricBandRow.qml")"
check "the band row needs no Qt Quick Controls" "0" "$(grep -c '^import QtQuick.Controls' "$here/../ParametricBandRow.qml")"

echo "== offscreen QML tests (key fields, response curve) =="
qmltestrunner=""
[[ -x /usr/lib/qt6/bin/qmltestrunner ]] && qmltestrunner=/usr/lib/qt6/bin/qmltestrunner
if [[ -n $qmltestrunner ]]; then
  qml_out="$(QT_QPA_PLATFORM=offscreen HOME="$T" timeout 90 "$qmltestrunner" \
    -import "$here/qml/imports" -input "$here/qml" 2>&1 || true)"
  printf '%s\n' "$qml_out" | grep -E 'Totals:' | sed 's/^/      /'
  check "the offscreen QML tests pass" "yes" \
    "$(printf '%s' "$qml_out" | grep -qE 'Totals: [0-9]+ passed, 0 failed' && echo yes || echo no)"
else
  printf 'SKIP  offscreen QML tests (qmltestrunner is not installed)\n'
fi

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
