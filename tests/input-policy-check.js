#!/usr/bin/env node
// Checks the one input-policy rule the sliders and the panel share:
//
//   preamp  never owns the wheel (a horizontal control under a vertical wheel
//           is never a deliberate edit; the panel scrolls instead)
//   fader   owns it only when focused (a click aimed at it) or when Alt is held
//           (declared intent); otherwise the panel scrolls
//
// The rule is a pure function in Model.js so these cases can run without Qt.
// tests/run-tests.sh runs this file and also checks that the panel uses the
// plugin-owned PreampSlider rather than the shell's wheel-adjusting one.
//
// Run: node tests/input-policy-check.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

// Qt 6 modifier bits. The policy accepts the numeric Alt bit so this test does
// not need a Qt runtime.
const SHIFT = 0x02000000;
const CTRL = 0x04000000;
const ALT = 0x08000000;
const META = 0x10000000;

let pass = 0, fail = 0;
function ok(name) { console.log('PASS  ' + name); pass++; }
function bad(name, detail) { console.log('FAIL  ' + name + ' -- ' + detail); fail++; }
function check(name, actual, expected) {
  if (actual === expected) ok(name);
  else bad(name, 'expected [' + expected + '] got [' + actual + ']');
}

// 1. The preamp never takes the wheel, focused or not, with or without Alt.
check('preamp unfocused, no modifier: the wheel scrolls', model.wheelOwns('preamp', 0, false), false);
check('preamp focused, no modifier: the wheel still scrolls', model.wheelOwns('preamp', 0, true), false);
check('preamp unfocused, Alt held: the wheel still scrolls', model.wheelOwns('preamp', ALT, false), false);
check('preamp focused, Alt held: the wheel still scrolls', model.wheelOwns('preamp', ALT, true), false);

// 2. A band fader is unarmed until the user aims at it.
check('fader unfocused, no modifier: unarmed', model.wheelOwns('fader', 0, false), false);

// 3. Focus (a click) arms it.
check('fader focused, no modifier: armed', model.wheelOwns('fader', 0, true), true);

// 4. Alt is the declared-intent shortcut, without focus.
check('fader unfocused, Alt held: armed', model.wheelOwns('fader', ALT, false), true);

// 5. Missing inputs are not an edit.
check('undefined kind: unknown controls never own the wheel', model.wheelOwns(undefined, 0, true), false);
check('empty kind: unknown controls never own the wheel', model.wheelOwns('', 0, true), false);
check('fader, no modifier, undefined focus: unarmed', model.wheelOwns('fader', 0, undefined), false);
check('fader, zero vertical delta, focused: unarmed', model.wheelOwns('fader', 0, true, 0), false);
check('fader, nonzero vertical delta, focused: armed', model.wheelOwns('fader', 0, true, -120), true);

// 6. Only Alt arms a fader among the modifier bits.
check('fader, Shift alone: unarmed', model.wheelOwns('fader', SHIFT, false), false);
check('fader, Ctrl alone: unarmed', model.wheelOwns('fader', CTRL, false), false);
check('fader, Meta alone: unarmed', model.wheelOwns('fader', META, false), false);
check('fader, Shift+Ctrl+Meta without Alt: unarmed',
  model.wheelOwns('fader', SHIFT | CTRL | META, false), false);
check('fader, Alt combined with another modifier: armed',
  model.wheelOwns('fader', ALT | SHIFT, false), true);

// 7. The delta a fader acts on: vertical first; with Alt held, a wheel the
// platform turned horizontal still counts, so Alt can always arm.
check('wheelDelta: vertical delta passes through', model.wheelDelta(0, -120, 0), -120);
check('wheelDelta: vertical wins over horizontal', model.wheelDelta(60, 120, ALT), 120);
check('wheelDelta: horizontal without Alt is no delta', model.wheelDelta(120, 0, 0), 0);
check('wheelDelta: Alt turned horizontal still counts', model.wheelDelta(-120, 0, ALT), -120);
check('fader, Alt wheel reported horizontally: armed',
  model.wheelOwns('fader', ALT, false, model.wheelDelta(120, 0, ALT)), true);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
