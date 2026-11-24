import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One band of the parametric equalizer: the four controls a band has to have to
// be worth calling parametric -- type, frequency, Q and gain -- plus its switch
// (Bypass), its audition (Solo) and its removal.
//
// Two shapes. In the Bands tab a band is a card of two lines: the number, the
// type, frequency and Q, Bypass, Solo and remove on top, and the gain slider
// with its readout the full width below, where it has room to be dragged. As
// the strip under the curve (`strip: true`) it is one line, with the gain as a
// readout only -- the curve's handle is the gain control there.
//
// The number matches the band's handle on the response curve, which is what
// ties the list to the drawing. It keeps its old shortcuts: a click bypasses
// the band (it keeps its values and shapes nothing), a right-click solos it.
//
// The text fields commit on Enter or on focus loss, never per keystroke, and
// an unchanged field commits nothing. The frequency takes kHz with a k
// ("2.5k"); ↑/↓ in a field nudge it (1/24 octave, a sixth of an octave of
// bandwidth for Q).
Item {
  id: root

  property int bandIndex: 0
  property real bandGain: 0
  property real bandFreq: 1000
  property real bandQ: 1.0
  property string bandType: "peaking"
  property bool bandEnabled: true
  property int bandSlope: 1
  property bool soloed: false
  // One line, no slider: the editor for the selected band under the curve.
  property bool strip: false

  property QtObject bar: null
  // Wheel scroll passthrough for this row's gain slider, injected by the panel.
  property var scrollBy: null
  property color foreground: bar ? bar.foreground : Color.foreground
  property color accent: Color.accent
  property color background: bar ? bar.background : Color.background
  // Secondary text, at the dimmest shade that still reads (Model.dimColor).
  property color dimText: Qt.darker(foreground, 1.5)
  property bool removable: false
  property bool showGain: Model.typeHasGain(bandType)

  signal gainChanged(real gain)
  signal gainCommitted(real gain)
  signal freqCommitted(real freq)
  signal qCommitted(real q)
  // The picker's value: a type, or "type:slope" for a steeper pass filter.
  signal typeChanged(string type)
  signal enabledToggled(bool enabled)
  signal soloToggled()
  signal removeRequested()

  // The row's own copy of the gain, so the readout tracks the slider during a
  // drag instead of waiting for the panel to read state back from the backend.
  property real liveGain: 0

  readonly property color dim: dimText
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int badgeSize: Math.max(16, Style.font.caption + Style.space(6))
  readonly property int fieldHeight: Math.max(Style.spacing.controlHeight, Style.font.body + Style.spacing.inputPaddingY * 2)
  readonly property real gap: Style.space(6)
  readonly property real lineHeight: Math.max(root.fieldHeight, removeButton.implicitHeight)
  // The gain range: ±12 dB, or ±24 dB for a band already outside that, so an
  // imported -15 dB cut is shown and kept, never clamped by a touch.
  readonly property real gainSpan: Model.gainSpan(bandGain)

  implicitHeight: strip
    ? lineHeight + Style.space(10)
    : lineHeight + gap + gainSlider.implicitHeight + Style.space(14)
  opacity: enabled ? 1.0 : 0.6
  // A bypassed band's controls stay usable (that is how it is tuned before it is
  // switched back on) but read as out of the chain.
  readonly property real controlsOpacity: bandEnabled ? 1.0 : 0.45

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function freqText(hz) { return Model.formatFreqField(hz) }
  function qText(q) { return String(Math.round((Number(q) || 1) * 100) / 100) }

  function commitFreq() {
    var text = String(freqField.text).trim()
    // A field left as it was is not an edit (its "1.25k" is rounded).
    if (text === freqText(bandFreq)) return
    var value = Model.parseFreqText(text)
    if (!isFinite(value)) { freqField.text = freqText(bandFreq); return }
    value = Math.round(Math.max(20, Math.min(20000, value)))
    freqField.text = freqText(value)
    root.freqCommitted(value)
  }

  function commitQ() {
    var text = String(qField.text).trim()
    if (text === qText(bandQ)) return
    var value = Number(text)
    if (!isFinite(value) || value <= 0) { qField.text = qText(bandQ); return }
    value = Math.round(Math.max(0.1, Math.min(30, value)) * 100) / 100
    qField.text = qText(value)
    root.qCommitted(value)
  }

  onBandGainChanged: liveGain = bandGain
  Component.onCompleted: liveGain = bandGain

  // The card the row sits on: one surface per band, lit while the pointer is
  // anywhere over it, so the row reads as a unit rather than loose fields.
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

  // The top line's vertical centre, for every control on it.
  Item {
    id: topLine
    x: 0
    y: Style.space(5)
    width: parent.width
    height: root.lineHeight
  }

  // ---- index badge: click bypasses, right-click solos (the buttons say so) ----
  BorderSurface {
    id: badge
    width: root.badgeSize
    height: root.badgeSize
    radius: root.badgeSize / 2
    color: root.soloed ? root.accent
      : root.bandEnabled ? root.rgba(root.foreground, badgeMouse.containsMouse ? 0.22 : 0.10)
      : "transparent"
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: topLine.verticalCenter

    Text {
      textFormat: Text.PlainText
      text: String(root.bandIndex + 1)
      color: root.soloed ? root.background : root.foreground
      opacity: root.bandEnabled ? 0.85 : 0.4
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.strikeout: !root.bandEnabled
      anchors.centerIn: parent
    }

    MouseArea {
      id: badgeMouse
      anchors.fill: parent
      anchors.margins: -Style.space(3)
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.soloToggled()
        else root.enabledToggled(!root.bandEnabled)
      }
    }

    PanelToolTip {
      visible: badgeMouse.containsMouse
      text: "Band " + (root.bandIndex + 1) + " · click to " + (root.bandEnabled ? "bypass" : "switch back on")
        + " · right-click to " + (root.soloed ? "stop soloing" : "hear it alone")
      fontFamily: root.fontFamily
    }
  }

  // ---- type: takes what the fixed controls to its right leave ----
  Dropdown {
    id: typeDropdown
    showLabel: false
    opacity: root.controlsOpacity
    value: Model.typeOptionValue(root.bandType, root.bandSlope)
    options: Model.bandTypeOptions
    foreground: root.foreground
    background: root.background
    anchors.left: badge.right
    anchors.leftMargin: root.gap
    anchors.right: freqField.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: topLine.verticalCenter
    onChanged: function(v) { root.typeChanged(v) }
  }

  // ---- frequency ----
  KeyField {
    id: freqField
    width: Style.space(54)
    height: root.fieldHeight
    foreground: root.foreground
    horizontalAlignment: Text.AlignRight
    horizontalPadding: Style.space(7)
    placeholderText: "Hz"
    allowedCharacters: /[0-9.kK]/
    maximumLength: 7
    steppable: true
    value: root.freqText(root.bandFreq)
    anchors.right: qField.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: topLine.verticalCenter
    onAccepted: root.commitFreq()
    onEditingFinished: root.commitFreq()
    onStepRequested: function(direction) {
      var next = Model.stepFreq(root.bandFreq, direction)
      text = root.freqText(next)
      root.freqCommitted(next)
    }

    PanelToolTip {
      visible: freqField.hovered && !freqField.activeFocus
      text: "Frequency in Hz, or kHz with a k (2.5k) · ↑/↓ move it 1/24 octave"
      fontFamily: root.fontFamily
    }
  }

  // ---- Q ----
  KeyField {
    id: qField
    width: Style.space(44)
    height: root.fieldHeight
    foreground: root.foreground
    horizontalAlignment: Text.AlignRight
    horizontalPadding: Style.space(7)
    placeholderText: "Q"
    allowedCharacters: /[0-9.]/
    maximumLength: 5
    steppable: true
    value: root.qText(root.bandQ)
    anchors.right: root.strip ? gainChip.left : bypassButton.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: topLine.verticalCenter
    onAccepted: root.commitQ()
    onEditingFinished: root.commitQ()
    onStepRequested: function(direction) {
      var next = Model.stepQ(root.bandQ, direction)
      text = root.qText(next)
      root.qCommitted(next)
    }

    PanelToolTip {
      visible: qField.hovered && !qField.activeFocus
      text: "Q: higher is narrower · ↑/↓ step a sixth of an octave"
      fontFamily: root.fontFamily
    }
  }

  // ---- gain readout, as a chip so the number reads as a value, not as another
  // label competing with the fields either side. On the strip it sits on the
  // line; in the Bands tab it ends the slider's line. ----
  BorderSurface {
    id: gainChip
    width: Math.max(Style.space(46), gainValue.implicitWidth + Style.space(12))
    height: Style.font.caption + Style.space(9)
    radius: Style.cornerRadius > 0 ? height / 2 : Math.max(1, Style.space(2))
    color: root.showGain && Math.abs(root.liveGain) >= 0.05
      ? root.rgba(root.accent, 0.18)
      : root.rgba(root.foreground, 0.06)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
    anchors.right: root.strip ? bypassButton.left : parent.right
    anchors.rightMargin: root.strip ? root.gap : Style.space(8)
    anchors.verticalCenter: root.strip ? topLine.verticalCenter : gainSlider.verticalCenter

    Text {
      id: gainValue
      textFormat: Text.PlainText
      text: root.showGain ? Model.formatGain(root.liveGain) : "—"
      color: root.showGain ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.centerIn: parent
    }
  }

  // ---- Bypass and Solo, labelled: the badge's clicks, where they can be seen ----
  Button {
    id: bypassButton
    text: root.bandEnabled ? "Bypass" : "Bypassed"
    bordered: true
    selected: !root.bandEnabled
    fontSize: Style.font.caption
    horizontalPadding: Style.space(6)
    foreground: root.foreground
    height: root.fieldHeight
    anchors.right: soloButton.left
    anchors.rightMargin: Style.space(4)
    anchors.verticalCenter: topLine.verticalCenter
    tooltipText: root.bandEnabled
      ? "Take band " + (root.bandIndex + 1) + " out (b); it keeps its values"
      : "Put band " + (root.bandIndex + 1) + " back (b)"
    onClicked: root.enabledToggled(!root.bandEnabled)
  }

  Button {
    id: soloButton
    text: "Solo"
    bordered: true
    selected: root.soloed
    fontSize: Style.font.caption
    horizontalPadding: Style.space(6)
    foreground: root.soloed ? root.accent : root.foreground
    height: root.fieldHeight
    anchors.right: removeButton.left
    anchors.rightMargin: Style.space(4)
    anchors.verticalCenter: topLine.verticalCenter
    tooltipText: root.soloed ? "Hear every band again (s)" : "Hear band " + (root.bandIndex + 1) + " alone (s)"
    onClicked: root.soloToggled()
  }

  Button {
    id: removeButton
    visible: root.removable
    width: visible ? implicitWidth : 0
    height: root.fieldHeight
    text: ""
    iconText: "󰅙"
    bordered: true
    horizontalPadding: Style.space(6)
    foreground: hot ? Color.urgent : root.foreground
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: topLine.verticalCenter
    // The kit Button renders its own tooltip; only controls without one need
    // PanelToolTip. (A Button exposes `hot`, not `containsMouse`.)
    tooltipText: "Remove this band (Delete)"
    onClicked: root.removeRequested()
  }

  // ---- gain, the full width of its own line (Bands tab only) ----
  HorizontalGainSlider {
    id: gainSlider
    visible: !root.strip
    anchors.left: badge.left
    anchors.right: gainChip.left
    anchors.rightMargin: Style.space(10)
    y: topLine.y + topLine.height + root.gap
    bar: root.bar
    accent: root.accent
    minimum: -root.gainSpan
    maximum: root.gainSpan
    step: 0.5
    value: root.bandGain
    opacity: (root.showGain ? 1.0 : 0.3) * root.controlsOpacity
    enabled: root.showGain && !root.strip
    scrollBy: root.scrollBy
    onMoved: function(v) { root.liveGain = v; root.gainChanged(v) }
    onReleased: function(v) { root.liveGain = v; root.gainCommitted(v) }
    onRightClicked: root.gainCommitted(0)
  }
}
