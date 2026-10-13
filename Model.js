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
// slider that moves nothing -- the same courtesy Audio Hijack's block faces pay
// when a parameter does not apply to the chosen type.
function typeHasGain(type) {
  var t = String(type || "peaking");
  return t !== "lowpass" && t !== "highpass" && t !== "bandpass"
    && t !== "notch" && t !== "allpass";
}

function typeLabel(type) {
  for (var i = 0; i < bandTypes.length; i++)
    if (bandTypes[i].value === String(type)) return bandTypes[i].label;
  return "Peaking";
}

// "Bands" that carry a gain for the summary line: a pass filter contributes no
// shaping, so counting it as flat would understate the preset.
function shapedCount(bands) {
  var n = 0;
  for (var i = 0; i < (bands || []).length; i++) {
    var b = bands[i];
    if (!b) continue;
    if (!typeHasGain(b.type)) continue;
    if (Math.abs(Number(b.gain) || 0) >= 0.05) n++;
  }
  return n;
}

function strongestBand(bands) {
  var best = null;
  for (var i = 0; i < (bands || []).length; i++) {
    var b = bands[i];
    if (!b || !typeHasGain(b.type)) continue;
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

// The whole chain at one frequency: preamp plus every band, exactly the order
// the graph runs them (the preamp has one control, so its dB is a plain sum).
function responseDb(bands, preamp, freq, rate) {
  var total = Number(preamp) || 0
  for (var i = 0; i < (bands || []).length; i++) {
    var b = bands[i]
    if (!b) continue
    total += magnitudeDb(biquadCoefficients(b.type, b.freq, b.q, b.gain, rate), freq, rate)
  }
  return total
}

// Where the curve peaks, which is what an automatic preamp has to cancel.
function peakDb(bands, preamp, rate, from, to) {
  var lo = Number(from) || 20, hi = Number(to) || 20000
  var steps = 400, max = -Infinity, at = lo
  for (var i = 0; i <= steps; i++) {
    var f = lo * Math.pow(hi / lo, i / steps)
    var db = responseDb(bands, preamp, f, rate)
    if (db > max) { max = db; at = f }
  }
  return { db: max, freq: at }
}

// The drawing asks for a few hundred points per repaint, so the coefficients are
// built once per repaint and the per-sample trig is shared by every band.
function chainCoefficients(bands, rate) {
  var out = [], list = bands || []
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (!b) continue
    out.push(biquadCoefficients(b.type, b.freq, b.q, b.gain, rate))
  }
  return out
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

// The preamp that cancels the curve's highest boost, so a full-scale input
// cannot clip. Measured on the bands alone (preamp 0), rounded to the slider's
// 0.5 dB step away from zero -- rounding toward zero would leave a sliver of
// boost, the exact clip this exists to prevent. A cut-only curve needs no
// preamp, and the slider's floor is -24 dB.
function autoPreampDb(bands, rate) {
  var peak = peakDb(bands, 0, rate);
  if (!(peak.db > 0.05)) return 0;
  return clamp(-Math.ceil(peak.db * 2) / 2, -24, 0);
}
