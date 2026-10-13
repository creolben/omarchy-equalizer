import QtQuick
import qs.Commons

// Pill on/off switch with an ON/OFF label and a sliding knob, used for the
// equalizer's master power.
//
// The stock kit switch is a bare track with an unlabelled knob, which leaves the
// state to be inferred from which end the knob sits at. This one says the state
// in words as well, because bypassing an equalizer is the one action here whose
// result is otherwise silent.
Item {
  id: root

  property bool checked: false
  property bool busy: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: Color.background

  // Track geometry. The knob is a circle inside the track, so the track height
  // is the knob plus padding, and the pill radius is half the height.
  readonly property int trackHeight: Math.max(20, Math.round(Style.spacing.controlHeight * 0.72))
  readonly property int trackWidth: Math.round(trackHeight * 2.35)
  readonly property int knobSize: trackHeight - Math.max(2, Style.space(4)) * 2
  readonly property int knobInset: Math.max(2, Style.space(4))
  readonly property bool rounded: Style.cornerRadius > 0
  readonly property string label: checked ? "ON" : "OFF"

  readonly property alias containsMouse: mouse.containsMouse
  readonly property bool hot: containsMouse

  // The label sits in the space the knob has vacated: knob right when on, so
  // the word goes left, and the other way round when off.
  readonly property bool labelOnLeft: checked

  signal toggled()

  implicitWidth: trackWidth
  implicitHeight: trackHeight
  opacity: busy ? 0.55 : 1.0

  Behavior on opacity { NumberAnimation { duration: 120 } }

  Rectangle {
    id: track
    anchors.fill: parent
    radius: root.rounded ? height / 2 : Math.max(1, Style.space(2))
    color: root.checked
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.85)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
    border.width: Math.max(1, Style.space(1))
    border.color: root.checked
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 1.0)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.hot ? 0.35 : 0.20)

    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on border.color { ColorAnimation { duration: 140 } }
  }

  // Caption on the side the knob has left, so the word and the knob never
  // overlap as the switch throws.
  Text {
    id: stateLabel
    textFormat: Text.PlainText
    text: root.label
    color: root.checked ? root.background : root.foreground
    opacity: root.hot || !root.checked ? 0.95 : 0.75
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 0.5
    anchors.verticalCenter: parent.verticalCenter
    x: root.labelOnLeft
      ? root.knobInset + Style.space(2)
      : track.width - width - root.knobInset - Style.space(2)
  }

  Rectangle {
    id: knob
    width: root.knobSize
    height: root.knobSize
    radius: root.rounded ? height / 2 : Math.max(1, Style.space(2))
    // Knob reads as 'raised': near-white in a dark theme, near-black in a light
    // one, without either being hardcoded.
    color: Qt.rgba(
      root.background.r * 0.25 + root.foreground.r * 0.75,
      root.background.g * 0.25 + root.foreground.g * 0.75,
      root.background.b * 0.25 + root.foreground.b * 0.75,
      1.0)
    border.width: Math.max(1, Style.space(1))
    border.color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.45)
    anchors.verticalCenter: parent.verticalCenter
    x: root.checked
      ? track.width - width - root.knobInset
      : root.knobInset
    scale: root.hot ? 1.06 : 1.0

    Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (!root.busy) root.toggled()
  }
}
