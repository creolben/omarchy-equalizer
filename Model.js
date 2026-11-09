// Parsing and formatting helpers for the equalizer panel. Kept out of the QML so
// the shapes the backend emits are described in exactly one place.

// The backend prints one JSON document; anything else on stdout is noise from a
// failing helper (pw-cli prints its errors to stdout, not stderr).
function parseStatus(text) {
  var raw = String(text || "").trim();
  if (raw === "") return null;
  var start = raw.indexOf("{");
  var end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(raw.slice(start, end + 1));
  } catch (e) {
    return null;
  }
}

// The AutoEq profile index command prints a JSON array; anything else on stdout
// is a failure message from a helper, so a non-array means "no results".
function parseJsonArray(text) {
  var raw = String(text || "").trim();
  var start = raw.indexOf("[");
  var end = raw.lastIndexOf("]");
  if (start < 0 || end <= start) return [];
  try {
    var parsed = JSON.parse(raw.slice(start, end + 1));
    return parsed instanceof Array ? parsed : [];
  } catch (e) {
    return [];
  }
}

function clamp(v, lo, hi) {
  var n = Number(v);
  if (!isFinite(n)) return lo;
  return Math.max(lo, Math.min(hi, n));
}

// The meter. Pure numbers so they can be tested without Qt; LevelWave.qml only
// eases and draws what these return.

// One line from bin/omarchy-equalizer-spectrum: "BEAT V1 .. Vn", all integers
// 0..100. Returns { beat: 0..1, bands: [0..1, ...] }, or null for a line that
// is not a frame (blank, too short, or not numbers), so a stray message on the
// helper's stdout can never reach the bars.
function parseSpectrumLine(line) {
  var parts = String(line === undefined || line === null ? "" : line).trim().split(/\s+/)
  if (parts.length < 3) return null
  var nums = []
  for (var i = 0; i < parts.length; i++) {
    if (!/^\d+$/.test(parts[i])) return null
    nums.push(clamp(Number(parts[i]), 0, 100) / 100)
  }
  return { beat: nums[0], bands: nums.slice(1) }
}

// The meter's motion, taken from the "sound wave" Lottie animation: 34 pill
// bars, evenly spaced, that all play one 25-key height sequence (a key every 5
// frames at 20 fps). Each bar has its own fixed height scale and its own start
// offset, which is what makes the row look irregular rather than a travelling
// sine. Keys are interpolated linearly, as in the source (its bezier handles
// sit on the diagonal). The source holds its last key and jumps at its 90-frame
// loop; here the sequence wraps from the last key back to the first over one
// more key, so the loop is seamless.
var LOTTIE_SEQ = [100, 237, 264.333, 247.667, 197, 29, 26, 158.5, 217, 250, 125,
                  163.5, 100, 37, 52, 92, 50, 154, 115, 157, 98, 168, 39, 73, 27]
var LOTTIE_SCALE = [76, 18, 55, 37, 28, 18, 27, 47, 76, 30, 57, 57, 18, 46, 32, 45, 75,
                    100, 44, 45, 55, 78, 37, 28, 18, 27, 47, 76, 30, 57, 57, 18, 46, 32]
var LOTTIE_START = [-32, -32, -23, -19, -21, -35, -30, -46, -32, -40, -29, -23, -32, -14,
                    -9, -13, -5, 0, -3, -6, -23, -5, -19, -21, -35, -30, -46, -32, -40,
                    -29, -23, -32, -14, -9]
var LOTTIE_BARS = 34
var LOTTIE_FPS = 20
var LOTTIE_PERIOD = 125              // 25 keys x 5 frames, wrapping
var LOTTIE_MAX = 264.333
// Bar width as a share of the bar pitch: 6 px bars on a 14.735 px pitch.
var LOTTIE_FILL = 6 / 14.735

// Heights 0..1 for every bar at animation frame `frame` (any real number).
function lottieBars(frame) {
  var f = Number(frame) || 0
  var out = []
  for (var i = 0; i < LOTTIE_BARS; i++) {
    var local = (f - LOTTIE_START[i]) % LOTTIE_PERIOD
    if (local < 0) local += LOTTIE_PERIOD
    var pos = local / 5
    var k = Math.floor(pos), t = pos - k
    var a = LOTTIE_SEQ[k % LOTTIE_SEQ.length]
    var b = LOTTIE_SEQ[(k + 1) % LOTTIE_SEQ.length]
    out.push((a + (b - a) * t) / LOTTIE_MAX * LOTTIE_SCALE[i] / 100)
  }
  return out
}

// One step of a damped spring pulling `x` toward `target`, for the bars'
// motion: a hit pops with a small overshoot and settles instead of snapping.
// `freq` is the natural frequency in Hz, `zeta` the damping ratio (1 = no
// overshoot). Sub-stepped, so a long frame stays stable. Returns [x, v].
function springStep(x, v, target, dt, freq, zeta) {
  var w = 2 * Math.PI * freq
  var steps = Math.max(1, Math.ceil(dt / 0.004))
  var h = dt / steps
  for (var s = 0; s < steps; s++) {
    v += (w * w * (target - x) - 2 * zeta * w * v) * h
    x += v * h
  }
  return [x, v]
}

// Energy for bar `i` of `count`, from a spectrum laid out bass-first: the row is
// mirrored, so the centre bars follow the bass and the outer bars the treble.
// Returns 0..1, or 0.5 (neutral) when there is no spectrum.
function barEnergy(bands, i, count) {
  var b = bands || []
  if (b.length === 0 || count < 1) return 0.5
  var d = count > 1 ? Math.abs((i / (count - 1)) * 2 - 1) : 0
  var pos = d * (b.length - 1)
  var k = Math.min(b.length - 1, Math.floor(pos)), f = pos - k
  var a0 = clamp(Number(b[k]) || 0, 0, 1)
  var a1 = clamp(Number(b[Math.min(b.length - 1, k + 1)]) || 0, 0, 1)
  return a0 + (a1 - a0) * f
}

// Fallback beat follower, on the peak monitor alone (the spectrum helper does
// its own, better detection). An onset is a peak that rises clearly above its
// own slow average *since the previous call*, judged on the rise rather than
// the level, so a loud, steady track still has beats. Call once per peak
// update; returns [avg, onset] with onset 0 or 1. It does not decay anything:
// the caller owns the visible pulse and passes it in as `pulse`, and a new
// onset is refused while that pulse is still above half strength.
function beatStep(avg, peak, pulse) {
  var p = clamp(Number(peak) || 0, 0, 1)
  var a = clamp(Number(avg) || 0, 0, 1)
  var b = clamp(Number(pulse) || 0, 0, 1)
  var onset = p > 0.05 && p - a > Math.max(0.04, a * 0.15) && b < 0.5
  // An onset resets the average to the new level, so a plateau after a hit is
  // not read as a string of further hits.
  if (onset) a = p
  else a += (p - a) * (p > a ? 0.15 : 0.05)
  return [a, onset ? 1 : 0]
}

// Which control, if any, a wheel event belongs to. One implementation, so the
// sliders cannot drift from each other or from tests/input-policy-check.js.
//
// A horizontal control under a vertical wheel is never a deliberate edit, so
// "preamp" always declines. A vertical fader may take the wheel only when the
// user has aimed at it (active focus, set by a click) or declared intent (Alt
// held). The optional delta lets callers pass the vertical amount through, so
// a zero-delta wheel is nobody's edit; omitting it keeps the three-argument
// rule the sliders and the node tests use.
var ALT_MODIFIER = 0x08000000
function wheelOwns(kind, modifiers, hasFocus, angleDeltaY) {
  if (kind !== "fader") return false
  if (angleDeltaY !== undefined && Number(angleDeltaY) === 0) return false
  if (hasFocus === true) return true
  return ((Number(modifiers) || 0) & ALT_MODIFIER) !== 0
}

// The vertical amount of a wheel event. Some platforms turn Alt+wheel into a
// horizontal scroll, which would leave angleDelta.y at 0 exactly when Alt is
// held to arm a fader; with Alt down the horizontal amount stands in for it.
function wheelDelta(angleDeltaX, angleDeltaY, modifiers) {
  var dy = Number(angleDeltaY) || 0
  if (dy !== 0) return dy
  if (((Number(modifiers) || 0) & ALT_MODIFIER) === 0) return 0
  return Number(angleDeltaX) || 0
}

// Frequencies read better abbreviated once they pass 1000 Hz.
function formatFreq(hz) {
  var n = Number(hz);
  if (!isFinite(n)) return "?";
  if (n >= 1000) {
    var khz = n / 1000;
    var text = (khz % 1 === 0) ? String(khz) : khz.toFixed(1);
    return text + "k";
  }
  return String(Math.round(n));
}

function formatGain(db) {
  var n = Number(db);
  if (!isFinite(n)) return "0.0";
  return (n > 0 ? "+" : "") + n.toFixed(1);
}

// The steepest pass filter: four cascaded stages, 48 dB/octave.
var MAX_SLOPE = 4;

// The type names the backend understands, paired with what to show.
var bandTypes = [
  { value: "peaking", label: "Peaking" },
  { value: "lowshelf", label: "Low shelf" },
  { value: "highshelf", label: "High shelf" },
  { value: "lowpass", label: "Low pass" },
  { value: "highpass", label: "High pass" },
  { value: "bandpass", label: "Band pass" },
  { value: "notch", label: "Notch" },
  { value: "allpass", label: "All pass" }
];

// A filter without a gain control says so on the face, rather than showing a
// slider that moves nothing, when a parameter does not apply to the chosen
// type.
function typeHasGain(type) {
  var t = String(type || "peaking");
  return t !== "lowpass" && t !== "highpass" && t !== "bandpass"
    && t !== "notch" && t !== "allpass";
}

// The band row's type picker: every type once, and the two pass filters once per
// slope, so a steeper corner is one pick rather than a second control. The value
// is "type" or "type:slope".
var bandTypeOptions = (function () {
  var out = []
  for (var i = 0; i < bandTypes.length; i++) {
    var t = bandTypes[i]
    if (typeHasSlope(t.value)) {
      for (var n = 1; n <= MAX_SLOPE; n++)
        out.push({ value: n === 1 ? t.value : t.value + ":" + n, label: t.label + " " + (12 * n) })
    } else {
      out.push(t)
    }
  }
  return out
})();

function typeOptionValue(type, slope) {
  var t = String(type || "peaking")
  var n = typeHasSlope(t) ? Math.max(1, Math.min(MAX_SLOPE, Math.round(Number(slope) || 1))) : 1
  return n === 1 ? t : t + ":" + n
}

function parseTypeOption(value) {
  var parts = String(value || "peaking").split(":")
  var n = parts.length > 1 ? Math.round(Number(parts[1]) || 1) : 1
  return { type: parts[0], slope: typeHasSlope(parts[0]) ? Math.max(1, Math.min(MAX_SLOPE, n)) : 1 }
}

// The balance as it reads on a mixer: centre, or how far toward one side.
function formatBalance(b) {
  var n = Math.round((Number(b) || 0) * 100)
  if (n === 0) return "C"
  return (n < 0 ? "L " : "R ") + Math.abs(n)
}

function typeLabel(type) {
  for (var i = 0; i < bandTypes.length; i++)
    if (bandTypes[i].value === String(type)) return bandTypes[i].label;
  return "Peaking";
}

// Only the two pass filters take a slope: a cascade of shelves or bells would
// just double their gain, which is a different curve, not a steeper one.
function typeHasSlope(type) {
  var t = String(type || "peaking");
  return t === "lowpass" || t === "highpass";
}

// A band switched off stays in the list (and keeps its slots) but shapes nothing.
function bandEnabled(b) {
  return !!b && b.enabled !== false;
}

// The slope a band is run at: 1..4, i.e. 12..48 dB/octave for a pass filter, and
// always 1 for every other type (MAX_SLOPE is defined with the type list).
function bandSlope(b) {
  if (!b || !typeHasSlope(b.type)) return 1;
  var n = Math.round(Number(b.slope) || 1);
  return Math.max(1, Math.min(MAX_SLOPE, n));
}

// The filter slots a band occupies in the 16-slot pool. A bypassed band keeps
// its slots, so switching it back on can never run out of room.
function bandSlots(b) { return b ? bandSlope(b) : 0; }
function slotCount(bands) {
  var n = 0;
  for (var i = 0; i < (bands || []).length; i++) n += bandSlots(bands[i]);
  return n;
}

// A band as the graph runs it: nothing while bypassed, and a pass filter with a
// slope of N as N cascaded biquads with Butterworth Qs, scaled by the band's own
// Q so the default 0.707 is a true Butterworth of order 2N and a higher Q still
// adds the same resonance at the corner. LSP's own slope control is not used:
// in the APO (DR) mode the pool runs it is ignored (measured -- x2 and x4
// respond exactly like x1), so the stages are separate slots instead.
// tests/run-tests.sh holds the backend's jq copy of this to the same numbers.
function bandStages(b) {
  if (!bandEnabled(b)) return [];
  var n = bandSlope(b);
  if (n <= 1) return [b];
  var scale = (Number(b.q) || Math.SQRT1_2) / Math.SQRT1_2;
  var out = [];
  for (var k = 1; k <= n; k++)
    out.push({ type: b.type, freq: b.freq, gain: 0,
               q: scale / (2 * Math.cos((2 * k - 1) * Math.PI / (4 * n))) });
  return out;
}

function expandBands(bands) {
  var out = [], list = bands || [];
  for (var i = 0; i < list.length; i++) {
    var stages = bandStages(list[i]);
    for (var k = 0; k < stages.length; k++) out.push(stages[k]);
  }
  return out;
}

// "Bands" that carry a gain for the summary line: a pass filter contributes no
// shaping, so counting it as flat would understate the preset.
function shapedCount(bands) {
  var n = 0;
  for (var i = 0; i < (bands || []).length; i++) {
    var b = bands[i];
    if (!bandEnabled(b)) continue;
    if (!typeHasGain(b.type)) continue;
    if (Math.abs(Number(b.gain) || 0) >= 0.05) n++;
  }
  return n;
}

function strongestBand(bands) {
  var best = null;
  for (var i = 0; i < (bands || []).length; i++) {
    var b = bands[i];
    if (!bandEnabled(b) || !typeHasGain(b.type)) continue;
    var g = Number(b.gain) || 0;
    if (best === null || Math.abs(g) > Math.abs(Number(best.gain) || 0)) best = b;
  }
  return best;
}


// ---------------------------------------------------------------- response
//
// The panel draws the response the filter-chain actually has, so these are a
// transcription of PipeWire's builtin biquads (spa/plugins/audioconvert/
// biquad.c). The graph instantiates each one with freq = 2*fc/rate, which makes
// w0 the usual 2*pi*fc/fs, and the filter types and the meaning of Q are the
// backend's own: Q is the bandwidth of a peaking filter and the slope of a
// shelf. tests/curve-check.js holds these to the C source and to a time-domain
// simulation of the difference equation.
//
// The only state in this file belongs to the response cache: the panel reads
// metrics() from several bindings for every status echo, so one memo slot and a
// test-only build counter save the sweep without anything else accumulating.
//
// With LSP the bands run through a para_equalizer_x16_stereo in APO (DR) mode at
// slope x1 instead of the builtin biquads. That mode was chosen precisely
// because its bell, shelf and pass shapes and its Q meaning match this RBJ math,
// so the same coefficients remain the model for the drawn curve and for
// auto_preamp_db. tests/dsp-check.sh measures the running plugin against these
// functions (every type within 0.05 dB), and tests/run-tests.sh pins the pool's
// fm/s mapping that keeps it so. Nothing here changes for the plugin.

function biquadCoefficients(type, freq, q, gain, rate) {
  var fs = (Number(rate) > 0) ? Number(rate) : 48000
  // The C code clamps the normalized frequency to (0, 1) and Q to >= 0 and has
  // dedicated branches for those limits; the panel never asks for them (20 Hz..
  // 20 kHz, Q 0.1..30), so clamping here keeps the formulas on their normal path.
  var fc = Math.max(1, Math.min(Number(freq) || 1000, fs / 2 - 1))
  var Q = Math.max(0.05, Number(q) || 1)
  var A = Math.pow(10, (Number(gain) || 0) / 40)
  var w0 = 2 * Math.PI * fc / fs
  var alpha = Math.sin(w0) / (2 * Q)
  var k = Math.cos(w0)
  var k2 = 2 * Math.sqrt(A) * alpha
  var b0, b1, b2, a0, a1, a2

  switch (String(type || "peaking")) {
    case "lowshelf":
      b0 = A * ((A + 1) - (A - 1) * k + k2)
      b1 = 2 * A * ((A - 1) - (A + 1) * k)
      b2 = A * ((A + 1) - (A - 1) * k - k2)
      a0 = (A + 1) + (A - 1) * k + k2
      a1 = -2 * ((A - 1) + (A + 1) * k)
      a2 = (A + 1) + (A - 1) * k - k2
      break
    case "highshelf":
      b0 = A * ((A + 1) + (A - 1) * k + k2)
      b1 = -2 * A * ((A - 1) + (A + 1) * k)
      b2 = A * ((A + 1) + (A - 1) * k - k2)
      a0 = (A + 1) - (A - 1) * k + k2
      a1 = 2 * ((A - 1) - (A + 1) * k)
      a2 = (A + 1) - (A - 1) * k - k2
      break
    case "lowpass":
      b0 = (1 - k) / 2; b1 = 1 - k; b2 = (1 - k) / 2
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha
      break
    case "highpass":
      b0 = (1 + k) / 2; b1 = -(1 + k); b2 = (1 + k) / 2
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha
      break
    case "bandpass":
      b0 = alpha; b1 = 0; b2 = -alpha
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha
      break
    case "notch":
      b0 = 1; b1 = -2 * k; b2 = 1
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha
      break
    case "allpass":
      b0 = 1 - alpha; b1 = -2 * k; b2 = 1 + alpha
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha
      break
    default: // peaking
      b0 = 1 + alpha * A; b1 = -2 * k; b2 = 1 - alpha * A
      a0 = 1 + alpha / A; a1 = -2 * k; a2 = 1 - alpha / A
  }
  return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
}

// |H(e^jw)| in dB for one biquad, from its normalized coefficients.
function magnitudeDb(c, freq, rate) {
  var fs = (Number(rate) > 0) ? Number(rate) : 48000
  var w = 2 * Math.PI * Number(freq) / fs
  var c1 = Math.cos(w), s1 = Math.sin(w)
  var c2 = Math.cos(2 * w), s2 = Math.sin(2 * w)
  var nr = c.b0 + c.b1 * c1 + c.b2 * c2
  var ni = -(c.b1 * s1 + c.b2 * s2)
  var dr = 1 + c.a1 * c1 + c.a2 * c2
  var di = -(c.a1 * s1 + c.a2 * s2)
  var num = Math.sqrt(nr * nr + ni * ni)
  var den = Math.sqrt(dr * dr + di * di)
  if (den < 1e-12) return 0
  return 20 * Math.log10(Math.max(num / den, 1e-9))
}

// The whole chain at one frequency: preamp plus every stage, exactly the order
// the graph runs them (the preamp has one control, so its dB is a plain sum).
function responseDb(bands, preamp, freq, rate) {
  var total = Number(preamp) || 0
  var stages = expandBands(bands)
  for (var i = 0; i < stages.length; i++) {
    var b = stages[i]
    total += magnitudeDb(biquadCoefficients(b.type, b.freq, b.q, b.gain, rate), freq, rate)
  }
  return total
}

// Where the curve peaks, which is what an automatic preamp has to cancel. This
// used to walk the grid with responseDb(), rebuilding every band's coefficients
// at every point; now the coefficients arrive built and responseSeries() walks
// the same 401 points. The preamp is passed through to responseSeries rather
// than added to the peak afterwards: both are a flat offset, but adding it after
// the sum rounds differently in the last bits, and the backend's awk port and
// tests/headroom-check.js compare these values exactly.
function peakDb(bands, preamp, rate, from, to) {
  return peakFromCoefficients(chainCoefficients(bands, rate), rate, from, to, 400, preamp)
}

// The same peak from coefficients already built for this band set. `steps` is
// the number of intervals, so 400 gives peakDb's 401-point sweep.
function peakFromCoefficients(coeffs, rate, from, to, steps, preamp) {
  var lo = Number(from) || 20, hi = Number(to) || 20000
  var n = Math.max(2, Math.round(Number(steps) || 400) + 1)
  var values = responseSeries(coeffs || [], preamp, rate, n, lo, hi)
  var max = -Infinity, at = lo
  for (var i = 0; i < values.length; i++) {
    if (values[i] > max) {
      max = values[i]
      at = lo * Math.pow(hi / lo, i / (values.length - 1))
    }
  }
  return { db: max, freq: at }
}

// The drawing asks for a few hundred points per repaint, so the coefficients are
// built once per repaint and the per-sample trig is shared by every band. The
// counter is bumped once per call (not once per band) so a test can assert that
// a metrics() computation built the chain exactly once.
var coefficientBuilds = 0
function chainCoefficients(bands, rate) {
  coefficientBuilds++
  var out = [], list = expandBands(bands)
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    out.push(biquadCoefficients(b.type, b.freq, b.q, b.gain, rate))
  }
  return out
}

function buildStats() {
  return { coefficientBuilds: coefficientBuilds }
}

function resetBuildStats() {
  coefficientBuilds = 0
}

function responseSeries(coeffs, preamp, rate, count, from, to) {
  var fs = (Number(rate) > 0) ? Number(rate) : 48000
  var lo = Number(from) || 20, hi = Number(to) || 20000
  var n = Math.max(2, Math.round(count))
  var base = Number(preamp) || 0
  var values = []
  for (var i = 0; i < n; i++) {
    // Even steps on a log axis: one sample per pixel of a log-scaled width.
    var f = lo * Math.pow(hi / lo, i / (n - 1))
    var w = 2 * Math.PI * f / fs
    var c1 = Math.cos(w), s1 = Math.sin(w)
    var c2 = Math.cos(2 * w), s2 = Math.sin(2 * w)
    var total = base
    for (var k = 0; k < coeffs.length; k++) {
      var c = coeffs[k]
      var nr = c.b0 + c.b1 * c1 + c.b2 * c2
      var ni = -(c.b1 * s1 + c.b2 * s2)
      var dr = 1 + c.a1 * c1 + c.a2 * c2
      var di = -(c.a1 * s1 + c.a2 * s2)
      var num = Math.sqrt(nr * nr + ni * ni)
      var den = Math.sqrt(dr * dr + di * di)
      total += (den < 1e-12) ? 0 : 20 * Math.log10(Math.max(num / den, 1e-9))
    }
    values.push(total)
  }
  return values
}

// A content signature for the metrics memo. Status echoes hand the panel a fresh
// bands array with the same contents, so object identity says nothing; the rate
// and the ordered type/freq/q/gain of every band are everything the numbers
// depend on. Bands that are missing are skipped, just as the sweep skips them.
var metricsCache = null
function metricsSignature(bands, rate) {
  var list = bands || [], parts = [String(rate)]
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (!b) continue
    parts.push([b.type, b.freq, b.q, b.gain, bandEnabled(b) ? 1 : 0, bandSlope(b)].join(","))
  }
  return parts.join("|")
}

// ---------------------------------------------------------------- loudness
//
// How loud a curve plays against Flat, as one number: the mean of the curve over
// the log sweep (pink noise -- equal energy per octave) blended with the same
// mean under A-weighting (the ear's own). A-weighted alone is too generous to a
// deep bass cut, pink alone too hard on it; tests/preset-levels.js gates the
// built-ins on the same blend. The level-matched A/B (the backend's compare
// command) and the "vs Flat" readout use it, so it lives here once and the
// backend's awk copy is held to it by tests/run-tests.sh.

// 0 dB at 1 kHz.
function aWeightDb(f) {
  var f2 = f * f, f4 = f2 * f2
  var ra = 12194 * 12194 * f4 /
    ((f2 + 20.6 * 20.6) * Math.sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * (f2 + 12194 * 12194))
  return 20 * Math.log10(2 * ra) + 2
}

// The level of a curve already sampled on the 401-point sweep peakDb walks
// (20 Hz .. 20 kHz, log-spaced), so the panel's metrics get it from the same
// series as the peak. A-weights are fixed per point, so they are built once.
var aWeights = null
function levelFromSeries(values) {
  var n = values.length
  if (n < 2) return 0
  if (aWeights === null || aWeights.length !== n) {
    aWeights = []
    for (var i = 0; i < n; i++)
      aWeights.push(Math.pow(10, aWeightDb(20 * Math.pow(1000, i / (n - 1))) / 10))
  }
  var sum = 0, wn = 0, wd = 0
  for (var k = 0; k < n; k++) {
    sum += values[k]
    wn += aWeights[k] * Math.pow(10, values[k] / 10)
    wd += aWeights[k]
  }
  return (sum / n + 10 * Math.log10(wn / wd)) / 2
}

// The curve's level with this preamp, in dB against Flat at unity.
function curveLevelDb(bands, preamp, rate) {
  return levelFromSeries(responseSeries(chainCoefficients(bands, rate), preamp, rate, 401))
}

// One call per status change in the panel, shared by every binding that needs a
// response number. A cold call builds the coefficients once and sweeps once; a
// hit returns the previous object without touching the model. The panel
// reassigns its whole status object constantly, so this is memoised on content,
// not identity.
function metrics(bands, sampleRate) {
  var rate = (Number(sampleRate) > 0) ? Number(sampleRate) : 48000
  var signature = metricsSignature(bands, rate)
  if (metricsCache !== null && metricsCache.signature === signature)
    return metricsCache.value

  var series = responseSeries(chainCoefficients(bands, rate), 0, rate, 401)
  var peak = peakFromSeries(series)
  var value = {
    peakDb: peak.db,
    peakFreq: peak.freq,
    autoPreamp: autoPreampForPeak(peak.db),
    // The level of the bands alone (preamp 0); add the preamp in force for
    // what is heard against Flat at the same volume.
    levelDb: levelFromSeries(series),
    // Bands that actually shape the sound; the gain and type it reads are in
    // the signature, so the memo keeps it in step with the rest.
    shapedCount: shapedCount(bands),
    slots: slotCount(bands),
    signature: signature
  }
  metricsCache = { signature: signature, value: value }
  return value
}

// The peak of a series on the 401-point sweep, the same walk
// peakFromCoefficients does over the values it computes.
function peakFromSeries(values) {
  var lo = 20, hi = 20000, max = -Infinity, at = lo
  for (var i = 0; i < values.length; i++) {
    if (values[i] > max) {
      max = values[i]
      at = lo * Math.pow(hi / lo, i / (values.length - 1))
    }
  }
  return { db: max, freq: at }
}

// Tests start from a known-cold cache without reaching into the memo object.
function resetMetricsCache() {
  metricsCache = null
}

// The preamp that cancels the curve's highest boost, so a full-scale input
// cannot clip. Measured on the bands alone (preamp 0), rounded to the slider's
// 0.5 dB step away from zero -- rounding toward zero would leave a sliver of
// boost, the exact clip this exists to prevent. A cut-only curve needs no
// preamp, and the slider's floor is -24 dB.
function autoPreampForPeak(peakDbValue) {
  if (!(peakDbValue > 0.05)) return 0
  return clamp(-Math.ceil(peakDbValue * 2) / 2, -24, 0)
}

function autoPreampDb(bands, rate) {
  var peak = peakDb(bands, 0, rate)
  return autoPreampForPeak(peak.db)
}
