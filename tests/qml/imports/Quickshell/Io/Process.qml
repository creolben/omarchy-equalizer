import QtQuick

// Test stand-in for Quickshell's Process: nothing runs. Every start and every
// write to stdin is recorded in ProcessLog, and a test plays the process's
// side through it (a line on stdout, an exit).
QtObject {
  id: proc
  property var command: []
  property bool running: false
  property bool stdinEnabled: false
  property QtObject stdout: null
  property QtObject stderr: null
  signal exited(int exitCode, int exitStatus)
  function write(data) { ProcessLog.wrote(proc, String(data)) }
  onRunningChanged: ProcessLog.changed(proc)
  Component.onCompleted: ProcessLog.add(proc)
}
