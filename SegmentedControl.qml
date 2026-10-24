import QtQuick
import qs.Commons

// Segmented control: a recessed track with one raised segment, for picking
// between a small number of mutually exclusive views (the equalizer's 10-band
// and parametric modes).
//
// The kit's ButtonGroup is a row of separately-bordered chips, which reads as
// three unrelated buttons rather than one control with one active setting. Here
// the track is one surface and the selection is a single raised pill that slides
// between segments.
Item {
  id: root

  // [{ value, label, icon? }] or plain strings, like the kit's ButtonGroup.
  property var options: []
  property string value: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: Color.background
  property bool focusable: true
  property int cursorIndex: -1
  // A caller that needs a specific cell width (the card-wide tab bar) can ask
  // for one; otherwise the cells size themselves to the labels below.
  property int cellWidthOverride: 0
  property real fontSize: Style.font.body

  signal changed(string value)
  signal hovered(int index, bool isHovered)

  readonly property int segmentCount: options ? options.length : 0
  // Cells size themselves to their own labels when no override is given. A
  // fixed cell narrower than its text centres the label and spills it onto
  // both neighbours -- "Parametric" over "10-band" -- because nothing clips
  // inside a segment. The widest label, measured bold (a theme may not use a
  // mono face), sizes every cell so the segments stay equal.
  readonly property real widestLabel: {
    var w = 0
    for (var i = 0; i < segmentCount; i++) {
      var advance = labelMetrics.advanceWidth(optionLabel(options[i]))
      if (optionIcon(options[i]) !== "") advance += Style.font.iconSmall + Style.space(6)
      w = Math.max(w, advance)
    }
    return w
  }
  readonly property int cellWidth: segmentCount > 0
    ? (cellWidthOverride > 0
      ? Math.max(Style.space(36), Math.round(cellWidthOverride))
      : Math.ceil(widestLabel) + Style.space(20))
    : 0
  readonly property int cellHeight: Math.max(Style.spacing.controlHeight, fontSize + Style.spacing.controlPaddingY * 2)
  readonly property real padding: Math.max(2, Style.space(2))
  readonly property int selectedIndex: {
    for (var i = 0; i < segmentCount; i++) if (optionValue(options[i]) === value) return i
    return -1
  }

  implicitWidth: segmentCount * cellWidth + padding * 2
  implicitHeight: cellHeight + padding * 2
  activeFocusOnTab: focusable

  function optionValue(o) { return (o && typeof o === "object") ? String(o.value) : String(o) }
  function optionLabel(o) { return (o && typeof o === "object" && o.label !== undefined) ? String(o.label) : String(o) }
  function optionIcon(o) { return (o && typeof o === "object" && o.icon) ? String(o.icon) : "" }

  Keys.onLeftPressed: move(-1)
  Keys.onRightPressed: move(1)
  Keys.onReturnPressed: activate()
  Keys.onEnterPressed: activate()
  Keys.onSpacePressed: activate()

  function move(delta) {
    if (segmentCount === 0) return
    var from = selectedIndex < 0 ? 0 : selectedIndex
    var next = Math.max(0, Math.min(segmentCount - 1, from + delta))
    if (next === selectedIndex) return
    root.changed(optionValue(options[next]))
  }

  function activate() {
    if (selectedIndex >= 0) root.changed(optionValue(options[selectedIndex]))
  }

  Rectangle {
    id: track
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? height / 2 : Math.max(1, Style.space(2))
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
  }

  // The measure for widestLabel: same family and size as the segment text,
  // bold, because the selected segment's label is bold.
  FontMetrics {
    id: labelMetrics
    font.family: Style.font.family
    font.pixelSize: root.fontSize
    font.bold: true
  }

  // The selected segment. Slides rather than jumping, so the eye can follow
  // which way the choice moved.
  Rectangle {
    id: indicator
    visible: root.selectedIndex >= 0
    width: root.cellWidth
    height: root.cellHeight
    radius: Style.cornerRadius > 0 ? height / 2 : Math.max(1, Style.space(2))
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
    x: root.padding + Math.max(0, root.selectedIndex) * root.cellWidth
    y: root.padding

    Behavior on x { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
  }

  Row {
    anchors.fill: parent
    anchors.margins: root.padding
    spacing: 0

    Repeater {
      model: root.options

      Item {
        required property var modelData
        required property int index
        width: root.cellWidth
        height: root.cellHeight

        readonly property bool selected: index === root.selectedIndex
        readonly property bool hot: segmentMouse.containsMouse
          || root.cursorIndex === index
          || (root.activeFocus && root.selectedIndex === index)

        Text {
          id: segmentIcon
          textFormat: Text.PlainText
          visible: text !== ""
          text: root.optionIcon(modelData)
          color: parent.selected ? root.foreground : Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.iconSmall
          anchors.verticalCenter: parent.verticalCenter
          x: parent.width / 2 - (segmentLabel.visible
            ? (segmentLabel.implicitWidth + width + Style.space(6)) / 2
            : width / 2)
        }

        Text {
          id: segmentLabel
          textFormat: Text.PlainText
          text: root.optionLabel(modelData)
          color: parent.selected
            ? root.foreground
            : Qt.darker(root.foreground, segmentMouse.containsMouse ? 1.15 : 1.5)
          font.family: Style.font.family
          font.pixelSize: root.fontSize
          font.bold: parent.selected
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: segmentIcon.visible ? segmentIcon.right : undefined
          anchors.leftMargin: segmentIcon.visible ? Style.space(6) : 0
          anchors.horizontalCenter: segmentIcon.visible ? undefined : parent.horizontalCenter

          Behavior on color { ColorAnimation { duration: 120 } }
        }

        MouseArea {
          id: segmentMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: root.hovered(index, containsMouse)
          onClicked: root.changed(root.optionValue(modelData))
        }
      }
    }
  }
}
