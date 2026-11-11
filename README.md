# SnowStorm

A menu bar app for macOS that makes it snow over your desktop. Snow settles on windows, desktop icons, widgets, the menu bar and the Dock. A snowman builds himself on the Dock.

## Features

- **Snow over everything, click-through.** A transparent overlay sits on every screen and every Space, including full-screen apps. Clicks pass straight through to your apps.
- **Corners bank up.** On rounded windows, widgets and the Dock, a full pile fills about half of the corner's curve, so it's a little squarer than the surface underneath.
- **Snow that settles.** Piles build up on window tops, desktop icons, widgets and the Dock, with a deeper bank on the Dock. A light dusting clings to the menu bar and melts after a while.
- **A snow bank along the bottom of the screen.** Snow builds up along the bottom edge of every display, up to about 18 pt deep, like snow gathering at the bottom of a window pane. It sits in front of app windows (so it shows even with maximized windows) but behind the Dock. Every falling flake can settle there, and clumps spilling off windows and the Dock land in it too. Toggle it under Snow Lands On › Bottom of Screen.
- **Snow respects stacking.** Snow on a window that's behind another one is hidden, and it comes back when that window comes to the front.
- **Window physics.** Drag a window and its snow slides off and tumbles down. Close it and the whole pile drops at once.
- **Piles spill over.** A full pile sheds clumps, mostly off its rounded corners. Clumps that fall onto a window, widget, icon or the Dock below settle there and can set off a spill in turn.
- **Icicles.** Leave a snowy window still and icicles grow along its bottom edge. Moving the window snaps them off.
- **The snowman.**
  - He builds himself: three snowballs roll onto the Dock and stack up, then he puts on a scarf and waves.
  - Every so often he throws a snowball at a window, an icon or the Dock. It sticks, slides down and melts.
  - Click him to burst one snowball at a time. Hitting the bottom drops him a level. Hitting the middle makes his head tumble into the snow.
  - After a while he melts: the carrot falls, the head slides off, and he slumps into the snow. Later a new one builds.
- **Menu bar controls:**
  - Snowing on or off
  - Intensity: Light, Normal or Blizzard
  - Snowman, Snowballs from the Snowman, and Icicles toggles
  - A per-surface "Snow Lands On" submenu (windows, desktop icons, widgets, menu bar, Dock, bottom of screen)
  - Shake Off All Snow
  - Start at Login
- **Rests when idle.** When nothing is moving it drops to 5 fps, about 2–3% CPU. Normal snow measured about 11% CPU on a two-display Mac (120 Hz + 75 Hz). Snow runs at a rate that divides each display's refresh evenly so nothing judders: about 24 fps for gently drifting snow, about 40 fps in a blizzard or while the snowman moves, and 60 fps only for quick motion such as thrown snowballs or a window shedding its pile. Window and Accessibility polling run off the main thread, so a slow app can't freeze the snow on any screen.

## Permissions

- **Accessibility (optional).** SnowStorm asks for this once, on first launch. It's needed to find the exact Dock frame and desktop icon positions. Without it, snow still lands on windows and widgets, and the Dock position is estimated. SnowStorm reads only positions and sizes, never window contents or keystrokes.
- **No Screen Recording permission is needed.** Window bounds come from `CGWindowListCopyWindowInfo`, which doesn't require it.

## Build and run

Requirements: macOS 14 or later, and Xcode or the Command Line Tools (Swift 5.9+).

```bash
./build.sh          # builds build/SnowStorm.app (ad-hoc signed)
./build.sh --run    # builds, then relaunches it
```

To install, drag `build/SnowStorm.app` into `/Applications`. Start at Login only works when you run the `.app` bundle.

> Each ad-hoc-signed rebuild gets a new code signature. macOS may then forget the Accessibility grant, so remove SnowStorm and re-add it under System Settings › Privacy & Security › Accessibility.

### Developer previews

```bash
.build/release/SnowStorm --preview /tmp/snow.png      # simulates snow over fake windows and writes PNGs
.build/release/SnowStorm --render-icon /tmp/icon.png  # renders the 1024px app icon
open build/SnowStorm.app --args --dump-widgets /tmp/w.txt  # lists widget windows + Notification Centre AX tree
open build/SnowStorm.app --args --frame-log /tmp/frames  # writes per-screen frame gaps (ms) after ~2400 entries
SNOW_SKVIEW=1 .build/release/SnowStorm                 # old SKView renderer, for comparison
```

## Layout

| File | Role |
|---|---|
| `AppDelegate.swift` | Status item, menu, overlays per screen, login item, permission prompt |
| `SurfaceTracker.swift` | Polls window bounds (every 150 ms) and the Dock and desktop icons via AX (every 2 s) |
| `SnowScene.swift` | SpriteKit scene: flakes, height-map piles, occlusion, shedding, icicles, debris, snowballs |
| `Snowman.swift` | Snowman lifecycle: build, wave, throw, click reactions, melt |
| `SnowRenderView.swift` | Draws the scene with SKRenderer into a Metal layer, paced by each screen's own display link (smooth on ProMotion) |
| `OverlayController.swift` | Click-through overlay window, plus the small panel that makes only the snowman clickable |
| `Settings.swift` | Settings stored in UserDefaults |
| `Art.swift` | Flake texture, menu bar icon and app icon, all drawn in code |

## Privacy

SnowStorm makes no network connections, has no analytics, and stores only its settings, locally in UserDefaults.

## License

MIT, see [LICENSE](LICENSE). All art (flakes, icons, the snowman) is drawn in code, so there are no third-party assets.
