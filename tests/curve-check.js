#!/usr/bin/env node
// Checks Model.js's response model against two independent references.
//
//   1. The coefficients are compared with a separate transcription of PipeWire's
//      own biquad source (spa/plugins/audioconvert/biquad.c, fetched from the
//      pipewire repo). A typo in either transcription shows up as a mismatch.
//   2. The magnitude at a frequency is compared with a time-domain simulation of
//      the difference equation: filter a sine with the same coefficients and
//      measure the output level. That checks the frequency-domain evaluation
//      itself, not just that two transcriptions agree.
//
// Run: node tests/curve-check.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const RATE = 48000;
let pass = 0, fail = 0;
function ok(name) { console.log('PASS  ' + name); pass++; }
function bad(name, detail) { console.log('FAIL  ' + name + ' -- ' + detail); fail++; }

// ---- reference 1: the C source, transcribed here independently -------------
// biquad_set() is called with freq = 2*fc/rate, then w0 = M_PI * freq.
function referenceCoefficients(type, freq, q, gain) {
  const A = Math.pow(10, gain / 40);
  const w0 = Math.PI * (2 * freq / RATE);
  const alpha = Math.sin(w0) / (2 * q);
  const k = Math.cos(w0);
  const k2 = 2 * Math.sqrt(A) * alpha;
  let b0, b1, b2, a0, a1, a2;
  switch (type) {
    case 'peaking':
      b0 = 1 + alpha * A; b1 = -2 * k; b2 = 1 - alpha * A;
      a0 = 1 + alpha / A; a1 = -2 * k; a2 = 1 - alpha / A; break;
    case 'lowshelf':
      b0 = A * ((A + 1) - (A - 1) * k + k2);
      b1 = 2 * A * ((A - 1) - (A + 1) * k);
      b2 = A * ((A + 1) - (A - 1) * k - k2);
      a0 = (A + 1) + (A - 1) * k + k2;
      a1 = -2 * ((A - 1) + (A + 1) * k);
      a2 = (A + 1) + (A - 1) * k - k2; break;
    case 'highshelf':
      b0 = A * ((A + 1) + (A - 1) * k + k2);
      b1 = -2 * A * ((A - 1) + (A + 1) * k);
      b2 = A * ((A + 1) + (A - 1) * k - k2);
      a0 = (A + 1) - (A - 1) * k + k2;
      a1 = 2 * ((A - 1) - (A + 1) * k);
      a2 = (A + 1) - (A - 1) * k - k2; break;
    case 'lowpass':
      b0 = (1 - k) / 2; b1 = 1 - k; b2 = (1 - k) / 2;
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case 'highpass':
      b0 = (1 + k) / 2; b1 = -(1 + k); b2 = (1 + k) / 2;
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case 'bandpass':
      b0 = alpha; b1 = 0; b2 = -alpha;
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case 'notch':
      b0 = 1; b1 = -2 * k; b2 = 1;
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case 'allpass':
      b0 = 1 - alpha; b1 = -2 * k; b2 = 1 + alpha;
      a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    default:
      throw new Error('unknown type ' + type);
  }
  return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 };
}

// ---- reference 2: the difference equation ---------------------------------
// A unit-amplitude sine has RMS 1/sqrt(2), so the gain is out/in in RMS terms.
// (Getting this wrong shifts every result by a constant 3.01 dB, which is how it
// was caught: a constant offset at every frequency is a units bug, not a curve.)
function simulateDb(c, freq, seconds) {
  const n = Math.floor(RATE * seconds);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0, sum = 0, count = 0;
  for (let i = 0; i < n; i++) {
    const x = Math.sin(2 * Math.PI * freq * i / RATE);
    const y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    if (i > n / 2) { sum += y * y; count++; }   // settle first, then measure
  }
  return 20 * Math.log10(Math.sqrt(sum / count) / Math.SQRT1_2);
}

// ---- reference 3: the DFT of the impulse response -------------------------
// Independent of both of the above: it transforms the filter's own impulse
// response rather than evaluating the transfer function at a point.
function impulseDftDb(c, freq, taps) {
  const h = [];
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < taps; i++) {
    const x = (i === 0) ? 1 : 0;
    const y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y; h.push(y);
  }
  const w = 2 * Math.PI * freq / RATE;
  let re = 0, im = 0;
  for (let n = 0; n < taps; n++) { re += h[n] * Math.cos(w * n); im -= h[n] * Math.sin(w * n); }
  return 20 * Math.log10(Math.sqrt(re * re + im * im));
}

const types = ['peaking', 'lowshelf', 'highshelf', 'lowpass', 'highpass', 'bandpass', 'notch', 'allpass'];
const cases = [];
for (const t of types) {
  cases.push([t, 100, 0.7, 6], [t, 1000, 1.0, -4.5], [t, 8000, 2.5, 3], [t, 31, 1.41, -12], [t, 16000, 0.71, 9]);
}

// 1. coefficients
let worst = 0, worstCase = '';
for (const [t, f, q, g] of cases) {
  const mine = model.biquadCoefficients(t, f, q, g, RATE);
  const ref = referenceCoefficients(t, f, q, g);
  for (const key of ['b0', 'b1', 'b2', 'a1', 'a2']) {
    const d = Math.abs(mine[key] - ref[key]);
    if (d > worst) { worst = d; worstCase = `${t} ${f}Hz Q${q} ${g}dB .${key}`; }
  }
}
if (worst < 1e-12) ok(`coefficients match the C source (worst delta ${worst.toExponential(1)})`);
else bad('coefficients match the C source', `worst delta ${worst} at ${worstCase}`);

// 2. magnitude vs simulation
//
// A notch (and a bandpass at its own edges) has a true null: the response at the
// exact centre is -infinity dB, and both sides of the comparison are then only
// measuring floating-point noise. Those points get their own assertion below;
// here the probes stand a little off any null.
worst = 0; worstCase = '';
const probes = [20, 100, 300, 1001, 3000, 8000, 16000, 20000];
for (const [t, f, q, g] of cases) {
  const c = model.biquadCoefficients(t, f, q, g, RATE);
  for (const p of probes) {
    if (p > RATE / 2 - 1) continue;
    if (t === 'notch' && Math.abs(p - f) < 2) continue;
    const analytic = model.magnitudeDb(c, p, RATE);
    const simulated = simulateDb(c, p, 0.5);
    const dft = impulseDftDb(c, p, 131072);
    const d = Math.max(Math.abs(analytic - simulated), Math.abs(analytic - dft));
    if (d > worst) {
      worst = d;
      worstCase = `${t} ${f}Hz Q${q} ${g}dB at ${p}Hz: curve ${analytic.toFixed(3)} sim ${simulated.toFixed(3)} dft ${dft.toFixed(3)}`;
    }
  }
}
if (worst < 0.05) ok(`magnitude matches both references: time-domain simulation and impulse-response DFT (worst delta ${worst.toFixed(4)} dB)`);
else bad('magnitude matches the time-domain simulation and the impulse-response DFT', worstCase);

// 2b. the notch's null, which the curve floors for drawing
const notchC = model.biquadCoefficients('notch', 1000, 1.0, 0, RATE);
const nullDb = model.magnitudeDb(notchC, 1000, RATE);
const shoulderDb = model.magnitudeDb(notchC, 2000, RATE);
if (nullDb < -40 && shoulderDb > -3)
  ok(`a notch is a deep null at its centre (${nullDb.toFixed(0)} dB there, ${shoulderDb.toFixed(2)} dB an octave up)`);
else bad('notch null depth', `${nullDb} dB at centre, ${shoulderDb} dB at 2 kHz`);

// 3. things the panel relies on
const flat = model.responseDb(
  [{ type: 'peaking', freq: 1000, q: 1.41, gain: 0 }, { type: 'lowshelf', freq: 80, q: 0.71, gain: 0 }],
  0, 1000, RATE);
if (Math.abs(flat) < 0.01) ok('a flat set of bands draws a flat 0 dB line');
else bad('flat bands draw 0 dB', `${flat} dB`);

const peak = model.peakDb([{ type: 'peaking', freq: 1000, q: 1.41, gain: 8 }], 0, RATE);
if (Math.abs(peak.db - 8) < 0.05 && Math.abs(peak.freq - 1000) / 1000 < 0.05)
  ok(`a single +8 dB band peaks at ${peak.db.toFixed(2)} dB near ${Math.round(peak.freq)} Hz`);
else bad('single band peak', `${peak.db.toFixed(2)} dB at ${Math.round(peak.freq)} Hz`);

const withPreamp = model.responseDb([{ type: 'peaking', freq: 1000, q: 1.41, gain: 8 }], -6, 1000, RATE);
if (Math.abs(withPreamp - 2) < 0.05) ok('the preamp adds to the curve (-6 dB preamp, +8 dB band gives +2 dB)');
else bad('preamp adds to the curve', `${withPreamp} dB`);

// 4. a graphic-EQ shape summing several bands: monotonic check around the boost
const graphic = [
  { type: 'peaking', freq: 31, q: 1.41, gain: 6 },
  { type: 'peaking', freq: 62, q: 1.41, gain: 6 },
  { type: 'peaking', freq: 125, q: 1.41, gain: 4 },
];
const at30 = model.responseDb(graphic, 0, 30, RATE);
const at60 = model.responseDb(graphic, 0, 60, RATE);
const at1000 = model.responseDb(graphic, 0, 1000, RATE);
if (at30 > at1000 + 4 && at60 > at1000 + 4)
  ok(`neighbouring bands sum as expected (${at30.toFixed(2)} dB at 30 Hz, ${at60.toFixed(2)} dB at 60 Hz, ${at1000.toFixed(2)} dB at 1 kHz)`);
else bad('neighbouring bands sum', `${at30} / ${at60} / ${at1000}`);

// 5. the series the painter uses must agree with the pointwise function
{
  const set = [
    { type: 'peaking', freq: 120, q: 1.0, gain: 5 },
    { type: 'highshelf', freq: 8000, q: 0.71, gain: -3.5 },
  ];
  const coeffs = model.chainCoefficients(set, RATE);
  const n = 97;
  const series = model.responseSeries(coeffs, -2, RATE, n, 20, 20000);
  let d = 0;
  for (let i = 0; i < n; i++) {
    const f = 20 * Math.pow(1000, i / (n - 1));
    d = Math.max(d, Math.abs(series[i] - model.responseDb(set, -2, f, RATE)));
  }
  if (series.length === n && d < 1e-9) ok(`the drawing series matches the pointwise response (worst delta ${d.toExponential(1)} dB)`);
  else bad('drawing series matches the pointwise response', `length ${series.length}, worst delta ${d}`);
}

// 6. auto-preamp: minus the curve's own peak, rounded away from zero to the
// slider step, never positive, clamped to the slider floor
{
  const freqs = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  const g = (gains) => gains.map((x, i) => ({ type: 'peaking', freq: freqs[i], q: 1.41, gain: x }));
  const cases = [
    ['a +9.6 dB peak gets -10 dB', g([8, 7, 5, 3, 1, 0, 0, 0, 0, 0]), -10],
    ['a flat curve gets 0 dB', g([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), 0],
    ['a cut-only curve gets 0 dB', g([-6, -3, 0, 0, 0, 0, 0, -4, 0, 0]), 0],
    ['ten +12 dB bands cancel their real ~+18.5 dB peak', g([12, 12, 12, 12, 12, 12, 12, 12, 12, 12]), -18.5],
    ['a +36 dB stacked boost clamps to -24 dB', [0, 1, 2].map(() => ({ type: 'peaking', freq: 1000, q: 1.0, gain: 12 })), -24],
  ];
  for (const [name, set, want] of cases) {
    const got = model.autoPreampDb(set, RATE);
    if (Math.abs(got - want) < 1e-9) ok(`auto-preamp: ${name}`);
    else bad(`auto-preamp: ${name}`, `want ${want} got ${got}`);
  }
  const cur = g([8, 7, 5, 3, 1, 0, 0, 0, 0, 0]);
  const after = model.peakDb(cur, model.autoPreampDb(cur, RATE), RATE).db;
  if (after <= 0) ok(`auto-preamp leaves the curve at or below 0 dB (peak ${after.toFixed(2)} dB)`);
  else bad('auto-preamp leaves the curve at or below 0 dB', `peak ${after}`);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
