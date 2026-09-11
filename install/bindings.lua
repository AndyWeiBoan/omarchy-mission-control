-- Mission Control keybindings, for ~/.config/hypr/bindings.lua (Omarchy's Lua
-- Hyprland config). Plugins cannot bind keys themselves, so this is manual.

o.bind("CTRL + UP", "Mission Control",
  "omarchy-shell shell toggle io.github.andyweiboan.missioncontrol '{}'")

-- A dedicated exit rather than a second toggle: a key that OPENS the overview
-- when it is shut is not an exit key. There is an in-overview CTRL+DOWN handler
-- as well, but a modifier pressed while an exclusive-focus layer holds the
-- keyboard does not always reach the client, so the compositor bind is the one
-- that is guaranteed to fire.
o.bind("CTRL + DOWN", "Close Mission Control",
  "omarchy-shell shell hide io.github.andyweiboan.missioncontrol")
