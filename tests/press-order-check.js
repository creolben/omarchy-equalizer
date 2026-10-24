#!/usr/bin/env node
// Guards the press handler in ResponseCurve.qml against the bug that made a
// band's first drag jump: `bandFreqAt()` answers with `draftFreq` for whichever
// band is marked as dragged, so assigning `dragIndex` before reading the band's
// frequency read back the *previous* drag's value -- 0 on the very first drag --
// and the handle was drawn at the 1 kHz fallback with the readout saying 0 Hz.
//
// The fix is an ordering constraint in one function, so this test checks the
// order of the two assignments rather than instantiating the component: the
// invariant is textual, and a source-order check cannot be fooled by a different
// Qt version's event delivery.
//
// Run: node tests/press-order-check.js [--file path/to/ResponseCurve.qml]

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2)
const fileArg = args.indexOf('--file')
const file = fileArg >= 0 && args[fileArg + 1]
  ? args[fileArg + 1]
  : path.join(__dirname, '..', 'ResponseCurve.qml')

let pass = 0, fail = 0
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name) }
  else { fail++; console.log('FAIL  ' + name + (detail ? ' -- ' + detail : '')) }
}

// Comments are stripped first: the handler explains the ordering in prose, and
// an assignment quoted in a comment must not satisfy (or break) the check.
const source = fs.readFileSync(file, 'utf8').replace(/\/\/[^\n]*/g, '')

// The plot has one press handler. If that ever stops being true this test has to
// be taught which one it means, rather than guessing.
// Keys.onPressed is the keyboard handler, not a press; only bare ones count.
const PRESS = /(^|[^.\w])onPressed:/g
const handlers = (source.match(PRESS) || []).length
check('ResponseCurve has exactly one onPressed handler', handlers === 1,
  handlers + ' found in ' + path.basename(file))

const firstPress = source.search(/(^|[^.\w])onPressed:/)
const start = firstPress >= 0 ? source.indexOf('onPressed:', firstPress) : -1
check('the press handler is present', start >= 0)

let body = ''
if (start >= 0) {
  // Cut the handler at the next handler (or 2000 chars, whatever comes first) so
  // an assignment in a later handler cannot satisfy the ordering check.
  const rest = source.slice(start)
  const next = rest.indexOf('onPositionChanged:')
  body = next > 0 ? rest.slice(0, next) : rest.slice(0, 2000)
}

// The read that matters is the one from the band itself; a decoy such as
// `draftFreq = 0` before the mark, with the real read after it, is the bug again.
const FREQ = /(?:root\.)?draftFreq\s*=\s*(?:root\.)?bandFreqAt\(\s*index\s*\)/
const DRAG = /(?:root\.)?dragIndex\s*=\s*index/

const freqAt = body.search(FREQ)
const dragAt = body.search(DRAG)

check('the handler reads the band frequency', freqAt >= 0)
check('the handler marks the band as dragged', dragAt >= 0)
check('the band frequency is read before the band is marked as dragged',
  freqAt >= 0 && dragAt >= 0 && freqAt < dragAt,
  'draftFreq at ' + freqAt + ', dragIndex at ' + dragAt +
  ' -- bandFreqAt() answers with draftFreq for the dragged band, so this order ' +
  'reads back the previous drag (0 on the first one) and draws the handle at 1 kHz')

// Nothing after the mark may re-read the band's frequency into the draft.
const afterDrag = dragAt >= 0 ? body.slice(dragAt) : ''
check('no draftFreq read from the band follows the dragged mark',
  dragAt >= 0 && !/draftFreq\s*=\s*(?:root\.)?bandFreqAt\(/.test(afterDrag))

// The ordering only matters while bandFreqAt() prefers the draft value for the
// dragged band. Keep that assumption explicit: if it is ever removed, this test
// is checking nothing and should be retired rather than left green.
const freqFn = source.indexOf('function bandFreqAt')
const freqBody = freqFn >= 0 ? source.slice(freqFn, freqFn + 600) : ''
check('bandFreqAt still prefers the draft frequency for the dragged band',
  freqBody.indexOf('dragIndex') >= 0 && freqBody.indexOf('draftFreq') >= 0)

console.log('\n' + pass + ' passed, ' + fail + ' failed')
process.exit(fail === 0 ? 0 : 1)
