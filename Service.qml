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
  property string meetingScanAction: ""    // "" | "start" | "offer"

  // Call detection. Two system-level signals, no app knowledge needed:
  //  - camera: a process holds /dev/video* -> a video call or recording.
  //    This is the default trigger; the prompter only matters on video.
  //  - microphone: a PipeWire capture stream -> any call (opt-in trigger,
  //    and part of the end condition so muting video mid-call is not "end").
  property bool meetingFollow: false       // window mode came from meeting detection
  property bool callWasActive: false
  property var cameraHolders: []           // [{device, comm, chain:[pids]}]
  readonly property bool cameraActive: cameraHolders.length > 0

  // A capture stream is isStream && audio && !isSink (playback streams
  // report isSink, cf. omarchy.media). Audio-filter infrastructure like
  // noise suppressors (capture.ns_source) holds a capture stream around the
  // clock and must not count as a call.
  readonly property bool micActive: {
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

  // In a call at all (end condition): camera OR mic still held.
  readonly property bool callActive: cameraActive || micActive
  // Should the autopilot act (start condition): camera, or mic if opted in.
  readonly property bool triggerActive: cameraActive || (profile.micTrigger && micActive)

  onTriggerActiveChanged: {
    console.log("prompter: trigger " + (triggerActive ? "on" : "off")
      + " (camera=" + cameraActive + ", mic=" + micActive + ", mode=" + activeMode + ")")
    if (!triggerActive) return
    if (profile.autopilot && prompterConnected
        && activeMode !== "teleprompter" && activeMode !== "window") {
      scanForMeeting(profile.autopilotConfirm ? "offer" : "start")
    }
  }

  onCallActiveChanged: {
    if (callActive) {
      if (meetingFollow && activeMode === "window") {
        callWasActive = true
        meetingEndTimer.stop()
      }
    } else {
      if (meetingFollow && activeMode === "window" && callWasActive)
        meetingEndTimer.restart()
      if (activeMode !== "window") autopilotAddress = ""   // re-offer on next call
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
  // Only a validated basename inside scriptsDir, never a raw path — a
  // tampered state file must not be able to point the shell at other files.
  property string currentScriptName: ""
  readonly property string currentScriptPath:
    currentScriptName !== "" ? scriptsDir + "/" + currentScriptName : ""
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
    stateReadProcess.command = Model.guardedReadCommand(statePath, 262144)
    stateReadProcess.running = true
    refreshMonitors()
    runDoctor()
    listScripts()
    lateOfferTimer.start()
  }

  // Catch calls whose rising edge we never saw (service started or profile
  // loaded mid-call) — offer once things have settled.
  Timer {
    id: lateOfferTimer
    interval: 3000
    onTriggered: {
      if (root.triggerActive && root.profile.autopilot && root.prompterConnected
          && root.activeMode === "off")
        root.scanForMeeting(root.profile.autopilotConfirm ? "offer" : "start")
    }
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
    console.log("prompter: startWindowMirror " + address + " meeting=" + (isMeeting === true))
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
  // a new window. action "start" mirrors the find, "offer" notifies.
  function scanForMeeting(action) {
    meetingScanAction = action === "offer" ? "offer" : "start"
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
    console.log("prompter: stopEngine (mode=" + activeMode + ")")
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
    readCurrentScript()   // fresh, guarded read on every start
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
    saveProcess.command = Model.saveStateCommand(statePath, payload)
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
        if (globalState.lastScript) {
          // Older state stored a full path; confine to a basename either way.
          var raw = String(globalState.lastScript)
          var base = raw.split("/").pop()
          var safe = Model.safeScriptName(base)
          if (safe !== "") { currentScriptName = safe; readCurrentScript() }
        }
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

  function selectScript(name) {
    var safe = Model.safeScriptName(name)
    if (safe === "") return
    currentScriptName = safe
    persistGlobal({ lastScript: safe })
    readCurrentScript()
  }

  function readCurrentScript() {
    if (currentScriptPath === "" || scriptReadProcess.running) return
    scriptReadProcess.command = Model.guardedReadCommand(currentScriptPath, 1048576)
    scriptReadProcess.running = true
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
      // Class-only here: PWA titles match around the clock, and the real
      // meeting-start trigger is the microphone (onCallActiveChanged).
      if (!profile.autopilot || !prompterConnected || activeMode === "teleprompter") break
      var address = "0x" + parts[0]
      var cls = String(parts[2] || "")
      var title = parts.slice(3).join(",")
      if (Model.matchMeetingWindow({ "class": cls, title: title }, null, null)) {
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

  // All collectors run their producers behind a deadline and a byte
  // ceiling so a wedged or hostile producer cannot balloon the shell.
  Process {
    id: monitorsProcess
    command: ["sh", "-c", "timeout 5 hyprctl -j monitors | head -c 1048576"]
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
    command: ["sh", "-c", "timeout 5 hyprctl -j clients | head -c 4194304"]
    stdout: StdioCollector { id: clientsOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      try {
        var parsed = JSON.parse(clientsOutput.text)
        root.clients = parsed instanceof Array ? parsed : []
        root.updateWindowRegion()
        if (root.meetingScanAction !== "") {
          var action = root.meetingScanAction
          root.meetingScanAction = ""
          // The camera holder's process tree points at the exact window —
          // works for any app, known or not. Patterns are the fallback.
          var meeting = root.cameraActive
            ? Model.windowForCameraHolders(root.clients, root.cameraHolders, root.monitors)
            : null
          if (!meeting) meeting = Model.findMeetingClient(root.clients, root.monitors)
          console.log("prompter: meeting scan (" + action + ") -> "
            + (meeting ? String(meeting.address) : "none"))
          if (!meeting) {
            if (action === "start")
              root.lastError = "No meeting window found (Teams, Zoom, Meet)."
          } else if (action === "start") {
            root.startWindowMirror(String(meeting.address),
              String(meeting["class"] || meeting.title || ""), true)
          } else if (root.autopilotAddress !== String(meeting.address)) {
            root.autopilotAddress = String(meeting.address)
            notifyProcess.command = ["notify-send", "-a", "Prompter", "Meeting call detected",
              "Mirror it from the Prompter panel, or run: omarchy-shell prompter mirrorMeeting"]
            notifyProcess.startDetached()
          }
        }
      } catch (e) {}
    }
  }

  Process {
    id: activeWindowProcess
    command: ["sh", "-c", "timeout 5 hyprctl -j activewindow | head -c 262144"]
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
    // Bounded: keep only the newest stderr line, truncated. A long-running
    // producer must never accumulate output in the shell process.
    property string lastStderrLine: ""
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { mirrorProcess.lastStderrLine = String(line).slice(0, 300) }
    }
    onStarted: lastStderrLine = ""
    onExited: function (exitCode) {
      if (root.stopRequested) { root.stopRequested = false; return }
      if (root.activeMode === "mirror" || root.activeMode === "window" || root.activeMode === "region") {
        var detail = mirrorProcess.lastStderrLine
        root.lastError = "wl-mirror exited unexpectedly (code " + exitCode + ")."
          + (detail !== "" ? " " + detail : "")
        console.log("prompter: wl-mirror exit", exitCode, detail)
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

  // Which processes hold a camera right now. fuser prints holder PIDs; the
  // ancestor chain is included because browsers and Electron apps open the
  // device from a helper process while the window belongs to the parent.
  Process {
    id: cameraPollProcess
    command: ["sh", "-c",
      'timeout 4 sh -c \'' +
      'for dev in /dev/video*; do [ -e "$dev" ] || continue; ' +
      'for pid in $(fuser "$dev" 2>/dev/null); do ' +
      'chain="$pid"; p="$pid"; i=0; while [ "$i" -lt 8 ]; do ' +
      'p=$(awk "/^PPid:/{print \\$2}" "/proc/$p/status" 2>/dev/null); ' +
      '[ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break; ' +
      'chain="$chain,$p"; i=$((i+1)); done; ' +
      'printf "%s|%s|%s\\n" "$dev" "$(head -c 64 "/proc/$pid/comm" 2>/dev/null)" "$chain"; ' +
      'done; done\' | head -n 32 | head -c 8192']
    stdout: StdioCollector { id: cameraPollOutput; waitForEnd: true }
    onExited: {
      var holders = Model.parseCameraHolders(cameraPollOutput.text)
      // Rebuild only on change so the property does not churn every poll.
      if (JSON.stringify(holders) !== JSON.stringify(root.cameraHolders))
        root.cameraHolders = holders
    }
  }

  Timer {
    id: cameraPoll
    interval: 3000
    repeat: true
    running: root.prompterConnected
    triggeredOnStart: true
    onTriggered: { if (!cameraPollProcess.running) cameraPollProcess.running = true }
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
      'timeout 5 ls -1 "$dir" | head -n 200 | head -c 16384', "list-scripts",
      pluginDir + "/resources/example-script.md"]
    stdout: StdioCollector { id: scriptsOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      var names = String(scriptsOutput.text || "").split("\n")
        .map(function (n) { return Model.safeScriptName(n.trim()) })
        .filter(function (n) { return n !== "" })
      root.scriptFiles = names
      if (root.currentScriptName === "" && names.length)
        root.selectScript(names[0])
    }
  }

  // Guarded reads (see Model.guardedReadCommand): refuse symlinks, validate
  // the opened inode (regular file, owned by us, size ceiling), bounded read.
  Process {
    id: stateReadProcess
    stdout: StdioCollector { id: stateReadOutput; waitForEnd: true }
    onExited: function (exitCode) {
      root.applyLoadedState(exitCode === 0 ? stateReadOutput.text : "")
    }
  }

  Process {
    id: scriptReadProcess
    stdout: StdioCollector { id: scriptReadOutput; waitForEnd: true }
    onExited: function (exitCode) {
      root.currentScriptText = exitCode === 0 ? scriptReadOutput.text : ""
    }
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
      else root.scanForMeeting("start")
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
        cameraActive: root.cameraActive,
        micActive: root.micActive,
        cameraHolders: root.cameraHolders,
        meetingFollow: root.meetingFollow,
        autopilotAddress: root.autopilotAddress,
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
