# CarSurf

Run any installed iOS app on your CarPlay head unit — what CarBridge did,
rebuilt for the iOS 15–18 CarPlay pipeline. Targets **iOS 18.5**, arm64 +
arm64e, rootless.

CarBridge stopped at iOS 13 because CarPlay's UI moved out of SpringBoard
into its own process and the entitlement gate moved into
`CarPlaySupport.framework`. This is a fresh implementation, not a port.

Measured working on iOS 18.5 (iPhone 11, rootless), iOS 16.7.12 (iPhone X,
RootHide), iOS 17.0 (iPhone 13, Dopamine).

## What it does

- **Any app you pick appears on the CarPlay dashboard** with a real, interactive
  `UIWindowScene`. Touch, gestures, keyboard, video, and modals all work — the
  app is running an ordinary second window scene and does not know it is a car.
- **Apps that already support CarPlay show their real interface**, not Apple's
  cut-down template UI. Vietmap, YouTube Music, and Zalo put their full phone app
  on the head unit.
- **The phone keeps its own screen** when the app supports multiple scenes. Apps
  with no `UIApplicationSceneManifest` get transplant mode: the UI moves to the
  car and comes back when you unplug.
- **Per-app Orientation, Layout, and Scale**, over global defaults. Fill the
  landscape area or use a centered 9:16 column, build the UI as iPhone or iPad,
  and scale 0.5×–2×.
- **Nothing is written to the app.** No re-signing, no trustcache, no per-app
  dylib, no backups to restore. App Store updates do not break it.

## How an app gets on the dashboard

Entirely at runtime, from inside SpringBoard and the CarPlay UI processes. The
app's bundle, executable, entitlements, and signature are never touched.

- **iOS 18+** — CarKit decides. CarSurf re-runs CarKit's own declaration factory
  with a narrow stand-in for the entitlement argument, injects a real
  `DBApplicationInfo` into the dashboard roster, and promotes the resulting
  `CRCarPlayAppPolicy`.
- **iOS 15–17** — LaunchServices decides. `CSSceneManifestSpoof.m` answers the
  typed entitlement getters for allowlisted bundles only.

`CSUsesRuntimeCarPlayAdmission()` in `CSSystem.m` picks which one runs. Details
and the list of approaches that broke CarPlay:
[docs/ios18-runtime-carplay-admission.md](docs/ios18-runtime-carplay-admission.md).

An app that ships its own CarPlay interface is bridged too — that interface
is usually cut-down, and putting the real one on the head unit is the point.
CarPlay is never allowed to build a template scene for it: its
`com.apple.developer.carplay-*` entitlements are answered as absent and its
`CPTemplateApplication*` scene roles are hidden, so CarPlay hands it a plain
window scene. Rewriting a template scene *after* CarPlay built one throws
inside `+[UIScene _sceneForFBSScene:create:withSession:connectionOptions:]`
and kills the app on every launch — that crashed Waze and Vietmap on both
16.7.12 and 18.5. The bridge now declines that rewrite and lets the app keep
its own UI for that launch.

`carsurf-helperd` is a small root daemon with one job: mirror preferences to a
relay file that sandboxed apps can read. It does not patch anything.

## Build

```sh
# one-time
git clone --recursive https://github.com/theos/theos.git ~/theos
# install an SDK into ~/theos/sdks (16.5 or newer)
brew install ldid dpkg

export THEOS=~/theos
make package FINALPACKAGE=1
```

The `.deb` lands in `packages/`:

| Path | What |
|------|------|
| `Library/MobileSubstrate/DynamicLibraries/CSSystem.dylib` | SpringBoard + CarPlay UI: dashboard roster, CarKit admission and policy |
| `Library/MobileSubstrate/DynamicLibraries/CSApp.dylib` | every enabled app: scene role rewriting, traits, scaling |
| `Library/PreferenceBundles/CSPrefs.bundle` | Settings pane |
| `Library/LaunchDaemons/com.pavunato.carsurf.helperd.plist` | keeps `carsurf-helperd` running |
| `usr/local/libexec/carsurf-helperd` | writes the preferences relay |
| `usr/local/bin/carsurf-audit` | checks every hooked private symbol still exists on this iOS build |
| `usr/local/bin/carsurf-logs`, `carsurf-classes` | on-device diagnostics. Debug builds also carry `carsurf-apps`, `carsurf-prefstest`, `carsurf-notify` and `carsurf-vehicle`; nothing in the tweak invokes any of them. |

## Install

```sh
scp packages/com.pavunato.carsurf_*.deb root@<device>:/tmp/
ssh root@<device> 'dpkg -i /tmp/com.pavunato.carsurf_*.deb && killall -9 SpringBoard'
```

Then in **Settings → CarSurf**: turn on **Enable CarSurf**, open **Apps**, pick
one app, and turn on **Enable for CarPlay**. It appears on the dashboard live —
no respring, no reconnect.

`libSandy` is recommended, not required — see *Preferences and the sandbox*.

## Verify it works before blaming the car

Run the audit first. It checks on your actual device that every private symbol
the tweak hooks still exists:

```sh
ssh root@<device> carsurf-audit
```

A line marked `[required]` and `MISSING` means bridging cannot work on that build
and the selector names need updating. The tweak skips missing hooks rather than
crashing, so a rename looks like "nothing happens", not a boot loop.

Then watch the hooks land. **iOS ships no `log` binary** (and in zsh `log` is a
shell built-in that silently swallows `log show ...`), so the tweak writes its
own file:

```sh
ssh root@<device> carsurf-logs        # print everything
ssh root@<device> carsurf-logs -c     # clear
```

Turn on **Verbose Logging** in the prefs pane for the detailed stream. A healthy
launch looks roughly like:

```
[system/CarPlay]  CarPlaySupport is now loaded — installing hooks
[applist/CarPlay] app list: 214 installed -> 7 listed (5 genuine CarPlay apps)
[app/YourApp]     bridging enabled for com.example.yourapp
[scene/YourApp]   scene bridge installed (configuration=1, role=1, multiScene=1)
[scene/YourApp]   rewriting scene role CPTemplateApplicationSceneSessionRoleApplication -> UIWindowSceneSessionRoleApplication
[scene/YourApp]   car scene connected (mode=1, scale=1.00)
```

Debugging method, device addresses, and log locations:
[docs/troubleshooting-framework.md](docs/troubleshooting-framework.md).

## If the device will not boot

Injecting into SpringBoard always carries that risk. The tweak reads its kill
switch *before* installing a single hook:

```sh
ssh root@<device> 'touch /var/mobile/Library/Preferences/.carsurf-disable'
```

That disables it entirely without uninstalling. Delete the file to re-enable.
`CS_SAFE=1` in a process's environment does the same for that one process.

## Preferences and the sandbox

Config lives at `/var/mobile/Library/Preferences/com.pavunato.carsurf.plist`.
App sandboxes deny that directory, so `CSApp.dylib` reads it one of two ways:

1. **libSandy** (`SystemGroupContainers` profile) — the clean path.
2. **Relay file** — `carsurf-helperd` and SpringBoard mirror the preferences to
   `/var/jb/Library/CarSurf/relay.plist`, mode 0644 (older installs fall back to
   `/var/tmp/.carsurf-relay.plist`).

If neither works the app-side tweak sees no config, treats itself as disabled,
and installs nothing. A sandbox failure degrades to "the tweak does nothing",
never to undefined behaviour.

## Per-app options

| Option | Default | When to change it |
|--------|---------|-------------------|
| Render Scale | 1.0 | Below 1.0 fits more UI on screen; above 1.0 enlarges controls. |
| Layout | Horizontal | Auto, Horizontal, or a centered 9:16 Vertical viewport. Global and per-app. |
| Interface Idiom | iPhone | Leave on iPhone. Apps that branch on `traitCollection.userInterfaceIdiom` see `.carPlay` otherwise and often render nothing. |

## Known limits

- **Apps with no scene manifest** get transplant mode — the phone goes blank
  until you unplug. A view controller can only belong to one window; duplicating
  the render tree gives a picture you cannot touch.
- **Non-touch head units** (knob/joystick) are not handled. The scene is a plain
  `UIWindowScene`, so it takes touches but has no UIKit focus support.
- **DRM video** may refuse to render on a non-main display. That decision is in
  the media stack, not UIKit.
- **CarPlay's own template apps** are untouched — the tweak only adds scenes.
- **Dashboard-widget and instrument-cluster scene roles** are deliberately left
  alone. A full app UI where the car expects a small widget is not an
  improvement.

## Safety and driving

This renders app UI on a screen in a moving vehicle. CarPlay's app restrictions
exist for a reason. Use it parked.
