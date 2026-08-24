// Plain-node tests for Model.js. Run: node tests/model.test.js
const fs = require("fs")
const path = require("path")

const source = fs
  .readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "")
const Model = {}
new Function(
  "exports",
  source +
    "\n;" +
    [
      "isPrompterMonitor", "findPrompter", "sourceCandidates", "monitorByName",
      "setupFingerprint", "wlMirrorCommand", "streamRegionLine",
      "streamTransformLine", "regionForClient", "regionForOutput", "monitorForClient",
      "matchMeetingWindow", "matchMeetingTitle", "findMeetingClient",
      "parseCameraHolders", "windowForCameraHolders", "parseScript", "formatDuration",
      "guardedReadCommand", "saveStateCommand", "safeScriptName", "safeConnectorName",
      "remainingSeconds", "doctorChecks", "fixCommand", "defaultProfile",
      "monitorKey", "DEFAULT_MEETING_TITLE_PATTERNS",
    ]
      .map((n) => `exports.${n} = ${n};`)
      .join("\n")
)(Model)

let failures = 0
function check(name, actual, expected) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) return console.log(`ok   ${name}`)
  failures++
  console.log(`FAIL ${name}\n  expected ${e}\n  actual   ${a}`)
}

const prompter = { name: "DVI-I-1", make: "IDI", model: "Elgato Prom.", serial: "0x01348D27", width: 1024, height: 600, scale: 1, x: 0, y: 0, id: 2 }
const samsung = { name: "DP-7", make: "Samsung Electric Company", model: "SAMSUNG", serial: "0x01000E00", width: 3840, height: 2160, scale: 1, x: 1024, y: 0, id: 1 }
const laptop = { name: "eDP-1", make: "BOE", model: "NE135A1M-NY1", serial: "", width: 2880, height: 1920, scale: 2, x: 4864, y: 0, id: 0 }
const monitors = [laptop, samsung, prompter]

check("finds prompter by EDID", Model.findPrompter(monitors).name, "DVI-I-1")
check("prompter never a source", Model.sourceCandidates(monitors).map((m) => m.name), ["eDP-1", "DP-7"])
check("fingerprint is port independent",
  Model.setupFingerprint(monitors),
  Model.setupFingerprint([{ ...prompter, name: "DVI-I-9" }, samsung, laptop]))

check("wl-mirror argv",
  Model.wlMirrorCommand({ prompterName: "DVI-I-1", source: "DP-7", flip: true, scaling: "fit", showCursor: false }),
  ["wl-mirror", "--stream", "--fullscreen-output", "DVI-I-1", "-s", "fit", "--no-show-cursor", "-t", "flipX", "DP-7"])
check("wl-mirror argv with region",
  Model.wlMirrorCommand({ prompterName: "DVI-I-1", region: "0,0 3840x2160 DP-7", scaling: "cover", showCursor: true }),
  ["wl-mirror", "--stream", "--fullscreen-output", "DVI-I-1", "-s", "cover", "-r", "0,0 3840x2160 DP-7"])

check("region for client on 4k stays global",
  Model.regionForClient({ at: [1224, 100], size: [1280, 720] }, samsung),
  "1224,100 1280x720 DP-7")
check("region clamps to scaled monitor",
  Model.regionForClient({ at: [4864, 0], size: [2000, 2000] }, laptop),
  "4864,0 1440x960 eDP-1")
check("full output region is global",
  Model.regionForOutput(laptop),
  "4864,0 1440x960 eDP-1")
check("client monitor resolution", Model.monitorForClient({ monitor: 1 }, monitors).name, "DP-7")

check("teams-for-linux matches", Model.matchMeetingWindow({ class: "teams-for-linux" }), true)
check("teams pwa matches", Model.matchMeetingWindow({ class: "msedge-teams.microsoft.com__-Default" }), true)
check("zoom flatpak matches", Model.matchMeetingWindow({ class: "us.zoom.Zoom" }), true)
check("editor does not match", Model.matchMeetingWindow({ class: "code", title: "model.test.js" }), false)
check("title pattern matches when enabled",
  Model.matchMeetingWindow({ class: "chromium", title: "Meeting | Microsoft Teams" }, null, Model.DEFAULT_MEETING_TITLE_PATTERNS),
  true)

// Chrome PWAs hide the host behind an app-id hash; only the title gives
// Teams away (real-world shape from dob's machine).
const teamsPwa = {
  class: "chrome-ompifgpmddkgmclendfeacglnodjjndh-Default",
  initialClass: "chrome-ompifgpmddkgmclendfeacglnodjjndh-Default",
  title: "Microsoft Teams (PWA) - Calendar | Meeting with Dominic",
  mapped: true, monitor: 1, focusHistoryID: 3,
}
check("chrome pwa class alone does not match", Model.matchMeetingWindow(teamsPwa), false)
check("chrome pwa title matches", Model.matchMeetingTitle(teamsPwa, null), true)
check("scan finds teams pwa among clients",
  Model.findMeetingClient([
    { class: "foot", title: "shell", mapped: true, monitor: 1 },
    teamsPwa,
    { class: "at.yrlf.wl_mirror", title: "Microsoft Teams mirror", mapped: true, monitor: 2 },
  ], monitors).title,
  teamsPwa.title)
check("scan prefers dedicated client over pwa",
  Model.findMeetingClient([
    teamsPwa,
    { class: "teams-for-linux", title: "call", mapped: true, monitor: 1 },
  ], monitors).class,
  "teams-for-linux")

// Camera holders: the browser's video-capture helper (pid 5001) holds the
// device; the window belongs to an ancestor (pid 4000).
const holders = Model.parseCameraHolders(
  "/dev/video0|chromium|5001,4000,1200\n/dev/video1|pipewire|900\nbroken line\n")
check("camera holder parsing", holders.length, 2)
check("holder chain numbers", holders[0].chain, [5001, 4000, 1200])
const browserWin = { class: "chromium", title: "some tab", pid: 4000, mapped: true, monitor: 1, focusHistoryID: 2 }
const meetWin = { class: "chromium", title: "Google Meet - x", pid: 4000, mapped: true, monitor: 1, focusHistoryID: 5 }
check("camera pid chain finds window",
  Model.windowForCameraHolders([{ class: "foot", pid: 77, mapped: true, monitor: 1 }, browserWin], holders, monitors).pid,
  4000)
check("meeting-looking window preferred among candidates",
  Model.windowForCameraHolders([browserWin, meetWin], holders, monitors).title,
  "Google Meet - x")
check("no candidate when camera held by non-window process",
  Model.windowForCameraHolders([browserWin], [{ device: "/dev/video1", comm: "pipewire", chain: [900] }], monitors),
  null)

const script = Model.parseScript("intro line\n\n# One\ntext one here\n\n## Two\nsecond text")
check("implicit first chapter", script.chapters[0].title, "")
check("chapter titles", script.chapters.map((c) => c.title), ["", "One", "Two"])
check("word count", script.totalWords, 7)

check("duration format", Model.formatDuration(125), "2:05")
check("remaining seconds", Model.remainingSeconds(400, 40), 10)
check("remaining without speed", Model.remainingSeconds(400, 0), -1)

// Script confinement: only plain basenames with known extensions survive.
check("script name passes", Model.safeScriptName("My Talk_v2.md"), "My Talk_v2.md")
check("path traversal rejected", Model.safeScriptName("../../etc/passwd"), "")
check("absolute path rejected", Model.safeScriptName("/etc/passwd.md"), "")
check("wrong extension rejected", Model.safeScriptName("script.sh"), "")
check("hidden dotfile rejected", Model.safeScriptName(".hidden.md"), "")

// Guarded IO commands run through sh with the path as a positional arg.
const readCmd = Model.guardedReadCommand("/tmp/x state.json", 1000)
check("guarded read is argv-safe", readCmd.slice(-2), ["/tmp/x state.json", "1000"])
check("guarded read opens with O_NOFOLLOW", readCmd[4].includes("O_NOFOLLOW"), true)
check("guarded read validates via fstat", readCmd[4].includes("os.fstat(fd)"), true)
const saveCmd = Model.saveStateCommand("/tmp/state.json", '{"a":1}')
check("state write uses mktemp", saveCmd[2].includes("mktemp"), true)
check("state write sets umask 077", saveCmd[2].includes("umask 077"), true)

// Live behavior of the guarded IO scripts (run through real sh):
const cp = require("child_process")
const os = require("os")
const fs2 = require("fs")
const dir = fs2.mkdtempSync(os.tmpdir() + "/prompter-test-")
const run = (cmd) => cp.spawnSync(cmd[0], cmd.slice(1), { encoding: "utf8" })
const w = run(Model.saveStateCommand(dir + "/state.json", '{"ok":true}'))
check("state write succeeds", w.status, 0)
check("state file mode 0600", (fs2.statSync(dir + "/state.json").mode & 0o777), 0o600)
check("guarded read returns content",
  run(Model.guardedReadCommand(dir + "/state.json", 1000)).stdout, '{"ok":true}')
fs2.symlinkSync("/etc/hostname", dir + "/link.json")
check("guarded read rejects symlink",
  run(Model.guardedReadCommand(dir + "/link.json", 1000)).status, 4)
// A symlink to a perfectly valid file we own must STILL be refused — proves
// O_NOFOLLOW rejects at open, not merely when the target looks wrong (the
// TOCTOU the maintainer flagged: a raced-in symlink to an own regular file).
fs2.symlinkSync(dir + "/state.json", dir + "/ownlink.json")
check("guarded read rejects symlink to own file",
  run(Model.guardedReadCommand(dir + "/ownlink.json", 1000)).status, 4)
check("guarded read caps size",
  run(Model.guardedReadCommand(dir + "/state.json", 4)).status, 8)
// A FIFO at the path must fail fast, never block (kimi-k3 finding).
cp.spawnSync("mkfifo", [dir + "/fifo.json"])
const fifoStart = Date.now()
check("guarded read rejects fifo",
  run(Model.guardedReadCommand(dir + "/fifo.json", 1000)).status, 9)
check("fifo rejection is immediate", Date.now() - fifoStart < 2000, true)
check("guarded read has outer deadline", Model.guardedReadCommand("/x", 1).slice(0, 2), ["timeout", "5"])
fs2.rmSync(dir, { recursive: true, force: true })

check("connector name passes", Model.safeConnectorName("DVI-I-1"), "DVI-I-1")
check("lua injection rejected", Model.safeConnectorName('x" }) os.execute("rm'), "")

check("doctor has all stages", Model.doctorChecks().map((c) => c.id),
  ["usb", "packages", "dkms", "service", "drm-env", "wl-mirror"])
check("unknown fix is null", Model.fixCommand("nope", "/tmp"), null)
check("drm-env fix copies snippet",
  Model.fixCommand("drm-env", "/plug")[6].includes("/plug/resources/50-omarchy-prompter-drm.sh"),
  true)

process.exit(failures ? 1 : 0)
