pragma Singleton
import QtQuick

// Test stand-in for the shell's Color singleton.
QtObject {
  property QtObject popups: QtObject { property color text: "#eee"; property color background: "#111"; property color border: "#444" }
  property color foreground: "#e6d9db"
  property color accent: "#f38d70"
  property color background: "#101315"
  property color urgent: "#e06c75"
}
