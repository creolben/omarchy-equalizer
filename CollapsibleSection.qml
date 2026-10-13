import QtQuick
import qs.Commons
import qs.Ui

// A panel section with a clickable header (title, dim meta summary, chevron)
// and a body that folds away. The collapsed state is owned by the caller: the
// section only reports the click -- `collapsed: uiState.xCollapsed` plus
// `onToggleRequested: uiState.xCollapsed = !uiState.xCollapsed` -- so the
// header can never argue with the persisted value.
//
// The body clips while its height animates, so the fold is visible instead of
// a pop. Content stays in the layout tree (implicitHeight, not visible), so a
// drag in progress elsewhere is not cancelled by a fold next to it.
Item {
  id: root

  property string title: ""
  // Right-of-title summary (peak readout, current value, band count). Kept
  // visible while collapsed too: the folded section still says what it holds.
  property string meta: ""
  property color metaColor: Qt.darker(foreground, 1.4)
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property color accent: Color.accent
  property bool collapsed: false
  // Header-to-body distance (response hugs its header tighter than the rest)
  // and the body's own row spacing; both mirror the Columns this replaced.
  property real gap: Style.space(6)
  property real bodySpacing: Style.space(6)

  signal toggleRequested()

  default property alias content: bodyColumn.data
  // Optional control that stays on the header line (Auto, Reset): to the left
  // of the chevron, clickable even while the section is folded.
  property alias accessory: accessorySlot.data

  implicitHeight: sectionColumn.implicitHeight

  Column {
    id: sectionColumn
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: root.gap

    Item {
      id: headerRow
      width: parent.width
      implicitHeight: Math.max(titleText.implicitHeight, accessorySlot.implicitHeight, chevron.implicitHeight)

      // Lowest z: the accessory buttons above it must keep their clicks.
      MouseArea {
        id: headerMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleRequested()
      }

      PanelSectionHeader {
        id: titleText
        text: root.title
        foreground: root.collapsed ? Qt.lighter(root.foreground, 1.15) : root.foreground
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: metaText
        textFormat: Text.PlainText
        text: root.meta
        visible: text !== ""
        color: root.metaColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        anchors.left: titleText.right
        anchors.leftMargin: Style.space(10)
        anchors.right: accessorySlot.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
      }

      Item {
        id: accessorySlot
        implicitWidth: childrenRect.width
        implicitHeight: childrenRect.height
        anchors.right: chevron.left
        anchors.rightMargin: implicitWidth > 0 ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter
      }

      // Glyph swap instead of a rotation: the direction is data, not a transform
      // -- a right chevron means folded, a down chevron means open.
      Text {
        id: chevron
        textFormat: Text.PlainText
        text: root.collapsed ? "󰅂" : "󰅀"
        color: headerMouse.containsMouse ? root.accent : Qt.darker(root.foreground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Behavior on color { ColorAnimation { duration: 120 } }
      }
    }

    Item {
      id: bodyClip
      width: parent.width
      clip: true
      implicitHeight: root.collapsed ? 0 : bodyColumn.implicitHeight
      opacity: root.collapsed ? 0.0 : 1.0
      visible: implicitHeight > 0

      Behavior on implicitHeight { NumberAnimation { duration: 140; easing.type: Easing.InOutCubic } }
      Behavior on opacity { NumberAnimation { duration: 120 } }

      Column {
        id: bodyColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: root.bodySpacing
      }
    }
  }
}
