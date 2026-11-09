import QtQuick
import QtTest
import "../.."

// The parametric band row's switch: a click on the number bypasses the band, a
// right-click solos it, and the type picker carries the slope of a pass filter
// ("highpass:2" is a 24 dB/octave high-pass). Offscreen, against stand-ins for
// the shell kit (tests/qml/imports).
Item {
  id: scene
  width: 520
  height: 80

  property var toggles: []
  property int solos: 0
  property var types: []

  ParametricBandRow {
    id: row
    width: 500
    bandIndex: 2
    bandType: "highpass"
    bandSlope: 2
    bandFreq: 80
    bandQ: 0.71
    onEnabledToggled: function(on) { scene.toggles = scene.toggles.concat([on]) }
    onSoloToggled: scene.solos++
    onTypeChanged: function(t) { scene.types = scene.types.concat([t]) }
  }

  TestCase {
    name: "BandRow"
    when: windowShown

    function findBadge() {
      // The badge is the first BorderSurface with a round radius after the card.
      for (var i = 0; i < row.children.length; i++) {
        var c = row.children[i]
        if (c && c.width === row.badgeSize && c.height === row.badgeSize) return c
      }
      return null
    }

    function test_click_bypasses_and_right_click_solos() {
      var b = findBadge()
      verify(b !== null, "the badge exists")
      mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton)
      compare(scene.toggles, [false], "a click on an enabled band asks to bypass it")
      row.bandEnabled = false
      mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton)
      compare(scene.toggles, [false, true], "a click on a bypassed band asks to switch it back on")
      mouseClick(b, b.width / 2, b.height / 2, Qt.RightButton)
      compare(scene.solos, 1, "a right-click asks to solo it")
      row.bandEnabled = true
    }

    function test_type_picker_carries_the_slope() {
      var picker = null
      for (var i = 0; i < row.children.length; i++)
        if (row.children[i] && row.children[i].options !== undefined && row.children[i].choose !== undefined) picker = row.children[i]
      verify(picker !== null, "the type picker exists")
      compare(picker.value, "highpass:2", "a slope-2 high-pass shows as the 24 dB/oct entry")
      var labels = picker.options.map(function(o) { return o.label })
      verify(labels.indexOf("High pass 48") >= 0, "the steepest high-pass is offered")
      verify(labels.indexOf("Peaking") >= 0 && labels.indexOf("Peaking 12") < 0, "a bell is offered once, without a slope")
      picker.choose("lowpass:3")
      compare(scene.types, ["lowpass:3"], "a pick hands the type and slope on together")
    }
  }
}
