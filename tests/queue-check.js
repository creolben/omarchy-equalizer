#!/usr/bin/env node
// The panel's action queue collapses repeated edits into one entry by key
// (Panel.qml actionKey). Two different edits must never share a key: a band's
// freq and its Q used to, so a queued Q replaced the freq edit and it was lost.
// The queue path is throttled, not debounced: a drag sends at most one command
// per 60 ms while it moves and always its last value (throttledRun), so the
// sound follows the hand when the live editor is not there to carry it.
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

check('the 10-band fit collapses to one entry', k(['set-gains', '1', '2']) === k(['set-gains', '3', '4']))
check('and is distinct from a single band', k(['set-gains', '1']) !== k(['set-gain', '1', '1']))

// The throttle, run with a fake timer: the first value goes at once, values in
// the window wait, only the last of them is sent when it fires, and a final
// value is sent at once and drops the one still waiting.
const throttle = extract('throttledRun')
check('throttledRun is found in Panel.qml', throttle !== null)
const sent = []
const timer = { running: false, start() { this.running = true }, stop() { this.running = false } }
const env = { throttlePending: {}, run: (a) => sent.push(a.join(' ')), throttleTimer: timer }
const fn = new Function('env', 'with (env) { ' + throttle + '; return throttledRun }')(env)
fn('gain:1', ['set-gain', '1', '1'], false)
fn('gain:1', ['set-gain', '1', '2'], false)
fn('gain:1', ['set-gain', '1', '3'], false)
check('the first value of a drag goes at once', sent.length === 1 && sent[0] === 'set-gain 1 1', sent.join(','))
check('values in the window wait, the last one kept', env.throttlePending['gain:1'][2] === '3')
fn('gain:1', ['set-gain', '1', '4'], true)
check('a final value goes at once', sent[sent.length - 1] === 'set-gain 1 4', sent.join(','))
check('and drops the value still waiting', env.throttlePending['gain:1'] === undefined)
check('the window is 60 ms', /id:\s*throttleTimer\s*\n\s*interval:\s*60\b/.test(src))
check('the old settle timers are gone', !/bandCommitTimer|preampCommitTimer/.test(src))

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
