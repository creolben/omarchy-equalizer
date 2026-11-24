#!/usr/bin/env node
// Checks the spectrum's pure functions in Model.js, the numbers the backdrop
// behind the response curve draws: the helper's line parser, the points on the
// curve's frequency axis, and the easing that keeps the shape from flickering.
// And the contrast helper every caption's colour comes from. No Qt runtime.
//
// Run: node tests/spectrum-check.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { console.log('PASS  ' + name); pass++; }
  else { console.log('FAIL  ' + name + (detail ? ' -- ' + detail : '')); fail++; }
}

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

// spectrumPoints: 24 levels become 24 points from 40 Hz to 11 kHz, log-spaced.
const levels = [];
for (let i = 0; i < 24; i++) levels.push((i % 5) / 4);
const pts = model.spectrumPoints(levels);
check('backdrop: one point per level', pts.length === 24, String(pts.length));
check('backdrop: the first point is 40 Hz and the last 11 kHz',
  Math.abs(pts[0].freq - 40) < 1e-9 && Math.abs(pts[23].freq - 11000) < 1e-6);
const ratio = pts[1].freq / pts[0].freq;
check('backdrop: the points are evenly spaced on a log axis',
  pts.every((p, i) => i === 0 || Math.abs(p.freq / pts[i - 1].freq - ratio) < 1e-9));
check('backdrop: levels pass through, clamped to 0..1',
  pts[4].level === 1 && model.spectrumPoints([2, -1])[0].level === 1 && model.spectrumPoints([2, -1])[1].level === 0);
check('backdrop: no levels draw nothing', model.spectrumPoints([]).length === 0 &&
  model.spectrumPoints(null).length === 0 && model.spectrumPoints([0.5]).length === 0);

// easeLevels: a rise is immediate, a fall is eased.
const eased = model.easeLevels([0.2, 0.8], [0.6, 0.2], 0.25);
check('backdrop: a rise shows at once', eased[0] === 0.6, String(eased[0]));
check('backdrop: a fall is eased', Math.abs(eased[1] - (0.8 + (0.2 - 0.8) * 0.25)) < 1e-12, String(eased[1]));
check('backdrop: easing from nothing starts at the new frame',
  JSON.stringify(model.easeLevels([], [0.3, 0.4])) === '[0.3,0.4]');

// dimColor: the dimmest blend toward the background that still reads at 4.5:1.
for (const [fg, bg] of [['#e6d9db', '#101315'], ['#202020', '#ffffff'], ['#ffffff', '#000000'], ['#c0caf5', '#1a1b26']]) {
  const d = model.dimColor(fg, bg);
  const r = model.contrastRatio(d, bg);
  check('contrast: ' + fg + ' on ' + bg + ' dims to ' + d + ' at 4.5:1 or better', r >= 4.5, r.toFixed(3));
  check('contrast: ' + fg + ' on ' + bg + ' is dimmed, not left as it was', model.contrastRatio(fg, bg) > r + 0.5,
    model.contrastRatio(fg, bg).toFixed(2) + ' vs ' + r.toFixed(2));
  check('contrast: ' + fg + ' on ' + bg + ' is not dimmed further than it has to be', r < 4.75, r.toFixed(3));
}
check('contrast: a foreground already under the ratio is kept', model.dimColor('#777777', '#888888') === '#777777');
check('contrast: a QML-style colour object works too',
  model.dimColor({ r: 1, g: 1, b: 1 }, { r: 0, g: 0, b: 0 }) === model.dimColor('#ffffff', '#000000'));

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
