# Prompter — Elgato Prompter for Omarchy

Turn your Elgato Prompter into a first-class citizen on
[Omarchy](https://omarchy.org). Elgato's Camera Hub does not exist for Linux —
this plugin replaces it and goes further.

- **Eye-contact mirroring without quality loss.** Mirror your working display
  (or just your meeting window, followed live) onto the prompter. Your screen
  share keeps capturing the real display at native 4K — the prompter is a
  read-only copy, not a detached surface.
- **Meeting autopilot.** Teams, Zoom and Meet windows are detected the moment
  they open and offered on the prompter.
- **Native teleprompter.** Markdown scripts with chapters, smooth scrolling,
  eyeline marker, countdown, remaining-time estimate, beam-splitter flip —
  rendered by the Omarchy shell in your theme's colors.
- **Control from anywhere.** Every action is one command
  (`omarchy-shell prompter play`), ready for Hyprland keybindings, a Stream
  Deck, or a presenter clicker.
- **Setup doctor.** Detects and fixes every step of the DisplayLink driver
  setup on Arch: packages, dkms build, service, and the `AQ_DRM_DEVICES`
  environment snippet Hyprland needs to see the output at all.
- **Per-setup profiles.** Home, laptop-only, office — settings are remembered
  per monitor combination (matched by EDID, not by port).

## Install

```bash
omarchy plugin add https://github.com/dominicboettger/omarchy-prompter.git --enable
```

Dependencies: `wl-mirror` (official repos) for mirroring, plus the DisplayLink
stack (`evdi-dkms`, `displaylink`, `linux-headers`). Open the panel — the
setup doctor checks all of it and offers one-click fixes.

> **Note:** After installing the DisplayLink stack you must log out and back
> in once so Hyprland starts with the evdi DRM device in `AQ_DRM_DEVICES`.
> The doctor installs the required snippet to `~/.config/uwsm/env.d/`.

## Usage

Click the prompter icon in the bar. Pick a mode:

| Mode | What it does |
|------|--------------|
| Mirror display | Mirrors the display you are working on (follows focus, or pin one) |
| Mirror window | Mirrors one window's region, followed as it moves |
| Mirror region | Mirrors a region you select with slurp |
| Teleprompter | Scrolls a Markdown script from `~/.local/share/omarchy-prompter/scripts` |

The mirrored window must be visible on its display — the mirror is a live
region copy, which is exactly why your screen share stays untouched.

### Remote control

```bash
omarchy-shell prompter mirror        # mirror the focused display
omarchy-shell prompter mirrorActive  # mirror the focused window
omarchy-shell prompter teleprompter  # start the teleprompter
omarchy-shell prompter playPause     # toggle scrolling
omarchy-shell prompter faster        # +10 px/s (slower: -10)
omarchy-shell prompter nextChapter   # jump chapters (prevChapter)
omarchy-shell prompter flip          # beam-splitter flip
omarchy-shell prompter autopilot instant   # meeting detection: instant | on | off
omarchy-shell prompter mirrorMeeting # mirror the detected meeting window
omarchy-shell prompter status        # engine state as JSON
omarchy-shell prompter off           # back to plain monitor mode
```

Keybinding examples for `~/.config/hypr/bindings.lua` are in
[`examples/bindings.lua`](examples/bindings.lua). Stream Deck: point any
button of your favorite tool (streamdeck-ui, OpenDeck) at these commands.

## Configure

```bash
omarchy bar move io.github.dominicboettger.prompter --section right
```

Teleprompter scripts are plain Markdown files; `#`/`##` headings become
chapters. Drop them into `~/.local/share/omarchy-prompter/scripts/`.

## Remove

```bash
omarchy plugin remove io.github.dominicboettger.prompter
```

## Development

```bash
scripts/dev-sync.sh --watch   # sync into ~/.config/omarchy/plugins (hot reload)
scripts/check.sh              # manifest validation + qmllint + unit tests
```

## License

MIT
