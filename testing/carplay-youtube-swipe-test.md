# YouTube swipe reproduction — 2026-09-11

Verified on iphone-11 with 0.2.9-11+debug and CarPlay Simulator.

```sh
bash testing/carplay-youtube-repro.sh 1050 330 1000 400 290
```

Arguments are absolute macOS screen points: thumbnail x/y, swipe x,
bottom y, top y. These coordinates were verified with the main simulator
window at (663,129), size 760×769. Recalibrate after moving/resizing the
window or changing the app layout. They are not portable defaults.

The script launches YouTube over SSH, waits 3 seconds, clicks a thumbnail,
waits 3 seconds, drags up, waits 3 seconds, then drags down. It captures
before/after device logs and a diff without clearing existing logs.
Ensure the feed is loaded first: a cold launch did not reliably become
interactive within the requested 3 seconds. Script exit 0 only confirms
input execution, not video/fullscreen success; inspect the transition logs.

## Successful device evidence

- 15:37:17: watch page opened; player size 731×411.
- 15:37:20: upward touch (424.5,344.1) → (424.5,174.4) in app coordinates
  hit the player overlay; YTUpForFullController's pan recognizer was changing.
- 15:37:21: YTWatchFullscreenViewController hosted the watch controller;
  player size became 1063×798.
- 15:37:23–24: downward touch followed the reverse path;
  YTExitFullscreenController's pan recognizer was changing.
- 15:37:25: watch controller returned to YTWatchLayerViewController, with
  no presented/presenting controller; player returned to 731×411.
  The existing fullscreen-dismissal size repair also ran.

Artifacts for that run:
`/var/folders/gc/76sq5tcx35jdfj40g7lwtc740000gn/T/carsurf-youtube.aqvUnu/`

## Why earlier runs were inconclusive

The original y=460 start maps to app y≈437, below the 411-point player.
In a separate cold-start run, the thumbnail click did not open a watch page;
both drags reached the feed's scroll recognizer. Correcting readiness and
targeting reproduced successful fullscreen entry and exit without changing
YouTube gesture behavior. This does not establish the cause of every manual
swipe failure or verify the rendered video visually: macOS screen capture
was unavailable during these runs.

Debug builds now trace car-window touch starts/ends at UIApplication's event
entry point, including hit-view ancestry and recognizer states before dispatch.
The observer does not install recognizers or alter gesture decisions. Release
builds omit it. The macOS input helper also pauses briefly after posting mouse-up.
