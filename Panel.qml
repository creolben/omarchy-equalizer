import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The equalizer face: on/off, a mode switch, the band set, presets, and the
// shape of what is playing behind the curve.
//
// State lives in the backend (bin/omarchy-equalizer), never in this file. Every
// control writes there and the panel re-reads the JSON status, so a preset saved
// from one session, or a band nudged from a terminal, shows up here unchanged.
//
// Adjusting is meant to be heard while the hand moves (docs/spec-v4.md): a drag
// is echoed into the panel's own copy of the bands on the frame it happens, so
// the curve, the handle and every readout move together, and streamed to the
// backend's live editor (`omarchy-equalizer live`), which writes only the
// changed controls into the running graph. The release commits the edit -- one
// state write, one undo step. Without the live editor (it is starting, the
// equalizer is off, an A/B is playing) the same edits go through the command
// queue, sent at most every 60 ms.
Panel {
  id: root
  moduleName: "io.github.creolben.equalizer"
  ipcTarget: "io.github.creolben.equalizer"

  // Injected by BarWidget.qml.
  property Item anchorItem: null
  property QtObject hostWidget: null

  // The backend that ships with this plugin, addressed where the plugin system
  // installs it: ~/.config/omarchy/plugins/<id>/bin/omarchy-equalizer. Resolving
  // it here (rather than taking whatever `omarchy-equalizer` PATH finds) is what
  // makes `omarchy plugin add <url>` a complete install -- no symlink step, and
  // the panel always drives the backend that belongs to the QML it is drawn by.
  // install.sh still links the same file into ~/.local/bin for terminal use, but
  // the panel does not depend on it.
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + moduleName
  readonly property string helper: pluginDir + "/bin/omarchy-equalizer"

  property var status: null
  property bool busy: false
  property string error: ""
  property string notice: ""
  property string saveName: ""
  property bool saveOpen: false
  property var actionQueue: []

  readonly property bool enabled: status ? status.enabled === true : false
  readonly property string mode: status ? String(status.mode || "graphic") : "graphic"
  readonly property string preset: status ? String(status.preset || "Flat") : "Flat"
  // The backend compares the running band set with the loaded preset's own
  // array. False means either a match or a preset that says nothing about the
  // active mode (a graphic-only preset viewed in parametric mode).
  readonly property bool presetDirty: status ? status.presetDirty === true : false
  readonly property var bands: status ? (status.bands || []) : []
  readonly property var presets: status ? (status.presets || []) : []
  readonly property int paramCount: status ? Number(status.parametricCount || 0) : 0
  readonly property int graphicCount: status ? Number(status.graphicCount || 0) : 0
  readonly property bool sinkPresent: status ? status.sinkPresent === true : false
  readonly property string targetSink: status ? String(status.targetSink || "") : ""
  readonly property real preamp: status ? Number(status.preamp || 0) : 0
  readonly property bool canUndo: status ? status.canUndo === true : false
  readonly property bool canRedo: status ? status.canRedo === true : false
  // The most gain a hand-set preamp may hold for this curve: the backend computes
  // it (same function as its automatic headroom) and clamps every manual write to
  // it. The local copy tracks a band drag instantly, the backend's field is the
  // authority both sides have to agree on, so the smaller wins and neither can
  // offer gain the backend would refuse.
  readonly property real backendPreampCeiling: (status && status.preampCeiling !== undefined) ? Number(status.preampCeiling) : 0
  readonly property real preampMax: Math.max(-23.5, Math.min(autoPreamp, backendPreampCeiling))
  // Gain staging and the output stage, all owned by the backend. Missing
  // fields read as the backend defaults (auto headroom, limiter on, boost off).
  readonly property string headroom: status ? String(status.headroom || "auto") : "auto"
  readonly property string limiter: status ? String(status.limiter || "on") : "on"
  readonly property string boost: status ? String(status.boost || "off") : "off"
  readonly property bool outputStage: status ? status.outputStage === true : false
  readonly property string leveler: status ? String(status.leveler || "off") : "off"
  // Balanced headroom leans on the limiter for the rare peak, so it only plays
  // as balanced while there is one; otherwise the backend plays it as Safe.
  readonly property bool balancedInForce: limiter === "on" && outputStage
  // Channel handling ahead of the bands, and the balance (-1 left .. 1 right).
  readonly property string channels: status ? String(status.channels || "stereo") : "stereo"
  readonly property real balance: status ? (Number(status.balance) || 0) : 0
  // Automatic headroom cuts the whole signal by the curve's peak at full volume;
  // below full volume the backend gives that cut back as far as the volume
  // allows (the relief), and -- when it is switched on -- as far as the
  // device's own volume allows after the limiter (the device relief). The bands
  // are heard under preamp + relief + device relief.
  readonly property real relief: status ? (Number(status.relief) || 0) : 0
  readonly property real deviceRelief: status ? (Number(status.deviceRelief) || 0) : 0
  readonly property bool followDeviceVolume: status ? status.followDeviceVolume === "on" : false
  readonly property real appliedPreamp: preamp + relief + deviceRelief
  // The A/B (Flat at the curve's loudness) or a solo, while one is in force.
  readonly property var listen: status ? (status.listen || null) : null
  readonly property bool comparing: !!listen && listen.mode === "flat"
  readonly property int soloIndex: (!!listen && listen.mode === "solo") ? Number(listen.band) : -1
  // The pool's 16 filter slots: a steeper pass filter takes one per 12 dB/oct.
  readonly property int slotsUsed: status ? Number(status.slots || 0) : 0
  readonly property int maxSlots: status ? Number(status.maxSlots || 16) : 16
  // Each output device keeps its own curve.
  readonly property bool deviceMemory: status ? status.deviceMemory !== "off" : true
  readonly property string deviceLabel: status ? String(status.deviceLabel || status.targetSink || "") : ""
  readonly property var rememberedDevices: status ? (status.devices || []) : []
  // Apps playing now, and the ones kept off the equalizer.
  readonly property var apps: status ? (status.apps || []) : []
  readonly property var excludedApps: status ? (status.excludedApps || []) : []
  // The rate the graph instantiates the biquads with, reported by the backend:
  // the curve's frequency axis depends on it.
  readonly property int sampleRate: status ? Number(status.sampleRate || 48000) : 48000
  // One response computation per status change, shared by every binding below.
  // The model memoises it on the bands' contents, so the local echo of a drag
  // (which reassigns the whole status object) does not re-run the sweep.
  readonly property var metrics: Model.metrics(bands, sampleRate)
  // The 10-band console shows and sets what the curve does at each band's
  // centre, not the overlapping bells' own gains (Model.fitGraphic).
  readonly property var handleGains: mode === "graphic" ? Model.graphicResponse(bands, sampleRate) : []

  // The preamp the curve will settle at once the edit in hand is committed:
  // the peak cut (Safe), the balanced cut, or a manual preamp under the curve's
  // ceiling. While the limiter holds the preamp still during a drag, the preamp
  // in force and this differ, and the preamp row says both.
  function settleFor(list) {
    var m = Model.metrics(list, sampleRate)
    if (headroom === "manual") return Math.min(preamp, m.autoPreamp)
    if (headroom === "balanced" && balancedInForce) return m.balancedPreamp
    return m.autoPreamp
  }
  readonly property real settlePreamp: headroom === "manual" ? Math.min(preamp, metrics.autoPreamp)
    : (headroom === "balanced" && balancedInForce) ? metrics.balancedPreamp : metrics.autoPreamp

  // The peak of the *shape* -- the line the handles sit on, measured with the
  // preamp at zero -- and then where the preamp together with that shape lands
  // the signal at the limiter's input. That last number is the one that matters:
  // while the limiter is on it is the worst-case gain reduction, and it is what
  // the limiter would otherwise hide. A chain holding +15 dB over the ceiling
  // sounds loud, flat and grainy and never reports a clip, because the limiter
  // is doing exactly its job.
  readonly property real postPreampPeak: status
    ? metrics.peakDb + preamp
    : 0
  // -1 dBFS is the limiter's ceiling (see limiter_values in the backend); anything
  // above it is removed on every sample. Safe headroom leaves at most 1 dB by
  // construction (it targets 0 dBFS); Balanced leaves the rare peak to the
  // limiter on purpose, so only a manual preamp stacked above the curve's own
  // headroom is an alarm.
  readonly property real limiterWarnDb: 2
  readonly property real limiterDucking: Math.max(0, postPreampPeak + 1)
  readonly property bool limiterAlarm: enabled && limiter === "on" && headroom === "manual" && limiterDucking >= limiterWarnDb
  // How loud the curve plays against Flat at the same volume: its level (the
  // pink/A-weighted blend the presets are level-matched on) under the preamp it
  // is heard with. A big boost reads as what it costs everything else.
  readonly property real levelVsFlat: metrics.levelDb + appliedPreamp
  readonly property string peakSummary: {
    if (!status) return ""
    if (!enabled) return "BYPASSED"
    if (comparing) return "A/B · FLAT AT THE CURVE'S LOUDNESS"
    if (soloIndex >= 0) return "SOLO · BAND " + (soloIndex + 1)
    var peak = metrics
    var text
    if (peak.peakDb <= 0.05) text = "NO BOOST"
    else text = "+" + peak.peakDb.toFixed(1) + " dB AT " + Model.formatFreq(peak.peakFreq) + " HZ"
    if (Math.abs(levelVsFlat) >= 0.05)
      text += " · " + Model.formatGain(levelVsFlat) + " dB VS FLAT"
    // Safe leaves the limiter the last dB at most, by design, so the figure is
    // news only under Balanced (which leans on it) and as an alarm under Manual.
    var show = limiter === "on" && (headroom === "manual" ? limiterDucking >= limiterWarnDb
      : headroom === "balanced" && balancedInForce && limiterDucking > 1.05)
    if (show) text += " · LIMITER −" + limiterDucking.toFixed(1) + " dB AT WORST"
    return text
  }

  // The ceiling is the preamp's top and the one number a manual preamp has to
  // respect. It travels with the two controls that can move the preamp.
  readonly property string preampCeilingText: preampMax < 0
    ? preampMax.toFixed(1) + " dB"
    : "0.0 dB (this curve has no boost to cancel)"

  // AutoEq import: a query, whatever the profile index matched, and a line of
  // feedback so the panel never silently does nothing.
  property string autoeqQuery: ""
  property var autoeqResults: []
  property string autoeqMessage: ""
  property bool autoeqBusy: false

  // The panel's one line of feedback, pinned below the tabbed band. A failure
  // wins over a notice and over the AutoEq progress/result because it is the
  // one the user has to act on; each clears 8 s after it was last written.
  readonly property string statusText: error !== "" ? error : (notice !== "" ? notice : autoeqMessage)

  Timer {
    id: statusClearTimer
    interval: 8000
    repeat: false
    onTriggered: {
      root.error = ""
      root.notice = ""
      // "Searching AutoEq…" is progress, not a result: it stays until the
      // search answers, however slow the index is.
      if (root.autoeqBusy) restart()
      else root.autoeqMessage = ""
    }
  }
  onErrorChanged: if (error !== "") statusClearTimer.restart()
  onAutoeqMessageChanged: if (autoeqMessage !== "") statusClearTimer.restart()
  // Writing the same text twice changes no property, so the change handlers
  // above stay silent; every write goes through these so a repeated message
  // gets its full 8 s again.
  function reportError(message) {
    error = String(message || "")
    if (error !== "") statusClearTimer.restart()
  }
  function reportNotice(message) {
    notice = String(message || "")
    if (notice !== "") statusClearTimer.restart()
  }
  function reportAutoEq(message) {
    autoeqMessage = String(message || "")
    if (autoeqMessage !== "") statusClearTimer.restart()
  }

  // The base Panel supplies barForeground (with a sane fallback for the moment
  // before the bar widget injects itself); the font family needs the same care.
  readonly property string barFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color cardBackground: bar ? bar.background : Color.background
  // Secondary text: the dimmest blend of the foreground toward the background
  // that still holds a 4.5:1 contrast (Model.dimColor), one shade for every
  // caption, meta line and readout, in a light theme as in a dark one.
  readonly property color dimText: Model.dimColor(barForeground, cardBackground)

  // Filled glyph while the equalizer is processing, outline while bypassed --
  // the same distinction the bar icon makes.
  readonly property string equalizerGlyph: enabled ? "󰺢" : "󰺣"

  // Hero meta line: what is being shaped, and how much.
  readonly property string summary: {
    if (!status) return "READING STATE"
    if (!enabled) return "BYPASSED"
    if (comparing) return "A/B · HEARING FLAT"
    if (soloIndex >= 0) return "SOLO · BAND " + (soloIndex + 1)
    // Mode lives once, on the response console's top line. The hero says what
    // is being shaped and how much, not which control chose the band set.
    var shaped = metrics.shapedCount
    if (shaped === 0) return "FLAT"
    // "8 BANDS ACTIVE" read as "this equalizer has 8 bands" next to a ten-band
    // curve and a mode control that says 10-band, so the total is stated too.
    var total = bands.length
    return shaped + " / " + total + " " + (total === 1 ? "BAND" : "BANDS") + " ACTIVE"
  }

  readonly property string modeMeta: mode === "parametric"
    ? String(bands.length) + " bands, freely placed"
    : "31 Hz – 16 kHz, one octave per band"

  // The tabbed band's selected page. Not persisted: the panel is the
  // instrument, so every open starts on the response console -- the tabs
  // exist so the set-and-forget pages never need a scroll to reach.
  property string activeTab: "response"

  // Leaving parametric mode retires the Bands page. Gated on status so the
  // property's first evaluation (before any status has arrived) cannot
  // clobber a page chosen before then.
  onModeChanged: if (status && mode !== "parametric" && activeTab === "bands") activeTab = "response"

  function tabOptions() {
    var options = [{ value: "response", label: "Response" }]
    if (mode === "parametric") options.push({ value: "bands", label: "Bands" })
    options.push({ value: "output", label: "Output" })
    options.push({ value: "autoeq", label: "AutoEq" })
    return options
  }

  // The curve lives inside the popup window, which a walk of the bar widget's
  // children cannot reach, so it is exposed here for the headless harness (and
  // for anything else that needs to drive the curve without a pointer).
  readonly property var responseCurve: responseCurveItem

  // Fold state is presentation state, so it lives in a small JSON file beside
  // the other panels' settings (the weather/notifications FileView idiom),
  // not in the backend's state.json -- a backend command for "the preset list
  // is folded" would be clutter. QML Settings is unusable in quickshell
  // anyway: the process sets no organizationName, so it warns and never
  // persists.
  property bool presetCollapsed: false
  property bool uiStateLoaded: false

  FileView {
    id: uiStateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/equalizer-panel.json"
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadUiState(text())
    onLoadFailed: root.loadUiState("")
  }

  Process {
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/omarchy/settings"]
    running: true
  }

  function loadUiState(raw) {
    // Fires once per shell start; a later toggle rewrites the file ourselves,
    // so a second load after that must not stomp the user's newer choice.
    if (uiStateLoaded) return
    uiStateLoaded = true
    if (raw === "") return
    try {
      var parsed = JSON.parse(raw)
      if (parsed && typeof parsed.presetCollapsed === "boolean")
        root.presetCollapsed = parsed.presetCollapsed
    } catch (e) { }
  }

  function setCollapsed(key, value) {
    root[key] = value
    if (uiStateLoaded) uiStateSaveTimer.restart()
  }

  Timer {
    id: uiStateSaveTimer
    interval: 200
    repeat: false
    onTriggered: uiStateFile.setText(JSON.stringify({
      presetCollapsed: root.presetCollapsed
    }, null, 2) + "\n")
  }

  // A status read while an edit is in hand would paint the values the local
  // echo already replaced, so it waits: the edit's own commit brings the next
  // status, and a read that was turned away is made once the edit is done.
  property bool statusSkipped: false
  readonly property bool editInFlight: editing || commitWanted !== "" || liveCommitsPending > 0 || liveCommitTimer.running

  function refresh() {
    // Not while an action is running: the backend's writes are in flight, and a
    // poll taken now would paint the values the local echo already replaced.
    if (editInFlight) { statusSkipped = true; return }
    if (statusProc.running || busy) return
    statusProc.running = true
  }

  // Actions queue instead of being thrown away: every panel action is a
  // subprocess, and an import or a preset apply takes long enough that a band
  // drag finishes while it is still running. Dropping the newer command left the
  // local echo and the backend disagreeing until the next poll snapped back.
  //
  // A commit still on its way to the live editor goes first: an undo, a preset
  // or a mode switch issued right after a nudge must act on the curve the
  // nudge made, not on the one before it.
  property var deferredActions: []
  function run(args) {
    if (commitWanted !== "") resolveCommit()
    if (liveCommitTimer.running) liveCommitNow()
    // Any other command may move the graph under what the editor last sent.
    liveLast = ({})
    if (liveCommitsPending > 0) { deferredActions = deferredActions.concat([args]); return }
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

  function runDeferred() {
    var waiting = deferredActions
    deferredActions = []
    for (var i = 0; i < waiting.length; i++) run(waiting[i])
  }

  // Repeatable commands (a drag's worth of values) can collapse to one entry.
  // Everything else -- presets, mode, import -- is a distinct action in order.
  function actionKey(args) {
    var name = String(args[0] || "")
    if (name === "set-gain" || name === "set-preamp")
      return name + ":" + String(args[1] || "")
    if (name === "set-balance" || name === "set-gains") return name
    // A band's freq and its Q are different edits: only the same property of
    // the same band may replace a queued one.
    if (name === "set-band")
      return name + ":" + String(args[1] || "") + ":" + String(args[2] || "")
    return ""
  }

  // A queued burst used to clear the error as each action started, so a failure
  // in the middle of a drag flashed for one action and was gone; the status
  // strip's own timer retires it instead.
  function startAction(args) {
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
    if (editInFlight) { statusSkipped = true; return }
    statusSkipped = false
    status = parsed
    // An editor that gave up (the graph was mid-rebuild after an upgrade, the
    // sink was briefly gone) is tried again once the state has moved on.
    if (liveWanted && !liveProc.running && Date.now() - liveLastStart > 10000) {
      liveStarts = 0
      Qt.callLater(syncLive)
    }
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

  // The sliders never rely on a declined wheel reaching the Flickable: they
  // accept it either way and call this when the policy says the wheel belongs
  // to the panel. Clamping here keeps the content from overshooting its ends.
  function scrollByDelta(dy) {
    var f = pageArea.contentItem
    if (!f) return
    var top = (Number(f.originY) || 0) - (Number(f.topMargin) || 0)
    var bottom = (Number(f.originY) || 0) + f.contentHeight + (Number(f.bottomMargin) || 0) - f.height
    f.contentY = Math.max(top, Math.min(Math.max(top, bottom), f.contentY + dy))
  }

  // ---------------------------------------------------------------- editing
  //
  // Every curve control lands here: the curve's handles, the faders, the band
  // rows and the strip, the preamp and the balance. A gesture's moves echo and
  // stream; its final value (a release, a nudge, a typed field) also commits.
  // A commit is sent at once after a drag, and after a short settle for a
  // nudge, so a run of arrow presses is one commit and one undo step.
  property bool editing: false
  property double editStartedAt: 0
  property bool fitClampReported: false
  property string commitWanted: ""
  // The path a gesture started on, kept to its end: an editor that arms in
  // the middle of a drag sent through the queue must not commit ahead of the
  // commands still queued for it.
  property bool editViaLive: false

  // The live editor, and nothing else in flight that it could overtake (or
  // that could overwrite it): no command running, queued or throttled.
  function liveClear() {
    return liveUsable && !actionProc.running && actionQueue.length === 0 && !throttleTimer.running
  }

  function beginEdit() {
    if (editing) return
    editing = true
    editStartedAt = Date.now()
    editViaLive = liveClear()
  }

  // True for a nudge: a final value with no drag before it, or a drag too short
  // to be one (a slider's own nudge emits a move and a release at once).
  function finishEdit() {
    var quick = !editing || Date.now() - editStartedAt < 80
    editing = false
    fitClampReported = false
    return quick
  }

  function num(v) { return String(Math.round((Number(v) || 0) * 100) / 100) }

  function sendEdit(key, line, args, final) {
    var viaLive = (editing ? editViaLive : liveClear()) && liveUsable
    var quick = final ? finishEdit() : false
    if (viaLive) {
      if (liveLast[key] !== line) {
        livePending[key] = line
        liveLast[key] = line
        if (!liveFlushTimer.running) liveFlushTimer.start()
      }
      if (final) {
        // A release emits its gain and its frequency one after the other: one
        // commit for both, at once if either came from a drag.
        if (!quick) commitWanted = "now"
        else if (commitWanted !== "now") commitWanted = "soon"
        Qt.callLater(resolveCommit)
      }
    } else {
      throttledRun(key, args, final)
    }
  }

  function resolveCommit() {
    var want = commitWanted
    commitWanted = ""
    if (want === "now") liveCommitNow()
    else if (want === "soon") liveCommitTimer.restart()
  }

  // The queue path: at most one command per 60 ms while a value keeps moving,
  // and always the last value; the queue itself collapses what is still
  // waiting for the same control.
  property var throttlePending: ({})
  function throttledRun(key, args, final) {
    if (final) {
      delete throttlePending[key]
      run(args)
      return
    }
    if (!throttleTimer.running) {
      run(args)
      throttleTimer.start()
      return
    }
    throttlePending[key] = args
  }

  Timer {
    id: throttleTimer
    interval: 60
    repeat: true
    onTriggered: {
      var any = false
      for (var k in root.throttlePending) { root.run(root.throttlePending[k]); any = true }
      root.throttlePending = ({})
      if (!any) stop()
    }
  }

  // The echo: the band set with one band changed (or a whole new set), and
  // the preamp with it when it follows the bands -- without a limiter to hold
  // it, and on the queue path, where every edit recomputes it.
  readonly property bool followsPreamp: !(liveUsable && limiter === "on" && outputStage)

  function echoBands(next) {
    var over = { bands: next }
    if (listen) over.listen = null
    if (followsPreamp) over.preamp = settleFor(next)
    withStatus(over)
  }

  function echoBand(index, key, value) {
    var next = bands.slice()
    if (!next[index]) return false
    var b = {}
    for (var k in next[index]) b[k] = next[index][k]
    b[key] = value
    next[index] = b
    echoBands(next)
    return true
  }

  // Parametric gain, frequency and Q.
  function editGain(index, gain, final) {
    if (!final) beginEdit()
    var g = Math.round(Model.clampGain(gain) * 100) / 100
    if (!echoBand(index, "gain", g)) return
    sendEdit("gain:" + index, "gain " + index + " " + num(g), ["set-gain", String(index), num(g)], final)
  }

  function editFreq(index, freq, final) {
    if (!final) beginEdit()
    var f = Math.round(Model.clamp(freq, 20, 20000))
    if (!echoBand(index, "freq", f)) return
    sendEdit("freq:" + index, "freq " + index + " " + f, ["set-band", String(index), "freq", String(f)], final)
  }

  function editQ(index, q, final) {
    if (!final) beginEdit()
    var v = Math.round(Model.clamp(q, 0.1, 30) * 100) / 100
    if (!echoBand(index, "q", v)) return
    sendEdit("q:" + index, "q " + index + " " + num(v), ["set-band", String(index), "q", num(v)], final)
  }

  // A 10-band fader or handle: the target is what the curve should do at that
  // band's centre; every bell moves so that it does, and no other fader moves.
  function editGraphic(index, target, final) {
    if (!final) beginEdit()
    var t = Model.clamp(target, -24, 24)
    var fit = Model.fitGraphic(bands, Model.graphicTargets(bands, index, t, sampleRate), sampleRate)
    if (fit.clamped && !fitClampReported) {
      fitClampReported = true
      reportNotice("Neighbouring faders this far apart cannot be fully reached.")
    }
    echoBands(fit.bands)
    var gains = []
    for (var i = 0; i < fit.bands.length; i++) gains.push(num(fit.bands[i].gain))
    sendEdit("gains", "gains " + gains.join(" "), ["set-gains"].concat(gains), final)
  }

  function bandGainEdited(index, value, final) {
    if (mode === "graphic") editGraphic(index, value, final)
    else editGain(index, value, final)
  }

  // A hand-set preamp is the backend's cue to stop tracking the curve. A click
  // or arrow that lands on the value already in force is not an edit: it must
  // not quietly switch automatic headroom off. A drag that wandered and came
  // back is one, though -- what it streamed is in the graph, and is filed.
  property bool preampStreamed: false
  function editPreamp(db, final) {
    var value = Math.round(Model.clamp(db, -24, preampMax) * 2) / 2
    if (!final) beginEdit()
    var current = Math.round((Number(root.preamp) || 0) * 2) / 2
    if (headroom !== "manual" && value === current && !preampStreamed) {
      if (final) finishEdit()
      return
    }
    preampStreamed = !final
    withStatus({ preamp: value, headroom: "manual", relief: 0, deviceRelief: 0 })
    sendEdit("preamp", "preamp " + num(value), ["set-preamp", num(value)], final)
  }

  // The balance is a drag: echo every step, stream it, commit at the end.
  function editBalance(value, final) {
    var v = Math.round(Model.clamp(value, -1, 1) * 20) / 20
    if (!final) beginEdit()
    withStatus({ balance: v })
    sendEdit("balance", "balance " + num(v), ["set-balance", num(v)], final)
  }

  // ---------------------------------------------------------------- live editor
  //
  // `omarchy-equalizer live`, kept running while the panel is open and the
  // equalizer is on and playing its own curve. It answers "ready" once, a
  // status after every commit, "stale" when the state changed under an
  // uncommitted edit, and exits when there is no graph to write to; it is
  // started again a moment later, and the queue covers the gap.
  property bool liveArmed: false
  property int liveStarts: 0
  property double liveLastStart: 0
  property int liveCommitsPending: 0
  property var livePending: ({})
  property var liveLast: ({})
  readonly property bool liveWanted: opened && enabled && sinkPresent && !comparing && soloIndex < 0
  readonly property bool liveUsable: liveArmed && liveProc.running && !comparing && soloIndex < 0

  onLiveWantedChanged: syncLive()

  function syncLive() {
    if (liveWanted) {
      liveStopTimer.stop()
      if (!liveProc.running && liveStarts < 6) {
        liveStarts++
        liveLastStart = Date.now()
        liveProc.stdinEnabled = true
        liveProc.running = true
      }
    } else if (liveProc.running) {
      // End of input: the editor files a nudge still settling (or a commit
      // decided this very turn, still waiting on Qt.callLater), puts back
      // whatever was not committed, and exits.
      if (commitWanted !== "") { commitWanted = "now"; resolveCommit() }
      if (liveCommitTimer.running) liveCommitNow()
      liveArmed = false
      liveFlush()
      liveProc.stdinEnabled = false
      liveStopTimer.restart()
    }
  }

  function liveFlush() {
    liveFlushTimer.stop()
    var lines = []
    for (var k in livePending) lines.push(livePending[k])
    livePending = ({})
    if (lines.length > 0 && liveProc.running) liveProc.write(lines.join("\n") + "\n")
  }

  function liveCommitNow() {
    liveCommitTimer.stop()
    if (!liveProc.running) return
    liveFlush()
    liveProc.write("commit\n")
    liveCommitsPending++
    // The next gesture starts from what the graph will have: a value equal to
    // one sent before this commit is still a value to send.
    liveLast = ({})
  }

  function liveLine(line) {
    var text = String(line || "")
    if (text.indexOf("ready") === 0) {
      liveArmed = true
      liveStarts = 0
    } else if (text.indexOf("status ") === 0) {
      liveCommitsPending = Math.max(0, liveCommitsPending - 1)
      applyStatus(text.slice(7))
      if (liveCommitsPending === 0) runDeferred()
    } else if (text.indexOf("error ") === 0) {
      reportError(text.slice(6))
    } else if (text === "stale") {
      liveLast = ({})
      statusSkipped = true
      Qt.callLater(refresh)
    } else if (text.indexOf("unavailable") === 0) {
      liveArmed = false
    }
  }

  Process {
    id: liveProc
    command: [root.helper, "live"]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.liveLine(line) }
    }
    onRunningChanged: {
      if (running) return
      root.liveArmed = false
      root.livePending = ({})
      root.liveLast = ({})
      var hadCommits = root.liveCommitsPending > 0
      root.liveCommitsPending = 0
      liveStopTimer.stop()
      root.runDeferred()
      if (hadCommits || root.statusSkipped) Qt.callLater(root.refresh)
      if (root.liveWanted) liveRestartTimer.restart()
    }
  }

  Timer {
    id: liveFlushTimer
    interval: 16
    repeat: false
    onTriggered: root.liveFlush()
  }
  // A nudge's commit waits for the run of nudges to end.
  Timer {
    id: liveCommitTimer
    interval: 300
    repeat: false
    onTriggered: root.liveCommitNow()
  }
  Timer {
    id: liveRestartTimer
    interval: 1500
    repeat: false
    onTriggered: root.syncLive()
  }
  // An editor that does not leave at the end of its input is stopped.
  Timer {
    id: liveStopTimer
    interval: 2500
    repeat: false
    onTriggered: if (liveProc.running && !root.liveWanted) liveProc.running = false
  }

  // ---------------------------------------------------------------- headroom and stage

  // Safe: the preamp cancels the curve's peak (the backend's "auto").
  // Balanced: it cancels what the curve adds to programme material and leaves
  // the rare peak to the limiter. Manual: it stays where it was left.
  readonly property real autoPreamp: metrics.autoPreamp
  function setHeadroom(value) {
    if (value === headroom) return
    var echo = { headroom: value }
    if (value === "auto") echo.preamp = autoPreamp
    else if (value === "balanced") echo.preamp = balancedInForce ? metrics.balancedPreamp : autoPreamp
    withStatus(echo)
    run(["set-headroom", value])
  }
  function setLimiter(value) { withStatus({ limiter: value }); run(["set-limiter", value]) }
  function setBoost(value) { withStatus({ boost: value }); run(["set-boost", value]) }
  function setLeveler(value) { withStatus({ leveler: value }); run(["set-leveler", value]) }
  function setChannels(value) { withStatus({ channels: value }); run(["set-channels", value]) }
  function setDeviceMemory(on) { withStatus({ deviceMemory: on ? "on" : "off" }); run(["set-device-memory", on ? "on" : "off"]) }
  function setDeviceRelief(on) { withStatus({ followDeviceVolume: on ? "on" : "off" }); run(["set-device-relief", on ? "on" : "off"]) }
  function setAppExcluded(name, excluded) { run([excluded ? "exclude-app" : "include-app", String(name)]) }
  function appRows() {
    var rows = [], seen = {}
    for (var i = 0; i < apps.length; i++) {
      var a = apps[i]
      if (!a || !a.name) continue
      seen[String(a.name).toLowerCase()] = true
      if (a.binary) seen[String(a.binary).toLowerCase()] = true
      rows.push({ name: String(a.name), excluded: a.excluded === true, playing: true })
    }
    for (var k = 0; k < excludedApps.length; k++) {
      var n = String(excludedApps[k])
      if (seen[n.toLowerCase()]) continue
      rows.push({ name: n, excluded: true, playing: false })
    }
    return rows
  }

  // The A/B: Flat at the curve's own loudness, so the comparison is the tone
  // and not the volume (the louder side always sounds better).
  function toggleCompare() {
    var on = !comparing
    withStatus({ listen: on ? { mode: "flat" } : null })
    run(["compare", on ? "on" : "off"])
  }
  function toggleSolo(index) {
    var off = soloIndex === index
    withStatus({ listen: off ? null : { mode: "solo", band: index } })
    run(["solo", off ? "off" : String(index)])
  }

  // A band's bypass and slope. The echo keeps every other field of the band, so
  // the curve redraws without the band (or with its new slope) at once.
  function setBandField(index, key, value) {
    var next = bands.slice()
    if (next[index]) {
      var b = {}
      for (var k in next[index]) b[k] = next[index][k]
      b[key] = value
      next[index] = b
      withStatus({ bands: next })
    }
  }
  function setBandEnabled(index, on) {
    setBandField(index, "enabled", on)
    run(["set-band", String(index), "enabled", on ? "on" : "off"])
  }
  function toggleBandEnabled(index) {
    var b = bands[index]
    if (b) setBandEnabled(index, b.enabled === false)
  }
  function setBandType(index, value) {
    var parsed = Model.parseTypeOption(value)
    var band = bands[index] || {}
    // A new type starts at slope 1 in the backend, so the slope to compare with
    // is that one, not whatever the band held as its old type.
    var typeChanged = String(band.type || "peaking") !== parsed.type
    if (typeChanged) {
      setBandField(index, "type", parsed.type)
      setBandField(index, "slope", 1)
      run(["set-band", String(index), "type", parsed.type])
    }
    var current = typeChanged ? 1 : Model.bandSlope(band)
    if (Model.typeHasSlope(parsed.type) && current !== parsed.slope) {
      setBandField(index, "slope", parsed.slope)
      run(["set-band", String(index), "slope", String(parsed.slope)])
    }
  }

  function searchAutoEq() {
    var query = String(autoeqQuery || "").trim()
    if (query === "") {
      reportAutoEq("Type a headphone model to search AutoEq.")
      return
    }
    autoeqResults = []
    reportAutoEq("Searching AutoEq for “" + query + "”…")
    autoeqBusy = true
    autoeqSearchProc.command = [helper, "autoeq-search", "--json", query]
    autoeqSearchProc.running = true
  }

  function updateAutoEqResults(text) {
    var parsed = Model.parseJsonArray(text)
    autoeqResults = parsed
    autoeqBusy = false
    if (parsed.length === 0) reportAutoEq("No AutoEq profile matched that.")
    else reportAutoEq(parsed.length + " profile" + (parsed.length === 1 ? "" : "s") + " found.")
  }

  // The profile path travels with the name: two sources can measure the same
  // headphone, and without the path the backend re-searches and re-ranks, which
  // can download a different measurement than the one that was picked.
  function importAutoEq(name, profilePath) {
    var target = String(name || "").trim()
    if (target === "") {
      reportAutoEq("Search first, then pick a profile.")
      return
    }
    var path = String(profilePath || "").trim()
    reportAutoEq("Importing " + target + "…")
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
    reportNotice("Flattened · press u to undo")
  }

  // An edit still on its way will be an undo step by the time this runs.
  function undo() { if (canUndo || editInFlight) run(["undo"]) }
  function redo() { if (canRedo) run(["redo"]) }
  function revertPreset() { run(["revert-preset"]) }
  function updatePreset() {
    if (!isUserPreset(preset)) return
    run(["save-preset", preset])
    reportNotice("Saved over “" + preset + "”")
  }

  // Double-click on empty plot: a band there, selected so the keys and the
  // strip act on it next.
  function addBandAt(freq, gain) {
    if (slotsUsed >= maxSlots) { reportError("Every filter slot is in use."); return }
    var next = bands.slice()
    next.push({ type: "peaking", freq: Math.round(freq), q: 1.0, gain: gain })
    echoBands(next)
    responseCurveItem.selectedIndex = next.length - 1
    run(["add-band", String(Math.round(freq)), num(gain), "1", "peaking"])
  }

  function addBand() {
    run(["add-band"])
  }

  function removeBand(index) {
    var next = bands.slice()
    next.splice(index, 1)
    echoBands(next)
    run(["remove-band", String(index)])
  }

  function openSave() {
    saveOpen = true
    Qt.callLater(function () { presetNameField.forceActiveFocus() })
  }

  function savePreset() {
    var name = String(saveName || "").trim()
    if (name === "") {
      reportError("Name the preset first.")
      return
    }
    saveName = ""
    saveOpen = false
    // The field follows saveName only while unfocused, and the button click
    // leaves it focused, so clear the draft here as well.
    presetNameField.text = ""
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

  function presetExists(name) {
    for (var i = 0; i < presets.length; i++) if (presets[i] && presets[i].name === name) return true
    return false
  }

  // The picker groups by the category the backend reports. Built-ins carry one
  // from their file; a user preset is "user" and reads as "Yours". Unknown
  // values still print, capitalised, rather than disappearing.
  function presetCategoryLabel(category, builtin) {
    var known = {
      reference: "Reference",
      tone: "Tone",
      genre: "Genre",
      speech: "Speech",
      situation: "Situation",
      user: "Yours",
      other: "Other"
    }
    var key = String(category || (builtin ? "other" : "user"))
    if (known[key] !== undefined) return known[key]
    return key.charAt(0).toUpperCase() + key.slice(1)
  }

  // Value is always the bare preset name: apply, delete and the edited check
  // all use it. The label is a scanning aid for the popup and the description
  // is the line the searchable picker filters and shows under it.
  // Rebuilt only when the list's content changes: every status poll hands over
  // a fresh presets array, and an open picker should not see its model swapped
  // for an identical one every few seconds.
  property var presetOptionList: []
  property string presetOptionKey: ""
  onPresetsChanged: {
    var next = presetOptions()
    var key = JSON.stringify(next)
    if (key === presetOptionKey) return
    presetOptionKey = key
    presetOptionList = next
  }

  function presetOptions() {
    var options = []
    for (var i = 0; i < presets.length; i++) {
      if (!presets[i]) continue
      var builtin = presets[i].builtin === true
      options.push({
        value: presets[i].name,
        label: presetCategoryLabel(presets[i].category, builtin) + " · " + presets[i].name,
        description: presets[i].description || ""
      })
    }
    return options
  }

  // What the loaded preset actually does. Every built-in carries the line in its
  // own file, which is the only place its curve is written down in words; a user
  // preset has no prose, so the caption falls back to the shape of the chain.
  readonly property string presetDescription: {
    for (var i = 0; i < presets.length; i++) {
      var p = presets[i]
      if (p && p.name === preset && p.description) return String(p.description)
    }
    var n = mode === "parametric" ? paramCount : graphicCount
    return n + (n === 1 ? " band · " : " bands · ")
      + (mode === "parametric" ? "parametric" : "graphic")
  }

  // The section header shows the preset's family, not its name: the picker
  // trigger one row below already shows the name, and repeating it there made
  // the row read as a label above a label.
  readonly property string presetCategory: {
    for (var i = 0; i < presets.length; i++) {
      var p = presets[i]
      if (p && p.name === preset) return presetCategoryLabel(p.category, p.builtin === true)
    }
    return ""
  }

  // What the preamp row reads: the gain in force, and while a held preamp has
  // not settled yet, where it is going.
  readonly property string preampReadout: {
    var fmt = function (v) { return (v > 0 ? "+" : "") + Number(v).toFixed(1) }
    if (Math.abs(settlePreamp - preamp) >= 0.05 && headroom !== "manual")
      return fmt(preamp) + " → " + fmt(settlePreamp) + " dB"
    return fmt(appliedPreamp) + " dB"
  }

  readonly property string headroomCaption: {
    var given = ""
    if (headroom !== "manual" && (relief >= 0.05 || deviceRelief >= 0.05))
      given = " · " + Number(relief + deviceRelief).toFixed(1) + " dB given back at this volume"
    if (headroom === "manual") return "Manual · the preamp stays where you left it."
    if (headroom === "balanced" && !balancedInForce)
      return "Balanced needs the limiter; without it the preamp plays as Safe" + given + "."
    if (headroom === "balanced")
      return "Balanced · cut by the programme level (+" + Number(Math.max(0, metrics.programGainDb)).toFixed(1)
        + " dB); the limiter takes the rare peak above it" + given + "."
    return "Safe · the preamp cancels the curve's peak, so nothing reaches the limiter" + given + "."
  }

  onOpenedChanged: {
    if (opened) refresh()
    // A gesture the close cut off (Escape mid-drag) ends here: what it had
    // reached is filed, and the panel does not reopen still "editing".
    if (!opened && editing) {
      var viaLive = editViaLive && liveUsable
      editing = false
      if (viaLive) liveCommitNow()
    }
    syncLive()
  }

  // The bar icon comes from status too, and the panel is instantiated with the
  // bar, so the first read happens at shell start rather than on first open.
  Component.onCompleted: refresh()

  // An enable, disable or preset from a terminal or keybind rewrites state.json;
  // watching it keeps the bar icon right while the panel is closed. The backend
  // renames a temp file over it, which the shell's own config FileViews survive.
  // Status itself never writes the file, so this cannot loop.
  property bool refreshQueued: false

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
      + "/omarchy-equalizer/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      if (statusProc.running) root.refreshQueued = true
      else root.refresh()
    }
  }

  // Status is re-read whenever the panel opens and after every action; the open
  // panel also polls slowly so an external change (a terminal, or the speaker
  // tuning being switched) is reflected without reopening.
  Process {
    id: statusProc
    command: [root.helper, "status"]
    onExited: {
      // A state change that landed during this read may not be in it.
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refresh)
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  // An edit that turned a status read away reads it once the edit is done.
  onEditInFlightChanged: if (!editInFlight && statusSkipped) Qt.callLater(refresh)

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
        if (message !== "") root.reportError(message)
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      // An error from an earlier action may still be showing; a new failure
      // keeps it up for its full 8 s rather than reporting nothing.
      if (exitCode !== 0) {
        if (root.error === "") root.reportError("The equalizer command failed.")
        else statusClearTimer.restart()
      }
      // Whatever was waiting runs next; the status read happens once the queue is
      // empty so a poll cannot land in the middle of a burst of writes.
      if (!root.pumpActions() && !statusProc.running) statusProc.running = true
    }
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
          root.autoeqBusy = false
          root.reportAutoEq(message)
        }
      }
    }
  }

  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // The output level, for the readout beside the hero's summary and the CLIP
  // hold. While the equalizer is on it watches the filter-chain's own playback
  // stream (omarchy_equalizer.output), i.e. the signal AFTER the preamp and
  // every band -- the only place a clipping boost shows. Bypassed, it falls
  // back to the default sink.
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

  // The live spectrum of the equalizer's output, drawn softly behind the curve.
  // Runs only while the panel is open and the equalizer is on; stopping the
  // process also stops the capture it owns.
  property var spectrum: []
  Process {
    id: spectrumProc
    command: [root.pluginDir + "/bin/omarchy-equalizer-spectrum", "omarchy_equalizer"]
    running: root.opened && root.enabled
    stdout: SplitParser {
      onRead: function(line) {
        var frame = Model.parseSpectrumLine(line)
        if (!frame) return
        root.spectrum = frame.bands
      }
    }
    onRunningChanged: if (!running) root.spectrum = []
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
    contentHeight: panel.fittedContentHeight(fixedBand.implicitHeight + tabBar.implicitHeight + pageArea.height + statusStrip.height
      + card.spacing * (statusStrip.visible ? 3 : 2), Style.space(760))

    // Ctrl+Z and Ctrl+Shift+Z: the key catcher passes them on (they are not
    // its keys), so they land here; u and Shift+U go through its textKey.
    Item {
      id: shortcuts
      anchors.fill: parent
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) {
          if (event.modifiers & Qt.ShiftModifier) root.redo(); else root.undo()
          event.accepted = true
        }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        onCloseRequested: root.close()
        onActivateRequested: root.toggleEnabled()
        onTextKey: function(t) {
          if (t === "e" || t === "E") root.toggleEnabled()
          else if (t === "m" || t === "M") root.setMode(root.mode === "graphic" ? "parametric" : "graphic")
          else if (t === "r" || t === "R") root.resetBands()
          else if (t === "a" || t === "A") root.toggleCompare()
          else if (t === "u") root.undo()
          else if (t === "U") root.redo()
        }
        // The card is a fixed band and a tabbed one. The fixed band (hero,
        // presets) never moves; the pages -- response console, band rows,
        // output stage, AutoEq import -- are one tab bar away from each other,
        // so nothing that is visible ever scrolls away. The page area only
        // scrolls when the page itself is taller than the card can fit (a long
        // band list).
        Column {
          id: card
          anchors.fill: parent
          spacing: Style.space(8)

          Item {
            id: fixedBand
            width: parent.width
            implicitHeight: fixedColumn.implicitHeight

            Column {
              id: fixedColumn
              width: parent.width
              spacing: Style.space(6)
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
                  background: root.cardBackground
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onToggled: root.toggleEnabled()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.enabled ? "Bypass (e)" : "Switch on (e)"
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

                  // What is shaped, and -- while it plays -- how loud the output
                  // is, with a clip held in red long enough to be seen.
                  Item {
                    width: parent.width
                    implicitHeight: Math.max(summaryText.implicitHeight, levelText.implicitHeight)

                    Text {
                      id: summaryText
                      textFormat: Text.PlainText
                      text: root.summary
                      color: root.dimText
                      font.family: root.barFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.2
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: levelText.left
                      anchors.rightMargin: Style.space(8)
                    }

                    Text {
                      id: levelText
                      visible: root.enabled
                      width: visible ? implicitWidth : 0
                      textFormat: Text.PlainText
                      text: root.clipHeld ? "CLIP" : peakMonitor.peak > 0.001
                        ? (Math.round(20 * Math.log(Math.max(peakMonitor.peak, 0.0001)) / Math.LN10) + " dB")
                        : "—"
                      color: root.clipHeld ? Color.urgent : root.dimText
                      font.family: root.barFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.right: parent.right
                      anchors.verticalCenter: summaryText.verticalCenter
                    }
                  }
                }
              }

              PanelSeparator { foreground: root.barForeground }

              // ---------- Presets ----------
              CollapsibleSection {
                width: parent.width
                gap: Style.space(8)
                bodySpacing: Style.space(8)
                title: "PRESET"
                meta: (root.presetCategory !== "" ? root.presetCategory.toUpperCase() : String(root.preset).toUpperCase())
                  + (root.presetDirty ? " · EDITED" : "")
                metaColor: root.dimText
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                collapsed: root.presetCollapsed
                onToggleRequested: root.setCollapsed("presetCollapsed", !root.presetCollapsed)

                // Everything that acts on the loaded preset shares the picker's
                // row: back to it as saved, save over it, save as a new one,
                // flatten, delete. The icon buttons take the trigger height and
                // are centred on it, so the edges line up.
                Item {
                  width: parent.width
                  implicitHeight: presetDropdown.implicitHeight

                  // The popup labels carry the category ("Genre · Zouk"); the
                  // trigger names the loaded preset by its bare name. PresetPicker
                  // is the shell's searchable dropdown with a KeyField for its
                  // search box: the shell's own one embeds a native text field,
                  // which would read the clipboard inside the shell process.
                  PresetPicker {
                    id: presetDropdown
                    anchors.left: parent.left
                    anchors.right: presetActions.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    currentValue: root.preset
                    triggerLabel: root.preset
                    placeholderText: "Search presets…"
                    options: root.presetOptionList
                    fontFamily: root.barFontFamily
                    foreground: root.barForeground
                    onChanged: function(v) { root.loadPreset(v) }
                  }

                  Row {
                    id: presetActions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    // Only while the curve differs from the preset it names.
                    Button {
                      id: revertButton
                      visible: root.presetDirty && root.presetExists(root.preset)
                      iconText: "󰕌"
                      bordered: true
                      foreground: root.barForeground
                      height: presetDropdown.height
                      enabled: !root.busy
                      tooltipText: "Back to “" + root.preset + "” as saved"
                      onClicked: root.revertPreset()
                    }

                    Button {
                      id: updateButton
                      visible: root.presetDirty && root.isUserPreset(root.preset)
                      iconText: "󰆓"
                      bordered: true
                      foreground: root.barForeground
                      height: presetDropdown.height
                      enabled: !root.busy
                      tooltipText: "Save these bands over “" + root.preset + "”"
                      onClicked: root.updatePreset()
                    }

                    Button {
                      id: saveAsButton
                      iconText: "󰆔"
                      bordered: true
                      selected: root.saveOpen
                      foreground: root.barForeground
                      height: presetDropdown.height
                      tooltipText: "Save as a new preset…"
                      onClicked: root.saveOpen ? (root.saveOpen = false) : root.openSave()
                    }

                    Button {
                      id: resetButton
                      iconText: "󰑐"
                      bordered: true
                      foreground: root.barForeground
                      height: presetDropdown.height
                      tooltipText: "Flatten bands (r) · undo with u"
                      onClicked: root.resetBands()
                    }

                    // Neutral at rest, red only on hover or when armed: a saturated
                    // idle control pulls the eye to the least important action.
                    // First click arms ("Delete?"), the second deletes; the arm
                    // expires after 3 s.
                    Button {
                      id: deletePresetButton
                      readonly property bool deletable: root.isUserPreset(root.preset)
                      property bool armed: false
                      text: armed ? "Delete?" : ""
                      iconText: "󰆴"
                      bordered: true
                      foreground: deletable && (armed || hot) ? Color.urgent : root.barForeground
                      height: presetDropdown.height
                      opacity: deletable ? 1.0 : 0.35
                      enabled: deletable && !root.busy
                      tooltipText: deletable
                        ? (armed ? "Click again to delete “" + root.preset + "”" : "Delete this preset")
                        : "Built-in presets cannot be deleted"
                      onDeletableChanged: armed = false
                      onClicked: {
                        if (!armed) { armed = true; disarmTimer.restart(); return }
                        armed = false
                        disarmTimer.stop()
                        root.deletePreset()
                      }
                    }
                  }

                  Timer {
                    id: disarmTimer
                    interval: 3000
                    onTriggered: deletePresetButton.armed = false
                  }
                }

                // One line on what the loaded preset does, so the list explains
                // itself instead of being a set of names to audition.
                Text {
                  textFormat: Text.PlainText
                  text: root.presetDescription
                  color: root.dimText
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  elide: Text.ElideRight
                }

                // Save as…: the name field opens in place and goes away after.
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.saveOpen
                  height: visible ? implicitHeight : 0

                  KeyField {
                    id: presetNameField
                    width: parent.width - savePresetButton.width - Style.space(6)
                    placeholderText: "Name the new preset…"
                    value: root.saveName
                    foreground: root.barForeground
                    onTextEdited: root.saveName = text
                    onAccepted: root.savePreset()
                    onCancelled: root.saveOpen = false
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
              }

            }
          }

          // The tab bar: one control picks the page below it -- the same
          // segmented control as the mode picker, stretched card-wide so it
          // reads as the card's structure rather than one more inline setting.
          // The BANDS page only exists in parametric mode; leaving that mode
          // while it is showing falls back to the response console. Cell width
          // derives from the panel's fixed content width, never from this
          // control's own width: implicitWidth depends on the cells, so a
          // width-derived cell width feeds back into implicitWidth and loops.
          SegmentedControl {
            id: tabBar
            width: parent.width
            cellWidthOverride: (panel.contentWidth - panel.padding * 2 - tabBar.padding * 2)
              / Math.max(1, tabBar.options ? tabBar.options.length : 1)
            options: root.tabOptions()
            value: root.activeTab
            foreground: root.barForeground
            accent: Color.accent
            background: root.cardBackground
            onChanged: function(v) { root.activeTab = v }
          }
          // The tabbed band. A page's height is capped by what the fixed band
          // leaves of a 760 px card, so the panel itself never needs a second
          // scroll surface -- the area only scrolls when one page is genuinely
          // too tall (a long band list).
          ScrollView {
            id: pageArea
            width: parent.width
            // Deterministic, no binding loop: the page band is bounded by what
            // the fixed band, the tab bar and the status strip leave of the
            // card. The 760 px cap is the same one contentHeight is measured
            // against; the real available height keeps a short screen from
            // overflowing.
            readonly property real heightBudget: Math.max(0,
              Math.min(Style.space(760),
                       panel.availableCardHeight > 0 ? panel.availableCardHeight : Style.space(760))
              - panel.verticalContentInset
              - fixedBand.implicitHeight
              - tabBar.implicitHeight
              - statusStrip.height
              - card.spacing * (statusStrip.visible ? 3 : 2))
            height: Math.min(pageColumn.implicitHeight, heightBudget)
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy: pageColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            Binding {
              target: pageArea.contentItem
              property: "interactive"
              value: pageColumn.implicitHeight > pageArea.height
            }

            Column {
              id: pageColumn
              width: pageArea.availableWidth
              spacing: 0

              // ---------- Response ----------
              // The curve the whole chain draws, from the same biquad formulas
              // the running filter-chain uses. It is the control as well as the
              // readout: a handle sets a band's gain, and its frequency in
              // parametric mode.
              Column {
                visible: root.activeTab === "response"
                width: parent.width
                spacing: Style.space(4)

                // The console's controls: the A/B on the left, the mode on the
                // right.
                Item {
                  width: parent.width
                  implicitHeight: Math.max(compareButton.implicitHeight, modeGroup.implicitHeight)

                  // The A/B: the bands out, at the curve's own loudness, so what is
                  // compared is the tone -- the louder side always sounds better.
                  Button {
                    id: compareButton
                    text: "A/B"
                    bordered: true
                    selected: root.comparing
                    foreground: root.comparing ? Color.accent : root.barForeground
                    enabled: root.enabled && !root.busy
                    height: modeGroup.height
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    tooltipText: root.comparing
                      ? "Hearing Flat at the curve's loudness · click (a) to hear the curve"
                      : "Compare with Flat at the same loudness (a)"
                    onClicked: root.toggleCompare()
                  }

                  // Cells size themselves to their labels, so "Parametric" can no
                  // longer spill onto its neighbour.
                  SegmentedControl {
                    id: modeGroup
                    fontSize: Style.font.caption
                    options: [
                      { value: "graphic", label: "10-band" },
                      { value: "parametric", label: "Parametric" }
                    ]
                    value: root.mode
                    foreground: root.barForeground
                    accent: Color.accent
                    background: root.cardBackground
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.setMode(v) }

                    HoverHandler { id: modeHover }
                    PanelToolTip {
                      visible: modeHover.hovered || modeGroup.activeFocus
                      text: "Mode (m) · " + root.modeMeta
                      fontFamily: root.barFontFamily
                    }
                  }
                }

                // Where the chain's shape lands the signal -- the operating point
                // the meter downstream cannot show once the limiter has taken the
                // top off -- on a line of its own, so it is read in full.
                Text {
                  id: peakText
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.peakSummary
                  // Red once a manual preamp has the limiter really working.
                  color: root.limiterAlarm ? Color.urgent : root.dimText
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }

                ResponseCurve {
                  id: responseCurveItem
                  width: parent.width
                  bands: root.bands
                  handleGains: root.handleGains
                  // The preamp in force: held during a drag, so the OUT line is
                  // what is heard.
                  preamp: root.preamp
                  sampleRate: root.sampleRate
                  spectrum: root.spectrum
                  foreground: root.barForeground
                  accent: Color.accent
                  dimText: root.dimText
                  handleBorder: root.cardBackground
                  background: root.cardBackground
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
                  scrollBy: function(dy) { root.scrollByDelta(dy) }
                  onBandGainMoved: function(i, g) { root.bandGainEdited(i, g, false) }
                  onBandGainCommitted: function(i, g) { root.bandGainEdited(i, g, true) }
                  onBandFreqMoved: function(i, f) { root.editFreq(i, f, false) }
                  onBandFreqCommitted: function(i, f) { root.editFreq(i, f, true) }
                  onBandQCommitted: function(i, q) { root.editQ(i, q, true) }
                  onAddBandRequested: function(f, g) { root.addBandAt(f, g) }
                  onBandBypassToggled: function(i) { root.toggleBandEnabled(i) }
                  onBandSoloToggled: function(i) { root.toggleSolo(i) }
                  onBandRemoveRequested: function(i) { root.removeBand(i) }
                }

                // Parametric: the selected band, every control of it in one row,
                // so a band can be set completely without leaving the curve.
                Item {
                  visible: root.mode === "parametric"
                  width: parent.width
                  implicitHeight: visible ? Math.max(selectedStrip.implicitHeight, stripHint.implicitHeight) : 0
                  readonly property int sel: responseCurveItem.selectedIndex
                  readonly property var band: (sel >= 0 && sel < root.bands.length) ? root.bands[sel] : null

                  ParametricBandRow {
                    id: selectedStrip
                    strip: true
                    visible: parent.band !== null
                    width: parent.width
                    bandIndex: Math.max(0, parent.sel)
                    bandGain: parent.band ? (Number(parent.band.gain) || 0) : 0
                    bandFreq: parent.band ? (Number(parent.band.freq) || 1000) : 1000
                    bandQ: parent.band ? (Number(parent.band.q) || 1.0) : 1.0
                    bandType: parent.band ? String(parent.band.type || "peaking") : "peaking"
                    bandEnabled: parent.band ? parent.band.enabled !== false : true
                    bandSlope: parent.band ? Model.bandSlope(parent.band) : 1
                    soloed: root.soloIndex === parent.sel
                    foreground: root.barForeground
                    dimText: root.dimText
                    bar: root.bar
                    removable: true
                    onFreqCommitted: function(f) { root.editFreq(parent.sel, f, true) }
                    onQCommitted: function(q) { root.editQ(parent.sel, q, true) }
                    onTypeChanged: function(t) { root.setBandType(parent.sel, t) }
                    onEnabledToggled: function(on) { root.setBandEnabled(parent.sel, on) }
                    onSoloToggled: root.toggleSolo(parent.sel)
                    onRemoveRequested: root.removeBand(parent.sel)
                  }

                  Text {
                    id: stripHint
                    visible: parent.band === null
                    width: parent.width
                    textFormat: Text.PlainText
                    text: "Click a band, or double-click the curve to add one."
                    color: root.dimText
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // The preamp serves the curve above it, so it belongs to the
                // console rather than to a section of its own.
                Item {
                  id: preampRow
                  width: parent.width
                  implicitHeight: Math.max(preampLabel.implicitHeight,
                                           preampSlider.implicitHeight,
                                           preampValue.implicitHeight)

                  Text {
                    id: preampLabel
                    textFormat: Text.PlainText
                    text: "PREAMP"
                    color: root.dimText
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    width: headroomLabel.implicitWidth
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PreampSlider {
                    id: preampSlider
                    anchors.left: preampLabel.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: preampValue.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    bar: root.bar
                    minimum: -24
                    // The curve's own headroom is the top of the range: more gain
                    // than that is gain the limiter would have to remove from every
                    // sample.
                    maximum: root.preampMax
                    step: 0.5
                    value: root.preamp
                    opacity: root.enabled ? 1.0 : 0.5
                    // The wheel always scrolls here; dragging and the arrow keys edit.
                    tooltipText: "Preamp: gain before the bands. This curve's ceiling is "
                      + root.preampCeilingText + ". Drag or use the arrow keys; the wheel scrolls the panel."
                    tooltipFontFamily: root.barFontFamily
                    scrollBy: function(dy) { root.scrollByDelta(dy) }
                    onMoved: function(v) { root.editPreamp(v, false) }
                    onReleased: function(v) { root.editPreamp(v, true) }
                    onRightClicked: root.editPreamp(0, true)
                  }

                  Text {
                    id: preampValue
                    textFormat: Text.PlainText
                    text: root.preampReadout
                    color: root.barForeground
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // How the preamp follows the curve. Each choice says in its
                // tooltip what it trades.
                Item {
                  width: parent.width
                  implicitHeight: Math.max(headroomLabel.implicitHeight, headroomGroup.implicitHeight)

                  Text {
                    id: headroomLabel
                    textFormat: Text.PlainText
                    text: "HEADROOM"
                    color: root.dimText
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  SegmentedControl {
                    id: headroomGroup
                    fontSize: Style.font.caption
                    options: [
                      { value: "auto", label: "Safe" },
                      { value: "balanced", label: "Balanced" },
                      { value: "manual", label: "Manual" }
                    ]
                    value: root.headroom
                    enabled: !root.busy
                    foreground: root.barForeground
                    accent: Color.accent
                    background: root.cardBackground
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.setHeadroom(v) }
                    onHovered: function(i, on) { headroomTip.index = on ? i : -1 }

                    PanelToolTip {
                      id: headroomTip
                      property int index: -1
                      visible: index >= 0
                      text: index === 0
                        ? "Safe: the preamp cancels the curve's peak. Nothing can clip and nothing is left to the limiter; a big boost plays everything else quieter."
                        : index === 1
                          ? "Balanced: the preamp cancels what the curve adds to music, plus a margin, and the limiter takes the rare peak above it. Louder than Safe for the same curve; needs the limiter."
                          : "Manual: the preamp stays where you set it, up to this curve's ceiling (" + root.preampCeilingText + ")."
                      fontFamily: root.barFontFamily
                    }
                  }
                }

                Text {
                  visible: root.enabled
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.headroomCaption
                  color: root.dimText
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              // ---------- Bands ----------
              // Graphic: the ten faders are part of the response console, so
              // this page exists for parametric mode only -- a card per band,
              // because a band's type, frequency and Q are as much of the sound
              // as its gain (the four controls any parametric equalizer
              // exposes).
              Column {
                id: parametricColumn
                visible: root.activeTab === "bands"
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
                    bandEnabled: band ? band.enabled !== false : true
                    bandSlope: band ? Model.bandSlope(band) : 1
                    soloed: root.soloIndex === index
                    bandIndex: index
                    foreground: root.barForeground
                    dimText: root.dimText
                    bar: root.bar
                    removable: true
                    scrollBy: function(dy) { root.scrollByDelta(dy) }
                    onGainChanged: function(g) { root.editGain(index, g, false) }
                    onGainCommitted: function(g) { root.editGain(index, g, true) }
                    onFreqCommitted: function(f) { root.editFreq(index, f, true) }
                    onQCommitted: function(q) { root.editQ(index, q, true) }
                    onTypeChanged: function(t) { root.setBandType(index, t) }
                    onEnabledToggled: function(on) { root.setBandEnabled(index, on) }
                    onSoloToggled: root.toggleSolo(index)
                    onRemoveRequested: root.removeBand(index)
                  }
                }

                // The pool's slot budget, next to the control that spends it: a
                // steeper pass filter takes one slot per 12 dB/octave.
                Item {
                  width: parent.width
                  implicitHeight: addBandButton.implicitHeight

                  Button {
                    id: addBandButton
                    text: "Add band"
                    iconText: "󰐕"
                    bordered: true
                    selected: true
                    foreground: root.barForeground
                    enabled: root.slotsUsed < root.maxSlots
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    tooltipText: "A flat bell at 1 kHz; or double-click the curve where the band should be"
                    onClicked: root.addBand()
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.slotsUsed + " of " + root.maxSlots + " filter slots"
                    color: root.dimText
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }


              // ---------- Output ----------
              // Everything after the bands, set and forget. The stage (limiter,
              // dynamics, leveler) is LSP's and is dimmed rather than hidden when
              // LSP is missing: the state is real even when the plugins are not
              // there to act on it. Channels, device curves and app exclusions
              // work either way. Every one of them is a live write -- nothing on
              // this page restarts the chain.
              Column {
                visible: root.activeTab === "output"
                width: parent.width
                spacing: Style.space(8)
                opacity: root.enabled ? 1.0 : 0.6

                Column {
                  width: parent.width
                  spacing: Style.space(8)
                  opacity: root.outputStage ? 1.0 : 0.5

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(limiterLabel.implicitHeight, limiterSwitch.implicitHeight)

                    Text {
                      id: limiterLabel
                      textFormat: Text.PlainText
                      text: "Limiter · −1 dB ceiling, both channels together"
                      color: root.barForeground
                      font.family: root.barFontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: limiterSwitch.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    PowerSwitch {
                      id: limiterSwitch
                      checked: root.limiter === "on"
                      busy: root.busy
                      foreground: root.barForeground
                      accent: Color.accent
                      background: root.cardBackground
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

                  // The device relief: the headroom cut given back after the
                  // limiter, as far as the device's own volume takes it off again.
                  Item {
                    width: parent.width
                    implicitHeight: Math.max(deviceReliefLabel.implicitHeight, deviceReliefSwitch.implicitHeight)

                    Text {
                      id: deviceReliefLabel
                      textFormat: Text.PlainText
                      text: "Give the cut back as the device volume allows"
                      color: root.barForeground
                      font.family: root.barFontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: deviceReliefSwitch.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    PowerSwitch {
                      id: deviceReliefSwitch
                      checked: root.followDeviceVolume
                      busy: root.busy
                      foreground: root.barForeground
                      accent: Color.accent
                      background: root.cardBackground
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      onToggled: root.setDeviceRelief(!root.followDeviceVolume)

                      PanelToolTip {
                        visible: deviceReliefSwitch.containsMouse
                        text: "Below full device volume, play the curve's boost as a boost instead of cutting everything for it"
                        fontFamily: root.barFontFamily
                      }
                    }
                  }

                  Text {
                    visible: root.followDeviceVolume
                    textFormat: Text.PlainText
                    text: root.deviceRelief >= 0.05
                      ? Number(root.deviceRelief).toFixed(1) + " dB given back at this volume."
                      : "Nothing given back now: the device is at full volume, muted, has its volume in hardware (Bluetooth), or the headroom is manual."
                    color: root.dimText
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.width
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Dynamics"
                    color: root.barForeground
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.body
                  }

                  // Three strengths of a music boost, and two characters.
                  SegmentedControl {
                    id: boostGroup
                    width: parent.width
                    fontSize: Style.font.caption
                    cellWidthOverride: (panel.contentWidth - panel.padding * 2 - boostGroup.padding * 2) / 6
                    options: [
                      { value: "off", label: "Off" },
                      { value: "low", label: "Low" },
                      { value: "medium", label: "Med" },
                      { value: "high", label: "High" },
                      { value: "night", label: "Night" },
                      { value: "voice", label: "Voice" }
                    ]
                    value: root.boost
                    foreground: root.barForeground
                    accent: Color.accent
                    background: root.cardBackground
                    onChanged: function(v) { root.setBoost(v) }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: !root.outputStage ? "LSP plugins are not installed; the output stage is inactive."
                      : root.boost === "night" ? "For film and TV at a low volume: quiet dialogue comes up, explosions are held down."
                      : root.boost === "voice" ? "For speech and calls: the voice is levelled, the bass is left alone so rumble cannot pump it."
                      : root.boost === "off" ? "Off: the bands, and nothing else, shape the sound."
                      : "Lifts quiet passages and holds loud ones, in three bands so the bass cannot pump the rest."
                    color: root.dimText
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.width
                    wrapMode: Text.WordWrap
                  }

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(levelerLabel.implicitHeight, levelerSwitch.implicitHeight)

                    Text {
                      id: levelerLabel
                      textFormat: Text.PlainText
                      text: "Leveler · one loudness for every source"
                      color: root.barForeground
                      font.family: root.barFontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: levelerSwitch.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    PowerSwitch {
                      id: levelerSwitch
                      checked: root.leveler === "on"
                      busy: root.busy
                      foreground: root.barForeground
                      accent: Color.accent
                      background: root.cardBackground
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      onToggled: root.setLeveler(root.leveler === "on" ? "off" : "on")

                      PanelToolTip {
                        visible: levelerSwitch.containsMouse
                        text: "A quiet podcast up, a loud master down, before the volume: the volume sets how loud normal is"
                        fontFamily: root.barFontFamily
                      }
                    }
                  }
                }

                PanelSeparator { foreground: root.barForeground }

                Item {
                  width: parent.width
                  implicitHeight: Math.max(channelsLabel.implicitHeight, channelsGroup.implicitHeight)

                  Text {
                    id: channelsLabel
                    textFormat: Text.PlainText
                    text: "Channels"
                    color: root.barForeground
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.body
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Mono plays the whole mix in each ear -- one earbud, or one ear
                  // that hears less; swap fixes a pair worn the wrong way round.
                  SegmentedControl {
                    id: channelsGroup
                    fontSize: Style.font.caption
                    options: [
                      { value: "stereo", label: "Stereo" },
                      { value: "mono", label: "Mono" },
                      { value: "swap", label: "Swap L/R" }
                    ]
                    value: root.channels
                    foreground: root.barForeground
                    accent: Color.accent
                    background: root.cardBackground
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.setChannels(v) }
                  }
                }

                Item {
                  width: parent.width
                  implicitHeight: Math.max(balanceLabel.implicitHeight, balanceSlider.implicitHeight, balanceValue.implicitHeight)

                  Text {
                    id: balanceLabel
                    textFormat: Text.PlainText
                    text: "BALANCE"
                    color: root.dimText
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // The far side is turned down, never the near one up, so the
                  // balance can add no gain the headroom did not plan for.
                  HorizontalGainSlider {
                    id: balanceSlider
                    anchors.left: balanceLabel.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: balanceValue.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    bar: root.bar
                    accent: Color.accent
                    minimum: -1
                    maximum: 1
                    step: 0.05
                    value: root.balance
                    scrollBy: function(dy) { root.scrollByDelta(dy) }
                    onMoved: function(v) { root.editBalance(v, false) }
                    onReleased: function(v) { root.editBalance(v, true) }
                    onRightClicked: root.editBalance(0, true)
                  }

                  Text {
                    id: balanceValue
                    textFormat: Text.PlainText
                    text: Model.formatBalance(root.balance)
                    width: Style.space(36)
                    horizontalAlignment: Text.AlignRight
                    color: root.barForeground
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                PanelSeparator { foreground: root.barForeground }

                // Each output device keeps its own curve: an AutoEq correction for
                // a pair of earbuds stays with the earbuds, and the speakers get
                // their own back when the earbuds go in their case.
                Item {
                  width: parent.width
                  implicitHeight: Math.max(deviceLabelText.implicitHeight, deviceSwitch.implicitHeight)

                  Text {
                    id: deviceLabelText
                    textFormat: Text.PlainText
                    text: "A curve per output device"
                    color: root.barForeground
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    anchors.left: parent.left
                    anchors.right: deviceSwitch.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PowerSwitch {
                    id: deviceSwitch
                    checked: root.deviceMemory
                    busy: root.busy
                    foreground: root.barForeground
                    accent: Color.accent
                    background: root.cardBackground
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.setDeviceMemory(!root.deviceMemory)

                    PanelToolTip {
                      visible: deviceSwitch.containsMouse
                      text: root.deviceMemory
                        ? "Every output remembers the curve it last played; switching outputs switches curves"
                        : "One curve for every output"
                      fontFamily: root.barFontFamily
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.deviceLabel !== ""
                  text: "Playing into " + root.deviceLabel
                    + (root.deviceMemory && root.rememberedDevices.length > 0
                       ? " · " + root.rememberedDevices.length + " other output"
                         + (root.rememberedDevices.length === 1 ? "" : "s") + " remembered"
                       : "")
                  color: root.dimText
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  elide: Text.ElideRight
                }

                PanelSeparator { foreground: root.barForeground }

                // Apps that should not be equalized -- a call, a DAW, a game with
                // its own EQ -- play straight to the device.
                Text {
                  textFormat: Text.PlainText
                  text: "Apps"
                  color: root.barForeground
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.apps.length === 0 && root.excludedApps.length === 0
                    ? "Nothing is playing. Apps show up here while they play; switch one off to keep it off the equalizer."
                    : "Switch an app off to play it straight to the device, without the equalizer."
                  color: root.dimText
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.appRows()

                  Item {
                    required property var modelData
                    width: parent ? parent.width : 0
                    implicitHeight: Math.max(appName.implicitHeight, appSwitch.implicitHeight)

                    Text {
                      id: appName
                      textFormat: Text.PlainText
                      text: modelData.name + (modelData.playing ? "" : "  ·  not playing")
                      color: modelData.excluded ? root.dimText : root.barForeground
                      font.family: root.barFontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: appSwitch.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    PowerSwitch {
                      id: appSwitch
                      checked: !modelData.excluded
                      busy: root.busy
                      foreground: root.barForeground
                      accent: Color.accent
                      background: root.cardBackground
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      onToggled: root.setAppExcluded(modelData.name, !modelData.excluded)
                    }
                  }
                }
              }

              // ---------- AutoEq ----------
              // AutoEq publishes measured headphone corrections; importing one
              // replaces the parametric bands and the preamp together. A search
              // field, the profile it matched, one import -- used once per set
              // of headphones, so it never sat well in the daily instrument.
              Column {
                visible: root.activeTab === "autoeq"
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "Search for a measured headphone correction; importing one replaces the parametric bands and the preamp."
                  color: root.dimText
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  KeyField {
                    id: autoeqField
                    width: parent.width - autoeqSearchButton.width - Style.space(6)
                    placeholderText: "Headphone model…"
                    value: root.autoeqQuery
                    foreground: root.barForeground
                    onTextEdited: root.autoeqQuery = text
                    onAccepted: root.searchAutoEq()
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
              }
            }
          }

          // One line, outside the tabbed band, so a failed save is visible next
          // to the control that failed. An empty strip has zero height: no
          // reserved gap when there is nothing to say.
          Item {
            id: statusStrip
            width: parent.width
            visible: root.statusText !== ""
            implicitHeight: statusTextItem.implicitHeight
            height: visible ? implicitHeight : 0

            Text {
              id: statusTextItem
              textFormat: Text.PlainText
              text: root.statusText
              color: root.error !== "" ? Color.urgent : root.dimText
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
