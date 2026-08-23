import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.dominicboettger.prompter"
  ipcTarget: "io.github.dominicboettger.prompter"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---------------------------------------------------------------------
  // Runtime state

  property var monitors: []
  property var clients: []
  property bool monitorsKnown: false

  // Engine
  property string activeMode: "off"       // off | mirror | window | region | teleprompter
  property string mirrorSource: ""        // connector currently mirrored (mirror mode)
  property string targetWindowAddress: ""
  property string targetWindowLabel: ""
  property string fixedRegion: ""          // slurp region (global coordinates)
  property bool stopRequested: false
  property string lastError: ""

  // Autopilot bookkeeping
  property string autopilotAddress: ""     // window the autopilot chose

  // Per-setup profile (Model.defaultProfile shape)
  property var profiles: ({})
  property var globalState: ({})
  property bool stateLoaded: false

  // Doctor
  property var doctorResults: []           // [{id,title,ok,failure,fix}]
  property bool doctorRan: false
  property int doctorIndex: -1
  property string pendingFix: ""

  // Teleprompter
  property var scriptFiles: []
  property string currentScriptPath: ""
  property string currentScriptText: ""
  property real scrollSpeed: 40            // px/s
  property real fontScale: 1.0
  property real eyelinePosition: 0.33      // fraction of screen height
  property bool teleprompterFlip: false
  property bool teleprompterOpen: false
  property bool teleprompterPlaying: false
  property int teleprompterChapter: 0

  // ---------------------------------------------------------------------
  // Computed

  readonly property var prompter: Model.findPrompter(monitors)
  readonly property bool prompterConnected: prompter !== null
  readonly property string prompterName: prompter ? String(prompter.name) : ""
  readonly property var sources: Model.sourceCandidates(monitors)
  readonly property string fingerprint: Model.setupFingerprint(monitors)
  readonly property var profile: {
    var p = profiles && fingerprint ? profiles[fingerprint] : null
    var d = Model.defaultProfile()
    if (!p) return d
    for (var k in p) d[k] = p[k]
    return d
  }
  readonly property bool engineRunning: mirrorProcess.running || teleprompterOpen
  readonly property bool doctorHealthy: doctorRan && doctorResults.every(function (r) { return r.ok })
  readonly property var doctorFailures: doctorResults.filter(function (r) { return !r.ok })
  readonly property var scriptModel: Model.parseScript(currentScriptText)

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string statePath:
    String(Quickshell.env("HOME") || "") + "/.local/state/omarchy-prompter/state.json"
  readonly property string scriptsDir:
    String(Quickshell.env("HOME") || "") + "/.local/share/omarchy-prompter/scripts"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------------
  // Lifecycle

  Component.onCompleted: {
    refreshMonitors()
    runDoctor()
    listScripts()
  }

  function open() {
    root.controller.show()
    refreshMonitors()
    refreshClients()
    runDoctor()
    listScripts()
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

  // ---------------------------------------------------------------------
  // Monitor / client discovery

  function refreshMonitors() {
    if (monitorsProcess.running) return
    monitorsProcess.running = true
  }

  function refreshClients() {
    if (clientsProcess.running) return
    clientsProcess.running = true
  }

  onMonitorsChanged: {
    if (!monitorsKnown) return
    // Hotplug: prompter vanished -> stop everything quietly. Prompter
    // appeared -> restore the profile's last mode.
    if (!prompterConnected && engineRunning) {
      stopEngine()
      return
    }
    if (prompterConnected && activeMode === "off" && stateLoaded) {
      var last = profile.mode
      if (last === "mirror") startDisplayMirror("")
    }
    // Pinned source unplugged mid-session -> fall back to auto.
    if (activeMode === "mirror" && mirrorSource !== ""
        && !Model.monitorByName(monitors, mirrorSource)) {
      startDisplayMirror("")
    }
  }

  // ---------------------------------------------------------------------
  // Engine: mirroring

  function resolveAutoSource() {
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
    if (focused !== "" && focused !== prompterName
        && Model.monitorByName(monitors, focused)) return focused
    if (mirrorSource !== "" && mirrorSource !== prompterName) return mirrorSource
    var candidates = sources
    return candidates.length ? String(candidates[0].name) : ""
  }

  function fullOutputRegion(name) {
    var m = Model.monitorByName(monitors, name)
    if (!m) return ""
    var scale = Number(m.scale || 1) || 1
    var w = Math.round(Number(m.width || 0) / scale)
    var h = Math.round(Number(m.height || 0) / scale)
    if (w <= 0 || h <= 0) return ""
    return "0,0 " + w + "x" + h + " " + name
  }

  // source "" means: follow the source strategy (pinned or auto).
  function startDisplayMirror(source) {
    if (!prompterConnected) return
    stopTeleprompter()
    var name = source
    if (name === "") {
      if (profile.sourceStrategy === "pinned" && profile.pinnedSource !== "") {
        var pinned = monitors.filter(function (m) {
          return Model.monitorKey(m) === profile.pinnedSource
        })
        if (pinned.length) name = String(pinned[0].name)
      }
      if (name === "") name = resolveAutoSource()
    }
    if (name === "" || name === prompterName) {
      lastError = "No source display available to mirror."
      return
    }
    var region = fullOutputRegion(name)
    if (region === "") return
    mirrorSource = name
    targetWindowAddress = ""
    activeMode = "mirror"
    launchMirror(region)
    persistProfile({ mode: "mirror" })
  }

  function startWindowMirror(address, label) {
    if (!prompterConnected) return
    stopTeleprompter()
    targetWindowAddress = String(address)
    targetWindowLabel = String(label || "")
    activeMode = "window"
    lastError = ""
    refreshClients()   // region follows once the client list arrives
    followPoll.restart()
    persistProfile({ mode: "window" })
  }

  function startRegionMirror() {
    if (!prompterConnected || slurpProcess.running) return
    stopTeleprompter()
    slurpProcess.running = true
  }

  function mirrorActiveWindow() {
    if (activeWindowProcess.running) return
    activeWindowProcess.running = true
  }

  function launchMirror(region) {
    var argv = Model.wlMirrorCommand({
      prompterName: prompterName,
      source: "",
      region: region,
      flip: profile.flip,
      scaling: profile.scaling,
      showCursor: profile.showCursor
    })
    if (mirrorProcess.running) {
      mirrorProcess.write(Model.streamRegionLine(region) + "\n")
      return
    }
    stopRequested = false
    mirrorProcess.command = argv
    mirrorProcess.running = true
  }

  function updateWindowRegion() {
    if (activeMode !== "window" || targetWindowAddress === "") return
    var client = null
    for (var i = 0; i < clients.length; i++) {
      if (String(clients[i].address) === targetWindowAddress) { client = clients[i]; break }
    }
    if (!client) {
      // Window is gone; stop rather than mirror whatever sits underneath.
      stopEngine()
      lastError = "The mirrored window was closed."
      return
    }
    var monitor = Model.monitorForClient(client, monitors)
    if (!monitor || Model.isPrompterMonitor(monitor)) return
    var region = Model.regionForClient(client, monitor)
    if (region !== "") launchMirror(region)
  }

  function applyMirrorOptions() {
    if (!mirrorProcess.running) return
    mirrorProcess.write(Model.streamTransformLine(profile.flip) + "\n")
    mirrorProcess.write("-s " + (profile.scaling === "cover" ? "cover" : "fit") + "\n")
    mirrorProcess.write((profile.showCursor ? "--show-cursor" : "--no-cursor") + "\n")
  }

  function stopEngine() {
    stopRequested = true
    activeMode = "off"
    mirrorSource = ""
    targetWindowAddress = ""
    autopilotAddress = ""
    followPoll.stop()
    if (mirrorProcess.running) mirrorProcess.signal(15)
    stopTeleprompter()
    persistProfile({ mode: "off" })
  }

  // ---------------------------------------------------------------------
  // Engine: teleprompter

  function startTeleprompter() {
    if (!prompterConnected) return
    if (mirrorProcess.running) {
      stopRequested = true
      mirrorProcess.signal(15)
    }
    mirrorSource = ""
    targetWindowAddress = ""
    activeMode = "teleprompter"
    teleprompterChapter = 0
    teleprompterPlaying = false
    teleprompterOpen = true
    persistProfile({ mode: "teleprompter" })
  }

  function stopTeleprompter() {
    teleprompterOpen = false
    teleprompterPlaying = false
    if (activeMode === "teleprompter") activeMode = "off"
  }

  function adjustSpeed(delta) {
    scrollSpeed = Math.max(5, Math.min(300, scrollSpeed + delta))
    persistGlobal({ scrollSpeed: scrollSpeed })
  }

  function jumpChapter(delta) {
    var count = scriptModel.chapters.length
    if (count === 0) return
    teleprompterChapter = Math.max(0, Math.min(count - 1, teleprompterChapter + delta))
  }

  // ---------------------------------------------------------------------
  // State persistence

  function persistProfile(patch) {
    if (fingerprint === "") return
    var all = profiles || {}
    var current = all[fingerprint] || Model.defaultProfile()
    for (var k in patch) current[k] = patch[k]
    all[fingerprint] = current
    profiles = all
    saveState()
  }

  function persistGlobal(patch) {
    var g = globalState || {}
    for (var k in patch) g[k] = patch[k]
    globalState = g
    saveState()
  }

  function saveState() {
    if (!stateLoaded) return
    saveDebounce.restart()
  }

  function writeStateNow() {
    var payload = JSON.stringify({ profiles: profiles, global: globalState }, null, 2)
    if (saveProcess.running) { saveDebounce.restart(); return }
    saveProcess.command = ["sh", "-c",
      'mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1".tmp && mv "$1".tmp "$1"',
      "write-state", statePath, payload]
    saveProcess.running = true
  }

  function applyLoadedState(text) {
    try {
      var data = JSON.parse(text)
      if (data && typeof data === "object") {
        profiles = data.profiles || {}
        globalState = data.global || {}
        if (globalState.scrollSpeed) scrollSpeed = Number(globalState.scrollSpeed)
        if (globalState.fontScale) fontScale = Number(globalState.fontScale)
        if (globalState.eyelinePosition) eyelinePosition = Number(globalState.eyelinePosition)
        if (globalState.teleprompterFlip !== undefined) teleprompterFlip = !!globalState.teleprompterFlip
        if (globalState.lastScript) currentScriptPath = String(globalState.lastScript)
      }
    } catch (e) { /* corrupt state falls back to defaults */ }
    stateLoaded = true
  }

  // ---------------------------------------------------------------------
  // Doctor

  function runDoctor() {
    if (doctorIndex >= 0) return
    doctorResults = []
    doctorIndex = 0
    runNextCheck()
  }

  function runNextCheck() {
    var checks = Model.doctorChecks()
    if (doctorIndex >= checks.length) {
      doctorIndex = -1
      doctorRan = true
      return
    }
    doctorProcess.command = checks[doctorIndex].command
    doctorProcess.running = true
  }

  function runFix(fixId) {
    var argv = Model.fixCommand(fixId, pluginDir)
    if (!argv) return
    pendingFix = fixId
    fixLaunchProcess.command = argv
    fixLaunchProcess.startDetached()
    fixPoll.restart()
  }

  // ---------------------------------------------------------------------
  // Scripts

  function listScripts() {
    if (scriptsProcess.running) return
    scriptsProcess.running = true
  }

  function selectScript(path) {
    currentScriptPath = path
    persistGlobal({ lastScript: path })
  }

  // ---------------------------------------------------------------------
  // Hyprland events

  function handleRawEvent(event) {
    var name = String(event && event.name ? event.name : "")
    var data = String(event && event.data !== undefined ? event.data : "")
    switch (name) {
    case "monitoraddedv2":
    case "monitoradded":
    case "monitorremoved":
    case "monitorremovedv2":
      refreshMonitors()
      break
    case "openwindow": {
      if (!profile.autopilot || !prompterConnected || activeMode === "teleprompter") break
      var parts = data.split(",")
      var address = "0x" + parts[0]
      var cls = String(parts[2] || "")
      var title = parts.slice(3).join(",")
      if (Model.matchMeetingWindow({ "class": cls, title: title }, null, Model.DEFAULT_MEETING_TITLE_PATTERNS)) {
        autopilotAddress = address
        if (profile.autopilotConfirm) {
          notifyProcess.command = ["notify-send", "-a", "Prompter", "Meeting window detected",
            "Open the Prompter panel or run: omarchy-shell prompter mirrorMeeting"]
          notifyProcess.startDetached()
        } else {
          startWindowMirror(address, cls)
        }
      }
      break
    }
    case "closewindow": {
      var addr = "0x" + data
      if (activeMode === "window" && addr === targetWindowAddress) {
        stopEngine()
        lastError = "The mirrored window was closed."
      }
      break
    }
    case "movewindowv2":
    case "movewindow":
    case "changefloatingmode":
    case "fullscreen":
    case "workspacev2":
    case "workspace":
      if (activeMode === "window") followDebounce.restart()
      break
    case "focusedmonv2":
    case "focusedmon":
      if (activeMode === "mirror" && profile.sourceStrategy === "auto") {
        var mon = data.split(",")[0]
        if (mon !== "" && mon !== prompterName && mon !== mirrorSource
            && Model.monitorByName(monitors, mon)) {
          mirrorSource = mon
          var region = fullOutputRegion(mon)
          if (region !== "" && mirrorProcess.running)
            mirrorProcess.write(Model.streamRegionLine(region) + "\n")
        }
      }
      break
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleRawEvent(event) }
  }

  // ---------------------------------------------------------------------
  // Processes

  Process {
    id: monitorsProcess
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector { id: monitorsOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      try {
        var parsed = JSON.parse(monitorsOutput.text)
        root.monitorsKnown = true
        root.monitors = parsed instanceof Array ? parsed : []
      } catch (e) { /* keep previous list */ }
    }
  }

  Process {
    id: clientsProcess
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector { id: clientsOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      try {
        var parsed = JSON.parse(clientsOutput.text)
        root.clients = parsed instanceof Array ? parsed : []
        root.updateWindowRegion()
      } catch (e) {}
    }
  }

  Process {
    id: activeWindowProcess
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector { id: activeWindowOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      try {
        var client = JSON.parse(activeWindowOutput.text)
        if (client && client.address)
          root.startWindowMirror(String(client.address), String(client["class"] || client.title || ""))
      } catch (e) {}
    }
  }

  Process {
    id: mirrorProcess
    stdinEnabled: true
    onExited: function (exitCode) {
      if (root.stopRequested) { root.stopRequested = false; return }
      if (root.activeMode === "mirror" || root.activeMode === "window" || root.activeMode === "region") {
        root.lastError = "wl-mirror exited unexpectedly (code " + exitCode + ")."
        root.activeMode = "off"
        followPoll.stop()
      }
    }
  }

  Process {
    id: slurpProcess
    command: ["slurp", "-f", "%x,%y %wx%h"]
    stdout: StdioCollector { id: slurpOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      var region = String(slurpOutput.text || "").trim()
      if (region === "") return
      root.fixedRegion = region
      root.targetWindowAddress = ""
      root.activeMode = "region"
      root.launchMirror(region)
      root.persistProfile({ mode: "region" })
    }
  }

  Process {
    id: saveProcess
  }

  Process {
    id: doctorProcess
    onExited: function (exitCode) {
      var checks = Model.doctorChecks()
      var check = checks[root.doctorIndex]
      if (check) {
        var results = root.doctorResults.slice()
        results.push({
          id: check.id, title: check.title, ok: exitCode === 0,
          failure: check.failure, fix: check.fix || ""
        })
        root.doctorResults = results
      }
      root.doctorIndex += 1
      root.runNextCheck()
    }
  }

  Process { id: fixLaunchProcess }
  Process { id: notifyProcess }

  Process {
    id: fixCheckProcess
    command: ["sh", "-c",
      'if [ -f "$XDG_RUNTIME_DIR/omarchy-prompter-fix.complete" ]; then exit 0; ' +
      'elif [ -f "$XDG_RUNTIME_DIR/omarchy-prompter-fix.failed" ]; then exit 2; else exit 1; fi']
    onExited: function (exitCode) {
      if (exitCode === 1) return   // still running
      root.fixPoll.stop()
      root.pendingFix = ""
      if (exitCode === 2) root.lastError = "The fix did not finish. Check the terminal output."
      root.runDoctor()
    }
  }

  Process {
    id: scriptsProcess
    command: ["sh", "-c",
      'dir="$HOME/.local/share/omarchy-prompter/scripts"; mkdir -p "$dir"; ' +
      'if [ -z "$(ls -A "$dir" 2>/dev/null)" ] && [ -f "$1" ]; then cp "$1" "$dir/welcome.md"; fi; ' +
      'ls -1 "$dir"', "list-scripts", pluginDir + "/resources/example-script.md"]
    stdout: StdioCollector { id: scriptsOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      var names = String(scriptsOutput.text || "").split("\n").filter(function (n) {
        return n.trim() !== "" && /\.(md|txt)$/i.test(n)
      })
      root.scriptFiles = names
      if (root.currentScriptPath === "" && names.length)
        root.currentScriptPath = root.scriptsDir + "/" + names[0]
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    printErrors: false
    onLoaded: root.applyLoadedState(text())
    onLoadFailed: root.applyLoadedState("")
  }

  FileView {
    id: scriptFile
    path: root.currentScriptPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.currentScriptText = text()
    onLoadFailed: root.currentScriptText = ""
  }

  // ---------------------------------------------------------------------
  // Timers

  Timer { id: saveDebounce; interval: 400; onTriggered: root.writeStateNow() }
  Timer { id: followDebounce; interval: 120; onTriggered: root.refreshClients() }
  Timer {
    id: followPoll
    interval: 1000
    repeat: true
    running: false
    onTriggered: root.refreshClients()
  }
  Timer {
    id: fixPoll
    interval: 2000
    repeat: true
    running: false
    onTriggered: { if (!fixCheckProcess.running) fixCheckProcess.running = true }
  }

  // ---------------------------------------------------------------------
  // IPC: full remote control for keybindings, Stream Deck, clickers.

  IpcHandler {
    target: "prompter"

    function off(): void { root.stopEngine() }
    function mirror(): void { root.startDisplayMirror("") }
    function mirrorActive(): void { root.mirrorActiveWindow() }
    function mirrorMeeting(): void {
      if (root.autopilotAddress !== "") root.startWindowMirror(root.autopilotAddress, "meeting")
      else root.mirrorActiveWindow()
    }
    function region(): void { root.startRegionMirror() }
    function teleprompter(): void { root.startTeleprompter() }
    function play(): void { root.teleprompterPlaying = true }
    function pause(): void { root.teleprompterPlaying = false }
    function playPause(): void { root.teleprompterPlaying = !root.teleprompterPlaying }
    function faster(): void { root.adjustSpeed(10) }
    function slower(): void { root.adjustSpeed(-10) }
    function nextChapter(): void { root.jumpChapter(1) }
    function prevChapter(): void { root.jumpChapter(-1) }
    function flip(): void {
      if (root.activeMode === "teleprompter") {
        root.teleprompterFlip = !root.teleprompterFlip
        root.persistGlobal({ teleprompterFlip: root.teleprompterFlip })
      } else {
        root.persistProfile({ flip: !root.profile.flip })
        root.applyMirrorOptions()
      }
    }
    function openPanel(): void { root.open() }
    function toggle(): void { root.toggle() }
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // ---------------------------------------------------------------------
  // Teleprompter overlay window

  Loader {
    id: teleprompterLoader
    active: root.teleprompterOpen && root.prompterConnected
    sourceComponent: TeleprompterOverlay {
      panel: root
    }
  }

  // ---------------------------------------------------------------------
  // Panel UI

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
                text: root.prompterConnected
                  ? "ELGATO PROMPTER · " + root.prompterName
                  : "NOT CONNECTED"
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
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------- Doctor
          Column {
            visible: root.doctorRan && root.doctorFailures.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "Setup" ; width: parent.width }

            Repeater {
              model: root.doctorFailures
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
                  visible: modelData.fix !== "" && root.pendingFix === ""
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Fix"
                  bordered: true
                  hasCursor: true
                  onClicked: root.runFix(modelData.fix)
                }
              }
            }

            Text {
              visible: root.pendingFix !== ""
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
                onClicked: root.stopEngine()
              }
              Button {
                text: "Mirror display"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "mirror"
                onClicked: root.startDisplayMirror("")
              }
              Button {
                text: "Mirror window"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "window"
                onClicked: { root.refreshClients(); windowPicker.visible = !windowPicker.visible }
              }
              Button {
                text: "Mirror region"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "region"
                onClicked: root.startRegionMirror()
              }
              Button {
                text: "Teleprompter"
                bordered: true
                hasCursor: true
                selected: root.activeMode === "teleprompter"
                onClicked: root.startTeleprompter()
              }
            }

            Text {
              visible: root.activeMode === "mirror"
              width: parent.width
              text: "Mirroring " + root.mirrorSource
                + (root.profile.sourceStrategy === "auto" ? " · follows your focus" : " · pinned")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.activeMode === "window"
              width: parent.width
              text: "Following window: " + root.targetWindowLabel
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
                model: root.clients.filter(function (c) {
                  return c && c.mapped !== false && String(c.title || "") !== ""
                })
                delegate: Toggle {
                  width: windowPicker.width
                  label: String(modelData["class"] || "?")
                  description: String(modelData.title || "")
                  checked: root.targetWindowAddress === String(modelData.address)
                  onClicked: {
                    windowPicker.visible = false
                    root.startWindowMirror(String(modelData.address),
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
              value: root.profile.sourceStrategy === "auto" ? "auto" : root.profile.pinnedSource
              options: {
                var opts = [{ value: "auto", label: "Auto · focused display" }]
                for (var i = 0; i < root.sources.length; i++) {
                  var m = root.sources[i]
                  opts.push({
                    value: Model.monitorKey(m),
                    label: (m.model || m.name) + " (" + m.name + ")"
                  })
                }
                return opts
              }
              onChanged: function (value) {
                if (value === "auto")
                  root.persistProfile({ sourceStrategy: "auto", pinnedSource: "" })
                else
                  root.persistProfile({ sourceStrategy: "pinned", pinnedSource: value })
                if (root.activeMode === "mirror") root.startDisplayMirror("")
              }
            }

            Toggle {
              width: parent.width
              label: "Flip horizontally"
              description: "For reading through the beam-splitter glass"
              checked: root.profile.flip
              onClicked: {
                root.persistProfile({ flip: !root.profile.flip })
                root.applyMirrorOptions()
              }
            }

            Toggle {
              width: parent.width
              label: "Fill the prompter screen"
              description: "Crop instead of letterboxing (cover vs. fit)"
              checked: root.profile.scaling === "cover"
              onClicked: {
                root.persistProfile({ scaling: root.profile.scaling === "cover" ? "fit" : "cover" })
                root.applyMirrorOptions()
              }
            }

            Toggle {
              width: parent.width
              label: "Show cursor"
              checked: root.profile.showCursor
              onClicked: {
                root.persistProfile({ showCursor: !root.profile.showCursor })
                root.applyMirrorOptions()
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
              checked: root.profile.autopilot
              onClicked: root.persistProfile({ autopilot: !root.profile.autopilot })
            }

            Toggle {
              visible: root.profile.autopilot
              width: parent.width
              label: "Ask before mirroring"
              description: "Notify instead of switching the prompter automatically"
              checked: root.profile.autopilotConfirm
              onClicked: root.persistProfile({ autopilotConfirm: !root.profile.autopilotConfirm })
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
              value: root.currentScriptPath
              options: root.scriptFiles.map(function (name) {
                return { value: root.scriptsDir + "/" + name, label: name }
              })
              onChanged: function (value) { root.selectScript(value) }
            }

            Text {
              width: parent.width
              text: "Scripts live in " + root.scriptsDir.replace(String(Quickshell.env("HOME")), "~")
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
                value: root.scrollSpeed
                onMoved: function (v) { root.scrollSpeed = v }
                onReleased: function (v) { root.persistGlobal({ scrollSpeed: v }) }
              }
              Text {
                text: Math.round(root.scrollSpeed) + " px/s"
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
                value: root.fontScale
                onMoved: function (v) { root.fontScale = v }
                onReleased: function (v) { root.persistGlobal({ fontScale: v }) }
              }
              Text {
                text: Math.round(root.fontScale * 100) + "%"
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
              checked: root.teleprompterFlip
              onClicked: {
                root.teleprompterFlip = !root.teleprompterFlip
                root.persistGlobal({ teleprompterFlip: root.teleprompterFlip })
              }
            }

            Flow {
              visible: root.activeMode === "teleprompter"
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: root.teleprompterPlaying ? "Pause" : "Play"
                bordered: true
                hasCursor: true
                onClicked: root.teleprompterPlaying = !root.teleprompterPlaying
              }
              Button {
                text: "󰒮 Chapter"
                bordered: true
                hasCursor: true
                onClicked: root.jumpChapter(-1)
              }
              Button {
                text: "Chapter 󰒭"
                bordered: true
                hasCursor: true
                onClicked: root.jumpChapter(1)
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
