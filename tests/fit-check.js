#!/usr/bin/env node
// The 10-band console's fit (Model.fitGraphic): a fader sets what the curve
// does at its band's centre, the overlapping bells are solved for it, and no
// other fader moves. docs/spec-v4.md §1.4 and §3.3 are the cases.
//
// Run: node tests/fit-check.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const RATE = 48000;
const ISO = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const graphic = (gains) => ISO.map((freq, i) => ({ type: 'peaking', freq, q: 1.41, gain: gains[i] }));
const flat = () => graphic(ISO.map(() => 0));

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { console.log('PASS  ' + name); pass++; }
  else { console.log('FAIL  ' + name + (detail ? ' -- ' + detail : '')); fail++; }
}
const worst = (a, b) => Math.max(...a.map((x, i) => Math.abs(x - b[i])));

// What the bells do unfitted, for the record (§1.4).
const raw = model.graphicResponse(graphic(ISO.map(() => 6)), RATE);
check('unfitted, all ten at +6 read well above +6 at the centres', Math.max(...raw) > 8.5, raw.map((v) => v.toFixed(1)).join(' '));

const cases = [
  ['all ten at +6', ISO.map(() => 6)],
  ['alternating ±6', ISO.map((_, i) => (i % 2 ? -6 : 6))],
  ['+6 at 1 kHz only', ISO.map((f) => (f === 1000 ? 6 : 0))],
  ['a bass shelf 8/6/4', [8, 6, 4, 0, 0, 0, 0, 0, 0, 0]],
  ['a smile', [6, 4, 2, 0, -2, -2, 0, 2, 4, 6]],
  ['alternating ±12', ISO.map((_, i) => (i % 2 ? -12 : 12))],
];
for (const [name, targets] of cases) {
  const fit = model.fitGraphic(flat(), targets, RATE);
  const got = model.graphicResponse(fit.bands, RATE);
  check(name + ': the curve passes through every fader within 0.1 dB', worst(got, targets) <= 0.1,
    'worst ' + worst(got, targets).toFixed(3));
  check(name + ': reported as reached', fit.clamped === false);
  check(name + ': bell gains stay in the backend range',
    fit.bands.every((b) => b.gain >= -30 && b.gain <= 20));
  check(name + ': bell gains are rounded to 0.01 dB',
    fit.bands.every((b) => Math.abs(b.gain * 100 - Math.round(b.gain * 100)) < 1e-9));
}

// One fader moves; the others stay where the curve has them.
const start = model.fitGraphic(flat(), [8, 6, 4, 0, 0, 0, 0, 0, 0, 0], RATE).bands;
const before = model.graphicResponse(start, RATE);
const moved = model.fitGraphic(start, model.graphicTargets(start, 2, 7, RATE), RATE);
const after = model.graphicResponse(moved.bands, RATE);
check('the dragged fader reaches its value', Math.abs(after[2] - 7) <= 0.05, after[2].toFixed(3));
check('every other fader stays within 0.05 dB',
  after.every((v, i) => i === 2 || Math.abs(v - before[i]) <= 0.05),
  after.map((v, i) => (v - before[i]).toFixed(3)).join(' '));

// A target the range cannot reach: reported, and the fader shows what was
// achieved.
const far = model.fitGraphic(flat(), ISO.map((_, i) => (i % 2 ? -24 : 24)), RATE);
check('an unreachable set is reported as clamped', far.clamped === true);
check('and its bells are held at the range', far.bands.some((b) => b.gain === 20 || b.gain === -30));
check('the achieved response is what the bands play',
  worst(far.achieved, model.graphicResponse(far.bands, RATE)) < 1e-9);

// A curve nobody touched: its own response as targets gives its own bells back.
for (const file of ['Rock', 'Bass Boost', 'Loudness', 'Late Night']) {
  const preset = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'presets', file + '.json'), 'utf8'));
  const bands = preset.graphic;
  const back = model.fitGraphic(bands, model.graphicResponse(bands, RATE), RATE);
  check(file + ': fitting its own response returns its own bells',
    back.bands.every((b, i) => Math.abs(b.gain - bands[i].gain) <= 0.01),
    back.bands.map((b, i) => (b.gain - bands[i].gain).toFixed(3)).join(' '));
}

// A bypassed band or a pass filter is not solved for: it keeps its value.
const mixed = flat();
mixed[3] = Object.assign({}, mixed[3], { enabled: false, gain: 5 });
mixed[9] = { type: 'lowpass', freq: 16000, q: 0.707, gain: 0 };
const kept = model.fitGraphic(mixed, ISO.map(() => 3), RATE);
check('a bypassed band keeps its gain', kept.bands[3].gain === 5 && kept.bands[3].enabled === false);
check('a pass filter keeps its gain and type', kept.bands[9].gain === 0 && kept.bands[9].type === 'lowpass');

// Fast enough for a drag: a fit per pointer move.
const t0 = Date.now();
for (let i = 0; i < 50; i++) model.fitGraphic(start, model.graphicTargets(start, i % 10, (i % 7) - 3, RATE), RATE);
const each = (Date.now() - t0) / 50;
check('a fit costs well under a frame (' + each.toFixed(2) + ' ms)', each < 8);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
