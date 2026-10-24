#!/usr/bin/env node
// Checks the panel's response metrics: the sweep built from prebuilt
// coefficients must be the same peak that peakDb always reported, and the one-slot
// memo must actually skip the work when a status echo hands over a fresh array
// with the same contents.
//
// The build counter is the assertion; the timings printed at the end are only
// information, because they differ by machine.
//
// Run: node tests/metrics-check.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const RATE = 48000;
const ISO = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

let pass = 0, fail = 0;
function ok(name) { console.log('PASS  ' + name); pass++; }
function bad(name, detail) { console.log('FAIL  ' + name + ' -- ' + detail); fail++; }

const band = (type, freq, q, gain) => ({ type, freq, q, gain });
const copyBands = (bands) => bands.map((b) => band(b.type, b.freq, b.q, b.gain));
const isoBands = () => {
  const gains = [8, 7, 5, 3, 1, 0, 0, 0, 0, 0];
  return ISO.map((freq, i) => band('peaking', freq, 1.41, gains[i]));
};
const isoReversed = () => isoBands().reverse();

// The three shapes the brief calls out: nothing but unity peaking filters, a
// full ten-band graphic curve, and a parametric set with both shelves and a
// high-pass (a filter type with no gain of its own).
const flat = ISO.map((freq) => band('peaking', freq, 1.41, 0));
const mixed = [
  band('peaking', 31, 1.41, 8),
  band('peaking', 62, 1.41, 5),
  band('lowshelf', 125, 0.71, -3),
  band('peaking', 250, 1.0, 2.5),
  band('peaking', 500, 1.41, -6),
  band('peaking', 1000, 1.41, 4),
  band('highshelf', 2000, 0.71, 1.5),
  band('peaking', 4000, 2.0, -2),
  band('peaking', 8000, 1.41, 6),
  band('peaking', 16000, 1.41, -1)
];
const parametric = [
  band('lowshelf', 80, 0.71, 6),
  band('highshelf', 10000, 0.71, -4),
  band('peaking', 1000, 1.4, 5),
  band('peaking', 3000, 2.0, -6),
  band('highpass', 40, 0.7, 0)
];
const sets = [
  ['flat bands', flat],
  ['ten-band mixed curve', mixed],
  ['parametric shelves and a high-pass', parametric]
];

// 1. The two peak definitions must agree to 1e-9. The preamp case is stricter:
// peakDb used to add the preamp before every band, so passing it through
// responseSeries keeps the rounding identical, not just close.
for (const [label, bands] of sets) {
  const direct = model.peakDb(bands, 0, RATE);
  const viaCoeffs = model.peakFromCoefficients(model.chainCoefficients(bands, RATE), RATE);
  const delta = Math.max(Math.abs(direct.db - viaCoeffs.db), Math.abs(direct.freq - viaCoeffs.freq));
  if (delta <= 1e-9)
    ok(label + ': peakDb and peakFromCoefficients agree to 1e-9');
  else
    bad(label + ': peakDb and peakFromCoefficients agree to 1e-9', 'worst delta ' + delta);

  const directPreamp = model.peakDb(bands, -3.3, RATE);
  const viaPreamp = model.peakFromCoefficients(
    model.chainCoefficients(bands, RATE), RATE, 20, 20000, 400, -3.3);
  if (Object.is(directPreamp.db, viaPreamp.db) && Object.is(directPreamp.freq, viaPreamp.freq))
    ok(label + ': the preamp stays in the same sum, bit for bit');
  else
    bad(label + ': the preamp stays in the same sum, bit for bit',
      directPreamp.db + ' dB at ' + directPreamp.freq + ' Hz vs ' +
      viaPreamp.db + ' dB at ' + viaPreamp.freq + ' Hz');
}

// 1b. Against the sweep peakDb used to be: responseDb() per grid point, which
// rebuilds every coefficient per point. That is independent code, so this is
// the bit-identity check -- for every set, with and without a preamp.
for (const [label, bands] of sets) {
  for (const preamp of [0, -3.3]) {
    let scanDb = -Infinity, scanAt = 20;
    for (let i = 0; i <= 400; i++) {
      const f = 20 * Math.pow(20000 / 20, i / 400);
      const db = model.responseDb(bands, preamp, f, RATE);
      if (db > scanDb) { scanDb = db; scanAt = f; }
    }
    const now = model.peakDb(bands, preamp, RATE);
    if (Object.is(now.db, scanDb) && Object.is(now.freq, scanAt))
      ok(label + ', preamp ' + preamp + ': peakDb matches the per-point sweep bit for bit');
    else
      bad(label + ', preamp ' + preamp + ': peakDb matches the per-point sweep bit for bit',
        now.db + ' dB at ' + now.freq + ' Hz vs ' + scanDb + ' dB at ' + scanAt + ' Hz');
  }
}

// 2. The peak frequency is still read off today's sweep grid: compare it with a
// direct walk of responseDb(), then with a known boost's centre frequency. One
// grid step is 20 * (20000/20)^(1/400).
{
  const boost = [band('peaking', 2000, 2.0, 9)];
  const peak = model.peakDb(boost, 0, RATE);
  let scanDb = -Infinity, scanAt = 20;
  for (let i = 0; i <= 400; i++) {
    const f = 20 * Math.pow(20000 / 20, i / 400);
    const db = model.responseDb(boost, 0, f, RATE);
    if (db > scanDb) { scanDb = db; scanAt = f; }
  }
  if (peak.freq === scanAt && peak.db === scanDb)
    ok('peakDb still walks the same 401-point 20-20000 Hz grid');
  else
    bad('peakDb still walks the same 401-point 20-20000 Hz grid',
      peak.db + ' dB at ' + peak.freq + ' Hz vs ' + scanDb + ' dB at ' + scanAt + ' Hz');

  const oneStep = Math.pow(20000 / 20, 1 / 400);
  if (Math.abs(Math.log(peak.freq / 2000)) <= Math.log(oneStep))
    ok('the reported peak frequency is within one sweep step of the boost');
  else
    bad('the reported peak frequency is within one sweep step of the boost',
      Math.round(peak.freq) + ' Hz for a 2000 Hz band');
}

// 3. A cold metrics() computation builds the coefficients exactly once (the
// counter is bumped per chainCoefficients call, not per band).
model.resetMetricsCache();
model.resetBuildStats();
const before = model.buildStats().coefficientBuilds;
const cold = model.metrics(mixed, RATE);
const coldBuilds = model.buildStats().coefficientBuilds - before;
if (coldBuilds === 1)
  ok('a cold metrics() call builds the coefficient chain exactly once');
else
  bad('a cold metrics() call builds the coefficient chain exactly once', coldBuilds + ' calls');

// 4. A different array with the same contents is a cache hit: same object, no
// coefficient builds. The panel reassigns status objects constantly, so this is
// the case that matters.
model.resetBuildStats();
const warm = model.metrics(copyBands(mixed), RATE);
const warmBuilds = model.buildStats().coefficientBuilds;
if (warm === cold)
  ok('a content-identical array returns the cached metrics object');
else
  bad('a content-identical array returns the cached metrics object', 'different object');
if (warmBuilds === 0)
  ok('the cached call builds no coefficients');
else
  bad('the cached call builds no coefficients', warmBuilds + ' builds');
if (warm.peakDb === cold.peakDb && warm.peakFreq === cold.peakFreq && warm.autoPreamp === cold.autoPreamp)
  ok('the cached values are the cold values');
else
  bad('the cached values are the cold values', JSON.stringify(warm) + ' vs ' + JSON.stringify(cold));

// 5. A changed gain invalidates the memo and rebuilds once.
const changed = copyBands(mixed);
changed[5].gain = (Number(changed[5].gain) || 0) + 2;
model.resetBuildStats();
const changedMetrics = model.metrics(changed, RATE);
const changedBuilds = model.buildStats().coefficientBuilds;
if (changedMetrics !== warm && changedMetrics.signature !== warm.signature)
  ok('changing one band gain invalidates the memo');
else
  bad('changing one band gain invalidates the memo', 'the old entry was reused');
if (changedBuilds === 1)
  ok('the changed band set rebuilds coefficients once');
else
  bad('the changed band set rebuilds coefficients once', changedBuilds + ' builds');

// ... and so does a changed sample rate, which is part of the signature.
model.resetBuildStats();
const rateMetrics = model.metrics(changed, 44100);
const rateBuilds = model.buildStats().coefficientBuilds;
if (rateMetrics !== changedMetrics && rateMetrics.signature !== changedMetrics.signature)
  ok('changing the sample rate invalidates the memo');
else
  bad('changing the sample rate invalidates the memo', 'the old entry was reused');
if (rateBuilds === 1)
  ok('the rate change rebuilds coefficients once');
else
  bad('the rate change rebuilds coefficients once', rateBuilds + ' builds');

// The order of bands is significant: reversing the array is a different curve.
const reordered = model.metrics(isoReversed(), RATE);
if (reordered.signature !== model.metrics(isoBands(), RATE).signature)
  ok('the signature includes the order of the bands');
else
  bad('the signature includes the order of the bands', 'reordering kept the signature');

// 6. metrics() must carry exactly what the panel's old bindings read.
model.resetMetricsCache();
const iso = isoBands();
const metrics = model.metrics(iso, RATE);
const direct = model.peakDb(iso, 0, RATE);
const auto = model.autoPreampDb(iso, RATE);
if (Math.abs(metrics.peakDb - direct.db) <= 1e-9 && Math.abs(metrics.peakFreq - direct.freq) <= 1e-9)
  ok('metrics().peakDb/peakFreq equal Model.peakDb() for the ten ISO bands');
else
  bad('metrics().peakDb/peakFreq equal Model.peakDb() for the ten ISO bands',
    JSON.stringify(metrics) + ' vs ' + JSON.stringify(direct));
if (Math.abs(metrics.autoPreamp - auto) <= 1e-9)
  ok('metrics().autoPreamp equals Model.autoPreampDb() for the ten ISO bands');
else
  bad('metrics().autoPreamp equals Model.autoPreampDb() for the ten ISO bands',
    metrics.autoPreamp + ' vs ' + auto);

// Every field the response depends on invalidates the memo, not just gain and
// rate: a type, frequency or Q edit with the gain unchanged must recompute.
for (const [field, value] of [['type', 'lowshelf'], ['freq', 1234], ['q', 3.3]]) {
  model.resetMetricsCache();
  const base = [band('peaking', 1000, 1.0, 6)];
  model.metrics(base, RATE);
  model.resetBuildStats();
  const edited = [Object.assign({}, base[0], { [field]: value })];
  model.metrics(edited, RATE);
  if (model.buildStats().coefficientBuilds === 1)
    ok('a ' + field + ' change misses the memo');
  else
    bad('a ' + field + ' change misses the memo', model.buildStats().coefficientBuilds + ' builds');
}

// shapedCount travels with the memo and agrees with the model's own count.
{
  model.resetMetricsCache();
  const m = model.metrics(mixed, RATE);
  if (m.shapedCount === model.shapedCount(mixed))
    ok('metrics().shapedCount is Model.shapedCount (' + m.shapedCount + ')');
  else
    bad('metrics().shapedCount is Model.shapedCount', m.shapedCount + ' vs ' + model.shapedCount(mixed));
}

// resetMetricsCache() is the cold-start switch tests need.
model.resetMetricsCache();
model.resetBuildStats();
model.metrics(iso, RATE);
if (model.buildStats().coefficientBuilds === 1)
  ok('resetMetricsCache() forces a cold recompute');
else
  bad('resetMetricsCache() forces a cold recompute', model.buildStats().coefficientBuilds + ' builds');

// 7. Timings, for the report only: a cold call resets the memo, a warm one hits
// it. Averaged so a scheduler hiccup does not own the number.
for (let i = 0; i < 3; i++) { model.resetMetricsCache(); model.metrics(iso, RATE); }
let t0 = process.hrtime.bigint();
for (let i = 0; i < 50; i++) { model.resetMetricsCache(); model.metrics(iso, RATE); }
const coldMs = Number(process.hrtime.bigint() - t0) / 1e6 / 50;
model.metrics(iso, RATE);
t0 = process.hrtime.bigint();
for (let i = 0; i < 200; i++) model.metrics(iso, RATE);
const warmMs = Number(process.hrtime.bigint() - t0) / 1e6 / 200;
console.log('      cold ' + coldMs.toFixed(2) + ' ms  warm ' + warmMs.toFixed(2) + ' ms');

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
