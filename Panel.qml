import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Pure UI. The engine is the plugin's service singleton (Service.qml); this
// panel is instantiated once per monitor's bar and merely reflects it.
Panel {
  id: root
  moduleName: "io.github.dominicboettger.prompter"
  ipcTarget: "io.github.dominicboettger.prompter"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  // Proxies for the bar widget.
  readonly property bool prompterConnected: service ? service.prompterConnected : false
  readonly property string activeMode: service ? service.activeMode : "off"
  readonly property bool engineRunning: service ? service.engineRunning : false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    root.controller.show()
    if (service) {
      service.refreshMonitors()
      service.refreshClients()
      service.runDoctor()
      service.listScripts()
    }
  }

  function openFromHotkey() { root.open() }
  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: ScrollBar.AsNeeded

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ------------------------------------------------- Hero
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍹"
              color: root.prompterConnected ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "Prompter"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: {
                  if (!root.service) return "SERVICE NOT RUNNING"
                  return root.prompterConnected
                    ? "ELGATO PROMPTER · " + root.service.prompterName
                    : "NOT CONNECTED"
                }
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }
          }

          Text {
            visible: root.service !== null && root.service.lastError !== ""
            width: parent.width
            text: root.service ? root.service.lastError : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.service === null
            width: parent.width
            text: "The prompter service is not loaded. Try: omarchy restart shell"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------- Doctor
          Column {
            visible: root.service !== null && root.service.doctorRan && root.service.doctorFailures.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "Setup"; width: parent.width }

            Repeater {
              model: root.service ? root.service.doctorFailures : []
              delegate: Item {
                width: contentColumn.width
                implicitHeight: fixColumn.implicitHeight + Style.space(8)

                Column {
                  id: fixColumn
                  anchors.left: parent.left
                  anchors.right: fixButton.visible ? fixButton.left : parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: modelData.title
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: modelData.failure
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                Button {
                  id: fixButton
                  visible: modelData.fix !== "" && root.service && root.service.pendingFix === ""
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Fix"
                  bordered: true
                  hasCursor: true
                  onClicked: root.service.runFix(modelData.fix)
                }
              }
            }

            Text {
              visible: root.service !== null && root.service.pendingFix !== ""
              width: parent.width
              text: "Running the fix in a terminal window…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ------------------------------------------------- Mode
          Column {
            visible: root.prompterConnected
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "Mode"; width: parent.width }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Off"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "off"
                onClicked: root.service.stopEngine()
              }
              Button {
                text: "Mirror display"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "mirror"
                onClicked: root.service.startDisplayMirror("")
              }
              Button {
                text: "Mirror window"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "window"
                onClicked: { root.service.refreshClients(); windowPicker.visible = !windowPicker.visible }
              }
              Button {
                text: "Mirror region"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "region"
                onClicked: root.service.startRegionMirror()
              }
              Button {
                text: "Teleprompter"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "teleprompter"
                onClicked: root.service.startTeleprompter()
              }
            }

            Text {
              visible: root.activeMode === "mirror"
              width: parent.width
              text: root.service
                ? "Mirroring " + root.service.mirrorSource
                  + (root.service.profile.sourceStrategy === "auto" ? " · follows your focus" : " · pinned")
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.activeMode === "window"
              width: parent.width
              text: root.service ? "Following window: " + root.service.targetWindowLabel : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            // Window picker
            Column {
              id: windowPicker
              visible: false
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.service ? root.service.clients.filter(function (c) {
                  return c && c.mapped !== false && String(c.title || "") !== ""
                    && !root.service.isMirrorClient(c)
                }) : []
                delegate: Toggle {
                  width: windowPicker.width
                  label: String(modelData["class"] || "?")
                  description: String(modelData.title || "")
                  checked: root.service && root.service.targetWindowAddress === String(modelData.address)
                  onClicked: {
                    windowPicker.visible = false
                    root.service.startWindowMirror(String(modelData.address),
                      String(modelData["class"] || modelData.title || ""))
                  }
                }
              }
            }
          }

          // ------------------------------------------------- Mirror options
          Column {
            visible: root.prompterConnected
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "Mirror options"; width: parent.width }

            Dropdown {
              width: parent.width
              label: "Source"
              value: root.service && root.service.profile.sourceStrategy === "pinned"
                ? root.service.profile.pinnedSource : "auto"
              options: {
                var opts = [{ value: "auto", label: "Auto · focused display" }]
                if (!root.service) return opts
                for (var i = 0; i < root.service.sources.length; i++) {
                  var m = root.service.sources[i]
                  opts.push({
                    value: Model.monitorKey(m),
                    label: (m.model || m.name) + " (" + m.name + ")"
                  })
                }
                return opts
              }
              onChanged: function (value) {
                if (value === "auto")
                  root.service.persistProfile({ sourceStrategy: "auto", pinnedSource: "" })
                else
                  root.service.persistProfile({ sourceStrategy: "pinned", pinnedSource: value })
                if (root.activeMode === "mirror") root.service.startDisplayMirror("")
              }
            }

            Toggle {
              width: parent.width
              label: "Flip horizontally"
              description: "For reading through the beam-splitter glass"
              checked: root.service ? root.service.profile.flip : false
              onClicked: {
                root.service.persistProfile({ flip: !root.service.profile.flip })
                root.service.applyMirrorOptions()
              }
            }

            Toggle {
              width: parent.width
              label: "Fill the prompter screen"
              description: "Crop instead of letterboxing (cover vs. fit)"
              checked: root.service ? root.service.profile.scaling === "cover" : false
              onClicked: {
                root.service.persistProfile({
                  scaling: root.service.profile.scaling === "cover" ? "fit" : "cover"
                })
                root.service.applyMirrorOptions()
              }
            }

            Toggle {
              width: parent.width
              label: "Show cursor"
              checked: root.service ? root.service.profile.showCursor : false
              onClicked: {
                root.service.persistProfile({ showCursor: !root.service.profile.showCursor })
                root.service.applyMirrorOptions()
              }
            }
          }

          // ------------------------------------------------- Autopilot
          Column {
            visible: root.prompterConnected
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "Meeting autopilot"; width: parent.width }

            Toggle {
              width: parent.width
              label: "Detect meeting windows"
              description: "Teams, Zoom and Meet windows are offered on the prompter"
              checked: root.service ? root.service.profile.autopilot : false
              onClicked: root.service.persistProfile({ autopilot: !root.service.profile.autopilot })
            }

            Toggle {
              visible: root.service ? root.service.profile.autopilot : false
              width: parent.width
              label: "Ask before mirroring"
              description: "Notify instead of switching the prompter automatically"
              checked: root.service ? root.service.profile.autopilotConfirm : true
              onClicked: root.service.persistProfile({
                autopilotConfirm: !root.service.profile.autopilotConfirm
              })
            }
          }

          // ------------------------------------------------- Teleprompter
          Column {
            visible: root.prompterConnected
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "Teleprompter"; width: parent.width }

            Dropdown {
              width: parent.width
              label: "Script"
              value: root.service ? root.service.currentScriptPath : ""
              options: root.service ? root.service.scriptFiles.map(function (name) {
                return { value: root.service.scriptsDir + "/" + name, label: name }
              }) : []
              onChanged: function (value) { root.service.selectScript(value) }
            }

            Text {
              width: parent.width
              text: root.service
                ? "Scripts live in " + root.service.scriptsDir.replace(String(Quickshell.env("HOME")), "~")
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: "Speed"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                anchors.verticalCenter: parent.verticalCenter
              }
              PanelSlider {
                width: parent.width - Style.space(120)
                anchors.verticalCenter: parent.verticalCenter
                bar: root.bar
                minimum: 5
                maximum: 300
                step: 5
                value: root.service ? root.service.scrollSpeed : 40
                onMoved: function (v) { if (root.service) root.service.scrollSpeed = v }
                onReleased: function (v) { if (root.service) root.service.persistGlobal({ scrollSpeed: v }) }
              }
              Text {
                text: root.service ? Math.round(root.service.scrollSpeed) + " px/s" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: "Text size"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                anchors.verticalCenter: parent.verticalCenter
              }
              PanelSlider {
                width: parent.width - Style.space(120)
                anchors.verticalCenter: parent.verticalCenter
                bar: root.bar
                minimum: 0.6
                maximum: 2.5
                step: 0.1
                value: root.service ? root.service.fontScale : 1.0
                onMoved: function (v) { if (root.service) root.service.fontScale = v }
                onReleased: function (v) { if (root.service) root.service.persistGlobal({ fontScale: v }) }
              }
              Text {
                text: root.service ? Math.round(root.service.fontScale * 100) + "%" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Toggle {
              width: parent.width
              label: "Flip for glass"
              description: "Mirror the text for the beam-splitter"
              checked: root.service ? root.service.teleprompterFlip : false
              onClicked: root.service.setTeleprompterFlip(!root.service.teleprompterFlip)
            }

            Flow {
              visible: root.activeMode === "teleprompter"
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: root.service && root.service.teleprompterPlaying ? "Pause" : "Play"
                bordered: true
                hasCursor: true
                onClicked: root.service.teleprompterPlaying = !root.service.teleprompterPlaying
              }
              Button {
                text: "󰒮 Chapter"
                bordered: true
                hasCursor: true
                onClicked: root.service.jumpChapter(-1)
              }
              Button {
                text: "Chapter 󰒭"
                bordered: true
                hasCursor: true
                onClicked: root.service.jumpChapter(1)
              }
            }
          }

          // ------------------------------------------------- Footer hint
          Text {
            width: parent.width
            text: "Remote control: omarchy-shell prompter play · pause · faster · flip · mirror · off"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
