import QtQuick

// Test stand-in for the shell's Button: the properties the plugin sets, and a
// clicked signal a test can emit.
Item {
  property string text: ""
  property string iconText: ""
  property string tooltipText: ""
  property bool bordered: false
  property bool selected: false
  property bool hot: false
  property color foreground: "white"
  signal clicked()
  implicitWidth: 40
  implicitHeight: 24
}
