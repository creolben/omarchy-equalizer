import QtQuick
import qs.Commons
import "Model.js" as Model

// The output meter: a live spectrum analyser of the equalizer's output, drawn as
// a row of rounded bars mirrored about the midline.
//
// `bands` comes from bin/omarchy-equalizer-spectrum (started by the panel): 24
// levels on a decibel scale, 0..1, bass first, plus a beat strength per frame
// in `beatIn` that the helper detects from bass spectral flux. This item only
// eases and draws: Model.spectrumBars() spreads the bands across the bars, each
// bar rises almost at once and falls over a fifth of a second, a small cap
// hangs above it and drops with gravity, and a beat kicks the bars, sends a
// swell out across the row, and lights a soft glow behind it.
//
// If no spectrum arrives (the helper is missing or failed) the bars fall back
// to Model.barSeries() scaled by the peak monitor, with Model.beatStep() for
// beats, so the meter never sits dead while audio plays. With no signal at all
// it draws a flat dashed baseline and the frame loop stops.
//
// Drawing is plain Rectangles in the scene graph (GPU), driven by a
// FrameAnimation so updates land on the display's own frames. All easing is per
// second of real frame time, so a slow frame moves further instead of hitching.
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
  property bool mirrored: false  // bass in the centre instead of on the left
  property bool debug: false     // overlay band values and beats
  property color foreground: 'white'
  property color accent: foreground
  property color urgent: 'red'

  implicitHeight: Style.space(44)

  readonly property real barWidth: Math.max(1.5, Style.spaceReal(2))
  readonly property real barGap: Math.max(2, barWidth * 1.25)
  readonly property int barCount: Math.max(1, Math.floor((width + barGap) / (barWidth + barGap)))
  readonly property real rowLeft: (width - (barCount * barWidth + (barCount - 1) * barGap)) / 2
  readonly property color barColor: clipped ? urgent : foreground
  readonly property color tipColor: clipped ? urgent : accent

  // Eased heights and caps, 0..1 of the full height. Reassigned as new arrays
  // each frame so the bar bindings see the change.
  property var heights: []
  property var caps: []
  property var capSpeed: []
  // Visible beat pulse (0..1) and the swell it launched (0 at the beat, 1 gone).
  property real beat: 0
  property real ripple: 1
  // Fallback state: smoothed peak, pattern phase, and the peak beat follower.
  property real level: 0
  property real phase: 0
  property real avg: 0
  property int beats: 0          // count, for the debug overlay

  readonly property bool haveBands: (bands || []).length >= 2
  property bool live: false
  // True while any bar or cap is still above the floor, so the loop outlives
  // the signal long enough for everything to settle instead of freezing.
  property bool settling: false

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function kick(strength) {
    beat = Math.max(beat, strength)
    ripple = 0
    beats++
  }

  onBandsChanged: {
    if (!active) return
    var b = bands || []
    var m = 0
    for (var i = 0; i < b.length; i++) m = Math.max(m, b[i])
    live = m > 0.02 || level > 0.01
    if (beatIn > 0) kick(0.55 + 0.45 * beatIn)
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
      heights = []; caps = []; capSpeed = []
      beat = 0; ripple = 1; level = 0; phase = 0; avg = 0
      live = false; settling = false
    }
  }

  FrameAnimation {
    running: root.active && (root.live || root.settling)
    onTriggered: {
      var dt = Math.max(0.001, Math.min(0.1, frameTime))
      var attack = 1 - Math.exp(-dt / 0.015)
      var release = 1 - Math.exp(-dt / 0.22)
      var n = root.barCount

      var hs = root.heights.length === n ? root.heights.slice() : []
      var cs = root.caps.length === n ? root.caps.slice() : []
      var vs = root.capSpeed.length === n ? root.capSpeed.slice() : []
      if (hs.length !== n) {
        hs = []; cs = []; vs = []
        for (var z = 0; z < n; z++) { hs.push(0); cs.push(0); vs.push(0) }
      }

      // Fallback driver: decay the smoothed peak and advance the pattern.
      var p = Math.max(0, Math.min(1, Number(root.peak) || 0))
      if (p >= root.level) root.level = p
      else root.level += (p - root.level) * (1 - Math.exp(-dt / 0.14))
      if (root.level <= 0.01) root.level = 0
      root.phase = (root.phase + 3.7 * dt) % 10

      var target = root.haveBands
        ? Model.spectrumBars(root.bands, n, root.mirrored)
        : Model.barSeries(Math.sqrt(root.level), root.phase, n)

      if (root.ripple < 1) root.ripple = Math.min(1, root.ripple + 2.2 * dt)
      root.beat *= Math.exp(-dt / 0.18)
      if (root.beat < 0.01) root.beat = 0

      var moving = false
      for (var i = 0; i < n; i++) {
        // Swell: a bump that travels out from the centre after each beat.
        var d = Math.abs(((i + 0.5) / n) * 2 - 1)
        var swell = root.ripple < 1
          ? 0.4 * Math.exp(-Math.pow((d - root.ripple) / 0.18, 2)) * (1 - root.ripple)
          : 0
        var t = Math.min(1, target[i] * (1 + 0.55 * root.beat) + swell)

        var cur = hs[i]
        cur += (t - cur) * (t > cur ? attack : release)
        if (cur < 0.003 && t < 0.003) cur = 0
        hs[i] = cur

        // Caps fall with gravity and are pushed back up by the bar.
        vs[i] += 2.6 * dt
        var cap = cs[i] - vs[i] * dt
        if (cap <= cur) { cap = cur; vs[i] = 0 }
        cs[i] = cap

        if (cur > 0.003 || cap > 0.003 || t > 0.003) moving = true
      }
      root.heights = hs
      root.caps = cs
      root.capSpeed = vs
      root.settling = moving
      if (!root.haveBands) root.live = root.level > 0.01
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

  // Beat glow: a soft accent band behind the row, only while a beat fades.
  // Three stacked translucent pills of growing size stand in for a blur, so it
  // needs no shader effect and draws the same on every renderer.
  Repeater {
    model: root.beat > 0.02 && (root.live || root.settling) ? 3 : 0
    Rectangle {
      readonly property real grow: 1 + index * 0.35
      anchors.centerIn: parent
      width: root.width * 0.55 * grow
      height: root.height * (0.3 + 0.4 * root.beat) * grow
      radius: height / 2
      opacity: root.beat * (0.22 - index * 0.06)
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: root.rgba(root.tipColor, 0) }
        GradientStop { position: 0.5; color: root.tipColor }
        GradientStop { position: 1.0; color: root.rgba(root.tipColor, 0) }
      }
    }
  }

  // The bars.
  Repeater {
    model: (root.live || root.settling) ? root.barCount : 0
    Item {
      id: slot
      readonly property real level: index < root.heights.length ? root.heights[index] : 0
      readonly property real capLevel: index < root.caps.length ? root.caps[index] : 0
      readonly property real edge: Math.abs(((index + 0.5) / root.barCount) * 2 - 1)
      readonly property bool capClear: (capLevel - level) * root.height > root.barWidth
      x: root.rowLeft + index * (root.barWidth + root.barGap)
      width: root.barWidth
      height: root.height
      opacity: 1 - 0.45 * edge * edge

      Rectangle {
        width: parent.width
        height: Math.max(width, slot.level * root.height)
        y: (root.height - height) / 2
        radius: width / 2
        // Tips in the accent colour, centre in the foreground: the bars read
        // as light rising out of the midline.
        gradient: Gradient {
          GradientStop { position: 0.0; color: root.tipColor }
          GradientStop { position: 0.5; color: root.barColor }
          GradientStop { position: 1.0; color: root.tipColor }
        }
      }

      // Caps, above and below, only when clear of the bar.
      Rectangle {
        visible: slot.capClear
        width: parent.width
        height: Math.max(1.5, root.barWidth * 0.75)
        radius: height / 2
        y: (root.height - slot.capLevel * root.height) / 2 - height
        color: root.rgba(root.tipColor, 0.8)
      }
      Rectangle {
        visible: slot.capClear
        width: parent.width
        height: Math.max(1.5, root.barWidth * 0.75)
        radius: height / 2
        y: (root.height + slot.capLevel * root.height) / 2
        color: root.rgba(root.tipColor, 0.8)
      }
    }
  }

  // Debug overlay: raw band values, beat count, and a dot that flashes on beats.
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
    text: (root.haveBands ? "spectrum" : "fallback") + "  beats " + root.beats + "\n" +
          (root.bands || []).map(function(v) { return Math.round(v * 99) }).join(" ")
  }
}
