import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Horizontal bipolar gain slider for the parametric rows: compact, with the fill
// growing out of the 0 dB centre and a visible track.
//
// The kit's PanelSlider fills from its left end, which on a -12..+12 dB control
// reads as a 0..max scale and makes every cut look like a boost. This is the
// horizontal counterpart of VerticalGainSlider, so a parametric band and a
// graphic band describe a gain the same way.
Item {
  id: root

  property real value: 0
  property real minimum: -12
  property real maximum: 12
  property real step: 0.5

  property QtObject bar: null
  // Injected by the panel: moves the enclosing scroll area when the wheel is
  // declined. Without it a declined wheel still does nothing to the gain.
  property var scrollBy: null
  property color foreground: bar ? bar.foreground : Color.foreground
  property color accent: Color.accent
  property color background: bar ? bar.background : Color.background
  property int trackHeight: Math.max(6, Style.space(8))
  property int knobWidth: Math.max(8, Style.space(10))
  property int knobHeight: Math.max(12, Style.space(16))

  readonly property alias containsMouse: mouse.containsMouse
  property bool dragging: false
  property real liveValue: value
  readonly property bool hot: containsMouse || dragging || activeFocus

  signal moved(real value)
  signal released(real value)
  signal rightClicked()

  onValueChanged: if (!dragging) liveValue = value

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
  readonly property real zeroProgress: Math.max(0, Math.min(1, (0 - minimum) / range))

  // The travel is inset by half a knob so the knob never overhangs either end.
  readonly property real trackLeft: knobWidth / 2
  readonly property real trackLength: Math.max(1, width - knobWidth)
  readonly property real knobCenterX: trackLeft + progress * trackLength
  readonly property real zeroX: trackLeft + zeroProgress * trackLength

  implicitHeight: Math.max(knobHeight, trackHeight)
  // Focus is click-only: a click arms the wheel and reveals the ring below.
  activeFocusOnTab: false

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function valueFromX(x) {
    var t = Math.max(0, Math.min(1, (x - trackLeft) / trackLength))
    var raw = minimum + t * range
    return Math.max(minimum, Math.min(maximum, Math.round(raw / step) * step))
  }

  function nudge(delta) {
    var next = Math.max(minimum, Math.min(maximum, liveValue + delta))
    liveValue = next
    root.moved(next)
    root.released(next)
  }

  Keys.onLeftPressed: nudge(-step)
  Keys.onRightPressed: nudge(step)
  Keys.onReturnPressed: { root.released(0); liveValue = 0 }

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    x: root.trackLeft
    width: root.trackLength
    height: root.trackHeight
    radius: height / 2
    color: root.rgba(root.foreground, 0.10)
    border.width: 1
    border.color: root.rgba(root.foreground, 0.07)
  }

  // Focus is what arms the wheel, so it has to be visible. Hover stays
  // cosmetic; this ring is only activeFocus.
  Rectangle {
    anchors.centerIn: track
    width: track.width + Style.space(8)
    height: track.height + Style.space(8)
    radius: height / 2
    color: "transparent"
    border.width: Math.max(1, Style.space(2))
    border.color: root.rgba(root.accent, 0.4)
    visible: root.activeFocus
  }

  // Fill from the 0 dB mark to the knob, so a cut and a boost are told apart by
  // which side of the centre lights up.
  Rectangle {
    anchors.verticalCenter: track.verticalCenter
    height: track.height
    radius: track.radius
    x: Math.min(root.knobCenterX, root.zeroX)
    width: Math.max(0, Math.abs(root.knobCenterX - root.zeroX))
    color: root.accent
    opacity: root.hot ? 1.0 : (root.liveValue < 0 ? 0.62 : 0.88)
    Behavior on opacity { NumberAnimation { duration: 120 } }
  }

  Rectangle {
    anchors.verticalCenter: track.verticalCenter
    x: root.zeroX - Math.max(1, Style.space(1)) / 2
    width: Math.max(1, Style.space(1))
    height: track.height + Style.space(4)
    color: root.rgba(root.foreground, 0.45)
  }

  BorderSurface {
    id: knob
    width: root.knobWidth
    height: root.knobHeight
    radius: Style.cornerRadius > 0 ? height / 2 : Math.max(1, Style.space(2))
    color: root.hot ? root.foreground : Qt.darker(root.foreground, 1.08)
    borderSpec: Border.flat(root.background, Math.max(1, Style.space(2)))
    anchors.verticalCenter: parent.verticalCenter
    x: root.knobCenterX - width / 2

    Behavior on x {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    // Right-click resets the band; without the right button here the branches
    // below never saw one.
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    onPressed: function(m) {
      if (m.button === Qt.RightButton) return
      root.forceActiveFocus()
      root.dragging = true
      var next = root.valueFromX(m.x)
      root.liveValue = next
      root.moved(next)
    }
    onPositionChanged: function(m) {
      if (!root.dragging) return
      var next = root.valueFromX(m.x)
      root.liveValue = next
      root.moved(next)
    }
    onReleased: function(m) {
      if (m.button === Qt.RightButton) { root.rightClicked(); return }
      if (!root.dragging) return
      root.dragging = false
      root.released(root.liveValue)
    }
    onWheel: function(wheel) {
      // Never rely on a declined wheel reaching the Flickable: accept it either
      // way, and scroll ourselves when the policy says the wheel is not ours.
      var dy = Model.wheelDelta(wheel.angleDelta.x, wheel.angleDelta.y, wheel.modifiers)
      if (!Model.wheelOwns("fader", wheel.modifiers, root.activeFocus, dy)) {
        if (root.scrollBy) root.scrollBy(-wheel.angleDelta.y / 2)
        wheel.accepted = true
        return
      }
      root.nudge(dy > 0 ? root.step : -root.step)
      wheel.accepted = true
    }
  }
}
