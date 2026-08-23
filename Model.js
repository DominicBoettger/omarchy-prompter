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
  if (!opts.showCursor) argv.push("--no-cursor")
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

// wl-mirror regions are output-local: "x,y WxH output". Hyprland clients
// report global layout coordinates, monitors report their own origin.
function regionForClient(client, monitor) {
  if (!client || !monitor) return ""
  var at = client.at instanceof Array ? client.at : [0, 0]
  var size = client.size instanceof Array ? client.size : [0, 0]
  var scale = Number(monitor.scale || 1) || 1
  var x = Math.round(Number(at[0]) - Number(monitor.x || 0))
  var y = Math.round(Number(at[1]) - Number(monitor.y || 0))
  var w = Math.round(Number(size[0]))
  var h = Math.round(Number(size[1]))
  // Hyprland positions are logical; wl-mirror regions are logical too, so no
  // scale conversion is needed. Clamp to the monitor so partially off-screen
  // windows still produce a valid region.
  var mw = Math.round(Number(monitor.width || 0) / scale)
  var mh = Math.round(Number(monitor.height || 0) / scale)
  if (mw > 0 && mh > 0) {
    if (x < 0) { w += x; x = 0 }
    if (y < 0) { h += y; y = 0 }
    w = Math.min(w, mw - x)
    h = Math.min(h, mh - y)
  }
  if (w <= 0 || h <= 0) return ""
  return x + "," + y + " " + w + "x" + h + " " + String(monitor.name)
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

var DEFAULT_MEETING_TITLE_PATTERNS = [
  "Microsoft Teams",
  "Zoom (Meeting|Workplace)",
  "Google Meet",
]

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
      title: "evdi listed in AQ_DRM_DEVICES",
      command: ["sh", "-c",
        "set -- /sys/class/drm/card[0-9]*; evdi=; for c; do d=$(basename \"$(readlink -f \"$c/device/driver\" 2>/dev/null)\" 2>/dev/null); [ \"$d\" = evdi ] && evdi=/dev/dri/$(basename \"$c\"); done; [ -n \"$evdi\" ] && case \":$AQ_DRM_DEVICES:\" in *:$evdi:*) exit 0;; esac; exit 1"],
      failure: "Hyprland was started without the evdi DRM device. Install the env snippet and log in again.",
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
    autopilotConfirm: true
  }
}

function monitorKey(monitor) {
  if (!monitor) return ""
  return [monitor.make || "", monitor.model || "", monitor.serial || ""].join("|")
}
