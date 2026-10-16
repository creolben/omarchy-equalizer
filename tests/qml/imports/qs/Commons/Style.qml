pragma Singleton
import QtQuick

// Test stand-in for the shell's Style: just the pieces KeyField uses.
QtObject {
  property real cornerRadius: 6
  property QtObject font: QtObject {
    property string family: "monospace"
    property real body: 14
  }
  property QtObject spacing: QtObject {
    property int controlPaddingX: 10
    property int inputPaddingY: 7
  }
  function space(px) { return Math.round(px) }
  function spaceReal(px) { return px }
  function controlFill(focused, hot, foreground, accent) { return focused ? "#30ffffff" : (hot ? "#20ffffff" : "#10ffffff") }
}
