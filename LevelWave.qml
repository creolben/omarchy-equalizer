import QtQuick
import qs.Commons
import "Model.js" as Model

// The output meter: a mirrored waveform envelope drawn from the peak monitor.
//
// The monitor reports one peak per update, not samples, so there is no audio to
// draw. Model.waveSeries() turns that peak into a synthetic envelope (two
// partials inside a window that tapers at both ends); this item only maps those
// numbers onto a filled, mirrored ribbon. The exact level stays in the dB number
// beside the meter, where a single number is easier to read than a shape.
//
// A straight bar with a width animation read as a progress bar. This one has
// ballistics instead: the envelope jumps to a new higher peak immediately and
// releases toward lower peaks, so it shows dynamics rather than a fill
// percentage. When the level falls below a hairline the timer stops and the
// item draws a flat line -- no motion and no CPU when nothing is playing.
//
// The shell does not expose a reduced-motion preference, so there is no setting
// to consult here; inventing one would be a fake preference.
Item {
  id: root

  property real peak: 0          // 0..1, from the peak monitor
  property bool active: false    // panel open and equalizer enabled
  property bool clipped: false   // clip hold or peak > 0.98
  property color foreground: 'white'
  property color urgent: 'red'

  implicitHeight: Style.space(20)

  // Smoothed level the ribbon is drawn from. Attack is instant (the monitor
  // reports a peak, so a rising edge must not lag behind it); release is an
  // 18 % step toward the new peak on every 33 ms frame.
  property real level: 0
  // Phase into the two partials, advanced only while the timer runs.
  property real phase: 0

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function targetPeak() { return Math.max(0, Math.min(1, Number(peak) || 0)) }
  // The Canvas is a child: property bindings can change while it is still being
  // constructed, so a repaint request has to wait until the id is real.
  function repaint() { if (canvas) canvas.requestPaint() }

  // Attack: applied on the peak change itself, so a rising level appears without
  // waiting for the next timer tick.
  function catchPeak() {
    if (!active) return
    var p = targetPeak()
    if (p > level) level = p
  }

  onPeakChanged: {
    catchPeak()
    repaint()
  }

  onActiveChanged: {
    if (active) catchPeak()
    else {
      // Closing the panel (or bypassing the equalizer) also resets the release
      // state, so the next open starts from the current peak rather than from a
      // stale ribbon.
      level = 0
      phase = 0
    }
    repaint()
  }

  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onForegroundChanged: repaint()
  onUrgentChanged: repaint()
  onClippedChanged: repaint()
  onLevelChanged: repaint()
  onPhaseChanged: repaint()

  // One frame per 33 ms while the panel is open, the equalizer is on, and there
  // is a signal worth showing. At rest the condition is false and the timer
  // stops; because `active` is the panel's `opened && enabled`, a closed panel
  // cannot animate this item inside the shell process.
  Timer {
    interval: 22
    repeat: true
    running: root.active && root.level > 0.01
    onTriggered: {
      var p = root.targetPeak()
      if (p >= root.level) root.level = p
      else root.level += (p - root.level) * 0.12
      // Below the idle line the timer stops, so land on exactly zero rather
      // than leaving a residue the next attack would start from.
      if (root.level <= 0.01) root.level = 0
      // Wrap at 10, not 1: the second partial runs at 1.7x the phase, and only
      // a multiple of 10 keeps 1.7 * phase a whole number of cycles -- a wrap
      // at 1 jumped that partial by 0.7 cycle every ~0.73 s.
      root.phase = (root.phase + 0.03) % 10
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

      // Zero reference: the straight bar had no midline, so the eye had no
      // baseline to read the ribbon against.
      ctx.fillStyle = root.rgba(root.foreground, 0.12)
      ctx.fillRect(0, Math.round(mid - hairline / 2), w, hairline)

      // The exact complement of the timer's `level > 0.01`: anything the timer
      // will not animate is drawn as idle, never as a frozen ribbon.
      if (root.level <= 0.01) {
        // Idle is a flat, dashed baseline: the level is genuinely zero, so the
        // meter must not invent motion. It is dashed rather than solid because a
        // solid hairline is indistinguishable from the section separators around
        // it -- at rest this row would read as a double rule, not as a meter.
        var dash = Math.max(2, Style.spaceReal(6))
        var gap = Math.max(2, Style.spaceReal(5))
        ctx.fillStyle = root.rgba(root.foreground, 0.4)
        for (var x0 = 0; x0 < w; x0 += dash + gap)
          ctx.fillRect(x0, Math.round(mid - hairline / 2), Math.min(dash, w - x0), hairline)
        return
      }

      var n = Math.max(8, Math.min(96, Math.round(w / 6)))
      var amplitude = Math.max(1, h / 2 - hairline)
      var color = root.clipped ? root.urgent : root.foreground

      // Three layered ribbons, back to front, each a phase-shifted and smaller
      // copy of the envelope. The overlap of translucent fills gives the soft,
      // flowing depth of stacked waves; the front layer carries the level.
      var layers = [
        { scale: 1.0,  shift: 0.62, alpha: 0.18 },
        { scale: 0.82, shift: 0.31, alpha: 0.32 },
        { scale: 0.62, shift: 0.0,  alpha: 0.85 }
      ]
      for (var k = 0; k < layers.length; k++) {
        var L = layers[k]
        var values = Model.waveSeries(root.level, root.phase + L.shift, n)
        var xs = [], top = [], bottom = []
        for (var i = 0; i < n; i++) {
          xs.push(w * i / (n - 1))
          top.push(mid - values[i] * L.scale * amplitude)
          bottom.push(mid + values[i] * L.scale * amplitude)
        }
        // Smooth edges: quadratic curves through the midpoints of the samples,
        // so the ribbon has no visible corners at any width.
        ctx.beginPath()
        ctx.moveTo(xs[0], top[0])
        for (var t = 1; t < n - 1; t++)
          ctx.quadraticCurveTo(xs[t], top[t], (xs[t] + xs[t + 1]) / 2, (top[t] + top[t + 1]) / 2)
        ctx.lineTo(xs[n - 1], top[n - 1])
        ctx.lineTo(xs[n - 1], bottom[n - 1])
        for (var u = n - 2; u > 0; u--)
          ctx.quadraticCurveTo(xs[u], bottom[u], (xs[u] + xs[u - 1]) / 2, (bottom[u] + bottom[u - 1]) / 2)
        ctx.lineTo(xs[0], bottom[0])
        ctx.closePath()
        ctx.fillStyle = root.rgba(color, L.alpha)
        ctx.fill()
      }
    }
  }
}
