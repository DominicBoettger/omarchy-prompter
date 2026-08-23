import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import "Model.js" as Model

// Engine singleton. The bar renders one widget per monitor, so anything that
// owns processes or reacts to compositor events must live here, exactly once.
// Panels find this via bar.shell.serviceFor(<plugin id>).
Item {
  id: root

  property var shell: null

  // ---------------------------------------------------------------------
  // Runtime state

  property var monitors: []
  property var clients: []
  property bool monitorsKnown: false

  property string activeMode: "off"       // off | mirror | window | region | teleprompter
  property string mirrorSource: ""        // connector currently mirrored (mirror mode)
  property string targetWindowAddress: ""
  property string targetWindowLabel: ""
  property string fixedRegion: ""          // slurp region (global coordinates)
  property bool stopRequested: false
  property string lastError: ""
  property string autopilotAddress: ""     // window the autopilot chose
  property bool pendingMeetingScan: false

  // Meeting-end detection. PWA windows never close and their titles keep
  // matching, but a call always holds a microphone capture stream — when it
  // disappears for a while, the meeting is over.
  property bool meetingFollow: false       // window mode came from meeting detection
  property bool callWasActive: false
  // A capture stream is isStream && audio && !isSink (playback streams
  // report isSink, cf. omarchy.media). Audio-filter infrastructure like
  // noise suppressors (capture.ns_source) holds a capture stream around the
  // clock and must not count as a call.
  readonly property bool callActive: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    var infra = /^capture\.|noise|rnnoise|echo[-_ ]?cancel|filter[-_ ]?chain|^ns[-_ ]|_ns_/i
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !n.audio || n.isSink === true) continue
      if (infra.test(String(n.name || ""))) continue
      return true
    }
    return false
  }

  onCallActiveChanged: {
    if (!meetingFollow || activeMode !== "window") return
    if (callActive) {
      callWasActive = true
      meetingEndTimer.stop()
    } else if (callWasActive) {
      meetingEndTimer.restart()
    }
  }

  // The fullscreen mirror window grabs focus when it spawns (dynamic
  // windowrules are unavailable under the non-legacy config parser), so the
  // engine hands focus straight back to the display the user was on.
  property string pendingRefocus: ""

  property var profiles: ({})
  property var globalState: ({})
  property bool stateLoaded: false

  property var doctorResults: []           // [{id,title,ok,failure,fix}]
  property bool doctorRan: false
  property int doctorIndex: -1
  property string pendingFix: ""

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

  Component.onCompleted: {
    refreshMonitors()
    runDoctor()
    listScripts()
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
    return Model.regionForOutput(Model.monitorByName(monitors, name))
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
    lastError = ""
    launchMirror(region)
    persistProfile({ mode: "mirror" })
  }

  function startWindowMirror(address, label, isMeeting) {
    if (!prompterConnected) return
    stopTeleprompter()
    targetWindowAddress = String(address)
    targetWindowLabel = String(label || "")
    activeMode = "window"
    lastError = ""
    meetingFollow = isMeeting === true
    callWasActive = meetingFollow && callActive
    meetingEndTimer.stop()
    refreshClients()   // region follows once the client list arrives
    followPoll.running = true
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

  // A meeting window usually exists long before the meeting starts (PWAs
  // live all day), so look through the open clients instead of waiting for
  // a new window.
  function scanForMeeting() {
    pendingMeetingScan = true
    refreshClients()
  }

  function isMirrorClient(client) {
    return String(client && client["class"] || "") === "at.yrlf.wl_mirror"
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
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
    pendingRefocus = focused !== "" && focused !== prompterName ? focused : ""
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
    if (!monitor) return
    if (Model.isPrompterMonitor(monitor)) {
      // The followed window moved onto the prompter itself; freeze rather
      // than mirror the mirror.
      return
    }
    var region = Model.regionForClient(client, monitor)
    if (region !== "") launchMirror(region)
  }

  function applyMirrorOptions() {
    if (!mirrorProcess.running) return
    mirrorProcess.write(Model.streamTransformLine(profile.flip) + "\n")
    mirrorProcess.write("-s " + (profile.scaling === "cover" ? "cover" : "fit") + "\n")
    mirrorProcess.write((profile.showCursor ? "--show-cursor" : "--no-show-cursor") + "\n")
  }

  function stopEngine() {
    stopRequested = true
    activeMode = "off"
    mirrorSource = ""
    targetWindowAddress = ""
    autopilotAddress = ""
    meetingFollow = false
    callWasActive = false
    meetingEndTimer.stop()
    followPoll.running = false
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
    lastError = ""
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

  function setTeleprompterFlip(value) {
    teleprompterFlip = !!value
    persistGlobal({ teleprompterFlip: teleprompterFlip })
  }

  function toggleFlip() {
    if (activeMode === "teleprompter" || teleprompterOpen) {
      setTeleprompterFlip(!teleprompterFlip)
    } else {
      persistProfile({ flip: !profile.flip })
      applyMirrorOptions()
    }
  }

  // ---------------------------------------------------------------------
  // State persistence

  // Assigning the same object reference back to a `var` property does not
  // emit a change signal, so bindings on `profile` would go stale — always
  // rebuild the containers.
  function persistProfile(patch) {
    if (fingerprint === "") return
    var next = {}
    for (var f in (profiles || {})) next[f] = profiles[f]
    var current = {}
    var base = next[fingerprint] || Model.defaultProfile()
    for (var b in base) current[b] = base[b]
    for (var k in patch) current[k] = patch[k]
    next[fingerprint] = current
    profiles = next
    saveState()
  }

  function persistGlobal(patch) {
    var next = {}
    for (var f in (globalState || {})) next[f] = globalState[f]
    for (var k in patch) next[k] = patch[k]
    globalState = next
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
    fixPoll.running = true
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
      var parts = data.split(",")
      if (String(parts[2] || "") === "at.yrlf.wl_mirror") {
        // The focus steal happens when the window goes fullscreen, shortly
        // after openwindow — hand focus back once that has settled.
        if (pendingRefocus !== "") refocusTimer.restart()
        break
      }
      if (!profile.autopilot || !prompterConnected || activeMode === "teleprompter") break
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
          startWindowMirror(address, cls, true)
        }
      }
      break
    }
    // Joining a meeting in an already-open window (Teams/Meet PWAs) only
    // changes the title — openwindow never fires.
    case "windowtitlev2": {
      if (!profile.autopilot || !prompterConnected || activeMode === "teleprompter") break
      var titleParts = data.split(",")
      var taddr = "0x" + titleParts[0]
      var ttitle = titleParts.slice(1).join(",")
      if (activeMode === "window" && taddr === targetWindowAddress) break
      if (!Model.matchMeetingTitle({ title: ttitle }, null)) break
      if (autopilotAddress === taddr) break   // already offered or mirrored
      autopilotAddress = taddr
      if (profile.autopilotConfirm) {
        notifyProcess.command = ["notify-send", "-a", "Prompter", "Meeting window detected",
          "Open the Prompter panel or run: omarchy-shell prompter mirrorMeeting"]
        notifyProcess.startDetached()
      } else {
        startWindowMirror(taddr, ttitle, true)
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
        if (root.pendingMeetingScan) {
          root.pendingMeetingScan = false
          var meeting = Model.findMeetingClient(root.clients, root.monitors)
          if (meeting)
            root.startWindowMirror(String(meeting.address),
              String(meeting["class"] || meeting.title || ""), true)
          else
            root.lastError = "No meeting window found (Teams, Zoom, Meet)."
        }
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
        if (!client || !client.address) return
        var monitor = Model.monitorForClient(client, root.monitors)
        if (root.isMirrorClient(client) || (monitor && Model.isPrompterMonitor(monitor))) {
          root.lastError = "Focus a window on another display first."
          return
        }
        root.startWindowMirror(String(client.address), String(client["class"] || client.title || ""))
      } catch (e) {}
    }
  }

  Process {
    id: mirrorProcess
    stdinEnabled: true
    stderr: StdioCollector { id: mirrorStderr; waitForEnd: true }
    onExited: function (exitCode) {
      if (root.stopRequested) { root.stopRequested = false; return }
      if (root.activeMode === "mirror" || root.activeMode === "window" || root.activeMode === "region") {
        var detail = String(mirrorStderr.text || "").trim().split("\n").pop() || ""
        root.lastError = "wl-mirror exited unexpectedly (code " + exitCode + ")."
          + (detail !== "" ? " " + detail : "")
        console.log("prompter: wl-mirror exit", exitCode, mirrorStderr.text)
        root.activeMode = "off"
        followPoll.running = false
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
      root.lastError = ""
      root.launchMirror(region)
      root.persistProfile({ mode: "region" })
    }
  }

  Process { id: saveProcess }

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
      fixPoll.running = false
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

  // Fires once the microphone has been quiet for a while during a followed
  // meeting — the call is over.
  Timer {
    id: meetingEndTimer
    interval: 8000
    onTriggered: {
      if (!root.meetingFollow || root.activeMode !== "window" || root.callActive) return
      if (root.profile.autopilotConfirm) {
        root.callWasActive = false   // one reminder per call
        notifyProcess.command = ["notify-send", "-a", "Prompter", "Meeting ended",
          "The prompter is still mirroring. Stop it from the panel or run: omarchy-shell prompter off"]
        notifyProcess.startDetached()
      } else {
        root.stopEngine()
        notifyProcess.command = ["notify-send", "-a", "Prompter", "Meeting ended",
          "Prompter is back to monitor mode."]
        notifyProcess.startDetached()
      }
    }
  }

  Timer {
    id: refocusTimer
    interval: 250
    onTriggered: {
      if (root.pendingRefocus === "") return
      // Omarchy's Hyprland uses the Lua config parser; classic dispatcher
      // strings are rejected there.
      Hyprland.dispatch('hl.dsp.focus({ monitor = "' + root.pendingRefocus + '" })')
      root.pendingRefocus = ""
    }
  }
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
      if (root.autopilotAddress !== "") root.startWindowMirror(root.autopilotAddress, "meeting", true)
      else root.scanForMeeting()
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
    function flip(): void { root.toggleFlip() }
    // "on" notifies before mirroring, "instant" mirrors immediately, "off"
    // disables meeting detection for the current monitor setup.
    function autopilot(mode: string): void {
      if (mode === "off") root.persistProfile({ autopilot: false })
      else root.persistProfile({ autopilot: true, autopilotConfirm: mode !== "instant" })
    }
    function status(): string {
      return JSON.stringify({
        mode: root.activeMode,
        prompter: root.prompterName,
        source: root.mirrorSource,
        window: root.targetWindowAddress,
        mirrorRunning: mirrorProcess.running,
        monitors: root.monitors.length,
        profile: root.profile,
        callActive: root.callActive,
        meetingFollow: root.meetingFollow,
        stateLoaded: root.stateLoaded,
        doctorHealthy: root.doctorHealthy,
        lastError: root.lastError
      })
    }
  }

  // ---------------------------------------------------------------------
  // Teleprompter overlay window

  Loader {
    id: teleprompterLoader
    active: root.teleprompterOpen && root.prompterConnected
    sourceComponent: TeleprompterOverlay {
      service: root
    }
  }
}
