# CarSurf — TODO

`[ ]` open, `[x]` done — kept for the reasoning.

## Open

- [ ] **No auto-horizontal-on-video geometry (regressed 0.2.6).** Removing
  `CSFullscreen.m` dropped the YouTube-only behavior that widened Auto-mode
  mirroring to full horizontal while a video player was active, with nothing
  general replacing it. Revisit if Auto-mode video layout is wanted back —
  ideally via a signal that doesn't require naming the app's view controller
  classes (e.g. `AVPlayerViewController` presentation/fullscreen state).
- [ ] **Customize list omits CarSurf apps.** The CRS fetch wrapper is off (it
  crashed native CarPlay — see below), so Settings > Customize shows only the
  12 Apple icons; apps still show on the dashboard. Needs a list update that
  preserves the fetched objects instead of rebuilding them.
- [ ] **`multiScene=0`** — `UIApplicationSceneManifest` is missing on iOS 18.5,
  so multi-scene hooks never install. Only single-scene bridging works.
- [ ] **Dashboard refresh storm** — old `refresh → invalidation → relay updated`
  oscillation. Invalidation is gone from the toggle path; re-check.
- [ ] **README install glob** still lands on the stale `0.2.0-1-93` package.
- [ ] **PAC crash** — improved but unconfirmed. Synthetic roster entries are
  pinned alive (`gPinnedRosterInfos`), and the in-place path pins the
  `DBApplicationInfo`/`DBApplication` it loads. Clean in Simulator toggling;
  still needs a connected-car run.

## Done — keep the reasoning

- [x] **Generic transplant compatibility replaces the YouTube-only fullscreen
  hack (0.2.6).** `CSFullscreen.m` swizzled `YTWatchViewController` /
  `YTWatchFullscreenViewController` lifecycle methods by name to flip the
  mirror window between Auto's horizontal and vertical geometry while a video
  player was on screen — useless for every other single-window-compat app,
  and one more thing that breaks silently when YouTube renames a class.
  Deleted, along with `CSSetMirroringVideoActive` and the
  `gAutoHorizontalApplied` state it drove.

  In its place, `CSMirror.m` installs app-agnostic compatibility shims once a
  transplant starts:
  - `-[UIWindow rootViewController]` is swizzled so reads through the now-empty
    *source* window alias to the transplanted root — compatibility-mode apps
    that cache `delegate.window` and re-read its `rootViewController` (instead
    of holding the controller directly) keep seeing their real UI instead of
    `nil`. Only applies while that exact root is actively transplanted; never
    touches `UIApplication.keyWindow` or redirects presentation.
  - `applicationDelegate.window` itself is reassigned from the source window to
    the car window for the duration of the transplant (restored on
    `CSStopMirroring`), so newly built controllers that read `.window.windowScene`
    or `.window.traitCollection` pick up the car scene instead of the detached
    phone one.
  - `viewDidAppear:` / `viewDidDisappear:` / `presentViewController:` /
    `dismissViewController:` are swizzled for diagnostic logging only (view
    hierarchy snapshots, controller-transition frames) — no behavior change —
    so a future compat bug report on some other app has the same evidence the
    YouTube investigation used to build this, without needing a per-app hook.

  Net effect: the auto-horizontal-on-video-playback behavior is gone (no
  general replacement shipped yet — nothing else fills that gap), but mirror
  compatibility for single-window apps is no longer YouTube-specific.

- [x] **Geometry never re-applied after a CarPlay reconnect (0.2.4).** This was
  the real defect behind "first scene ignores the display setting", and the
  symptom was described backwards in the old entry: reconnecting CarPlay did
  not *fix* it, reconnecting CarPlay *caused* it. Geometry is applied from
  `CSCarSceneConnected` on `UISceneDidActivateNotification`, deduped by a set
  keyed on `scene.session.persistentIdentifier` — and that set was never pruned
  on disconnect. The identifier is *persistent*, so when a session tears down
  and comes back the stale entry silently skipped the handler: no geometry, no
  mirroring, and `gActiveCarScenes` decremented without a matching increment.
  Only killing the app cleared it, which is exactly why "close and reopen"
  appeared to be the cure. Fix: the set moved to file scope as
  `gConfiguredScenes` and `CSCarSceneDisconnected` removes the identifier.

  Device-proven on iphone-11 with a live CarPlay Simulator session, same repro
  either side of the fix — kill the CarPlay host, then re-launch the app on the
  display while its process survives:
  - 0.2.3, app pid 7167 survived: only `car scene disconnected` and `rewriting
    scene role …`. The role hook fired for the new scene, so it *did* connect,
    but `car scene connected` never logged.
  - 0.2.4, app pid 7356 survived: `car scene disconnected` → `car scene
    connected (mode=1, scale=0.50, layout=1)` → `configured car window to
    1190x720 at (45,0), 0.50x`.

  Review by Fable raised a fair objection: `CSMarkSessionBridged` has exactly one
  call site, in the `-[UISceneSession role]` swizzle, and the `rewriting scene
  role` line comes from the *configuration* hook — so "bailed at
  `CSIsBridgedCarScene`" and "bailed at the dedupe check" were indistinguishable
  in that evidence. Both observers now log on entry (0.2.5), which answers it
  directly instead of by elimination:
  `scene activated Car[2-3]:com.google.ios.youtubemusic (bridged=1, already
  configured=0)` on the reconnect. Same identifier byte-for-byte either side of
  the teardown — the reuse the diagnosis depended on, now observed rather than
  assumed — with `bridged=1` proving the session *was* re-marked and activation
  *does* fire again on reconnect.

  Two further fixes from that review (0.2.5):
  - `gActiveCarScenes` is gone. It incremented only for scenes that reached
    `CSCarSceneConnected` but decremented for every bridged disconnect, so a
    scene torn down before it ever activated stole a decrement and could leave
    `CSHasActiveCarScene()` — which gates all of `CSKeyboard` — reporting NO
    while a scene was live. It was a second representation of what
    `gConfiguredScenes` already knows, so the counter was deleted rather than
    repaired.
  - Declined the suggestion to re-key the set to session object identity in a
    weak table. The identical identifier across the teardown indicates the
    session is reused, so object identity would very likely reproduce the same
    stale-entry bug; pruning on the disconnect *event* does not depend on that
    assumption. The reasoning is recorded at the declaration.

- [x] **Per-app options are not dead for App Store apps — premise disproven
  (2026-08-18).** The long-standing suspicion that per-app settings never reach
  a sandboxed app was wrong, as were both earlier candidates (`CSApp.dylib` not
  injected; `CSLogFilePath` mis-selecting a path). What was actually broken was
  only the *reporting*: `CSVerboseEnabled` in `shared/CSLog.m` checked two
  sandbox-denied paths and never `/var/jb/Library/CarSurf/relay.plist` — the one
  candidate an app sandbox can read, and the one `CSConfig` was already reading
  successfully in the same process. Every log macro is gated on it, so app-side
  logging was a runtime no-op in exactly the apps the tweak exists for.
  `CSConfigLocation` now owns the paths and the change notification for all five
  call sites that had grown private copies, and `CSVerboseEnabled` re-reads on
  `com.pavunato.carsurf/reload` (it was a bare `dispatch_once` with no observer,
  so toggling verbose logging did nothing until the process restarted).

  With logging alive, the geometry path measured clean end to end. YouTube Music
  is configured `{enabled=1, scale=0.5}` with no `idiomMode`; `defaults` is
  `{idiomMode=2, scale=0.7296417}`. A cold launch driven from the CarPlay side
  produced `car scene connected (mode=1, scale=0.50, layout=1)` and `configured
  car window to 1190x720 at (45,0), 0.50x, display 640x360, safe l=45` — the
  per-app scale and the defaults idiom resolving correctly from two different
  sources. Changing the value to 0.85 and firing the reload gave `700x424 at
  0.85x` on the next cold launch (595/0.85, 360/0.85). No stale cache; the
  `CSOptionsForThisApp` `dispatch_once` in `CSTraits` was not implicated.

  Note the one real limitation this exposed: geometry is applied once per scene
  connect, so editing scale or idiom does **not** re-flow a live car scene. The
  app has to be relaunched. Worth deciding whether the reload notification
  should re-apply geometry to an already-connected scene.

- [x] **Manifest role spoof no longer installs in `carkitd` (0.2.3).**
  `CSSystem.plist` filters in `carkitd`, and on iOS 18 `CSInstallCarPlayHooks`
  took the `else` branch and swizzled `-[LSBundleProxy
  objectForInfoDictionaryKey:ofClass:]` process-wide there.
  [ios18-runtime-carplay-admission.md](ios18-runtime-carplay-admission.md)
  lists hooking anything in `carkitd` as a hard rule — an earlier LS-accessor
  hook there put the head unit into an endless connecting loop. No loop was
  observed with this one, but the launch broker runs in SpringBoard and the
  CarPlay hosts, so the daemon gained nothing from it. Now gated on
  `CSIsCarKitDaemon()`; verified on device 2026-08-18, carkitd restarts clean
  and logs `manifest role spoof withheld` while SpringBoard still installs it.
  This is stricter than `CSCarKitPolicy`'s observe-only treatment of the same
  daemon, deliberately: that hook is one low-frequency class method, this one
  is a general info-dictionary accessor. Still wants a connected-car run.

- [x] **On-disk patching removed from `helperd` (0.1.4-27-19).** Runtime
  admission covers every supported release, so the daemon no longer patches,
  re-signs, trustcaches, backs up, or reverts anything. `carsurf-helperd.m`
  went 988 → ~127 lines, now just the preferences relay. The per-app "Patch
  Now" UI and the `ldid`/`uikittools` Depends are gone.
  `CSUsesRuntimeCarPlayAdmission()` is unchanged — it still selects the
  per-release admission hook, and the full `CSInstallSceneManifestSpoof` would
  crash-loop SpringBoard on 18.5. Bundles patched by older builds are left
  alone; there's no automatic revert.
- [x] **Live enable/disable without a reload (0.1.4-27).** Toggling mutates
  `DBApplicationController` in place (`_loadApplicationWithInfo:` /
  `_removeApplicationWithBundleIdentifier:`) and fires `_didAddApplications:` /
  `_didRemoveApplications:`. The grid re-renders live — no
  `FBSApplicationLibrary` invalidation, reflow, or re-sort. Whole-library
  invalidation is now only for a genuine uninstall. User-verified: 15 in-place
  events, 0 crashes, CarPlay on one pid throughout.
- [x] **Enabled-app launch crash (0.1.4-27-17).** Toggling an app off→on then
  launching it aborted the CarPlay host. Cause: the in-place re-enable path
  leaves the icon backed by a thin `DBApplication` wrapper exposing only
  `-info`/`-bundleIdentifier`/`-appPolicy`, while DashBoard sends it the whole
  `FBSApplicationInfo` identity family (`applicationIdentity`,
  `processIdentity`, `signerIdentity`, `carPlayDeclaration`) — all living on
  `-info`. A full reload never crashed because native startup caches the
  launch identity. Fix: one `-forwardingTargetForSelector:` on `DBApplication`
  forwards anything the wrapper lacks to `-info`, leaving
  `-respondsToSelector:` at `NO` so native feature-detection is unchanged.
- [x] **Icon flicker on re-enable (0.1.4-27-18).** After re-enabling, the icon
  flickered for ~1 minute: disable and re-enable each started a
  `CSVerifyHiddenDeltaAfterDelay` chain carrying a *frozen* delta, and they
  replayed opposite states against each other. Fix: each reassertion prunes
  its delta against the live enabled set at fire time and stops once a newer
  toggle supersedes it. The retry chain itself stays — DashBoard reconciles
  hidden writes back to all-visible on reconnect.
- [x] **CRS fetch interception crash.** Launchd recorded `CarPlayApp`
  `SIGSEGV` in the native `DBIconLayoutVehicleDataProvider
  getIconStateWithCompletion:` path while the CRS fetch wrapper was installed.
  Keep the fetch hook off until a read path that doesn't reconstruct state is
  designed.
- [x] **Customize empty on relaunch.** DashBoard's own `setIconState` can
  write an empty `pages[0]` at startup. CarSurf now restores that vehicle's
  persisted `*-CarDisplayIconState.plist` into native CRS icon objects when a
  fresh process has no snapshot.
- [x] **Config-to-scene reactivity.** The app-side CarPlay gate reads the
  current allowlist instead of its launch-time value, and a live CarPlay
  scene exits when the global or per-app toggle goes off. Phone-only app
  processes aren't killed. Teardown timing still wants one check on a
  connected vehicle.

## North star — reached

Runtime admission only. No on-disk app mutation, no trustcache, no per-app
dylib. The version that survives App Store updates.
