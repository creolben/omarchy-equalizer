import QtQuick

// Test stand-in for Quickshell's FileView: no file is read or written.
QtObject {
  property string path: ""
  property bool watchChanges: false
  property bool printErrors: true
  property bool atomicWrites: false
  signal fileChanged()
  signal loaded()
  signal loadFailed(int error)
  function reload() {}
  function text() { return "" }
  function setText(t) {}
}
