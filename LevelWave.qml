import QtQuick
import qs.Commons
import "Model.js" as Model

// The output meter, styled after the "sound wave" Lottie animation: 34 solid
// pill bars, evenly spaced, centred on the midline, each playing the same
// height sequence from its own start offset and at its own fixed scale
// (Model.lottieBars). That irregular stagger is the whole look; there are no
// caps, gradients or glows.
//
// The music drives it rather than a fixed loop, the way a professional
// visualiser would:
//  - Loudness (the spectrum helper's `bands`, or the peak monitor without it)
//    sets how large the shape plays and, gently, how fast.
//  - Each bar also follows its own part of the spectrum (Model.barEnergy): the
//    row is mirrored, bass in the centre and treble at the edges, so a kick
//    lifts the middle and hi-hats flicker the ends.
//  - Every bar moves on a damped spring (Model.springStep), so changes pop with
//    a slight overshoot and settle instead of snapping.
//  - A beat (`beatIn`, from the helper's bass-flux detector, or
//    Model.beatStep() on the peak) is an impulse that radiates out from the
//    centre: the middle bars kick first and hardest, the edges a beat later and
//    softer. Taller bars are drawn brighter, so the hit also reads as light.
//
// Silent: a flat dashed baseline and the frame loop stops.
//
// Drawing is plain Rectangles in the scene graph, driven by a FrameAnimation,
// and all easing is per second of real frame time.
//
// The shell does not expose a reduced-motion preference, so there is none to
// consult here.
Item {
  id: root

  property real peak: 0          // 0..1, from the peak monitor (fallback + clip)
  property var bands: []         // live spectrum, 0..1 per band, may be empty
  property real beatIn: 0        // helper's beat strength for the current frame
  property bool active: false    // panel open and equalizer enabled
  property bool clipped: false   // clip hold or peak > 0.98
  property bool debug: false     // overlay loudness and beats
  property color foreground: 'white'
  property color accent: foreground
  property color urgent: 'red'

  implicitHeight: Style.space(44)

  readonly property int barCount: Model.LOTTIE_BARS
  readonly property real pitch: width / barCount
  readonly property real barWidth: Math.max(1.5, pitch * Model.LOTTIE_FILL)
  readonly property color barColor: clipped ? urgent : accent

  // Animation frame in the source's 20 fps timebase, and the bar heights for
  // it, 0..1 of the full height. `heights` is reassigned as a new array each
  // frame so the bar bindings see the change.
  property real frame: 0
  property var heights: []
  // Smoothed loudness 0..1 and a beat pulse 0..1 (for the debug overlay).
  property real loud: 0
  property real beat: 0
  // Spring state per bar, recent beat impulses still travelling outward, and a
  // running clock for them. Plain arrays; only `heights` is bound to.
  property var springX: []
  property var springV: []
  property var hits: []
  property real clock: 0
  // Peak fallback state.
  property real level: 0
  property real avg: 0
  property int beats: 0          // count, for the debug overlay

  readonly property bool haveBands: (bands || []).length >= 2
  property bool live: false
  // True while the bars are still shrinking after the music stopped.
  property bool settling: false

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function kick(strength) {
    beat = Math.max(beat, strength)
    var h = hits.slice()
    h.push({ t: clock, s: strength })
    hits = h
    beats++
  }

  // Loudness the music is driving the bars with right now, 0..1.
  function targetLoud() {
    if (haveBands) {
      var b = bands, sum = 0
      for (var i = 0; i < b.length; i++) sum += b[i]
      // Ordinary music averages about 0.3..0.5 on the helper's scale.
      return Math.min(1, (sum / b.length) / 0.45)
    }
    return Math.sqrt(level)
  }

  onBandsChanged: {
    if (!active) return
    live = targetLoud() > 0.03 || level > 0.01
    if (beatIn > 0) kick(0.5 + 0.5 * beatIn)
  }

  onPeakChanged: {
    if (!active) return
    var p = Math.max(0, Math.min(1, Number(peak) || 0))
    if (p > level) level = p
    if (!haveBands) {
      live = level > 0.01
      var bs = Model.beatStep(avg, p, beat)
      avg = bs[0]
      if (bs[1] === 1) kick(1)
    }
  }

  onActiveChanged: {
    if (!active) {
      heights = []; springX = []; springV = []; hits = []; clock = 0
      frame = 0; loud = 0; beat = 0; level = 0; avg = 0
      live = false; settling = false
    }
  }

  FrameAnimation {
    running: root.active && (root.live || root.settling)
    onTriggered: {
      var dt = Math.max(0.001, Math.min(0.1, frameTime))

      var p = Math.max(0, Math.min(1, Number(root.peak) || 0))
      if (p >= root.level) root.level = p
      else root.level += (p - root.level) * (1 - Math.exp(-dt / 0.14))
      if (root.level <= 0.01) root.level = 0
      if (!root.haveBands) root.live = root.level > 0.01

      // Loudness rises quickly and falls gently; silence takes it to zero.
      var want = root.live ? root.targetLoud() : 0
      root.loud += (want - root.loud) * (1 - Math.exp(-dt / (want > root.loud ? 0.06 : 0.35)))
      if (!root.live && root.loud < 0.005) root.loud = 0

      root.beat *= Math.exp(-dt / 0.16)
      if (root.beat < 0.01) root.beat = 0

      // The shape plays at the source's 20 fps, a little slower when quiet and
      // a little faster when loud. Beats do not touch the speed: they arrive
      // as impulses below, so the motion never jumps.
      root.frame = (root.frame + dt * Model.LOTTIE_FPS * (0.7 + 0.5 * root.loud)) % Model.LOTTIE_PERIOD
      var shape = Model.lottieBars(root.frame)
      var n = shape.length

      // Any audible music plays the shape at most of its size, as in the
      // source; loudness pushes it the rest of the way. Fades in and out at
      // the edges of silence.
      var gain = root.loud > 0 ? (0.45 + 0.55 * root.loud) * Math.min(1, root.loud / 0.08) : 0

      var xs = root.springX.length === n ? root.springX.slice() : []
      var vs = root.springV.length === n ? root.springV.slice() : []
      if (xs.length !== n) { xs = []; vs = []; for (var z = 0; z < n; z++) { xs.push(0); vs.push(0) } }

      var prev = root.clock
      root.clock += dt
      var hs = root.hits
      var keep = []
      var moving = root.loud > 0.005
      var out = []
      for (var i = 0; i < n; i++) {
        var d = Math.abs((i / (n - 1)) * 2 - 1)        // 0 centre .. 1 edges
        var e = Math.min(1, Model.barEnergy(root.bands, i, n) * 1.4)
        var target = Math.min(1, shape[i] * gain * (0.75 + 0.55 * e))

        // Beat impulses reach bar i after a delay that grows with its distance
        // from the centre, and are weaker at the edges.
        var delay = 0.14 * d
        for (var k = 0; k < hs.length; k++) {
          var age0 = prev - hs[k].t, age1 = root.clock - hs[k].t
          if (age0 < delay && age1 >= delay)
            vs[i] += hs[k].s * 16 * (1 - 0.55 * d) * (0.5 + 0.5 * root.loud)
        }

        var sv = Model.springStep(xs[i], vs[i], target, dt, 4.5, 0.5)
        xs[i] = sv[0]; vs[i] = sv[1]
        out.push(Math.max(0, Math.min(1, xs[i])))
        if (Math.abs(xs[i]) > 0.003 || Math.abs(vs[i]) > 0.02) moving = true
      }
      for (var q = 0; q < hs.length; q++)
        if (root.clock - hs[q].t < 0.2) keep.push(hs[q])
      root.hits = keep
      root.springX = xs
      root.springV = vs
      root.heights = out
      root.settling = moving
    }
  }

  // Midline: a zero reference the bars grow from.
  Rectangle {
    width: parent.width
    height: Math.max(1, Style.spaceReal(1))
    y: Math.round((parent.height - height) / 2)
    color: root.rgba(root.foreground, 0.12)
  }

  // Idle: nothing playing and everything settled. Dashed, because a solid
  // hairline reads as one more section separator.
  Item {
    id: idle
    anchors.fill: parent
    visible: !root.live && !root.settling
    readonly property real dash: Math.max(2, Style.spaceReal(6))
    readonly property real dashGap: Math.max(2, Style.spaceReal(5))
    Repeater {
      model: idle.visible ? Math.ceil(root.width / (idle.dash + idle.dashGap)) : 0
      Rectangle {
        x: index * (idle.dash + idle.dashGap)
        width: Math.min(idle.dash, root.width - x)
        height: Math.max(1, Style.spaceReal(1))
        y: Math.round((root.height - height) / 2)
        color: root.rgba(root.foreground, 0.4)
      }
    }
  }

  // The bars: solid pills, centred in their slot and on the midline. A bar
  // never shrinks below a round dot, as in the source.
  Repeater {
    model: (root.live || root.settling) ? root.barCount : 0
    Rectangle {
      readonly property real level: index < root.heights.length ? root.heights[index] : 0
      // Taller bars glow brighter, so a hit reads as light as well as height.
      opacity: 0.6 + 0.4 * Math.min(1, level * 1.8)
      x: index * root.pitch + (root.pitch - width) / 2
      width: root.barWidth
      height: Math.max(width, level * root.height)
      y: (root.height - height) / 2
      radius: width / 2
      color: root.barColor
    }
  }

  // Debug overlay: loudness, beat count, and a dot that flashes on beats.
  Rectangle {
    visible: root.debug
    width: Style.space(8); height: width; radius: width / 2
    anchors.right: parent.right; anchors.top: parent.top
    color: root.urgent
    opacity: root.beat
  }
  Text {
    visible: root.debug
    anchors.left: parent.left; anchors.top: parent.top
    textFormat: Text.PlainText
    font.pixelSize: Math.max(8, Style.font.caption * 0.8)
    color: root.foreground
    text: (root.haveBands ? "spectrum" : "fallback") + "  loud " + root.loud.toFixed(2) +
          "  beats " + root.beats
  }
}
