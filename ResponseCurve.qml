import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The response view: what the chain does to the signal, drawn from the same
// biquad formulas the running filter-chain uses (Model.js, held to PipeWire's
// own source by tests/curve-check.js).
//
// One framed console. The plot is the top region: a recessed rect with the dB
// scale in a left gutter, one point of curve per pixel of width, a handle per
// band, and the output the preamp leaves behind as a second, dashed line.
// Behind the curve, softly, the shape of what is playing (the spectrum the
// meter helper reads off the equalizer's own output). In graphic mode the ten
// faders sit below the plot *inside the same frame*, each column on the log
// position its own band occupies on the frequency axis -- so a fader's number
// is directly under the part of the curve it moves.
//
// The curve and the handles are drawn from one array, `bands`, and nothing
// else: the panel echoes every move of a drag into it before the backend has
// heard of it, so the line follows the hand on every frame and nothing snaps
// back on release. In graphic mode the handles and faders show what the curve
// does at each band's centre (`handleGains`, the panel's fit) rather than the
// bells' own gains, which overlap; in parametric mode a handle is its band's
// gain, as in any parametric equalizer.
Item {
  id: root

  property var bands: []
  // Graphic mode: the response at each band's centre, which is what a handle
  // and a fader show and set. Empty means "the bands' own gains".
  property var handleGains: []
  property real preamp: 0
  property int sampleRate: 48000
  // The spectrum helper's levels, 0..1, low bands first (empty when idle).
  property var spectrum: []

  property color foreground: 'white'
  property color accent: 'white'
  property color handleBorder: 'black'
  property color background: 'black'
  property string fontFamily: Style.font.family
  // Secondary text, at the dimmest shade that still reads (Model.dimColor).
  property color dimText: Qt.darker(foreground, 1.6)

  property bool editable: false
  property bool freqEditable: false
  // Parametric mode: Q on the wheel and on [ ], and the band keys (b, s, Delete).
  property bool qEditable: freqEditable
  // The fader bank: graphic mode's control, on the plot's own axis.
  property bool showFaders: false
  // Wheel scroll passthrough: the panel injects its scrollByDelta here and the
  // bank's faders call it when the wheel is not theirs.
  property var scrollBy: null

  // The plot is ±18 dB, and ±30 dB while a band or the curve is outside that.
  readonly property real span: wideScale ? 30 : 18
  property real minDb: -span
  property real maxDb: span
  property real floorDb: -42
  property real gainStep: 0.5

  property int dragIndex: -1
  property int hoverIndex: -1
  // The band the keyboard acts on: set by a press on its handle or by ←/→
  // while the curve has focus. -1 until one is chosen.
  property int selectedIndex: -1

  // The eased spectrum the backdrop draws.
  property var backdropLevels: []

  signal bandGainMoved(int index, real gain)
  signal bandGainCommitted(int index, real gain)
  signal bandFreqMoved(int index, real freq)
  signal bandFreqCommitted(int index, real freq)
  signal bandQCommitted(int index, real q)
  signal addBandRequested(real freq, real gain)
  signal bandBypassToggled(int index)
  signal bandSoloToggled(int index)
  signal bandRemoveRequested(int index)

  readonly property real minFreq: 20
  readonly property real maxFreq: 20000
  readonly property color dim: dimText
  readonly property var gridFreqs: [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
  readonly property var minorFreqs: [40, 50, 80, 100, 200, 300, 400, 600, 800, 3000, 5000, 6000, 10000, 12000]

  readonly property var curveMetrics: Model.metrics(bands, sampleRate)
  readonly property bool wideScale: {
    if (curveMetrics.peakDb > 18 || curveMetrics.troughDb < -18) return true
    for (var i = 0; i < bands.length; i++) {
      if (Math.abs(bandGainAt(i)) > 18) return true
      if (bands[i] && Math.abs(Number(bands[i].gain) || 0) > 18) return true
    }
    return false
  }
  // The bank's range: ±12 dB, or ±24 dB while any band reads outside ±12.
  readonly property real faderSpan: {
    for (var i = 0; i < bands.length; i++) if (Model.gainSpan(bandGainAt(i)) > 12) return 24
    return 12
  }

  // Every coordinate helper maps into these rectangles, so hit-testing, the
  // curve, the grid and the faders can never disagree about where a frequency
  // sits.
  readonly property real gutterLeft: Style.space(30)
  readonly property real padTop: Style.space(6)
  readonly property real padRight: Style.space(12)
  readonly property real plotX: gutterLeft
  readonly property real plotY: padTop
  readonly property real plotW: Math.max(1, width - gutterLeft - padRight)
  readonly property real gutterBottom: Style.space(5) + Style.font.caption + Style.space(4)

  // Fader bank geometry. The bank lives inside the console, below the plot, so
  // the plot gives up the height it takes (and its own bottom gutter, whose
  // labels the console keeps one row lower, under the faders).
  readonly property real faderTravel: Style.space(140)
  readonly property real faderLabelH: Style.font.caption + Style.space(4)
  readonly property real faderGap: showFaders ? Style.space(8) : 0
  readonly property real faderZoneH: showFaders ? faderLabelH + faderTravel : 0
  readonly property int faderColumnWidth: Math.max(Style.space(24),
    Math.min(Style.space(40),
      Math.round(plotW / Math.max(1, bands.length) - Style.space(2))))

  readonly property real plotH: Math.max(1, height - padTop - faderGap - faderZoneH - gutterBottom)
  readonly property real faderY: plotY + plotH + faderGap
  readonly property real consoleBottom: faderY + faderZoneH

  implicitHeight: showFaders ? Style.space(372) : Style.space(196)
  implicitWidth: Style.space(400)

  function xFor(freq) {
    var f = Math.max(minFreq, Math.min(maxFreq, Number(freq) || 1000))
    return plotX + plotW * (Math.log(f / minFreq) / Math.log(maxFreq / minFreq))
  }

  function freqForX(x) {
    var t = Math.max(0, Math.min(1, (x - plotX) / plotW))
    return minFreq * Math.pow(maxFreq / minFreq, t)
  }

  function yFor(db) {
    var d = Math.max(minDb, Math.min(maxDb, Number(db) || 0))
    return plotY + plotH * (maxDb - d) / (maxDb - minDb)
  }

  function dbForY(y) {
    var t = Math.max(0, Math.min(1, (y - plotY) / plotH))
    return maxDb - t * (maxDb - minDb)
  }

  function snapGain(db, step) {
    var s = Number(step) > 0 ? Number(step) : (Number(gainStep) > 0 ? Number(gainStep) : 0.5)
    return Math.round(db / s) * s
  }

  function snapFreq(f) { return Math.round(Math.max(minFreq, Math.min(maxFreq, Number(f) || 1000))) }

  // What a band's handle shows: the response at its centre in graphic mode
  // (the panel's handleGains), its own gain otherwise.
  function bandGainAt(index) {
    if (handleGains && index >= 0 && index < handleGains.length && handleGains[index] !== undefined)
      return Number(handleGains[index]) || 0
    var b = bands[index]
    return b ? Number(b.gain) || 0 : 0
  }

  function bandFreqAt(index) {
    var b = bands[index]
    return b ? Number(b.freq) || 1000 : 1000
  }

  function bandQAt(index) {
    var b = bands[index]
    return b ? Number(b.q) || 1 : 1
  }

  // Every band has a handle: a bypassed one is hollow and can still be moved
  // (that is how it is tuned before it is switched back on), and a filter
  // without a gain sits on the 0 dB line and moves sideways only.
  function hasHandle(index) { return !!bands[index] }
  function handleHasGain(index) {
    var b = bands[index]
    return !!b && (b.type === undefined || Model.typeHasGain(b.type))
  }

  // A band's gain range: ±12 dB, or ±24 dB for a band already outside that.
  function gainLimitFor(index) {
    var b = bands[index]
    return Model.gainSpan(Math.max(Math.abs(bandGainAt(index)), b ? Math.abs(Number(b.gain) || 0) : 0))
  }

  // Where a band's handle is drawn. drawHandles() and the tests read the same
  // function, so a test on it is a test on the drawing.
  function handleXFor(index) { return xFor(bandFreqAt(index)) }
  function handleYFor(index) { return yFor(handleHasGain(index) ? bandGainAt(index) : 0) }

  // The grab radius: 18 px, but never more than half the gap between the two
  // closest handles, so a press between neighbours cannot reach past the one it
  // is nearer to. It never shrinks below the drawn handle itself.
  function hitRadius() {
    var r = Style.space(18)
    var pts = []
    for (var i = 0; i < bands.length; i++) {
      if (!hasHandle(i)) continue
      pts.push({ x: handleXFor(i), y: handleYFor(i) })
    }
    for (var a = 0; a < pts.length; a++) {
      for (var c = a + 1; c < pts.length; c++) {
        var dx = pts[a].x - pts[c].x, dy = pts[a].y - pts[c].y
        r = Math.min(r, Math.sqrt(dx * dx + dy * dy) / 2)
      }
    }
    return Math.max(Math.max(6, Style.space(8)), r)
  }

  // The nearest handle within the grab radius, or -1.
  function nearestBand(x, y) {
    var best = -1, bestDistance = hitRadius()
    for (var i = 0; i < bands.length; i++) {
      if (!hasHandle(i)) continue
      var dx = handleXFor(i) - x
      var dy = handleYFor(i) - y
      var d = Math.sqrt(dx * dx + dy * dy)
      if (d < bestDistance) { bestDistance = d; best = i }
    }
    return best
  }

  // ←/→ walk the handles; from nothing selected the first step lands on the
  // first or last handle.
  function stepSelection(direction) {
    var n = bands.length
    if (n === 0) return
    var i = selectedIndex
    for (var tries = 0; tries < n; tries++) {
      if (i < 0 || i >= n) i = direction > 0 ? 0 : n - 1
      else i = (i + direction + n) % n
      if (hasHandle(i)) { selectedIndex = i; return }
    }
  }

  function selectedOk() { return selectedIndex >= 0 && selectedIndex < bands.length && hasHandle(selectedIndex) }

  function nudgeSelected(delta) {
    if (!selectedOk() || !handleHasGain(selectedIndex)) return
    var lim = gainLimitFor(selectedIndex)
    var step = Math.abs(delta) < gainStep ? Math.abs(delta) : gainStep
    var g = Math.max(-lim, Math.min(lim, snapGain(bandGainAt(selectedIndex) + delta, step)))
    bandGainCommitted(selectedIndex, g)
  }

  function nudgeFreq(steps) {
    if (!freqEditable || !selectedOk()) return
    bandFreqCommitted(selectedIndex, Model.stepFreq(bandFreqAt(selectedIndex), steps))
  }

  function nudgeQ(steps) {
    if (!qEditable || !selectedOk()) return
    bandQCommitted(selectedIndex, Model.stepQ(bandQAt(selectedIndex), steps))
  }

  activeFocusOnTab: editable
  // Every other key goes on to the panel's key catcher (e / m / r / a / u, Escape).
  Keys.onPressed: function(event) {
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var plain = (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
    event.accepted = true
    if (plain && event.key === Qt.Key_Left) {
      if (shift && freqEditable) nudgeFreq(-1); else stepSelection(-1)
    } else if (plain && event.key === Qt.Key_Right) {
      if (shift && freqEditable) nudgeFreq(1); else stepSelection(1)
    } else if (plain && event.key === Qt.Key_Up) {
      nudgeSelected(shift ? 0.1 : gainStep)
    } else if (plain && event.key === Qt.Key_Down) {
      nudgeSelected(shift ? -0.1 : -gainStep)
    } else if (plain && event.key === Qt.Key_0 && selectedOk() && handleHasGain(selectedIndex)) {
      bandGainCommitted(selectedIndex, 0)
    } else if (plain && qEditable && event.key === Qt.Key_BracketLeft) {
      nudgeQ(-1)
    } else if (plain && qEditable && event.key === Qt.Key_BracketRight) {
      nudgeQ(1)
    } else if (plain && !shift && qEditable && event.key === Qt.Key_B && selectedOk()) {
      bandBypassToggled(selectedIndex)
    } else if (plain && !shift && qEditable && event.key === Qt.Key_S && selectedOk()) {
      bandSoloToggled(selectedIndex)
    } else if (plain && qEditable && event.key === Qt.Key_Delete && selectedOk()) {
      bandRemoveRequested(selectedIndex)
    } else {
      event.accepted = false
    }
  }
  onActiveFocusChanged: {
    if (activeFocus && selectedIndex < 0) stepSelection(1)
    repaint()
  }

  function repaint() { canvas.requestPaint() }

  onBandsChanged: {
    if (selectedIndex >= bands.length) selectedIndex = -1
    repaint()
  }
  onHandleGainsChanged: repaint()
  onPreampChanged: repaint()
  onSampleRateChanged: repaint()
  onWidthChanged: { repaint(); backdrop.requestPaint() }
  onHeightChanged: { repaint(); backdrop.requestPaint() }
  onDragIndexChanged: repaint()
  onHoverIndexChanged: repaint()
  onSelectedIndexChanged: repaint()
  onForegroundChanged: repaint()
  onAccentChanged: repaint()
  onMinDbChanged: repaint()
  onSpectrumChanged: {
    backdropLevels = Model.easeLevels(backdropLevels, spectrum, 0.18)
    backdrop.requestPaint()
  }

  // The spectrum behind the curve: a canvas of its own, so the curve is not
  // repainted 40 times a second. Its scale is the helper's own relative one --
  // it shows the shape of what is playing, so it carries no dB labels.
  Canvas {
    id: backdrop
    anchors.fill: parent
    onPaint: {
      var ctx = getContext('2d')
      ctx.reset()
      var pts = Model.spectrumPoints(root.backdropLevels)
      if (pts.length < 2) return
      ctx.save()
      ctx.beginPath()
      ctx.rect(root.plotX, root.plotY, root.plotW, root.plotH)
      ctx.clip()
      var base = root.plotY + root.plotH
      var top = root.plotH * 0.82
      ctx.beginPath()
      ctx.moveTo(root.xFor(pts[0].freq), base)
      var prevX = root.xFor(pts[0].freq), prevY = base - pts[0].level * top
      ctx.lineTo(prevX, prevY)
      for (var i = 1; i < pts.length; i++) {
        var x = root.xFor(pts[i].freq), y = base - pts[i].level * top
        var mx = (prevX + x) / 2, my = (prevY + y) / 2
        ctx.quadraticCurveTo(prevX, prevY, mx, my)
        prevX = x; prevY = y
      }
      ctx.lineTo(prevX, prevY)
      ctx.lineTo(prevX, base)
      ctx.closePath()
      var grad = ctx.createLinearGradient(0, root.plotY, 0, base)
      grad.addColorStop(0, root.rgba(root.foreground, 0.10))
      grad.addColorStop(1, root.rgba(root.foreground, 0.03))
      ctx.fillStyle = grad
      ctx.fill()
      ctx.restore()
    }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    onPaint: {
      var ctx = getContext('2d')
      ctx.reset()
      root.drawFrame(ctx)
      ctx.save()
      root.roundedRect(ctx, root.plotX, root.plotY, root.plotW, root.consoleBottom - root.plotY, Style.cornerRadius)
      ctx.clip()
      root.drawGrid(ctx)
      root.drawCurve(ctx)
      ctx.restore()
      root.drawScales(ctx)
      root.drawHandles(ctx)
      if (root.activeFocus) root.drawFocusRing(ctx)
    }
  }

  // ---- fader bank ---------------------------------------------------------
  // Graphic mode's control. It is a child of this item rather than of the panel
  // so that a column's x comes from xFor() -- the same function the curve and
  // the gridlines are drawn with. Its model is the band count, never the band
  // array: the panel echoes every write back as a new array, and a Repeater over
  // an array rebuilds all ten delegates, which kills the drag in progress.
  // Above the plot's MouseArea, which fills the whole console: without it the
  // plot took every press, hover and wheel over the bank, so a fader could not
  // be dragged, focused (the wheel's arm) or double-clicked back to zero.
  Item {
    id: faderLayer
    z: 1
    visible: root.showFaders
    x: root.plotX
    y: root.faderY
    width: root.plotW
    height: root.faderZoneH

    // The shared zero line of ten faders, continuous across the bank and level
    // with the plot's own 0 dB rule.
    Rectangle {
      y: Math.round(root.faderLabelH + root.faderTravel / 2) - Math.max(1, Style.spaceReal(1)) / 2
      width: parent.width
      height: Math.max(1, Style.spaceReal(1))
      color: root.rgba(root.foreground, 0.18)
    }

    Repeater {
      model: root.showFaders ? root.bands.length : 0

      Item {
        id: faderColumn
        required property int index
        readonly property bool hot: fader.hot

        width: root.faderColumnWidth
        height: faderLayer.height
        // xFor() maps into the console's coordinates, and this layer already
        // starts at plotX, so the gutter is subtracted here -- without it every
        // column lands a whole gutter to the right, on the next band's line.
        x: Math.round(root.xFor(root.bandFreqAt(index)) - root.plotX - width / 2)

        // The number the fader is setting sits over its column and lights up
        // with it; it reads the fader's own live value, not the echoed state.
        Text {
          id: valueLabel
          textFormat: Text.PlainText
          text: Model.formatGain(fader.liveGain)
          color: faderColumn.hot
            ? root.accent
            : (Math.abs(fader.liveGain) < 0.05 ? root.dim : root.foreground)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
        }

        VerticalGainSlider {
          id: fader
          width: parent.width
          height: root.faderTravel
          // Fixed offset, not `valueLabel.bottom`: the bank's shared 0 dB rule is
          // drawn at faderLabelH + travel/2, so the fader's own zero has to land
          // on it exactly.
          anchors.top: parent.top
          anchors.topMargin: root.faderLabelH
          minimum: -root.faderSpan
          maximum: root.faderSpan
          gain: root.bandGainAt(index)
          foreground: root.foreground
          accent: root.accent
          background: root.background
          scrollBy: root.scrollBy
          onGainMoved: function(g) { root.bandGainMoved(index, g) }
          onGainCommitted: function(g) { root.bandGainCommitted(index, g) }
          onResetRequested: root.bandGainCommitted(index, 0)
        }

        // Touching a fader lights the band's handle on the curve and names it in
        // the curve's readout: the two regions are one instrument.
        onHotChanged: {
          if (hot) root.hoverIndex = index
          else if (root.hoverIndex === index && root.dragIndex < 0) root.hoverIndex = -1
        }

        PanelToolTip {
          visible: fader.containsMouse
          text: Model.formatFreq(root.bandFreqAt(index)) + " Hz · double-click to reset"
          fontFamily: root.fontFamily
        }
      }
    }
  }

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function roundedRect(ctx, x, y, w, h, r) {
    var rr = Math.max(0, Math.min(Number(r) || 0, w / 2, h / 2))
    ctx.beginPath()
    ctx.moveTo(x + rr, y)
    ctx.lineTo(x + w - rr, y)
    if (rr > 0) ctx.arcTo(x + w, y, x + w, y + rr, rr)
    ctx.lineTo(x + w, y + h - rr)
    if (rr > 0) ctx.arcTo(x + w, y + h, x + w - rr, y + h, rr)
    ctx.lineTo(x + rr, y + h)
    if (rr > 0) ctx.arcTo(x, y + h, x, y + h - rr, rr)
    ctx.lineTo(x, y + rr)
    if (rr > 0) ctx.arcTo(x, y + rr, x + rr, y, rr)
    ctx.closePath()
  }

  // The console sits on its own recessed surface, like an analyzer window: plot
  // and fader bank in one frame, so the faders are visibly part of the drawing
  // they set.
  function drawFrame(ctx) {
    roundedRect(ctx, plotX, plotY, plotW, consoleBottom - plotY, Style.cornerRadius)
    ctx.fillStyle = rgba(foreground, 0.035)
    ctx.fill()
    ctx.lineWidth = 1
    ctx.strokeStyle = rgba(foreground, 0.10)
    ctx.stroke()
  }

  function drawGrid(ctx) {
    ctx.lineWidth = 1
    ctx.strokeStyle = rgba(foreground, 0.035)
    for (var m = 0; m < minorFreqs.length; m++) {
      var mx = Math.round(xFor(minorFreqs[m])) + 0.5
      ctx.beginPath(); ctx.moveTo(mx, plotY); ctx.lineTo(mx, plotY + plotH); ctx.stroke()
    }
    // The octave lines run the full height of the console, through the fader
    // bank, so a fader stands on the line its band draws on.
    ctx.strokeStyle = rgba(foreground, 0.075)
    for (var i = 0; i < gridFreqs.length; i++) {
      var x = Math.round(xFor(gridFreqs[i])) + 0.5
      ctx.beginPath(); ctx.moveTo(x, plotY); ctx.lineTo(x, consoleBottom); ctx.stroke()
    }
    var stepDb = span > 18 ? 10 : 6
    for (var db = minDb + stepDb; db < maxDb; db += stepDb) {
      var y = Math.round(yFor(db)) + 0.5
      var zero = Math.abs(db) < 0.001
      // 0 dB is the reference everything is measured against, so it is the one
      // horizontal rule that has to read at a glance.
      ctx.strokeStyle = rgba(foreground, zero ? 0.48 : 0.07)
      ctx.lineWidth = zero ? Math.max(1.5, Style.spaceReal(1.5)) : 1
      if (zero) ctx.setLineDash([Style.space(4), Style.space(3)])
      else ctx.setLineDash([])
      ctx.beginPath(); ctx.moveTo(plotX, y); ctx.lineTo(plotX + plotW, y); ctx.stroke()
    }
    ctx.setLineDash([])
  }

  function drawScales(ctx) {
    var caption = Style.font.caption
    ctx.font = caption + 'px ' + fontFamily
    ctx.textAlign = 'right'
    ctx.textBaseline = 'middle'
    var stepDb = span > 18 ? 10 : 6
    for (var db = minDb + stepDb; db < maxDb; db += stepDb) {
      var zero = Math.abs(db) < 0.001
      ctx.fillStyle = rgba(foreground, zero ? 0.75 : 0.42)
      ctx.fillText(zero ? '0' : (db > 0 ? '+' : '') + db, plotX - Style.space(6), yFor(db))
    }
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    ctx.fillStyle = rgba(foreground, 0.42)
    for (var i = 0; i < gridFreqs.length; i++)
      ctx.fillText(Model.formatFreq(gridFreqs[i]), xFor(gridFreqs[i]), consoleBottom + Style.space(5))
  }

  function drawCurve(ctx) {
    var zeroY = yFor(0)
    var ceiling = minDb - 6
    var samples = Math.max(64, Math.round(plotW))
    // Bands alone: the shape the handles set. The preamp is a flat gain, so it is
    // drawn as a second series offset by it, never mixed into the handles' line.
    var series = Model.responseSeries(Model.chainCoefficients(bands, sampleRate),
                                      0, sampleRate, samples, minFreq, maxFreq)
    var points = []
    for (var i = 0; i < samples; i++) {
      var f = minFreq * Math.pow(maxFreq / minFreq, i / (samples - 1))
      points.push({ x: xFor(f), y: yFor(Math.max(ceiling, series[i])) })
    }

    // Area between the curve and 0 dB, strongest at the extremes and fading
    // at the zero line, so boosts and cuts both read by their depth.
    ctx.beginPath()
    for (var p = 0; p < points.length; p++) {
      if (p === 0) ctx.moveTo(points[p].x, points[p].y)
      else ctx.lineTo(points[p].x, points[p].y)
    }
    for (var q = points.length - 1; q >= 0; q--) ctx.lineTo(points[q].x, zeroY)
    ctx.closePath()
    var zeroFrac = Math.max(0.01, Math.min(0.99, (zeroY - plotY) / plotH))
    var grad = ctx.createLinearGradient(0, plotY, 0, plotY + plotH)
    grad.addColorStop(0, rgba(accent, 0.34))
    grad.addColorStop(zeroFrac, rgba(accent, 0.03))
    grad.addColorStop(1, rgba(accent, 0.24))
    ctx.fillStyle = grad
    ctx.fill()

    // Where the preamp actually lands the signal: the same shape, shifted.
    if (Math.abs(Number(preamp) || 0) >= 0.05) {
      var out = []
      for (var s = 0; s < samples; s++)
        out.push({ x: points[s].x, y: yFor(Math.max(ceiling, series[s] + Number(preamp))) })
      ctx.setLineDash([Style.space(3), Style.space(3)])
      strokePath(ctx, out, Math.max(1, Style.spaceReal(1.5)), rgba(accent, 0.45))
      ctx.setLineDash([])
      drawLegend(ctx)
    }

    drawFocusBand(ctx, samples)

    // A soft glow under a crisp line.
    strokePath(ctx, points, Math.max(4, Style.space(6)), rgba(accent, 0.14))
    strokePath(ctx, points, Math.max(2, Style.space(2)), accent)
  }

  // The band under the pointer, as its own bell. Ten octave bands overlap, so the
  // sum runs a dB or two above a band's own gain in the middle of a cluster; this
  // is the band's own share of the line.
  function drawFocusBand(ctx, samples) {
    var index = dragIndex >= 0 ? dragIndex : hoverIndex
    if (index < 0 || index >= bands.length) return
    var b = bands[index]
    if (!b || b.enabled === false) return
    if (b.type !== undefined && !Model.typeHasGain(b.type) && !Model.typeHasSlope(b.type)) return
    if (Model.typeHasGain(b.type || "peaking") && Math.abs(Number(b.gain) || 0) < 0.05) return

    var one = Model.responseSeries(Model.chainCoefficients([b], sampleRate),
                                   0, sampleRate, samples, minFreq, maxFreq)
    var pts = []
    for (var i = 0; i < samples; i++) {
      var f = minFreq * Math.pow(maxFreq / minFreq, i / (samples - 1))
      pts.push({ x: xFor(f), y: yFor(Math.max(floorDb, Math.min(maxDb, one[i]))) })
    }
    ctx.setLineDash([Style.space(2), Style.space(2)])
    strokePath(ctx, pts, Math.max(1, Style.spaceReal(1.5)), rgba(accent, 0.55))
    ctx.setLineDash([])
  }

  // What the two lines are, said once and small, and only while they differ.
  function drawLegend(ctx) {
    var size = Style.font.caption
    ctx.font = size + 'px ' + fontFamily
    ctx.textAlign = 'left'
    ctx.textBaseline = 'middle'
    var seg = Style.space(13)
    var gap = Style.space(5)
    var step = Style.space(9)
    var outW = ctx.measureText('OUT').width
    var eqW = ctx.measureText('EQ').width
    var total = seg + gap + eqW + step + seg + gap + outW
    var x = plotX + plotW - total - Style.space(9)
    var y = plotY + Style.space(7) + size / 2

    ctx.lineWidth = Math.max(1.5, Style.spaceReal(1.5))
    ctx.setLineDash([])
    ctx.strokeStyle = accent
    ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + seg, y); ctx.stroke()
    ctx.fillStyle = rgba(foreground, 0.6)
    ctx.fillText('EQ', x + seg + gap, y)

    x += seg + gap + eqW + step
    ctx.setLineDash([Style.space(3), Style.space(3)])
    ctx.strokeStyle = rgba(accent, 0.45)
    ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + seg, y); ctx.stroke()
    ctx.setLineDash([])
    ctx.fillText('OUT', x + seg + gap, y)
  }

  function strokePath(ctx, points, lineWidth, color) {
    ctx.beginPath()
    for (var s = 0; s < points.length; s++) {
      if (s === 0) ctx.moveTo(points[s].x, points[s].y)
      else ctx.lineTo(points[s].x, points[s].y)
    }
    ctx.lineJoin = 'round'
    ctx.lineCap = 'round'
    ctx.lineWidth = lineWidth
    ctx.strokeStyle = color
    ctx.stroke()
  }

  // The same ring the sliders show: 2 px of accent at 40 % round the console.
  function drawFocusRing(ctx) {
    var w = Math.max(1, Style.space(2))
    roundedRect(ctx, plotX + w / 2, plotY + w / 2, plotW - w, consoleBottom - plotY - w, Style.cornerRadius)
    ctx.lineWidth = w
    ctx.setLineDash([])
    ctx.strokeStyle = rgba(accent, 0.4)
    ctx.stroke()
  }

  function drawHandles(ctx) {
    var radius = Math.max(6, Style.space(8))
    var numberSize = Math.max(8, Style.font.caption - 1)
    for (var i = 0; i < bands.length; i++) {
      var b = bands[i]
      if (!b) continue
      var x = handleXFor(i)
      var y = handleYFor(i)
      var bypassed = b.enabled === false
      var gainType = handleHasGain(i)
      var dragging = (i === dragIndex)
      var hot = dragging || (i === hoverIndex && dragIndex < 0)
        || (activeFocus && i === selectedIndex && dragIndex < 0)
      var shaped = gainType ? Math.abs(bandGainAt(i)) >= 0.05 : true
      var r = hot ? radius * 1.2 : radius

      ctx.save()
      if (bypassed && !hot) ctx.globalAlpha = 0.5
      if (hot) {
        ctx.beginPath()
        ctx.arc(x, y, r + Style.space(5), 0, Math.PI * 2)
        ctx.fillStyle = rgba(accent, 0.18)
        ctx.fill()
      }
      ctx.beginPath()
      if (gainType) {
        ctx.arc(x, y, r, 0, Math.PI * 2)
      } else {
        // A filter without a gain: a diamond on the 0 dB line, moved sideways.
        var d = r * 1.15
        ctx.moveTo(x, y - d); ctx.lineTo(x + d, y); ctx.lineTo(x, y + d); ctx.lineTo(x - d, y); ctx.closePath()
      }
      ctx.fillStyle = bypassed ? 'transparent' : (dragging ? accent : handleBorder)
      if (!bypassed) ctx.fill()
      ctx.lineWidth = Math.max(1.5, Style.space(1.75))
      if (bypassed) ctx.setLineDash([Style.space(2), Style.space(2)])
      ctx.strokeStyle = (shaped || hot) ? accent : rgba(foreground, 0.45)
      ctx.stroke()
      ctx.setLineDash([])

      ctx.font = 'bold ' + numberSize + 'px ' + fontFamily
      ctx.textAlign = 'center'
      ctx.textBaseline = 'middle'
      ctx.fillStyle = dragging && !bypassed ? handleBorder : (shaped || hot ? foreground : rgba(foreground, 0.6))
      ctx.fillText(String(i + 1), x, y + 0.5)
      ctx.restore()
    }
    var readout = dragIndex >= 0 ? dragIndex : hoverIndex
    if (readout < 0 && activeFocus) readout = selectedIndex
    if (readout >= 0 && readout < bands.length) drawReadout(ctx, readout)
  }

  // Floating tag with the band's frequency, Q (parametric) and gain, kept
  // inside the plot.
  function drawReadout(ctx, index) {
    var b = bands[index] || {}
    var text = Model.formatFreq(bandFreqAt(index)) + ' Hz'
    if (qEditable) text += '   Q ' + (Math.round(bandQAt(index) * 100) / 100)
    if (handleHasGain(index)) text += '   ' + Model.formatGain(bandGainAt(index)) + ' dB'
    if (b.enabled === false) text += '   off'
    var caption = Style.font.caption
    ctx.font = 'bold ' + caption + 'px ' + fontFamily
    var padX = Style.space(8)
    var boxH = caption + Style.space(10)
    var boxW = ctx.measureText(text).width + padX * 2
    var hx = handleXFor(index)
    var hy = handleYFor(index)
    var gap = Style.space(16)
    var bx = Math.max(plotX + Style.space(4), Math.min(plotX + plotW - boxW - Style.space(4), hx - boxW / 2))
    var by = hy - gap - boxH
    if (by < plotY + Style.space(2)) by = hy + gap

    roundedRect(ctx, bx, by, boxW, boxH, Style.cornerRadius)
    ctx.fillStyle = rgba(handleBorder, 0.94)
    ctx.fill()
    ctx.lineWidth = 1
    ctx.strokeStyle = rgba(accent, 0.55)
    ctx.stroke()
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillStyle = foreground
    ctx.fillText(text, bx + boxW / 2, by + boxH / 2 + 0.5)
  }

  // ---- the drag -------------------------------------------------------------
  // Relative to where the press landed, so grabbing a handle never makes it
  // jump to the pointer. Shift is the fine mode -- 0.1 dB steps and a quarter of
  // the pointer's travel -- and pressing or releasing it mid-drag re-anchors at
  // the current values, so the change of scale makes no jump either.
  property real anchorX: 0
  property real anchorY: 0
  property real anchorGain: 0
  property real anchorFreq: 1000
  property bool dragFine: false
  property bool dragMoved: false
  property real lastGain: 0
  property real lastFreq: 1000

  function anchorAt(x, y, fine) {
    anchorX = x; anchorY = y
    anchorGain = lastGain; anchorFreq = lastFreq
    dragFine = fine
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.editable
    cursorShape: (root.dragIndex >= 0 || root.hoverIndex >= 0)
      ? (root.freqEditable ? Qt.SizeAllCursor : Qt.SizeVerCursor)
      : Qt.ArrowCursor

    onPressed: function(m) {
      var index = root.nearestBand(m.x, m.y)
      // A press on the plot takes keyboard focus, so ←/→ ↑/↓ and 0 work next.
      root.forceActiveFocus()
      if (index < 0) return
      root.lastGain = root.bandGainAt(index)
      root.lastFreq = root.bandFreqAt(index)
      root.anchorAt(m.x, m.y, (m.modifiers & Qt.ShiftModifier) !== 0)
      root.dragMoved = false
      root.dragIndex = index
      root.selectedIndex = index
    }

    onPositionChanged: function(m) {
      if (root.dragIndex < 0) {
        root.hoverIndex = root.nearestBand(m.x, m.y)
        return
      }
      var index = root.dragIndex
      var fine = (m.modifiers & Qt.ShiftModifier) !== 0
      if (fine !== root.dragFine) root.anchorAt(m.x, m.y, fine)
      var scale = fine ? 0.25 : 1
      if (root.handleHasGain(index)) {
        var lim = root.gainLimitFor(index)
        var ddb = -(m.y - root.anchorY) / root.plotH * (root.maxDb - root.minDb) * scale
        var g = Math.max(-lim, Math.min(lim, root.snapGain(root.anchorGain + ddb, fine ? 0.1 : root.gainStep)))
        g = Math.round(g * 10) / 10
        if (g !== root.lastGain) {
          root.lastGain = g
          root.dragMoved = true
          root.bandGainMoved(index, g)
        }
      }
      if (root.freqEditable) {
        var dlog = (m.x - root.anchorX) / root.plotW * Math.log(root.maxFreq / root.minFreq) * scale
        var f = root.snapFreq(root.anchorFreq * Math.exp(dlog))
        if (f !== root.lastFreq) {
          root.lastFreq = f
          root.dragMoved = true
          root.bandFreqMoved(index, f)
        }
      }
      root.repaint()
    }

    onExited: if (root.dragIndex < 0) root.hoverIndex = -1

    // A drag the window lost (the panel closed under it) ends like a release.
    onCanceled: finish()
    onReleased: finish()

    function finish() {
      if (root.dragIndex < 0) return
      var index = root.dragIndex
      root.dragIndex = -1
      if (root.dragMoved) {
        if (root.handleHasGain(index)) root.bandGainCommitted(index, root.lastGain)
        if (root.freqEditable) root.bandFreqCommitted(index, root.lastFreq)
      }
      root.dragMoved = false
      root.repaint()
    }

    onDoubleClicked: function(m) {
      var index = root.nearestBand(m.x, m.y)
      // Drop the drag the second press began, so its release cannot commit the
      // pressed position over the reset.
      root.dragIndex = -1
      root.dragMoved = false
      if (index >= 0) {
        if (root.handleHasGain(index)) root.bandGainCommitted(index, 0)
      } else if (root.freqEditable && m.y >= root.plotY && m.y <= root.plotY + root.plotH) {
        // Empty plot, parametric mode: a band where the pointer is.
        var lim = 12
        var g = Math.max(-lim, Math.min(lim, root.snapGain(root.dbForY(m.y))))
        root.addBandRequested(root.snapFreq(root.freqForX(m.x)), g)
      }
      root.repaint()
    }

    // The wheel over a selected handle (or any handle, with Alt) changes its
    // Q, a sixth of an octave of bandwidth per notch; anywhere else it scrolls
    // the panel, so a wheel crossing the plot never edits.
    onWheel: function(wheel) {
      var dy = Model.wheelDelta(wheel.angleDelta.x, wheel.angleDelta.y, wheel.modifiers)
      var index = root.nearestBand(wheel.x, wheel.y)
      if (root.qEditable && index >= 0
          && Model.wheelOwns("handle", wheel.modifiers, index === root.selectedIndex && root.activeFocus, dy)) {
        root.selectedIndex = index
        root.bandQCommitted(index, Model.stepQ(root.bandQAt(index), dy > 0 ? 1 : -1))
      } else if (root.scrollBy) {
        root.scrollBy(-wheel.angleDelta.y / 2)
      }
      wheel.accepted = true
    }
  }
}
