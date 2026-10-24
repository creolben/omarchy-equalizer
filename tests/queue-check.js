#!/usr/bin/env node
// The panel's action queue collapses repeated edits into one entry by key
// (Panel.qml actionKey). Two different edits must never share a key: a band's
// freq and its Q used to, so a queued Q replaced the freq edit and it was lost.
// This also holds the band commit superseding the settle timer (sendBandNow
// stops bandCommitTimer), which is what made a double-click reset stick.
//
// Run: node tests/queue-check.js

const fs = require('fs')
const path = require('path')
const src = fs.readFileSync(path.join(__dirname, '..', 'Panel.qml'), 'utf8')

let pass = 0, fail = 0
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name) }
  else { fail++; console.log('FAIL  ' + name + (detail ? ' -- ' + detail : '')) }
}

function extract(name) {
  const start = src.indexOf('function ' + name + '(')
  if (start < 0) return null
  let depth = 0, i = src.indexOf('{', start)
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++
    else if (src[j] === '}' && --depth === 0) return src.slice(start, j + 1)
  }
  return null
}

const body = extract('actionKey')
check('actionKey is found in Panel.qml', body !== null)
const actionKey = new Function(body + '; return actionKey')()
const k = a => actionKey(a)
check('two gain drags on one band collapse', k(['set-gain', '3', '1']) === k(['set-gain', '3', '2']))
check('gains on different bands do not', k(['set-gain', '3', '1']) !== k(['set-gain', '4', '1']))
check('a band freq and Q edit stay distinct', k(['set-band', '2', 'freq', '900']) !== k(['set-band', '2', 'q', '2']))
check('two freq edits on one band collapse', k(['set-band', '2', 'freq', '900']) === k(['set-band', '2', 'freq', '950']))
check('presets are never collapsed', k(['apply-preset', 'Rock']) === '')

const send = extract('sendBandNow') || ''
check('an immediate band send stops the settle timer', /bandCommitTimer\.stop\(\)/.test(send))
check('and clears the pending band', /pendingBandIndex\s*=\s*-1/.test(send))

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
