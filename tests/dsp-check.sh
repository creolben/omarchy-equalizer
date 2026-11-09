#!/bin/bash
# Real-audio checks for omarchy-equalizer: the graph the backend generates, run
# by a private PipeWire with the real plugins, measured against Model.js.
#
# Everything else in tests/ checks the backend against stubs and the model
# against a transcription of itself; nothing there would notice a plugin
# ignoring a control (LSP's slope is ignored in the mode the pool runs), a
# default that is not neutral (envb made the boost engage 17 dB early), or a
# limiter that distorts bass. This plays signals through the actual graph and
# records what comes out.
#
# Isolation: a private PipeWire daemon on its own runtime directory, with no
# devices and no session manager (the ports are configured and linked here, the
# way WirePlumber would on a real system). systemctl and pactl are the test
# stubs, so no unit, sink or stream of the real session is ever touched; the
# script refuses to run if the daemon it reaches shows any real device.
#
# Run: bash tests/dsp-check.sh        (about two minutes; SKIPs without PipeWire)
#      OMARCHY_EQ_DSP=0 skips it inside tests/run-tests.sh.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
E="$here/../bin/omarchy-equalizer"
J="$here/dsp-check.js"

if [[ ${OMARCHY_EQ_DSP:-1} == 0 ]]; then echo "SKIP  dsp-check (OMARCHY_EQ_DSP=0)"; exit 0; fi
for tool in pipewire pw-cat pw-record pw-link pw-cli pw-dump pw-metadata node jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP  dsp-check ($tool is not installed)"; exit 0; }
done
lv2_root="${OMARCHY_EQ_DSP_LV2:-/usr/lib/lv2}"
have_lsp=true
for p in para_equalizer_x16_stereo mb_compressor_stereo limiter_stereo autogain_stereo; do
  [[ -f $lv2_root/lsp-plugins.lv2/$p.ttl ]] || have_lsp=false
done

T="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-eq-dsp.XXXXXX")"
export XDG_RUNTIME_DIR="$T/run" PIPEWIRE_RUNTIME_DIR="$T/run"
export XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state"
unset PIPEWIRE_REMOTE PULSE_SERVER DBUS_SESSION_BUS_ADDRESS PIPEWIRE_CONFIG_DIR
mkdir -p "$XDG_RUNTIME_DIR" "$T/bin" "$T/sig"
chmod 700 "$XDG_RUNTIME_DIR"
# Only the stubs for the parts of the system that must never be reached.
for stub in systemctl pactl curl omarchy-audio-output-sink; do ln -s "$here/bin/$stub" "$T/bin/$stub"; done
export PATH="$T/bin:$PATH"
export SYSTEMCTL_LOG="$T/systemctl.log" CURL_LOG="$T/curl.log"
export OMARCHY_EQ_NO_RAMP=1 OMARCHY_EQ_VANISH_GRACE=0 OMARCHY_EQ_LV2_DIR="$lv2_root"
export PACTL_DEFAULT_SINK=harness.out PACTL_DEVICE_SINK=harness.out
unset PACTL_APP_STREAM PACTL_APP_STREAMS PACTL_EQ_AIM PACTL_EQ_AIM_SINK_ID PACTL_DEVICE_SINK2 PACTL_LOG \
  PACTL_SINK_VOLUME_DB PACTL_NO_EQ_SINK PACTL_SUBSCRIBE_COUNT PACTL_EQ_STATE PACTL_EQ_RATE SYSTEMCTL_RESTART_FAILS

daemon_pid="" host_pid=""
cleanup() {
  [[ -n $host_pid ]] && kill "$host_pid" 2>/dev/null
  [[ -n $daemon_pid ]] && kill "$daemon_pid" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

cat >"$T/daemon.conf" <<'EOF'
context.properties = {
    core.daemon = true
    core.name = pipewire-0
    log.level = 2
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum = 1024
    default.clock.min-quantum = 1024
    default.clock.max-quantum = 1024
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-access args = { } }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
]
context.objects = [
    { factory = spa-node-factory
        args = { factory.name = support.node.driver node.name = Dummy-Driver priority.driver = 200000 } }
]
EOF

pipewire -c "$T/daemon.conf" >"$T/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 50); do [[ -S $XDG_RUNTIME_DIR/pipewire-0 ]] && break; sleep 0.1; done
nodes="$(timeout 5 pw-dump 2>/dev/null | jq -r '.[] | select(.type == "PipeWire:Interface:Node") | .info.props["node.name"]')"
if [[ $nodes != Dummy-Driver ]]; then
  echo "FAIL  dsp-check: the private PipeWire daemon is not the only one reached (saw: ${nodes//$'\n'/, }); refusing to run"
  exit 1
fi

pass=0 fail=0
ok()  { printf 'PASS  %s -- %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s -- %s\n' "$1" "$2"; fail=$((fail + 1)); }
# Run a dsp-check.js measurement and count it.
measure_check() { # name args...
  local name="$1" out rc
  shift
  out="$(node "$J" "$@" 2>&1)"; rc=$?
  out="${out#ok   }"; out="${out#FAIL }"
  if ((rc == 0)); then ok "$name" "$out"; else bad "$name" "$out"; fi
}
check() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1" "$3"; else bad "$1" "expected [$2] got [$3]"; fi
}
holds() { # name awk-condition-on-x measured
  if LC_ALL=C awk -v x="$3" "BEGIN { exit !($2) }"; then ok "$1" "$3"; else bad "$1" "$3 fails $2"; fi
}
eq() { "$E" "$@" 2>>"$T/backend.log"; }
node_id() {
  timeout 5 pw-dump 2>/dev/null | jq -r --arg n "$1" '.[] | select(.type == "PipeWire:Interface:Node")
    | select(.info.props["node.name"] == $n) | .id' | head -n1
}
port_config() { # node-id direction
  timeout 5 pw-cli set-param "$1" PortConfig "{ \"direction\": \"$2\", \"mode\": \"dsp\", \"format\": { \"mediaType\": \"audio\", \"mediaSubtype\": \"raw\", \"format\": \"F32P\", \"rate\": 48000, \"channels\": 2, \"position\": [ \"FL\", \"FR\" ] } }" >/dev/null
}

# The equalizer's host, as the systemd unit would run it, with its two stream
# nodes given ports the way WirePlumber gives them.
host_start() {
  local a="" b=""
  pipewire -c omarchy-equalizer.conf >>"$T/host.log" 2>&1 &
  host_pid=$!
  for _ in $(seq 60); do
    a="$(node_id omarchy_equalizer)"; b="$(node_id omarchy_equalizer.output)"
    [[ -n $a && -n $b ]] && break
    sleep 0.1
  done
  [[ -n $a && -n $b ]] || { echo "FAIL  dsp-check: the equalizer graph did not load"; tail -n 20 "$T/host.log"; exit 1; }
  port_config "$a" Input
  port_config "$b" Output
  eq_node="$a"
}
host_stop() {
  [[ -n $host_pid ]] || return 0
  kill "$host_pid" 2>/dev/null; wait "$host_pid" 2>/dev/null; host_pid=""
  for _ in $(seq 30); do [[ -z $(node_id omarchy_equalizer) ]] && break; sleep 0.1; done
}

# Play $1 through the equalizer and record its output into $2.
play() {
  local rec_pid play_pid id
  pw-record --rate 48000 --channels 2 --format f32 -P '{ node.name = harness-rec }' "$2" 2>>"$T/play.log" &
  rec_pid=$!
  for _ in $(seq 50); do id="$(node_id harness-rec)"; [[ -n $id ]] && break; sleep 0.05; done
  port_config "$id" Input; sleep 0.1
  timeout 5 pw-link omarchy_equalizer.output:output_FL harness-rec:input_FL >/dev/null 2>&1
  timeout 5 pw-link omarchy_equalizer.output:output_FR harness-rec:input_FR >/dev/null 2>&1
  pw-cat --playback --rate 48000 --channels 2 --format f32 -P '{ node.name = harness-play }' "$1" 2>>"$T/play.log" &
  play_pid=$!
  for _ in $(seq 50); do id="$(node_id harness-play)"; [[ -n $id ]] && break; sleep 0.05; done
  port_config "$id" Output; sleep 0.1
  timeout 5 pw-link harness-play:output_FL omarchy_equalizer:playback_FL >/dev/null 2>&1
  timeout 5 pw-link harness-play:output_FR omarchy_equalizer:playback_FR >/dev/null 2>&1
  timeout 30 tail --pid="$play_pid" -f /dev/null
  sleep 0.4
  kill -INT "$rec_pid" 2>/dev/null; wait "$rec_pid" 2>/dev/null
}

# The graph's latency, measured: one four-channel recording holds the
# equalizer's output (FL/FR) and the signal that went into it (RL/RR), so both
# impulses are on one clock and the lag between them is the graph's own.
latency_samples() {
  local rec_pid play_pid id out="$T/sig/latency.wav"
  pw-record --rate 48000 --channels 4 --format f32 -P '{ node.name = harness-lat }' "$out" 2>>"$T/play.log" &
  rec_pid=$!
  for _ in $(seq 50); do id="$(node_id harness-lat)"; [[ -n $id ]] && break; sleep 0.05; done
  timeout 5 pw-cli set-param "$id" PortConfig '{ "direction": "Input", "mode": "dsp", "format": { "mediaType": "audio", "mediaSubtype": "raw", "format": "F32P", "rate": 48000, "channels": 4, "position": [ "FL", "FR", "RL", "RR" ] } }' >/dev/null
  sleep 0.1
  timeout 5 pw-link omarchy_equalizer.output:output_FL harness-lat:input_FL >/dev/null 2>&1
  timeout 5 pw-link omarchy_equalizer.output:output_FR harness-lat:input_FR >/dev/null 2>&1
  pw-cat --playback --rate 48000 --channels 2 --format f32 -P '{ node.name = harness-play }' "$T/sig/impulse.wav" 2>>"$T/play.log" &
  play_pid=$!
  for _ in $(seq 50); do id="$(node_id harness-play)"; [[ -n $id ]] && break; sleep 0.05; done
  port_config "$id" Output; sleep 0.1
  timeout 5 pw-link harness-play:output_FL harness-lat:input_RL >/dev/null 2>&1
  timeout 5 pw-link harness-play:output_FR harness-lat:input_RR >/dev/null 2>&1
  timeout 5 pw-link harness-play:output_FL omarchy_equalizer:playback_FL >/dev/null 2>&1
  timeout 5 pw-link harness-play:output_FR omarchy_equalizer:playback_FR >/dev/null 2>&1
  timeout 30 tail --pid="$play_pid" -f /dev/null
  sleep 0.4
  kill -INT "$rec_pid" 2>/dev/null; wait "$rec_pid" 2>/dev/null
  node "$J" lag "$out"
}

# Put a band set in the state and have the backend write it into the running
# graph -- the real live path, pw-cli included.
set_bands() { # mode bands-json
  local st="$XDG_STATE_HOME/omarchy-equalizer/state.json"
  jq -c --arg m "$1" --argjson b "$2" '.mode = $m | .[$m] = $b | .headroom = "auto" | del(.listen)' "$st" >"$st.x" &&
    mv "$st.x" "$st"
  eq set-mode "$1" >/dev/null
}
status() { eq status; }
bands_file() { status | jq -c '.bands' >"$T/sig/bands.json"; printf '%s' "$T/sig/bands.json"; }
applied() { status | jq -r '.appliedPreamp'; }

node "$J" gen impulse "$T/sig/impulse.wav"
node "$J" gen sine "$T/sig/l-only.wav" 1000 0.5 0
node "$J" gen sine "$T/sig/hot-50.wav" 50 0.32 0.32 1.0
node "$J" gen sine "$T/sig/hot-l.wav" 1000 0.5 0.1
node "$J" gen sine "$T/sig/quiet.wav" 1000 0.01 0.01
node "$J" gen sine "$T/sig/loud.wav" 1000 0.3162 0.3162
node "$J" gen sine "$T/sig/lev-quiet.wav" 1000 0.01 0.01 8
node "$J" gen sine "$T/sig/lev-loud.wav" 1000 0.7 0.7 4
rec="$T/sig/rec.wav"

eq enable >/dev/null || { echo "FAIL  dsp-check: enable failed"; cat "$T/backend.log"; exit 1; }

if $have_lsp; then
  echo "== the LSP pool, measured =="
  host_start
  check "the graph runs the v3 layout" "pool" "$(sed -n 's/^# Layout: v3 //p' "$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf")"
  eq set-limiter off >/dev/null
  set_bands graphic "$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] | map({ type: "peaking", freq: ., q: 1.41, gain: 0 })')"
  play "$T/sig/impulse.wav" "$rec"
  measure_check "null test: Flat with the stage off is transparent" flat "$rec" 0 0.02

  for spec in 'peaking 1000 1.41 6' 'peaking 60 0.8 -9' 'lowshelf 120 0.71 7' 'highshelf 6000 0.71 -5' \
              'lowpass 7000 0.9 0' 'highpass 90 0.707 0' 'bandpass 1500 1.2 0' 'notch 2500 3 0' 'allpass 800 0.7 0'; do
    set -- $spec
    set_bands parametric "[{\"type\":\"$1\",\"freq\":$2,\"q\":$3,\"gain\":$4}]"
    play "$T/sig/impulse.wav" "$rec"
    measure_check "$1 at $2 Hz matches Model.js" response "$rec" "$(bands_file)" "$(applied)" 0.1
  done

  for spec in 'highpass 80 0.7071 2' 'highpass 55 0.7071 4' 'lowpass 9000 0.7071 3' 'highpass 120 1.1 2'; do
    set -- $spec
    set_bands parametric "[{\"type\":\"$1\",\"freq\":$2,\"q\":$3,\"gain\":0,\"slope\":$4},{\"type\":\"peaking\",\"freq\":2000,\"q\":1,\"gain\":3}]"
    play "$T/sig/impulse.wav" "$rec"
    measure_check "a $1 at slope $4 is the cascade Model.js draws" response "$rec" "$(bands_file)" "$(applied)" 0.1
  done

  set_bands parametric '[{"type":"peaking","freq":1000,"q":1,"gain":8,"enabled":false},{"type":"peaking","freq":3000,"q":1.4,"gain":-4}]'
  play "$T/sig/impulse.wav" "$rec"
  printf '[{"type":"peaking","freq":3000,"q":1.4,"gain":-4}]' >"$T/sig/bypassed.json"
  measure_check "a bypassed band shapes nothing" response "$rec" "$T/sig/bypassed.json" 0 0.1

  eq apply-preset Rock >/dev/null
  play "$T/sig/impulse.wav" "$rec"
  measure_check "Rock plays as drawn, under its own preamp" response "$rec" "$(bands_file)" "$(applied)" 0.1
  eq compare on >/dev/null
  play "$T/sig/impulse.wav" "$rec"
  measure_check "the A/B plays Flat at the curve's loudness" flat "$rec" "$(status | jq -r '.listen.preamp')" 0.03
  eq compare off >/dev/null
  eq solo 4 >/dev/null
  play "$T/sig/impulse.wav" "$rec"
  status | jq -c '[.bands[4]]' >"$T/sig/solo.json"
  measure_check "solo plays one band alone" response "$rec" "$T/sig/solo.json" "$(status | jq -r '.listen.preamp')" 0.1
  eq solo off >/dev/null

  echo "== volume and relief =="
  set_bands graphic "$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] | map({ type: "peaking", freq: ., q: 1.41, gain: (if . == 1000 then 6 else 0 end) })')"
  timeout 5 pw-cli set-param "$eq_node" Props '{ channelVolumes = [ 0.25, 0.25 ] }' >/dev/null
  PACTL_SINK_VOLUME_DB=-12.04 eq retarget >/dev/null
  check "at -12 dB the cut is given back" "0" "$(applied)"
  play "$T/sig/impulse.wav" "$rec"
  measure_check "the boost plays as a boost, under the in-graph volume" response "$rec" "$(bands_file)" "$(LC_ALL=C awk -v a="$(applied)" 'BEGIN { printf "%.4f", a + 20 * log(0.25) / log(10) }')" 0.1
  timeout 5 pw-cli set-param "$eq_node" Props '{ channelVolumes = [ 1.0, 1.0 ] }' >/dev/null
  PACTL_SINK_VOLUME_DB=0 eq retarget >/dev/null
  check "at full volume the whole cut stands" "-6" "$(applied)"

  echo "== channels =="
  set_bands graphic "$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] | map({ type: "peaking", freq: ., q: 1.41, gain: 0 })')"
  eq set-channels swap >/dev/null
  play "$T/sig/l-only.wav" "$rec"
  check "swap: a left-only tone comes out on the right" "0.0000 0.5000" "$(node "$J" level "$rec")"
  eq set-channels mono >/dev/null
  play "$T/sig/l-only.wav" "$rec"
  check "mono: both sides hear half of it" "0.2500 0.2500" "$(node "$J" level "$rec")"
  eq set-channels stereo >/dev/null
  eq set-balance -0.5 >/dev/null
  node "$J" gen sine "$T/sig/both.wav" 1000 0.5 0.5
  play "$T/sig/both.wav" "$rec"
  check "a balance to the left halves the right only" "0.5000 0.2500" "$(node "$J" level "$rec")"
  eq set-balance 0 >/dev/null

  echo "== the limiter =="
  # The volume raised faster than the follower: a +12 dB band with all of its
  # cut given back (the relief of a -20 dB volume) while the in-graph volume is
  # already at full. That is the case the limiter is there for.
  eq set-limiter on >/dev/null
  set_bands graphic "$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] | map({ type: "peaking", freq: ., q: 1.41, gain: (if . == 1000 then 12 else 0 end) })')"
  PACTL_SINK_VOLUME_DB=-20 eq retarget >/dev/null
  check "the whole cut is given back" "0" "$(applied)"
  play "$T/sig/hot-l.wav" "$rec"
  read -r l r <<<"$(node "$J" level "$rec")"
  holds "a hot left channel is held at the -1 dBFS ceiling" "x >= 0.85 && x <= 0.895" "$l"
  holds "and the quiet right comes down with it (linked: right/left)" "x > 0.19 && x < 0.21" \
    "$(LC_ALL=C awk -v l="$l" -v r="$r" 'BEGIN { printf "%.3f", r / l }')"
  # 50 Hz driven 3 dB over the ceiling: the case where a short lookahead moved
  # the gain inside every bass cycle (9.7 % THD with the old 5 ms).
  set_bands parametric '[{"type":"peaking","freq":50,"q":1.41,"gain":12}]'
  PACTL_SINK_VOLUME_DB=-20 eq retarget >/dev/null
  play "$T/sig/hot-50.wav" "$rec"
  holds "50 Hz limited 3 dB comes out at the ceiling" "x >= 0.85 && x <= 0.895" "$(node "$J" level "$rec" | cut -d' ' -f1)"
  holds "and stays under 2 % THD" "x < 2" "$(node "$J" thd "$rec" 50)"
  # A filter-chain hands its output on one quantum later (1024 samples here);
  # the rest is the plugins -- the limiter's 20 ms lookahead, mostly. Players
  # are told the latency, so it costs no lip-sync, but it should not grow.
  holds "the plugins add under 25 ms on top of the quantum (samples)" "x >= 0 && x < 1200" "$(( $(latency_samples) - 1024 ))"

  PACTL_SINK_VOLUME_DB=0 eq retarget >/dev/null

  echo "== dynamics =="
  eq set-limiter off >/dev/null
  set_bands graphic "$(jq -cn '[31,62,125,250,500,1000,2000,4000,8000,16000] | map({ type: "peaking", freq: ., q: 1.41, gain: 0 })')"
  for mode in off night voice; do
    eq set-boost "$mode" >/dev/null
    play "$T/sig/quiet.wav" "$rec"; q="$(node "$J" level "$rec" | cut -d' ' -f1)"
    play "$T/sig/loud.wav" "$rec"; l="$(node "$J" level "$rec" | cut -d' ' -f1)"
    span="$(LC_ALL=C awk -v q="$q" -v l="$l" 'BEGIN { printf "%.1f", 20 * log(l / q) / log(10) }')"
    case "$mode" in
      off) check "boost off: a 30 dB step stays 30 dB" "30.0" "$span" ;;
      *) holds "boost $mode: a 30 dB step is squeezed under 18 dB" "x < 18" "$span" ;;
    esac
  done
  eq set-boost off >/dev/null

  echo "== the leveler =="
  eq set-leveler on >/dev/null
  play "$T/sig/lev-quiet.wav" "$rec"
  read -r first last <<<"$(node "$J" trend "$rec")"
  holds "a quiet source is lifted toward the target (dB over 8 s)" "x >= 4" \
    "$(LC_ALL=C awk -v a="$first" -v b="$last" 'BEGIN { printf "%.1f", b - a }')"
  play "$T/sig/lev-loud.wav" "$rec"
  read -r first last <<<"$(node "$J" trend "$rec")"
  holds "a loud source is brought down from -3 dBFS (to dBFS)" "x <= -6" "$last"
  eq set-leveler off >/dev/null
  host_stop
else
  echo "SKIP  the LSP pool (lsp-plugins-lv2 is not installed)"
fi

echo "== the builtin biquad chain (no LSP) =="
mkdir -p "$T/no-lsp"
export OMARCHY_EQ_LV2_DIR="$T/no-lsp"
eq apply-preset Rock >/dev/null
host_stop
host_start
check "without LSP the graph is the biquad chain" "1" "$(grep -c '^# Layout: v3 biquad:' "$XDG_CONFIG_HOME/pipewire/omarchy-equalizer.conf.d/90-eq.conf")"
play "$T/sig/impulse.wav" "$rec"
measure_check "Rock on biquads plays as drawn" response "$rec" "$(bands_file)" "$(applied)" 0.1
set_bands parametric '[{"type":"highpass","freq":70,"q":0.7071,"gain":0,"slope":2},{"type":"lowshelf","freq":150,"q":0.71,"gain":4},{"type":"peaking","freq":3000,"q":2,"gain":-3}]'
host_stop
host_start
play "$T/sig/impulse.wav" "$rec"
measure_check "a sloped parametric set on biquads plays as drawn" response "$rec" "$(bands_file)" "$(applied)" 0.1
holds "the builtin chain adds nothing on top of the quantum (samples)" "x >= 0 && x < 48" "$(( $(latency_samples) - 1024 ))"
eq set-channels swap >/dev/null
play "$T/sig/l-only.wav" "$rec"
read -r l r <<<"$(node "$J" level "$rec")"
holds "swap works on the biquad chain too (left out, right in)" "x == 1" "$(LC_ALL=C awk -v l="$l" -v r="$r" 'BEGIN { print (l < 0.0001 && r > 0.1) ? 1 : 0 }')"
host_stop

printf '\ndsp-check: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
