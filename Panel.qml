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
  // Channel handling ahead of the bands, and the balance (-1 left .. 1 right).
  readonly property string channels: status ? String(status.channels || "stereo") : "stereo"
  readonly property real balance: status ? (Number(status.balance) || 0) : 0
  // Automatic headroom cuts the whole signal by the curve's peak at full volume;
  // below full volume the backend gives that cut back as far as the volume
  // allows (the relief). The bands are heard under preamp + relief.
  readonly property real relief: status ? (Number(status.relief) || 0) : 0
  readonly property real appliedPreamp: preamp + relief
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

  // The peak of the *shape* -- the line the handles sit on, measured with the
  // preamp at zero -- and then where the preamp together with that shape lands
  // the signal at the limiter's input. That last number is the one that matters:
  // while the limiter is on it is the worst-case gain reduction, and it is what
  // the limiter would otherwise hide. A chain holding +15 dB over the ceiling
  // sounds loud, flat and grainy and never reports a clip, because the limiter
  // is doing exactly its job. The preamp itself has its own row under the curve;
  // the header meta stays short enough to share the line with the mode control.
  readonly property real postPreampPeak: status
    ? metrics.peakDb + preamp
    : 0
  // -1 dBFS is the limiter's ceiling (see limiter_values in the backend); anything
  // above it is removed on every sample. Automatic headroom leaves at most 1 dB by
  // construction (it targets 0 dBFS), so only more than that is worth a warning --
  // which is what a preamp stacked above the curve's own headroom looks like.
  readonly property real limiterWarnDb: 2
  readonly property real limiterDucking: Math.max(0, postPreampPeak + 1)
  // How loud the curve plays against Flat at the same volume: its level (the
  // pink/A-weighted blend the presets are level-matched on) under the preamp it
  // is heard with. A big boost reads as what it costs everything else.
  readonly property real levelVsFlat: metrics.levelDb + appliedPreamp
  readonly property string peakSummary: {
    if (!status) return ""
    if (!enabled) return "BYPASSED"
    if (comparing) return "A/B \u00b7 FLAT AT THE CURVE'S LOUDNESS"
    if (soloIndex >= 0) return "SOLO \u00b7 BAND " + (soloIndex + 1)
    var peak = metrics
    var text
    // The preamp has its own row now, so the header reports the curve's shape
    // and the limiter warning only: the line has to share width with the mode
    // control.
    if (peak.peakDb <= 0.05) text = "NO BOOST"
    else text = "+" + peak.peakDb.toFixed(1) + " dB AT " + Model.formatFreq(peak.peakFreq) + " HZ"
    if (Math.abs(levelVsFlat) >= 0.05)
      text += " \u00b7 " + Model.formatGain(levelVsFlat) + " dB VS FLAT"
    if (limiter === "on" && limiterDucking >= limiterWarnDb)
      text += " \u00b7 LIMITER \u2212" + limiterDucking.toFixed(1) + " dB"
    return text
  }

  // The ceiling is the preamp's top and the one number a manual preamp has to
  // respect. It used to be printed under a scale; now it travels with the two
  // controls that can move the preamp.
  readonly property string preampCeilingText: preampMax < 0
    ? preampMax.toFixed(1) + " dB"
    : "0.0 dB (this curve has no boost to cancel)"

  // AutoEq import: a query, whatever the profile index matched, and a line of
  // feedback so the panel never silently does nothing.
  property string autoeqQuery: ""
  property var autoeqResults: []
  property string autoeqMessage: ""
  property bool autoeqBusy: false
  property real preampPending: 0

  // The panel's one line of feedback, pinned below the tabbed band. A failure
  // wins over the AutoEq progress/result because it is the one the user has to
  // act on; either clears 8 s after it was last written.
  readonly property string statusText: error !== "" ? error : autoeqMessage

  Timer {
    id: statusClearTimer
    interval: 8000
    repeat: false
    onTriggered: {
      root.error = ""
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
  function reportAutoEq(message) {
    autoeqMessage = String(message || "")
    if (autoeqMessage !== "") statusClearTimer.restart()
  }

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
    if (comparing) return "A/B \u00b7 HEARING FLAT"
    if (soloIndex >= 0) return "SOLO \u00b7 BAND " + (soloIndex + 1)
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
  // persists. The tabbed pages retired three of the four fold states; their
  // keys are simply not written, so an old settings file sheds them.
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
    if (name === "set-gain" || name === "set-preamp")
      return name + ":" + String(args[1] || "")
    if (name === "set-balance") return name
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

  function commitPreamp(db) {
    preampPending = Model.clamp(db, -24, preampMax)
    preampCommitTimer.restart()
  }

  function sendPreampNow(db) {
    // An immediate commit supersedes the settle timer: no second write, and a
    // click that changed nothing cannot leave a stale value waiting to fire.
    preampCommitTimer.stop()
    // The slider hands over raw positions like -8.7079. Snap to its 0.5 dB step
    // here, the one place every preamp write passes through -- and hold the
    // curve's ceiling, so the panel never asks the backend for gain it refuses.
    var value = Math.round(Model.clamp(db, -24, preampMax) * 2) / 2
    // A click or arrow that lands on the value already in force is not an edit:
    // it must not quietly switch automatic headroom off.
    var current = Math.round((Number(root.preamp) || 0) * 2) / 2
    if (root.headroom === "auto" && value === current) return
    // A hand-set preamp is the backend's cue to stop tracking the curve.
    withStatus({ preamp: value, headroom: "manual" })
    run(["set-preamp", String(value)])
  }

  // One click: preamp = minus the curve's peak boost (see Model.autoPreampDb).
  readonly property real autoPreamp: metrics.autoPreamp
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
  function setLeveler(value) { withStatus({ leveler: value }); run(["set-leveler", value]) }
  function setChannels(value) { withStatus({ channels: value }); run(["set-channels", value]) }
  // The balance is a drag: echo every step, let the queue keep only the last.
  function setBalance(value) {
    var v = Math.round(Model.clamp(value, -1, 1) * 20) / 20
    withStatus({ balance: v })
    run(["set-balance", String(v)])
  }
  function setDeviceMemory(on) { withStatus({ deviceMemory: on ? "on" : "off" }); run(["set-device-memory", on ? "on" : "off"]) }
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
  function setBandType(index, value) {
    var parsed = Model.parseTypeOption(value)
    var band = bands[index] || {}
    if (String(band.type || "peaking") !== parsed.type) {
      setBandField(index, "type", parsed.type)
      run(["set-band", String(index), "type", parsed.type])
    }
    if (Model.typeHasSlope(parsed.type) && Model.bandSlope(band) !== parsed.slope) {
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
  }

  function commitBand(index, gain) {
    pendingBandIndex = index
    pendingBandGain = Model.clamp(gain, -12, 12)
    bandCommitTimer.restart()
  }

  function sendBandNow(index, gain) {
    // An immediate commit supersedes the settle timer, as for the preamp: a
    // drag's last position must not fire 120 ms after a reset and undo it. A
    // different band still waiting is sent first rather than dropped.
    bandCommitTimer.stop()
    if (pendingBandIndex >= 0 && pendingBandIndex !== index) {
      var waiting = pendingBandIndex
      pendingBandIndex = -1
      sendBandNow(waiting, pendingBandGain)
    }
    pendingBandIndex = -1
    // Local echo first: a slider that waits for a subprocess round trip feels
    // broken on a fast drag.
    var next = bands.slice()
    if (next[index]) {
      var echo = {}
      for (var k in next[index]) echo[k] = next[index][k]
      echo.gain = Model.clamp(gain, -12, 12)
      next[index] = echo
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
      reportError("Name the preset first.")
      return
    }
    saveName = ""
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
        label: presetCategoryLabel(presets[i].category, builtin) + " \u00b7 " + presets[i].name,
        description: presets[i].description || ""
      })
    }
    return options
  }

  // What the loaded preset actually does. Every built-in carries the line in its
  // own file, which is the only place its curve is written down in words; a user
  // preset has no prose, so the caption falls back to the shape of the chain.
  // Worth the row: the list is otherwise a loudness comparison, and every
  // built-in now lands within about 2 dB of Flat, so what changed is the tone.
  readonly property string presetDescription: {
    for (var i = 0; i < presets.length; i++) {
      var p = presets[i]
      if (p && p.name === preset && p.description) return String(p.description)
    }
    var n = mode === "parametric" ? paramCount : graphicCount
    return n + (n === 1 ? " band \u00b7 " : " bands \u00b7 ")
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

  onOpenedChanged: {
    if (opened) refresh()
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
          root.autoeqBusy = false
          root.reportAutoEq(message)
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

  // Live spectrum and beat track of the equalizer output, for the meter. Runs
  // only while the panel is open and the equalizer is on; stopping the process
  // also stops the capture it owns. The beat is set before the bands, because
  // the meter reads it when the bands change.
  property var spectrum: []
  property real spectrumBeat: 0
  // OMARCHY_EQ_METER_DEBUG=1 in the shell's environment shows the raw values.
  readonly property bool meterDebug: Quickshell.env("OMARCHY_EQ_METER_DEBUG") === "1"
  Process {
    id: spectrumProc
    command: [root.pluginDir + "/bin/omarchy-equalizer-spectrum", "omarchy_equalizer"]
    running: root.opened && root.enabled
    stdout: SplitParser {
      onRead: function(line) {
        var frame = Model.parseSpectrumLine(line)
        if (!frame) return
        root.spectrumBeat = frame.beat
        root.spectrum = frame.bands
      }
    }
    onRunningChanged: if (!running) { root.spectrumBeat = 0; root.spectrum = [] }
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
      }
      // The card is a fixed band and a tabbed one. The fixed band (hero,
      // meter, presets) never moves; the pages -- response console, band
      // rows, output stage, AutoEq import -- are one tab bar away from each
      // other, so nothing that is visible ever scrolls away. The page area
      // only scrolls when the page itself is taller than the card can fit
      // (a long band list).
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
                background: root.bar ? root.bar.background : Color.background
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
            // Meter: a live spectrum of the equalizer's output (spectrumProc),
            // with the peak monitor as fallback and for the red CLIP hold. The
            // dB text beside it stays the precise level.
            Row {
              width: parent.width
              spacing: Style.space(6)
              visible: root.enabled

              LevelWave {
                width: parent.width - levelText.implicitWidth - Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                peak: peakMonitor.peak
                bands: root.spectrum
                beatIn: root.spectrumBeat
                accent: Color.accent
                debug: root.meterDebug
                // Only animate while the card is on screen and the EQ is on.
                // The component's timer binds to this property.
                active: root.opened && root.enabled
                clipped: root.clipHeld || peakMonitor.peak > 0.98
                foreground: root.barForeground
                urgent: Color.urgent
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

            // ---------- Presets ----------
            CollapsibleSection {
              width: parent.width
              gap: Style.space(8)
              bodySpacing: Style.space(8)
              title: "PRESET"
              meta: (root.presetCategory !== "" ? root.presetCategory.toUpperCase() : String(root.preset).toUpperCase())
                + (root.presetDirty ? " \u00b7 EDITED" : "")
              foreground: root.barForeground
              fontFamily: root.barFontFamily
              collapsed: root.presetCollapsed
              onToggleRequested: root.setCollapsed("presetCollapsed", !root.presetCollapsed)

              // Reset and delete share the picker row: the picker must never
              // scroll away, and the two actions that act on the loaded preset
              // belong next to it rather than on a foldable header.
              // Uncaptioned dropdown fills the row; the two icon buttons take
              // the trigger height and are centred on it, so the edges line up.
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
                  anchors.right: resetButton.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  currentValue: root.preset
                  triggerLabel: root.preset
                  placeholderText: "Search presets\u2026"
                  options: root.presetOptionList
                  fontFamily: root.barFontFamily
                  foreground: root.barForeground
                  onChanged: function(v) { root.loadPreset(v) }
                }

                Button {
                  id: resetButton
                  iconText: "󰑐"
                  bordered: true
                  foreground: root.barForeground
                  height: presetDropdown.height
                  anchors.right: deletePresetButton.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  tooltipText: "Flatten bands (r)"
                  onClicked: root.resetBands()
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

              // One line on what the loaded preset does, so the list explains
              // itself instead of being a set of names to audition.
              Text {
                textFormat: Text.PlainText
                text: root.presetDescription
                color: Qt.darker(root.barForeground, 1.6)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                elide: Text.ElideRight
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                KeyField {
                  id: presetNameField
                  width: parent.width - savePresetButton.width - Style.space(6)
                  placeholderText: "Save current bands as…"
                  value: root.saveName
                  foreground: root.barForeground
                  onTextEdited: root.saveName = text
                  onAccepted: root.savePreset()
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
          background: root.bar ? root.bar.background : Color.background
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

              // The console's own top line: where the chain's shape lands the
              // signal (the operating point the peak meter downstream cannot
              // show once the limiter has taken the top off), and, stated
              // once, the mode -- the two band sets are a property of the
              // console below, not a page of their own.
              Item {
                width: parent.width
                implicitHeight: Math.max(peakText.implicitHeight, modeGroup.implicitHeight)

                Text {
                  id: peakText
                  textFormat: Text.PlainText
                  text: root.peakSummary
                  // Red once the limiter is really working: that is the
                  // operating point the peak meter downstream cannot show,
                  // because by then the peaks are gone.
                  color: (root.enabled && root.limiter === "on" && root.limiterDucking >= root.limiterWarnDb)
                    ? Color.urgent
                    : Qt.darker(root.barForeground, 1.4)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                  anchors.left: parent.left
                  anchors.right: compareButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                }

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
                  anchors.right: modeGroup.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  tooltipText: root.comparing
                    ? "Hearing Flat at the curve's loudness \u00b7 click (a) to hear the curve"
                    : "Compare with Flat at the same loudness (a)"
                  onClicked: root.toggleCompare()
                }

                // The caption that used to sit under the control is the
                // tooltip. Cells size themselves to their labels, so
                // "Parametric" can no longer spill onto its neighbour.
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
                  background: root.bar ? root.bar.background : Color.background
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onChanged: function(v) { root.setMode(v) }

                  HoverHandler { id: modeHover }
                  PanelToolTip {
                    visible: modeHover.hovered || modeGroup.activeFocus
                    text: "Mode (m) \u00b7 " + root.modeMeta
                    fontFamily: root.barFontFamily
                  }
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
                scrollBy: function(dy) { root.scrollByDelta(dy) }
                onBandGainMoved: function(i, g) { root.commitBand(i, g) }
                onBandGainCommitted: function(i, g) { root.sendBandNow(i, g) }
                onBandFreqCommitted: function(i, f) { root.setBandProperty(i, "freq", f) }
              }

              // One row under the faders: the preamp exists to serve the curve
              // above it, so it belongs to the console rather than to a section
              // of its own. It used to be a folded section with a separator, a
              // scale repeater and a three-line caption -- roughly 100 px for one
              // slider that never leaves the instrument.
              Item {
                id: preampRow
                width: parent.width
                implicitHeight: Math.max(preampLabel.implicitHeight,
                                         preampSlider.implicitHeight,
                                         preampValue.implicitHeight,
                                         autoPreampButton.implicitHeight)

                Text {
                  id: preampLabel
                  textFormat: Text.PlainText
                  text: "PREAMP"
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
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
                  onMoved: function(v) { root.commitPreamp(v) }
                  onReleased: function(v) { root.sendPreampNow(v) }
                  onRightClicked: root.sendPreampNow(0)
                }

                Text {
                  id: preampValue
                  textFormat: Text.PlainText
                  text: (root.appliedPreamp > 0 ? "+" : "") + Number(root.appliedPreamp).toFixed(1) + " dB"
                  color: root.barForeground
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: autoPreampButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                }

                // Sets the preamp to cancel the curve's peak, or hands control
                // back to the user. The tooltip carries the ceiling now that the
                // scale under the slider is gone.
                Button {
                  id: autoPreampButton
                  readonly property bool autoOn: root.headroom === "auto"
                  text: autoOn ? "Auto \u00b7 on" : "Auto \u00b7 off"
                  bordered: true
                  foreground: autoOn ? Color.accent : root.barForeground
                  enabled: !root.busy
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  tooltipText: (autoOn
                    ? "Headroom is automatic: the preamp follows the curve's peak."
                    : "Make headroom automatic (" + root.autoPreamp.toFixed(1) + " dB for this curve).")
                    + " Ceiling " + root.preampCeilingText + "."
                  onClicked: root.setHeadroom(autoOn ? "manual" : "auto")
                }
              }

              // The one line the old three-line caption keeps, and only when it
              // matters: a manual preamp no longer follows the curve, which is
              // easy to miss after a drag switched automatic headroom off.
              Text {
                visible: root.headroom === "auto" && root.relief >= 0.05
                width: parent.width
                textFormat: Text.PlainText
                text: Number(root.preamp).toFixed(1) + " dB at full volume \u00b7 "
                  + Number(root.relief).toFixed(1) + " dB of it given back at this volume, so the boost plays as a boost."
                color: Qt.darker(root.barForeground, 1.6)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                visible: root.headroom === "manual"
                width: parent.width
                textFormat: Text.PlainText
                text: "Manual headroom \u00b7 the preamp stays where you left it."
                color: Qt.darker(root.barForeground, 1.6)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

            }

            // ---------- Bands ----------
            // Graphic: the ten faders are part of the response console, so
            // this page exists for parametric mode only -- a row per band,
            // because a band's type, frequency and Q are as much of the sound
            // as its gain (the same four Audio Hijack's Parametric EQ block
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
                  bar: root.bar
                  removable: true
                  scrollBy: function(dy) { root.scrollByDelta(dy) }
                  onGainChanged: function(g) { root.commitBand(index, g); }
                  onGainCommitted: function(g) { root.sendBandNow(index, g); }
                  onFreqCommitted: function(f) { root.setBandProperty(index, "freq", f); }
                  onQCommitted: function(q) { root.setBandProperty(index, "q", q); }
                  onTypeChanged: function(t) { root.setBandType(index, t); }
                  onEnabledToggled: function(on) { root.setBandEnabled(index, on); }
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
                  onClicked: root.addBand()
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.slotsUsed + " of " + root.maxSlots + " filter slots"
                  color: Qt.darker(root.barForeground, 1.6)
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
                  background: root.bar ? root.bar.background : Color.background
                  onChanged: function(v) { root.setBoost(v) }
                }

                Text {
                  textFormat: Text.PlainText
                  text: !root.outputStage ? "LSP plugins are not installed; the output stage is inactive."
                    : root.boost === "night" ? "For film and TV at a low volume: quiet dialogue comes up, explosions are held down."
                    : root.boost === "voice" ? "For speech and calls: the voice is levelled, the bass is left alone so rumble cannot pump it."
                    : root.boost === "off" ? "Off: the bands, and nothing else, shape the sound."
                    : "Lifts quiet passages and holds loud ones, in three bands so the bass cannot pump the rest."
                  color: Qt.darker(root.barForeground, 1.6)
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
                    background: root.bar ? root.bar.background : Color.background
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
                  background: root.bar ? root.bar.background : Color.background
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
                  color: Qt.darker(root.barForeground, 1.4)
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
                  onMoved: function(v) { balanceValue.text = Model.formatBalance(v) }
                  onReleased: function(v) { root.setBalance(v) }
                  onRightClicked: root.setBalance(0)
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
                  background: root.bar ? root.bar.background : Color.background
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
                color: Qt.darker(root.barForeground, 1.6)
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
                color: Qt.darker(root.barForeground, 1.6)
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
                    color: modelData.excluded ? Qt.darker(root.barForeground, 1.4) : root.barForeground
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
                    background: root.bar ? root.bar.background : Color.background
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
                color: Qt.darker(root.barForeground, 1.6)
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
            color: root.error !== "" ? Color.urgent : Qt.darker(root.barForeground, 1.4)
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
