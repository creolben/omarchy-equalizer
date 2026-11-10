import QtQuick

// Test stand-in for the shell's Panel base: the lifecycle a plugin panel reads.
// `opened` is writable here so a test can open the panel.
Item {
  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
  property string ipcTarget: ""
  property bool opened: false
  readonly property color barForeground: "#e6d9db"
  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened = !opened }
}
