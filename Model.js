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

// The spectrum behind the curve. Pure numbers so they can be tested without
// Qt; ResponseCurve.qml only eases and draws what these return.

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

// Which control, if any, a wheel event belongs to. One implementation, so the
// sliders cannot drift from each other or from tests/input-policy-check.js.
//
// A horizontal control under a vertical wheel is never a deliberate edit, so
// "preamp" always declines. A vertical fader may take the wheel only when the
// user has aimed at it (active focus, set by a click) or declared intent (Alt
// held). A handle on the curve follows the fader's rule: it takes the wheel
// (for its Q) only when it is the selected one, or with Alt. The optional delta
// lets callers pass the vertical amount through, so a zero-delta wheel is
// nobody's edit; omitting it keeps the three-argument rule the sliders and the
// node tests use.
var ALT_MODIFIER = 0x08000000
function wheelOwns(kind, modifiers, hasFocus, angleDeltaY) {
  if (kind !== "fader" && kind !== "handle") return false
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

// The ranges a band may hold, the backend's own (state_problem). The panel
// clamps what it sends to these, never to the ±12 dB a slider happens to show,
// so touching an imported band at -15 dB keeps it at -15.
var GAIN_MIN = -30, GAIN_MAX = 20
var FREQ_MIN = 10, FREQ_MAX = 24000
var Q_MIN = 0.05, Q_MAX = 30
function clampGain(db) { return clamp(db, GAIN_MIN, GAIN_MAX) }

// A gain control's range: ±12 dB, or ±24 dB for a band already outside that.
function gainSpan(db) { return Math.abs(Number(db) || 0) > 12.0001 ? 24 : 12 }

// A typed frequency: plain Hz, or kHz with a k ("2.5k" is 2500). NaN for
// anything else.
function parseFreqText(text) {
  var t = String(text === undefined || text === null ? "" : text).trim().toLowerCase()
  var m = /^([0-9]+(?:\.[0-9]*)?|\.[0-9]+)(k?)$/.exec(t)
  if (!m) return NaN
  var v = Number(m[1]) * (m[2] === "k" ? 1000 : 1)
  return isFinite(v) && v > 0 ? v : NaN
}

// A frequency for a field at rest: Hz below 1 kHz, kHz with up to two decimals
// above ("1.25k", "16k"), so the column reads like the curve's own axis.
function formatFreqField(hz) {
  var n = Number(hz)
  if (!isFinite(n) || n <= 0) return ""
  if (n < 1000) return String(Math.round(n))
  var k = Math.round(n / 10) / 100
  return String(k) + "k"
}

// Bandwidth in octaves of a bell of quality Q, and back: the analog relation
// the RBJ cookbook gives, 1/Q = 2 sinh(ln 2 / 2 * BW).
function asinh(x) { return Math.log(x + Math.sqrt(x * x + 1)) }
function qToOctaves(q) { return 2 / Math.LN2 * asinh(1 / (2 * Math.max(Q_MIN, Number(q) || 1))) }
function octavesToQ(bw) { return 1 / (2 * Math.sinh(Math.LN2 / 2 * bw)) }

// One step of Q in sixths of an octave of bandwidth: a positive step narrows
// the band (raises Q). Kept inside the 0.1..30 the fields allow, and rounded
// to the two decimals they show.
function stepQ(q, steps) {
  var bw = qToOctaves(q) - (Number(steps) || 0) / 6
  var next = bw > 0.01 ? octavesToQ(bw) : 30
  return Math.round(clamp(next, 0.1, 30) * 100) / 100
}

// A frequency moved by 1/24 octave per step, within the backend's range.
function stepFreq(hz, steps) {
  var f = (Number(hz) || 1000) * Math.pow(2, (Number(steps) || 0) / 24)
  return Math.round(clamp(f, 20, 20000))
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

// The type picker's label for a band: the type, and the slope of a pass filter.
function typeOptionLabel(type, slope) {
  var v = typeOptionValue(type, slope)
  for (var i = 0; i < bandTypeOptions.length; i++)
    if (bandTypeOptions[i].value === v) return bandTypeOptions[i].label
  return typeLabel(type)
}

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
  var program = programGainDb(series)
  var trough = Infinity
  for (var t = 0; t < series.length; t++) trough = Math.min(trough, series[t])
  var value = {
    peakDb: peak.db,
    peakFreq: peak.freq,
    // The curve's lowest point, for the plot's scale.
    troughDb: trough,
    autoPreamp: autoPreampForPeak(peak.db),
    // How much louder programme material leaves the bands, and the cut the
    // Balanced headroom takes for it (see balancedPreampFor).
    programGainDb: program,
    balancedPreamp: balancedPreampFor(peak.db, program),
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

// ---------------------------------------------------------------- balanced headroom
//
// The Safe preamp cancels the curve's peak, which is what a full-scale tone at
// that one frequency needs. Programme material spreads its energy: pink noise
// through a +9.3 dB bass shelf comes out only 3.5 dB louder. Balanced cuts by
// that programme gain plus a margin and leaves the rare peak above it to the
// limiter -- so it needs the limiter, and plays as Safe without one (the
// backend decides that; these are the numbers). The backend's awk copy of both
// is held to these by tests/headroom-check.js.

// The margin over the programme gain, in dB. Raised from 1.5 by the gate in
// tests/dsp-check.sh (docs/spec-v4.md §3.5.2), which records why.
var BALANCED_MARGIN = 3.5

// Pink-noise power gain of a curve sampled on the 401-point log sweep: the
// mean of 10^(H/10), in dB. Rounded to 0.01 dB so the JS and awk copies agree
// at the 0.5 dB steps the preamp is rounded to.
function programGainDb(values) {
  var n = values.length
  if (n < 1) return 0
  var p = 0
  for (var i = 0; i < n; i++) p += Math.pow(10, values[i] / 10)
  return Math.round(10 * Math.log10(p / n) * 100) / 100
}

// -min(the Safe cut, the programme gain plus the margin, rounded up to the
// preamp's 0.5 dB step).
function balancedPreampFor(peakDbValue, programGain) {
  var safe = autoPreampForPeak(peakDbValue)
  var cut = Math.ceil(Math.round((Math.max(0, Number(programGain) || 0) + BALANCED_MARGIN) * 100) / 50) / 2
  var p = Math.max(safe, -cut)
  return p === 0 ? 0 : p
}

// ---------------------------------------------------------------- graphic fit
//
// Ten octave bells at Q 1.41 overlap, so a band's own gain is not what the
// curve does at its frequency: all ten at +6 dB read +6.5 to +8.8 dB at the
// centres, and alternating ±6 only ±4. The 10-band console therefore shows the
// response at each band's centre -- the fader, its number and its handle -- and
// an edit solves the bells for it. The state and the presets keep bell gains,
// so nothing the backend computes changes meaning, and a curve that was never
// touched plays exactly as before; its faders just read what it does.

// The response at each band's own centre frequency, from the whole chain. A
// one-slot memo on the bands' content: every status echo asks again.
var graphicCache = null
function graphicResponse(bands, rate) {
  var fs = (Number(rate) > 0) ? Number(rate) : 48000
  var list = bands || []
  var signature = metricsSignature(list, fs)
  if (graphicCache !== null && graphicCache.signature === signature) return graphicCache.value.slice()
  var stages = expandBands(list), coeffs = []
  for (var s = 0; s < stages.length; s++)
    coeffs.push(biquadCoefficients(stages[s].type, stages[s].freq, stages[s].q, stages[s].gain, fs))
  var out = []
  for (var i = 0; i < list.length; i++) {
    var f = list[i] ? (Number(list[i].freq) || 1000) : 1000, total = 0
    for (var k = 0; k < coeffs.length; k++) total += magnitudeDb(coeffs[k], f, fs)
    out.push(total)
  }
  graphicCache = { signature: signature, value: out }
  return out.slice()
}

// Solve a small dense system a.x = b by Gaussian elimination with partial
// pivoting; null when it is singular.
function solveLinear(a, b) {
  var n = b.length, m = []
  for (var i = 0; i < n; i++) m.push(a[i].slice().concat([b[i]]))
  for (var c = 0; c < n; c++) {
    var p = c
    for (var r = c + 1; r < n; r++) if (Math.abs(m[r][c]) > Math.abs(m[p][c])) p = r
    if (Math.abs(m[p][c]) < 1e-12) return null
    var t = m[c]; m[c] = m[p]; m[p] = t
    for (var r2 = 0; r2 < n; r2++) {
      if (r2 === c) continue
      var k = m[r2][c] / m[c][c]
      if (k === 0) continue
      for (var j = c; j <= n; j++) m[r2][j] -= k * m[c][j]
    }
  }
  var x = []
  for (var i2 = 0; i2 < n; i2++) x.push(m[i2][n] / m[i2][i2])
  return x
}

// Bell gains whose response at the band centres is `targets` (dB, one per
// band). Newton's method from the current gains, with the Jacobian measured at
// each step; a band without a gain of its own (a pass filter, a bypassed band)
// keeps its value and its target is ignored. Gains stay inside the backend's
// range and are rounded to 0.01 dB.
//
// Returns { bands, achieved, clamped }: the new band set, the response it
// reaches at each centre, and whether a gain hit the range before the targets
// were met (neighbours too far apart to be fully reached).
function fitGraphic(bands, targets, rate) {
  var fs = (Number(rate) > 0) ? Number(rate) : 48000
  var list = bands || [], n = list.length
  var gains = [], free = [], centres = []
  for (var i = 0; i < n; i++) {
    var b = list[i] || {}
    gains.push(Number(b.gain) || 0)
    centres.push(Number(b.freq) || 1000)
    if (list[i] && bandEnabled(b) && typeHasGain(b.type)) free.push(i)
  }
  // Everything that is not a free bell, at every centre, once.
  var fixedStages = []
  for (var s = 0; s < n; s++) {
    if (free.indexOf(s) >= 0) continue
    var st = bandStages(list[s])
    for (var k = 0; k < st.length; k++)
      fixedStages.push(biquadCoefficients(st[k].type, st[k].freq, st[k].q, st[k].gain, fs))
  }
  var fixed = []
  for (var r = 0; r < n; r++) {
    var tot = 0
    for (var q = 0; q < fixedStages.length; q++) tot += magnitudeDb(fixedStages[q], centres[r], fs)
    fixed.push(tot)
  }
  function coeffFor(idx, g) {
    var bb = list[idx]
    return biquadCoefficients(bb.type, bb.freq, bb.q, g, fs)
  }
  function responseRows(g) {
    var cs = []
    for (var a = 0; a < free.length; a++) cs.push(coeffFor(free[a], g[free[a]]))
    var out = []
    for (var row = 0; row < n; row++) {
      var t = fixed[row]
      for (var c2 = 0; c2 < cs.length; c2++) t += magnitudeDb(cs[c2], centres[row], fs)
      out.push(t)
    }
    return out
  }
  var hitBound = false, worst = 0, resp = responseRows(gains)
  for (var iter = 0; iter < 8 && free.length > 0; iter++) {
    var err = []
    worst = 0
    for (var a2 = 0; a2 < free.length; a2++) {
      var e = (Number(targets[free[a2]]) || 0) - resp[free[a2]]
      err.push(e)
      worst = Math.max(worst, Math.abs(e))
    }
    if (worst < 0.02) break
    var up = [], down = [], D = 0.05
    for (var c3 = 0; c3 < free.length; c3++) {
      up.push(coeffFor(free[c3], gains[free[c3]] + D))
      down.push(coeffFor(free[c3], gains[free[c3]] - D))
    }
    var jac = []
    for (var r3 = 0; r3 < free.length; r3++) {
      var jrow = [], fr = centres[free[r3]]
      for (var c4 = 0; c4 < free.length; c4++)
        jrow.push((magnitudeDb(up[c4], fr, fs) - magnitudeDb(down[c4], fr, fs)) / (2 * D))
      jac.push(jrow)
    }
    var step = solveLinear(jac, err)
    if (step === null) break
    for (var c5 = 0; c5 < free.length; c5++) {
      var g2 = gains[free[c5]] + step[c5]
      if (g2 > GAIN_MAX) { g2 = GAIN_MAX; hitBound = true }
      if (g2 < GAIN_MIN) { g2 = GAIN_MIN; hitBound = true }
      gains[free[c5]] = g2
    }
    resp = responseRows(gains)
  }
  var out = []
  for (var i3 = 0; i3 < n; i3++) {
    var copy = {}
    for (var key in list[i3]) copy[key] = list[i3][key]
    if (free.indexOf(i3) >= 0) copy.gain = Math.round(gains[i3] * 100) / 100
    out.push(copy)
  }
  var achieved = graphicResponse(out, fs)
  worst = 0
  for (var a4 = 0; a4 < free.length; a4++)
    worst = Math.max(worst, Math.abs((Number(targets[free[a4]]) || 0) - achieved[free[a4]]))
  return { bands: out, achieved: achieved, clamped: hitBound && worst > 0.05 }
}

// What a fader edit asks of the fit: band `index` at `target`, every other band
// where the curve has it now (unrounded), so the other faders do not move.
function graphicTargets(bands, index, target, rate) {
  var t = graphicResponse(bands, rate)
  if (index >= 0 && index < t.length) t[index] = Number(target) || 0
  return t
}

// ---------------------------------------------------------------- contrast
//
// Secondary text is the foreground blended toward the background, but only as
// far as it still reads: the dimmest blend that keeps a 4.5:1 contrast ratio
// (WCAG AA for body text) against the background. A foreground that is already
// below the ratio is returned as it is. Colours are anything with r, g, b in
// 0..1 (a QML color) or a "#rrggbb" string; the result is a "#rrggbb" string,
// which a QML color property takes.

function colorParts(c) {
  if (typeof c === "string") {
    var h = c.replace("#", "")
    if (h.length === 8) h = h.slice(2)
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
    return { r: parseInt(h.slice(0, 2), 16) / 255, g: parseInt(h.slice(2, 4), 16) / 255, b: parseInt(h.slice(4, 6), 16) / 255 }
  }
  return { r: Number(c.r) || 0, g: Number(c.g) || 0, b: Number(c.b) || 0 }
}

function relativeLuminance(c) {
  var p = colorParts(c)
  function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * lin(p.r) + 0.7152 * lin(p.g) + 0.0722 * lin(p.b)
}

function contrastRatio(a, b) {
  var la = relativeLuminance(a), lb = relativeLuminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function hexColor(p) {
  function two(v) { var s = Math.round(clamp(v, 0, 1) * 255).toString(16); return s.length < 2 ? "0" + s : s }
  return "#" + two(p.r) + two(p.g) + two(p.b)
}

function dimColor(fg, bg, ratio) {
  var want = Number(ratio) > 0 ? Number(ratio) : 4.5
  var f = colorParts(fg), b = colorParts(bg)
  if (contrastRatio(f, b) <= want) return hexColor(f)
  function blend(t) { return { r: f.r + (b.r - f.r) * t, g: f.g + (b.g - f.g) * t, b: f.b + (b.b - f.b) * t } }
  var lo = 0, hi = 1
  for (var i = 0; i < 24; i++) {
    var t = (lo + hi) / 2
    if (contrastRatio(blend(t), b) >= want) lo = t; else hi = t
  }
  // The 8-bit colour it is written as can round across the line; step back
  // toward the foreground until the colour as written still holds the ratio.
  var out = hexColor(blend(lo))
  for (var s = 0; s < 64 && lo > 0 && contrastRatio(out, b) < want; s++) {
    lo = Math.max(0, lo - 1 / 255)
    out = hexColor(blend(lo))
  }
  return out
}

// ---------------------------------------------------------------- spectrum backdrop
//
// The 24 levels the spectrum helper prints (40 Hz .. 11 kHz, log-spaced, 0..1)
// as points on the curve's own frequency axis, for the soft shape drawn behind
// the response. Empty for no levels: the backdrop then draws nothing.
var SPECTRUM_LOW = 40, SPECTRUM_HIGH = 11000
function spectrumPoints(levels) {
  var list = levels || [], n = list.length, out = []
  if (n < 2) return out
  for (var i = 0; i < n; i++)
    out.push({ freq: SPECTRUM_LOW * Math.pow(SPECTRUM_HIGH / SPECTRUM_LOW, i / (n - 1)),
               level: clamp(Number(list[i]) || 0, 0, 1) })
  return out
}

// The backdrop's motion: a level rises at once and falls back slowly, so the
// shape reads as what is playing rather than flickering at the frame rate.
function easeLevels(previous, next, fall) {
  var p = previous || [], n = next || [], out = []
  var k = Number(fall) > 0 ? Number(fall) : 0.18
  for (var i = 0; i < n.length; i++) {
    var was = i < p.length ? Number(p[i]) || 0 : 0, now = clamp(Number(n[i]) || 0, 0, 1)
    out.push(now >= was ? now : was + (now - was) * k)
  }
  return out
}
