#!/usr/bin/env node
// Checks the SHAPE of every built-in preset, not just that the numbers parse.
//
// A preset is applied on top of an automatic preamp, so whatever a curve's peak
// is, the applied curve peaks at 0 dBFS. What is left to get wrong is the level
// the curve then sits at: a preset built from boosts plays several dB below Flat
// (at the same volume setting, with no way to win it back at full volume), and a
// set whose members disagree about level gets compared by loudness instead of by
// tone. Both are audible complaints about an equalizer, neither shows up in any
// other test.
//
// The loudness proxy is the mean of the applied curve over a log sweep (pink
// noise: equal energy per octave) blended with the same mean weighted by
// A-weighting (the ear's own weighting). A-weighted alone is too generous to
// deep bass cuts; pink alone is too hard on them. The blend is the number the
// design of these presets was solved against.
//
// Run: node tests/preset-levels.js [preset-dir]

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dir = process.argv[2] || path.join(__dirname, '..', 'presets');
const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const RATE = 44100;
// The graph runs at whatever the device does (44.1, 48 and 96 kHz are all live
// here), and the same file has to hold up at every one of them.
const RATES = [44100, 48000, 96000];
const LEVEL_FLOOR = -2.5;   // dB below Flat a preset may sit
const LEVEL_CEIL = 0.5;     // dB above Flat a preset may sit
const SPREAD_MAX = 2.5;     // dB between the loudest and quietest preset
const PEAK_MAX = 0.5;       // the applied curve may not run over 0 dBFS
// Sanity bounds on any single point of the curve. The floor is well below the
// deepest EQ cut on purpose: a high-pass in a speech or small-speaker preset is
// supposed to fall away below its corner (that is the point of it), and a pink
// sweep still has energy down there to measure it with.
const DEEPEST = -26, LOUDEST = 4;

// The explicit category and the order band are two encodings of the same idea.
// Keeping both is useful (order still sorts, category is what the picker shows),
// but only if they cannot drift: the table below is the contract, and every file
// is checked against it.
const CATEGORIES = ['reference', 'tone', 'genre', 'speech', 'situation'];
const BAND_CATEGORY = {
  1: 'reference',   // order 10-19
  2: 'tone',        // order 20-29
  3: 'genre',       // order 30-39
  4: 'speech',      // order 40-49
  5: 'situation'    // order 50-59
};

let pass = 0, fail = 0;
function ok(name) { console.log('PASS  ' + name); pass++; }
function bad(name, detail) { console.log('FAIL  ' + name + ' -- ' + detail); fail++; }

const SWEEP = [];
for (let i = 0; i <= 800; i++) SWEEP.push(20 * Math.pow(1000, i / 800));

function aWeightDb(f) {
  const f2 = f * f, f4 = f2 * f2;
  const ra = 12194 * 12194 * f4 /
    ((f2 + 20.6 * 20.6) * Math.sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * (f2 + 12194 * 12194));
  return 20 * Math.log10(2 * ra) + 2;      // normalised to 0 dB at 1 kHz
}

function analyse(bands, preamp, rate) {
  const curve = SWEEP.map(f => model.responseDb(bands, preamp, f, rate));
  const peak = Math.max(...curve);
  const fin = curve.map(v => v - peak);                    // what is actually heard
  const pink = fin.reduce((a, b) => a + b, 0) / fin.length;
  let wn = 0, wd = 0;
  for (let i = 0; i < SWEEP.length; i++) {
    const w = Math.pow(10, aWeightDb(SWEEP[i]) / 10);
    wn += w * Math.pow(10, fin[i] / 10);
    wd += w;
  }
  return { peak, pink, a: 10 * Math.log10(wn / wd), level: 0, lo: Math.min(...fin), hi: Math.max(...fin) };
}

// Worst case over every rate the chain can run at, so a preset that only holds
// up at one sample rate is reported as failing rather than passing by accident.
function analyseAll(bands, preamp) {
  const worst = { peak: -Infinity, pink: Infinity, a: Infinity, lo: Infinity, hi: -Infinity };
  for (const rate of RATES) {
    const s = analyse(bands, preamp, rate);
    worst.peak = Math.max(worst.peak, s.peak);
    worst.pink = Math.min(worst.pink, s.pink);
    worst.a = Math.min(worst.a, s.a);
    worst.lo = Math.min(worst.lo, s.lo);
    worst.hi = Math.max(worst.hi, s.hi);
  }
  worst.level = (worst.a + worst.pink) / 2;
  return worst;
}

const files = fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort();
if (!files.length) { bad('presets are present', 'no *.json under ' + dir); }
const results = [];
const fmt = n => (n >= 0 ? '+' : '') + n.toFixed(1);

for (const file of files) {
  const name = file.replace(/\.json$/, '');
  let doc;
  try { doc = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8')); }
  catch (e) { bad(name + ' parses', e.message); continue; }

  const mode = doc.mode === 'parametric' ? 'parametric' : 'graphic';
  const bands = doc[mode];
  if (!Array.isArray(bands) || !bands.length) { bad(name + ' has bands', 'no ' + mode + ' array'); continue; }

  // The list is built from the name inside the file; apply-preset reads the file
  // by name. Letting the two differ would put a preset in the dropdown that
  // applies something else.
  if (typeof doc.name !== 'string' || doc.name !== name)
    bad(name + ' names itself', 'name field is ' + JSON.stringify(doc.name));
  else ok(name + ' names itself');
  if (typeof doc.description !== 'string' || !doc.description.trim())
    bad(name + ' describes itself', 'description is ' + JSON.stringify(doc.description));
  else ok(name + ' describes itself');
  if (!Number.isInteger(doc.order))
    bad(name + ' has a sort order', 'order is ' + JSON.stringify(doc.order));
  else ok(name + ' has a sort order');

  if (!CATEGORIES.includes(doc.category))
    bad(name + ' has a category', 'category is ' + JSON.stringify(doc.category) +
      ', allowed ' + CATEGORIES.join(', '));
  else ok(name + ' has a category');
  const bandCategory = Number.isInteger(doc.order) ? BAND_CATEGORY[Math.floor(doc.order / 10)] : null;
  if (bandCategory && doc.category === bandCategory)
    ok(name + ' category agrees with its order band');
  else
    bad(name + ' category agrees with its order band', 'order ' + JSON.stringify(doc.order) +
      ' maps to ' + JSON.stringify(bandCategory) + ', category is ' + JSON.stringify(doc.category));

  const s = analyseAll(bands, Number(doc.preamp) || 0);
  results.push({ name, category: doc.category, ...s });
  console.log('      ' + name.padEnd(16) + ' ' + String(doc.category || '?').padEnd(10) +
    ' level ' + fmt(s.level).padStart(6) +
    '  (pink ' + fmt(s.pink) + ', A ' + fmt(s.a) + ')  peak ' + fmt(s.peak).padStart(5) +
    '  range ' + fmt(s.lo) + ' .. ' + fmt(s.hi));
}

for (const r of results) {
  if (r.level < LEVEL_FLOOR || r.level > LEVEL_CEIL)
    bad(r.name + ' is level-matched', 'level ' + fmt(r.level) + ' dB, allowed ' +
      fmt(LEVEL_FLOOR) + ' .. ' + fmt(LEVEL_CEIL));
  else ok(r.name + ' is level-matched');
  if (r.peak > PEAK_MAX)
    bad(r.name + ' fits the headroom', 'applied peak ' + fmt(r.peak) + ' dB');
  else ok(r.name + ' fits the headroom');
  if (r.lo < DEEPEST || r.hi > LOUDEST)
    bad(r.name + ' stays in range', 'contour ' + fmt(r.lo) + ' .. ' + fmt(r.hi));
  else ok(r.name + ' stays in range');
}

// The set needs one neutral reference, and it has to be the file named Flat:
// every level below is measured against it.
const references = results.filter(r => r.category === 'reference');
if (references.length === 1)
  ok('exactly one preset is the reference');
else
  bad('exactly one preset is the reference', references.length + ' found' +
    (references.length ? ': ' + references.map(r => r.name).join(', ') : ''));
if (references.length === 1 && references[0].name === 'Flat')
  ok('the reference preset is Flat');
else
  bad('the reference preset is Flat', references.length === 1
    ? 'the reference is ' + references[0].name
    : 'no single reference to check');

// Files are named by preset, so a duplicate here would be a file whose name
// field collides with another one. It would make the picker ambiguous.
const seenNames = new Set();
const duplicates = [];
for (const r of results) {
  if (seenNames.has(r.name)) duplicates.push(r.name);
  seenNames.add(r.name);
}
if (duplicates.length)
  bad('preset names are unique', 'duplicates: ' + duplicates.join(', '));
else
  ok('preset names are unique');

if (results.length) {
  const hi = Math.max(...results.map(r => r.level)), lo = Math.min(...results.map(r => r.level));
  if (hi - lo > SPREAD_MAX)
    bad('the set is consistent', 'spread ' + (hi - lo).toFixed(1) + ' dB, allowed ' + SPREAD_MAX);
  else ok('the set is consistent (spread ' + (hi - lo).toFixed(1) + ' dB)');
}

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
