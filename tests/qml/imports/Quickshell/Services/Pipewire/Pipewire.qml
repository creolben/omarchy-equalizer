pragma Singleton
import QtQuick

// Test stand-in for Quickshell's Pipewire singleton: no nodes, no default sink.
QtObject {
  property var nodes: ({ values: [] })
  property var defaultAudioSink: null
}
