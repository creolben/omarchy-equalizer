import QtQuick
import QtTest
import "../.."

// PresetPicker: the shell's searchable dropdown with a KeyField search box.
// Typing filters on label and description ("comp" finds Kompa through
// "Haitian compas"), Return picks the first match, Escape closes, the filter
// clears on reopen, and Down from the search starts at the loaded preset.
Item {
  width: 430; height: 500
  property var picked: []
  PresetPicker {
    id: pp
    width: 300
    currentValue: "Rock"
    triggerLabel: "Rock"
    options: [
      { value: "Flat", label: "Reference · Flat", description: "All bands at 0 dB" },
      { value: "Rock", label: "Genre · Rock", description: "Guitars" },
      { value: "Zouk", label: "Genre · Zouk", description: "French Antilles" },
      { value: "Kompa", label: "Genre · Kompa", description: "Haitian compas" }
    ]
    onChanged: function(v) { parent.picked = parent.picked.concat([v]) }
  }
  TestCase {
    when: windowShown
    function test_filter_and_pick() {
      mouseClick(pp, 20, pp.height / 2)
      tryCompare(pp, "popupOpen", true)
      wait(50)
      keyClick(Qt.Key_C); keyClick(Qt.Key_O); keyClick(Qt.Key_M); keyClick(Qt.Key_P)
      compare(pp.filtered.length, 1)
      compare(pp.filtered[0].value, "Kompa")
      keyClick(Qt.Key_Return)
      compare(parent.picked, ["Kompa"])
      tryCompare(pp, "popupOpen", false)
      mouseClick(pp, 20, pp.height / 2)
      tryCompare(pp, "popupOpen", true)
      wait(50)
      keyClick(Qt.Key_Z); keyClick(Qt.Key_O); keyClick(Qt.Key_U)
      compare(pp.filtered.length, 1)
      keyClick(Qt.Key_Escape)
      tryCompare(pp, "popupOpen", false)
      mouseClick(pp, 20, pp.height / 2)
      tryCompare(pp, "popupOpen", true)
      wait(50)
      compare(pp.filtered.length, 4, "filter cleared on reopen")
      keyClick(Qt.Key_Down); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
      compare(parent.picked, ["Kompa", "Zouk"], "Down from search starts at the current row (Rock)")
    }
  }
}
