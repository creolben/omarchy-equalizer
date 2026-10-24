import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The preamp is horizontal, so its track, fill and knob are a copy of the
// shell's PanelSlider at the same metrics and colours. Owning the component is
// what lets the plugin apply its input policy: a vertical wheel over a
// horizontal control is never a deliberate edit, so the wheel scrolls the
// panel instead of moving the preamp. Dragging and the arrow keys still edit.
Item {
  id: root

  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property color trackColor: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "#333"
  property color fillColor: bar ? bar.foreground : Color.foreground
  property color knobColor: bar ? bar.foreground : Color.foreground
  property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  // Injected by the panel: moves the enclosing scroll area. Without it the
  // declined wheel still does nothing to the preamp.
  property var scrollBy: null
  // The panel owns the ceiling, so it also owns the sentence that explains it.
  property string tooltipText: ""
  property string tooltipFontFamily: Style.font.family

  property bool dragging: false
  property real liveValue: value

  signal moved(real value)
  signal released(real value)
  signal rightClicked()

  onValueChanged: if (!dragging) liveValue = value

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
  readonly property bool hot: mouseArea.containsMouse || root.dragging

  // Focus is click-only: a click arms the arrow keys and reveals the ring.
  activeFocusOnTab: false

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function nudge(delta) {
    var size = Number(root.step) > 0 ? Number(root.step) : 0.5
    var next = Math.max(root.minimum, Math.min(root.maximum, root.liveValue + delta))
    next = Math.round(next / size) * size
    root.liveValue = next
    root.moved(next)
    root.released(next)
  }

  Keys.onLeftPressed: nudge(-step)
  Keys.onRightPressed: nudge(step)

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    height: root.trackHeight
    radius: height / 2
    color: root.trackColor
  }

  // Focus is what arms the arrow keys, so it has to be visible. Hover stays
  // cosmetic (the knob's scale below); this ring is only activeFocus.
  Rectangle {
    anchors.fill: track
    anchors.topMargin: -Style.space(4)
    anchors.bottomMargin: -Style.space(4)
    radius: height / 2
    color: "transparent"
    border.width: Math.max(1, Style.space(2))
    border.color: root.rgba(Color.accent, 0.4)
    visible: root.activeFocus
  }

  Rectangle {
    id: fill
    anchors.verticalCenter: track.verticalCenter
    anchors.left: track.left
    height: track.height
    radius: track.radius
    color: root.fillColor
    width: track.width * root.progress

    Behavior on width {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }

  BorderSurface {
    id: knob
    width: root.knobSize
    height: root.knobSize
    radius: root.knobSize / 2
    color: root.knobColor
    borderSpec: Border.flat(root.bar ? root.bar.background : "#101315", Math.max(1, Style.space(2)))
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progress - width / 2))
    scale: root.hot ? 1.15 : 1.0

    Behavior on x {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    function valueFromX(x) {
      var size = Number(root.step) > 0 ? Number(root.step) : 0.5
      var clamped = Math.max(0, Math.min(track.width, x))
      var raw = root.minimum + (clamped / track.width) * root.range
      raw = Math.round(raw / size) * size
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.forceActiveFocus()
      root.dragging = true
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.rightClicked()
    }
    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }
    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = false
      root.released(root.liveValue)
      root.liveValue = root.value
    }
    onWheel: function(wheel) {
      // A horizontal control under a vertical wheel is never a deliberate edit:
      // the policy always declines "preamp", so the wheel belongs to the panel.
      // Accepting in both outcomes keeps it from also reaching the Flickable.
      if (!Model.wheelOwns("preamp", wheel.modifiers, root.activeFocus, wheel.angleDelta.y)) {
        if (root.scrollBy) root.scrollBy(-wheel.angleDelta.y / 2)
      }
      wheel.accepted = true
    }
  }

  PanelToolTip {
    visible: mouseArea.containsMouse && root.tooltipText !== ""
    text: root.tooltipText
    fontFamily: root.tooltipFontFamily
  }
}
