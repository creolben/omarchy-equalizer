#!/usr/bin/env node
// Checks the meter's waveform series, the shape LevelWave.qml draws. The series
// is pure math in Model.js so the bounds, silence, scaling, phase motion, count
// clamps and taper can be tested without a Qt runtime.
//
// The timing at the end is information only; the assertions never depend on it.
//
// Run: node tests/wave-check.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const EPS = 1e-12;

let pass = 0, fail = 0;
function ok(name) { console.log('PASS  ' + name); pass++; }
function bad(name, detail) { console.log('FAIL  ' + name + ' -- ' + detail); fail++; }

function close(a, b, eps) { return Math.abs(a - b) <= (eps === undefined ? EPS : eps); }

// 1. Every sample stays inside the peak it was given, for every phase.
const peaks = [0, 0.01, 0.5, 1];
const phases = [0, 0.13, 0.7];
for (const peak of peaks) {
  for (const phase of phases) {
    const series = model.waveSeries(peak, phase, 96);
    let out = -1;
    for (let i = 0; i < series.length; i++)
      if (Math.abs(series[i]) > peak + EPS) { out = i; break; }
    if (out < 0) ok('bounds: peak ' + peak + ', phase ' + phase);
    else bad('bounds: peak ' + peak + ', phase ' + phase,
      'sample ' + out + ' = ' + series[out] + ' exceeds ' + peak);
  }
}

// 2. Silence is exactly silence, not a rounded-down hairline.
const silent = model.waveSeries(0, 0.42, 96);
if (silent.every((v) => v === 0)) ok('silence: peak 0 returns all zeros');
else bad('silence: peak 0 returns all zeros', 'found ' + silent.filter((v) => v !== 0).length + ' nonzero samples');

// 3. Amplitude is linear in peak at a fixed phase.
const quiet = model.waveSeries(0.25, 0.13, 96);
const loud = model.waveSeries(0.5, 0.13, 96);
if (quiet.every((v, i) => close(loud[i], v * 2, 1e-9)))
  ok('amplitude scales linearly with peak');
else {
  let worst = 0;
  for (let i = 0; i < quiet.length; i++) worst = Math.max(worst, Math.abs(loud[i] - quiet[i] * 2));
  bad('amplitude scales linearly with peak', 'worst residual ' + worst);
}

// 4. Phase moves the series, and moving it does not change the bounds.
const p1 = model.waveSeries(0.5, 0.1, 96);
const p2 = model.waveSeries(0.5, 0.2, 96);
const differs = p1.some((v, i) => Math.abs(v - p2[i]) > 1e-9);
const p2Inside = p2.every((v) => Math.abs(v) <= 0.5 + EPS);
if (differs) ok('phase changes the series');
else bad('phase changes the series', 'series at 0.1 and 0.2 are equal');
if (p2Inside) ok('phase motion keeps the amplitude bounds');
else bad('phase motion keeps the amplitude bounds', 'a sample left [-0.5, 0.5]');

// 5. Count is rounded and clamped to [8, 512].
const cases = [
  ['1 clamps up to 8', model.waveSeries(0.5, 0, 1).length, 8],
  ['9999 clamps down to 512', model.waveSeries(0.5, 0, 9999).length, 512],
  ['12.4 rounds to 12', model.waveSeries(0.5, 0, 12.4).length, 12],
  ['12.6 rounds to 13', model.waveSeries(0.5, 0, 12.6).length, 13]
];
for (const [name, actual, expected] of cases) {
  if (actual === expected) ok('count: ' + name);
  else bad('count: ' + name, 'expected ' + expected + ' got ' + actual);
}

// 6. Determinism: same inputs, same numbers, no hidden state.
const a = model.waveSeries(0.8, 0.37, 96);
const b = model.waveSeries(0.8, 0.37, 96);
if (JSON.stringify(a) === JSON.stringify(b)) ok('determinism: identical calls are deeply equal');
else bad('determinism: identical calls are deeply equal', 'the two calls differ');

// 7. The window works: both ends sit below the interior peak.
const tapered = model.waveSeries(1, 0, 96);
let largest = 0;
for (const v of tapered) largest = Math.max(largest, Math.abs(v));
if (Math.abs(tapered[0]) < largest && Math.abs(tapered[tapered.length - 1]) < largest)
  ok('taper: first and last samples are smaller than the largest');
else bad('taper: first and last samples are smaller than the largest',
  'first ' + tapered[0] + ', last ' + tapered[tapered.length - 1] + ', largest ' + largest);

// 8. Timing, information only: 10 000 series of 96 points.
const t0 = process.hrtime.bigint();
for (let i = 0; i < 10000; i++) model.waveSeries(0.7, i / 10000, 96);
const ms = Number(process.hrtime.bigint() - t0) / 1e6;
console.log('      10 000 series of 96 points: ' + ms.toFixed(1) + ' ms');

// 7. The meter wraps its phase at 10 (LevelWave.qml). Both partials must be
// periodic there -- 1.0 * 10 and 1.7 * 10 are whole cycles -- so the wrap is
// invisible; a wrap at 1 would jump the 1.7x partial by 0.7 cycle.
{
  const a = model.waveSeries(0.8, 10, 96), b = model.waveSeries(0.8, 0, 96);
  let worst = 0;
  for (let i = 0; i < a.length; i++) worst = Math.max(worst, Math.abs(a[i] - b[i]));
  if (worst < 1e-9) ok('the phase wrap at 10 is seamless');
  else bad('the phase wrap at 10 is seamless', 'max jump ' + worst);
  const c = model.waveSeries(0.8, 1, 96);
  let jump = 0;
  for (let i = 0; i < c.length; i++) jump = Math.max(jump, Math.abs(c[i] - b[i]));
  if (jump > 0.05) ok('a wrap at 1 would not be (jump ' + jump.toFixed(2) + ')');
  else bad('a wrap at 1 would not be', 'series at 1 and 0 agree; the wrap note is stale');
}

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
