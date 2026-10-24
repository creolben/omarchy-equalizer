#!/usr/bin/env node
// Checks the meter's pure functions in Model.js, the numbers LevelWave.qml
// draws: the spectrum line parser, the band-to-bar spread, the fallback bar
// series, and the fallback beat follower. No Qt runtime needed.
//
// Run: node tests/wave-check.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const EPS = 1e-9;
let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { console.log('PASS  ' + name); pass++; }
  else { console.log('FAIL  ' + name + (detail ? ' -- ' + detail : '')); fail++; }
}
const inRange = (xs, lo, hi) => xs.every(v => v >= lo - EPS && v <= hi + EPS);

// parseSpectrumLine
let f = model.parseSpectrumLine('40 0 50 100');
check('parse: beat and bands scaled to 0..1',
  f && f.beat === 0.4 && f.bands.length === 3 && f.bands[1] === 0.5 && f.bands[2] === 1,
  JSON.stringify(f));
f = model.parseSpectrumLine('  0 10 20 \n');
check('parse: surrounding whitespace is ignored', f && f.bands.length === 2);
check('parse: blank line is not a frame', model.parseSpectrumLine('') === null);
check('parse: too short is not a frame', model.parseSpectrumLine('5 7') === null);
check('parse: text is not a frame', model.parseSpectrumLine('Traceback (most recent') === null);
check('parse: negative or fractional is not a frame', model.parseSpectrumLine('0 -1 2') === null &&
  model.parseSpectrumLine('0 1.5 2') === null);
f = model.parseSpectrumLine('0 250 3');
check('parse: values above 100 are clamped', f && f.bands[0] === 1);

// spectrumBars
const bands = [];
for (let i = 0; i < 24; i++) bands.push(i / 23);
for (const mirrored of [false, true]) {
  for (const n of [1, 7, 60]) {
    const bars = model.spectrumBars(bands, n, mirrored);
    check('bars: count ' + n + (mirrored ? ' mirrored' : ''), bars.length === n);
    check('bars: bounded ' + n + (mirrored ? ' mirrored' : ''), inRange(bars, 0, 1));
  }
}
check('bars: silence is silence', model.spectrumBars(new Array(24).fill(0), 40, false).every(v => v === 0));
check('bars: no spectrum is silence', model.spectrumBars([], 40, true).every(v => v === 0));
let bars = model.spectrumBars(bands, 60, false);
check('bars: unmirrored puts bass on the left', bars[2] < bars[30] && bars[30] < bars[50]);
bars = model.spectrumBars(bands, 60, true);
check('bars: mirrored is symmetric', bars.every((v, i) => Math.abs(v - bars[59 - i]) < EPS));
check('bars: mirrored puts bass in the centre', bars[30] < bars[5]);
check('bars: count is clamped', model.spectrumBars(bands, 0, false).length === 1 &&
  model.spectrumBars(bands, 9999, false).length === 512);

// barSeries (fallback)
for (const peak of [0, 0.3, 1]) {
  const s = model.barSeries(peak, 1.7, 40);
  check('fallback: bounded by peak ' + peak, inRange(s, 0, peak));
}
check('fallback: silent at zero', model.barSeries(0, 3, 30).every(v => v === 0));
const a = model.barSeries(1, 0, 30), b = model.barSeries(1, 10, 30);
check('fallback: the wrap at 10 is seamless', a.every((v, i) => Math.abs(v - b[i]) < EPS));
check('fallback: phase moves the bars', model.barSeries(1, 0.2, 30).some((v, i) => Math.abs(v - a[i]) > 1e-3));

// beatStep (fallback)
let st = [0.2, 0];
const onsets = [];
for (const p of [0.2, 0.2, 0.2, 0.6, 0.6, 0.6, 0.6, 0.6, 0.2, 0.2, 0.2, 0.7]) {
  st = model.beatStep(st[0], p, 0);
  onsets.push(st[1]);
}
check('beat: steady level does not fire', onsets.slice(0, 3).every(o => o === 0), onsets.join(''));
check('beat: a jump fires once', onsets[3] === 1 && onsets.slice(4, 8).every(o => o === 0), onsets.join(''));
check('beat: a later jump fires again', onsets[11] === 1, onsets.join(''));
st = model.beatStep(0.2, 0.9, 0.8);
check('beat: refused while the pulse is still strong', st[1] === 0);
st = model.beatStep(0.2, 0.9, 0.3);
check('beat: allowed once the pulse has faded', st[1] === 1);
// A loud, steady track: average near the top, but a rise still counts.
st = [0.85, 0];
st = model.beatStep(st[0], 0.85, 0);
const steady = st[1];
st = model.beatStep(st[0], 1.0, 0);
check('beat: loud tracks still have beats', steady === 0 && st[1] === 1);
check('beat: does not decay the pulse itself', model.beatStep(0.2, 0.2, 0.7).length === 2);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
