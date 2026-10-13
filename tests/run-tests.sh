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
check "remove-band rejects a non-number" "1|Band index must be a number." "$rc|$out"

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
run set-mode parametric >/dev/null
: >"$SYSTEMCTL_LOG"
run set-band 3 type lowshelf >/dev/null
check "a type change restarts the unit" "yes" "$(grep -c restart "$SYSTEMCTL_LOG" | sed 's/^0$/no/;s/^[1-9].*/yes/')"
: >"$SYSTEMCTL_LOG"
run set-band 3 freq 300 >/dev/null
check "a frequency change does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
run set-band 3 q 2.5 >/dev/null
check "a Q change does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
run set-gain 3 -4.5 >/dev/null
check "a gain change does not restart the unit" "0" "$(grep -c restart "$SYSTEMCTL_LOG")"
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

echo "== preset list =="
check "every preset file is listed" \
  "$(ls "$here/../presets"/*.json | wc -l)" "$(run status | jq '[.presets[] | select(.builtin)] | length')"
check "the list is in the order the files declare" "Flat,Bass Boost,Treble Boost" \
  "$(run status | jq -r '[.presets[] | select(.builtin) | .name] | .[0:3] | join(",")')"
check "the list carries a description for the selected preset" "yes" \
  "$(run status | jq -r '[.presets[] | select(.name == "Rock")][0].description | if . == null then "no" else "yes" end')"
check "a built-in is marked as one" "true" \
  "$(run status | jq -r '[.presets[] | select(.name == "Rock")][0].builtin')"

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

echo "== preset ramp =="
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
: >"$SYSTEMCTL_LOG"
run add-band >/dev/null
check "a band-count change restarts the unit" "yes" \
  "$(grep -c restart "$SYSTEMCTL_LOG" | sed 's/^0$/no/;s/^[1-9].*/yes/')"

echo "== output stage defaults =="
check "the limiter defaults on" "on" "$(run status | jq -r '.limiter')"
check "the boost defaults off" "off" "$(run status | jq -r '.boost')"
check "the output stage is active" "true" "$(run status | jq -r '.outputStage')"

echo "== output stage in the fragment =="
# The graphic set is a fixed 10 bands, so "the last band" is g9.
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
check "the last band feeds the compressor" "1" \
  "$(grep -c 'g9:Out" input = "boost:in"' "$frag")"
check "the compressor feeds the limiter" "1" \
  "$(grep -c 'boost:out" input = "limit:in"' "$frag")"
check "the limiter is the graph output" "0" "$(grep -c 'limit:out' "$frag")"
# With no bands the preamp is the whole head of the chain and feeds the stage.
run set-mode parametric >/dev/null
while [[ $(run status | jq -r '.bands | length') -gt 0 ]]; do run remove-band 0 >/dev/null; done
check "with no bands the preamp feeds the compressor" "1" \
  "$(grep -c 'pre:Out" input = "boost:in"' "$frag")"
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

echo "== output stage survives a rebuild =="
run set-mode parametric >/dev/null
: >"$SYSTEMCTL_LOG"
run add-band >/dev/null
check "a band-count change still restarts with the stage" "yes" \
  "$(grep -c restart "$SYSTEMCTL_LOG" | sed 's/^0$/no/;s/^[1-9].*/yes/')"
check "the regenerated fragment keeps the compressor" "1" "$(grep -c 'lv2/mb_compressor_mono' "$frag")"
check "the regenerated fragment keeps the limiter" "1" "$(grep -c 'limiter_mono' "$frag")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
