import QtQuick
import qs.Commons
import qs.Ui

// A single-line text field built from key events instead of Qt's text-input
// types, so the shared shell never reads another application's clipboard on
// its behalf.
//
// Every native Qt text input connects to the clipboard and reads a foreign
// application's offer on each clipboard change -- unbounded, with no deadline,
// even while unfocused and hidden -- so a stalled clipboard producer can stall
// or exhaust the shell process the panel runs in (marketplace review: "remove
// this automatic unbounded read"). This field never instantiates one: it takes
// typed characters, Backspace, Ctrl+U, Return and Escape, and draws its text
// with a plain Text. There is no paste, no selection and no caret movement;
// the preset name and the AutoEq query do not need them, and paste is
// unavailable by design.
//
// `value` is the model's current text. The field follows it while it is not
// being edited; `text` holds what the user typed. Typing emits textEdited();
// Return emits accepted(); leaving the field emits editingFinished(); Escape
// restores the model's text and emits cancelled().
Item {
  id: root

  property string value: ""
  property string text: ""
  property string placeholderText: ""
  property int maximumLength: 32767
  // When set, each typed character must match this expression.
  property var allowedCharacters: null
  property int horizontalAlignment: Text.AlignLeft
  property color foreground: Color.foreground
  property color accent: Color.accent
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body

  signal textEdited()
  signal accepted()
  signal editingFinished()
  signal cancelled()

  readonly property bool _hot: mouse.containsMouse
  readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

  // Typed text from a key event, or "" for anything that is not plain input.
  function typed(event) {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return ""
    var value = String(event.text || "")
    for (var i = 0; i < value.length; i++) {
      var code = value.charCodeAt(i)
      if (code < 32 || code === 127) return ""
      if (root.allowedCharacters && !root.allowedCharacters.test(value[i])) return ""
    }
    return value
  }

  function edit(next) {
    if (next === root.text) return
    root.text = next
    root.textEdited()
  }

  activeFocusOnTab: true
  implicitWidth: Style.space(160)
  implicitHeight: label.implicitHeight + 2 * verticalPadding + Border.top(_borderSpec) + Border.bottom(_borderSpec)

  Component.onCompleted: text = value
  onValueChanged: if (!activeFocus) text = value
  onActiveFocusChanged: if (!activeFocus) editingFinished()

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Backspace) {
      // Ctrl+Backspace clears, as there is no selection to delete.
      root.edit(event.modifiers & Qt.ControlModifier ? "" : root.text.slice(0, -1))
      event.accepted = true
    } else if (event.key === Qt.Key_U && (event.modifiers & Qt.ControlModifier)) {
      root.edit("")
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // Only accepted(); the focus-loss path emits editingFinished(), and one
      // commit per gesture is what the callers' backends expect.
      root.accepted()
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      root.edit(root.value)
      root.cancelled()
      event.accepted = true
    } else {
      var value = root.typed(event)
      if (value === "") return
      if (root.text.length < root.maximumLength) root.edit((root.text + value).slice(0, root.maximumLength))
      event.accepted = true
    }
  }

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root.activeFocus, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  Item {
    id: inner
    anchors.fill: parent
    anchors.leftMargin: root.horizontalPadding + Border.left(root._borderSpec)
    anchors.rightMargin: root.horizontalPadding + Border.right(root._borderSpec)
    clip: true

    Text {
      id: label
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      // Long text keeps its end, where typing happens, in view.
      x: implicitWidth > inner.width ? inner.width - implicitWidth - caret.width
        : (root.horizontalAlignment === Text.AlignRight ? inner.width - implicitWidth - caret.width
          : (root.horizontalAlignment === Text.AlignHCenter ? (inner.width - implicitWidth) / 2 : 0))
      text: root.text !== "" ? root.text : root.placeholderText
      color: root.text !== "" ? root.foreground : Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
    }

    Rectangle {
      id: caret
      visible: root.activeFocus && blink.on
      x: root.text !== "" ? label.x + label.implicitWidth : label.x
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(1, Style.spaceReal(1))
      height: label.font.pixelSize * 1.2
      color: root.foreground
    }
  }

  Timer {
    id: blink
    property bool on: true
    interval: 530
    repeat: true
    running: root.activeFocus
    onRunningChanged: on = true
    onTriggered: on = !on
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.IBeamCursor
    onClicked: root.forceActiveFocus()
  }
}
