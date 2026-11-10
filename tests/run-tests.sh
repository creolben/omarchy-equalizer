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
# Pin PATH so the stubs win, but keep the directory node lives in: a CI runner
# installs it under the toolcache (actions/setup-node) rather than /usr/bin.
node_bin="$(command -v node || true)"
export PATH="$here/bin:/usr/bin:/bin${node_bin:+:$(dirname "$node_bin")}"
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

# The output stage and the band pool check for the LSP stereo plugins under this
# root. Empty TTLs are enough -- lsp_available only needs the files to exist --
# and the missing-plugin section swaps in a root without them. (tests/dsp-check.sh
# runs the real plugins.)
export OMARCHY_EQ_LV2_DIR="$T/lv2"
mkdir -p "$OMARCHY_EQ_LV2_DIR/lsp-plugins.lv2"
for p in para_equalizer_x16_stereo mb_compressor_stereo limiter_stereo autogain_stereo; do
  : >"$OMARCHY_EQ_LV2_DIR/lsp-plugins.lv2/$p.ttl"
done

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
check "set-headroom rejects anything else" "1|Headroom must be auto, balanced or manual." "$rc|$out"

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

echo "== the balanced headroom matches Model.js =="
# The bass shelf, the smile and the treble lift of docs/spec-v4.md §1.3 on top of
# the three sets above: the programme gain and the balanced preamp the backend's
# awk computes against the panel's model, number for number.
set4="$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] as $f | [8,6,4,0,0,0,0,0,0,0] as $g
  | [range(0; 10) | { type: "peaking", freq: $f[.], q: 1.41, gain: $g[.] }]')"
set5="$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] as $f | [6,4,2,0,-2,-2,0,2,4,6] as $g
  | [range(0; 10) | { type: "peaking", freq: $f[.], q: 1.41, gain: $g[.] }]')"
set6="$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] | map({ type: "peaking", freq: ., q: 1.41, gain: (if . == 16000 then 10 else 0 end) })')"
jq -c --argjson d "$set4" --argjson e "$set5" --argjson f "$set6" '. + [$d, $e, $f]' "$T/headroom-sets.json" >"$T/balanced-sets.json"
model_b="$(node "$here/headroom-check.js" "$rate" "$T/balanced-sets.json" balanced)"
model_p="$(node "$here/headroom-check.js" "$rate" "$T/balanced-sets.json" program)"
modes=(graphic parametric parametric graphic graphic graphic)
for i in 0 1 2 3 4 5; do
  bands="$(jq -c ".[$i]" "$T/balanced-sets.json")"
  backend_auto_preamp "${modes[$i]}" "$bands" >/dev/null
  got="$(run status | jq -c '[.balancedPreamp, .programGainDb]')"
  want="$(jq -cn --argjson b "$model_b" --argjson p "$model_p" "[\$b[$i], \$p[$i]]")"
  check "balanced preamp and programme gain match Model.js for set $((i + 1))" "true" \
    "$(jq -cn --argjson a "$got" --argjson b "$want" '($a[0] - $b[0]) == 0 and (($a[1] - $b[1]) | fabs) < 0.005')"
done
check "the bass shelf takes less cut balanced than safe" "true" \
  "$(jq -cn --argjson b "$model_b" --argjson a "$(node "$here/headroom-check.js" "$rate" "$T/balanced-sets.json")" '$b[3] > $a[3]')"
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
check "the fragment still hosts the preamp, one per channel" "2" "$(grep -c 'name = pre_[lr] label = linear' "$frag")"
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
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"pre_l:Mult" 0.501187 "pre_r:Mult" 0.501187' && echo yes || echo no)"
check "the fragment follows the live preamp" "2" "$(grep -c 'name = pre_[lr] label = linear control = { "Mult" = 0.501187' "$frag")"
out="$(run set-preamp -8 2>&1)"
check "a preamp below the ceiling is left alone" "0" "$(grep -c 'above the headroom ceiling' <<<"$out")"
check "and is what the graph and the state hold" "-8" "$(run status | jq -r '.preamp')"
check "and is what the fragment holds" "2" "$(grep -c 'name = pre_[lr] label = linear control = { "Mult" = 0.398107' "$frag")"

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

echo "== the spectrum behind the curve, and the caption contrast =="
node "$here/spectrum-check.js" >"$T/spectrum-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/spectrum-check.log"
check "the backdrop parses only real frames and the dim text holds 4.5:1" "0" "$rc"

echo "== the 10-band faders set the response at their centres =="
node "$here/fit-check.js" >"$T/fit-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/fit-check.log"
check "the fit reaches every fader and moves no other" "0" "$rc"

echo "== one input policy: the wheel scrolls, it does not edit =="
node "$here/input-policy-check.js" >"$T/input-policy-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/input-policy-check.log"
check "the wheel policy follows the rule table exactly" "0" "$rc"

echo "== the curve draws its handles from the bands it draws its line from =="
# Issue #3 (a first drag drew its handle at the 1 kHz fallback) came from draft
# values the curve kept beside the bands. The curve now has none: the panel
# echoes every move into the bands, and tests/qml/tst_responsecurve.qml holds
# the handle on the line during and after a drag.
check "the curve keeps no draft gain or frequency of its own" "0" \
  "$(grep -cE 'draft(Gain|Freq)' "$here/../ResponseCurve.qml")"

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
export SYSTEMCTL_PARKED_SNAPSHOT="$T/parked-at-restart"
run apply-preset "Small Speakers" >/dev/null
unset SYSTEMCTL_PARKED_SNAPSHOT
check "the mode-changing preset still restarts the chain" "1" "$(grep -c '^--user restart' "$SYSTEMCTL_LOG")"
# A restart the follower starts takes the follower down with it (it is PartOf the
# unit), so the parked streams have to be on disk before the restart, for the
# next follower to return.
check "the parked streams are on record before the restart begins" "[42]" "$(cat "$T/parked-at-restart")"
check "and the record is dropped once they are back" "gone" \
  "$([[ -e $XDG_STATE_HOME/omarchy-equalizer/parked-streams ]] && echo kept || echo gone)"
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
check "the parked stream is remembered" "[42]" "$(cat "$XDG_STATE_HOME/omarchy-equalizer/parked-streams")"
# systemd brings the sink back; the follower's pass returns the stream.
rm -f "$T/eq-gone"; unset SYSTEMCTL_RESTART_FAILS; : >"$PACTL_LOG"
run retarget >/dev/null
check "the follower returns the parked stream" "1" \
  "$(grep -c '^move-sink-input 42 omarchy_equalizer$' "$PACTL_LOG")"
check "and takes the default back" "1" "$(grep -c '^set-default-sink omarchy_equalizer$' "$PACTL_LOG")"
check "the parked record is cleared" "gone" \
  "$([[ -e $XDG_STATE_HOME/omarchy-equalizer/parked-streams ]] && echo kept || echo gone)"
# A 2.0 state kept them in state.json; the follower returns those too.
jq -c '.parkedStreams = [77]' "$st" >"$st.x" && mv "$st.x" "$st"; : >"$PACTL_LOG"
run retarget >/dev/null
check "streams parked by 2.0 come back too" "1|null" \
  "$(grep -c '^move-sink-input 77 omarchy_equalizer$' "$PACTL_LOG")|$(jq -c '.parkedStreams // null' "$st")"
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
# A machine without LSP runs the biquad chain.
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
# PipeWire's builtin biquad clears its history on every update, so each write
# clicks once whatever its size (tests/dsp-check.sh): the biquad chain takes a
# preset in one write rather than eight.
check "a shape-compatible preset does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "a shape-compatible preset is one write of the biquads" "1" "$(grep -c 'g9_l:Gain' "$PWCLI_LOG")"
check "which carries the preset's final gains" "yes" \
  "$(grep 'g9_l:Gain' "$PWCLI_LOG" | tail -n1 | grep -q '"g9_l:Gain" -5.5.*"g9_r:Gain" -5.5' && echo yes || echo no)"
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
# A whole new set in one write clicks in the pool too (tests/dsp-check.sh), so a
# preset of the same shape is cross-faded there as well; another shape is one write.
# The flat gains then walk to the new preamp in 0.1 dB steps (they click when
# stepped at once), in the background: Rock's -0.5 dB to Bass Boost's 0 is five.
run apply-preset Rock >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
unset OMARCHY_EQ_NO_RAMP
run apply-preset "Bass Boost" >/dev/null
export OMARCHY_EQ_NO_RAMP=1
for _ in $(seq 100); do tail -n1 "$PWCLI_LOG" | grep -q '"pre_l:Mult" 1.000000' && break; sleep 0.02; done
check "a preset of the same shape is cross-faded in the pool" "8|0" \
  "$(grep -c 'para:g_9' "$PWCLI_LOG")|$(grep -c restart "$SYSTEMCTL_LOG")"
check "and the last band step is the preset itself" "yes" \
  "$(grep 'para:g_9' "$PWCLI_LOG" | tail -n1 | grep -q "\"para:g_9\" $(LC_ALL=C awk 'BEGIN { printf "%.6f", 10 ^ (-5.5 / 20) }')" && echo yes || echo no)"
check "the bands move under the old preamp" "8" "$(grep 'para:g_9' "$PWCLI_LOG" | grep -c '"pre_l:Mult" 0.944061')"
check "then the flat gains walk to the new one in 0.1 dB steps" "5|1" \
  "$(grep -vc 'para:' "$PWCLI_LOG")|$(tail -n1 "$PWCLI_LOG" | grep -c '"pre_l:Mult" 1.000000')"
: >"$PWCLI_LOG"
unset OMARCHY_EQ_NO_RAMP
run apply-preset "Speech Clarity" >/dev/null
export OMARCHY_EQ_NO_RAMP=1
check "a preset of another shape is one write" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"

echo "== output stage defaults =="
check "the limiter defaults on" "on" "$(run status | jq -r '.limiter')"
check "the boost defaults off" "off" "$(run status | jq -r '.boost')"
check "the output stage is active" "true" "$(run status | jq -r '.outputStage')"

echo "== output stage in the fragment =="
# With LSP the graphic set runs in the pool too, so the bands are one node.
run set-mode graphic >/dev/null
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "the fragment hosts the stereo multiband compressor" "1" "$(grep -c 'lv2/mb_compressor_stereo' "$frag")"
check "the fragment no longer hosts the single-band compressor" "0" "$(grep -c 'lv2/compressor_mono' "$frag")"
check "the fragment hosts the stereo limiter" "1" "$(grep -c 'lv2/limiter_stereo' "$frag")"
check "the fragment hosts the stereo leveler" "1" "$(grep -c 'lv2/autogain_stereo' "$frag")"
check "no mono build is left to process a channel on its own" "0" "$(grep -c '_mono"' "$frag")"
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
check "the band pool feeds the leveler" "1" \
  "$(grep -c 'para:out_l" input = "level:in_l"' "$frag")"
check "the leveler feeds the compressor" "1" \
  "$(grep -c 'level:out_r" input = "boost:in_r"' "$frag")"
check "the compressor feeds the relief, the relief the volume" "2" \
  "$(grep -cE 'boost:out_l" input = "relief_l:In"|relief_l:Out" input = "vol_l:In"' "$frag")"
check "the volume feeds the limiter" "1" "$(grep -c 'vol_r:Out" input = "limit:in_r"' "$frag")"
check "the device relief is the graph output" "1" "$(grep -c 'outputs = \[ "drelief_l:Out" "drelief_r:Out" \]' "$frag")"
check "and the limiter feeds only it" "2" "$(grep -c 'output = "limit:out' "$frag")"
check "the limiter feeds the device relief" "1" "$(grep -c 'limit:out_r" input = "drelief_r:In"' "$frag")"
check "the sink volume drives the in-graph volume nodes" "2" \
  "$(grep -cE '\{ control = "vol_[lr]:Mult" \}' "$frag")"
# With no bands the preamp is the whole head of the chain and feeds the pool,
# which then feeds the stage.
run set-mode parametric >/dev/null
while [[ $(run status | jq -r '.bands | length') -gt 0 ]]; do run remove-band 0 >/dev/null; done
check "with no bands the channel stage feeds the pool" "1" \
  "$(grep -c 'mix_l:Out" input = "para:in_l"' "$frag")"
check "with no bands the pool feeds the leveler" "1" \
  "$(grep -c 'para:out_l" input = "level:in_l"' "$frag")"
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
check "set-boost rejects anything else" "1|Boost must be off, low, medium, high, night or voice." "$rc|$out"
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
check "the synced fragment keeps the compressor" "1" "$(grep -c 'lv2/mb_compressor_stereo' "$frag")"
check "the synced fragment keeps the limiter" "1" "$(grep -c 'lv2/limiter_stereo' "$frag")"

echo "== parametric pool fragment =="
# The type map, APO (DR) mode and Off unused slots are the contract the panel's
# curve and the backend's headroom rest on, so they are asserted, not assumed.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode parametric >/dev/null
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "the fragment hosts the 16-slot stereo pool" "1" "$(grep -c 'lv2/para_equalizer_x16_stereo' "$frag")"
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
  "$(grep -q '"ife_l" = 0 "ife_r" = 0 "ofe_l" = 0 "ofe_r" = 0' "$frag" && echo yes || echo no)"
check "each preamp feeds both channel mixers" "4" "$(grep -cE 'pre_[lr]:Out" input = "mix_[lr]:In [12]"' "$frag")"
check "the channel mixers feed the pool" "2" "$(grep -cE 'mix_[lr]:Out" input = "para:in_[lr]"' "$frag")"
check "the pool feeds the leveler" "1" "$(grep -c 'para:out_r" input = "level:in_r"' "$frag")"
check "the volume still feeds the limiter" "1" "$(grep -c 'vol_l:Out" input = "limit:in_l"' "$frag")"
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

echo "== layout: the fragment names its shape, and an old graph is rebuilt once =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json" "$XDG_STATE_HOME/omarchy-equalizer/running-layout"
# The sections below need an equalizer that is on, so it needs a device to play into.
export PACTL_DEVICE_SINK=alsa_output.stub PACTL_DEFAULT_SINK=alsa_output.stub
run disable >/dev/null
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "the fragment names its layout" "1" "$(grep -c '^# Layout: v4 pool$' "$frag")"
check "enable records the layout the graph runs" "v4 pool" "$(cat "$XDG_STATE_HOME/omarchy-equalizer/running-layout")"
# What a version-3 backend recorded ("pool", no version) is another layout: the
# first edit after the upgrade rebuilds once, to add the device relief.
printf 'pool\n' >"$XDG_STATE_HOME/omarchy-equalizer/running-layout"
: >"$SYSTEMCTL_LOG"
run set-gain 2 1 >/dev/null
check "a graph a version-3 backend started is rebuilt once" "1" "$(grep -c '^--user restart' "$SYSTEMCTL_LOG")"
run set-gain 2 0 >/dev/null
# A graph from before the layout line: the first live command rebuilds it once.
printf '' >"$XDG_STATE_HOME/omarchy-equalizer/running-layout"
: >"$SYSTEMCTL_LOG"
run set-gain 2 1 >/dev/null
check "a graph of an older layout is rebuilt on the first edit" "1" "$(grep -c '^--user restart' "$SYSTEMCTL_LOG")"
check "and the rebuild records the new layout" "v4 pool" "$(cat "$XDG_STATE_HOME/omarchy-equalizer/running-layout")"
: >"$SYSTEMCTL_LOG"
run set-gain 2 0 >/dev/null
check "after that edits are live again" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
# A values-only rewrite of an outdated graph (a preamp) must not leave a fragment
# of another shape on disk under it: it rebuilds too.
printf '' >"$XDG_STATE_HOME/omarchy-equalizer/running-layout"
: >"$SYSTEMCTL_LOG"
run set-limiter on >/dev/null
check "a stage toggle on an outdated graph rebuilds it" "1" "$(grep -c '^--user restart' "$SYSTEMCTL_LOG")"

unset PACTL_DEVICE_SINK PACTL_DEFAULT_SINK

echo "== band bypass =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode parametric >/dev/null
run set-gain 2 6 >/dev/null
check "a boosted band takes headroom" "-6.0" "$(run status | jq -r '.preamp')"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 2 enabled off >/dev/null
check "bypassing a band does not restart the pool" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "bypassing is one live write" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "the bypassed band is stored, values intact" "false|6" "$(run status | jq -r '"\(.bands[2].enabled)|\(.bands[2].gain)"')"
check "a bypassed band takes no headroom" "0" "$(run status | jq -r '.preamp')"
check "the running pool plays seven bands" "7" "$(grep -oE '"para:ft_[0-9]+" [1-9]' "$PWCLI_LOG" | wc -l | tr -d ' ')"
check "and none of them is the bypassed one" "0" "$(grep -c '"para:f_[0-9]*" 250 ' "$PWCLI_LOG")"
check "the fragment leaves it out too" "0" "$(grep -c '"f_[0-9]*" = 250 ' "$frag")"
run set-band 2 enabled on >/dev/null
check "switching it back on restores its headroom" "-6.0" "$(run status | jq -r '.preamp')"
out="$(run set-band 2 enabled maybe)"; rc=$?
check "enabled takes on or off only" "1|Enabled must be on or off, not 'maybe'." "$rc|$out"
# A band written with its defaults is the band without them: not an edit.
run apply-preset "Warm Speakers" >/dev/null
run set-band 0 enabled off >/dev/null
run set-band 0 enabled on >/dev/null
check "bypassing and restoring a band leaves the preset unedited" "false" "$(run status | jq -r '.presetDirty')"
# Without LSP the biquad chain changes shape when a band drops out: a rebuild.
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"
run set-mode graphic >/dev/null
: >"$SYSTEMCTL_LOG"
run set-band 3 enabled off >/dev/null
check "on the biquad chain a bypass rebuilds" "1" "$(grep -c '^--user restart' "$SYSTEMCTL_LOG")"
check "the bypassed biquad band is left out of the chain" "9" "$(grep -c 'name = g[0-9]*_l label' "$frag")"
run set-band 3 enabled on >/dev/null
export OMARCHY_EQ_LV2_DIR="$T/lv2"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== slopes: a steeper pass filter is a cascade of Butterworth stages =="
run set-mode parametric >/dev/null
run set-band 0 type highpass >/dev/null
run set-band 0 freq 80 >/dev/null
run set-band 0 q 0.7071067811865476 >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-band 0 slope 2 >/dev/null
check "a slope change in the pool is live" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "slope 2 takes two slots" "9" "$(run status | jq -r '.slots')"
check "both stages are Hi-pass slots" "yes" \
  "$(grep -q '"para:ft_0" 2 .*"para:ft_1" 2 ' "$PWCLI_LOG" && echo yes || echo no)"
stage_qs="$(grep -oE '"q_[01]" = [0-9.]+' "$frag" | awk '{ printf "%.9f,", $3 }')"
model_qs="$(node -e '
  const fs = require("fs"), vm = require("vm"), m = {}; vm.createContext(m);
  vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), m);
  process.stdout.write(m.bandStages({ type: "highpass", freq: 80, q: Math.SQRT1_2, gain: 0, slope: 2 })
    .map(s => s.q.toFixed(9) + ",").join(""));' "$here/../Model.js")"
check "the stage Qs are Model.js bandStages, to 1e-9" "$model_qs" "$stage_qs"
check "and are a 4th-order Butterworth" "0.541196100,1.306562965," "$stage_qs"
out="$(run set-band 0 slope 5)"; rc=$?
check "a slope past 4 is refused" "1" "$rc"
# A slope belongs to the pass filter it was set on: another type starts at 1.
run set-band 0 type peaking >/dev/null
run set-band 0 type highpass >/dev/null
check "a type change resets the slope" "8|null" "$(run status | jq -r '"\(.slots)|\(.bands[0].slope // "null")"')"
run set-band 0 slope 2 >/dev/null
# The slot budget: 8 default bands + 3 more for a slope of 4 = 11; fill the rest.
run set-band 0 slope 4 >/dev/null
while [[ $(run status | jq -r '.slots') -lt 16 ]]; do run add-band >/dev/null; done
out="$(run add-band)"; rc=$?
check "a full slot budget refuses another band" "1" "$rc"
check "and says why" "1" "$(grep -c 'no free filter slot' <<<"$out")"
out="$(run set-band 1 type lowpass)"; rc=$?; out="$(run set-band 1 slope 2 2>&1)"; rc=$?
check "a slope that would overflow the slots is refused" "1" "$rc"
check "the refusal names the slot count" "1" "$(grep -c 'needs 17 filter slots' <<<"$out")"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== automatic headroom matches Model.js with bypassed and sloped bands =="
set4='[{"type":"peaking","freq":1000,"q":1.0,"gain":9,"enabled":false},{"type":"peaking","freq":200,"q":1.4,"gain":3}]'
set5='[{"type":"highpass","freq":60,"q":0.9,"gain":0,"slope":3},{"type":"lowshelf","freq":90,"q":0.7,"gain":5},{"type":"lowpass","freq":9000,"q":1.2,"gain":0,"slope":2}]'
jq -cn --argjson a "$set4" --argjson b "$set5" '[$a, $b]' >"$T/headroom-sets2.json"
model="$(node "$here/headroom-check.js" "$rate" "$T/headroom-sets2.json")"
for i in 0 1; do
  bands="$(jq -c ".[$i]" "$T/headroom-sets2.json")"
  got="$(backend_auto_preamp parametric "$bands")"
  want="$(jq -r ".[$i]" <<<"$model")"
  check "auto headroom matches Model.autoPreampDb for set $((i + 4))" "true" \
    "$(jq -cn --argjson a "$got" --argjson b "$want" '($a - $b) == 0')"
done
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== the A/B: Flat at the curve's own loudness =="
run set-mode graphic >/dev/null
run apply-preset Rock >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
out="$(run compare on)"
check "compare on reports the level it matched" "1" "$(grep -c "Playing Flat at the curve's loudness" <<<"$out")"
check "compare is live, not a rebuild" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "it is one live write" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "every slot is Off while comparing" "16" "$(grep -oE '"para:ft_[0-9]+" 0' "$PWCLI_LOG" | wc -l | tr -d ' ')"
check "status says what is playing" "flat" "$(run status | jq -r '.listen.mode')"
level="$(run status | jq -r '.listen.levelDb')"
model_level="$(node -e '
  const fs = require("fs"), vm = require("vm"), m = {}; vm.createContext(m);
  vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), m);
  const s = JSON.parse(process.argv[2]);
  process.stdout.write(m.curveLevelDb(s.bands, s.preamp, s.sampleRate).toFixed(2));' "$here/../Model.js" "$(run status)")"
check "the backend's level is Model.curveLevelDb's" "$model_level" "$(printf '%.2f' "$level")"
want_mult="$(LC_ALL=C awk -v d="$(run status | jq -r '.listen.preamp')" 'BEGIN { printf "%.6f", 10 ^ (d / 20) }')"
check "Flat plays under the matched preamp" "yes" \
  "$(grep -q "\"pre_l:Mult\" $want_mult" "$PWCLI_LOG" && echo yes || echo no)"
# The fragment carries what is playing, so a restart (one systemd makes on its
# own too) comes up on the same sound the state describes.
check "the fragment follows the comparison" "0" "$(grep -c '"ft_9" = 1' "$frag")"
run compare off >/dev/null
check "compare off plays the curve again" "null" "$(run status | jq -r '.listen')"
check "and the fragment carries the curve again" "1" "$(grep -c '"ft_9" = 1' "$frag")"
# A preamp change ends the comparison, and the curve has to come back with it --
# not only the preamp.
run compare on >/dev/null
: >"$PWCLI_LOG"
run set-preamp -4 >/dev/null
check "a preamp change during the A/B ends it" "null" "$(run status | jq -r '.listen')"
check "and writes the bands back, not just the preamp" "10" "$(grep -oE '"para:ft_[0-9]+" 1' "$PWCLI_LOG" | wc -l | tr -d ' ')"
run set-headroom auto >/dev/null
run compare toggle >/dev/null
run set-gain 0 1 >/dev/null
check "an edit ends the comparison" "null" "$(run status | jq -r '.listen')"
out="$(run compare maybe)"; rc=$?
check "compare takes on, off or toggle" "1|Compare must be on, off or toggle." "$rc|$out"

echo "== solo: one band alone =="
: >"$PWCLI_LOG"
run solo 4 >/dev/null
check "solo names the band" "solo|4" "$(run status | jq -r '"\(.listen.mode)|\(.listen.band)"')"
check "only that band's slot is on" "15" "$(grep -oE '"para:ft_[0-9]+" 0' "$PWCLI_LOG" | wc -l | tr -d ' ')"
check "the soloed band is the one left" "yes" "$(grep -q '"para:ft_0" 1 "para:fm_0" 6 "para:s_0" 0 "para:f_0" 500' "$PWCLI_LOG" && echo yes || echo no)"
run solo off >/dev/null
check "solo off plays every band" "null" "$(run status | jq -r '.listen')"
# A band alone may need more headroom than the curve: two bands that cancel.
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode parametric >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
jq -c '.parametric = [{"type":"peaking","freq":100,"q":1,"gain":10},{"type":"peaking","freq":100,"q":1,"gain":-8},{"type":"peaking","freq":2000,"q":1,"gain":4,"enabled":false}]' "$st" >"$st.x" && mv "$st.x" "$st"
run set-mode parametric >/dev/null
: >"$PWCLI_LOG"
run solo 0 >/dev/null
check "a soloed band plays under its own headroom, not the curve's" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"pre_l:Mult" 0.316228 ' && echo yes || echo no)"
run solo 2 >/dev/null
check "a bypassed band can be soloed" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"para:ft_0" 1 "para:fm_0" 6 "para:s_0" 0 "para:f_0" 2000' && echo yes || echo no)"
run solo off >/dev/null
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode graphic >/dev/null
run apply-preset Rock >/dev/null
out="$(run solo 40)"; rc=$?
check "solo refuses a band that does not exist" "1|Band 40 does not exist." "$rc|$out"

echo "== volume relief: a boost plays as a boost below full volume =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-mode graphic >/dev/null
run reset >/dev/null
export PACTL_SINK_VOLUME_DB=-20.00
: >"$PWCLI_LOG"
run set-gain 5 6 >/dev/null
check "at -20 dB the whole cut is given back" "-6.0|6|0" "$(run status | jq -r '"\(.preamp)|\(.relief)|\(.appliedPreamp)"')"
check "the relief reaches the graph with the bands" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"relief_l:Mult" 1.995262 "relief_r:Mult" 1.995262' && echo yes || echo no)"
check "the fragment carries it" "2" "$(grep -c 'name = relief_[lr] label = linear control = { "Mult" = 1.995262' "$frag")"
export PACTL_SINK_VOLUME_DB=-2.50
run set-gain 5 6 >/dev/null
check "near full volume only the headroom the volume leaves is given back" "2.5|-3.5" \
  "$(run status | jq -r '"\(.relief)|\(.appliedPreamp)"')"
export PACTL_SINK_VOLUME_DB=0.00
run set-gain 5 6 >/dev/null
check "at full volume the whole cut stands" "0" "$(run status | jq -r '.relief')"
# The follower keeps it in step when only the volume moves.
export PACTL_DEVICE_SINK=alsa_output.stub PACTL_DEFAULT_SINK=alsa_output.stub
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
export PACTL_SINK_VOLUME_DB=-12.00
: >"$PWCLI_LOG"
run retarget >/dev/null
check "a volume change moves the relief on the next pass" "6" "$(run status | jq -r '.relief')"
check "with one live write of the relief alone" "1" \
  "$(grep -c 'params = \[ "relief_l:Mult" 1.995262 "relief_r:Mult" 1.995262 "drelief_l:Mult" 1.000000 "drelief_r:Mult" 1.000000 \]' "$PWCLI_LOG")"
: >"$PWCLI_LOG"
run retarget >/dev/null
check "a pass with nothing to change writes nothing" "0" "$(grep -c 'relief_l' "$PWCLI_LOG")"
run set-preamp -8 >/dev/null
check "manual headroom takes no relief" "0" "$(run status | jq -r '.relief')"
run set-headroom auto >/dev/null
check "auto headroom takes it back" "6" "$(run status | jq -r '.relief')"
check "status reports the volume it read" "-12" "$(run status | jq -r '.volumeDb')"
# The relief lags a fast volume change by a follower pass, and the limiter is
# what keeps that moment clean: no limiter, no relief.
: >"$PWCLI_LOG"
run set-limiter off >/dev/null
check "with the limiter off there is no relief" "0" "$(run status | jq -r '.relief')"
check "and it is taken back in the same write as the limiter" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"limit:enabled" 0 .*"relief_l:Mult" 1.000000' && echo yes || echo no)"
run set-limiter on >/dev/null
check "the limiter back on brings the relief back" "6" "$(run status | jq -r '.relief')"
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"
run set-gain 5 6 >/dev/null
check "without LSP (and so no limiter) there is no relief" "0" "$(run status | jq -r '.relief')"
export OMARCHY_EQ_LV2_DIR="$T/lv2"
run set-gain 5 6 >/dev/null
unset PACTL_DEVICE_SINK PACTL_DEFAULT_SINK
unset PACTL_SINK_VOLUME_DB
run disable >/dev/null

echo "== channels and balance =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
export PACTL_DEFAULT_SINK=alsa_output.stub
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-channels mono >/dev/null
check "mono is live, not a rebuild" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "mono feeds each side half of both" "yes" \
  "$(grep -q '"mix_l:Gain 1" 0.500000 "mix_l:Gain 2" 0.500000 "mix_r:Gain 1" 0.500000 "mix_r:Gain 2" 0.500000' "$PWCLI_LOG" && echo yes || echo no)"
run set-channels swap >/dev/null
check "swap crosses the channels" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"mix_l:Gain 1" 0.000000 "mix_l:Gain 2" 1.000000 "mix_r:Gain 1" 1.000000 "mix_r:Gain 2" 0.000000' && echo yes || echo no)"
run set-channels stereo >/dev/null
run set-balance 0.5 >/dev/null
check "a balance to the right turns the left down, never the right up" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"mix_l:Gain 1" 0.500000 "mix_l:Gain 2" 0.000000 "mix_r:Gain 1" 0.000000 "mix_r:Gain 2" 1.000000' && echo yes || echo no)"
check "the fragment carries the balance" "1" "$(grep -c 'name = mix_l label = mixer control = { "Gain 1" = 0.500000' "$frag")"
out="$(run set-balance 2)"; rc=$?
check "a balance past the ends is refused" "1" "$rc"
out="$(run set-channels quad)"; rc=$?
check "channels take stereo, mono or swap" "1|Channels must be stereo, mono or swap." "$rc|$out"
run set-balance 0 >/dev/null
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"
run set-channels swap >/dev/null   # the first command rebuilds into the biquad layout
: >"$PWCLI_LOG"
run set-channels mono >/dev/null
check "channel handling works without LSP" "yes" "$(grep -q '"mix_r:Gain 2" 0.500000' "$PWCLI_LOG" && echo yes || echo no)"
run set-channels stereo >/dev/null
export OMARCHY_EQ_LV2_DIR="$T/lv2"
run disable >/dev/null

echo "== the leveler and the dynamics characters =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
export PACTL_DEFAULT_SINK=alsa_output.stub
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-leveler on >/dev/null
check "the leveler switches live" "0|yes" \
  "$(grep -c restart "$SYSTEMCTL_LOG")|$(tail -n1 "$PWCLI_LOG" | grep -q '"level:enabled" 1' && echo yes || echo no)"
check "it targets -18 LUFS with at most +12 dB of lift" "yes" \
  "$(grep 'name = level' "$frag" | grep -q '"level" = -18 .*"max_on" = 1 "max_amp" = 12' && echo yes || echo no)"
out="$(run set-leveler loud)"; rc=$?
check "the leveler takes on or off" "1|Leveler must be on or off." "$rc|$out"
run set-boost night >/dev/null
check "night compresses the mid band hardest" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:cr_1" 6 .*"boost:mk_1" 5.011872' && echo yes || echo no)"
run set-boost voice >/dev/null
check "voice barely touches the bass band" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:cr_0" 2 ' && echo yes || echo no)"
check "the compressor detects both channels together, from the louder" "yes" \
  "$(tail -n1 "$PWCLI_LOG" | grep -q '"boost:ssplit" 0 .*"boost:scs_0" 5 .*"boost:scs_2" 5' && echo yes || echo no)"
check "the limiter is stereo-linked with a 20 ms lookahead" "yes" \
  "$(grep 'name = limit' "$frag" | grep -q '"lk" = 20 "at" = 20 .*"alr" = 0 .*"slink" = 100' && echo yes || echo no)"
run set-boost off >/dev/null
run set-leveler off >/dev/null
run disable >/dev/null
unset PACTL_DEVICE_SINK PACTL_DEFAULT_SINK

echo "== the latency budget =="
# The chain must stay usable for video: the limiter's lookahead is the only real
# latency in it (tests/dsp-check.sh measures what the graph reports).
check "the limiter looks ahead at most 20 ms" "yes" \
  "$(grep 'name = limit' "$frag" | grep -oE '"lk" = [0-9.]+' | awk '{ print ($3 <= 20) ? "yes" : "no" }')"
check "the band pool runs IIR filters (no FFT latency)" "1" "$(grep 'name = para' "$frag" | grep -c '"mode" = 0 ')"
check "the compressor never runs linear phase" "0" "$(grep 'name = boost' "$frag" | grep -c '"mode" = 2 ')"
check "the leveler adds no lookahead" "1" "$(grep 'name = level' "$frag" | grep -c '"lkahead" = 0 ')"

echo "== the graph rate follows a running sink =="
export PACTL_EQ_STATE=RUNNING PACTL_EQ_RATE=96000
check "a running sink's negotiated rate wins" "96000" "$(run status | jq -r '.sampleRate')"
export PACTL_EQ_STATE=SUSPENDED
check "an idle sink falls back to the clock rate" "44100" "$(run status | jq -r '.sampleRate')"
unset PACTL_EQ_STATE PACTL_EQ_RATE

echo "== excluded apps play straight to the device =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run disable >/dev/null
export PACTL_DEVICE_SINK=alsa_output.stub PACTL_DEFAULT_SINK=alsa_output.stub
run exclude-app zoom >/dev/null
check "an excluded app is stored" '["zoom"]' "$(run status | jq -c '.excludedApps')"
export PACTL_APP_STREAMS="42:2:Chromium:chromium,43:2:ZOOM:zoom" PACTL_LOG="$T/pactl-excl.log"; : >"$PACTL_LOG"
run enable >/dev/null
check "enable moves the other apps onto the equalizer" "1" "$(grep -c '^move-sink-input 42 omarchy_equalizer$' "$PACTL_LOG")"
check "and the excluded app to the device, matched without case" "1" "$(grep -c '^move-sink-input 43 alsa_output.stub$' "$PACTL_LOG")"
export PACTL_DEFAULT_SINK=omarchy_equalizer
# WirePlumber puts a new stream of it on the default sink -- the equalizer.
export PACTL_APP_STREAMS="42:1:Chromium:chromium,44:1:zoom:zoom"; : >"$PACTL_LOG"
run retarget >/dev/null
check "the follower moves an excluded stream off the equalizer" "1" "$(grep -c '^move-sink-input 44 alsa_output.stub$' "$PACTL_LOG")"
check "and leaves the rest alone" "0" "$(grep -c '^move-sink-input 42 ' "$PACTL_LOG")"
check "status lists the apps playing, excluded or not" "Chromium:false|zoom:true" \
  "$(run status | jq -r '[.apps[] | "\(.name):\(.excluded)"] | join("|")')"
: >"$PACTL_LOG"
run include-app ZOOM >/dev/null
check "include-app puts it back on the equalizer now" "1" "$(grep -c '^move-sink-input 44 omarchy_equalizer$' "$PACTL_LOG")"
check "and drops it from the list" "[]" "$(run status | jq -c '.excludedApps')"
out="$(run include-app zoom)"; rc=$?
check "including an app that is not excluded is refused" "1|'zoom' is not excluded." "$rc|$out"
# Excluded by its binary, put back by the name the panel shows.
run exclude-app zoom >/dev/null
export PACTL_APP_STREAMS="42:1:Chromium:chromium,45:1:Zoom Meeting:zoom"
out="$(run include-app "Zoom Meeting")"; rc=$?
check "an app excluded by binary is put back by its name" "0|[]" "$rc|$(run status | jq -c '.excludedApps')"
# A device the user picks moves the apps onto the EQ -- the excluded ones to the device.
run exclude-app zoom >/dev/null
export PACTL_DEFAULT_SINK=alsa_output.stub; : >"$PACTL_LOG"
run retarget >/dev/null
check "a manual device pick sends an excluded app to the device, never to the EQ" "yes|0" \
  "$( (( $(grep -c '^move-sink-input 45 alsa_output.stub$' "$PACTL_LOG") >= 1 )) && echo yes || echo no)|$(grep -c '^move-sink-input 45 omarchy_equalizer$' "$PACTL_LOG")"
export PACTL_DEFAULT_SINK=omarchy_equalizer
run include-app zoom >/dev/null
check "the follower wakes for a new stream" "wake" "$(follow_event_wanted "Event 'new' on sink-input #12" && echo wake || echo ignore)"
unset PACTL_APP_STREAMS PACTL_LOG PACTL_DEVICE_SINK PACTL_DEFAULT_SINK
run disable >/dev/null

echo "== every output device keeps its own curve =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run disable >/dev/null
export PACTL_DEVICE_SINK=audio_effect.stub-dsp PACTL_DEFAULT_SINK=audio_effect.stub-dsp
run apply-preset Rock >/dev/null
run enable >/dev/null
st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
check "the device it plays into is the active one" "audio_effect.stub-dsp" "$(jq -r '.activeDevice' "$st")"
export PACTL_DEFAULT_SINK=omarchy_equalizer
run retarget >/dev/null
jq -c '.targetPickedAt = 100' "$st" >"$st.x" && mv "$st.x" "$st"
buds=bluez_output.AA_BB_CC_DD_EE_FF.1
export PACTL_DEVICE_SINK2=$buds; run retarget >/dev/null
export PACTL_EQ_AIM=1 PACTL_EQ_AIM_SINK_ID=3; run retarget >/dev/null
check "a device seen for the first time keeps what was playing" "$buds|Rock" "$(jq -r '"\(.targetSink)|\(.preset)"' "$st")"
check "the device is keyed without its profile suffix" "bluez_output.AA_BB_CC_DD_EE_FF" "$(jq -r '.activeDevice' "$st")"
run apply-preset "Bass Boost" >/dev/null
# The earbuds go back in the case: the stream falls back to the speakers.
export PACTL_DEVICE_SINK2= PACTL_EQ_AIM_SINK_ID=2
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run retarget >/dev/null
check "back on the speakers, their own curve comes back" "audio_effect.stub-dsp|Rock" "$(jq -r '"\(.targetSink)|\(.preset)"' "$st")"
check "the switch is live, not a rebuild" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
check "and reaches the graph" "1" "$(grep -c 'para:ft_0' "$PWCLI_LOG")"
check "a device-curve switch clears the undo history" "false|false" "$(run status | jq -r '"\(.canUndo)|\(.canRedo)"')"
check "the earbuds' curve is remembered" "Bass Boost" "$(jq -r '.deviceCurves["bluez_output.AA_BB_CC_DD_EE_FF"].preset' "$st")"
# The earbuds come back, under their other profile.
export PACTL_DEVICE_SINK2=bluez_output.AA_BB_CC_DD_EE_FF.2 PACTL_EQ_AIM_SINK_ID=3
jq -c '.targetPickedAt = 100 | .seenSinks = {}' "$st" >"$st.x" && mv "$st.x" "$st"
run retarget >/dev/null
run retarget >/dev/null
check "back on the earbuds, theirs comes back" "Bass Boost" "$(jq -r '.preset' "$st")"
check "devices lists what is remembered" "audio_effect.stub-dsp:Rock|bluez_output.AA_BB_CC_DD_EE_FF:Bass Boost" \
  "$(run devices | jq -r '[.[] | "\(.device):\(.preset)"] | join("|")')"
run forget-device audio_effect.stub-dsp >/dev/null
check "forget-device drops a device's curve" "1" "$(run devices | jq 'length')"
run set-device-memory off >/dev/null
export PACTL_DEVICE_SINK2= PACTL_EQ_AIM_SINK_ID=2
run retarget >/dev/null
check "with device memory off one curve plays everywhere" "Bass Boost" "$(jq -r '.preset' "$st")"
unset PACTL_DEVICE_SINK2 PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID
run set-device-memory on >/dev/null
check "status names the device and its description" "audio_effect.stub-dsp|Stub audio_effect.stub-dsp" \
  "$(run status | jq -r '"\(.deviceKey)|\(.deviceLabel)"')"
# A curve picked while the EQ is off is for the device it plays into next: not
# filed under the one it played into before, and not replaced by the next one's.
jq -c '.deviceCurves = { "audio_effect.stub-dsp": { mode: "graphic", preset: "Jazz", graphic: .graphic, parametric: .parametric, preamp: 0, headroom: "auto" } }
  | .activeDevice = "bluez_output.AA_BB_CC_DD_EE_FF"' "$st" >"$st.x" && mv "$st.x" "$st"
run disable >/dev/null
run apply-preset Pop >/dev/null
export PACTL_DEFAULT_SINK=audio_effect.stub-dsp
run enable >/dev/null
check "a curve picked while off plays at the next enable" "Pop" "$(jq -r '.preset' "$st")"
check "the device's own remembered curve is left as it was" "Jazz" "$(jq -r '.deviceCurves["audio_effect.stub-dsp"].preset' "$st")"
check "the previous device does not inherit the pick" "null" "$(jq -r '.deviceCurves["bluez_output.AA_BB_CC_DD_EE_FF"].preset // "null"' "$st")"
check "and the pick is no longer pending" "null" "$(jq -r '.curveEditedOff // "null"' "$st")"
run disable >/dev/null
unset PACTL_DEFAULT_SINK PACTL_DEVICE_SINK

echo "== preset files =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run export-preset Rock "$T/rock.json" >/dev/null
check "an exported preset names its format, version and name" "omarchy-equalizer-preset|1|Rock" \
  "$(jq -r '"\(.format)|\(.version)|\(.name)"' "$T/rock.json")"
check "it carries the bands and the preamp" "10|-0.5" "$(jq -r '"\(.graphic | length)|\(.preamp)"' "$T/rock.json")"
out="$(run import-preset "$T/rock.json")"; rc=$?
check "a built-in's name is refused on import" "1" "$rc"
out="$(run import-preset "$T/rock.json" "My Rock")"; rc=$?
check "imported under its own name" "0|My Rock" "$rc|$(jq -r '.preset' <<<"$out")"
check "the import is a user preset" "user" "$(run status | jq -r '[.presets[] | select(.name == "My Rock")][0].category')"
run apply-preset "My Rock" >/dev/null
check "and applies like one" "My Rock|false" "$(run status | jq -r '"\(.preset)|\(.presetDirty)"')"
jq '.graphic[0].gain = 90' "$T/rock.json" >"$T/loud.json"
out="$(run import-preset "$T/loud.json" Loud)"; rc=$?
check "an out-of-range preset file is refused" "1" "$rc"
check "and says why" "1" "$(grep -c 'out of range: Band 0 gain 90' <<<"$out")"
jq '.graphic[0].q = "0.7}\nINJECTED_MARKER"' "$T/rock.json" >"$T/evil.json"
out="$(run import-preset "$T/evil.json" Evil)"; rc=$?
check "a crafted preset file is refused" "1" "$rc"
printf '{"name":"x"}\n' >"$T/notapreset.json"
out="$(run import-preset "$T/notapreset.json")"; rc=$?
check "a file without the format is refused" "1|'$T/notapreset.json' is not an equalizer preset." "$rc|$out"
out="$(run apply-preset ../../etc/x)"; rc=$?
check "a preset name cannot step out of the preset directory" "1" "$rc"
run delete-preset "My Rock" >/dev/null

echo "== the state file carries its version, and keys it does not know =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-gain 1 2 >/dev/null
check "a written state names its version" "4" "$(jq -r '.version' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
jq '.futureKey = {"kept": true} | .version = 7' "$XDG_STATE_HOME/omarchy-equalizer/state.json" >"$T/s.json" &&
  mv "$T/s.json" "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run set-gain 1 3 >/dev/null
check "an unknown key survives an edit" "true" "$(jq -r '.futureKey.kept' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
check "a newer version number is not written back down" "7" "$(jq -r '.version' "$XDG_STATE_HOME/omarchy-equalizer/state.json")"
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== AutoEq: unnumbered filters and a built-in's name =="
printf 'Preamp: -3 dB\nFilter: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0\nFilter: ON LSC Fc 105 Hz Gain 2.0 dB Q 0.7\n' >"$T/Rock ParametricEQ.txt"
out="$(run import-autoeq "$T/Rock ParametricEQ.txt")"; rc=$?
check "unnumbered filter lines import" "0|2" "$rc|$(jq -r '.bands' <<<"$out")"
check "a profile named like a built-in is saved under a suffix" "Rock (AutoEq)" "$(jq -r '.preset' <<<"$out")"
check "and the state names the suffixed preset" "Rock (AutoEq)" "$(run status | jq -r '.preset')"
run delete-preset "Rock (AutoEq)" >/dev/null
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"

echo "== the queue path walks the preamp too =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json" "$XDG_STATE_HOME/omarchy-equalizer/history.json"
run set-mode parametric >/dev/null
: >"$PWCLI_LOG"
unset OMARCHY_EQ_NO_RAMP
run set-gain 4 6 >/dev/null
# The walk is detached; it is done when the preamp lands on the new cut.
for _ in $(seq 300); do tail -n1 "$PWCLI_LOG" | grep -q '"pre_l:Mult" 0.501187' && break; sleep 0.02; done
export OMARCHY_EQ_NO_RAMP=1
check "a band edit goes in under the preamp the graph had" "1" "$(head -n1 "$PWCLI_LOG" | grep -c '"para:g_4" 1.995262.*\|"pre_l:Mult" 1.000000')"
check "and the preamp walks to the new cut in 0.1 dB steps" "60|1" \
  "$(grep -vc 'para:' "$PWCLI_LOG")|$(tail -n1 "$PWCLI_LOG" | grep -c '"pre_l:Mult" 0.501187')"
# An A/B is a comparison: it switches at once, not over a walk.
: >"$PWCLI_LOG"
unset OMARCHY_EQ_NO_RAMP
run compare on >/dev/null
sleep 0.3
export OMARCHY_EQ_NO_RAMP=1
check "an A/B switches in one write, without a walk" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
run compare off >/dev/null

echo "== set-gains: every band at once =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json" "$XDG_STATE_HOME/omarchy-equalizer/history.json"
run set-mode graphic >/dev/null
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run set-gains 1 2 3 4 5 6 7 8 9 10 >/dev/null
check "set-gains sets every band" "1,2,3,4,5,6,7,8,9,10" "$(run status | jq -r '[.bands[].gain | tostring] | join(",")')"
check "in one live write" "1" "$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
check "without a restart" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
out="$(run set-gains 1 2 3)"; rc=$?
check "the wrong count is refused" "1|set-gains takes one gain per band: 10, not 3." "$rc|$out"
out="$(run set-gains 1 2 3 4 5 6 7 8 9 x)"; rc=$?
check "a non-number is refused" "1|'x' is not a number." "$rc|$out"
out="$(run set-gains 1 2 3 4 5 6 7 8 9 40)"; rc=$?
check "a gain out of range is refused" "1" "$rc"
check "and a refused set leaves the bands as they were" "10" "$(run status | jq -r '.bands[9].gain')"

echo "== add-band where the curve was double-clicked =="
run set-mode parametric >/dev/null
n="$(run status | jq '.bands | length')"
run add-band 3150 4.5 1 peaking >/dev/null
check "add-band takes a frequency, a gain, a Q and a type" "3150|4.5|1|peaking" \
  "$(run status | jq -r '.bands[-1] | "\(.freq)|\(.gain)|\(.q)|\(.type)"')"
check "and appends one band" "$((n + 1))" "$(run status | jq '.bands | length')"
out="$(run add-band 1000 0 1 wobble)"; rc=$?
check "a type the graph does not know is refused" "1" "$rc"
out="$(run add-band 99999)"; rc=$?
check "a frequency out of range is refused" "1" "$rc"
check "and nothing was added by either" "$((n + 1))" "$(run status | jq '.bands | length')"
run remove-band "$n" >/dev/null

echo "== undo, redo and revert =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json" "$XDG_STATE_HOME/omarchy-equalizer/history.json"
run set-mode graphic >/dev/null
rm -f "$XDG_STATE_HOME/omarchy-equalizer/history.json"
out="$(run undo)"; rc=$?
check "nothing to undo says so" "1|Nothing to undo." "$rc|$out"
run set-gain 2 3 >/dev/null
check "an edit can be undone" "true|false" "$(run status | jq -r '"\(.canUndo)|\(.canRedo)"')"
: >"$SYSTEMCTL_LOG"; : >"$PWCLI_LOG"
run undo >/dev/null
check "undo puts the curve back" "0|false|true" "$(run status | jq -r '"\(.bands[2].gain)|\(.canUndo)|\(.canRedo)"')"
check "live, without a restart" "0|1" "$(grep -c restart "$SYSTEMCTL_LOG")|$(wc -l <"$PWCLI_LOG" | tr -d ' ')"
run redo >/dev/null
check "redo puts the edit back" "3|true|false" "$(run status | jq -r '"\(.bands[2].gain)|\(.canUndo)|\(.canRedo)"')"
for g in 4 5 6 7; do run set-gain 2 "$g" >/dev/null; done
run undo >/dev/null
check "a burst of set-gain on one band within a second is one step" "3" "$(run status | jq -r '.bands[2].gain')"
run redo >/dev/null
run apply-preset Rock >/dev/null
run undo >/dev/null
check "a preset can be undone" "Flat|7" "$(run status | jq -r '"\(.preset)|\(.bands[2].gain)"')"
run reset >/dev/null
run undo >/dev/null
check "a reset can be undone" "7" "$(run status | jq -r '.bands[2].gain')"
run set-mode parametric >/dev/null
run undo >/dev/null
check "a mode switch can be undone" "graphic" "$(run status | jq -r '.mode')"
run set-preamp -12 >/dev/null
run undo >/dev/null
check "a hand-set preamp can be undone, headroom and all" "auto" "$(run status | jq -r '.headroom')"
run set-gain 1 1 >/dev/null
check "a new edit after an undo clears redo" "false" "$(run status | jq -r '.canRedo')"
steps="$(jq '.undo | length' "$XDG_STATE_HOME/omarchy-equalizer/history.json")"
run save-preset "Undo Test" >/dev/null
check "saving a preset is not a step" "$steps" "$(jq '.undo | length' "$XDG_STATE_HOME/omarchy-equalizer/history.json")"
run delete-preset "Undo Test" >/dev/null
printf 'Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0\n' >"$T/Undone ParametricEQ.txt"
run import-autoeq "$T/Undone ParametricEQ.txt" >/dev/null
run undo >/dev/null
check "an AutoEq import can be undone" "graphic" "$(run status | jq -r '.mode')"
run delete-preset "Undone" >/dev/null
for i in $(seq 1 35); do run set-gain $((i % 10)) "$((i / 10)).$((i % 10))" >/dev/null; done
check "the history keeps at most 30 steps" "30" "$(jq '.undo | length' "$XDG_STATE_HOME/omarchy-equalizer/history.json")"
run apply-preset Rock >/dev/null
run set-gain 4 5 >/dev/null
check "an edited preset reads as edited" "true" "$(run status | jq -r '.presetDirty')"
run revert-preset >/dev/null
check "revert-preset goes back to it as saved" "Rock|false" "$(run status | jq -r '"\(.preset)|\(.presetDirty)"')"
run undo >/dev/null
check "and the revert is a step of its own" "true" "$(run status | jq -r '.presetDirty')"
run save-preset "Gone Soon" >/dev/null
run delete-preset "Gone Soon" >/dev/null
out="$(run revert-preset)"; rc=$?
check "a preset that is gone cannot be reverted to" "1" "$rc"
# Only a burst on one band merges: two presets in a second are two steps.
run apply-preset Rock >/dev/null
run apply-preset Jazz >/dev/null
run undo >/dev/null
check "two presets within a second are two steps" "Rock" "$(run status | jq -r '.preset')"

echo "== balanced headroom =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json" "$XDG_STATE_HOME/omarchy-equalizer/history.json"
run set-mode graphic >/dev/null
run set-gains 8 6 4 0 0 0 0 0 0 0 >/dev/null
safe="$(run status | jq -r '.preamp')"
: >"$PWCLI_LOG"
run set-headroom balanced >/dev/null
check "balanced plays the balanced preamp" "balanced|true" "$(run status | jq -r '"\(.headroom)|\(.preamp == .balancedPreamp)"')"
check "which cuts less than safe for a bass shelf" "true" "$(run status | jq --argjson s "$safe" '.preamp > $s')"
check "the switch reaches the graph" "1" "$(grep -c 'pre_l:Mult' "$PWCLI_LOG")"
check "a manual preamp's ceiling stays the safe one" "true" "$(run status | jq '.preampCeiling == .autoPreamp')"
: >"$PWCLI_LOG"
run set-limiter off >/dev/null
check "without the limiter balanced plays as safe" "balanced|$safe" "$(run status | jq -r '"\(.headroom)|\(.preamp)"')"
check "and the limiter switch moves the preamp in the graph too" "1" "$(grep -c 'pre_l:Mult' "$PWCLI_LOG")"
run set-limiter on >/dev/null
check "with the limiter back it is balanced again" "true" "$(run status | jq '.preamp == .balancedPreamp')"
run set-gain 3 3 >/dev/null
check "an edit under balanced stays balanced" "true" "$(run status | jq '.preamp == .balancedPreamp')"
check "the summary of the cut is in the status" "true" "$(run status | jq '(.programGainDb | type) == "number"')"
# An edit recomputes the relief; at -20 dB the whole balanced cut is given back.
PACTL_SINK_VOLUME_DB=-20 run set-gain 3 3 >/dev/null
check "the volume relief gives back the balanced cut" "true" "$(run status | jq '.relief == -.preamp and .relief > 0')"
run set-gain 3 3 >/dev/null
export OMARCHY_EQ_LV2_DIR="$T/lv2-missing"
run set-gain 3 2 >/dev/null
check "without LSP balanced plays as safe" "true" "$(run status | jq '.preamp == .autoPreamp')"
export OMARCHY_EQ_LV2_DIR="$T/lv2"
run set-gain 3 3 >/dev/null
run set-headroom auto >/dev/null
check "and back to safe" "auto|true" "$(run status | jq -r '"\(.headroom)|\(.preamp == .autoPreamp)"')"

echo "== a hint when Bluetooth shares the band with Wi-Fi =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json"
run disable >/dev/null
export PACTL_DEVICE_SINK=bluez_output.AA_BB_CC_DD_EE_FF.1 PACTL_DEFAULT_SINK=bluez_output.AA_BB_CC_DD_EE_FF.1
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
check "Bluetooth output with Wi-Fi on 2.4 GHz is flagged" "true" "$(IW_FREQ=2437.0 run status | jq -r '.bluetoothOn24GhzWifi')"
check "on 5 GHz it is not" "false" "$(IW_FREQ=5180.0 run status | jq -r '.bluetoothOn24GhzWifi')"
check "nor with Wi-Fi disconnected" "false" "$(IW_FREQ= run status | jq -r '.bluetoothOn24GhzWifi')"
run disable >/dev/null
export PACTL_DEVICE_SINK=alsa_output.stub PACTL_DEFAULT_SINK=alsa_output.stub
run enable >/dev/null
check "a wired output on 2.4 GHz Wi-Fi is not flagged" "false" "$(IW_FREQ=2437.0 run status | jq -r '.bluetoothOn24GhzWifi')"
run disable >/dev/null
unset PACTL_DEVICE_SINK PACTL_DEFAULT_SINK

echo "== device relief: the cut given back as the device volume allows =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json" "$XDG_STATE_HOME/omarchy-equalizer/history.json"
run disable >/dev/null
export PACTL_DEVICE_SINK=audio_effect.stub-dsp PACTL_DEFAULT_SINK=audio_effect.stub-dsp
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
run set-mode graphic >/dev/null
run set-gains 0 0 0 0 0 6 0 0 0 0 >/dev/null
export PACTL_DEVICE_VOLUME_DB=-12.00
run retarget >/dev/null
check "off by default: nothing is given back, whatever the device volume" "off|0|-6" \
  "$(run status | jq -r '"\(.followDeviceVolume)|\(.deviceRelief)|\(.appliedPreamp)"')"
: >"$PWCLI_LOG"
run set-device-relief on >/dev/null
check "on, the cut is given back as far as the device volume allows" "6|0" "$(run status | jq -r '"\(.deviceRelief)|\(.appliedPreamp)"')"
check "and it reaches the graph" "1" "$(grep -c '"drelief_l:Mult" 1.995262' "$PWCLI_LOG")"
frag="$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf"
check "the fragment carries it, so a restart keeps it" "1" "$(grep -c 'name = drelief_l label = linear control = { "Mult" = 1.995262' "$frag")"
# A walk the relief alone takes over is finished, not stranded: the device
# relief is written as the follower has it and the preamp at the walk's target.
unset OMARCHY_EQ_NO_RAMP
run set-gains 8 6 4 0 0 0 0 0 0 0 >/dev/null
sleep 0.1
check "a deeper cut walks while the limiter is on" "1" "$(grep -c '^w' "$XDG_STATE_HOME/omarchy-equalizer/gain-walk")"
PACTL_DEVICE_VOLUME_DB=-2.00 run retarget >/dev/null
export OMARCHY_EQ_NO_RAMP=1
sleep 0.2
check "the relief's own write ends the walk" "0" "$(wc -c <"$XDG_STATE_HOME/omarchy-equalizer/gain-walk" | tr -d ' ')"
check "with the walk's preamp target and the follower's device relief" "1" \
  "$(tail -n1 "$PWCLI_LOG" | grep -c '"pre_l:Mult" 0.334965.*"drelief_l:Mult" 1.258925\|"drelief_l:Mult" 1.258925.*"pre_l:Mult" 0.334965')"
check "which is what the state says" "-9.5|2" "$(PACTL_DEVICE_VOLUME_DB=-2.00 run status | jq -r '"\(.preamp)|\(.deviceRelief)"')"
run set-gains 0 0 0 0 0 6 0 0 0 0 >/dev/null
export PACTL_DEVICE_VOLUME_DB=-3.50
run retarget >/dev/null
check "a louder device gives less back" "3.5" "$(run status | jq -r '.deviceRelief')"
export PACTL_DEVICE_FLAGS="HARDWARE HW_VOLUME_CTRL DECIBEL_VOLUME LATENCY"
run retarget >/dev/null
check "a volume in the device's hardware (Bluetooth) gives nothing back" "0" "$(run status | jq -r '.deviceRelief')"
unset PACTL_DEVICE_FLAGS
export PACTL_DEVICE_MUTE=yes; run retarget >/dev/null
check "a muted device gives nothing back" "0" "$(run status | jq -r '.deviceRelief')"
unset PACTL_DEVICE_MUTE
export PACTL_DEVICE_BASE=80; run retarget >/dev/null
check "a base volume under 100 % gives nothing back" "0" "$(run status | jq -r '.deviceRelief')"
unset PACTL_DEVICE_BASE
export PACTL_DEVICE_VOLUME_DB=-12.00; run retarget >/dev/null
PACTL_SINK_VOLUME_DB=-2.00 run retarget >/dev/null
check "the equalizer's own volume gives back its part first" "2|4" \
  "$(PACTL_SINK_VOLUME_DB=-2.00 run status | jq -r '"\(.relief)|\(.deviceRelief)"')"
run retarget >/dev/null
run set-headroom manual >/dev/null
check "manual headroom takes none" "0" "$(run status | jq -r '.deviceRelief')"
run set-headroom auto >/dev/null
run set-limiter off >/dev/null
check "without the limiter there is none" "0" "$(run status | jq -r '.deviceRelief')"
run set-limiter on >/dev/null
check "with it back there is again" "6" "$(run status | jq -r '.deviceRelief')"
# The follower answers a volume change on the device it plays into at once, on
# its own write, before the event burst is drained.
echo "-12.00" >"$T/device-volume"
export PACTL_DEVICE_VOLUME_FILE="$T/device-volume"
: >"$PWCLI_LOG"
( sleep 0.2; echo "-4.00" >"$T/device-volume" ) &
PACTL_SUBSCRIBE_COUNT=1 PACTL_SUBSCRIBE_EVENT="Event 'change' on sink #2" run follow >/dev/null
wait
check "a volume change on the device is answered with the device relief alone" "1" \
  "$(grep -c 'params = \[ "drelief_l:Mult" 1.584893 "drelief_r:Mult" 1.584893 \]' "$PWCLI_LOG")"
check "and the state follows" "4" "$(run status | jq -r '.deviceRelief')"
# A held volume key is one close burst, its steps landing while a retarget pass
# is still running: the follower's own listener answers every one of them.
echo "-12.00" >"$T/device-volume"
run retarget >/dev/null
: >"$PWCLI_LOG"
( sleep 0.1; echo "-8.00" >"$T/device-volume"; sleep 0.12; echo "-5.00" >"$T/device-volume"; sleep 0.12; echo "-3.00" >"$T/device-volume" ) &
PACTL_SUBSCRIBE_COUNT=4 PACTL_SUBSCRIBE_GAP=0.12 PACTL_SUBSCRIBE_EVENT="Event 'change' on sink #2" run follow >/dev/null
wait
# At a 6 dB cut the device relief is 6 dB at -12 and at -8 dB: -5 and -3 change it.
check "a held volume key is followed step by step" "2" \
  "$(grep -c 'params = \[ "drelief_l:Mult" [0-9.]* "drelief_r:Mult" [0-9.]* \]' "$PWCLI_LOG")"
check "to the last step" "3" "$(run status | jq -r '.deviceRelief')"
unset PACTL_DEVICE_VOLUME_FILE PACTL_DEVICE_VOLUME_DB
run set-device-relief off >/dev/null
check "off again, nothing is given back" "0" "$(run status | jq -r '.deviceRelief')"
run disable >/dev/null
unset PACTL_DEVICE_SINK PACTL_DEFAULT_SINK

echo "== the live editor: a drag streamed into the graph =="
rm -f "$XDG_STATE_HOME/omarchy-equalizer/state.json" "$XDG_STATE_HOME/omarchy-equalizer/history.json"
run disable >/dev/null
export PACTL_DEVICE_SINK=alsa_output.stub PACTL_DEFAULT_SINK=alsa_output.stub
run enable >/dev/null
export PACTL_DEFAULT_SINK=omarchy_equalizer
run set-mode parametric >/dev/null
rm -f "$XDG_STATE_HOME/omarchy-equalizer/history.json"
# A jq that counts itself, for the live process only: nothing between ready and
# commit may run one.
real_jq="$(command -v jq)"
mkdir -p "$T/jqlog"
printf '#!/bin/bash\n[[ -n ${JQ_LOG:-} ]] && printf x >>"$JQ_LOG"\nexec %q "$@"\n' "$real_jq" >"$T/jqlog/jq"
chmod +x "$T/jqlog/jq"
live_pid=""
live_start() { # [env assignments...]
  rm -f "$T/live.in"; mkfifo "$T/live.in"; : >"$T/live.out"
  env "$@" PATH="$T/jqlog:$PATH" JQ_LOG="$T/jq.log" "$E" live <"$T/live.in" >"$T/live.out" 2>"$T/live.err" &
  live_pid=$!
  exec 8>"$T/live.in"
  live_wait_for '^(ready|unavailable)'
}
live_send() { printf '%s\n' "$@" >&8; }
live_wait_for() { local i; for i in $(seq 1 300); do grep -qE "$1" "$T/live.out" && return 0; sleep 0.02; done; return 1; }
live_wait_writes() { local i; for i in $(seq 1 300); do (( $(wc -l <"$PWCLI_LOG") >= $1 )) && return 0; sleep 0.01; done; return 1; }
live_stop() { exec 8>&-; wait "$live_pid" 2>/dev/null; live_rc=$?; }
live_writes() { wc -l <"$PWCLI_LOG" | tr -d ' '; }

live_start OMARCHY_EQ_NO_RAMP=0
check "the editor says it is ready, with the shape it holds" "ready parametric:8:8" "$(head -n1 "$T/live.out")"
: >"$PWCLI_LOG"; : >"$T/jq.log"
live_send "freq 2 300"; live_wait_writes 1
check "a frequency is one write of only that control" 'params = [ "para:f_2" 300 ]' "$(grep -o 'params = \[.*\]' "$PWCLI_LOG")"
live_send "gain 2 4.5"; live_wait_writes 2
check "a gain is one write of only that slot" 'params = [ "para:g_2" 1.678804 ]' "$(tail -n1 "$PWCLI_LOG" | grep -o 'params = \[.*\]')"
check "with the limiter on the preamp is held" "0" "$(grep -c 'pre_l' "$PWCLI_LOG")"
live_send 'gain 2 1}' 'freq 2 1e9' 'gain 99 1' 'q 2 -1' 'preamp abc' 'gain 2 "x"' 'bogus 1'
live_wait_for 'unknown line'
check "every bad line is refused" "7" "$(grep -c '^error ' "$T/live.out")"
check "and none of them reaches the graph" "2" "$(live_writes)"
burst=()
for i in $(seq 1 50); do burst+=("gain 2 $((i % 9)).25"); done
live_send "${burst[@]}"
live_wait_writes 3; sleep 0.3
check "a burst of 50 lines is one or two writes" "yes" "$( (( $(live_writes) <= 4 )) && echo yes || echo no)"
check "and the graph ends on the last value" "1" "$(tail -n1 "$PWCLI_LOG" | grep -c "\"para:g_2\" $(LC_ALL=C awk 'BEGIN { printf "%.6f", 10 ^ (5.25 / 20) }')")"
# Line to graph, one at a time: the cost of a line on the stubs.
total=0
for i in $(seq 1 20); do
  n0="$(live_writes)"; t0="${EPOCHREALTIME//[!0-9]/}"
  live_send "gain 4 $((i % 7)).5"
  until (( $(live_writes) > n0 )); do :; done
  total=$((total + ${EPOCHREALTIME//[!0-9]/} - t0))
done
mean=$((total / 20 / 1000))
printf '      a line reaches the graph in %s ms on average\n' "$mean"
check "a line reaches the graph in under 25 ms" "yes" "$( ((mean < 25)) && echo yes || echo no)"
check "no jq runs between ready and commit" "0" "$(wc -c <"$T/jq.log" | tr -d ' ')"
n0="$(live_writes)"
live_send commit
live_wait_for '^status '
check "the commit answers with the status" "1" "$(grep -c '^status {' "$T/live.out")"
check "and files the edit" "300|5.25|6.5" "$(run status | jq -r '"\(.bands[2].freq)|\(.bands[2].gain)|\(.bands[4].gain)"')"
check "as one undo step" '["live:2,4"]' "$(jq -c '[.undo[].key]' "$XDG_STATE_HOME/omarchy-equalizer/history.json")"
settled="$(run status | jq -r '.preamp')"
final="\"pre_l:Mult\" $(LC_ALL=C awk -v p="$settled" 'BEGIN { printf "%.6f", 10 ^ (p / 20) }')"
for _ in $(seq 400); do tail -n1 "$PWCLI_LOG" | grep -q "$final" && break; sleep 0.02; done
# The commit sends the session's own controls once more (another command may
# have written over them meanwhile), and the rest is the walk.
check "the preamp settles in 0.1 dB steps of the flat gains alone" \
  "$(LC_ALL=C awk -v p="$settled" 'BEGIN { n = int(-p / 0.1 + 0.999999); print n "|1" }')" \
  "$(tail -n +$((n0 + 1)) "$PWCLI_LOG" | grep -c 'pre_l:Mult')|$(tail -n +$((n0 + 1)) "$PWCLI_LOG" | grep -c 'para:')"
check "and lands where the state has it" "1" "$(tail -n1 "$PWCLI_LOG" | grep -c "$final")"
# Two gestures on one band within a second are two steps: a drag is one.
live_send "gain 2 1" commit
for _ in $(seq 300); do (( $(grep -c '^status ' "$T/live.out") >= 2 )) && break; sleep 0.02; done
live_send "gain 2 2" commit
for _ in $(seq 300); do (( $(grep -c '^status ' "$T/live.out") >= 3 )) && break; sleep 0.02; done
check "two live commits on one band within a second are two undo steps" '["live:2,4","live:2","live:2"]' \
  "$(jq -c '[.undo[].key]' "$XDG_STATE_HOME/omarchy-equalizer/history.json")"
# The state moves while the commit waits for the lock: the commit is stale,
# and it still answers with the status, so the panel is never left waiting.
live_send "gain 6 3"; sleep 0.3
( exec 9>"$XDG_STATE_HOME/omarchy-equalizer/.lock"; flock 9; sleep 0.6
  st="$XDG_STATE_HOME/omarchy-equalizer/state.json"; jq -c '.parametric[7].gain = 1' "$st" >"$st.x" && mv "$st.x" "$st" ) &
sleep 0.2
statuses="$(grep -c '^status ' "$T/live.out")"
live_send commit
wait $!
for _ in $(seq 300); do (( $(grep -c '^status ' "$T/live.out") > statuses )) && break; sleep 0.02; done
check "a commit the state moved under is stale" "1" "$(grep -c '^stale$' "$T/live.out")"
check "and is answered with the status all the same" "$((statuses + 1))" "$(grep -c '^status ' "$T/live.out")"
check "and the state keeps the other command's band, not the dropped edit" "1|0" \
  "$(run status | jq -r '"\(.bands[7].gain)|\(.bands[6].gain)"')"
# Another command changes the bands under an uncommitted edit: dropped, and the
# graph put back as the state now has it.
live_send "gain 2 6"; sleep 0.2
run set-gain 5 2 >/dev/null
: >"$PWCLI_LOG"
live_send "gain 3 1"
live_wait_for '^stale$'
check "an edit the state moved under is stale" "1" "$(grep -c '^stale$' "$T/live.out")"
live_wait_writes 2
check "and the graph is put back from the state" "1" "$(head -n1 "$PWCLI_LOG" | grep -c '"para:ft_15"')"
check "the band the other command set stays set" "2" "$(run status | jq -r '.bands[5].gain')"
# End of input with an edit not committed: the graph is put back.
: >"$PWCLI_LOG"
live_stop
check "the editor leaves at the end of its input" "0" "$live_rc"
check "and puts back what was not committed" "1" "$(tail -n1 "$PWCLI_LOG" | grep -c '"para:ft_15"')"
check "which the state never saw" "0" "$(run status | jq -r '.bands[3].gain')"
# Without the limiter nothing would catch the clip: the preamp follows each line.
run set-limiter off >/dev/null
live_start
: >"$PWCLI_LOG"
# A boost past the curve's peak deepens the cut at once; taking it back does
# not give the cut back during the drag (the commit does).
live_send "gain 1 12"; live_wait_writes 1
check "with the limiter off a boost deepens the cut at once" "1" "$(grep -c '"pre_l:Mult"' "$PWCLI_LOG")"
live_send "gain 1 0"; live_wait_writes 2
check "and taking it back keeps the cut until the commit" "1" "$(grep -c '"pre_l:Mult"' "$PWCLI_LOG")"
live_send commit; live_wait_for '^status '
check "and the commit files the preamp the backend computes" "true" "$(run status | jq '.preamp == .autoPreamp')"
live_stop
run set-limiter on >/dev/null
# The 10-band console's fit: one line, every band.
run set-mode graphic >/dev/null
live_start
: >"$PWCLI_LOG"
live_send "gains 1 2 3 4 5 6 7 8 9 10"; live_wait_writes 1
check "a fitted set is one write of ten slots" "10" "$(grep -o '"para:g_[0-9]*"' "$PWCLI_LOG" | wc -l | tr -d ' ')"
live_send commit; live_wait_for '^status '
check "and is filed as ten gains" "1,2,3,4,5,6,7,8,9,10" "$(run status | jq -r '[.bands[].gain | tostring] | join(",")')"
steps="$(jq '.undo | length' "$XDG_STATE_HOME/omarchy-equalizer/history.json")"
live_send "balance -0.5" commit
live_wait_for 'status .*"balance":-0.5'
check "a balance drag is filed too, and is not a curve step" "-0.5|$steps" \
  "$(run status | jq -r '.balance')|$(jq '.undo | length' "$XDG_STATE_HOME/omarchy-equalizer/history.json")"
live_stop
run set-balance 0 >/dev/null
# An A/B, or the equalizer off: nothing to stream into.
run compare on >/dev/null
live_start
check "an A/B in force makes the editor unavailable" "1" "$(grep -c '^unavailable ' "$T/live.out")"
live_stop
check "and it says so with exit 3" "3" "$live_rc"
run compare off >/dev/null
run disable >/dev/null
unset PACTL_DEVICE_SINK PACTL_DEFAULT_SINK

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

echo "== the real graph, measured (tests/dsp-check.sh) =="
# A private PipeWire runs the generated graph with the real plugins and the result
# is measured against Model.js. It needs the real pw-* tools, so it runs on a PATH
# without this suite's stubs (it brings its own systemctl and pactl stubs). A
# machine without PipeWire, like the CI runner, SKIPs it.
dsp_out="$(PATH="/usr/bin:/bin${node_bin:+:$(dirname "$node_bin")}" bash "$here/dsp-check.sh" 2>&1)"; rc=$?
if grep -q '^SKIP  dsp-check' <<<"$dsp_out"; then
  grep '^SKIP' <<<"$dsp_out"
else
  grep -E '^(FAIL|SKIP)|^dsp-check:' <<<"$dsp_out" | sed 's/^/      /'
  check "the real graph measures as Model.js draws it" "0" "$rc"
fi

echo "== offscreen QML tests (key fields, response curve, band row, panel) =="
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
