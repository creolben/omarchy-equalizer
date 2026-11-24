import QtQuick

// Test stand-in for Quickshell's PwNodePeakMonitor: the peak stays at 0.
QtObject {
  property var node: null
  property bool enabled: false
  property real peak: 0
}
