import QtQuick

// Test stand-in for the shell's Dropdown: holds the value and the options, and
// lets a test pick one through choose(), which emits changed like a real pick.
Item {
  property var options: []
  property string value: ""
  property string label: ""
  property bool showLabel: true
  property color foreground: "white"
  property color background: "black"
  signal changed(string value)
  implicitWidth: 100
  implicitHeight: 24
  function choose(v) { changed(v) }
}
