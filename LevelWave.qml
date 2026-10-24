import QtQuick
import qs.Commons
import "Model.js" as Model

// The output meter: a mirrored spectrum analyser drawn from the equalizer's
// real output.
//
// `bands` is a live spectrum (bin/omarchy-equalizer-spectrum, started by the
// panel): 16 values, 0..100, bass first. They are spread across the bars with
// the bass in the middle and the treble at both ends, so the row reads as one
// symmetric wave. Each bar rises quickly and falls slowly, with a small cap that
// hangs and drops, and a bass onset fires a shockwave out from the centre.
//
// If no spectrum arrives (the helper is missing or failed) the bars fall back to
// a synthetic pattern scaled by the peak monitor, so the meter never sits dead
// while audio plays. With no signal at all it draws a flat dashed baseline and
// the timer stops, so nothing runs while nothing plays.
//
// The shell does not expose a reduced-motion preference, so there is none to
// consult here.
Item {
  id: root

  property real peak: 0          // 0..1, from the peak monitor (fallback + clip)
  property var bands: []         // live spectrum, 0..100 per band, may be empty
  property bool active: false    // panel open and equalizer enabled
  property bool clipped: false   // clip hold or peak > 0.98
  property color foreground: 'white'
  property color urgent: 'red'

  implicitHeight: Style.space(64)

  // Smoothed peak, used only by the fallback pattern.
  property real level: 0
  property real phase: 0
  // Beat follower on the bass bands, and the shockwave it launches.
  property real avg: 0
  property real beat: 0
  property real ripple: 1
  // Per-bar smoothed heights and falling caps, 0..1. Plain arrays: they change
  // every frame and nothing binds to them.
  property var heights: []
  property var caps: []
  property real bandMax: 0
  // True while any bar is still moving, so the timer outlives the signal long
  // enough for the bars to settle instead of freezing mid-fall.
  property bool settling: false
  // Timestamp of the previous frame: all easing below is per second, not per
  // frame, so a late timer tick moves the bars further instead of stuttering.
  property real lastFrame: 0

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function targetPeak() { return Math.max(0, Math.min(1, Number(peak) || 0)) }
  function repaint() { if (canvas) canvas.requestPaint() }
  function barCount() {
    var bw = Math.max(2, Style.spaceReal(2.5))
    var gap = Math.max(2, Math.round(bw * 0.8))
    return Math.max(1, Math.floor((width + gap) / (bw + gap)))
  }

  // One band-set per ~33 ms. The beat is read here rather than per frame, so it
  // follows the data rate and not the display rate.
  onBandsChanged: {
    if (!active) return
    var b = bands || []
    var m = 0
    for (var i = 0; i < b.length; i++) m = Math.max(m, Number(b[i]) || 0)
    bandMax = m
    if (b.length >= 4) {
      var bass = ((Number(b[0]) || 0) + (Number(b[1]) || 0) + (Number(b[2]) || 0) + (Number(b[3]) || 0)) / 400
      var bs = Model.beatStep(avg, bass, beat)
      avg = bs[0]
      if (bs[1] === 1) ripple = 0
      beat = bs[1]
    }
  }

  onPeakChanged: {
    if (active && targetPeak() > level) level = targetPeak()
  }

  onActiveChanged: {
    if (!active) {
      level = 0; phase = 0; avg = 0; beat = 0; ripple = 1
      bandMax = 0; heights = []; caps = []; settling = false
    }
    repaint()
  }

  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onForegroundChanged: repaint()
  onUrgentChanged: repaint()
  onClippedChanged: repaint()

  readonly property bool live: bandMax > 2 || level > 0.01

  Timer {
    interval: 16
    repeat: true
    running: root.active && (root.live || root.settling)
    onTriggered: {
      var now = Date.now()
      var dt = root.lastFrame > 0 ? Math.min(0.1, (now - root.lastFrame) / 1000) : 0.016
      root.lastFrame = now
      var attack = 1 - Math.exp(-dt / 0.05)
      var release = 1 - Math.exp(-dt / 0.2)
      var n = root.barCount()
      var hs = root.heights.length === n ? root.heights : []
      var cs = root.caps.length === n ? root.caps : []
      if (hs.length !== n) { hs = []; cs = []; for (var z = 0; z < n; z++) { hs.push(0); cs.push(0) } }

      // Fallback driver, also decays the synthetic level.
      var p = root.targetPeak()
      if (p >= root.level) root.level = p
      else root.level += (p - root.level) * (1 - Math.exp(-dt / 0.14))
      if (root.level <= 0.01) root.level = 0
      root.phase = (root.phase + 3.7 * dt) % 10

      var b = root.bands || []
      var haveBands = b.length >= 2 && root.bandMax > 2
      var synth = haveBands ? null : Model.barSeries(Math.pow(root.level, 0.5), root.phase, n)
      var moving = false
      if (root.ripple < 1) root.ripple = Math.min(1, root.ripple + 2.8 * dt)
      root.beat *= Math.exp(-dt / 0.22)
      if (root.beat < 0.01) root.beat = 0

      for (var i = 0; i < n; i++) {
        var u = (i + 0.5) / n
        var d = Math.abs(2 * u - 1)               // 0 centre .. 1 edges
        var t
        if (haveBands) {
          var pos = d * (b.length - 1)
          var k = Math.floor(pos), f = pos - k
          var a0 = (Number(b[k]) || 0) / 100
          var a1 = (Number(b[Math.min(b.length - 1, k + 1)]) || 0) / 100
          t = a0 + (a1 - a0) * (1 - Math.cos(Math.PI * f)) / 2
          // Edges shorter, so the row has a rounded silhouette.
          t *= 1 - 0.35 * d * d
        } else {
          t = synth[i]
        }
        var swell = root.ripple < 1
          ? 0.35 * Math.exp(-Math.pow((d - root.ripple) / 0.2, 2)) * (1 - root.ripple)
          : 0
        t = Math.min(1, t * (1 + 0.25 * root.beat) + swell)
        var cur = hs[i]
        cur += (t - cur) * (t > cur ? attack : release)
        if (cur < 0.004 && t === 0) cur = 0
        hs[i] = cur
        var cap = cs[i] - 0.6 * dt
        cs[i] = cap > cur ? cap : cur
        if (cur > 0.004 || cs[i] > 0.004 || t > 0) moving = true
      }
      root.heights = hs
      root.caps = cs
      root.settling = moving
      if (!moving) root.lastFrame = 0
      root.repaint()
    }
  }

  Canvas {
    id: canvas
    anchors.fill: parent

    onPaint: {
      var ctx = getContext('2d')
      ctx.reset()
      var w = width, h = height
      if (w <= 0 || h <= 0) return

      var mid = h / 2
      var hairline = Math.max(1, Style.spaceReal(1))
      var color = root.clipped ? root.urgent : root.foreground

      ctx.fillStyle = root.rgba(root.foreground, 0.12)
      ctx.fillRect(0, Math.round(mid - hairline / 2), w, hairline)

      // Nothing playing and every bar settled: a flat dashed baseline. Dashed,
      // because a solid hairline reads as one more section separator.
      if (!root.live && !root.settling) {
        var dash = Math.max(2, Style.spaceReal(6))
        var dgap = Math.max(2, Style.spaceReal(5))
        ctx.fillStyle = root.rgba(root.foreground, 0.4)
        for (var x0 = 0; x0 < w; x0 += dash + dgap)
          ctx.fillRect(x0, Math.round(mid - hairline / 2), Math.min(dash, w - x0), hairline)
        return
      }

      var bw = Math.max(2, Style.spaceReal(2.5))
      var gap = Math.max(2, Math.round(bw * 0.8))
      var n = root.barCount()
      var left = (w - (n * bw + (n - 1) * gap)) / 2
      var hs = root.heights, cs = root.caps
      if (hs.length !== n) return
      var amplitude = Math.max(1, h / 2 - hairline)
      var r = bw / 2

      function pill(x, y, pw, ph) {
        var rr = Math.min(pw, ph) / 2
        ctx.beginPath()
        ctx.moveTo(x + rr, y)
        ctx.arcTo(x + pw, y, x + pw, y + ph, rr)
        ctx.arcTo(x + pw, y + ph, x, y + ph, rr)
        ctx.arcTo(x, y + ph, x, y, rr)
        ctx.arcTo(x, y, x + pw, y, rr)
        ctx.closePath()
      }

      // Bar fill: bright centre fading to the ends.
      var grad = ctx.createLinearGradient(0, 0, w, 0)
      grad.addColorStop(0, root.rgba(color, 0.45))
      grad.addColorStop(0.5, root.rgba(color, 1))
      grad.addColorStop(1, root.rgba(color, 0.45))

      // Beat glow: a wider, faint copy of each bar underneath, only while a beat
      // is fading.
      if (root.beat > 0.05) {
        ctx.fillStyle = root.rgba(color, 0.22 * root.beat)
        for (var g = 0; g < n; g++) {
          var gh = Math.min(h, Math.max(bw, hs[g] * amplitude * 2)) + bw * 2
          pill(left + g * (bw + gap) - bw * 0.75, mid - gh / 2, bw * 2.5, gh)
          ctx.fill()
        }
      }

      ctx.fillStyle = grad
      for (var i = 0; i < n; i++) {
        var bh = Math.min(h, Math.max(bw, hs[i] * amplitude * 2))
        pill(left + i * (bw + gap), mid - bh / 2, bw, bh)
        ctx.fill()
      }

      // Caps: a small pill hanging above and below each bar, falling slowly.
      ctx.fillStyle = root.rgba(color, 0.7)
      for (var c = 0; c < n; c++) {
        var ch = Math.min(h, cs[c] * amplitude * 2)
        var bhc = Math.min(h, Math.max(bw, hs[c] * amplitude * 2))
        if (ch - bhc < bw * 1.2) continue
        var cx = left + c * (bw + gap)
        pill(cx, mid - ch / 2 - bw * 0.2, bw, bw)
        ctx.fill()
        pill(cx, mid + ch / 2 - bw * 0.8, bw, bw)
        ctx.fill()
      }
    }
  }
}
