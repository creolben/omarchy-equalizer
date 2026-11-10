pragma Singleton
import QtQuick

// The test-side record of every stand-in Process: what was started (as a
// command line), what was written to which one, and a way to answer for one.
QtObject {
  property var all: []
  property var starts: []
  property var writes: []

  function cmdOf(p) { return (p.command || []).join(" ") }
  function add(p) { all = all.concat([p]) }
  function changed(p) { if (p.running) starts = starts.concat([cmdOf(p)]) }
  function wrote(p, data) { writes = writes.concat([{ cmd: cmdOf(p), data: data }]) }
  function clear() { starts = []; writes = [] }

  // The running process whose command line contains `part`.
  function find(part) {
    for (var i = 0; i < all.length; i++)
      if (all[i].running && cmdOf(all[i]).indexOf(part) >= 0) return all[i]
    return null
  }
  function written(part) {
    var out = ""
    for (var i = 0; i < writes.length; i++) if (writes[i].cmd.indexOf(part) >= 0) out += writes[i].data
    return out
  }
  function startedWith(part) {
    var out = []
    for (var i = 0; i < starts.length; i++) if (starts[i].indexOf(part) >= 0) out.push(starts[i])
    return out
  }
  function feed(part, line) {
    var p = find(part)
    if (p && p.stdout && p.stdout.read) p.stdout.read(line)
    return p !== null
  }
  function finish(part, code) {
    var p = find(part)
    if (!p) return false
    p.running = false
    p.exited(code || 0, 0)
    return true
  }
}
