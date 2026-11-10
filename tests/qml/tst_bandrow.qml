import QtQuick
import QtTest
import "../.."
import "../../Model.js" as Model

// The parametric band row's switch: a click on the number bypasses the band, a
// right-click solos it -- and the labelled Bypass and Solo buttons do the same
// where they can be seen -- and the type picker carries the slope of a pass
// filter ("highpass:2" is a 24 dB/octave high-pass). The frequency field takes
// kHz with a k, commits nothing when left as it was, and ↑/↓ nudge it.
// Offscreen, against stand-ins for the shell kit (tests/qml/imports).
Item {
  id: scene
  width: 520
  height: 80

  property var toggles: []
  property int solos: 0
  property var types: []
  property var freqs: []
  property var qs: []

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
    onFreqCommitted: function(f) { scene.freqs = scene.freqs.concat([f]) }
    onQCommitted: function(q) { scene.qs = scene.qs.concat([q]) }
  }

  ParametricBandRow {
    id: strip
    y: 100
    width: 500
    strip: true
    bandIndex: 0
    bandGain: -15
    bandFreq: 1250
    bandQ: 1.41
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

    function findButton(item, label) {
      for (var i = 0; i < item.children.length; i++) {
        var c = item.children[i]
        if (c && c.text !== undefined && c.bordered !== undefined && String(c.text).indexOf(label) === 0) return c
      }
      return null
    }

    function findField(item, placeholder) {
      for (var i = 0; i < item.children.length; i++) {
        var c = item.children[i]
        if (c && c.placeholderText === placeholder && c.steppable !== undefined) return c
      }
      return null
    }

    function test_labelled_buttons_bypass_and_solo() {
      var bypass = findButton(row, "Bypass"), solo = findButton(row, "Solo")
      verify(bypass !== null && solo !== null, "the row names both")
      scene.toggles = []
      bypass.clicked()
      compare(scene.toggles, [false], "Bypass asks to take the band out")
      row.bandEnabled = false
      compare(bypass.text, "Bypassed", "and says when it is out")
      verify(bypass.selected)
      bypass.clicked()
      compare(scene.toggles, [false, true], "and to put it back")
      row.bandEnabled = true
      var before = scene.solos
      solo.clicked()
      compare(scene.solos, before + 1, "Solo asks to hear it alone")
    }

    function test_frequency_field_takes_khz_and_nudges() {
      var field = findField(row, "Hz")
      verify(field !== null, "the frequency field exists")
      compare(field.text, "80", "it shows Hz below 1 kHz")
      field.forceActiveFocus()
      keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace)
      keyClick(Qt.Key_2); keyClick(Qt.Key_Period); keyClick(Qt.Key_5); keyClick(Qt.Key_K)
      keyClick(Qt.Key_Return)
      compare(scene.freqs, [2500], "2.5k is 2500 Hz")
      row.bandFreq = 2500
      field.text = row.freqText(2500)
      keyClick(Qt.Key_Return)
      compare(scene.freqs, [2500], "a field left as it was commits nothing")
      keyClick(Qt.Key_Up)
      compare(scene.freqs[scene.freqs.length - 1], Model.stepFreq(2500, 1), "↑ moves it 1/24 octave")
      row.bandFreq = 80
    }

    function test_q_field_nudges_by_bandwidth() {
      var field = findField(row, "Q")
      verify(field !== null, "the Q field exists")
      field.forceActiveFocus()
      keyClick(Qt.Key_Down)
      compare(scene.qs[scene.qs.length - 1], Model.stepQ(0.71, -1), "↓ widens it a sixth of an octave")
    }

    function test_strip_is_one_line_with_a_wide_range() {
      verify(strip.implicitHeight < row.implicitHeight, "the strip is one line, the row two")
      compare(strip.gainSpan, 24, "a band at -15 dB gets the ±24 dB range, so a touch cannot clamp it")
      compare(findField(strip, "Hz").text, "1.25k", "the strip shows kHz above 1 kHz")
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
