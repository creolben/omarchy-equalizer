import QtQuick
import QtTest
import "../.."

// ResponseCurve, offscreen against the shell-kit stand-ins in tests/qml/imports.
//
// - GitHub issue #3: the first drag of a band drew its handle at the 1 kHz
//   fallback, because the press marked the band as dragged before reading its
//   frequency. The handle must stay on the band's own frequency.
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
  property var passedKeys: []

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
      onBandGainMoved: function(i, g) { scene.moved = scene.moved.concat([[i, g]]) }
      onBandGainCommitted: function(i, g) { scene.committed = scene.committed.concat([[i, g]]) }
    }
  }

  TestCase {
    name: "ResponseCurve"
    when: windowShown

    function init() {
      curve.bands = scene.tenBands
      curve.showFaders = true
      curve.freqEditable = false
      curve.dragIndex = -1
      curve.selectedIndex = -1
      curve.draftFreq = 0
      scene.moved = []
      scene.committed = []
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
