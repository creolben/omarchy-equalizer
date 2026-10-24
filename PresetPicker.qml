import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// The preset picker: the shell's SearchableDropdown, minus its native search
// field.
//
// The shell's control leads its popup with a Qt Quick Controls TextField, and
// every native Qt text input reads another application's clipboard offer on
// each clipboard change -- unbounded, even while hidden -- inside the shared
// shell process (marketplace review, issue 11753; see KeyField.qml). This copy
// keeps the same trigger, popup, filter and keyboard model and types its search
// into a KeyField instead, so the panel still never instantiates a text input.
//
// Filtering is a case-insensitive substring match on each option's label and
// description, as in the shell's control: "zou" finds "Genre · Zouk" by label,
// "compas" finds Kompa by its description.
//
// Unlike the shell's control the trigger shows `triggerLabel` (the bare preset
// name) rather than the matched option's label, and `currentValue` only marks
// which row is current when the popup opens; selecting emits changed(value).
Item {
  id: root

  property string currentValue: ""
  property string triggerLabel: ""
  property var options: []
  property string placeholderText: "Search..."
  property string emptyText: "No matches"

  property color foreground: Color.popups.text
  property color background: Color.popups.background
  property color popupBorder: Color.popups.border
  property color accent: Color.accent
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property int popupMinHeight: Style.spacing.searchablePopupMinHeight

  readonly property bool popupOpen: popup.opened
  function open() { popup.open() }
  function close() { popup.close() }

  signal changed(string value)

  function optionValue(o) {
    return (o && typeof o === "object") ? String(o.value) : String(o)
  }
  function optionLabel(o) {
    return (o && typeof o === "object") ? String(o.label) : String(o)
  }
  function optionDescription(o) {
    return (o && typeof o === "object" && o.description) ? String(o.description) : ""
  }

  property var filtered: options
  function recomputeFiltered() {
    var q = searchField.text.toLowerCase()
    if (!q) { filtered = options; return }
    var out = []
    for (var i = 0; i < options.length; i++) {
      var lbl = optionLabel(options[i]).toLowerCase()
      var desc = optionDescription(options[i]).toLowerCase()
      if (lbl.indexOf(q) !== -1 || desc.indexOf(q) !== -1) out.push(options[i])
    }
    filtered = out
  }

  function indexOfValue(v) {
    for (var i = 0; i < filtered.length; i++) {
      if (optionValue(filtered[i]) === v) return i
    }
    return -1
  }

  // The status poll hands over a fresh options array every few seconds; keep
  // the highlighted row on the same preset rather than letting it jump.
  onOptionsChanged: {
    var keep = resultList.currentIndex >= 0 && resultList.currentIndex < filtered.length
      ? optionValue(filtered[resultList.currentIndex]) : ""
    recomputeFiltered()
    if (keep !== "") resultList.currentIndex = indexOfValue(keep)
  }

  implicitWidth: Style.spacing.searchableDropdownWidth
  implicitHeight: rowHeight

  BorderSurface {
    id: trigger
    width: parent.width
    height: root.rowHeight
    radius: Style.cornerRadius

    readonly property bool _focused: trigger.activeFocus
    readonly property bool _hot: triggerHover.hovered
    readonly property var _borderSpec: Border.controlSpec(trigger._focused ? "focus" : (trigger._hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

    color: Style.controlFill(trigger._focused, trigger._hot, root.foreground, root.accent)
    borderSpec: _borderSpec

    activeFocusOnTab: true

    HoverHandler { id: triggerHover }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
        popup.opened ? popup.close() : popup.open()
        event.accepted = true
      } else if (event.key === Qt.Key_Escape && popup.opened) {
        popup.close(); event.accepted = true
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: chevron.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
      anchors.rightMargin: trigger.borderRight + Style.spacing.md
      text: root.triggerLabel || root.placeholderText
      color: root.triggerLabel ? root.foreground : Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: chevron
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
      text: "󰅀"
      color: Qt.darker(root.foreground, 1.2)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        trigger.forceActiveFocus()
        popup.opened ? popup.close() : popup.open()
      }
    }

    QQC.Popup {
      id: popup
      x: 0
      y: trigger.height + Style.spacing.xxs
      width: trigger.width
      implicitHeight: Math.max(root.popupMinHeight,
                               Math.min(resultList.contentHeight + Style.space(50),
                                        root.popupRowHeight * 6 + 5 * Style.spacing.labelGap + Style.space(50)))
      padding: Style.spacing.hairline
      leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
      rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
      topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
      bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
      focus: true

      background: BorderSurface {
        color: root.background
        borderSpec: root.popupBorderSpec
        radius: Style.cornerRadius
      }

      onOpened: {
        searchField.text = ""
        root.recomputeFiltered()
        resultList.currentIndex = root.indexOfValue(root.currentValue)
        if (resultList.currentIndex >= 0) resultList.positionViewAtIndex(resultList.currentIndex, ListView.Contain)
        Qt.callLater(function() { searchField.forceActiveFocus() })
      }
      onClosed: searchField.text = ""

      contentItem: Column {
        spacing: 0

        // Down and Up are not text, so the field lets them through to here.
        Item {
          id: searchHeader
          width: parent.width
          height: root.popupRowHeight + Style.spacing.controlPaddingX

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Down) {
              if (resultList.count > 0) {
                if (resultList.currentIndex < 0) resultList.currentIndex = 0
                resultList.forceActiveFocus()
              }
              event.accepted = true
            }
          }

          KeyField {
            id: searchField
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            placeholderText: root.placeholderText
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily

            onTextEdited: {
              root.recomputeFiltered()
              resultList.currentIndex = resultList.count > 0 ? 0 : -1
            }
            onCancelled: popup.close()
            onAccepted: {
              if (resultList.count > 0) {
                if (resultList.currentIndex < 0) resultList.currentIndex = 0
                resultList.selectCurrent()
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.foreground, 0.10)
        }

        Item {
          width: parent.width
          height: popup.height - searchHeader.height - Style.spacing.xxs - 1

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: resultList.count === 0
            text: root.emptyText
            color: Qt.darker(root.foreground, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          ListView {
            id: resultList
            anchors.fill: parent
            spacing: Style.spacing.labelGap
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.filtered
            currentIndex: -1
            keyNavigationEnabled: false

            function selectCurrent() {
              if (currentIndex < 0 || currentIndex >= root.filtered.length) return
              var v = root.optionValue(root.filtered[currentIndex])
              popup.close()
              root.changed(v)
            }

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                popup.close(); event.accepted = true
              } else if (event.key === Qt.Key_Down || event.text === "j") {
                if (resultList.currentIndex < resultList.count - 1)
                  resultList.currentIndex = resultList.currentIndex + 1
                event.accepted = true
              } else if (event.key === Qt.Key_Up || event.text === "k") {
                if (resultList.currentIndex <= 0) searchField.forceActiveFocus()
                else resultList.currentIndex = resultList.currentIndex - 1
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                resultList.selectCurrent(); event.accepted = true
              }
            }

            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool current: root.optionValue(modelData) === root.currentValue
              width: resultList.width
              height: Math.max(root.popupRowHeight, rowContent.implicitHeight + Style.spacing.rowPaddingX)
              color: index === resultList.currentIndex
                ? Style.hoverFillFor(root.foreground, root.accent)
                : "transparent"

              Column {
                id: rowContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.rightMargin: Style.spacing.controlPaddingX
                spacing: Style.spacing.xxs

                Text {
                  textFormat: Text.PlainText
                  text: root.optionLabel(modelData)
                  color: index === resultList.currentIndex
                    ? Style.hoverStateColor(root.foreground, root.accent)
                    : (parent.parent.current ? root.accent : root.foreground)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: parent.parent.current
                  elide: Text.ElideRight
                  width: parent.width
                }
                Text {
                  textFormat: Text.PlainText
                  visible: text !== ""
                  text: root.optionDescription(modelData)
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: resultList.currentIndex = parent.index
                onClicked: resultList.selectCurrent()
              }
            }
          }
        }
      }
    }
  }
}
