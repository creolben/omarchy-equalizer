pragma Singleton
import QtQuick

// Test stand-in for the shell's Border: just the pieces KeyField and the
// faders use.
QtObject {
  function localOrSurfaceSpec(a, b, c, d, w) { return { width: w } }
  function controlSpec(state, foreground, accent) { return { width: 1, state: state } }
  function flat(color, width) { return { width: width, color: color } }
  function top(spec) { return spec.width }
  function right(spec) { return spec.width }
  function bottom(spec) { return spec.width }
  function left(spec) { return spec.width }
}
