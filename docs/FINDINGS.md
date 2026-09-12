# Findings

Things that were measured rather than assumed while building this, kept because
each one cost real time to discover and every one of them is a trap somebody
else will walk into.

## 1. hyprexpo cannot show the real desktop behind it

The obvious thing to build on. It cannot work, for a structural reason:
hyprexpo is a render pass inside the compositor, not a client. It clears the
whole monitor to `bg_col` every frame, so a fully transparent
`bg_col = "rgba(00000000)"` still paints black — there is nothing underneath to
show through, because the pass owns the frame. And `wallpaper_bg = 1` draws
Hyprland's *built-in* wallpaper, which Omarchy does not use: Omarchy's wallpaper
is painted by a layer-surface client that a render pass cannot reach.

Owning a surface is the only way to get the real desktop behind an overview.
That is the reason this project exists.

## 2. Off-screen toplevels can be captured, live

The premise the whole design rests on, verified with a spike before anything
else was written: Hyprland renders a toplevel into an offscreen buffer on demand
for `wlr-screencopy`, so whether the window is on a visible workspace does not
matter. Thumbnails of windows on other desktops are live, not stale snapshots.

A `live: false` + `captureFrame()` one-shot was tried to cut CPU and then
reverted — one-shot capture of an *off-screen* toplevel is unverified, where
live capture of one is measured and works. Do not reintroduce it without a
window open on another workspace to test against.

## 3. Under the Lua config parser, a dispatch string is a Lua expression

Omarchy configures Hyprland with the Lua parser. In that mode an IPC dispatch
string is not `<dispatcher> <args>` — it is a Lua expression pasted inside
`hl.dispatch(...)`. So the usual `"workspace 3"` is a **syntax error**, and so is
`"focuswindow address:0x..."`. `Hyprland.usingLua` is exactly the flag for this,
so branch on it rather than hardcoding one dialect:

```qml
function dispatch(luaExpr, legacy) {
  Hyprland.dispatch(Hyprland.usingLua ? luaExpr : legacy);
}
```

Related: `hyprctl keyword` does **not** work on a Lua-parser build — it prints
`ok` and changes nothing, which is the worst kind of failure. `hyprctl eval` runs
Lua and is the working equivalent.

## 4. `HyprlandToplevel.address` is missing the `0x`

It is the bare pointer, `55c058e3d1d0`, while every dispatcher that takes an
address wants hyprctl's spelling, `0x55c058e3d1d0`. Without the prefix Hyprland
answers "window not found" and the click silently does nothing.

## 5. `reserved` is in different units from `width`/`height`

Hyprland reports a monitor's `width`/`height` in **physical** pixels but its
`reserved` area in **logical** ones — `reserved` is the strip taken out of the
workspace coordinate space, which is where window rectangles live. So monitor
size must be divided by `scale` and `reserved` must not be. Verified against the
bar, which measures 35 logical px and is reported as 35.

## 6. The exposé is a uniform shrink, not a grid

macOS scales the whole desktop by **one** factor and leaves every window where it
actually is, at its real relative size. That is what makes it read as "your
desktop, smaller" rather than "a gallery of windows". Packing windows into equal
cells blew small windows up to the size of big ones and put everything in the
wrong place.

Two details that matter as much as the scale itself:

- Scale off the monitor's **usable** area, not the whole monitor. The bar and the
  window gap mean a tiled window starts ~100px down; feeding the full monitor
  rect in scales that dead strip along with everything else and pushes the
  windows a long way below the Spaces strip.
- Anchor on the **windows' bounding box**, not on the desktop rect. That is what
  makes the gap under the Spaces strip a fixed ratio whatever the bar reserves.

Spreading overlapping windows apart, which macOS also does, is not needed:
Hyprland tiles, so windows on a workspace already do not overlap. Floating ones
can, and are left overlapping on purpose — that is where they are.

## 7. Rounded corners on arbitrary content need a mask

`clip: true` only ever cuts a square. Render the tile to a texture and mask it
with a rounded rectangle via `MultiEffect`.

## 8. The open must be two-phase, and phase two cannot be on a timer

`shown` puts the surface up with every window at its real size and position —
which is pixel-for-pixel the desktop you were already on — and `expanded` is what
shrinks them. They cannot be one flag: the windows have to be painted at full
size for at least one frame before the animation has anywhere to start from.

Starting the shrink on a fixed delay does not work either. A layer surface takes
~80ms to be mapped and composited, so a 16ms timer meant most of the 260ms
shrink ran while there was still nothing on screen, and the overview appeared
with the windows already three-quarters of the way down. Trigger on
`QsWindow.backingWindowVisible` instead — the signal that the surface is
actually composited — and keep a generous timer only as a backstop.

Corollary for testing: **`hyprctl layers` reporting a layer is not the same as
the frame being on screen.** Any latency measurement that stops at the layer
appearing is measuring something else.

## 9. A close animation needs an intent flag, not the on-screen state

Guarding the pending animation timers on "is it shown" is not enough. During the
260ms close, `shown` is still true, so a pending expand timer sets `expanded`
back to true and leaves it stuck true while hidden — after which every toggle
reads "already open", tries to close an already-closed overview, and the key
appears dead. This actually happened, and the user found it, not the tests.

Keep a separate flag for what the user last asked for (`opened` here) and guard
every asynchronous timer on that.

## 10. QtQuick `opacity` is not group opacity

Fading the QML items made the close **flicker brighter** halfway through. Measured
off a 60fps capture: mean luma ran 0.148 → 0.180 → 0.143 over ~130ms, exactly the
fade duration.

The cause is that QtQuick opacity is inherited multiplicatively by each child
rather than applied to the subtree as a group, so the dark window thumbnails
became transparent at the same rate as the bright wallpaper behind them and the
wallpaper peeked through. A parent `Item` does not help; `layer.enabled` does,
at the cost of an FBO.

The fix used here is `HyprlandWindow.opacity` — whole-surface opacity applied by
the compositor, which composites our surface first and then blends the result.

Related: the Spaces strip deliberately does **not** animate out on close. Animating
it out changed that band of screen twice in quick succession — strip slides away
uncovering our copy of the wallpaper, then the surface vanishes and the same band
changes again to the real desktop — which reads as the region being redrawn,
because it was.

## 11. `lastIpcObject` goes undefined under a live binding

Filtering it out when the model is built is not enough: the model filter runs
once, and delegate bindings re-evaluate afterwards. A toplevel Hyprland has
announced but not yet described, or one being torn down while the model still
holds it, throws `TypeError: Cannot read property '0' of undefined` on `.at[0]`
and floods the log at shell startup, when every window is announced at once.
Guard the accessors.

## 12. Gestures cannot be tested by editing the config and reloading

There is no unset/ungesture in Hyprland's Lua API (only `hl.unbind` for keys), so
a `hyprctl reload` cannot remove a gesture registered earlier in the session.
Editing and reloading therefore does not test a gesture change — log out and back
in.

Separately: if a gesture stops responding entirely, it is almost certainly *not*
a conflict with another gesture. Hyprland has a known bug where gestures stop
working and a reload does not clear them; restarting the compositor (or
`omarchy restart trackpad`) does.

**Two-finger swipes are impossible**, and not because of Hyprland: libinput only
emits SWIPE events for three or more fingers. Two fingers is always scroll or
pinch, and there is no horizontal-scroll bind to hang a workspace switch off.

## 13. Window titles are untrusted input

Every string this plugin displays about a window -- its title and its app id --
is chosen by the application itself. A web page can set its browser tab's title,
so a remote page can put arbitrary text into the overview.

A QML `Text` defaults to `textFormat: Text.AutoText`, which sniffs the string for
HTML and silently switches to rich text when it finds any -- and the rich-text
path handles resources rather than merely drawing characters. Displaying a
window title in an AutoText sink therefore lets a title act as markup.

Both defences are applied where the value enters the UI:

- **`textFormat: Text.PlainText` on every sink.** Not just the title: the
  workspace-name label takes the same treatment, because it is configuration
  text rather than markup too.
- **A length cap of 128 characters**, applied before the string reaches the
  item (`root.maxLabelLength` / `root.displayLabel`). `elide` is not a
  substitute: eliding only stops the text being *drawn*, the whole string is
  still laid out.

### The same class again, one function over: the app id

The title was not the only attacker-chosen string. A window's **app id** is also
picked by the client, and it was being used to build a `file://` URL:

```qml
const name = String((entry && entry.icon) || appId || "");   // falls back to the app id
if (name.startsWith("/")) return "file://" + name;           // ...and then opens it
```

So a local application could name itself `/anything` and have the shell open
that pathname as an image. Not merely a wrong icon: it crosses local file
boundaries, and a FIFO that never returns or an image crafted to exhaust the
decoder takes the whole long-lived shell process with it.

The fix separates the two sources rather than sanitising one string:

- **An absolute path is honoured only when it came from a desktop entry** -- a
  local file the session installed, not something a client just made up.
- **A raw app id is only ever an icon THEME name**, and only when it looks like
  one: `[A-Za-z0-9][A-Za-z0-9._+-]*`, at most 128 characters, no `..`. Anything
  else is refused outright rather than cleaned up. There is no need to salvage a
  hostile value when a generic icon is a perfectly good answer.

The general lesson, and the reason both findings landed in the same file: **ask
where each string came from, not what it looks like.** Both bugs came from
treating "the icon name" and "the window title" as data the shell owned, when
both are supplied by whatever program happens to be running.

Both found by the Omarchy marketplace security review, not by this project.

## 14. Plugin contract notes

- `close()` is what the shell calls when **it** closes the plugin. It must not
  call back into `shell.hide()`, or the two recurse until
  `RangeError: Maximum call stack size exceeded` — which leaves the overlay
  stuck on screen, because the exception aborts the close before the surface
  comes down. Use a separate `dismiss()` for closing on our own initiative
  (Escape, backdrop click, picking a window), which does both.
- The `opened` property is what the shell reads to decide what `toggle` means, so
  it has to be the intent flag from §9, not the on-screen state.
- `keepLoaded: true` is what makes the overview open instantly; see the
  Performance section of the README for the numbers it replaces.
