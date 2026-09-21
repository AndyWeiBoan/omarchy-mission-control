// Mission Control -- a macOS-style workspace overview for Omarchy.
//
// A Spaces strip of live desktop thumbnails across the top, and underneath it
// the current desktop's windows shrunk down so none overlaps, each with its app
// icon and title. Click a window to go to it, click a desktop to switch to it.
//
// The open is two-phase, and that is the whole trick behind the macOS feel: the
// surface goes up with every window drawn at its real size and position -- which
// is pixel-for-pixel the desktop you were already looking at -- and only then do
// the windows shrink into the overview. The desktop appears to shrink, rather
// than a different-looking screen fading in over it. See `shown` vs `expanded`.
//
// The thumbnails are live, not stale, even for windows on workspaces you cannot
// see: Hyprland renders a toplevel into an offscreen buffer on demand for
// screencopy, so visibility does not matter.
//
// Why this is not hyprexpo: hyprexpo does a similar job inside the compositor,
// but it is a render pass, not a client -- it clears the whole monitor to
// bg_col every frame, so a transparent bg_col still paints black and nothing
// can show through from underneath, and wallpaper_bg = 1 draws Hyprland's
// built-in wallpaper, which Omarchy does not use. Owning a surface is the only
// way to get the real desktop behind the overview. Both were measured, not
// assumed -- see docs/FINDINGS.md.
//
// This is an `overlay` plugin with keepLoaded: true, which means the shell
// mounts it at startup and it stays mounted. That matters: an earlier
// standalone version launched per keypress and took ~340ms before anything
// appeared, of which ~145ms was Qt/QML starting up and ~190ms was decoding
// Omarchy's 5120x2880 wallpaper. Neither is avoidable per launch. Mounted once
// at shell startup, a toggle shows in ~80ms.

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

Item {
  id: root

  // --- plugin contract --------------------------------------------------
  // Set by the shell's Loader when this plugin is mounted.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // What the user last asked for, as opposed to what is currently on screen.
  // The shell reads this to decide what `toggle` means, and it has to be the
  // intent rather than the state: the open and the close are both animated, so
  // mid-animation neither `shown` nor `expanded` answers "should this be open?"
  // correctly. An earlier version keyed the toggle on the on-screen state and
  // wedged -- a pending expand timer would fire during the close, leave
  // `expanded` true while hidden, and every later toggle read that as "already
  // open" and tried to close something already closed.
  property bool opened: false

  // Called by the shell on summon. The payload is accepted and ignored -- there
  // is only one thing this plugin does -- but the signature is part of the
  // contract, so keep it.
  function open(payloadJson) {
    // The background may have changed since the last open.
    root.refreshWallpaper()
    root.setShown(true)
  }

  // Called by the shell when IT closes us (`omarchy-shell shell hide <id>`).
  // Must NOT call back into shell.hide(), or the two bounce off each other.
  function close() {
    root.setShown(false)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Closing on our own initiative -- Escape, a click on the backdrop, picking a
  // window. Tells the shell as well, so its open-plugin bookkeeping does not go
  // on thinking we are up; without this the next `toggle` would try to hide an
  // already-hidden overview and appear to do nothing.
  function dismiss() {
    root.setShown(false)
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.andyweiboan.missioncontrol")
  }

  // --- appearance ---------------------------------------------------------
  // The labels follow the shell's menu font, so this matches the rest of
  // Omarchy and honours OMARCHY_MENU_FONT. Note it must be an explicit family:
  // the fontconfig alias `sans` resolves to whatever the user has installed,
  // which on a developer box is often a monospace whose digits look wrong once
  // they are scaled up to strip-label size.
  readonly property string fontFamily: Style.font.menuFamily

  // Omarchy keeps the active wallpaper behind a stable symlink, which is also
  // where its own background plugin reads it from. Following the link rather
  // than the theme directory means a theme switch is picked up with no reload.
  // The wallpaper is loaded through Omarchy's state symlink -- a fixed
  // pathname, and the ONLY one this plugin ever hands to an image loader. What
  // changes is a cache token appended as a query, because the link's path is
  // stable while its target moves (on a theme switch, and on a background
  // switch within a theme) and QtQuick caches images by URL. Qt strips a query
  // before opening a local file but keeps it in the cache key.
  //
  // 1.0.1 resolved the link and used the RESOLVED PATH as the source. That was
  // a regression on 1.0.0, which only ever used the fixed link: a pathname
  // something else controls should not reach an image loader, and bounding the
  // string does not bound what it points at -- the same mistake as the icon
  // lookup in section 13. Found in review of the sibling Launchpad plugin,
  // where the identical code had been copied.
  readonly property string wallpaperLink:
      Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property string wallpaperToken: ""
  readonly property string wallpaperSource:
      "file://" + root.wallpaperLink
      + (root.wallpaperToken.length > 0
         ? "?v=" + encodeURIComponent(root.wallpaperToken) : "")

  readonly property string pluginDir:
      Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  function refreshWallpaper() {
    if (!wallpaperProbe.running) {
      wallpaperProbe.running = true
      probeWatchdog.restart()
    }
  }

  Process {
    id: wallpaperProbe
    // Absolute interpreter and a minimal environment: a bare command name is
    // resolved through whatever PATH this process inherited, so a shadowed
    // executable would be run automatically by a plugin mounted for the whole
    // session.
    command: ["/bin/sh", root.pluginDir + "/bin/wallpaper-token"]
    clearEnvironment: true
    environment: ({ "HOME": Quickshell.env("HOME") })
    stdout: StdioCollector {
      onStreamFinished: root.wallpaperToken = String(text || "").trim().slice(0, 128)
    }
  }

  // A deadline. Nothing that runs automatically in a long-lived process should
  // be able to hang without one, however small it is.
  Timer {
    id: probeWatchdog
    interval: 2000
    onTriggered: if (wallpaperProbe.running) wallpaperProbe.running = false
  }

  Timer {
    running: true
    interval: 400
    onTriggered: root.refreshWallpaper()
  }

  // --- state machine ------------------------------------------------------

  // Surface up, with every window still drawn at its real size and position.
  property bool shown: false

  // Second phase: what actually shrinks the windows into the overview. This
  // cannot be folded into `shown`, because the windows have to be painted at
  // full size for at least one frame before the animation has anywhere to
  // start from.
  property bool expanded: false

  // Our last frame and the real desktop are not identical -- we draw a slight
  // dim and our captures exclude hyprbars' title bars -- so cutting the surface
  // away the instant the windows are home is a visible pop. Dissolving the last
  // stretch hides the difference: the real desktop is directly behind a
  // transparent window, so fading our content out *is* a crossfade to it.
  property bool contentVisible: false

  // The fade is applied to the whole SURFACE, by the compositor, not to the QML
  // items -- because QtQuick opacity is inherited multiplicatively by each
  // child rather than applied to the subtree as a group. Fading the items
  // individually made the dark window thumbnails become transparent at the same
  // rate as the bright wallpaper behind them, so the wallpaper peeked through
  // and the screen got BRIGHTER halfway through a fade to nothing.
  //
  // Measured off a 60fps capture of the close: mean luma ran
  // 0.148 -> 0.180 -> 0.143 over ~130ms, exactly the fade duration. That bump
  // was the flash. Compositor-side opacity composites our surface first and
  // then blends the result, which is what we actually meant.
  property real contentOpacity: root.contentVisible ? 1 : 0
  Behavior on contentOpacity {
    NumberAnimation { duration: root.fadeDuration; easing.type: Easing.InOutQuad }
  }

  // The Spaces strip comes down on open and goes back up on close, following
  // `expanded` in both directions.
  //
  // It used to stay put and leave only by being dissolved with everything else,
  // because animating it out was a flicker: that band of screen changed twice
  // in quick succession -- first the strip slid away and uncovered our copy of
  // the wallpaper, then the surface vanished and the same band changed again to
  // the real desktop and bar. Two transitions in one place read as the region
  // being redrawn, which is what it was.
  //
  // WATCH FOR THAT COMING BACK. The exit runs 0-260ms while the crossfade runs
  // 200-330ms, so there is a stretch where the strip has left and the band is
  // showing nothing but our wallpaper copy. If it flickers again the fix is not
  // to abandon the motion but to start it with the fade instead of with the
  // shrink, so the band only changes once -- the strip lifting away while
  // everything dissolves around it.
  property bool stripDeployed: false
  onExpandedChanged: root.stripDeployed = root.expanded
  // Belt and braces: if anything leaves this set while the surface goes, the
  // next open still starts from above the screen edge.
  onShownChanged: if (!root.shown) root.stripDeployed = false

  // --- hyprbars ------------------------------------------------------------
  // A screencopy of a toplevel is the CLIENT surface, and hyprbars' title bar
  // is a compositor-side decoration -- so every thumbnail here arrived without
  // one. That is not just a missing detail in the overview: it is the flash on
  // the way out. Our last frame has no title bars, the real desktop does, so
  // the moment the surface is dropped a bar appears on every window at once.
  //
  // Drawn rather than captured, then, and from the same numbers Hyprland is
  // using. The height is asked for once at load; the colour is the theme's
  // `background`, which is literally what hyprbars.lua sets bar_color to, so
  // it follows a theme change for free.
  //
  // Zero when hyprbars is not installed, which is also the right answer: the
  // probe fails, nothing is drawn, and the geometry below collapses to what it
  // was before.
  property int hyprbarsHeight: 0

  // --- the rest of what a window looks like ---------------------------------
  // The border was the other half of the flash, and the bigger half by the
  // numbers. Comparing our last frame against the real desktop, region by
  // region: the strip of screen where a window's left border runs measured 74.3
  // on the real desktop and 31.6 in ours. Hyprland draws a 2px accent border
  // around every window and a screencopy of the client surface contains no such
  // thing, so at the moment the surface was dropped a bright outline appeared
  // around every window at once.
  //
  // Read rather than assumed, because all four of these are things the user
  // changes: the active colour happens to be the theme's accent today, but
  // saying so in code would make this wrong the moment it is not.
  property int hyprBorderSize: 0
  property int hyprRounding: 0
  property color hyprActiveBorder: Color.accent
  property color hyprInactiveBorder: Qt.rgba(0.35, 0.35, 0.35, 0.67)

  // A gradient reads back as "aarrggbb <angle>deg"; we want the first stop.
  function firstGradientStop(text, fallback) {
    const m = String(text || "").match(/([0-9a-fA-F]{8})/);
    if (!m)
      return fallback;
    const v = parseInt(m[1], 16);
    return Qt.rgba(((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255,
                   (v & 255) / 255, ((v >> 24) & 255) / 255);
  }

  Process {
    id: hyprLookProbe
    running: true
    // One process for the lot. Each getoption answers with its own JSON object,
    // so the reply is a stream of them rather than an array.
    command: ["hyprctl", "-j", "--batch",
              "getoption plugin:hyprbars:bar_height;"
              + "getoption general:border_size;"
              + "getoption decoration:rounding;"
              + "getoption general:col.active_border;"
              + "getoption general:col.inactive_border"]
    stdout: StdioCollector {
      onStreamFinished: {
        const seen = {};
        const re = /\{[^{}]*\}/g;
        let m;
        while ((m = re.exec(text)) !== null) {
          try {
            const o = JSON.parse(m[0]);
            if (o && o.option)
              seen[o.option] = o;
          } catch (e) { }
        }
        function intOf(key, max) {
          const o = seen[key];
          // `set` is false when Hyprland is echoing a default back at us, which
          // is how an absent hyprbars announces itself.
          return (o && o.set && o.int > 0) ? Math.min(max, o.int) : 0;
        }
        root.hyprbarsHeight = intOf("plugin:hyprbars:bar_height", 200);
        root.hyprBorderSize = intOf("general:border_size", 20);
        root.hyprRounding = intOf("decoration:rounding", 60);
        if (seen["general:col.active_border"])
          root.hyprActiveBorder = root.firstGradientStop(
              seen["general:col.active_border"].gradient, root.hyprActiveBorder);
        if (seen["general:col.inactive_border"])
          root.hyprInactiveBorder = root.firstGradientStop(
              seen["general:col.inactive_border"].gradient, root.hyprInactiveBorder);
      }
    }
  }

  // --- shared motion vocabulary ---------------------------------------------
  // These numbers are not this plugin's own. They are the same ones the
  // Launchpad overlay uses, so the two read as parts of one desktop rather than
  // as two things that happen to sit on the same screen. Three rules, and the
  // durations fall out of them:
  //
  //   Arriving takes longer than leaving.  320 in, 240 out. Something coming
  //   towards you is worth watching; something going away has already said what
  //   it had to say.
  //
  //   The atmosphere outlives the content.  Launchpad's blur runs 380/340
  //   against its grid's 320/240, and the crossfade here is the same idea: it
  //   starts before the windows are home and finishes after them, so the last
  //   thing on screen is a dissolve rather than a cut.
  //
  //   Translations accelerate away; fades taper.  A thing sliding off should
  //   look like it is leaving. A thing dissolving should not -- Launchpad's exit
  //   fade was on an accelerating curve once, which puts most of the alpha in
  //   the last few frames and reads as a flash rather than a fade.
  //
  // Anything retimed here should be retimed there, and the other way round.
  readonly property int openDuration: 320
  readonly property int closeDuration: 240

  // The strip is given LESS time than the windows, deliberately, and this took
  // three wrong guesses to land on.
  //
  // Both ran for the same 260ms to begin with, and measurement said they were
  // simultaneous: start and finish within 3ms of each other, every time. It
  // still looked as though the strip arrived late, because identical curves on
  // different objects do not read as identical motion. The windows are
  // shrinking from the whole screen to a thumbnail, so their last eighth is a
  // nudge of something already small and the eye calls it arrived at about
  // 60% of the way through. The strip is a solid 146px band travelling in a
  // straight line, and its last eighth is eighteen pixels that are plainly
  // still moving.
  //
  // Sharpening the curve made it worse, not better. OutQuint covers 76% of the
  // distance in the first quarter and then creeps the rest over the remaining
  // three quarters -- and a slow persistent drift is MORE visible than a
  // quicker one, not less. The answer was not a different shape but less time:
  // the strip is simply finished, tail and all, by the point the windows look
  // settled.
  // The strip gets about two thirds of the windows' time, in both directions.
  // Not because it is less important but because it is a different object: see
  // the note on its Behavior for why an identical duration did not read as
  // simultaneous.
  readonly property int stripOpenDuration: 200
  readonly property int stripCloseDuration: 150

  // The crossfade to the real desktop. It begins 60ms before the windows are
  // home and runs past them, which is the "atmosphere outlives the content"
  // rule above.
  readonly property int fadeDuration: 160

  // Everything the open does once the desktop underneath is settled. Split out
  // of setShown because a flattened workspace reaches it one timer later.

  function setShown(next) {
    root.opened = next;
    if (next) {
      // Pressed again mid-close: the surface is still up, so just re-expand
      // rather than falling through the "already shown" guard and doing
      // nothing while it finishes collapsing.
      collapseThenHide.stop();
      fadeOutSoon.stop();
      root.contentVisible = true;
      if (root.shown) {
        root.expanded = true;
        return;
      }
    } else if (!root.shown) {
      // Already hidden. Still clear `expanded`, so that a state left
      // inconsistent by anything at all heals on the next close rather than
      // wedging the toggle.
      root.expanded = false;
      return;
    }
    if (next) {
      // This plugin stays mounted, possibly idle for hours. Hyprland's model is
      // event-driven, but a window that was moved or resized while we held no
      // interest in it can leave lastIpcObject stale -- and every thumbnail's
      // position and size is computed from that, so a stale rect puts windows
      // in visibly wrong places. Ask for the current state before showing.
      //
      // Three round trips on the Hyprland socket, all before the first frame.
      // Cheap enough to keep in the critical path, and the alternative --
      // showing first and correcting after -- would move windows under the
      // pointer.
      Hyprland.refreshMonitors();
      Hyprland.refreshWorkspaces();
      Hyprland.refreshToplevels();
      root.contentVisible = true;
      root.shown = true;
      // The shrink is started by the window itself, once its surface is
      // actually up -- see onBackingWindowVisibleChanged below. This is only a
      // backstop so the overview can never sit there showing full-size windows
      // if that signal does not arrive.
      expandFallback.start();
    } else {
      // Reverse of the open: shrink back out to the real desktop, then drop the
      // surface once the windows are home. Dropping it first would cut the
      // animation off and read as a flicker.
      root.expanded = false;
      expandFallback.stop();
      fadeOutSoon.restart();
      collapseThenHide.restart();
    }
  }

  // Dispatch syntax depends on which parser Hyprland was configured with, and
  // getting it wrong fails at the far end where nothing here would notice.
  // Omarchy uses the Lua config, and in Lua mode the string is not a dispatcher
  // name and its arguments -- it is a Lua expression pasted into
  // `hl.dispatch(...)`. So the usual "workspace 3" is a syntax error, and
  // "focuswindow address:0x..." is too. Hyprland.usingLua is exactly the flag
  // for this, so branch on it rather than hardcoding one dialect.
  //
  // (`hl.dsp.workspace` exists but is a table of workspace *management* verbs --
  // rename, move to monitor, toggle_special. Merely going to one is a focus.)
  function dispatch(luaExpr, legacy) {
    Hyprland.dispatch(Hyprland.usingLua ? luaExpr : legacy);
  }

  // Everything interpolated into a dispatch is checked for SHAPE first.
  //
  // Under the Lua parser a dispatch string is not a command with arguments, it
  // is an expression the compositor evaluates -- so a value carrying a quote
  // would close the string literal it was pasted into and the rest would run as
  // Lua. These particular values arrive from Hyprland's own IPC rather than
  // from a client, so this is not a live hole; it is refusing to have one. The
  // cost is two regular expressions, and the alternative is trusting that the
  // provenance of every field stays what it is today.
  //
  // Refuse rather than escape. A workspace id that is not a number and an
  // address that is not hex are not values worth salvaging.
  function safeWorkspaceId(value) {
    const text = String(value);
    return /^-?[0-9]{1,10}$/.test(text) ? text : "";
  }

  function safeAddress(value) {
    const text = String(value || "");
    const bare = text.startsWith("0x") ? text.slice(2) : text;
    return /^[0-9a-fA-F]{1,16}$/.test(bare) ? "0x" + bare : "";
  }

  // Switching and closing are one action, but the dispatch travels over a
  // socket -- hiding in the same tick can cut it off, so give it a frame.
  function goToWorkspace(id) {
    const target = root.safeWorkspaceId(id);
    if (target === "")
      return;
    root.dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })", "workspace " + target);
    hideSoon.start();
  }

  // HyprlandToplevel.address is the bare pointer -- "55c058e3d1d0" -- while
  // every dispatcher that takes one wants hyprctl's spelling, "0x55c058e3d1d0".
  // Without the prefix Hyprland answers "window not found" and the click simply
  // does nothing, so normalise here rather than at each call site.
  function focusWindow(address) {
    const addr = root.safeAddress(address);
    if (addr === "")
      return;
    root.dispatch("hl.dsp.focus({ window = \"address:" + addr + "\" })",
                  "focuswindow address:" + addr);
    hideSoon.start();
  }

  // Backstop only. The real trigger is the surface becoming visible; a fixed
  // delay cannot do the job, because the layer surface takes ~80ms to be mapped
  // and composited. Expanding on a 16ms timer meant most of the 260ms shrink
  // ran while there was still nothing on screen, and the overview appeared with
  // the windows already three-quarters of the way down -- which throws away the
  // entire point of animating from the real desktop.
  Timer {
    id: expandFallback
    interval: 400
    onTriggered: if (root.opened) root.expanded = true
  }

  // Start dissolving just before the windows finish returning, so the fade is
  // over the tail of the movement rather than after it.
  Timer {
    id: fadeOutSoon
    interval: Math.max(0, root.closeDuration - 60)
    onTriggered: if (!root.opened) root.contentVisible = false
  }

  Timer {
    id: collapseThenHide
    onTriggered: if (!root.opened) root.shown = false
    interval: root.closeDuration - 60 + root.fadeDuration
  }

  Timer {
    id: hideSoon
    interval: 80
    onTriggered: root.dismiss()
  }

  // Window titles and app ids are chosen by the application itself, and a web
  // page can set its browser tab's title, so every one of these strings is
  // attacker-influenced by the time it reaches us. Two defences, both applied
  // at the point of display:
  //
  // 1. `textFormat: Text.PlainText` on every sink that shows one. A QML Text
  //    defaults to Text.AutoText, which sniffs the string for HTML and switches
  //    to rich text when it finds any -- and rich text follows markup into
  //    resource handling. A title is data, never markup.
  // 2. A documented length cap, applied here rather than relying on elide.
  //    Eliding only stops it being *drawn*; the whole string is still laid out.
  readonly property int maxLabelLength: 128

  function displayLabel(value) {
    const text = String(value || "");
    return text.length > root.maxLabelLength
      ? text.slice(0, root.maxLabelLength) + "\u2026"
      : text;
  }

  // Icon for a window, looked up from its app id. heuristicLookup copes with
  // the usual mismatches between a Wayland app id and a .desktop file name.
  // A Wayland client chooses its own app id, so this string is attacker-chosen
  // text arriving in a long-lived shell process. Two rules follow from that:
  //
  //   1. An absolute path is honoured ONLY when it came out of a desktop entry
  //      -- a local file the session installed. An earlier version fell back to
  //      the app id for the icon name and then turned any leading "/" into a
  //      file:// URL, which let a client point the shell at any pathname it
  //      liked and have it opened as an image: across local file boundaries, at
  //      a FIFO that never returns, or at something crafted to exhaust the
  //      decoder. The process holding that image is the whole shell.
  //   2. A raw app id is only ever used as an icon THEME name, and only when it
  //      looks like one. A slash, a colon, a leading dot, "..", or an
  //      unreasonable length means it is not a theme name, so it is refused
  //      rather than sanitised -- there is no need to salvage a hostile value
  //      when a generic icon is a perfectly good answer.
  //
  // Reported by the Omarchy marketplace security review.
  readonly property int maxIconNameLength: 128
  readonly property int maxIconPathLength: 512

  function looksLikeIconName(value) {
    return value.length > 0
        && value.length <= root.maxIconNameLength
        && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(value)
        && value.indexOf("..") === -1;
  }

  function iconFor(appId) {
    const fallback = Quickshell.iconPath("application-x-executable", true);
    // Bounded before it is used for anything at all, lookup included.
    const id = String(appId || "").slice(0, root.maxIconNameLength);
    if (id.length === 0)
      return fallback;

    const entry = DesktopEntries.heuristicLookup(id);
    const fromEntry = String((entry && entry.icon) || "");
    if (fromEntry.length > 0 && fromEntry.length <= root.maxIconPathLength) {
      if (fromEntry.startsWith("/") && fromEntry.indexOf("..") === -1)
        return "file://" + fromEntry;
      if (root.looksLikeIconName(fromEntry)) {
        const themed = Quickshell.iconPath(fromEntry, true);
        if (themed.length > 0)
          return themed;
      }
    }

    // No entry, or nothing usable in it. The app id is all that is left, and it
    // is untrusted: theme name only, never a path.
    if (!root.looksLikeIconName(id))
      return fallback;
    const guess = Quickshell.iconPath(id, true);
    return guess.length > 0 ? guess : fallback;
  }

  Variants {
    // Skip Quickshell's placeholder screen. When the only output drops its
    // link (an OLED waking from DPMS re-handshakes DisplayPort), Quickshell
    // hands out a nameless placeholder for a beat. Building a panel for it
    // would instantiate every thumbnail below against windows that have no
    // monitor, and Hyprland 0.56 crashes on that capture request.
    model: Quickshell.screens.filter(s => s && s.name !== "")

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"


      // Hiding tears down the layer surface but keeps the QML tree and, more to
      // the point, the decoded wallpaper -- which is the 190ms.
      visible: root.shown

      // Whole-surface opacity, handed to Hyprland. See contentOpacity.
      HyprlandWindow.opacity: root.contentOpacity

      // `visible` is our intent; `backingWindowVisible` is the surface actually
      // being up, which is what the shrink has to start from. One more frame
      // after that, so the full-size state -- indistinguishable from the real
      // desktop -- is painted at least once and the animation has somewhere to
      // come from.
      onBackingWindowVisibleChanged: {
        if (backingWindowVisible && root.opened)
          firstFrame.start();
        else
          firstFrame.stop();
      }

      Timer {
        id: firstFrame
        interval: 16
        onTriggered: if (root.opened) root.expanded = true
      }

      // Overlay so it covers the bar and the dock too; exclusive keyboard focus
      // so the arrow keys work without a click first.
      WlrLayershell.namespace: "mission-control"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      // --- which monitor are we on -----------------------------------------
      // Window positions come out of Hyprland in global logical coordinates, so
      // mapping them into a thumbnail needs this monitor's logical origin and
      // size. HyprlandMonitor.width/height are *physical* pixels; divide by
      // scale to get the logical box the client rectangles live in.
      readonly property var hyprMonitor: {
        const mons = Hyprland.monitors.values || [];
        for (let i = 0; i < mons.length; i++)
          if (String(mons[i].name) === String(panel.screen.name))
            return mons[i];
        return null;
      }
      readonly property real monX: hyprMonitor ? hyprMonitor.x : 0
      readonly property real monY: hyprMonitor ? hyprMonitor.y : 0
      readonly property real monW: hyprMonitor ? hyprMonitor.width / hyprMonitor.scale : panel.screenW
      readonly property real monH: hyprMonitor ? hyprMonitor.height / hyprMonitor.scale : panel.screenH

      // --- which desktops ---------------------------------------------------
      // Only this monitor's workspaces, and only real ones: the scratchpad and
      // other special workspaces have negative ids and are not desktops.
      // Workspaces 1-N exist at all times because looknfeel.lua pins them
      // persistent -- without that Hyprland would only create them on demand
      // and the strip would have holes that appear and vanish.
      readonly property var desktops: {
        const out = [];
        const all = Hyprland.workspaces.values || [];
        for (let i = 0; i < all.length; i++) {
          const ws = all[i];
          if (ws.id < 0)
            continue;
          if (panel.hyprMonitor && ws.monitor && ws.monitor.id !== panel.hyprMonitor.id)
            continue;
          out.push(ws);
        }
        out.sort((a, b) => a.id - b.id);
        return out;
      }

      readonly property var currentDesktop: {
        for (let i = 0; i < panel.desktops.length; i++)
          if (panel.desktops[i].focused)
            return panel.desktops[i];
        return panel.desktops.length > 0 ? panel.desktops[0] : null;
      }

      // Windows of the current desktop, most recently used first --
      // focusHistoryID counts up from the window you were last in, so ascending
      // order puts the one you are coming back to in the top-left.
      readonly property var windows: {
        const out = [];
        if (!panel.currentDesktop)
          return out;
        const tls = panel.currentDesktop.toplevels ? (panel.currentDesktop.toplevels.values || []) : [];
        for (let i = 0; i < tls.length; i++) {
          const t = tls[i];
          const o = t.lastIpcObject;
          if (!t.wayland || !o || o.mapped === false || o.hidden === true)
            continue;
          out.push(t);
        }
        out.sort((a, b) => (a.lastIpcObject.focusHistoryID || 0) - (b.lastIpcObject.focusHistoryID || 0));
        return out;
      }

      // --- geometry ---------------------------------------------------------
      // Proportions taken off a real Mission Control screenshot: the Spaces
      // strip is about a sixth of the screen, and the thumbnails in it about
      // two thirds of the strip, leaving room for a label underneath.
      // Geometry comes from the SCREEN, not from the window.
      //
      // An unmapped PanelWindow is not the size of its screen: it collapses to
      // Qt's 100x100 default while hidden and reports 0x0 at the instant it
      // maps. Everything below used to be derived from panel.width/height, so
      // every dimension changed twice per open -- and stripH is one of them.
      //
      // That broke the entrance, not just the numbers. The strip's resting
      // place is `-stripH`, so as stripH went 16 -> 0 -> 146 the strip's target
      // moved three times before the overview even opened, each move starting
      // its Behavior. By the time `expanded` flipped 34ms later the strip was
      // not parked above the screen at all: it was somewhere in mid-flight, at
      // a different place every time. It then slid to 0 from wherever that was,
      // which is why it never matched the windows shrinking beside it.
      // Measured, three opens in a row, before this was changed.
      //
      // The screen does not resize when our window is hidden.
      readonly property real screenW: panel.modelData ? panel.modelData.width : panel.width
      readonly property real screenH: panel.modelData ? panel.modelData.height : panel.height

      readonly property real uiScale: panel.screenW / 1920
      readonly property real stripH: Math.round(panel.screenH * 0.155)
      readonly property real stripPad: Math.round(12 * uiScale)
      readonly property real stripGap: Math.round(22 * uiScale)
      readonly property int stripLabelSize: Math.max(9, Math.round(15 * uiScale))
      readonly property real stripLabelBand: Math.round(stripLabelSize * 1.9)

      // Thumbnails keep the screen's aspect ratio, so each is a faithful
      // miniature. Fit to whichever axis runs out first -- with a dozen
      // desktops it is the width, with two it is the strip height.
      readonly property int deskCount: Math.max(1, panel.desktops.length)
      readonly property real stripTileH: Math.min(
          stripH - stripLabelBand - stripPad * 2,
          ((panel.screenW * 0.92) - (deskCount - 1) * stripGap) / deskCount * (panel.screenH / panel.screenW))
      readonly property real stripTileW: stripTileH * panel.screenW / panel.screenH

      // The exposé is NOT a grid of equal cells. macOS shrinks the whole
      // desktop by one factor and leaves every window where it actually is, at
      // its real relative size -- that is what makes it read as "your desktop,
      // smaller" instead of "a gallery of windows". Packing windows into equal
      // cells blew small windows up to the size of big ones and put everything
      // in the wrong place.
      //
      // Spreading overlapping windows apart, which macOS also does, is not
      // needed here: Hyprland tiles, so the windows on a workspace already do
      // not overlap. Floating ones can, and are left overlapping on purpose --
      // that is where they are.
      //
      // The margins are measured off a real Mission Control screenshot: a gap
      // under the Spaces strip of ~5.8% of the screen, ~10% left at the bottom
      // (macOS keeps the dock clear down there, and so do we), and a hair of
      // side padding. On a 16:10 screen that lands the scale near 0.68.
      readonly property real exposeGapTop: Math.round(panel.screenH * 0.058)
      readonly property real exposeGapBottom: Math.round(panel.screenH * 0.10)
      readonly property real exposeGapSide: Math.round(panel.screenW * 0.015)
      readonly property real exposeAreaX: exposeGapSide
      readonly property real exposeAreaY: stripH + exposeGapTop
      readonly property real exposeAreaW: panel.screenW - exposeGapSide * 2
      readonly property real exposeAreaH: panel.screenH - exposeAreaY - exposeGapBottom

      // Scale off the monitor's *usable* area, not the whole monitor. The bar
      // and the window gap mean a tiled window starts ~100px down; feeding the
      // full monitor rect in scaled that dead strip along with everything else
      // and pushed the windows a long way below the Spaces strip.
      // Careful: hyprctl reports a monitor's width/height in PHYSICAL pixels but
      // its reserved area in LOGICAL ones (it is the strip taken out of the
      // workspace coordinate space, which is where window rectangles live).
      // Verified against the bar, which measures 35 logical px and is reported
      // as 35. So this one is not divided by scale, unlike monW/monH above.
      readonly property var reserved: {
        const o = panel.hyprMonitor ? panel.hyprMonitor.lastIpcObject : null;
        return o && o.reserved ? o.reserved : [0, 0, 0, 0];
      }
      readonly property real usableW: Math.max(1, panel.monW - reserved[0] - reserved[2])
      readonly property real usableH: Math.max(1, panel.monH - reserved[1] - reserved[3])

      // The one scale every window shares.
      readonly property real shrink: Math.min(exposeAreaW / usableW, exposeAreaH / usableH)

      // Where the scaled desktop is pinned. Anchoring on the *windows* rather
      // than on the desktop rect is what makes the gap under the Spaces strip a
      // fixed ratio: whatever the bar reserves, the topmost window always lands
      // exposeGapTop below the strip. Horizontally the block is centred.
      readonly property var bbox: {
        const ws = panel.windows;
        if (ws.length === 0)
          return null;
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (let i = 0; i < ws.length; i++) {
          const o = ws[i].lastIpcObject;
          // Same live-binding hazard as the delegates: skip rather than throw.
          if (!o || !o.at || !o.size)
            continue;
          x0 = Math.min(x0, o.at[0]);
          // The bar sits directly above the client area, so the top of a window
          // is that much higher than Hyprland's `at`. Without this the block is
          // anchored on the client tops and every bar hangs above the gap the
          // layout reserved.
          y0 = Math.min(y0, o.at[1] - root.hyprbarsHeight);
          x1 = Math.max(x1, o.at[0] + o.size[0]);
          y1 = Math.max(y1, o.at[1] + o.size[1]);
        }
        return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
      }
      readonly property real originX: bbox
          ? exposeAreaX + (exposeAreaW - bbox.w * shrink) / 2 - (bbox.x - panel.monX) * shrink
          : exposeAreaX
      readonly property real originY: bbox
          ? exposeAreaY - (bbox.y - panel.monY) * shrink
          : exposeAreaY

      // Icon and title sizes come off the screen, not off the window, so every
      // label in the view is the same size -- measured at ~2.3% and ~0.85% of
      // the screen width in the macOS shot.
      readonly property int iconSize: Math.max(18, Math.round(panel.screenW * 0.023))
      readonly property int titleSize: Math.max(10, Math.round(panel.screenW * 0.0085))

      // --- selection --------------------------------------------------------
      // Index into panel.windows; -1 when the desktop is empty.
      property int selected: panel.windows.length > 0 ? 0 : -1

      // Windows sit wherever they sit, so arrow keys pick the nearest one in
      // that direction rather than stepping through a grid. Distance is
      // weighted so a window that is roughly in line wins over one that is
      // nearer but far off to the side.
      function centreOf(t) {
        const o = t.lastIpcObject;
        if (!o || !o.at || !o.size)
          return { x: 0, y: 0 };
        return { x: o.at[0] + o.size[0] / 2, y: o.at[1] + o.size[1] / 2 };
      }

      function move(dx, dy) {
        const n = panel.windows.length;
        if (n === 0)
          return;
        if (panel.selected < 0 || panel.selected >= n) {
          panel.selected = 0;
          return;
        }
        const from = panel.centreOf(panel.windows[panel.selected]);
        let best = -1;
        let bestCost = Infinity;
        for (let i = 0; i < n; i++) {
          if (i === panel.selected)
            continue;
          const to = panel.centreOf(panel.windows[i]);
          const along = (to.x - from.x) * dx + (to.y - from.y) * dy;
          if (along <= 0)
            continue;
          const across = Math.abs((to.x - from.x) * dy) + Math.abs((to.y - from.y) * dx);
          const cost = along + across * 2;
          if (cost < bestCost) {
            bestCost = cost;
            best = i;
          }
        }
        // Nothing that way: stay put rather than jumping to the far side.
        if (best >= 0)
          panel.selected = best;
      }

      // --- background -------------------------------------------------------
      // The wallpaper, blurred here in QML, with a dark tint over it.
      //
      // Sharp, not blurred. macOS does not blur the desktop in Mission Control
      // -- it shows the real wallpaper and shrinks the windows down onto it,
      // and only the Spaces strip along the top is a frosted band. An earlier
      // version blurred the whole screen, which was this project's own
      // invention rather than the thing it was copying.
      //
      // Nothing here is a compositor blur either, and nothing should become
      // one: a `blur = true` layer rule on a full-screen layer -- and equally
      // Quickshell's BackgroundEffect, which asks the compositor for the same
      // thing -- makes hyprbars' title bars flicker between transparent and
      // coloured every time they redraw, and
      // decoration:blur:new_optimizations = false does not stop it.
      // --- the bar's band is left alone -----------------------------------
      // Nothing of ours is drawn in the strip of screen the bar reserved, so
      // the real bar shows through: this is an Overlay layer and the bar is a
      // Top one, and transparent pixels here composite onto it.
      //
      // That band was the last real discrepancy between our final frame and the
      // desktop behind it -- measured at 32.1 on the real screen against 82.1
      // in ours, the single biggest thing left. Painting a rectangle the bar's
      // colour got it to within 4. Painting nothing gets it to nothing, and
      // keeps the clock running while the overview is up.
      //
      // The cost is the layout: the Spaces strip can no longer sit over the
      // bar, because the strip is barely opaque -- 7% white over our wallpaper
      // copy -- and with no copy underneath, the bar's own icons would show
      // through the desktop thumbnails. So the strip goes below the bar, which
      // is where macOS puts it anyway; it does not hide the menu bar either.
      readonly property real barBand: panel.reserved[1]

      // Both pieces below draw the SAME full-panel wallpaper and clip to their
      // own band, rather than each being fitted to its own height. Fitting them
      // separately means two different PreserveAspectCrop results and a seam
      // along the join -- which the Spaces strip does not hide, because the
      // strip is only 7% white.
      Item {
        id: backdrop
        y: panel.barBand
        width: parent.width
        height: parent.height - panel.barBand
        clip: true

      Image {
        id: wallpaper
        y: -panel.barBand
        width: parent.width
        height: panel.height
        source: root.wallpaperSource
        fillMode: Image.PreserveAspectCrop
        // Do NOT add sourceSize here. Omarchy's wallpapers are 5K and the
        // obvious "decode it smaller" made the window *slower* to appear --
        // 505ms against 341ms -- because Qt still parses the whole JPEG and
        // then does a smooth scale on top. Matching the size on the strip
        // thumbnails so they share one cache entry did not recover it either
        // (496ms). Measured, twice.
        // Asynchronous. The helper checks the target is a bounded regular file
        // but cannot hold it -- the link can be replaced between that check and
        // this load -- so decoding off the main thread bounds the consequence
        // rather than the input: a late background instead of a shell that
        // renders and stops answering.
        asynchronous: true
        cache: true
      }

      // A whisper of dim, so the shrunken windows have something to sit
      // against. Not the heavy scrim the blurred version needed.
      Rectangle {
        y: -panel.barBand
        width: parent.width
        height: panel.height
        color: "#0b0d14"
        opacity: 0.14
      }
      }

      // --- the bar's band ---------------------------------------------------
      // Transparent to begin with, so the real bar is simply there -- widgets,
      // running clock and all -- and then covered as the Spaces strip comes
      // down, on the strip's own timing. The bar does not slide out of the way
      // and it is not hidden: it dissolves under what is arriving, and on the
      // way out it comes back the same way.
      //
      // This is also what turns the last discontinuity into a fade. Our final
      // frame used to differ from the real desktop by 50 luma in this band --
      // the biggest thing left by a distance -- because we painted bright
      // wallpaper where the desktop has a dark bar. Now they are the same
      // pixels, crossfading.
      Item {
        id: barCover
        width: parent.width
        height: panel.barBand
        clip: true
        opacity: root.stripDeployed ? 1 : 0
        // A fade, so it tapers in both directions -- see the vocabulary note.
        Behavior on opacity {
          NumberAnimation {
            duration: root.stripDeployed ? root.stripOpenDuration
                                         : root.stripCloseDuration
            easing.type: Easing.OutCubic
          }
        }

        Image {
          width: parent.width
          height: panel.height
          source: root.wallpaperSource
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
        }
        Rectangle {
          width: parent.width
          height: panel.height
          color: "#0b0d14"
          opacity: 0.14
        }
      }

      // Click anywhere that is not a window or a desktop to dismiss. A
      // TapHandler, not a MouseArea: a MouseArea grabs the press outright and
      // any handler on a sibling never sees the gesture.
      TapHandler {
        onTapped: root.dismiss()
      }

      Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: root.dismiss()
        // Left/right walk the Spaces strip and actually switch desktop, without
        // closing -- the exposé below follows, so you can flick through the
        // desktops and only then pick a window. Up/down move between the
        // windows of whichever desktop you landed on.
        Keys.onLeftPressed: panel.stepDesktop(-1)
        Keys.onRightPressed: panel.stepDesktop(1)
        Keys.onUpPressed: panel.move(0, -1)
        Keys.onDownPressed: panel.move(0, 1)
        Keys.onTabPressed: panel.cycleWindow()
        Keys.onReturnPressed: panel.activateSelection()
        Keys.onEnterPressed: panel.activateSelection()

        // Keys.onPressed runs before the named handlers above, so this is where
        // anything that has to win over plain arrow navigation goes.
        Keys.onPressed: event => {
          // CTRL+DOWN closes, mirroring the CTRL+UP that opened it. There is a
          // Hyprland bind for this too -- a modifier pressed on a virtual
          // keyboard does not reliably reach a client through an
          // exclusive-focus layer, so the compositor bind is the one that is
          // guaranteed to fire and this is the belt to its braces.
          if ((event.modifiers & Qt.ControlModifier)
              && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
            root.dismiss();
            event.accepted = true;
            return;
          }
          // Number keys jump straight to a desktop, like SUPER+n does normally.
          if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            const want = event.key - Qt.Key_0;
            for (let i = 0; i < panel.desktops.length; i++) {
              if (panel.desktops[i].id === want) {
                root.goToWorkspace(want);
                event.accepted = true;
                return;
              }
            }
          }
        }
      }

      // Switch desktop but stay open. Not goToWorkspace(), which quits: the
      // point of walking the strip is to look before you leap.
      function stepDesktop(dir) {
        const n = panel.desktops.length;
        if (n === 0)
          return;
        let i = 0;
        for (let k = 0; k < n; k++)
          if (panel.desktops[k].focused)
            i = k;
        const next = panel.desktops[(i + dir + n) % n];
        const target = root.safeWorkspaceId(next.id);
        if (target === "")
          return;
        root.dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })",
                      "workspace " + target);
      }

      function cycleWindow() {
        const n = panel.windows.length;
        if (n > 0)
          panel.selected = (panel.selected + 1 + n) % n;
      }

      // Landing on another desktop starts its selection over; without this the
      // index left over from the previous desktop points at nothing.
      onWindowsChanged: panel.selected = panel.windows.length > 0 ? 0 : -1

      function activateSelection() {
        if (panel.selected >= 0 && panel.selected < panel.windows.length)
          root.focusWindow(String(panel.windows[panel.selected].address));
        else
          root.dismiss();
      }

      // Everything eases in together rather than the contents popping in over a
      // static background -- the two-step open is the thing that gives away
      // that this is a separate process and not the compositor.
      Item {
        id: stage
        anchors.fill: parent
        // No fade and no scale on the whole stage any more. The motion lives on
        // the individual windows (real rect -> shrunken rect) and on the strip
        // sliding in from above; fading the lot on top of that made the open
        // look like a cross-dissolve between two screens instead of one screen
        // shrinking.

        // --- Spaces strip ---------------------------------------------------
        Rectangle {
          id: strip
          width: parent.width
          height: panel.stripH
          // Slides down from off-screen as the desktop shrinks to make room for
          // it, which is where macOS puts the motion. Driven by stripDeployed,
          // not by `expanded`, so it does not animate back out on close -- see
          // the note on stripDeployed.
          y: root.stripDeployed ? 0 : -panel.stripH
          opacity: root.stripDeployed ? 1 : 0
          // Arriving and leaving are not the same movement. Coming down it
          // decelerates into place, the way something that has arrived should;
          // going up it accelerates off, the way something leaving should. One
          // curve for both directions makes the exit read as reluctant.
          //
          // See stripOpenDuration for why this is shorter than the windows' own
          // animation rather than the same length.
          Behavior on y {
            NumberAnimation {
              duration: root.stripDeployed ? root.stripOpenDuration
                                           : root.stripCloseDuration
              // A translation, so it accelerates away on the way out.
              easing.type: root.stripDeployed ? Easing.OutCubic : Easing.InCubic
            }
          }
          Behavior on opacity {
            // A fade, so it tapers in both directions -- see the vocabulary
            // note. Sliding away and dissolving are not the same motion even
            // when they belong to the same object.
            NumberAnimation {
              duration: root.stripDeployed ? root.stripOpenDuration
                                           : root.stripCloseDuration
              easing.type: Easing.OutCubic
            }
          }
          }
          color: Qt.rgba(1, 1, 1, 0.07)

          Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: Qt.rgba(1, 1, 1, 0.12)
          }

          Row {
            anchors.centerIn: parent
            spacing: panel.stripGap

            Repeater {
              model: panel.desktops

              delegate: Item {
                id: deskCell
                required property var modelData
                width: panel.stripTileW
                height: panel.stripTileH + panel.stripLabelBand

                readonly property var deskWindows: {
                  const out = [];
                  const tls = deskCell.modelData.toplevels ? (deskCell.modelData.toplevels.values || []) : [];
                  for (let i = 0; i < tls.length; i++) {
                    const t = tls[i];
                    const o = t.lastIpcObject;
                    if (!t.wayland || !o || o.mapped === false || o.hidden === true)
                      continue;
                    out.push(t);
                  }
                  // Back to front: the window you last used ends up on top,
                  // which is where it is on the real desktop.
                  out.sort((a, b) => (b.lastIpcObject.focusHistoryID || 0) - (a.lastIpcObject.focusHistoryID || 0));
                  return out;
                }

                Item {
                  id: thumb
                  width: panel.stripTileW
                  height: panel.stripTileH

                  // Rounded corners the only way QtQuick offers for arbitrary
                  // content: render the tile to a texture and mask it with a
                  // rounded rectangle. `clip: true` would only ever cut a square.
                  Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.effect: MultiEffect {
                      maskEnabled: true
                      maskSource: thumbMask
                      maskThresholdMin: 0.5
                      maskSpreadAtMin: 1.0
                    }

                    // Every desktop shows the wallpaper, windows or not -- that
                    // is what makes an empty one read as "an empty desktop"
                    // rather than as a hole in the strip.
                    Image {
                      anchors.fill: parent
                      source: wallpaper.source
                      fillMode: Image.PreserveAspectCrop
                      // No sourceSize -- same source and same (absent) size as
                      // the background image, so this is a cache hit. See the
                      // note there for why asking for a smaller decode is a
                      // pessimisation, not an optimisation.
                      asynchronous: false
                      cache: true
                      smooth: true
                    }

                    Repeater {
                      model: deskCell.deskWindows

                      delegate: ScreencopyView {
                        required property var modelData
                        readonly property var ipc: modelData.lastIpcObject
                        readonly property real k: panel.stripTileW / panel.monW

                        // lastIpcObject goes undefined for a beat -- a toplevel
                        // Hyprland has announced but not yet described, or one
                        // being torn down while the model still holds it. The
                        // model filter cannot prevent that: it runs once, and
                        // these are live bindings that re-evaluate afterwards.
                        // Unguarded they throw on `.at[0]` and flood the log at
                        // shell startup, when every window is announced at once.
                        readonly property var at: (ipc && ipc.at) ? ipc.at : [0, 0]
                        readonly property var size: (ipc && ipc.size) ? ipc.size : [0, 0]

                        x: (at[0] - panel.monX) * k
                        y: (at[1] - panel.monY) * k
                        width: size[0] * k
                        height: size[1] * k

                        // No capture source at all while hidden. ScreencopyView
                        // requests a frame from the compositor the moment it has
                        // a source, regardless of `live`, so a bare
                        // `captureSource` here means every screen change (or
                        // shell start) fires one capture per window while the
                        // overlay is not even visible. Null tears the context
                        // down; `shown` flipping true creates it and captures.
                        captureSource: root.shown ? modelData.wayland : null
                        // Live, but only while shown. This plugin stays
                        // mounted, so an unconditional `live: true` would keep
                        // pulling frames of every window on every workspace
                        // forever, for a view nobody is looking at.
                        //
                        // A one-shot `live: false` + captureFrame() on open was
                        // tried, to cut the cost of capturing every window on
                        // every desktop. Reverted: the high CPU that motivated
                        // it turned out to be an artifact of measuring while a
                        // terminal was animating on the captured desktop, not a
                        // standing cost -- and one-shot capture of an
                        // *off-screen* toplevel is unverified, where live
                        // capture of one is measured and works. Do not
                        // reintroduce it without a window open on another
                        // workspace to test against.
                        live: root.shown
                        paintCursor: false
                      }
                    }

                    Rectangle {
                      anchors.fill: parent
                      color: "#05060a"
                      opacity: deskCell.modelData.focused ? 0.0 : (deskHover.hovered ? 0.10 : 0.28)
                      Behavior on opacity { NumberAnimation { duration: 140 } }
                    }
                  }

                  Item {
                    id: thumbMask
                    anchors.fill: parent
                    layer.enabled: true
                    visible: false
                    Rectangle {
                      anchors.fill: parent
                      radius: Math.max(4, Math.round(8 * panel.uiScale))
                      color: "black"
                    }
                  }

                  // One border at three brightnesses -- the desktop you are on,
                  // the one under the cursor, the rest. A second colour here
                  // would read as a second meaning.
                  Rectangle {
                    anchors.fill: parent
                    radius: Math.max(4, Math.round(8 * panel.uiScale))
                    color: "transparent"
                    border.width: Math.max(1, Math.round(2 * panel.uiScale))
                    border.color: deskCell.modelData.focused ? Qt.rgba(1, 1, 1, 0.96)
                                : deskHover.hovered ? Qt.rgba(1, 1, 1, 0.55)
                                : Qt.rgba(1, 1, 1, 0.16)
                    Behavior on border.color { ColorAnimation { duration: 120 } }
                  }

                  HoverHandler { id: deskHover }
                  TapHandler { onTapped: root.goToWorkspace(deskCell.modelData.id) }

                  scale: deskHover.hovered ? 1.03 : 1.0
                  Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
                }

                Text {
                  y: panel.stripTileH
                  width: parent.width
                  height: panel.stripLabelBand
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  // Same treatment as the window title: a workspace name is
                  // configuration-supplied text, not markup.
                  textFormat: Text.PlainText
                  text: root.displayLabel(deskCell.modelData.name || deskCell.modelData.id)
                  // An explicit sans face: the system's default `sans` resolves
                  // to Comic Code here, a monospace whose digits look like kana
                  // once they are scaled up.
                  font.family: root.fontFamily
                  font.pixelSize: panel.stripLabelSize
                  color: deskCell.modelData.focused ? "#ffffff" : Qt.rgba(1, 1, 1, 0.62)
                  style: Text.Raised
                  styleColor: Qt.rgba(0, 0, 0, 0.55)
                }
              }
            }
          }
        }

        // --- exposé of the current desktop ----------------------------------
        Repeater {
          model: panel.windows

          delegate: Item {
            id: win
            required property var modelData
            required property int index
            readonly property var ipc: modelData.lastIpcObject
            readonly property int motionDuration: root.expanded ? root.openDuration
                                                                : root.closeDuration
            readonly property bool isSelected: panel.selected === win.index
            // Hyprland's focus, not ours: focusHistoryID 0 is the window that
            // currently wears the active border on the real desktop, and that
            // is what has to match when the surface goes away.
            readonly property bool isHyprFocused: !!(ipc && ipc.focusHistoryID === 0)

            // Two rects per window, and the animation between them is the
            // whole effect.
            //
            // "real" is where the window is on the actual desktop: this layer
            // covers the screen one-to-one and the wallpaper underneath is the
            // real one, so a window drawn here at scale 1 sits exactly on top
            // of itself. That is the frame the open starts from, which is why
            // it reads as the desktop shrinking rather than a new screen
            // appearing.
            //
            // "target" is its place in the overview: the same position and size
            // scaled by the one factor every window shares.
            // Screen-relative: what Hyprland reports, minus this monitor's
            // origin. The overview layout is built in this space.
            // Guarded for the same reason as the strip thumbnails above:
            // lastIpcObject can go undefined under a live binding.
            readonly property var at: (ipc && ipc.at) ? ipc.at : [0, 0]
            readonly property var size: (ipc && ipc.size) ? ipc.size : [0, 0]

            readonly property real screenX: at[0] - panel.monX
            readonly property real screenY: at[1] - panel.monY

            // The rect is the WHOLE window -- hyprbars' bar plus the client
            // area -- so the two shrink as one object instead of the bar being
            // a thing that appears at the end.
            readonly property real barH: root.hyprbarsHeight
            readonly property real realX: screenX
            readonly property real realY: screenY - barH
            readonly property real realW: size[0]
            readonly property real realH: size[1] + barH
            readonly property real targetX: panel.originX + screenX * panel.shrink
            readonly property real targetY: panel.originY + (screenY - barH) * panel.shrink
            readonly property real targetW: realW * panel.shrink
            readonly property real targetH: realH * panel.shrink

            x: root.expanded ? targetX : realX
            y: root.expanded ? targetY : realY
            width: root.expanded ? targetW : realW
            height: root.expanded ? targetH : realH

            // One easing for all four, or the window visibly changes shape on
            // the way down instead of just getting smaller.
            Behavior on x { NumberAnimation {
              duration: win.motionDuration; easing.type: Easing.OutCubic
            } }
            Behavior on y { NumberAnimation { duration: win.motionDuration; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: win.motionDuration; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: win.motionDuration; easing.type: Easing.OutCubic } }

            Item {
              id: shot
              anchors.fill: parent

              // Proportional, not absolute: the delegate is mid-animation for
              // most of the time anyone is looking at it, and a bar with a
              // fixed pixel height would slide against the content it is
              // attached to all the way down.
              readonly property real barFrac: win.realH > 0 ? win.barH / win.realH : 0
              readonly property real barPx: shot.height * shot.barFrac

              // hyprbars' own bar, redrawn. Same colour it is given in
              // hyprbars.lua (the theme's `background`), the traffic lights in
              // the same order and alignment, and the title where it puts it.
              Rectangle {
                id: fauxBar
                visible: win.barH > 0
                width: parent.width
                height: shot.barPx
                color: Color.background
                // hyprbars has bar_precedence_over_border, so the border wraps
                // bar and content together and only the top corners are round.
                topLeftRadius: Math.min(height, Math.round(12 * panel.shrink))
                topRightRadius: fauxBar.topLeftRadius

                // bar_buttons_alignment = "left", bar_padding 14, button
                // padding 9, size 12 -- all as fractions of the bar height so
                // they ride the shrink with everything else.
                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  x: shot.barPx * (14 / 44)
                  spacing: shot.barPx * (9 / 44)
                  Repeater {
                    model: ["#ff5f57", "#febc2e", "#28c840"]
                    delegate: Rectangle {
                      required property string modelData
                      width: shot.barPx * (12 / 44)
                      height: width
                      radius: width / 2
                      color: modelData
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                // bar_text_align = "center". Illegible once the desktop is
                // shrunk, and that is correct -- the real one is illegible at
                // that size too, and leaving it out is what makes a thumbnail
                // look like a mock-up of a window rather than a window.
                Text {
                  anchors.centerIn: parent
                  width: parent.width * 0.5
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: win.modelData.title || ""
                  // hyprbars uses the theme's light_foreground; the shell's
                  // Color singleton does not expose that one, and `foreground`
                  // is the same colour a shade darker -- indistinguishable once
                  // the desktop is shrunk.
                  color: Color.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Math.max(1, shot.barPx * (13 / 44))
                }
              }

              ScreencopyView {
                y: fauxBar.visible ? shot.barPx : 0
                width: parent.width
                height: parent.height - y
                // Null while hidden -- see the note in the Spaces strip.
                captureSource: root.shown ? win.modelData.wayland : null
                // Live while shown, and only while shown -- see the note in the
                // Spaces strip. Hyprland renders a toplevel on demand for
                // capture whether or not it is on a visible workspace, so
                // "live" costs nothing extra beyond the frames themselves.
                live: root.shown
                paintCursor: false
              }

              // Selection is a ring plus a nudge in size. No fill and no dim on
              // the others: in the exposé the windows are the content, and
              // dimming five of six makes the whole view look switched off.
              Rectangle {
                anchors.fill: parent
                anchors.margins: -Math.round(3 * panel.uiScale)
                radius: Math.max(4, Math.round(10 * panel.uiScale))
                color: "transparent"
                border.width: Math.max(2, Math.round(3 * panel.uiScale))
                border.color: (win.isSelected && root.expanded) ? Qt.rgba(1, 1, 1, 0.92) : "transparent"
                Behavior on border.color { ColorAnimation { duration: 120 } }
              }

              // Gated on `expanded`, which the selection ring above already
              // was and this was not. Left ungated it stayed on through the
              // close: the window animated back to its real rect and then sat
              // there two percent too large until the surface was dropped and
              // it snapped to the real one. What that looks like is the window
              // overshooting its old position and pulling back, which is not a
              // flourish -- it is the overview's selection state outliving the
              // overview.
              scale: (win.isSelected && root.expanded) ? 1.02 : 1.0
              Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
            }

            // Hyprland's own border, redrawn, because the capture cannot carry
            // it. It sits OUTSIDE the window rect -- a tiled window reports
            // at=[12,89] against a 10px gap, and those two missing pixels each
            // side are the border -- and with hyprbars' bar_precedence_over_
            // border it wraps the bar and the content together, which is what
            // this rect already is.
            //
            // Scaled by how far into the shrink the window is, not by
            // panel.shrink, so the border thins with the window instead of
            // snapping to its final width on the first frame.
            Rectangle {
              readonly property real k: win.realW > 0 ? win.width / win.realW : 1
              readonly property real px: root.hyprBorderSize * k
              visible: root.hyprBorderSize > 0
              // Only at full size. This border exists to match the real desktop
              // at the moment the surface is dropped, not to decorate the
              // overview -- in there the white selection ring is the frame, and
              // drawing both put two outlines a pixel apart around every
              // window. It fades on exactly the animation that returns the
              // windows to full size, so it is at full strength precisely when
              // it has something to match.
              opacity: root.expanded ? 0 : 1
              Behavior on opacity {
                NumberAnimation { duration: win.motionDuration; easing.type: Easing.OutCubic }
              }
              anchors.fill: parent
              anchors.margins: -px
              color: "transparent"
              border.width: px
              border.color: win.isHyprFocused ? root.hyprActiveBorder
                                              : root.hyprInactiveBorder
              radius: root.hyprRounding * k + px
            }

            // Icon straddling the bottom edge of the window with the title
            // under it -- the macOS arrangement. Capped against the window so a
            // small floating window does not get an icon wider than itself.
            // Icon and title belong to the overview, not to the desktop, so
            // they arrive as the shrink finishes rather than riding down with
            // the window at full size -- which looked like the window had grown
            // a label.
            Image {
              id: appIcon
              width: Math.min(panel.iconSize, win.width * 0.4)
              height: width
              x: (win.width - width) / 2
              y: win.height - height / 2
              opacity: root.expanded ? 1 : 0
              Behavior on opacity {
                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
              }
              source: root.iconFor(win.ipc["class"])
              sourceSize.width: panel.iconSize
              sourceSize.height: panel.iconSize
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
            }

            Text {
              width: Math.max(win.width, panel.screenW * 0.16)
              x: (win.width - width) / 2
              y: appIcon.y + appIcon.height + Math.round(panel.titleSize * 0.5)
              horizontalAlignment: Text.AlignHCenter
              // Untrusted: see root.displayLabel.
              textFormat: Text.PlainText
              text: root.displayLabel(win.modelData.title || win.ipc["class"] || "")
              font.family: root.fontFamily
              font.pixelSize: panel.titleSize
              color: win.isSelected ? "#ffffff" : Qt.rgba(1, 1, 1, 0.78)
              opacity: root.expanded ? 1 : 0
              Behavior on opacity {
                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
              }
              elide: Text.ElideRight
              maximumLineCount: 1
              style: Text.Raised
              styleColor: Qt.rgba(0, 0, 0, 0.6)
            }

            HoverHandler {
              id: winHover
              // Only once the windows have settled: during the shrink they are
              // sliding under a stationary pointer, so every window they pass
              // under would grab the selection.
              onHoveredChanged: if (hovered && root.expanded) panel.selected = win.index
            }

            TapHandler {
              onTapped: root.focusWindow(String(win.modelData.address))
            }
          }
        }

        // An empty desktop says so, rather than leaving a blank half-screen
        // that looks like something failed to load.
        Text {
          visible: panel.windows.length === 0
          opacity: root.expanded ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 140 } }
          anchors.horizontalCenter: parent.horizontalCenter
          y: panel.exposeAreaY + panel.exposeAreaH * 0.42
          textFormat: Text.PlainText
          text: "No windows"
          font.family: root.fontFamily
          font.pixelSize: Math.round(22 * panel.uiScale)
          color: Qt.rgba(1, 1, 1, 0.35)
        }
      }
    }
  }
}
