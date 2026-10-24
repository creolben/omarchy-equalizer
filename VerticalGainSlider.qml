import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Vertical fader for the graphic equalizer face: a recessed track with a dB
// scale, a fill that grows out of the 0 dB line, and a fader cap to grab.
//
// Bipolar by construction: 0 dB is the origin, so a cut fills downward and a
// boost upward, instead of a bottom-up bar that reads as more for a cut.
Item {
  id: root

  property real gain: 0
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
  property int knobSize: Math.max(10, Style.space(12))
  readonly property int capWidth: Math.max(12, Math.min(width - Style.space(6), Style.space(26)))
  readonly property int trackWidth: Math.max(4, Style.space(6))

  readonly property alias containsMouse: mouse.containsMouse
  property bool dragging: false
  property real liveGain: gain
  readonly property bool hot: containsMouse || dragging || activeFocus

  signal gainMoved(real gain)
  signal gainCommitted(real gain)
  signal resetRequested()

  onGainChanged: if (!dragging) liveGain = gain

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveGain - minimum) / range))
  readonly property real zeroProgress: Math.max(0, Math.min(1, (0 - minimum) / range))

  // The track is inset by half a cap so the cap never overhangs either end.
  readonly property real trackTop: knobSize / 2
  readonly property real trackLength: Math.max(1, height - knobSize)
  readonly property real knobCenterY: trackTop + (1 - progress) * trackLength
  readonly property real zeroY: trackTop + (1 - zeroProgress) * trackLength

  readonly property var tickValues: {
    var out = []
    for (var v = Math.ceil(minimum / 6) * 6; v <= maximum + 0.001; v += 6) out.push(v)
    return out
  }

  implicitWidth: Style.space(30)
  implicitHeight: Style.space(150)
  // Focus is click-only: ten tab stops through the plot would be worse than
  // none. A click arms the wheel and reveals the ring below.
  activeFocusOnTab: false

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function gainFromY(y) {
    var t = Math.max(0, Math.min(1, (y - trackTop) / trackLength))
    var raw = maximum - t * range
    return Math.max(minimum, Math.min(maximum, Math.round(raw / step) * step))
  }

  function nudge(delta) {
    var next = Math.max(minimum, Math.min(maximum, liveGain + delta))
    liveGain = next
    root.gainMoved(next)
    root.gainCommitted(next)
  }

  Keys.onUpPressed: nudge(step)
  Keys.onDownPressed: nudge(-step)
  Keys.onReturnPressed: root.resetRequested()
  Keys.onEnterPressed: root.resetRequested()

  // Scale ticks every 6 dB. The 0 dB tick spans the cap, so the shared zero
  // line reads straight across all ten faders.
  Repeater {
    model: root.tickValues
    Rectangle {
      required property var modelData
      readonly property bool zero: Math.abs(Number(modelData)) < 0.001
      width: zero ? root.capWidth + Style.space(4) : root.trackWidth + Style.space(8)
      height: Math.max(1, Style.space(1))
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.trackTop + (1 - (Number(modelData) - root.minimum) / root.range) * root.trackLength - height / 2
      color: root.rgba(root.foreground, zero ? 0.45 : 0.16)
    }
  }

  Rectangle {
    id: track
    width: root.trackWidth
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.trackTop
    height: root.trackLength
    radius: width / 2
    color: root.rgba(root.foreground, 0.08)
    border.width: 1
    border.color: root.rgba(root.foreground, 0.06)
  }

  // Focus is what arms the wheel, so it has to be visible. Hover stays
  // cosmetic (the halo and chip below); this ring is only activeFocus.
  Rectangle {
    anchors.centerIn: track
    width: root.capWidth + Style.space(8)
    height: track.height + Style.space(8)
    radius: Math.min(width, height) / 2
    color: "transparent"
    border.width: Math.max(1, Style.space(2))
    border.color: root.rgba(root.accent, 0.4)
    visible: root.activeFocus
  }

  Rectangle {
    id: fill
    width: track.width
    anchors.horizontalCenter: track.horizontalCenter
    radius: width / 2
    y: Math.min(root.knobCenterY, root.zeroY)
    height: Math.max(0, Math.abs(root.knobCenterY - root.zeroY))
    color: root.accent
    opacity: root.hot ? 1.0 : (root.liveGain < 0 ? 0.6 : 0.85)
    Behavior on opacity { NumberAnimation { duration: 120 } }
  }

  // Soft halo while the fader is hovered, focused or dragged.
  Rectangle {
    anchors.centerIn: knob
    width: knob.width + Style.space(8)
    height: knob.height + Style.space(8)
    radius: knob.radius > 0 ? knob.radius + Style.space(4) : 0
    color: root.rgba(root.accent, root.dragging ? 0.28 : 0.16)
    visible: root.hot
  }

  BorderSurface {
    id: knob
    width: root.capWidth
    height: root.knobSize
    radius: Style.cornerRadius > 0 ? height / 2 : Math.max(1, Style.space(2))
    color: root.hot ? root.foreground : Qt.darker(root.foreground, 1.08)
    borderSpec: Border.flat(root.background, Math.max(1, Style.space(2)))
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.knobCenterY - height / 2

    // Grip line, the way a hardware fader cap is marked.
    Rectangle {
      anchors.centerIn: parent
      width: Math.round(parent.width * 0.45)
      height: Math.max(1, Style.space(2))
      radius: height / 2
      color: root.rgba(root.background, 0.55)
    }

    Behavior on y {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }

  // The value rides with the cap, flipped to whichever side of it has room: the
  // number being set belongs next to the thing being moved, not only in the row
  // of values above the bank.
  Rectangle {
    id: valueChip
    readonly property real above: knob.y - height - Style.space(3)
    visible: root.hot
    width: chipText.implicitWidth + Style.space(10)
    height: chipText.implicitHeight + Style.space(6)
    radius: Style.cornerRadius
    color: root.rgba(root.background, 0.92)
    border.width: 1
    border.color: root.rgba(root.accent, 0.5)
    x: Math.round(knob.x + knob.width / 2 - width / 2)
    y: above < 0 ? knob.y + knob.height + Style.space(3) : above
    z: 2

    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: Model.formatGain(root.liveGain)
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onPressed: function(m) {
      root.forceActiveFocus()
      root.dragging = true
      var next = root.gainFromY(m.y)
      root.liveGain = next
      root.gainMoved(next)
    }
    onPositionChanged: function(m) {
      if (!root.dragging) return
      var next = root.gainFromY(m.y)
      root.liveGain = next
      root.gainMoved(next)
    }
    onReleased: {
      if (!root.dragging) return
      root.dragging = false
      root.gainCommitted(root.liveGain)
    }
    // The second press of a double-click starts a drag like any press; end it
    // here, or its release commits the pressed position over the reset.
    onDoubleClicked: {
      root.dragging = false
      root.liveGain = 0
      root.resetRequested()
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
