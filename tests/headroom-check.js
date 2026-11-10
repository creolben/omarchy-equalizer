#!/usr/bin/env node
// Prints Model.autoPreampDb for each band set, so the backend's awk port of the
// same formulas can be compared with the model the panel draws from. The rate is
// an argument because the backend reads it from pw-metadata rather than assuming
// one: the biquads and this calculation both depend on it. "balanced" prints the
// balanced headroom's preamp instead, and "program" the programme gain it rests
// on (Model.balancedPreampFor, Model.programGainDb).
//
// Usage: node tests/headroom-check.js <rate> <sets.json> [auto|balanced|program]
//   sets.json is an array of band arrays.
//
// It runs as a helper inside tests/run-tests.sh, which compares its output with
// the backend's awk port. Invoked bare it prints this usage rather than failing
// on a missing path.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

if (process.argv.length < 4) {
  process.stderr.write('usage: node tests/headroom-check.js <rate> <sets.json>\n');
  process.exit(0);
}

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const rate = Number(process.argv[2]) || 48000;
const sets = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const what = process.argv[4] || 'auto';
process.stdout.write(JSON.stringify(sets.map((bands) => {
  if (what === 'auto') return model.autoPreampDb(bands, rate);
  const m = model.metrics(bands, rate);
  return what === 'balanced' ? m.balancedPreamp : m.programGainDb;
})));
