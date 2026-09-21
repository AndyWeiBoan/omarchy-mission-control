# Mission Control

A macOS-style workspace overview for [Omarchy](https://omarchy.org), as a shell plugin.

![Mission Control: a frosted strip of five desktop thumbnails across the top, the third hovered and showing its close badge, a grey + at the right-hand end, and the current desktop's window shrunk out beneath](preview.png)

A frosted strip of live desktop thumbnails across the top, and underneath it the
current desktop's windows shrunk out so none overlaps, each with its app icon and
title.

- Click a window to jump to it, or a desktop to switch to it.
- **Drag** a window onto a desktop to move it there.
- **Add** a desktop with the `+` at the right-hand end, **remove** one with the
  close badge that appears when you hover it.

The open is two-phase, and that is the whole point: the surface goes up with
every window drawn at its real size and position — pixel-for-pixel the desktop
you were already looking at — and only then do the windows shrink into place. So
your desktop appears to shrink, rather than a different-looking screen fading in
over it.

The thumbnails are live, including windows on workspaces you cannot currently
see. They are also complete: a screencopy of a toplevel is the client surface
only, so the title bar and border that the compositor draws are redrawn here from
the values Hyprland is actually using. Without that, dropping the overview made a
bar and an outline appear on every window at once.

## Install

```bash
omarchy plugin add https://github.com/AndyWeiBoan/omarchy-mission-control --enable
```

Then bind a key — plugins cannot bind keys themselves. In `~/.config/hypr/bindings.lua`:

```lua
o.bind("CTRL + UP", "Mission Control",
  "omarchy-shell shell toggle io.github.andyweiboan.missioncontrol '{}'")

-- Optional: a dedicated exit, so CTRL+UP is never an accidental re-open.
o.bind("CTRL + DOWN", "Close Mission Control",
  "omarchy-shell shell hide io.github.andyweiboan.missioncontrol")
```

For the legacy (non-Lua) Hyprland config format, see [`install/bindings.conf`](install/bindings.conf).

Touchpad gestures are optional and live in [`install/gestures.lua`](install/gestures.lua):
three- or four-finger swipe up to open, swipe down to close.

## Removal

```bash
omarchy plugin disable io.github.andyweiboan.missioncontrol
omarchy plugin remove  io.github.andyweiboan.missioncontrol
```

Then delete the two binds you added to `bindings.lua`, and the gestures from
`input.lua` if you added those.

The plugin writes nothing outside its own folder — no config files, no state, no
autostart entries, nothing in `~/.local`. Removing it leaves nothing behind, and
disabling it is enough to stop it being mounted. The keybindings are the only
thing it asks you to change, and you make that change yourself.

Two things it does change, both at runtime only and both undone: a scrolling
workspace's layout while the overview is open (see
[Scrolling workspaces](#scrolling-workspaces)), and the persistence of any
desktop you add or remove (see [Desktops](#desktops)). Neither touches your
config, so `hyprctl reload` restores whatever that says.

## Keys and mouse

| Key | Action |
| --- | --- |
| `←` `→` | Walk the Spaces strip — switches desktop **without** closing, so you can look before you leap |
| `↑` `↓` | Move between the windows of the current desktop. On a single row of windows, where there is nothing above or below, they step along the row instead |
| `Tab` | Cycle windows |
| `1`–`9` | Jump straight to that desktop |
| `Enter` | Open the selected window |
| `Esc`, click the backdrop | Close |
| `CTRL`+`↓` / `CTRL`+`↑` | Close (mirrors whatever opened it) |

Clicking a desktop thumbnail switches to it and closes. Clicking a window
focuses it and closes. Clicking anywhere in the strip that is not a desktop does
nothing — the strip is not backdrop.

**Dragging** a window preview picks it up and shrinks it. Held over a desktop it
shrinks further and that desktop springs — it goes in when you let go, not
before. The `+` at the end takes a drop too, for a desktop that does not exist
yet. The view stays where it is, so you can move several windows without leaving
the overview.

## Desktops

The `+` at the right-hand end adds one; the badge in a desktop's corner, which
appears when you hover it, removes that one. A removed desktop's windows are
moved to the nearest desktop that is staying — nothing here closes a window.

Ten is the ceiling, because ten is what Omarchy binds: its `tiling.lua` does
`for workspace = 1, 10`, so `SUPER`+`1` through `SUPER`+`0` reach ten desktops
and nothing reaches an eleventh. At ten the `+` greys out rather than
disappearing. Hyprland itself has no limit; if you change that loop, change
`maxWorkspaces` with it.

Both are runtime-only, and that is the right shape rather than a shortcoming.
Your Hyprland config is what says which desktops exist — a `for i = 1, 5` of
persistent workspace rules, typically — so a reload returns to that, and this
plugin never writes to it. What survives a reload is what has windows on it:
Hyprland does not collect a workspace that is not empty. So a desktop you added
and put something on stays, and one you added and left empty does not.

The strip scrolls once there are more desktops than fit, by two-finger swipe or
by dragging its background. It settles with the last desktop the same distance
from the `+` as the sixth desktop has — six being the last count that fits
without scrolling, and so the last spacing nobody had to choose. Scrolling by
hand is not held to that: it runs from the first desktop against the left margin
to the last against the right, under the `+` and past it, wherever you want to
put it.

## Scrolling workspaces

Hyprland's scrolling layout puts a workspace's windows in one long row that runs
off both edges of the screen. Thumbnails of the windows out there come up blank,
and there is no error anywhere to say why: Hyprland does not copy a screencopy
frame for a window whose rect does not intersect the monitor, and it skips it
silently.

So the overview takes the workspace off the accordion while it is open — scrolling
to dwindle, which puts every window back on the monitor — and puts it back on
close. Verified reversible across eight open/close cycles: position, size and
column order all come back identical.

This has costs, and they are visible:

- Every window is resized twice, on the way in and on the way out. Terminals
  reflow, and the thumbnails are of the reflowed windows rather than of the row
  you left.
- The desktop is seen to re-tile, once each way.
- dwindle's tiling is very uneven, so the thumbnails are too.

Nothing happens on a workspace whose windows all fit on the screen, which is
every ordinary tiled desktop.

## Known issues

**The Spaces strip snaps into place instead of sliding.** Recorded at 60fps, its
bottom edge goes from absent to its final position in a single frame, on every
open. One early recording did catch an open moving over four frames and that has
not reproduced. The durations are not the problem — the animation is not running.
Two candidates have been eliminated: a Behavior that never saw a change (the item
is created with the overview already expanded, so its position binding evaluates
straight to its final value), and the one-frame delay meant to fix that. The
remaining suspicion is that the surface only becomes visible after the animation
has already run, which would make every measurement of it a measurement of the
aftermath.

**Dragging several windows to the same desktop does not preserve their order.**
Where a window lands is Hyprland's insertion rule, which puts it next to the
target desktop's *active* window — and moving without following means the window
that arrives never becomes active, so the next one is inserted next to the same
old reference. Measured: moving four windows in the order A B C D produced
A C D B. Making the view follow and switching back does fix the order, and
flickers doing it — recorded at 60fps, two frames of the target desktop, 33 ms,
which is exactly long enough to see. There is no silent focus dispatcher to do
it with instead; `follow = false`, `silent = true` and no argument at all were
all measured and all switch the view.

**Removing a desktop can take a moment to show.** Dropping a workspace's
persistence is not always acted on immediately — measured once as needing a
second request before the workspace disappeared — so the strip may keep the
desktop for a beat after the badge is clicked.

**Dragging floating windows is untested.** Tiled windows are what this has been
exercised on.

**The flatten occasionally does not trigger.** Observed once on a workspace with
two windows fully off screen: the overview opened without flattening and their
thumbnails were blank. This is the same class of fault as an earlier one that was
fixed — the layout name is read from a cached IPC object that only updates on
events nothing here subscribes to — so the fix is probably incomplete rather than
wrong.

**Thumbnails of windows on a scrolling workspace are of the flattened layout.**
See above. There is no way to have both: a window has to be inside the monitor
for Hyprland to produce its frames at all, and six full-size windows do not fit
on one screen.

## Requirements

Nothing to install — everything it uses ships with Omarchy.

One external command: the bundled `bin/wallpaper-token` runs as a POSIX shell
and uses coreutils `readlink`/`stat`/`basename` to read file metadata about
Omarchy's `current/background` link. It prints a short cache token, never a
path; the wallpaper is always loaded through the link itself.

- Omarchy with shell plugin support (`omarchy plugin list` works)
- Hyprland — window geometry comes from its IPC, and thumbnails from
  `wlr-screencopy`
- **Persistent workspaces**, if you want the strip to be stable. Hyprland only
  creates a workspace when something lands on it, so without pinning them the
  strip grows and shrinks as you work. In `~/.config/hypr/looknfeel.lua`:

  ```lua
  hl.workspace({ id = 1, persistent = true })  -- ... and so on for 2..N
  ```

  It works without this; the strip is just less stable.

hyprbars is optional. Its bar height is asked for once at load, and when it is
not installed the answer is zero: nothing is drawn and the geometry collapses to
what it would have been.

## Theming

Labels follow the shell's menu font, so `OMARCHY_MENU_FONT` is honoured and the
plugin matches the rest of Omarchy. The background is your real wallpaper, read
from Omarchy's `current/background` link, so a theme switch is picked up with no
reload.

The window decorations are drawn from live values rather than assumed ones: the
bar's colour is the theme's `background`, which is what hyprbars is given, and
the border's size, rounding and both colours are read from Hyprland. The active
border happens to be the theme's accent today, and saying so in code would make
it wrong the moment it is not.

The `+` and the close badge are drawn rather than typed. A `+` or `×` from the
menu font is a typographic glyph — short, thick, and sitting on the text baseline
rather than in the middle of the disc it is supposed to be centred in.

The desktop behind the overview is deliberately **not** blurred — macOS does not
blur it in Mission Control either. Only the Spaces strip is frosted, and that
blur is done here in QML rather than by the compositor, on the plugin's own copy
of the wallpaper.

Earlier versions of this file warned against adding a compositor `blur = true`
layer rule for the `mission-control` namespace, on the grounds that it set
hyprbars' title bars flickering. That was wrong. The flicker is
[hyprwm/hyprland-plugins#697](https://github.com/hyprwm/hyprland-plugins/issues/697):
Hyprland's blurred-texture path leaves `glStencilMask` at `0x00`, so hyprbars'
rounded-corner mask silently writes nothing and the bar is tested against the
previous surface's discard mask. It has nothing to do with this plugin, and a
blur rule here is harmless.

## Why not hyprexpo

hyprexpo does a similar job inside the compositor, but it is a render pass, not
a client: it clears the whole monitor to `bg_col` every frame, so a transparent
`bg_col` still paints black and nothing shows through from underneath, and
`wallpaper_bg = 1` draws Hyprland's *built-in* wallpaper, which Omarchy does not
use. Owning a surface is the only way to get the real desktop behind the
overview.

Both were measured rather than assumed — see [docs/FINDINGS.md](docs/FINDINGS.md).

## Performance

The plugin declares `keepLoaded: true`, so the shell mounts it at startup and it
stays mounted, hidden, until summoned. That is not an optimisation detail, it is
the difference between usable and not: a standalone predecessor launched a
Quickshell process per keypress and took ~340ms before anything appeared —
~145ms of Qt/QML startup plus ~190ms decoding a 5120×2880 wallpaper, neither
avoidable per launch. Mounted once, `summon` to mapped surface measures 37–48ms
on this machine.

Window captures run only while the overview is shown, so a mounted-but-hidden
plugin costs nothing beyond the decoded wallpaper it is holding.

The strip's frost is a single blurred copy of that same cached wallpaper, blurred
once and re-positioned rather than re-blurred, so it costs nothing per frame
either.

## Licence

MIT — see [LICENSE](LICENSE).
