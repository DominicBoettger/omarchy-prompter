import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.dominicboettger.prompter"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool prompterConnected: panelLoader.item ? panelLoader.item.prompterConnected === true : false
  readonly property string activeMode: panelLoader.item ? panelLoader.item.activeMode : "off"
  readonly property bool engineRunning: panelLoader.item ? panelLoader.item.engineRunning === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool callUnmirrored: panelLoader.item ? panelLoader.item.callUnmirrored === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍹"
    dimmed: !root.prompterConnected
    tooltipText: {
      if (!root.prompterConnected) return "Prompter · not connected"
      switch (root.activeMode) {
      case "mirror": return "Prompter · mirroring display"
      case "window": return "Prompter · mirroring window"
      case "region": return "Prompter · mirroring region"
      case "teleprompter": return "Prompter · teleprompter"
      default: return root.callUnmirrored
        ? "Prompter · call in progress, not mirrored"
        : "Prompter · monitor mode"
      }
    }
    iconComponent: Component {
      Item {
        OpticalGlyph {
          id: barGlyph
          anchors.fill: parent
          text: button.text
          color: button.foreground
          fontFamily: button.fontFamily
          fontSize: button.fontSize
        }

        Rectangle {
          visible: root.engineRunning || root.callUnmirrored
          width: Math.max(4, Math.round(button.fontSize * 0.28))
          height: width
          radius: width / 2
          // Accent while mirroring; urgent while a call runs unmirrored.
          color: root.engineRunning ? Color.accent : Color.urgent
          anchors.right: barGlyph.right
          anchors.bottom: barGlyph.bottom
          anchors.rightMargin: -Style.space(1)
          anchors.bottomMargin: -Style.space(1)
        }
      }
    }
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.LeftButton) root.togglePanel()
    }
  }
}
