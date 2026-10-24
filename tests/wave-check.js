#!/usr/bin/env node
// Checks the meter's pure functions in Model.js, the numbers LevelWave.qml
// draws: the spectrum line parser, the Lottie bar motion, and the fallback
// beat follower. No Qt runtime needed.
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

// lottieBars
const f0 = model.lottieBars(0);
check('lottie: 34 bars', f0.length === 34);
let allIn = true, maxSeen = 0;
for (let fr = -50; fr < 300; fr += 0.37) {
  const v = model.lottieBars(fr);
  for (const x of v) { if (x < 0 || x > 1 + EPS) allIn = false; maxSeen = Math.max(maxSeen, x); }
}
check('lottie: heights stay in 0..1', allIn);
check('lottie: the tallest bar reaches full height', maxSeen > 0.99, String(maxSeen));
const p0 = model.lottieBars(17.3), p1 = model.lottieBars(17.3 + 125);
check('lottie: loops every 125 frames', p0.every((v, i) => Math.abs(v - p1[i]) < EPS));
let maxStep = 0;
for (let fr = 0; fr < 125; fr += 0.05) {
  const x = model.lottieBars(fr), y = model.lottieBars(fr + 0.05);
  for (let i = 0; i < 34; i++) maxStep = Math.max(maxStep, Math.abs(x[i] - y[i]));
}
check('lottie: no jumps anywhere, including the wrap', maxStep < 0.03, String(maxStep));
// Bar 17 has scale 100 and start 0: at frame 10 it sits on key 2 (264.333).
check('lottie: matches the source keys', Math.abs(model.lottieBars(10)[17] - 1) < EPS);
check('lottie: bars are out of step with each other', f0.some((v, i) => i > 0 && Math.abs(v - f0[i - 1]) > 0.05));

// springStep
let x = 0, v = 0, over = 0;
for (let k = 0; k < 120; k++) { [x, v] = model.springStep(x, v, 1, 1 / 60, 5, 0.55); over = Math.max(over, x); }
check('spring: settles on the target', Math.abs(x - 1) < 0.01, String(x));
check('spring: overshoots a little, not wildly', over > 1.02 && over < 1.25, String(over));
[x, v] = [0, 0];
for (let k = 0; k < 10; k++) [x, v] = model.springStep(x, v, 1, 0.1, 5, 0.55);
check('spring: stable with long frames', Math.abs(x - 1) < 0.05 && Math.abs(v) < 1, x + ' ' + v);
[x, v] = [0.5, 0];
[x, v] = model.springStep(x, v, 0.5, 1 / 60, 5, 0.55);
check('spring: at rest stays at rest', x === 0.5 && v === 0);

// barEnergy
const spec = []; for (let i = 0; i < 24; i++) spec.push(i < 4 ? 1 : 0);
check('energy: centre bars follow the bass', model.barEnergy(spec, 17, 34) > 0.9 && model.barEnergy(spec, 16, 34) > 0.9);
check('energy: edge bars follow the treble', model.barEnergy(spec, 0, 34) === 0 && model.barEnergy(spec, 33, 34) === 0);
check('energy: neutral without a spectrum', model.barEnergy([], 5, 34) === 0.5);
let sym = true; for (let i = 0; i < 34; i++) if (Math.abs(model.barEnergy(bands24(), i, 34) - model.barEnergy(bands24(), 33 - i, 34)) > EPS) sym = false;
function bands24() { const b = []; for (let i = 0; i < 24; i++) b.push(i / 23); return b; }
check('energy: the row is mirrored', sym);

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
