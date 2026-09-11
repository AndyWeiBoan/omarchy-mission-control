-- Optional touchpad gestures, for ~/.config/hypr/input.lua.
--
-- Three and four fingers both: macOS uses three, and three here coexists with
-- the three-finger *horizontal* workspace swipe, because `direction` is part of
-- the gesture spec and the axis distinguishes them.
--
-- Two fingers is not possible, and this is not a Hyprland limitation: libinput
-- only emits SWIPE events for three or more fingers. Two is always scroll or
-- pinch, and there is no horizontal-scroll bind to hang a workspace switch off.
--
-- Testing note: there is no unset/ungesture in the Lua API (only hl.unbind for
-- keys), so a `hyprctl reload` cannot remove a gesture registered earlier in
-- the session. Editing this file and reloading is NOT a valid way to test a
-- gesture change -- log out and back in. Relatedly, if a gesture stops
-- responding entirely, that is a known upstream Hyprland bug rather than a
-- conflict with these; restarting the compositor clears it.
--
-- `hide` rather than a bare toggle on the downward swipe, for the same reason
-- as CTRL+DOWN in bindings.lua.

local mc_toggle = "omarchy-shell shell toggle io.github.andyweiboan.missioncontrol '{}'"
local mc_hide   = "omarchy-shell shell hide io.github.andyweiboan.missioncontrol"

for _, fingers in ipairs({ 3, 4 }) do
  hl.gesture({ fingers = fingers, direction = "up", action = function()
    hl.dispatch(hl.dsp.exec_cmd(mc_toggle))
  end })
  hl.gesture({ fingers = fingers, direction = "down", action = function()
    hl.dispatch(hl.dsp.exec_cmd(mc_hide))
  end })
end
