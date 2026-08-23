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
      "matchMeetingWindow", "matchMeetingTitle", "findMeetingClient", "parseScript", "formatDuration",
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

const script = Model.parseScript("intro line\n\n# One\ntext one here\n\n## Two\nsecond text")
check("implicit first chapter", script.chapters[0].title, "")
check("chapter titles", script.chapters.map((c) => c.title), ["", "One", "Two"])
check("word count", script.totalWords, 7)

check("duration format", Model.formatDuration(125), "2:05")
check("remaining seconds", Model.remainingSeconds(400, 40), 10)
check("remaining without speed", Model.remainingSeconds(400, 0), -1)

check("doctor has all stages", Model.doctorChecks().map((c) => c.id),
  ["usb", "packages", "dkms", "service", "drm-env", "wl-mirror"])
check("unknown fix is null", Model.fixCommand("nope", "/tmp"), null)
check("drm-env fix copies snippet",
  Model.fixCommand("drm-env", "/plug")[6].includes("/plug/resources/50-omarchy-prompter-drm.sh"),
  true)

process.exit(failures ? 1 : 0)
