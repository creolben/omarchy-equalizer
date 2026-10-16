pragma Singleton
import QtQuick

// Test stand-in for the shell's Border: just the pieces KeyField uses.
QtObject {
  function controlSpec(state, foreground, accent) { return { width: 1, state: state } }
  function top(spec) { return spec.width }
  function right(spec) { return spec.width }
  function bottom(spec) { return spec.width }
  function left(spec) { return spec.width }
}
