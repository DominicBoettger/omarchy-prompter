import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// Fullscreen teleprompter surface on the prompter's screen. All control state
// (script, speed, playing, chapter) lives on the panel; this window renders it.
PanelWindow {
  id: overlay

  required property var panel

  readonly property var prompterScreen: {
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === panel.prompterName) return screens[i]
    }
    return null
  }

  screen: prompterScreen
  visible: prompterScreen !== null
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-prompter"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  readonly property real eyelineY: height * panel.eyelinePosition
  readonly property real baseFontSize: Math.round(30 * panel.fontScale)
  property int countdown: 0

  function chapterY(index) {
    var item = chapterRepeater.itemAt(index)
    return item ? item.y : 0
  }

  function jumpToChapter(index) {
    scroller.contentY = Math.max(0, Math.min(chapterY(index), scroller.contentHeight - scroller.height))
  }

  Connections {
    target: overlay.panel
    function onTeleprompterChapterChanged() { overlay.jumpToChapter(overlay.panel.teleprompterChapter) }
    function onTeleprompterPlayingChanged() {
      if (overlay.panel.teleprompterPlaying && scroller.contentY <= 1)
        overlay.countdown = 3
    }
    function onCurrentScriptTextChanged() {
      scroller.contentY = 0
      overlay.panel.teleprompterChapter = 0
    }
  }

  Timer {
    interval: 1000
    running: overlay.countdown > 0
    repeat: true
    onTriggered: overlay.countdown -= 1
  }

  // Scroll driver: fixed cadence, speed in logical pixels per second.
  Timer {
    interval: 16
    running: overlay.panel.teleprompterPlaying && overlay.countdown === 0
    repeat: true
    onTriggered: {
      var max = Math.max(0, scroller.contentHeight - scroller.height)
      var next = scroller.contentY + overlay.panel.scrollSpeed * (interval / 1000)
      if (next >= max) {
        scroller.contentY = max
        overlay.panel.teleprompterPlaying = false
      } else {
        scroller.contentY = next
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    // The beam-splitter shows a mirrored image; flip the whole content so the
    // text reads correctly through the glass.
    transform: Scale {
      xScale: overlay.panel.teleprompterFlip ? -1 : 1
      origin.x: overlay.width / 2
    }

    Flickable {
      id: scroller
      anchors.fill: parent
      contentWidth: width
      contentHeight: scriptColumn.implicitHeight
      interactive: false
      clip: true

      Column {
        id: scriptColumn
        width: scroller.width
        // Text enters at the eyeline and the last line can scroll up to it.
        topPadding: overlay.eyelineY
        bottomPadding: overlay.height - overlay.eyelineY
        spacing: Math.round(overlay.baseFontSize * 0.8)

        Repeater {
          id: chapterRepeater
          model: overlay.panel.scriptModel.chapters
          delegate: Column {
            width: scriptColumn.width
            spacing: Math.round(overlay.baseFontSize * 0.3)

            Text {
              visible: String(modelData.title || "") !== ""
              width: parent.width
              leftPadding: Math.round(overlay.width * 0.06)
              rightPadding: leftPadding
              text: String(modelData.title || "")
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Math.round(overlay.baseFontSize * 0.7)
              font.bold: true
              font.letterSpacing: 1.5
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              leftPadding: Math.round(overlay.width * 0.06)
              rightPadding: leftPadding
              text: String(modelData.text || "")
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: overlay.baseFontSize
              font.bold: true
              lineHeight: 1.25
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }

    // Fade everything but the reading zone so the eye stays anchored.
    Rectangle {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Math.max(0, overlay.eyelineY - overlay.baseFontSize)
      gradient: Gradient {
        GradientStop { position: 0.0; color: Color.background }
        GradientStop { position: 1.0; color: Qt.alpha(Color.background, 0) }
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: overlay.height * 0.35
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.alpha(Color.background, 0) }
        GradientStop { position: 1.0; color: Color.background }
      }
    }

    // Eyeline marker
    Text {
      x: Math.round(overlay.width * 0.012)
      y: overlay.eyelineY - height / 2
      text: "󰍟"
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Math.round(overlay.baseFontSize * 0.8)
    }

    // Progress and remaining time
    Text {
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Math.round(overlay.height * 0.02)
      text: {
        var max = Math.max(1, scroller.contentHeight - scroller.height)
        var pct = Math.round(Math.min(1, scroller.contentY / max) * 100)
        var remaining = Model.remainingSeconds(max - scroller.contentY, overlay.panel.scrollSpeed)
        return pct + "% · " + (remaining < 0 ? "–" : Model.formatDuration(remaining))
      }
      color: Qt.darker(Color.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Math.round(overlay.baseFontSize * 0.45)
    }

    // Countdown before the scroll starts
    Rectangle {
      visible: overlay.countdown > 0
      anchors.fill: parent
      color: Qt.alpha(Color.background, 0.85)

      Text {
        anchors.centerIn: parent
        text: String(overlay.countdown)
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Math.round(overlay.height * 0.5)
        font.bold: true
      }
    }

    // Idle hint when stopped at the top
    Text {
      visible: !overlay.panel.teleprompterPlaying && scroller.contentY <= 1 && overlay.countdown === 0
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.round(overlay.height * 0.04)
      text: "omarchy-shell prompter play"
      color: Qt.darker(Color.foreground, 1.8)
      font.family: Style.font.family
      font.pixelSize: Math.round(overlay.baseFontSize * 0.4)
    }
  }
}
