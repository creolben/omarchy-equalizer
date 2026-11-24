import QtQuick

// Test stand-in for the shell's PanelKeyCatcher: the same key dispatch the
// panel relies on -- Escape closes, Return and Space activate, the arrows move,
// and any other single character is a textKey -- with the event left
// unaccepted for text, so it goes on up to the panel's own handler.
Item {
  property bool blocked: false

  signal moveRequested(int dx, int dy)
  signal activateRequested()
  signal returnRequested()
  signal closeRequested()
  signal deleteRequested()
  signal tabRequested(int direction)
  signal textKey(string text)

  focus: true
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (blocked) return
    if (event.key === Qt.Key_Escape) { closeRequested(); event.accepted = true; return }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      tabRequested((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Down) { moveRequested(0, 1); event.accepted = true; return }
    if (event.key === Qt.Key_Up) { moveRequested(0, -1); event.accepted = true; return }
    if (event.key === Qt.Key_Right) { moveRequested(1, 0); event.accepted = true; return }
    if (event.key === Qt.Key_Left) { moveRequested(-1, 0); event.accepted = true; return }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      returnRequested(); activateRequested(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Space) { activateRequested(); event.accepted = true; return }
    if (event.text && event.text.length === 1) textKey(event.text)
  }
}
