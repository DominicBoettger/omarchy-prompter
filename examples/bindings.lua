-- Prompter keybindings for ~/.config/hypr/bindings.lua
-- Every action is also available to Stream Deck / macro tools as a plain
-- command: omarchy-shell prompter <method>

-- Toggle the teleprompter scroll (great on a foot pedal or Stream Deck)
o.bind("SUPER SHIFT", "P", "exec", "omarchy-shell prompter playPause")

-- Mirror the display you are working on onto the prompter / turn it off
o.bind("SUPER SHIFT", "M", "exec", "omarchy-shell prompter mirror")
o.bind("SUPER SHIFT", "O", "exec", "omarchy-shell prompter off")

-- Mirror the currently focused window (e.g. your Teams call)
o.bind("SUPER SHIFT", "W", "exec", "omarchy-shell prompter mirrorActive")

-- Scroll speed while reading
o.bind("SUPER SHIFT", "up", "exec", "omarchy-shell prompter faster")
o.bind("SUPER SHIFT", "down", "exec", "omarchy-shell prompter slower")

-- Chapter navigation
o.bind("SUPER SHIFT", "right", "exec", "omarchy-shell prompter nextChapter")
o.bind("SUPER SHIFT", "left", "exec", "omarchy-shell prompter prevChapter")
