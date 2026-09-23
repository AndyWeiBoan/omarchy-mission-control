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
  // Deployed one frame AFTER `expanded`, never in the same one.
  //
  // The strip snapped into place instead of sliding, from the second open
  // onwards. Recorded at 60fps: the first open moved it over four frames
  // (bottom edge 128 -> 132 -> 238 -> 239 -> 288), the second put it at 288 in
  // a single frame. Nothing about the durations was wrong -- the animation
  // never ran.
  //
  // `expanded` is set when the backing window becomes visible, and on a warm
  // open that arrives before the strip item has been created. The item is then
  // born with stripDeployed already true, so its y binding evaluates straight
  // to 0 and the Behavior has no transition to animate: a Behavior only fires
  // on a CHANGE, and there was none. The first open works only because the
  // surface is cold and slow enough to lose the race.
  //
  // One frame of delay puts the change back after the item exists and is
  // parked above the screen edge, which is what the Behavior needs.
  onExpandedChanged: {
    if (root.expanded)
      deployStrip.restart();
    else {
      deployStrip.stop();
      root.stripDeployed = false;
    }
  }
  Timer {
    id: deployStrip
    interval: 16
    onTriggered: if (root.expanded) root.stripDeployed = true
  }
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

  // The strip runs at the SAME rate as the windows: one ratio, set to 1.
  //
  // It has been given less time twice, and both times the reasoning was about
  // how the motion reads rather than about what it is. The note is worth
  // keeping because the observation was real: with both at 260 ms, measurement
  // said they were simultaneous -- start and finish within 3 ms, every time --
  // and it still looked as though the strip arrived late, because identical
  // curves on different objects do not read as identical motion. The windows
  // shrink from the whole screen to a thumbnail, so their last eighth is a
  // nudge of something already small; the strip is a solid 146px band whose
  // last eighth is eighteen pixels that are plainly still moving.
  //
  // Shortening it to 200 against a 260 ms window animation fixed that. What it
  // did not survive was the windows going to 320 and the strip keeping its flat
  // 200: the ratio fell to 0.62 and the strip visibly stopped while the windows
  // were still moving. Raising it to 0.75 made it late again. andywei asked for
  // the same rate, which is what this now is -- and tied to the window
  // durations rather than written out, so it cannot drift again.
  readonly property real stripTimeRatio: 0.85
  readonly property int stripOpenDuration: Math.round(root.openDuration * root.stripTimeRatio)
  readonly property int stripCloseDuration: Math.round(root.closeDuration * root.stripTimeRatio)

  // The crossfade to the real desktop. It begins 60ms before the windows are
  // home and runs past them, which is the "atmosphere outlives the content"
  // rule above.
  readonly property int fadeDuration: 160

  // Everything the open does once the desktop underneath is settled. Split out
  // of setShown because a flattened workspace reaches it one timer later.
  function reallyShow() {
    root.contentVisible = true;
    root.shown = true;
    settleStripSoon.restart();
    // The shrink is started by the window itself, once its surface is actually
    // up -- see onBackingWindowVisibleChanged below. This is only a backstop so
    // the overview can never sit there showing full-size windows if that signal
    // does not arrive.
    expandFallback.start();
  }

  // Long enough for three socket round trips to land. This plugin stays
  // mounted, possibly idle for hours, and a window moved or resized while we
  // held no interest in it leaves lastIpcObject stale -- every thumbnail's
  // position and size is computed from that, so a stale rect puts windows in
  // visibly wrong places, and a stale layout name picks the wrong overview
  // entirely.
  Timer {
    id: decideThenFlatten
    interval: 70
    onTriggered: {
      if (!root.opened)
        return;
      if (root.flattenIfNeeded())
        flattenSettle.restart();
    }
  }

  // Long enough for Hyprland to re-tile and for the new rects to be worth
  // asking for. Shorter and the overview opens on the accordion's geometry and
  // then jumps; this is the one place where waiting is cheaper than correcting.
  // The re-tile moved every window, and the overview is laid out from those
  // rects. Fetching them retargets the shrink that is already running.
  // Once the desktops are in and the strip has a width to measure.
  Timer {
    id: settleStripSoon
    interval: 60
    onTriggered: if (root.shown) root.settleAllStrips()
  }

  signal settleAllStrips()

  Timer {
    id: flattenSettle
    interval: 180
    onTriggered: {
      if (!root.opened) {
        // Closed again inside the window. Put the layout back and stay down.
        root.restoreWorkspaceLayout();
        return;
      }
      Hyprland.refreshToplevels();
    }
  }

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
      // wedging the toggle -- and still put the layout back, for the same
      // reason: whatever got us here, the workspace is not ours to keep.
      root.expanded = false;
      root.restoreWorkspaceLayout();
      return;
    }
    if (next) {
      // Ask Hyprland what is actually true, THEN decide.
      //
      // This used to read the cached IPC objects directly and it got the first
      // open of every session wrong: `tiledLayout` only changes on a config
      // event, which nothing here subscribes to, so the cached value was
      // whatever it had been when the plugin loaded. The first open saw
      // "dwindle" on a scrolling workspace and skipped the flatten; the second
      // open saw the value the first open's refresh had fetched and worked.
      // Two opens in a row therefore did different things, which is the one
      // behaviour an overview cannot have.
      //
      // Three round trips on the Hyprland socket, and now we wait for them
      // rather than reading through them. The plugin already accepted their
      // cost in the critical path; what it did not do was let them land.
      Hyprland.refreshMonitors();
      Hyprland.refreshWorkspaces();
      Hyprland.refreshToplevels();
      // Show NOW, on the geometry we already have, and flatten underneath the
      // animation rather than in front of it.
      //
      // Waiting for the re-tile first gave two separate motions: the desktop
      // visibly rearranged, and only then did the overview open. Two animations
      // in a row where the eye expects one reads as a stutter, and it also
      // throws away this plugin's whole opening trick -- the first frame is
      // supposed to be the desktop you were already looking at.
      //
      // So the surface goes up on the accordion's own rects, which IS that
      // desktop, and the flatten lands a few frames later while the windows are
      // already shrinking. Their targets move once, mid-flight, and the
      // Behaviors carry them there: one motion that settles, instead of two
      // that queue.
      root.reallyShow();
      decideThenFlatten.restart();
      return;
    }
    {
      // Reverse of the open: shrink back out to the real desktop, then drop the
      // surface once the windows are home. Dropping it first would cut the
      // animation off and read as a flicker.
      //
      // The accordion comes back HERE, at the start of the close, for the same
      // reason it was not restored before the open: so there is one motion
      // rather than two. The windows animate out to where the accordion is
      // putting them -- most of them off the edge of the screen, which is
      // exactly where they are -- and by the time the surface drops the desktop
      // underneath already matches. Restoring after the drop instead left the
      // desktop rearranging itself in full view, a beat after the overview had
      // gone.
      root.restoreWorkspaceLayout();
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
  // --- flattening a scrolling workspace -------------------------------------
  // Hyprland does not copy a screencopy frame for a window whose rect does not
  // intersect the monitor -- see CScreenshareManager::onOutputCommit -- and in
  // a scrolling workspace most of the row is off screen, so most thumbnails
  // arrive empty. There is no error anywhere to say why: no `ready`, no
  // `failed`, nothing in either log.
  //
  // So the overview flattens the workspace before it opens. scrolling ->
  // dwindle puts every window back onto the monitor, which is the only thing
  // Hyprland needs to start producing their frames, and closing puts it back.
  //
  // MEASURED, because the whole idea rests on it: position, size AND column
  // order all come back identical, across four consecutive round trips.
  // `fit all` is NOT a substitute -- it also brings the row on screen, but a
  // layout round trip after it reorders the columns.
  //
  // The cost is real and visible: dwindle tiles the row into very uneven
  // rectangles (measured 175x185 next to 730x861), so every terminal reflows
  // on the way in and back on the way out, and the thumbnails are of those
  // reflowed windows rather than of the row you left.
  property string flattenedWorkspace: ""
  Process { id: layoutSwap }

  function setWorkspaceLayout(id, layout) {
    const safe = root.safeWorkspaceId(id);
    if (safe === "")
      return;
    layoutSwap.running = false;
    layoutSwap.command = ["hyprctl", "eval",
                          'hl.workspace_rule({ workspace = "' + safe
                          + '", layout = "' + layout + '" })'];
    layoutSwap.running = true;
  }

  // True when the workspace is scrolling AND something on it is entirely off
  // the monitor. Both halves matter: a scrolling workspace whose row happens
  // to fit needs nothing done to it, and no other layout can put a window
  // outside the monitor in the first place.
  function flattenIfNeeded() {
    if (root.flattenedWorkspace !== "")
      return false;
    const ws = Hyprland.focusedWorkspace;
    const o = ws ? ws.lastIpcObject : null;
    if (!o || o.tiledLayout !== "scrolling")
      return false;
    const mon = Hyprland.focusedMonitor;
    const m = mon ? mon.lastIpcObject : null;
    if (!m || !m.scale)
      return false;
    const mx = m.x, my = m.y;
    const mw = m.width / m.scale, mh = m.height / m.scale;
    const tls = ws.toplevels ? (ws.toplevels.values || []) : [];
    let offscreen = false;
    for (let i = 0; i < tls.length; i++) {
      const w = tls[i].lastIpcObject;
      if (!w || !w.at || !w.size || w.mapped === false)
        continue;
      if (w.at[0] + w.size[0] <= mx || w.at[0] >= mx + mw
          || w.at[1] + w.size[1] <= my || w.at[1] >= my + mh) {
        offscreen = true;
        break;
      }
    }
    if (!offscreen)
      return false;
    root.flattenedWorkspace = root.safeWorkspaceId(ws.id);
    if (root.flattenedWorkspace === "")
      return false;
    root.setWorkspaceLayout(root.flattenedWorkspace, "dwindle");
    return true;
  }

  function restoreWorkspaceLayout() {
    if (root.flattenedWorkspace === "")
      return;
    root.setWorkspaceLayout(root.flattenedWorkspace, "scrolling");
    root.flattenedWorkspace = "";
  }

  // Belt and braces. Leaving somebody's workspace on the wrong layout because
  // the shell was restarted mid-overview is not an acceptable failure mode.
  Component.onDestruction: root.restoreWorkspaceLayout()

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
  // --- adding and removing desktops ---------------------------------------
  // Both are runtime-only, and that is the right shape rather than a
  // shortcoming. The user's Hyprland config is what says which desktops exist
  // -- a `for i = 1, 5` of persistent workspace rules, typically -- so a reload
  // returns to that, and this plugin never writes to it.
  //
  // What survives a reload is what has windows on it: Hyprland does not collect
  // a workspace that is not empty. So a desktop you added and put something on
  // stays, and one you added and left empty does not, which is what you would
  // want either way.
  // Ten, to match what Omarchy binds: its tiling.lua does `for workspace =
  // 1, 10`, so SUPER+1 through SUPER+0 reach ten desktops and nothing reaches
  // an eleventh. Hyprland itself has no limit; this is the number that has
  // keys on it. If that loop is changed, change this with it.
  readonly property int maxWorkspaces: 10

  function addWorkspace() {
    const taken = {};
    const list = Hyprland.workspaces ? (Hyprland.workspaces.values || []) : [];
    for (let i = 0; i < list.length; i++)
      taken[list[i].id] = true;
    for (let id = 1; id <= root.maxWorkspaces; id++) {
      if (!taken[id]) {
        root.setWorkspacePersistent(id, true);
        return id;
      }
    }
    return -1;
  }

  // Windows first, then the desktop. Dropping persistence on a workspace that
  // still has something on it does nothing -- Hyprland keeps it precisely
  // because it is not empty -- so the close button would look broken.
  function removeWorkspace(id, windows, fallbackId, isCurrent) {
    // Hyprland does not collect the workspace you are standing on, so step off
    // it first -- silently, the way the arrow keys walk the strip, which moves
    // the desktop under the overview without closing it.
    if (isCurrent) {
      const to = root.safeWorkspaceId(fallbackId);
      if (to === "")
        return;
      root.dispatch("hl.dsp.focus({ workspace = \"" + to + "\" })",
                    "workspace " + to);
    }
    for (let i = 0; i < windows.length; i++) {
      const o = windows[i].lastIpcObject;
      if (o && o.address)
        root.moveWindowToWorkspace(o.address, fallbackId);
    }
    root.setWorkspacePersistent(id, false);
  }

  function setWorkspacePersistent(id, persistent) {
    const ws = root.safeWorkspaceId(id);
    if (ws === "")
      return;
    workspaceRule.running = false;
    workspaceRule.command = ["hyprctl", "eval",
                             'hl.workspace_rule({ workspace = "' + ws
                             + '", persistent = ' + (persistent ? "true" : "false") + ' })'];
    workspaceRule.running = true;
  }

  Process { id: workspaceRule }

  // Move a window to another desktop without going there.
  //
  // `follow = false` is the whole point: the plain dispatcher takes the view
  // with it, which would drop you on the target desktop and tear the overview
  // down around the window you were still arranging. Measured all three
  // spellings -- `silent = true` and `switch = false` are both accepted and
  // both still follow.
  function moveWindowToWorkspace(address, workspaceId) {
    const addr = root.safeAddress(address);
    const ws = root.safeWorkspaceId(workspaceId);
    if (addr === "" || ws === "")
      return;
    root.dispatch('hl.dsp.window.move({ window = "address:' + addr
                  + '", workspace = "' + ws + '", follow = false })',
                  "movetoworkspacesilent " + ws + ",address:" + addr);
  }

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
    interval: root.closeDuration - 60 + root.fadeDuration
    onTriggered: {
      if (root.opened)
        return;
      root.shown = false;
      // Belt and braces: the close path above restores it, but any route that
      // reaches here without having done so must not leave the workspace on
      // the wrong layout.
      root.restoreWorkspaceLayout();
    }
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

      // Runtime-only visual order. Hyprland workspace IDs stay unchanged, so
      // this does not alter bindings or workspace rules and disappears on a
      // shell restart.
      property var desktopOrder: []
      readonly property var orderedDesktops: {
        const source = panel.desktops;
        const byId = {};
        const out = [];
        for (let i = 0; i < source.length; i++)
          byId[source[i].id] = source[i];
        for (let i = 0; i < panel.desktopOrder.length; i++) {
          const ws = byId[panel.desktopOrder[i]];
          if (ws) {
            out.push(ws);
            delete byId[panel.desktopOrder[i]];
          }
        }
        for (let i = 0; i < source.length; i++)
          if (byId[source[i].id])
            out.push(source[i]);
        return out;
      }

      function reorderDesktop(deskId, beforeId) {
        const order = panel.orderedDesktops.map(ws => ws.id);
        const from = order.indexOf(deskId);
        if (from < 0)
          return;
        order.splice(from, 1);
        let to = beforeId < 0 ? order.length : order.indexOf(beforeId);
        if (to < 0)
          to = order.length;
        order.splice(to, 0, deskId);
        panel.desktopOrder = order;
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
      // One size, whatever the count. The tile is as tall as the strip allows
      // and that is the end of it.
      //
      // It used to also shrink to keep the row inside 92% of the screen, which
      // was the right answer when the strip could not scroll. Now that it can,
      // shrinking is the worse half of the trade: measured, the height limit
      // holds up to seven desktops at 168px wide, and from the eighth the width
      // term takes over -- 159, then 139, then 124. Three visible consequences,
      // all of them unpleasant. The thumbnails get too small to read. The row's
      // top edge moves down as they shrink, so everything in the strip drifts.
      // And adding a desktop no longer shifts the row by a fixed amount, so the
      // strip lurches by a different distance each time.
      //
      // Fixed size, and the row overruns the screen instead. That is what the
      // scrolling is for.
      readonly property real stripTileH: stripH - stripLabelBand - stripPad * 2
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

      // The one scale every window shares. It assumes the desktop fits on the
      // screen, which is what flattening a scrolling workspace is for -- see
      // flattenIfNeeded.
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

      // --- dragging a window onto another desktop ----------------------------
      // index into panel.windows while a drag is in flight, -1 otherwise.
      property int dragging: -1
      // The desktop a release right now would move it to, or -1.
      property int dropTarget: -1
      // The tile itself, not just its id: the dragged window is flown to it, so
      // its position and size are needed, not merely its identity.
      property var dropCell: null
      property int reorderTarget: -1
      property int draggingDesktop: -1

      function reorderTargetAt(sceneX) {
        const p = stripRow.mapFromItem(null, sceneX, 0);
        const cells = stripRow.children;
        for (let i = 0; i < cells.length; i++) {
          const c = cells[i];
          if (c.deskId === undefined || !c.visible)
            continue;
          if (p.x < c.x + c.width / 2)
            return c.deskId;
        }
        return -1;
      }

      // How far the Spaces strip is scrolled from centre. Zero, and irrelevant,
      // until there are more desktops than fit. Re-clamped when the row's length
      // changes under it, or removing a desktop could leave it scrolled past an
      // end that no longer exists.
      property real stripScroll: 0

      // The rest position is where the strip IS, not somewhere it slides to
      // after an addition. It was conditional on the count having grown at
      // first, which meant opening the overview on seven desktops left the
      // seventh 61px from the "+" -- measured off the screen, against the 153.5
      // the rule asks for -- because arriving at seven is not the same event as
      // growing to it.
      // Settled off the ROW's width, not off the desktop count.
      //
      // The count changes first and the row is laid out afterwards, so settling
      // on the count computed the rest position from the width the strip still
      // had a moment ago. Deleting desktops from ten down left the row parked
      // 35px off centre, because the arithmetic had been done against a row
      // that no longer existed.
      Connections {
        target: stripRow
        function onWidthChanged() { panel.settleStrip(); }
      }
      Connections {
        target: root
        function onSettleAllStrips() { panel.settleStrip(); }
      }
      function settleStrip() {
        panel.stripScroll = stripViewport.clampScroll(stripViewport.restScroll);
      }

      // One past the highest desktop that exists. Hyprland creates a workspace
      // on demand when a window is moved to one, so this needs no setting up --
      // and computing it beats asking for "empty", which resolved to a desktop
      // that already had windows on it when it was tried.
      readonly property int newWorkspaceId: {
        let top = 0;
        for (let i = 0; i < panel.desktops.length; i++)
          top = Math.max(top, panel.desktops[i].id);
        return top + 1;
      }

      // Hit-tested with the dragged WINDOW's rectangle, not with the pointer.
      //
      // The pointer is wherever you happened to grab the thing. Grab a window
      // near its bottom edge and its top can be well inside a desktop tile
      // while the cursor is still hundreds of pixels below the strip -- so the
      // window plainly overlapped the target and nothing happened. What is
      // touching the tile is what should decide.
      //
      // The tile with the largest overlap wins, so a window straddling two of
      // them goes to the one it is mostly on.
      //
      // Hit-tested by position rather than by index, so it does not care how
      // the strip is laid out or how many tiles are in it.
      function dropTargetForRect(sceneX, sceneY, w, h) {
        // In the viewport's space, because the "+" is anchored to the viewport's
        // right edge while the tiles live in a row that scrolls inside it.
        const p = stripViewport.mapFromItem(null, sceneX, sceneY);
        let best = null, bestArea = 0;
        function consider(c, cx, cy) {
          if (!c || c.deskId === undefined || c.width <= 0 || !c.visible)
            return;
          const ox = Math.min(p.x + w, cx + c.width) - Math.max(p.x, cx);
          const oy = Math.min(p.y + h, cy + c.height) - Math.max(p.y, cy);
          if (ox <= 0 || oy <= 0)
            return;
          if (ox * oy > bestArea) {
            bestArea = ox * oy;
            best = c;
          }
        }
        for (let i = 0; i < stripRow.children.length; i++) {
          const c = stripRow.children[i];
          consider(c, stripRow.x + c.x, stripRow.y + c.y);
        }
        if (newDeskCell.enabled)
          consider(newDeskCell, newDeskCell.x, newDeskCell.y);
        panel.dropCell = best;
        return best ? best.deskId : -1;
      }

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
        // Did any window lie along this axis at all, in either direction? A
        // whole pixel of tolerance, so windows that merely round differently
        // do not count as being above one another.
        let axisLive = false;
        for (let i = 0; i < n; i++) {
          if (i === panel.selected)
            continue;
          const to = panel.centreOf(panel.windows[i]);
          const along = (to.x - from.x) * dx + (to.y - from.y) * dy;
          if (Math.abs(along) > 1)
            axisLive = true;
          if (along <= 0)
            continue;
          const across = Math.abs((to.x - from.x) * dy) + Math.abs((to.y - from.y) * dx);
          const cost = along + across * 2;
          if (cost < bestCost) {
            bestCost = cost;
            best = i;
          }
        }
        if (best >= 0) {
          panel.selected = best;
          return;
        }
        // Nothing that way. Two different situations, and they want different
        // answers:
        //
        //   The axis is live and we are at the end of it -- something IS above
        //   us, we are just the bottom row. Stay put rather than jumping to the
        //   far side, which is what this always did.
        //
        //   The axis is dead: no window lies either way along it. A scrolling
        //   workspace is one long row, so every window shares a y and up/down
        //   never has anywhere to go -- the keyboard could not move the
        //   selection at all, only Tab could. Step along the row instead.
        if (axisLive)
          return;
        panel.stepInOrder(dy !== 0 ? dy : dx);
      }

      // Windows left to right, top to bottom. Only used when the arrow keys
      // are pressed along a dead axis, so the order is a fallback, not the
      // navigation model -- see move().
      function orderedIndices() {
        const out = [];
        for (let i = 0; i < panel.windows.length; i++)
          out.push(i);
        out.sort((a, b) => {
          const ca = panel.centreOf(panel.windows[a]);
          const cb = panel.centreOf(panel.windows[b]);
          return (ca.x - cb.x) || (ca.y - cb.y);
        });
        return out;
      }

      // One step, and it stops at the ends: the no-wrap rule in move() applies
      // here too, so holding the key down does not loop the row.
      function stepInOrder(dir) {
        const order = panel.orderedIndices();
        const at = order.indexOf(panel.selected);
        if (at < 0)
          return;
        const next = at + (dir > 0 ? 1 : -1);
        if (next < 0 || next >= order.length)
          return;
        panel.selected = order[next];
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
      //
      // The Spaces strip is not backdrop. A tap that lands in it and hits
      // nothing -- the gap between two desktops, the empty run in front of the
      // "+", the "+" itself once it is disabled -- should do nothing at all,
      // and it was closing the overview instead, because none of those consume
      // the tap and this handler sees everything the rest of the surface does
      // not take.
      //
      // Guarded by position rather than by putting a consuming MouseArea over
      // the strip: a MouseArea there would take the press from the drag that
      // scrolls the strip, and scrolling by dragging would stop working.
      TapHandler {
        onTapped: eventPoint => {
          const y = eventPoint.position.y;
          if (y >= strip.y && y <= strip.y + strip.height)
            return;
          root.dismiss();
        }
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
        const n = panel.orderedDesktops.length;
        if (n === 0)
          return;
        let i = 0;
        for (let k = 0; k < n; k++)
          if (panel.orderedDesktops[k].focused)
            i = k;
        const next = panel.orderedDesktops[(i + dir + n) % n];
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
      // index left over from the previous desktop points at nothing. Index 0 is
      // Hyprland's focused window -- panel.windows is sorted by focusHistoryID
      // -- so the selection opens on the window you just left.
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
          // Driven by an explicit animation, not by a Behavior on a bound
          // property.
          //
          // As bindings -- y: deployed ? 0 : -stripH, with a Behavior on each
          // -- the strip snapped into place instead of sliding, and did it
          // inconsistently: recorded at 60fps, one open moved it over four
          // frames and the next put it at its final position in a single one.
          // A Behavior only runs on a CHANGE, and on a warm open the item is
          // created with the overview already expanded, so its y evaluates
          // straight to 0 and there is no change to animate. Delaying the flag
          // by a frame did not help, because the race is with the item's own
          // construction rather than with a signal.
          //
          // Starting from an explicit `from` removes the question. Whenever the
          // overview expands, the strip is put above the screen edge and told
          // to travel; whenever it collapses, the reverse. It cannot matter
          // when the item was built or what the flag was at the time.
          y: -panel.stripH
          opacity: 0

          // Arriving and leaving are not the same movement. Coming down it
          // decelerates into place, the way something that has arrived should;
          // going up it accelerates off, the way something leaving should. One
          // curve for both directions makes the exit read as reluctant. The
          // fade tapers in both, because sliding away and dissolving are not
          // the same motion even when they belong to the same object.
          ParallelAnimation {
            id: stripIn
            NumberAnimation {
              target: strip; property: "y"; to: 0
              duration: root.stripOpenDuration; easing.type: Easing.OutCubic
            }
            NumberAnimation {
              target: strip; property: "opacity"; to: 1
              duration: root.stripOpenDuration; easing.type: Easing.OutCubic
            }
          }
          ParallelAnimation {
            id: stripOut
            NumberAnimation {
              target: strip; property: "y"; to: -panel.stripH
              // A translation, so it accelerates away on the way out.
              duration: root.stripCloseDuration; easing.type: Easing.InCubic
            }
            NumberAnimation {
              target: strip; property: "opacity"; to: 0
              duration: root.stripCloseDuration; easing.type: Easing.OutCubic
            }
          }

          function deploy(open) {
            stripIn.stop();
            stripOut.stop();
            if (open) {
              // Always from the parked position, even when the item was built
              // after the overview had already expanded.
              strip.y = -panel.stripH;
              strip.opacity = 0;
              stripIn.start();
            } else {
              stripOut.start();
            }
          }
          Connections {
            target: root
            function onExpandedChanged() { strip.deploy(root.expanded); }
          }
          Component.onCompleted: if (root.expanded) strip.deploy(true);

          // Frosted, not merely tinted. 7% white over a sharp wallpaper is a
          // wash; macOS's Spaces strip is glass, and the give-away is that the
          // thumbnails in it sit against something softer than the desktop
          // below. So the fill moves off the Rectangle and becomes two layers:
          // a blurred copy of the wallpaper, then the same 7% white over it.
          color: "transparent"

          // The blur is done HERE, on our own copy of the wallpaper. NOT by the
          // compositor: a `blur = true` layer rule, and equally Quickshell's
          // BackgroundEffect, makes hyprbars' title bars flicker between
          // transparent and coloured every time they redraw -- see the note on
          // the background for the full story.
          Item {
            anchors.fill: parent
            clip: true

            Image {
              // Screen-anchored, not strip-anchored. `-strip.y` cancels the
              // strip's own slide, so what shows through the band is the piece
              // of wallpaper actually behind it. Bound to the strip instead,
              // the frost would travel with it and read as a picture sliding
              // in rather than as glass moving across a still background.
              y: -strip.y - bleed
              // Same framing as the background image and the bar cover: the
              // whole panel, cropped once. Fitting this to the band instead
              // would be a different PreserveAspectCrop result and the frost
              // would not line up with the sharp wallpaper it meets at the
              // strip's lower edge.
              height: panel.height + bleed * 2
              source: root.wallpaperSource
              fillMode: Image.PreserveAspectCrop
              // Same source and same (absent) sourceSize as the background, so
              // this is a cache hit rather than a second 5K decode.
              asynchronous: true
              cache: true

              // The layer is on the IMAGE, whose content never changes, so the
              // blur is rendered once and merely re-positioned while the strip
              // moves. On the clipping Item above it instead, it would re-blur
              // every frame of the slide.
              //
              // `bleed` is why this image is drawn larger than the area it
              // covers. MultiEffect samples past the edges of what it blurs,
              // and the top edge of this layer is the top edge of the SCREEN --
              // so the blur ran out of pixels exactly there and the first rows
              // of the band came back barely blurred at all. Measured over a
              // thumbnail-free column: high-frequency sd 6.16 in the top 20
              // physical pixels and 3.85 in the next 20, against 1.2-1.5
              // through the rest of the band. On screen that is the strip going
              // thin and see-through right where it meets the top of the
              // display.
              //
              // Growing the source by more than blurMax on every side moves
              // those edges off screen, so every row of the band is blurred by
              // the same full kernel. The content is then scaled ~12% larger
              // than the sharp wallpaper it sits over and no longer lines up
              // with it -- which is free, because it is blurred past the point
              // where anything could line up.
              //
              // Downsampling the layer instead (layer.textureSize) also fixes
              // the edge, and was tried: uniform, cheaper, and visibly blocky.
              // An upscale that large shows its bilinear facets.
              readonly property int bleed: 96
              x: -bleed
              width: strip.width + bleed * 2
              layer.enabled: true
              layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                blurMax: 64
              }
            }
          }

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(1, 1, 1, 0.07)
          }

          Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: Qt.rgba(1, 1, 1, 0.12)
          }

          // The strip scrolls once it is wider than the screen, which nine
          // desktops plus the "+" tile always is: ten tiles come to about
          // 2500px against 1512 of screen.
          //
          // Centred while it fits and only scrollable when it does not, so the
          // usual four or five desktops sit in the middle of the screen exactly
          // as they did before this existed.
          Item {
            id: stripViewport
            anchors.fill: parent
            clip: true

            // The row is ALWAYS centred, and scrolling moves it either way from
            // there. It used to be centred while it fitted and pinned to x = 0
            // once it did not, and the switch between the two was the thing
            // that felt wrong: measured, adding the seventh desktop moved the
            // row 93px, the eighth 117px, and the ninth not at all, because the
            // eighth was where the mode flipped. Centred throughout, every
            // desktop added moves it by exactly half a tile.
            //
            // The row gets the whole strip. The "+" floats over it rather than
            // taking a slice out of it: reserving room squeezed the desktops
            // into a narrower space for the sake of a control, and at nine of
            // them the last tile ran under the disc anyway. Over the top, the
            // row keeps the full width and simply runs off the edges, which is
            // what the scrolling is there for.
            readonly property real usableW: width
            readonly property real overflow: Math.max(0, stripRow.width - usableW)
            // There is somewhere to scroll to when the two ends of the range
            // are not the same place.
            readonly property bool scrollable:
                Math.abs(clampScroll(-99999) - clampScroll(99999)) > 1
            readonly property real centredX: (usableW - stripRow.width) / 2
            readonly property real plusLeft: width - newDeskCell.width
                                             - Math.round(panel.stripGap * 1.2)

            // The gap a sixth desktop happens to leave in front of the "+",
            // taken as the rule for every desktop after it. Six is the last
            // count that fits without scrolling, so it is the last one whose
            // spacing nobody had to choose -- and it is the spacing this strip
            // looks right at.
            readonly property real restGap: {
                const row6 = 6 * panel.stripTileW + 5 * panel.stripGap;
                return plusLeft - ((usableW - row6) / 2 + row6);
            }

            // Where a newly added desktop wants the row to sit: far enough left
            // that the new last tile keeps restGap in front of the "+". Never
            // to the right of centred -- the rule is a minimum distance, not a
            // position, so it only ever pulls the row forward.
            readonly property real restScroll: Math.min(
                0, plusLeft - restGap - stripRow.width - centredX)

            // Scrolling by hand is NOT held to that rule. It runs from the first
            // tile flush against the left edge to the last tile flush against
            // the right -- under the "+", past it, wherever you want to put it.
            // The rule is where the strip settles, not a wall.
            //
            // Not gated on the row overflowing, either. Seven desktops still fit
            // on this screen and the seventh still lands 61px from the "+",
            // which is less than half the distance the rule asks for: the rule
            // starts mattering before the scrolling does.
            function clampScroll(v) {
                // Both ends stop with the same clear space: restGap in front of
                // the "+" on the right, restGap in from the screen edge on the
                // left. Scrolling right used to stop with the first desktop
                // jammed flat against the edge at x = 0 while the other end
                // kept its 153px, which is the asymmetry that reads as the
                // first desktop not being able to get back where it was.
                const hi = stripViewport.restGap - stripViewport.centredX;
                const lo = Math.min(stripViewport.restScroll,
                                    stripViewport.width - stripRow.width
                                    - stripViewport.centredX);
                if (lo >= hi)
                  return lo;
                return Math.max(lo, Math.min(hi, v));
            }

            // Two fingers, or the left button held down and dragged. Both end
            // up here.
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.NoButton
              onWheel: wheel => {
                if (!stripViewport.scrollable)
                  return;
                let d = wheel.pixelDelta.x || wheel.pixelDelta.y;
                if (d === 0)
                  d = (wheel.angleDelta.x || wheel.angleDelta.y) / 8 * 3;
                if (d === 0)
                  return;
                panel.stripScroll = stripViewport.clampScroll(panel.stripScroll + d);
                wheel.accepted = true;
              }
            }

            // Dragging the strip's background, not a tile: a DragHandler placed
            // here would take the press from the tiles' own tap handlers, so it
            // is on the empty space behind them and the tiles stay clickable.
            DragHandler {
              id: stripDrag
              target: null
              enabled: stripViewport.scrollable
              property real startScroll: 0
              onActiveChanged: if (active) startScroll = panel.stripScroll
              onCentroidChanged: {
                if (!stripDrag.active)
                  return;
                panel.stripScroll = stripViewport.clampScroll(
                    stripDrag.startScroll + stripDrag.activeTranslation.x);
              }
            }

            // The "+", as macOS has it: a small grey disc at the right-hand end
            // of the strip, not a tile of its own.
            //
            // It was a full-size tile with a big plus in it first, and that was
            // wrong in a way worth naming: at tile size it reads as one more
            // desktop that happens to be empty, which is exactly what it is not.
            // Small, round and set apart, it reads as a control.
            //
            // Anchored to the RIGHT EDGE rather than trailing the last tile, so
            // it stays put while the row scrolls under it -- and so it is in the
            // same place whether you have two desktops or nine.
            //
            // It is also where a window is dropped to send it to a desktop that
            // does not exist yet. One affordance, not two.
            Item {
              id: newDeskCell
              readonly property int deskId: panel.newWorkspaceId
              readonly property real disc: Math.round(panel.stripTileH * 0.30)
              // Disabled, not hidden, at the ceiling. A control that vanishes
              // when you reach a limit does not tell you there was one.
              enabled: panel.desktops.length < root.maxWorkspaces
              z: 10
              anchors.right: parent.right
              anchors.rightMargin: Math.round(panel.stripGap * 1.2)
              // Centred on the TILES, by way of the row they live in, not on the
              // strip. The row is vertically centred and is taller than a tile
              // by the label band under it, so measuring from the strip's top
              // put the disc 9px high -- and further out as the tiles changed
              // size, which is how it was noticed.
              y: stripRow.y + (panel.stripTileH - disc) / 2
              width: disc
              height: disc

              Rectangle {
                id: newDeskDisc
                anchors.fill: parent
                radius: width / 2
                opacity: newDeskCell.enabled ? 1 : 0.35
                // Light, translucent, and unoutlined. It went dark with a white
                // hairline when it started floating over the thumbnails, for
                // contrast, and that is what stopped it looking like a macOS
                // control -- a dark chip with a border reads as a badge stuck
                // onto the strip rather than as part of it.
                //
                // It can afford to be light again because the row now rests
                // with a tile-and-a-half of clear frosted background in front
                // of it. It only meets a thumbnail when the strip is dragged by
                // hand, and losing some contrast for as long as you are holding
                // it is a fair trade for looking right the rest of the time.
                color: panel.dropTarget === newDeskCell.deskId ? Qt.rgba(1, 1, 1, 0.42)
                     : newDeskHover.hovered ? Qt.rgba(1, 1, 1, 0.26)
                                            : Qt.rgba(1, 1, 1, 0.15)
                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on opacity { NumberAnimation { duration: 140 } }

                // Drawn rather than typed. A "+" from the menu font is a
                // typographic plus -- short, thick, and sitting on the text
                // baseline rather than in the middle of the disc.
                Rectangle {
                  anchors.centerIn: parent
                  width: Math.round(parent.width * 0.50)
                  height: Math.max(1, Math.round(parent.width * 0.055))
                  radius: height / 2
                  color: Qt.rgba(1, 1, 1, newDeskHover.hovered && newDeskCell.enabled ? 1.0 : 0.82)
                  Behavior on color { ColorAnimation { duration: 120 } }
                }
                Rectangle {
                  anchors.centerIn: parent
                  height: Math.round(parent.width * 0.50)
                  width: Math.max(1, Math.round(parent.width * 0.055))
                  radius: width / 2
                  color: Qt.rgba(1, 1, 1, newDeskHover.hovered && newDeskCell.enabled ? 1.0 : 0.82)
                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                HoverHandler { id: newDeskHover; enabled: newDeskCell.enabled }

                // A MouseArea, not a TapHandler, and that is the whole reason
                // adding a desktop used to close the overview. The backdrop
                // dismisses on any tap it sees; a TapHandler here does not stop
                // it seeing this one. A MouseArea takes the press outright.
                MouseArea {
                  anchors.fill: parent
                  enabled: newDeskCell.enabled
                  onClicked: root.addWorkspace()
                }

                scale: newDeskHover.hovered ? 1.12 : 1.0
                Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
              }
            }

          Row {
            id: stripRow
            anchors.verticalCenter: parent.verticalCenter
            x: stripViewport.centredX + panel.stripScroll
            Behavior on x {
              enabled: !stripDrag.active
              NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }
            spacing: panel.stripGap

            Repeater {
              model: panel.orderedDesktops

              delegate: Item {
                id: deskCell
                required property var modelData
                // What a drop on this tile means. Read by panel.dropTargetAt,
                // which hit-tests the strip by position rather than by index.
                readonly property int deskId: deskCell.modelData.id
                width: panel.stripTileW
                height: panel.stripTileH + panel.stripLabelBand

                // Workspace order is visual and runtime-only. The handler does
                // not move the Hyprland workspace; it only changes the order
                // in which the strip's model is presented.
                DragHandler {
                  id: deskDrag
                  target: null
                  enabled: root.expanded
                  onActiveChanged: {
                    if (active) {
                      panel.draggingDesktop = deskCell.deskId;
                      return;
                    }
                    const before = panel.reorderTarget;
                    panel.draggingDesktop = -1;
                    panel.reorderTarget = -1;
                    if (before !== deskCell.deskId)
                      panel.reorderDesktop(deskCell.deskId, before);
                  }
                  onCentroidChanged: {
                    if (!deskDrag.active)
                      return;
                    const centre = deskCell.mapToItem(null,
                                                       deskCell.width / 2,
                                                       deskCell.height / 2);
                    panel.reorderTarget = panel.reorderTargetAt(
                        centre.x + deskDrag.activeTranslation.x);
                  }
                }

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

                  // The tile a release right now would move the window to.
                  Rectangle {
                    anchors.fill: parent
                    radius: parent.radius !== undefined ? parent.radius : 0
                    visible: panel.dropTarget === deskCell.deskId
                    color: Qt.rgba(1, 1, 1, 0.16)
                    border.width: 2
                    border.color: Qt.rgba(1, 1, 1, 0.85)
                  }

                  HoverHandler { id: deskHover }
                  TapHandler { onTapped: root.goToWorkspace(deskCell.modelData.id) }

                  // Close badge, in the corner, on hover -- the macOS place for
                  // it and the macOS timing. A permanent one on every tile
                  // would make a row of desktops look like a row of dialogs.
                  //
                  // The last desktop has no badge: removing it would leave
                  // nowhere to be, and a control that refuses is worse than one
                  // that is not there.
                  Rectangle {
                    id: closeBadge
                    visible: panel.desktops.length > 1
                             && (deskHover.hovered || closeHover.hovered)
                    x: Math.round(-width / 3)
                    y: Math.round(-height / 3)
                    // Sized off the tile, so it keeps its proportion as the
                    // strip changes. 0.26 was too heavy against a thumbnail.
                    width: Math.round(panel.stripTileH * 0.19)
                    height: width
                    radius: width / 2
                    // White disc, grey mark. It was the other way round, which
                    // made a grey blob with a white slash in it -- the disc read
                    // as the symbol and the symbol as a hole.
                    color: closeHover.hovered ? "#ffffff" : Qt.rgba(1, 1, 1, 0.92)
                    border.width: 1
                    border.color: Qt.rgba(0, 0, 0, 0.18)
                    opacity: visible ? 1 : 0
                    Behavior on color { ColorAnimation { duration: 120 } }

                    // Drawn, not typed, for the same reason as the "+": the
                    // font's own multiplication sign is not centred on its own
                    // body, so anchors.centerIn puts it visibly off in a disc
                    // this small.
                    Item {
                      anchors.centerIn: parent
                      width: Math.round(parent.width * 0.42)
                      height: width
                      Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: Math.max(1, Math.round(closeBadge.width * 0.085))
                        radius: height / 2
                        rotation: 45
                        color: closeHover.hovered ? Qt.rgba(0.25, 0.25, 0.25, 1)
                                                  : Qt.rgba(0.42, 0.42, 0.42, 1)
                        Behavior on color { ColorAnimation { duration: 120 } }
                      }
                      Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: Math.max(1, Math.round(closeBadge.width * 0.085))
                        radius: height / 2
                        rotation: -45
                        color: closeHover.hovered ? Qt.rgba(0.25, 0.25, 0.25, 1)
                                                  : Qt.rgba(0.42, 0.42, 0.42, 1)
                        Behavior on color { ColorAnimation { duration: 120 } }
                      }
                    }

                    HoverHandler { id: closeHover }

                    // MouseArea, for the same reason as the "+": a TapHandler
                    // does not stop the backdrop's dismiss handler seeing the
                    // same tap, so closing a desktop also closed the overview.
                    MouseArea {
                      anchors.fill: parent
                      // Its windows go to the nearest desktop that is staying,
                      // rather than being closed with it. Nothing here should be
                      // able to lose work.
                      onClicked: {
                        const all = panel.desktops;
                        let fallback = -1;
                        for (let i = 0; i < all.length; i++) {
                          if (all[i].id === deskCell.modelData.id)
                            continue;
                          if (fallback < 0
                              || Math.abs(all[i].id - deskCell.modelData.id)
                                 < Math.abs(fallback - deskCell.modelData.id))
                            fallback = all[i].id;
                        }
                        if (fallback < 0)
                          return;
                        root.removeWorkspace(deskCell.modelData.id,
                                             deskCell.deskWindows, fallback,
                                             !!deskCell.modelData.focused);
                      }
                    }
                  }

                  // A tile being touched by a dragged window springs, rather
                  // than merely lighting up: the overshoot is the part that
                  // reads as "this one is ready to take it".
                  scale: panel.dropTarget === deskCell.deskId ? 1.12
                       : panel.reorderTarget === deskCell.deskId ? 1.08
                       : deskHover.hovered ? 1.03
                                           : 1.0
                  Behavior on scale {
                    NumberAnimation {
                      duration: panel.dropTarget === deskCell.deskId ? 300 : 130
                      easing.type: panel.dropTarget === deskCell.deskId ? Easing.OutBack
                                                                       : Easing.OutCubic
                      easing.overshoot: 2.6
                    }
                  }
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

            // The drag offset is added on top of the layout rather than
            // replacing it, so letting go simply drops it back to zero and the
            // window returns to wherever the overview had put it. Assigning x
            // and y directly would break their bindings for good.
            // Where the drag has put it. Free, it tracks the pointer with just
            // enough smoothing to take the jitter off; over a tile, it is the
            // offset that lands its centre on the tile's centre, and it gets a
            // real animation so the window is seen to travel there.
            readonly property real layoutX: root.expanded ? targetX : realX
            readonly property real layoutY: root.expanded ? targetY : realY
            // No animation on the position: the window tracks the pointer
            // exactly. Smoothing it, even by 60 ms, is what made the drag feel
            // draggy rather than smooth -- the window lagged the cursor and
            // every change of direction showed the lag. All the softness lives
            // in the scale, which is the only thing that should be easing.
            readonly property real dragDX: winDrag.active ? win.freeDX : 0
            readonly property real dragDY: winDrag.active ? win.freeDY : 0
            Behavior on dragScale {
              NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
            }
            transform: Scale {
              origin.x: win.width / 2
              origin.y: win.height / 2
              xScale: win.dragScale
              yScale: win.dragScale
            }
            x: win.layoutX + win.dragDX
            y: win.layoutY + win.dragDY
            z: winDrag.active ? 10 : 0

            // Picked up, the window shrinks. Held over a desktop, it shrinks
            // further -- and that is ALL it does until the button comes up.
            //
            // It used to fly to the tile and take its size, which overshot the
            // idea: the drop looked as though it had already happened, while
            // the window was still in hand and could still be taken somewhere
            // else. Getting smaller over a target says the same thing without
            // claiming it is finished. The window goes in when you let go, and
            // not before.
            readonly property bool overTarget: winDrag.active && panel.dropCell !== null

            // The size it is carried at, and the smaller size it takes over a
            // target. The hit test uses carriedScale and never dragScale: the
            // rectangle that decides whether we are over a tile must not itself
            // depend on being over a tile, or the two define each other.
            readonly property real carriedScale: 0.45
            property real dragScale: !winDrag.active ? 1.0
                                   : win.overTarget ? 0.16
                                                    : win.carriedScale

            // Scaled about the CENTRE, always, so that flying to a tile is a
            // matter of putting that centre on the tile's centre. The cost is
            // that a free drag would slide out from under the pointer as it
            // shrinks, which the (1 - scale) term below cancels: it is the
            // distance the grabbed point moves when the item shrinks about its
            // middle, subtracted back out.
            readonly property real freeDX: winDrag.activeTranslation.x
                + (1 - win.dragScale) * (winDrag.centroid.pressPosition.x - win.width / 2)
            readonly property real freeDY: winDrag.activeTranslation.y
                + (1 - win.dragScale) * (winDrag.centroid.pressPosition.y - win.height / 2)
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
                id: shotView
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

                // Re-request the capture whenever the window changes size.
                //
                // Moving a window off a desktop re-tiles what is left, and the
                // survivors' thumbnails kept the shape they had before: the
                // card grew to the new rect while the picture in it stayed the
                // old one's aspect, so it sat letterboxed inside its own frame
                // with wallpaper showing through the gap. It did not settle --
                // still wrong two seconds later.
                //
                // Hyprland does watch for this: the session listens on the
                // window's resize event and recalculates its constraints. What
                // does not happen is the running capture picking the new size
                // up, so it has to be asked again. Dropping captureSource and
                // putting it back on the next turn of the event loop is how you
                // ask.
                readonly property string sizeKey: win.realW + "x" + win.realH
                onSizeKeyChanged: if (root.shown) reCapture.restart()
                Timer {
                  id: reCapture
                  interval: 0
                  onTriggered: {
                    shotView.captureSource = null;
                    shotView.captureSource = root.shown ? win.modelData.wayland : null;
                  }
                }
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

            // Drag a window onto a desktop in the strip to move it there.
            //
            // `target: null` so the handler reports the gesture instead of
            // moving the item itself -- the item's position is a binding on the
            // overview's layout, and a handler that wrote to it would replace
            // that binding permanently.
            DragHandler {
              id: winDrag
              target: null
              enabled: root.expanded
              onActiveChanged: {
                if (active) {
                  panel.dragging = win.index;
                  return;
                }
                const target = panel.dropTarget;
                panel.dragging = -1;
                panel.dropTarget = -1;
                panel.dropCell = null;
                if (target >= 0 && target !== (panel.currentDesktop ? panel.currentDesktop.id : -1))
                  root.moveWindowToWorkspace(win.modelData.address, target);
              }
              onCentroidChanged: {
                if (!winDrag.active)
                  return;
                // The carried rectangle, in scene coordinates. Scaled about
                // the centre, so that is where it stays.
                const vw = win.width * win.carriedScale;
                const vh = win.height * win.carriedScale;
                const pt = win.parent.mapToItem(null,
                                                win.x + win.width / 2 - vw / 2,
                                                win.y + win.height / 2 - vh / 2);
                panel.dropTarget = panel.dropTargetForRect(pt.x, pt.y, vw, vh);
              }
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
