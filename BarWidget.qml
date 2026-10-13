import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar half of the equalizer plugin: the icon in the bar and the IPC surface the
// shell summons. The panel it hosts is a separate file so this file stays a thin
// shell, exactly like the first-party panels under plugins/panels/.
BarWidget {
  id: root
  moduleName: "io.github.creolben.equalizer"

  // Summoned by omarchy-shell shell summon io.github.creolben.equalizer, and by the
  // plugin's own click. Bar.findPanelWidget requires open/close/opened on the
  // bar-widget root, so all three are mirrored off the panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // md-equalizer / md-equalizer-outline: filled means the equalizer is actually
  // processing, outline means bypassed. A bar icon that looked the same in both
  // states would be the one thing this widget must not do.
  readonly property string glyph: panelLoader.item ? panelLoader.item.equalizerGlyph : "󰺣"

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    slotSize: Style.bar.statusSlot
    tooltipText: "Equalizer"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}