import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The equalizer face: on/off, a mode switch, the band set, presets, and a live
// meter showing the result.
//
// State lives in the backend (bin/omarchy-equalizer), never in this file. Every
// control writes there and the panel re-reads the JSON status, so a preset saved
// from one session, or a band nudged from a terminal, shows up here unchanged.
Panel {
  id: root
  moduleName: "creolben.equalizer"
  ipcTarget: "creolben.equalizer"

  // Injected by BarWidget.qml.
  property Item anchorItem: null
  property QtObject hostWidget: null

  readonly property string helper: "omarchy-equalizer"

  property var status: null
  property bool busy: false
  property string error: ""
  property string saveName: ""
  property var actionQueue: []

  // The band being dragged sends its own gains at 30 ms; the backend's
  // live write is one pw-cli call, so this stays cheap.
  property int pendingBandIndex: -1
  property real pendingBandGain: 0
  property bool bandDirty: false

  readonly property bool enabled: status ? status.enabled === true : false
  readonly property string mode: status ? String(status.mode || "graphic") : "graphic"
  readonly property string preset: status ? String(status.preset || "Flat") : "Flat"
  readonly property var bands: status ? (status.bands || []) : []
  readonly property var presets: status ? (status.presets || []) : []
  readonly property int paramCount: status ? Number(status.parametricCount || 0) : 0
  readonly property bool sinkPresent: status ? status.sinkPresent === true : false
  readonly property string targetSink: status ? String(status.targetSink || "") : ""
  readonly property real preamp: status ? Number(status.preamp || 0) : 0
  // Gain staging and the output stage, all owned by the backend. Missing
  // fields read as the backend defaults (auto headroom, limiter on, boost off).
  readonly property string headroom: status ? String(status.headroom || "auto") : "auto"
  readonly property string limiter: status ? String(status.limiter || "on") : "on"
  readonly property string boost: status ? String(status.boost || "off") : "off"
  readonly property bool outputStage: status ? status.outputStage === true : false
  // The rate the graph instantiates the biquads with, reported by the backend:
  // the curve's frequency axis depends on it.
  readonly property int sampleRate: status ? Number(status.sampleRate || 48000) : 48000

  // The peak of the *shape* -- the line the handles sit on, measured with the
  // preamp at zero -- with the preamp named next to it, because those two are
  // what decide whether a boost can clip. A post-preamp peak would read "no
  // boost" on a curve that visibly boosts.
  readonly property string peakSummary: {
    if (!status) return ""
    if (!enabled) return "BYPASSED"
    var peak = Model.peakDb(bands, 0, sampleRate)
    if (peak.db <= 0.05)
      return Math.abs(preamp) >= 0.25
        ? "PEAK \u2264 0 dB · PREAMP " + preamp.toFixed(1)
        : "NO BOOST"
    var text = "+" + peak.db.toFixed(1) + " dB PEAK AT " + Model.formatFreq(peak.freq) + " HZ"
    if (Math.abs(preamp) >= 0.25) text += " · PREAMP " + (preamp > 0 ? "+" : "") + preamp.toFixed(1)
    return text
  }

  // AutoEq import: a query, whatever the profile index matched, and a line of
  // feedback so the panel never silently does nothing.
  property string autoeqQuery: ""
  property var autoeqResults: []
  property string autoeqMessage: ""
  property bool autoeqBusy: false
  property real preampPending: 0

  // The base Panel supplies barForeground (with a sane fallback for the moment
  // before the bar widget injects itself); the font family needs the same care.
  readonly property string barFontFamily: bar ? bar.fontFamily : Style.font.family

  // Filled glyph while the equalizer is processing, outline while bypassed --
  // the same distinction the bar icon makes.
  readonly property string equalizerGlyph: enabled ? "󰺢" : "󰺣"

  // Hero meta line: what is being shaped, and how much.
  readonly property string summary: {
    if (!status) return "READING STATE"
    if (!enabled) return "BYPASSED"
    var shaped = Model.shapedCount(bands)
    var label = mode === "parametric" ? "PARAMETRIC" : "10-BAND"
    if (shaped === 0) return label + " · FLAT"
    return label + " · " + shaped + (shaped === 1 ? " BAND" : " BANDS") + " ACTIVE"
  }

  readonly property string modeMeta: mode === "parametric"
    ? String(bands.length) + " bands, freely placed"
    : "31 Hz – 16 kHz, one octave per band"

  // The curve lives inside the popup window, which a walk of the bar widget's
  // children cannot reach, so it is exposed here for the headless harness (and
  // for anything else that needs to drive the curve without a pointer).
  readonly property var responseCurve: responseCurveItem

  function refresh() {
    // Not while an action is running: the backend's writes are in flight, and a
    // poll taken now would paint the values the local echo already replaced.
    if (statusProc.running || busy) return
    statusProc.running = true
  }

  // Actions queue instead of being thrown away: every panel action is a
  // subprocess, and an import or a preset apply takes long enough that a band
  // drag finishes while it is still running. Dropping the newer command left the
  // local echo and the backend disagreeing until the next poll snapped back.
  function run(args) {
    if (actionProc.running) {
      var key = actionKey(args)
      if (key !== "") {
        // A drag emits many commands for one target; only the last value matters.
        for (var i = 0; i < actionQueue.length; i++) {
          if (actionKey(actionQueue[i]) === key) { actionQueue[i] = args; return }
        }
      }
      actionQueue.push(args)
      return
    }
    startAction(args)
  }

  // Repeatable commands (a drag's worth of values) can collapse to one entry.
  // Everything else -- presets, mode, import -- is a distinct action in order.
  function actionKey(args) {
    var name = String(args[0] || "")
    if (name === "set-gain" || name === "set-band" || name === "set-preamp")
      return name + ":" + String(args[1] || "")
    return ""
  }

  function startAction(args) {
    error = ""
    busy = true
    actionProc.command = [helper].concat(args)
    actionProc.running = true
  }

  function pumpActions() {
    if (actionQueue.length === 0) return false
    startAction(actionQueue.shift())
    return true
  }

  function applyStatus(text) {
    var parsed = Model.parseStatus(text)
    // Guard against the other commands' JSON: import-autoeq prints a summary
    // object, and letting that replace the status would empty the panel.
    if (!parsed || !(parsed.bands instanceof Array) || parsed.presets === undefined) return
    status = parsed
  }

  // Local echo: a slider that waits for a subprocess round trip feels broken on
  // a fast drag.
  function withStatus(overrides) {
    var next = {}
    var base = status || {}
    for (var key in base) next[key] = base[key]
    for (var over in overrides) next[over] = overrides[over]
    status = next
  }

  function commitPreamp(db) {
    preampPending = Model.clamp(db, -24, 12)
    preampCommitTimer.restart()
  }

  function sendPreampNow(db) {
    // PanelSlider only snaps when `integer` is set, so a drag hands over raw
    // positions like -8.7079. Snap to the slider's 0.5 dB step here, the one
    // place every preamp write passes through.
    var value = Math.round(Model.clamp(db, -24, 12) * 2) / 2
    // A hand-set preamp is the backend's cue to stop tracking the curve.
    withStatus({ preamp: value, headroom: "manual" })
    run(["set-preamp", String(value)])
  }

  // One click: preamp = minus the curve's peak boost (see Model.autoPreampDb).
  readonly property real autoPreamp: Model.autoPreampDb(bands, sampleRate)
  // Auto headroom: the backend recomputes the preamp from the curve's peak on
  // every edit (eqMac's peak limiter, done on the real response). Dragging the
  // preamp hands control back to the user.
  function setHeadroom(value) {
    var echo = { headroom: value }
    if (value === "auto") echo.preamp = autoPreamp
    withStatus(echo)
    run(["set-headroom", value])
  }
  function setLimiter(value) { withStatus({ limiter: value }); run(["set-limiter", value]) }
  function setBoost(value) { withStatus({ boost: value }); run(["set-boost", value]) }

  function searchAutoEq() {
    var query = String(autoeqQuery || "").trim()
    if (query === "") {
      autoeqMessage = "Type a headphone model to search AutoEq."
      return
    }
    autoeqResults = []
    autoeqMessage = "Searching AutoEq for “" + query + "”…"
    autoeqBusy = true
    autoeqSearchProc.command = [helper, "autoeq-search", "--json", query]
    autoeqSearchProc.running = true
  }

  function updateAutoEqResults(text) {
    var parsed = Model.parseJsonArray(text)
    autoeqResults = parsed
    if (parsed.length === 0) autoeqMessage = "No AutoEq profile matched that."
    else autoeqMessage = parsed.length + " profile" + (parsed.length === 1 ? "" : "s") + " found."
    autoeqBusy = false
  }

  // The profile path travels with the name: two sources can measure the same
  // headphone, and without the path the backend re-searches and re-ranks, which
  // can download a different measurement than the one that was picked.
  function importAutoEq(name, profilePath) {
    var target = String(name || "").trim()
    if (target === "") {
      autoeqMessage = "Search first, then pick a profile."
      return
    }
    var path = String(profilePath || "").trim()
    autoeqMessage = "Importing " + target + "…"
    var args = ["import-autoeq", target]
    if (path !== "") args.push(path)
    run(args)
  }

  function importAutoEqQuery() {
    importAutoEq(String(autoeqQuery || "").trim())
  }

  function autoeqOptions() {
    var options = []
    for (var i = 0; i < autoeqResults.length; i++) {
      var entry = autoeqResults[i]
      if (!entry || !entry.name) continue
      options.push({
        value: entry.name + "||" + entry.path,
        label: entry.name + (entry.source ? "  · " + entry.source : "")
      })
    }
    return options
  }

  function toggleEnabled() {
    run(["toggle"])
  }

  function setMode(next) {
    if (next === mode) return
    run(["set-mode", next])
  }

  function loadPreset(name) {
    if (name === "") return
    run(["apply-preset", name])
  }

  function resetBands() {
    run(["reset"])
  }

  function commitBand(index, gain) {
    pendingBandIndex = index
    pendingBandGain = Model.clamp(gain, -12, 12)
    bandCommitTimer.restart()
  }

  function sendBandNow(index, gain) {
    // Local echo first: a slider that waits for a subprocess round trip feels
    // broken on a fast drag.
    var next = bands.slice()
    if (next[index]) {
      next[index] = {
        type: next[index].type,
        freq: next[index].freq,
        q: next[index].q,
        gain: Model.clamp(gain, -12, 12)
      }
    }
    withStatus({ bands: next })
    run(["set-gain", String(index), String(Model.clamp(gain, -12, 12))])
  }

  function setBandProperty(index, key, value) {
    run(["set-band", String(index), key, String(value)])
  }

  function addBand() {
    run(["add-band"])
  }

  function removeBand(index) {
    run(["remove-band", String(index)])
  }

  function savePreset() {
    var name = String(saveName || "").trim()
    if (name === "") {
      error = "Name the preset first."
      return
    }
    saveName = ""
    run(["save-preset", name])
  }

  function deletePreset() {
    if (!isUserPreset(preset)) return
    run(["delete-preset", preset])
  }

  function isBuiltinPreset(name) {
    for (var i = 0; i < presets.length; i++)
      if (presets[i] && presets[i].name === name) return presets[i].builtin === true
    return false
  }

  // Only a preset that exists and is not built-in can be deleted. The state can
  // name a preset that is in neither list ("Custom", or one already deleted),
  // and isBuiltinPreset alone would call that deletable.
  function isUserPreset(name) {
    for (var i = 0; i < presets.length; i++)
      if (presets[i] && presets[i].name === name) return presets[i].builtin !== true
    return false
  }

  function presetOptions() {
    var options = []
    for (var i = 0; i < presets.length; i++) {
      if (!presets[i]) continue
      options.push({
        value: presets[i].name,
        label: presets[i].name + (presets[i].builtin ? "" : "  •")
      })
    }
    return options
  }

  onOpenedChanged: {
    if (opened) refresh()
  }

  // Status is re-read whenever the panel opens and after every action; the open
  // panel also polls slowly so an external change (a terminal, or the speaker
  // tuning being switched) is reflected without reopening.
  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.error = message
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0 && root.error === "") root.error = "The equalizer command failed."
      // Whatever was waiting runs next; the status read happens once the queue is
      // empty so a poll cannot land in the middle of a burst of writes.
      if (!root.pumpActions() && !statusProc.running) statusProc.running = true
    }
  }

  // A drag must not leave the backend mid-write when the mouse stops moving, so
  // the last pending value is flushed once motion settles.
  // Same settle-then-flush treatment as the band sliders.
  Timer {
    id: preampCommitTimer
    interval: 120
    repeat: false
    onTriggered: root.sendPreampNow(root.preampPending)
  }

  Process {
    id: autoeqSearchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateAutoEqResults(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") {
          root.autoeqMessage = message
          root.autoeqBusy = false
        }
      }
    }
  }

  Timer {
    id: bandCommitTimer
    interval: 120
    repeat: false
    onTriggered: {
      if (root.pendingBandIndex < 0) return
      root.sendBandNow(root.pendingBandIndex, root.pendingBandGain)
      root.pendingBandIndex = -1
    }
  }

  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Live output meter, in the hero. While the equalizer is on it watches the
  // filter-chain's own playback stream (omarchy_equalizer.output), i.e. the
  // signal AFTER the preamp and every band -- the only place a clipping boost
  // shows. Bypassed, it falls back to the default sink.
  readonly property var eqOutputNode: {
    var list = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].name) === "omarchy_equalizer.output") return list[i]
    return null
  }
  readonly property var sinkNode: (root.enabled && root.eqOutputNode) ? root.eqOutputNode : Pipewire.defaultAudioSink
  PwObjectTracker { objects: root.sinkNode ? [root.sinkNode] : [] }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.sinkNode
    enabled: root.opened && !!root.sinkNode
  }

  // A clip lasts milliseconds; the indicator holds it long enough to be seen.
  property bool clipHeld: false
  Connections {
    target: peakMonitor
    function onPeakChanged() {
      if (peakMonitor.peak > 0.98) { root.clipHeld = true; clipHoldTimer.restart() }
    }
  }
  Timer { id: clipHoldTimer; interval: 1500; onTriggered: root.clipHeld = false }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.toggleEnabled()
      onTextKey: function(t) {
        if (t === "e" || t === "E") root.toggleEnabled()
        else if (t === "m" || t === "M") root.setMode(root.mode === "graphic" ? "parametric" : "graphic")
        else if (t === "r" || t === "R") root.resetBands()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: contentColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.equalizerGlyph
              color: root.barForeground
              opacity: root.enabled ? 1.0 : 0.45
              font.family: root.barFontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Behavior on opacity { NumberAnimation { duration: 140 } }
            }

            PowerSwitch {
              id: powerSwitch
              checked: root.enabled
              busy: root.busy
              foreground: root.barForeground
              accent: Color.accent
              background: root.bar ? root.bar.background : Color.background
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleEnabled()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.enabled ? "Bypass the equalizer" : "Switch the equalizer on"
                fontFamily: root.barFontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Equalizer"
                color: root.barForeground
                font.family: root.barFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.summary
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // Meter: peak level leaving the equalizer (see eqOutputNode), with a
          // red CLIP hold when it hits full scale. Peak-only, because RMS in a
          // bar this small reads as noise.
          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.enabled

            Rectangle {
              width: parent.width - levelText.implicitWidth - Style.space(6)
              height: Math.max(4, Style.space(5))
              radius: height / 2
              color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.12)
              anchors.verticalCenter: parent.verticalCenter
              clip: true

              Rectangle {
                height: parent.height
                radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, peakMonitor.peak))
                color: (peakMonitor.peak > 0.98 || root.clipHeld)
                  ? Color.urgent
                  : root.barForeground

                Behavior on width { NumberAnimation { duration: 90 } }
              }
            }

            Text {
              id: levelText
              textFormat: Text.PlainText
              text: root.clipHeld ? "CLIP" : peakMonitor.peak > 0.001
                ? (Math.round(20 * Math.log(Math.max(peakMonitor.peak, 0.0001)) / Math.LN10) + " dB")
                : "—"
              color: root.clipHeld ? Color.urgent : Qt.darker(root.barForeground, 1.4)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSeparator { foreground: root.barForeground }

          // ---------- Mode ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            // The mode control owns its own row: side by side with its caption
            // the segmented track squeezed the text into an ellipsis.
            Column {
              width: parent.width
              spacing: Style.space(6)

              // Inside a Column the layout owns x/y, so this control must not
              // carry anchors of its own.
              SegmentedControl {
                id: modeGroup
                options: [
                  { value: "graphic", label: "10-Band" },
                  { value: "parametric", label: "Parametric" }
                ]
                value: root.mode
                foreground: root.barForeground
                accent: Color.accent
                background: root.bar ? root.bar.background : Color.background
                onChanged: function(v) { root.setMode(v) }
              }

              Text {
                textFormat: Text.PlainText
                text: root.modeMeta
                color: Qt.darker(root.barForeground, 1.6)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                elide: Text.ElideRight
              }
            }
          }

          // ---------- Response ----------
          // The curve the whole chain draws, from the same biquad formulas the
          // running filter-chain uses. It is the control as well as the readout:
          // a handle sets a band's gain, and its frequency in parametric mode.
          Column {
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: parent.width
              implicitHeight: Math.max(responseHeader.implicitHeight, peakLabel.implicitHeight)

              PanelSectionHeader {
                id: responseHeader
                text: "RESPONSE"
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: peakLabel
                textFormat: Text.PlainText
                text: root.peakSummary
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            ResponseCurve {
              id: responseCurveItem
              width: parent.width
              bands: root.bands
              preamp: root.preamp
              sampleRate: root.sampleRate
              foreground: root.barForeground
              accent: Color.accent
              handleBorder: root.bar ? root.bar.background : Color.background
              background: root.bar ? root.bar.background : Color.background
              fontFamily: root.barFontFamily
              // Editable while bypassed too, like the band controls: shaping a
              // curve and switching it in is how a comparison is made.
              editable: true
              freqEditable: root.mode === "parametric"
              // Graphic mode's ten faders belong to the console below the plot,
              // on the plot's own frequency axis -- a fader has to stand at the
              // frequency it moves, or its number means nothing.
              showFaders: root.mode !== "parametric"
              opacity: root.enabled ? 1.0 : 0.6
              onBandGainMoved: function(i, g) { root.commitBand(i, g) }
              onBandGainCommitted: function(i, g) { root.sendBandNow(i, g) }
              onBandFreqCommitted: function(i, f) { root.setBandProperty(i, "freq", f) }
            }
          }

          // In graphic mode the faders live inside the console above, sharing its
          // axis; only the parametric rows need a section of their own.
          PanelSeparator {
            visible: root.mode === "parametric"
            foreground: root.barForeground
          }

          // ---------- Bands ----------
          Item {
            visible: root.mode === "parametric"
            width: parent.width
            implicitHeight: parametricColumn.implicitHeight

            // Graphic: the ten faders are part of the response console above, so
            // this section exists for parametric mode only.
            //
            // Parametric: a row per band, because a band's type, frequency and Q
            // are as much of the sound as its gain -- the same four controls
            // Audio Hijack's Parametric EQ block exposes per band.
            Column {
              id: parametricColumn
              visible: root.mode === "parametric"
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                // The band count, not the band array: the panel echoes every write
                // back as a fresh array, and a Repeater over an array rebuilds all
                // its delegates -- which kills a drag that is still in progress.
                model: root.mode === "parametric" ? root.bands.length : 0

                ParametricBandRow {
                  required property int index
                  readonly property var band: root.bands[index]
                  width: parametricColumn.width
                  visible: band !== undefined && band !== null
                  bandGain: band ? (Number(band.gain) || 0) : 0
                  bandFreq: band ? (Number(band.freq) || 1000) : 1000
                  bandQ: band ? (Number(band.q) || 1.0) : 1.0
                  bandType: band ? String(band.type || "peaking") : "peaking"
                  bandIndex: index
                  foreground: root.barForeground
                  bar: root.bar
                  removable: true
                  onGainChanged: function(g) { root.commitBand(index, g); }
                  onGainCommitted: function(g) { root.sendBandNow(index, g); }
                  onFreqCommitted: function(f) { root.setBandProperty(index, "freq", f); }
                  onQCommitted: function(q) { root.setBandProperty(index, "q", q); }
                  onTypeChanged: function(t) { root.setBandProperty(index, "type", t); }
                  onRemoveRequested: root.removeBand(index)
                }
              }

              Button {
                text: "Add band"
                iconText: "󰐕"
                bordered: true
                selected: true
                foreground: root.barForeground
                onClicked: root.addBand()
              }
            }
          }


          PanelSeparator { foreground: root.barForeground }

          // ---------- Preamp ----------
          // A profile's bands and its preamp only make sense together, so the
          // preamp sits directly under the bands rather than with the presets.
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(preampHeader.implicitHeight, preampValue.implicitHeight, autoPreampButton.implicitHeight)

              PanelSectionHeader {
                id: preampHeader
                text: "PREAMPLIFIER"
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: preampValue
                textFormat: Text.PlainText
                text: (root.preamp > 0 ? "+" : "") + Number(root.preamp).toFixed(1) + " dB"
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: autoPreampButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }

              // Sets the preamp to cancel the curve's peak. Dimmed when the
              // preamp already matches, so it doubles as a 'you are safe' cue.
              Button {
                id: autoPreampButton
                readonly property bool autoOn: root.headroom === "auto"
                text: autoOn ? "Auto \u00b7 on" : "Auto \u00b7 off"
                bordered: true
                foreground: autoOn ? Color.accent : root.barForeground
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: !root.busy
                tooltipText: autoOn
                  ? "Headroom is automatic: the preamp follows the curve's peak. Click to set it by hand."
                  : "Make headroom automatic (" + root.autoPreamp.toFixed(1) + " dB for this curve)"
                onClicked: root.setHeadroom(autoOn ? "manual" : "auto")
              }
            }

            PanelSlider {
              id: preampSlider
              width: parent.width
              bar: root.bar
              minimum: -24
              maximum: 12
              step: 0.5
              tickCount: 4
              value: root.preamp
              opacity: root.enabled ? 1.0 : 0.5
              onMoved: function(v) { root.commitPreamp(v) }
              onReleased: function(v) { root.sendPreampNow(v) }
              onRightClicked: root.sendPreampNow(0)
            }

            // Scale under the slider: the range is asymmetric (-24..+12), so
            // without marks a 0 dB knob two-thirds along reads as a bug.
            Item {
              id: preampScale
              width: parent.width
              implicitHeight: Style.font.caption + Style.space(2)
              Repeater {
                model: [ { db: -24, f: 0 }, { db: -12, f: 1/3 }, { db: 0, f: 2/3 }, { db: 12, f: 1 } ]
                Text {
                  required property var modelData
                  textFormat: Text.PlainText
                  text: (modelData.db > 0 ? "+" : "") + modelData.db
                  color: Qt.darker(root.barForeground, modelData.db === 0 ? 1.2 : 1.7)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: modelData.db === 0
                  x: Math.max(0, Math.min(preampScale.width - implicitWidth, preampScale.width * modelData.f - implicitWidth / 2))
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Cancels boosts so they cannot clip. Auto keeps it matched to the curve's peak; moving the slider switches to manual."
              color: Qt.darker(root.barForeground, 1.6)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.barForeground }

          // ---------- Output ----------
          // Audio Hijack's output blocks: a brickwall limiter last in the chain so
          // nothing after it can clip, and Magic Boost, a compressor with makeup
          // gain for quiet material. Both always sit in the graph and are switched
          // by their enabled controls, so neither ever restarts the chain.
          Column {
            width: parent.width
            spacing: Style.space(8)
            opacity: root.outputStage ? (root.enabled ? 1.0 : 0.5) : 0.4

            PanelSectionHeader {
              text: "OUTPUT"
              foreground: root.barForeground
              fontFamily: root.barFontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(limiterLabel.implicitHeight, limiterSwitch.implicitHeight)

              Text {
                id: limiterLabel
                textFormat: Text.PlainText
                text: "Limiter \u00b7 \u22121 dB ceiling"
                color: root.barForeground
                font.family: root.barFontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              PowerSwitch {
                id: limiterSwitch
                checked: root.limiter === "on"
                busy: root.busy
                foreground: root.barForeground
                accent: Color.accent
                background: root.bar ? root.bar.background : Color.background
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.setLimiter(root.limiter === "on" ? "off" : "on")

                PanelToolTip {
                  visible: limiterSwitch.containsMouse
                  text: root.limiter === "on" ? "Turn the output limiter off" : "Catch peaks before they clip"
                  fontFamily: root.barFontFamily
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Magic Boost"
              color: root.barForeground
              font.family: root.barFontFamily
              font.pixelSize: Style.font.body
            }

            SegmentedControl {
              id: boostGroup
              options: [
                { value: "off", label: "Off" },
                { value: "low", label: "Low" },
                { value: "medium", label: "Medium" },
                { value: "high", label: "High" }
              ]
              value: root.boost
              foreground: root.barForeground
              accent: Color.accent
              background: root.bar ? root.bar.background : Color.background
              onChanged: function(v) { root.setBoost(v) }
            }

            Text {
              textFormat: Text.PlainText
              text: root.outputStage
                ? "Boost compresses and adds makeup gain so quiet audio gets louder; the limiter keeps the peaks clean."
                : "LSP plugins are not installed; the output stage is inactive."
              color: Qt.darker(root.barForeground, 1.6)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.barForeground }

          // ---------- Presets ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(presetHeader.implicitHeight, resetButton.implicitHeight)

              PanelSectionHeader {
                id: presetHeader
                text: "PRESET"
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: resetButton
                text: "Reset"
                iconText: "󰑐"
                bordered: true
                foreground: root.barForeground
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                tooltipText: "Flatten every band in this mode"
                onClicked: root.resetBands()
              }
            }

            // Uncaptioned dropdown fills the row; the delete button takes the
            // trigger height and is centred on it, so top and bottom edges line up.
            Item {
              width: parent.width
              implicitHeight: presetDropdown.implicitHeight

              Dropdown {
                id: presetDropdown
                showLabel: false
                anchors.left: parent.left
                anchors.right: deletePresetButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                value: root.preset
                options: root.presetOptions()
                foreground: root.barForeground
                onChanged: function(v) { root.loadPreset(v) }
              }

              // Icon-only and the trigger's exact height, centred on it. Neutral
              // at rest, red only on hover or when armed: a saturated idle
              // control pulls the eye to the least important action. First click
              // arms ("Delete?"), the second deletes; the arm expires after 3 s.
              Button {
                id: deletePresetButton
                readonly property bool deletable: root.isUserPreset(root.preset)
                property bool armed: false
                text: armed ? "Delete?" : ""
                iconText: "󰆴"
                bordered: true
                foreground: deletable && (armed || hot) ? Color.urgent : root.barForeground
                height: presetDropdown.height
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                opacity: deletable ? 1.0 : 0.35
                enabled: deletable && !root.busy
                tooltipText: deletable
                  ? (armed ? "Click again to delete \u201c" + root.preset + "\u201d" : "Delete this preset")
                  : "Built-in presets cannot be deleted"
                onDeletableChanged: armed = false
                onClicked: {
                  if (!armed) { armed = true; disarmTimer.restart(); return }
                  armed = false
                  disarmTimer.stop()
                  root.deletePreset()
                }
              }

              Timer {
                id: disarmTimer
                interval: 3000
                onTriggered: deletePresetButton.armed = false
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: presetNameField
                width: parent.width - savePresetButton.width - Style.space(6)
                placeholderText: "Save current bands as…"
                text: root.saveName
                foreground: root.barForeground
                onTextChanged: root.saveName = text
                Keys.onReturnPressed: root.savePreset()
                Keys.onEnterPressed: root.savePreset()
              }

              Button {
                id: savePresetButton
                text: "Save"
                iconText: "󰆓"
                bordered: true
                selected: true
                foreground: root.barForeground
                enabled: !root.busy && String(root.saveName || "").trim() !== ""
                anchors.verticalCenter: presetNameField.verticalCenter
                onClicked: root.savePreset()
              }
            }


            PanelSeparator { foreground: root.barForeground }

            // ---------- AutoEq ----------
            // AutoEq publishes measured headphone corrections; importing one
            // replaces the parametric bands and the preamp together.
            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "AUTOEQ"
                foreground: root.barForeground
                fontFamily: root.barFontFamily
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                TextField {
                  id: autoeqField
                  width: parent.width - autoeqSearchButton.width - Style.space(6)
                  placeholderText: "Headphone model…"
                  text: root.autoeqQuery
                  foreground: root.barForeground
                  onTextChanged: root.autoeqQuery = text
                  Keys.onReturnPressed: root.searchAutoEq()
                  Keys.onEnterPressed: root.searchAutoEq()
                }

                Button {
                  id: autoeqSearchButton
                  text: "Search"
                  iconText: "󰍉"
                  bordered: true
                  foreground: root.barForeground
                  enabled: !root.autoeqBusy
                  anchors.verticalCenter: autoeqField.verticalCenter
                  onClicked: root.searchAutoEq()
                }
              }

              Dropdown {
                id: autoeqDropdown
                visible: root.autoeqResults.length > 0
                height: visible ? implicitHeight : 0
                label: "Profiles"
                width: parent.width
                value: ""
                options: root.autoeqOptions()
                foreground: root.barForeground
                // The value carries name and path: two sources can measure the
                // same headphone, and the source is what tells them apart.
                onChanged: function(v) {
                  var parts = String(v).split("||")
                  root.importAutoEq(parts[0], parts[1])
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                Button {
                  id: autoeqImportButton
                  text: "Import best match"
                  iconText: "󰇚"
                  bordered: true
                  selected: true
                  foreground: root.barForeground
                  enabled: !root.busy && String(root.autoeqQuery || "").trim() !== ""
                  onClicked: root.importAutoEqQuery()
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.autoeqMessage !== ""
                  text: root.autoeqMessage
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: autoeqImportButton.verticalCenter
                  elide: Text.ElideRight
                  width: Math.max(0, parent.width - autoeqImportButton.width - Style.space(6))
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.error !== ""
              text: root.error
              color: Color.urgent
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }
}