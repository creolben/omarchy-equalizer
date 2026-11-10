import QtQuick

// Test stand-in for the shell's KeyboardPanel: a plain card the content fills.
Item {
  property Item anchorItem: null
  property var owner: null
  property QtObject bar: null
  property bool open: false
  property Item focusTarget: null
  property int contentWidth: 430
  property int contentHeight: 760
  property int padding: 14
  property real availableCardHeight: 900
  property real verticalContentInset: 28
  default property alias content: holder.data
  function fittedContentWidth(w, cap) { return Math.round(Number(w) || 1) }
  function fittedContentHeight(h, cap) { return Math.round(Math.min((Number(h) || 0) + 28, Number(cap) || 1e9)) }
  width: contentWidth
  height: contentHeight
  Item { id: holder; anchors.fill: parent }
}
