// Pure helpers for the Prompter plugin. No Quickshell imports here so the
// logic stays testable with plain node (tests/model.test.js).
.pragma library

// ---------------------------------------------------------------------------
// Prompter and monitor detection

// The Elgato Prompter identifies itself over EDID as make "IDI" with a model
// starting in "Elgato Prom" (truncated by EDID's 13-char descriptor). Matching
// on that instead of the connector name survives replugs and docks.
function isPrompterMonitor(monitor) {
  if (!monitor) return false
  var make = String(monitor.make || "").trim().toUpperCase()
  var model = String(monitor.model || "").trim().toUpperCase()
  return make === "IDI" && model.indexOf("ELGATO PROM") === 0
}

function findPrompter(monitors) {
  var list = monitors instanceof Array ? monitors : []
  for (var i = 0; i < list.length; i++) {
    if (isPrompterMonitor(list[i])) return list[i]
  }
  return null
}

function sourceCandidates(monitors) {
  var list = monitors instanceof Array ? monitors : []
  return list.filter(function (m) {
    return m && !isPrompterMonitor(m) && m.disabled !== true
  })
}

function monitorByName(monitors, name) {
  var list = monitors instanceof Array ? monitors : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].name) === String(name)) return list[i]
  }
  return null
}

// A setup is identified by which displays are attached, never by which port
// they happen to use. Sorted so cable shuffles produce the same fingerprint.
function setupFingerprint(monitors) {
  var parts = (monitors instanceof Array ? monitors : []).map(function (m) {
    return [m.make || "", m.model || "", m.serial || ""].join("|")
  })
  parts.sort()
  return parts.join("::")
}

// ---------------------------------------------------------------------------
// wl-mirror command construction

// Build the argv for wl-mirror. opts:
//   prompterName  connector of the prompter output (fullscreen target)
//   source        connector of the source output ("" when region carries it)
//   region        "x,y WxH output" region string, or ""
//   flip          mirror horizontally for the beam-splitter glass
//   scaling       "fit" | "cover"
//   showCursor    include the cursor in the mirror
function wlMirrorCommand(opts) {
  var argv = ["wl-mirror", "--stream", "--fullscreen-output", String(opts.prompterName)]
  argv.push("-s", opts.scaling === "cover" ? "cover" : "fit")
  if (!opts.showCursor) argv.push("--no-show-cursor")
  if (opts.flip) argv.push("-t", "flipX")
  if (opts.region) argv.push("-r", String(opts.region))
  else argv.push(String(opts.source))
  return argv
}

// Lines written to a running `wl-mirror --stream` stdin. Each line is parsed
// like extra command-line options.
function streamRegionLine(region) {
  return "-r '" + String(region).replace(/'/g, "") + "'"
}

function streamTransformLine(flip) {
  return flip ? "-t flipX" : "-t normal"
}

function streamFullscreenLine(prompterName) {
  return "--fullscreen-output '" + String(prompterName).replace(/'/g, "") + "'"
}

// wl-mirror regions use global logical layout coordinates (slurp's format);
// a trailing output name binds the region to that output, and the region
// must lie inside it. Hyprland clients already report global coordinates.
function regionForClient(client, monitor) {
  if (!client || !monitor) return ""
  var at = client.at instanceof Array ? client.at : [0, 0]
  var size = client.size instanceof Array ? client.size : [0, 0]
  var scale = Number(monitor.scale || 1) || 1
  var x = Math.round(Number(at[0]))
  var y = Math.round(Number(at[1]))
  var w = Math.round(Number(size[0]))
  var h = Math.round(Number(size[1]))
  // Clamp to the monitor's global rect so partially off-screen windows still
  // produce a region wl-mirror accepts.
  var mx = Math.round(Number(monitor.x || 0))
  var my = Math.round(Number(monitor.y || 0))
  var mw = Math.round(Number(monitor.width || 0) / scale)
  var mh = Math.round(Number(monitor.height || 0) / scale)
  if (mw > 0 && mh > 0) {
    if (x < mx) { w -= mx - x; x = mx }
    if (y < my) { h -= my - y; y = my }
    w = Math.min(w, mx + mw - x)
    h = Math.min(h, my + mh - y)
  }
  if (w <= 0 || h <= 0) return ""
  return x + "," + y + " " + w + "x" + h + " " + String(monitor.name)
}

// Full-output region in global logical coordinates.
function regionForOutput(monitor) {
  if (!monitor) return ""
  var scale = Number(monitor.scale || 1) || 1
  var w = Math.round(Number(monitor.width || 0) / scale)
  var h = Math.round(Number(monitor.height || 0) / scale)
  if (w <= 0 || h <= 0) return ""
  return Math.round(Number(monitor.x || 0)) + "," + Math.round(Number(monitor.y || 0))
    + " " + w + "x" + h + " " + String(monitor.name)
}

// Which monitor a client sits on, resolved via Hyprland's client.monitor id.
function monitorForClient(client, monitors) {
  if (!client) return null
  var list = monitors instanceof Array ? monitors : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && Number(list[i].id) === Number(client.monitor)) return list[i]
  }
  return null
}

// ---------------------------------------------------------------------------
// Meeting window detection (autopilot)

var DEFAULT_MEETING_PATTERNS = [
  // Dedicated clients
  "^teams-for-linux$",
  "^us\\.zoom\\.Zoom$",
  "^[Zz]oom(\\s|$)",
  // PWAs: chromium-family class names carry the app host
  "teams\\.microsoft\\.com",
  "meet\\.google\\.com",
  // Electron Slack huddles run inside the main Slack window; opt-in only.
]

// Chromium-family PWAs carry an opaque app-id hash in their class
// (chrome-<hash>-Default), so PWAs are only recognizable by title.
var DEFAULT_MEETING_TITLE_PATTERNS = [
  "Microsoft Teams",
  "Zoom (Meeting|Workplace)",
  "Google Meet",
  "meet\\.google\\.com",
]

function matchMeetingTitle(client, titlePatterns) {
  var tps = titlePatterns instanceof Array && titlePatterns.length
    ? titlePatterns : DEFAULT_MEETING_TITLE_PATTERNS
  var title = String(client && client.title || "")
  for (var i = 0; i < tps.length; i++) {
    try { if (new RegExp(tps[i]).test(title)) return true } catch (e) {}
  }
  return false
}

function matchMeetingWindow(client, classPatterns, titlePatterns) {
  if (!client) return false
  var classes = [String(client.class || ""), String(client.initialClass || "")]
  var cps = classPatterns instanceof Array && classPatterns.length
    ? classPatterns : DEFAULT_MEETING_PATTERNS
  for (var i = 0; i < cps.length; i++) {
    var re
    try { re = new RegExp(cps[i]) } catch (e) { continue }
    if (re.test(classes[0]) || re.test(classes[1])) return true
  }
  var tps = titlePatterns instanceof Array ? titlePatterns : []
  var title = String(client.title || "")
  for (var j = 0; j < tps.length; j++) {
    try { if (new RegExp(tps[j]).test(title)) return true } catch (e) {}
  }
  return false
}

// Find a meeting window among the already-open clients (a Teams PWA lives
// all day; joining a meeting only changes its title). Class matches rank
// above title matches; the currently focused one wins within a rank.
function findMeetingClient(clients, monitors) {
  var list = clients instanceof Array ? clients : []
  var best = null
  var bestScore = 0
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!c || c.mapped === false) continue
    if (String(c["class"] || "") === "at.yrlf.wl_mirror") continue
    var monitor = monitorForClient(c, monitors)
    if (monitor && isPrompterMonitor(monitor)) continue
    var score = 0
    if (matchMeetingWindow(c, null, null)) score = 4
    else if (matchMeetingTitle(c, null)) score = 2
    if (score > 0 && c.focusHistoryID === 0) score += 1
    if (score > bestScore) { best = c; bestScore = score }
  }
  return best
}

// ---------------------------------------------------------------------------
// Camera-based call detection

// Parse the camera-poll script output: one "device|comm|pid,ppid,..." line
// per process holding a /dev/video* node.
function parseCameraHolders(text) {
  var holders = []
  // Cardinality ceiling: no sane system has more camera holders than this.
  var lines = String(text || "").split("\n").slice(0, 32)
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("|")
    if (parts.length < 3) continue
    var chain = parts[2].split(",").map(function (p) { return Number(p) })
      .filter(function (p) { return p > 1 })
    if (!chain.length) continue
    holders.push({ device: parts[0], comm: parts[1], chain: chain })
  }
  return holders
}

// The process holding the camera is usually a child (browser video-capture
// utility, Electron helper), so match windows against the whole ancestor
// chain. When several windows of the same app qualify (multi-window
// browser), prefer the one that looks like a meeting, then the focused one.
function windowForCameraHolders(clients, holders, monitors) {
  var pids = {}
  var list = holders instanceof Array ? holders : []
  for (var h = 0; h < list.length; h++) {
    var chain = list[h].chain instanceof Array ? list[h].chain : []
    for (var c = 0; c < chain.length; c++) pids[Number(chain[c])] = true
  }
  var candidates = (clients instanceof Array ? clients : []).filter(function (w) {
    if (!w || w.mapped === false) return false
    if (String(w["class"] || "") === "at.yrlf.wl_mirror") return false
    if (!pids[Number(w.pid)]) return false
    var monitor = monitorForClient(w, monitors)
    return !(monitor && isPrompterMonitor(monitor))
  })
  if (!candidates.length) return null
  var meeting = findMeetingClient(candidates, monitors)
  if (meeting) return meeting
  var focused = candidates.filter(function (w) { return w.focusHistoryID === 0 })
  return focused.length ? focused[0] : candidates[0]
}

// ---------------------------------------------------------------------------
// Teleprompter scripts

// Markdown headings (# / ##) open chapters; text in front of the first
// heading becomes an implicit chapter so plain-text scripts still work.
function parseScript(markdown) {
  var lines = String(markdown || "").split("\n")
  var chapters = []
  var current = null
  var ensure = function (title) {
    current = { title: title, lines: [], words: 0 }
    chapters.push(current)
  }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var heading = line.match(/^#{1,2}\s+(.*)$/)
    if (heading) {
      ensure(heading[1].trim())
      continue
    }
    if (!current) {
      if (line.trim() === "") continue
      ensure("")
    }
    current.lines.push(line)
    var words = line.trim().split(/\s+/).filter(function (w) { return w !== "" })
    current.words += words.length
  }
  var total = 0
  for (var c = 0; c < chapters.length; c++) {
    chapters[c].text = chapters[c].lines.join("\n").replace(/^\n+|\n+$/g, "")
    delete chapters[c].lines
    total += chapters[c].words
  }
  return { chapters: chapters, totalWords: total }
}

function formatDuration(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  var m = Math.floor(s / 60)
  var r = s % 60
  return m + ":" + (r < 10 ? "0" : "") + r
}

// Remaining reading time from what is left to scroll. contentHeight and
// remainingPx describe the flickable, pxPerSec is the scroll speed.
function remainingSeconds(remainingPx, pxPerSec) {
  var speed = Number(pxPerSec) || 0
  if (speed <= 0) return -1
  return Math.max(0, Number(remainingPx) || 0) / speed
}

// ---------------------------------------------------------------------------
// Setup doctor

// Ordered diagnosis cascade. Each stage names the shell command the panel
// runs (read-only) and how to interpret exit status / stdout.
function doctorChecks() {
  return [
    {
      id: "usb",
      title: "DisplayLink device on USB",
      command: ["sh", "-c", "lsusb | grep -qi ' 17e9:'"],
      failure: "No DisplayLink USB device found. Connect the Prompter's USB-C cable."
    },
    {
      id: "packages",
      title: "Driver packages installed",
      command: ["sh", "-c", "pacman -Q evdi-dkms displaylink linux-headers >/dev/null 2>&1 || pacman -Q evdi displaylink >/dev/null 2>&1"],
      failure: "evdi-dkms, displaylink or linux-headers missing.",
      fix: "packages"
    },
    {
      id: "dkms",
      title: "evdi module built for this kernel",
      command: ["sh", "-c", "modinfo evdi >/dev/null 2>&1"],
      failure: "The evdi kernel module is not built for the running kernel.",
      fix: "packages"
    },
    {
      id: "service",
      title: "DisplayLink service running",
      command: ["sh", "-c", "systemctl is-enabled --quiet displaylink.service && systemctl is-active --quiet displaylink.service"],
      failure: "displaylink.service is not enabled and running.",
      fix: "service"
    },
    {
      id: "drm-env",
      title: "evdi visible to Hyprland (AQ_DRM_DEVICES)",
      // An empty/unset AQ_DRM_DEVICES means aquamarine scans every DRM
      // device, which includes evdi. Only a set-but-incomplete list hides
      // the DisplayLink output.
      command: ["sh", "-c",
        "[ -z \"$AQ_DRM_DEVICES\" ] && exit 0; set -- /sys/class/drm/card[0-9]*; evdi=; for c; do d=$(basename \"$(readlink -f \"$c/device/driver\" 2>/dev/null)\" 2>/dev/null); [ \"$d\" = evdi ] && evdi=/dev/dri/$(basename \"$c\"); done; [ -n \"$evdi\" ] && case \":$AQ_DRM_DEVICES:\" in *:$evdi:*) exit 0;; esac; exit 1"],
      failure: "AQ_DRM_DEVICES is set but misses the evdi DRM device, so Hyprland cannot see the prompter. Install the env snippet and log in again.",
      fix: "drm-env"
    },
    {
      id: "wl-mirror",
      title: "wl-mirror installed",
      command: ["sh", "-c", "command -v wl-mirror >/dev/null"],
      failure: "wl-mirror (official repos) is required for mirroring.",
      fix: "wl-mirror"
    }
  ]
}

// Fixes run visibly in a floating terminal so sudo can prompt. The runtime
// marker files let the panel notice completion, mirroring the pattern other
// Omarchy plugins use.
function fixCommand(fixId, pluginDir) {
  var marker = "\"$XDG_RUNTIME_DIR/omarchy-prompter-fix"
  var body
  switch (fixId) {
    case "packages":
      body = "omarchy pkg add linux-headers && omarchy pkg aur add evdi-dkms displaylink"
      break
    case "service":
      body = "sudo systemctl enable --now displaylink.service"
      break
    case "drm-env":
      body = "mkdir -p \"$HOME/.config/uwsm/env.d\" && cp '" + pluginDir
        + "/resources/50-omarchy-prompter-drm.sh' \"$HOME/.config/uwsm/env.d/50-omarchy-prompter-drm.sh\""
        + " && echo && echo 'Installed. Log out and back in so Hyprland picks up AQ_DRM_DEVICES.'"
      break
    case "wl-mirror":
      body = "omarchy pkg add wl-mirror"
      break
    default:
      return null
  }
  var script = "rm -f " + marker + ".failed\" " + marker + ".complete\"; status=0; "
    + body + " || status=$?; if [ \"$status\" -eq 0 ]; then : > " + marker
    + ".complete\"; else printf '%s\\n' \"$status\" > " + marker
    + ".failed\"; fi; read -r -p 'Press enter to close…' _ || true; (exit \"$status\")"
  return ["omarchy", "launch", "floating", "terminal", "with", "presentation", script]
}

// ---------------------------------------------------------------------------
// Guarded file IO
//
// The shell must never trust files an attacker could have replaced. Reads
// refuse symlinks at the path, then validate the inode actually opened
// (same descriptor via /proc/self/fd): regular file, owned by the current
// user, within the size ceiling — and read at most that many bytes from the
// already-open descriptor. Writes go through an exclusive random mode-0600
// temp file and an atomic rename (rename does not follow a symlink at the
// destination).

// The open must be atomic: a check-then-open shell sequence lets a symlink
// be raced into the pathname between the test and the open. Python opens
// with O_NOFOLLOW (the open itself fails on a final-component symlink, no
// window) plus O_NONBLOCK (a FIFO cannot block it), then validates the
// descriptor it actually holds — regular file, owner, size — before reading.
// python3 is guaranteed on Omarchy (uwsm depends on it).
function guardedReadCommand(path, maxBytes) {
  var py =
    "import os,sys,stat\n" +
    "p=sys.argv[1]; m=int(sys.argv[2])\n" +
    "try:\n" +
    "    fd=os.open(p, os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)\n" +
    "except FileNotFoundError: sys.exit(3)\n" +
    "except OSError: sys.exit(4)\n" +   // ELOOP (symlink) and friends
    "try:\n" +
    "    st=os.fstat(fd)\n" +
    "    if not stat.S_ISREG(st.st_mode): sys.exit(9)\n" +   // fifo/dir/device
    "    if st.st_uid != os.getuid(): sys.exit(7)\n" +
    "    if st.st_size > m: sys.exit(8)\n" +
    "    os.set_blocking(fd, True)\n" +
    "    left=m; buf=b''\n" +
    "    while left>0:\n" +
    "        chunk=os.read(fd, min(65536,left))\n" +
    "        if not chunk: break\n" +
    "        buf+=chunk; left-=len(chunk)\n" +
    "    os.write(1, buf)\n" +
    "finally:\n" +
    "    os.close(fd)\n"
  // Outer deadline stays as belt-and-suspenders against any unforeseen block.
  return ["timeout", "5", "python3", "-c", py, String(path), String(Math.max(1, maxBytes | 0))]
}

function saveStateCommand(path, payload) {
  var script =
    'path="$1"; dir=$(dirname "$path"); mkdir -p "$dir" || exit 1; ' +
    'umask 077; tmp=$(mktemp "$dir/.state.XXXXXXXX") || exit 1; ' +
    'printf %s "$2" > "$tmp" && mv -f "$tmp" "$path" || { rm -f "$tmp"; exit 1; }'
  return ["sh", "-c", script, "write-state", String(path), String(payload)]
}

// Connector names come from DRM and are interpolated into a Lua dispatch
// string; permit only the charset real connectors use so no quoting can
// ever escape the string literal.
function safeConnectorName(name) {
  var n = String(name || "")
  return /^[A-Za-z0-9._-]{1,64}$/.test(n) ? n : ""
}

// Script selection is confined to the scripts directory: only a plain
// basename with a known extension survives, never a path.
function safeScriptName(name) {
  var n = String(name || "")
  if (n.indexOf("/") !== -1 || n.indexOf("\\") !== -1 || n.indexOf("..") !== -1) return ""
  if (!/^[A-Za-z0-9][A-Za-z0-9._ -]{0,120}\.(md|txt)$/i.test(n)) return ""
  return n
}

// ---------------------------------------------------------------------------
// State persistence shape

function defaultProfile() {
  return {
    mode: "off",            // off | mirror | window | region | teleprompter
    sourceStrategy: "auto",  // auto | pinned
    pinnedSource: "",        // "make|model|serial" of the pinned source
    flip: false,
    scaling: "fit",
    showCursor: false,
    autopilot: false,
    autopilotConfirm: true,
    micTrigger: false        // also trigger on audio-only calls
  }
}

function monitorKey(monitor) {
  if (!monitor) return ""
  return [monitor.make || "", monitor.model || "", monitor.serial || ""].join("|")
}
