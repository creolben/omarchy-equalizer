import QtQuick

// Test stand-in for Quickshell's StdioCollector: nothing is collected.
QtObject {
  property bool waitForEnd: false
  property string text: ""
  signal streamFinished()
}
