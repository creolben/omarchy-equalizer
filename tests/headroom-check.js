#!/usr/bin/env node
// Prints Model.autoPreampDb for each band set, so the backend's awk port of the
// same formulas can be compared with the model the panel draws from. The rate is
// an argument because the backend reads it from pw-metadata rather than assuming
// one: the biquads and this calculation both depend on it.
//
// Usage: node tests/headroom-check.js <rate> <sets.json>
//   sets.json is an array of band arrays.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

const rate = Number(process.argv[2]) || 48000;
const sets = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
process.stdout.write(JSON.stringify(sets.map((bands) => model.autoPreampDb(bands, rate))));
