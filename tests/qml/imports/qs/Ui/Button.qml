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
  property real fontSize: 12
  property real horizontalPadding: 10
  property real verticalPadding: 6
  property bool focusable: false
  property bool active: false
  signal clicked()
  signal rightClicked()
  implicitWidth: 40
  implicitHeight: 24
}
