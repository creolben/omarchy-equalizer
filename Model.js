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

// The meter's waveform. Pure numbers so it can be tested without Qt: the panel
// draws what this returns, and the shape is defined here rather than in Canvas.
//
// There is no sample data to draw -- the monitor reports a peak -- so this is a
// synthetic envelope scaled by that peak: two partials inside a window that
// tapers to the midline at both ends. Amplitude is linear in peak rather than a
// dB conversion, because the dB text beside the meter stays the precise number;
// the shape only has to show that the signal is moving.
//
// The two partials give the ribbon a broken, non-sinusoidal profile and the
// window keeps its ends at the midline, so the envelope does not look cut off at
// the edges of the slot. No state and no cache: phase is supplied by the
// component's animation timer.
function waveSeries(peak, phase, count) {
  var n = Math.round(Number(count))
  if (!(n >= 8)) n = 8
  if (n > 512) n = 512
  var p = clamp(Number(peak) || 0, 0, 1)
  var ph = Number(phase) || 0
  var out = []
  for (var i = 0; i < n; i++) {
    var u = i / (n - 1)
    var body = Math.sin(2 * Math.PI * (u + ph)) * 0.7 +
               Math.sin(2 * Math.PI * (2.7 * u + 1.7 * ph)) * 0.3
    var window = 1 - 0.55 * Math.pow(2 * u - 1, 2)
    out.push(body * window * p)
  }
  return out
}

// Bar heights for the meter, in the style of a bar-type sound-wave animation:
// a row of rounded bars that all play one height sequence, each a little later
// than its neighbour, so a pulse travels along the row. Heights are 0..peak.
//
// BAR_KEYS is that sequence (relative heights, 25 keys) and is interpolated
// with a cosine ease so a bar never jumps between keys. `phase` runs 0..10 like
// waveSeries; five keys per phase unit makes ten units a whole 50 keys, two full
// laps, so the timer's wrap at 10 is seamless. A window shortens the outer bars.
var BAR_KEYS = [100, 237, 264, 248, 197, 29, 26, 158, 217, 250, 125, 163, 100,
                37, 52, 92, 50, 154, 115, 157, 98, 168, 39, 73, 27]
function barSeries(peak, phase, count) {
  var n = Math.round(Number(count))
  if (!(n >= 1)) n = 1
  if (n > 256) n = 256
  var p = clamp(Number(peak) || 0, 0, 1)
  var pos0 = (Number(phase) || 0) * 5
  var len = BAR_KEYS.length
  var out = []
  for (var i = 0; i < n; i++) {
    var pos = pos0 + i * 1.3
    pos = ((pos % len) + len) % len
    var k = Math.floor(pos)
    var f = pos - k
    var e = (1 - Math.cos(Math.PI * f)) / 2
    var a = BAR_KEYS[k], b = BAR_KEYS[(k + 1) % len]
    var u = n > 1 ? i / (n - 1) : 0.5
    var window = 1 - 0.5 * Math.pow(2 * u - 1, 2)
    out.push((a + (b - a) * e) / 264 * window * p)
  }
  return out
}

// Beat follower for the meter. The monitor reports only a peak, so a beat is an
// onset: a peak that jumps clearly above its own slow average. Call once per
// frame; returns [avg, beat], where beat is 1 on an onset and decays toward 0.
// A new onset is ignored while the last beat is still above half strength, so
// one drum hit cannot retrigger on its own tail.
function beatStep(avg, peak, beat) {
  var p = clamp(Number(peak) || 0, 0, 1)
  var a = clamp(Number(avg) || 0, 0, 1)
  var b = clamp(Number(beat) || 0, 0, 1) * 0.84
  var onset = p > 0.05 && p > a * 1.3 + 0.03 && b < 0.5
  a += (p - a) * (p > a ? 0.15 : 0.05)
  return [a, onset ? 1 : b]
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
//
// The only state in this file belongs to the response cache: the panel reads
// metrics() from several bindings for every status echo, so one memo slot and a
// test-only build counter save the sweep without anything else accumulating.
//
// In parametric mode with LSP the bands run through a para_equalizer_x16_mono in
// APO (DR) mode at slope x1 instead of the builtin biquads. That mode was chosen
// precisely because its bell and shelf shapes and its Q meaning match this RBJ
// math, so the same coefficients remain the model for the drawn curve and for
// auto_preamp_db; tests/run-tests.sh pins the pool's fm/s mapping that keeps it
// so. Nothing here changes for the plugin.

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
  var out = [], list = bands || []
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (!b) continue
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
    parts.push([b.type, b.freq, b.q, b.gain].join(","))
  }
  return parts.join("|")
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

  var peak = peakFromCoefficients(chainCoefficients(bands, rate), rate)
  var value = {
    peakDb: peak.db,
    peakFreq: peak.freq,
    autoPreamp: autoPreampForPeak(peak.db),
    // Bands that actually shape the sound; the gain and type it reads are in
    // the signature, so the memo keeps it in step with the rest.
    shapedCount: shapedCount(bands),
    signature: signature
  }
  metricsCache = { signature: signature, value: value }
  return value
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
