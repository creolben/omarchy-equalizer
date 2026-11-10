import QtQuick

// Test stand-in for the shell's PanelSeparator: a hairline that takes the width.
Item {
  property color foreground: "white"
  width: parent ? parent.width : 0
  implicitHeight: 1
}
