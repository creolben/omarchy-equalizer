pragma Singleton
import QtQuick

// Test stand-in for the shell's Style: just the pieces KeyField, PresetPicker,
// ResponseCurve and VerticalGainSlider use.
QtObject {
  property real cornerRadius: 6
  property QtObject font: QtObject {
    property string family: "monospace"
    property real body: 14
    property real caption: 11
  }
  property QtObject spacing: QtObject {
    property int controlPaddingX: 10
    property int inputPaddingY: 7
    property int controlHeight: 32
    property int popupRowHeight: 28
    property int searchablePopupMinHeight: 120
    property int searchableDropdownWidth: 240
    property int md: 6
    property int xxs: 2
    property int hairline: 1
    property int labelGap: 2
    property int controlGap: 6
    property int rowPaddingX: 6
  }
  property int normalBorderWidth: 1
  function hoverFillFor(f, a) { return "#20ffffff" }
  function hoverStateColor(f, a) { return a }
  function space(px) { return Math.round(px) }
  function spaceReal(px) { return px }
  function controlFill(focused, hot, foreground, accent) { return focused ? "#30ffffff" : (hot ? "#20ffffff" : "#10ffffff") }
}
