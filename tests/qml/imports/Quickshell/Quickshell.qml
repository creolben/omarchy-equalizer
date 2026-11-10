pragma Singleton
import QtQuick

// Test stand-in for Quickshell's singleton: only env(), which the panel reads
// its paths from. HOME is a fixed fake so the plugin's helper path is known.
QtObject {
  function env(name) { return name === "HOME" ? "/home/tester" : "" }
}
