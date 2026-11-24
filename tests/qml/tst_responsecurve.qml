import QtQuick
import QtTest
import "../.."
import "../../Model.js" as Model

// ResponseCurve, offscreen against the shell-kit stand-ins in tests/qml/imports.
//
// - GitHub issue #3: the first drag of a band drew its handle at the 1 kHz
//   fallback, because the press marked the band as dragged before reading its
//   frequency. The handle must stay on the band's own frequency.
// - The handle and the line come from one array: during a drag (the scene
//   echoes every move into it, as the panel does) the handle sits on the
//   curve, and after the release it stays where it was let go.
// - Parametric gestures: a double-click on empty plot adds a band there, a
//   pass filter's handle moves sideways only, the wheel over the selected
//   handle sets its Q, and a band outside ±12 dB is never clamped by a touch.
// - The graphic-mode faders sit inside the plot's area; a press on one must
//   reach the fader (drag, focus for the wheel arm), not the plot.
// - Keyboard: ←/→ select a handle, ↑/↓ move it 0.5 dB, 0 resets it; every
//   other key goes on to the panel.
// - The grab radius shrinks when handles crowd, so a press cannot take a
//   handle from beyond its neighbour.
Item {
  id: scene
  width: 460
  height: 420

  property var moved: []
  property var committed: []
  property var freqMoved: []
  property var freqCommitted: []
  property var qCommitted: []
  property var added: []
  property var passedKeys: []
  // When set, the scene echoes moves back into the curve's bands like the panel.
  property bool echo: false

  function echoed(i, key, v) {
    var next = curve.bands.slice()
    var b = {}
    for (var k in next[i]) b[k] = next[i][k]
    b[key] = v
    next[i] = b
    curve.bands = next
  }

  readonly property var tenBands: [
    { freq: 31, gain: 4, q: 1.41 },  { freq: 62, gain: 2, q: 1.41 },
    { freq: 125, gain: -3, q: 1.41 }, { freq: 250, gain: 0, q: 1.41 },
    { freq: 500, gain: 1, q: 1.41 },  { freq: 1000, gain: 0, q: 1.41 },
    { freq: 2000, gain: -2, q: 1.41 }, { freq: 4000, gain: 3, q: 1.41 },
    { freq: 8000, gain: 0, q: 1.41 }, { freq: 16000, gain: 5, q: 1.41 }
  ]

  // Stands in for the panel's key catcher: whatever the curve declines lands here.
  Item {
    id: catcher
    anchors.fill: parent
    focus: true
    Keys.onPressed: function(event) { scene.passedKeys = scene.passedKeys.concat([event.key]) }

    ResponseCurve {
      id: curve
      x: 10
      y: 10
      width: 430
      height: implicitHeight
      editable: true
      showFaders: true
      bands: scene.tenBands
      onBandGainMoved: function(i, g) { scene.moved = scene.moved.concat([[i, g]]); if (scene.echo) scene.echoed(i, "gain", g) }
      onBandGainCommitted: function(i, g) { scene.committed = scene.committed.concat([[i, g]]); if (scene.echo) scene.echoed(i, "gain", g) }
      onBandFreqMoved: function(i, f) { scene.freqMoved = scene.freqMoved.concat([[i, f]]); if (scene.echo) scene.echoed(i, "freq", f) }
      onBandFreqCommitted: function(i, f) { scene.freqCommitted = scene.freqCommitted.concat([[i, f]]); if (scene.echo) scene.echoed(i, "freq", f) }
      onBandQCommitted: function(i, q) { scene.qCommitted = scene.qCommitted.concat([[i, q]]) }
      onAddBandRequested: function(f, g) { scene.added = scene.added.concat([[f, g]]) }
    }
  }

  TestCase {
    name: "ResponseCurve"
    when: windowShown

    function init() {
      curve.bands = scene.tenBands
      curve.handleGains = []
      curve.showFaders = true
      curve.freqEditable = false
      curve.dragIndex = -1
      curve.selectedIndex = -1
      scene.echo = false
      scene.moved = []
      scene.committed = []
      scene.freqMoved = []
      scene.freqCommitted = []
      scene.qCommitted = []
      scene.added = []
      scene.passedKeys = []
      catcher.forceActiveFocus()
    }

    function test_firstDragKeepsTheHandleOnItsBand() {
      var hx = curve.handleXFor(2), hy = curve.handleYFor(2)
      compare(curve.nearestBand(hx, hy), 2, "the press lands on band 3's handle")
      mousePress(curve, hx, hy)
      compare(curve.dragIndex, 2)
      compare(curve.bandFreqAt(2), 125, "the dragged band keeps its frequency")
      fuzzyCompare(curve.handleXFor(2), curve.xFor(125), 0.001,
                   "the handle is drawn at 125 Hz, not at the 1 kHz fallback")
      mouseRelease(curve, hx, hy)
      compare(curve.dragIndex, -1)

      // A second drag of another band must not inherit the first one's frequency.
      var x7 = curve.handleXFor(7), y7 = curve.handleYFor(7)
      mousePress(curve, x7, y7)
      compare(curve.bandFreqAt(7), 4000)
      mouseRelease(curve, x7, y7)
    }

    function test_aPressOnAFaderReachesTheFader() {
      // Band 6 (1 kHz) column, in the fader zone, away from its zero line.
      var fx = curve.xFor(1000)
      var fy = curve.faderY + curve.faderLabelH + curve.faderTravel * 0.25
      compare(curve.nearestBand(fx, fy), -1, "no handle sits over the fader zone")
      mousePress(curve, fx, fy)
      mouseRelease(curve, fx, fy)
      verify(scene.moved.length > 0, "the fader moved its band")
      compare(scene.moved[0][0], 5)
      verify(scene.moved[0][1] > 0, "a press above the zero line boosts")
      verify(!curve.activeFocus, "the fader, not the plot, took focus")
    }

    // The second press of a double-click is a drag too; its release must not
    // commit the pressed position after the reset (the panel's 120 ms settle
    // timer turned that into the last word).
    function test_faderDoubleClickResetsLast() {
      var fx = curve.xFor(1000)
      var fy = curve.faderY + curve.faderLabelH + curve.faderTravel * 0.25
      mouseDoubleClickSequence(curve, fx, fy)
      verify(scene.committed.length > 0)
      compare(scene.committed[scene.committed.length - 1], [5, 0], "the reset is the last commit")
    }

    function test_handleDoubleClickResetsLast() {
      var hx = curve.handleXFor(2), hy = curve.handleYFor(2)
      mouseDoubleClickSequence(curve, hx, hy)
      compare(scene.committed[scene.committed.length - 1], [2, 0], "the reset is the last commit")
      compare(curve.dragIndex, -1)
    }

    function test_bypassedBandKeepsAHollowHandle() {
      // A bypassed band shapes nothing, but it can still be selected and moved:
      // that is how it is tuned before it is switched back on.
      var bands = []
      for (var i = 0; i < scene.tenBands.length; i++) {
        var b = {}
        for (var k in scene.tenBands[i]) b[k] = scene.tenBands[i][k]
        if (i === 3) b.enabled = false
        bands.push(b)
      }
      curve.bands = bands
      verify(curve.hasHandle(3), "a bypassed band keeps its handle")
      compare(curve.nearestBand(curve.handleXFor(3), curve.handleYFor(3)), 3, "and it can be grabbed")
    }

    function test_theHandleRidesTheLineDuringADrag() {
      // Parametric: one band, so the line at its frequency is its own gain.
      curve.showFaders = false
      curve.freqEditable = true
      curve.bands = [{ type: "peaking", freq: 1000, gain: 0, q: 1 }]
      scene.echo = true
      var hx = curve.handleXFor(0), hy = curve.handleYFor(0)
      mousePress(curve, hx, hy)
      mouseMove(curve, hx + 30, hy - 40)
      verify(scene.moved.length > 0 && scene.freqMoved.length > 0, "the drag moved gain and frequency")
      var g = Number(curve.bands[0].gain)
      verify(g > 0, "dragging up boosts")
      fuzzyCompare(curve.handleYFor(0), curve.yFor(g), 0.001, "the handle is drawn at the echoed gain")
      var series = Model.responseSeries(Model.chainCoefficients(curve.bands, 48000), 0, 48000, 2,
                                        curve.bands[0].freq, curve.bands[0].freq * 1.0001)
      fuzzyCompare(series[0], g, 0.01, "and the line passes through it at the band's frequency")
      mouseRelease(curve, hx + 30, hy - 40)
      compare(scene.freqCommitted.length, 1, "the release commits the frequency once")
      var f = scene.freqCommitted[0][1]
      fuzzyCompare(curve.handleXFor(0), curve.xFor(f), 0.001, "after the release the handle stays where it was let go")
      compare(scene.committed[scene.committed.length - 1][1], g, "and the gain it was let go at")
    }

    function test_aPressWithoutAMoveCommitsNothing() {
      curve.showFaders = false
      curve.freqEditable = true
      curve.bands = [{ type: "peaking", freq: 1000, gain: -15, q: 1 }]
      var hx = curve.handleXFor(0), hy = curve.handleYFor(0)
      mousePress(curve, hx + 3, hy + 3)
      mouseRelease(curve, hx + 3, hy + 3)
      compare(scene.committed.length, 0, "a touch is not an edit")
      compare(scene.moved.length, 0, "and the handle did not jump to the pointer")
      // An imported -15 dB cut is outside ±12, so its range is ±24, not a clamp.
      keyClick(Qt.Key_Up)
      compare(scene.committed[scene.committed.length - 1], [0, -14.5], "a nudge from -15 keeps it near -15")
    }

    function test_doubleClickOnEmptyPlotAddsABand() {
      curve.showFaders = false
      curve.freqEditable = true
      curve.bands = [{ type: "peaking", freq: 100, gain: 0, q: 1 }]
      var x = curve.xFor(3000), y = curve.yFor(6)
      mouseDoubleClickSequence(curve, x, y)
      compare(scene.added.length, 1, "one band is asked for")
      verify(Math.abs(scene.added[0][0] - 3000) < 40, "at the pointer's frequency: " + scene.added[0][0])
      compare(scene.added[0][1], 6, "and its gain")
      // Graphic mode has no free frequency, so it adds nothing.
      curve.freqEditable = false
      curve.showFaders = true
      curve.bands = scene.tenBands
      mouseDoubleClickSequence(curve, curve.xFor(90), curve.yFor(-15))
      compare(scene.added.length, 1, "graphic mode does not add bands")
    }

    function test_aPassFilterHandleMovesSidewaysOnly() {
      curve.showFaders = false
      curve.freqEditable = true
      curve.bands = [{ type: "highpass", freq: 80, gain: 0, q: 0.707 }]
      verify(!curve.handleHasGain(0), "a high-pass has no gain to set")
      compare(curve.handleYFor(0), curve.yFor(0), "its handle sits on the 0 dB line")
      var hx = curve.handleXFor(0), hy = curve.handleYFor(0)
      mousePress(curve, hx, hy)
      mouseMove(curve, hx + 40, hy - 50)
      mouseRelease(curve, hx + 40, hy - 50)
      compare(scene.moved.length, 0, "no gain is sent")
      verify(scene.freqMoved.length > 0 && scene.freqMoved[scene.freqMoved.length - 1][1] > 80, "the corner moved up")
    }

    function test_theWheelOverTheSelectedHandleSetsItsQ() {
      curve.showFaders = false
      curve.freqEditable = true
      curve.bands = [{ type: "peaking", freq: 1000, gain: 6, q: 1.41 }]
      var hx = curve.handleXFor(0), hy = curve.handleYFor(0)
      // Not selected yet: the wheel is the panel's.
      mouseWheel(curve, hx, hy, 0, 120)
      compare(scene.qCommitted.length, 0, "an unselected handle does not take the wheel")
      mouseClick(curve, hx, hy)
      compare(curve.selectedIndex, 0)
      mouseWheel(curve, hx, hy, 0, 120)
      compare(scene.qCommitted.length, 1, "the selected handle does")
      compare(scene.qCommitted[0][1], Model.stepQ(1.41, 1), "one notch narrows it a sixth of an octave")
      keyClick(Qt.Key_BracketLeft)
      compare(scene.qCommitted[scene.qCommitted.length - 1][1], Model.stepQ(1.41, -1), "[ widens it")
    }

    function test_graphicHandlesShowTheResponse() {
      // The panel hands the response at each centre; the handles sit there.
      var shown = [5, 4, 3, 2, 1, 0, -1, -2, -3, -4]
      curve.handleGains = shown
      fuzzyCompare(curve.handleYFor(0), curve.yFor(5), 0.001, "band 1's handle is at its response")
      compare(curve.bandGainAt(9), -4)
      mouseClick(curve, curve.xFor(700), curve.yFor(-15))
      keyClick(Qt.Key_Up)
      compare(scene.committed[scene.committed.length - 1], [0, 5.5], "a nudge steps from the response shown")
    }

    function test_keyboardSelectsNudgesAndResets() {
      // A press on empty plot focuses the curve and selects the first handle.
      mouseClick(curve, curve.xFor(700), curve.yFor(-15))
      verify(curve.activeFocus)
      compare(curve.selectedIndex, 0)
      keyClick(Qt.Key_Right)
      keyClick(Qt.Key_Right)
      compare(curve.selectedIndex, 2)
      keyClick(Qt.Key_Up)
      compare(scene.committed[scene.committed.length - 1], [2, -2.5])
      keyClick(Qt.Key_Down)
      compare(scene.committed[scene.committed.length - 1], [2, -3.5])
      keyClick(Qt.Key_0)
      compare(scene.committed[scene.committed.length - 1], [2, 0])
      keyClick(Qt.Key_Left)
      keyClick(Qt.Key_Left)
      keyClick(Qt.Key_Left)
      compare(curve.selectedIndex, 9, "selection wraps")
      compare(scene.passedKeys.length, 0, "the curve's own keys stop at the curve")
      keyClick(Qt.Key_E)
      keyClick(Qt.Key_Escape)
      compare(scene.passedKeys, [Qt.Key_E, Qt.Key_Escape], "other keys reach the panel")
    }

    function test_nudgeIsClampedToTheBandRange() {
      curve.bands = [{ freq: 1000, gain: 12, q: 1, type: "peaking" }]
      curve.showFaders = false
      curve.forceActiveFocus()
      compare(curve.selectedIndex, 0)
      keyClick(Qt.Key_Up)
      compare(scene.committed[scene.committed.length - 1], [0, 12])
    }

    function test_crowdedHandlesShrinkTheGrabRadius() {
      curve.showFaders = false
      curve.freqEditable = true
      curve.bands = [
        { type: "peaking", freq: 1000, gain: 0, q: 1 },
        { type: "peaking", freq: 1000 * Math.pow(1000, 20 / curve.plotW), gain: 0, q: 1 }
      ]
      var x0 = curve.handleXFor(0), x1 = curve.handleXFor(1), y = curve.handleYFor(0)
      verify(Math.abs((x1 - x0) - 20) < 0.5, "handles are 20 px apart")
      verify(curve.hitRadius() <= 10.001, "radius is at most half the gap")
      compare(curve.nearestBand(x0 + 4, y), 0)
      compare(curve.nearestBand(x1 - 4, y), 1)
      compare(curve.nearestBand(x0 - 15, y), -1, "a press 15 px out no longer grabs")
      // Apart, the full radius applies again.
      curve.bands = [{ type: "peaking", freq: 1000, gain: 0, q: 1 }]
      compare(curve.nearestBand(curve.handleXFor(0) - 15, y), 0)
    }
  }
}
