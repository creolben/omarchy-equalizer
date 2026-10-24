import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One band of the parametric equalizer: the four controls a band has to have to
// be worth calling parametric -- type, frequency, Q and gain -- laid out as a
// single row so a whole set can be read at a glance and compared.
//
// The row is a card: a numbered badge, then type, gain, frequency, Q, then the
// removal. The number matches the band's handle on the response curve, which is
// what ties the list to the drawing.
//
// The text fields commit on Enter or on focus loss, never per keystroke: each
// commit crosses a process boundary into the backend, and a rebuild of the
// filter graph for frequency/type changes, so typing "1000" must not fire four
// rebuilds.
Item {
  id: root

  property int bandIndex: 0
  property real bandGain: 0
  property real bandFreq: 1000
  property real bandQ: 1.0
  property string bandType: "peaking"

  property QtObject bar: null
  // Wheel scroll passthrough for this row's gain slider, injected by the panel.
  property var scrollBy: null
  property color foreground: bar ? bar.foreground : Color.foreground
  property color accent: Color.accent
  property color background: bar ? bar.background : Color.background
  property bool removable: false
  property bool showGain: Model.typeHasGain(bandType)

  signal gainChanged(real gain)
  signal gainCommitted(real gain)
  signal freqCommitted(real freq)
  signal qCommitted(real q)
  signal typeChanged(string type)
  signal removeRequested()

  // The row's own copy of the gain, so the readout tracks the slider during a
  // drag instead of waiting for the panel to read state back from the backend.
  property real liveGain: 0

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property int badgeSize: Math.max(16, Style.font.caption + Style.space(6))
  readonly property int fieldHeight: Math.max(Style.spacing.controlHeight, Style.font.body + Style.spacing.inputPaddingY * 2)

  implicitHeight: Math.max(root.fieldHeight, removeButton.implicitHeight) + Style.space(10)
  opacity: enabled ? 1.0 : 0.6

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function commitFreq() {
    var value = Number(String(freqField.text).trim())
    if (!isFinite(value) || value <= 0) { freqField.text = String(Math.round(bandFreq)); return }
    value = Math.max(20, Math.min(20000, value))
    freqField.text = String(Math.round(value))
    root.freqCommitted(value)
  }

  function commitQ() {
    var value = Number(String(qField.text).trim())
    if (!isFinite(value) || value <= 0) { qField.text = String(bandQ); return }
    value = Math.max(0.1, Math.min(30, value))
    qField.text = String(value)
    root.qCommitted(value)
  }

  onBandGainChanged: liveGain = bandGain
  Component.onCompleted: liveGain = bandGain

  // The card the row sits on: one surface per band, lit while the pointer is
  // anywhere over it, so the row reads as a unit rather than five loose fields.
  BorderSurface {
    id: card
    anchors.fill: parent
    radius: Style.cornerRadius
    color: rowMouse.containsMouse || gainSlider.dragging
      ? root.rgba(root.foreground, 0.055)
      : root.rgba(root.foreground, 0.025)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

    Behavior on color { ColorAnimation { duration: 120 } }
  }

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  // ---- index badge ----
  BorderSurface {
    id: badge
    width: root.badgeSize
    height: root.badgeSize
    radius: root.badgeSize / 2
    color: root.rgba(root.foreground, 0.10)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter

    Text {
      textFormat: Text.PlainText
      text: String(root.bandIndex + 1)
      color: root.foreground
      opacity: 0.85
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.centerIn: parent
    }
  }

  // ---- type ----
  Dropdown {
    id: typeDropdown
    width: Style.space(114)
    showLabel: false
    value: root.bandType
    options: Model.bandTypes
    foreground: root.foreground
    background: root.background
    anchors.left: badge.right
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    onChanged: function(v) { root.typeChanged(v) }
  }

  // ---- gain ----
  Item {
    id: gainCell
    anchors.left: typeDropdown.right
    anchors.leftMargin: Style.space(12)
    anchors.right: gainChip.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    height: gainSlider.implicitHeight

    HorizontalGainSlider {
      id: gainSlider
      anchors.fill: parent
      bar: root.bar
      accent: root.accent
      minimum: -12
      maximum: 12
      step: 0.5
      value: root.bandGain
      opacity: root.showGain ? 1.0 : 0.3
      enabled: root.showGain
      scrollBy: root.scrollBy
      onMoved: function(v) { root.liveGain = v; root.gainChanged(v) }
      onReleased: function(v) { root.liveGain = v; root.gainCommitted(v) }
      onRightClicked: root.gainCommitted(0)
    }
  }

  // ---- gain readout, as a chip so the number reads as a value, not as another
  // label competing with the fields either side ----
  BorderSurface {
    id: gainChip
    width: Math.max(Style.space(52), gainValue.implicitWidth + Style.space(14))
    height: Style.font.caption + Style.space(9)
    radius: Style.cornerRadius > 0 ? height / 2 : Math.max(1, Style.space(2))
    color: root.showGain && Math.abs(root.liveGain) >= 0.05
      ? root.rgba(root.accent, 0.18)
      : root.rgba(root.foreground, 0.06)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
    anchors.right: freqField.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter

    Text {
      id: gainValue
      textFormat: Text.PlainText
      text: root.showGain ? Model.formatGain(root.liveGain) : "—"
      color: root.showGain ? root.foreground : root.dim
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.centerIn: parent
    }
  }

  // ---- frequency ----
  KeyField {
    id: freqField
    width: Style.space(66)
    height: root.fieldHeight
    foreground: root.foreground
    horizontalAlignment: Text.AlignRight
    placeholderText: "Hz"
    allowedCharacters: /[0-9.]/
    maximumLength: 7
    value: String(Math.round(root.bandFreq))
    anchors.right: qField.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    onAccepted: root.commitFreq()
    onEditingFinished: root.commitFreq()
  }

  // ---- Q ----
  KeyField {
    id: qField
    width: Style.space(56)
    height: root.fieldHeight
    foreground: root.foreground
    horizontalAlignment: Text.AlignRight
    placeholderText: "Q"
    allowedCharacters: /[0-9.]/
    maximumLength: 5
    value: String(root.bandQ)
    anchors.right: removeButton.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    onAccepted: root.commitQ()
    onEditingFinished: root.commitQ()
  }

  Button {
    id: removeButton
    visible: root.removable
    width: visible ? implicitWidth : 0
    height: root.fieldHeight
    text: ""
    iconText: "󰅙"
    bordered: true
    foreground: hot ? Color.urgent : root.foreground
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    // The kit Button renders its own tooltip; only controls without one need
    // PanelToolTip. (A Button exposes `hot`, not `containsMouse`.)
    tooltipText: "Remove this band"
    onClicked: root.removeRequested()
  }
}
