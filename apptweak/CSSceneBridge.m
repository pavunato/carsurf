#define CS_TAG "scene"

#import "CSAppInternal.h"
#import <stdatomic.h>
#import "CSLog.h"
#import "CSPrivate.h"
#import "CSRuntime.h"
#import <objc/message.h>

NSString *const CSCarSceneRolePrefix = @"CPTemplateApplicationSceneSessionRole";

// Two role families reach a bridged app:
//
//   UIWindowSceneSessionRoleCarPlay          what the manifest spoof advertises,
//                                            and what Apple's own CarCamera /
//                                            CarRadio / AutoSettings use
//   CPTemplateApplicationSceneSessionRole*   the template role, for apps CarPlay
//                                            already knew about
//
// Neither exists in an ordinary app's Info.plist, so both are rewritten onto the
// app's real window-scene configuration.
NSString *const CSCarPlayWindowSceneRolePrefix = @"UIWindowSceneSessionRoleCarPlay";

BOOL CSIsCarSceneRole(NSString *role) {
    if (![role isKindOfClass:NSString.class]) return NO;
    return [role hasPrefix:CSCarSceneRolePrefix] ||
           [role hasPrefix:CSCarPlayWindowSceneRolePrefix];
}

// The whole tweak turns on this one idea: rather than teach a normal app to speak
// CarPlay's template protocol, we rewrite the *role* of the incoming scene from
// CPTemplateApplicationSceneSessionRoleApplication to the ordinary
// UIWindowSceneSessionRoleApplication. UIKit then resolves the app's own
// Info.plist scene configuration, instantiates a plain UIWindowScene, and hands
// it to the app's real scene delegate. The app renders a full interactive UI on
// the head unit without knowing the display is a car.
//
// Two selectors have to agree on the lie:
//   * -[UISceneConfiguration initWithName:sessionRole:] — so the configuration
//     lookup finds a match in Info.plist instead of throwing.
//   * -[UISceneSession role] — so an app whose delegate branches on the role
//     takes its normal path.

#pragma mark - Bridged scene bookkeeping

/// Whether this process is building for the head unit at all, as opposed to
/// merely having the tweak loaded. True from the moment a car scene's role is
/// rewritten — before the app's delegate has built a window — and false again
/// once the last car scene disconnects.
///
/// CSHasActiveCarScene below answers a different question and is the wrong gate
/// for anything that has to be right during launch: it only becomes true at
/// scene *activation*, by which point an app has already chosen its layout. A
/// plain atomic rather than a count over the weak table, because the idiom
/// override reads this on every trait query.
static atomic_bool gBridgingForCar;

BOOL CSIsBridgingForCar(void) { return atomic_load(&gBridgingForCar); }

/// Sessions whose role we rewrote. Weak, so a disconnected scene's session does
/// not keep anything alive.
static NSHashTable *CSBridgedSessions(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static NSLock *CSBridgeLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

static void CSMarkSessionBridged(id session) {
    if (!session) return;
    NSLock *lock = CSBridgeLock();
    [lock lock];
    [CSBridgedSessions() addObject:session];
    [lock unlock];
    atomic_store(&gBridgingForCar, true);
}

static BOOL CSIsSessionBridged(id session) {
    if (!session) return NO;
    NSLock *lock = CSBridgeLock();
    [lock lock];
    BOOL bridged = [CSBridgedSessions() containsObject:session];
    [lock unlock];
    return bridged;
}

BOOL CSIsBridgedCarScene(UIScene *scene) {
    return scene && CSIsSessionBridged(scene.session);
}

/// Car scenes that have connected and had their geometry applied, keyed on the
/// session's -persistentIdentifier. The lifecycle observer listens for
/// activation rather than connection (the delegate has no window yet at connect
/// time), and activation fires on every foreground, so membership is what keeps
/// the geometry from being recomputed each time the user returns to the app.
///
/// It must be pruned on disconnect. The identifier is *persistent*: a CarPlay
/// host restart tears the scene down and rebuilds it under the same one, so a
/// stale entry silently skips CSCarSceneConnected — no geometry, no mirroring.
/// Device-verified on iphone-11: before the prune, killing the CarPlay host left
/// the surviving app logging the role rewrite for the new scene but never "car
/// scene connected", stuck at the previous scale until the process was killed.
/// Pruning on the disconnect *event* is deliberate rather than keying this on
/// session object identity in a weak table like CSBridgedSessions above: we have
/// not established that a reconnect produces a new session object, and if it
/// reuses the old one — which the stable identifier suggests — object identity
/// would reproduce exactly the bug this prune fixes.
///
/// This set is also the single source of truth for CSHasActiveCarScene. A
/// separate counter used to track the same thing and drifted: it incremented
/// only for scenes that reached CSCarSceneConnected, but decremented for every
/// bridged disconnect, so a scene torn down before it ever activated stole a
/// decrement and could report "no car scene" while one was live.
///
/// Main-thread only, so no lock. UIScene lifecycle notifications are posted on
/// the main thread and both observers register with queue:nil, i.e. delivered
/// synchronously on the posting thread. CSBridgedSessions above does take a lock
/// because it is reached from the -[UISceneSession role] swizzle, which app code
/// can call from any thread.
static NSMutableSet<NSString *> *gConfiguredScenes;

BOOL CSHasActiveCarScene(void) { return gConfiguredScenes.count > 0; }

/// The head unit's screen, for anything that has to be built against the display
/// the app is actually on rather than the sleeping phone (CSDisplayLink.m). Held
/// weakly and read from any thread: a weak load is atomic, and it goes nil on its
/// own if the scene is torn down without a disconnect notification.
static __weak UIScreen *gCarScreen;

UIScreen *CSCarScreen(void) { return gCarScreen; }

static NSString *CSSceneIdentifier(UIScene *scene) {
    return scene.session.persistentIdentifier ?: @"";
}

#pragma mark - Role rewriting

static BOOL gLeavesTemplateScenesAlone = NO;

void CSSetLeavesTemplateScenesAlone(BOOL leaveAlone) {
    gLeavesTemplateScenesAlone = leaveAlone;
}

/// A real template scene this process must not rewrite — see
/// CSSetLeavesTemplateScenesAlone.
static BOOL CSMustLeaveRoleAlone(NSString *role) {
    return gLeavesTemplateScenesAlone && [role isKindOfClass:NSString.class] &&
           [role hasPrefix:CSCarSceneRolePrefix];
}

static BOOL CSBridgingEnabledForThisApp(void) {
    // This is deliberately a live read. The preferences process can remove an
    // app from the allowlist while its process is still hosting a CarPlay
    // scene; caching the first answer would let later CarPlay roles keep being
    // rewritten after the toggle was turned off.
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    return [CSConfig.sharedConfig isBundleEnabled:bundleID];
}

static id (*orig_initWithNameSessionRole)(id, SEL, NSString *, NSString *);

static id cs_initWithNameSessionRole(id self, SEL _cmd, NSString *name, NSString *role) {
    if (!CSIsCarSceneRole(role) || !CSBridgingEnabledForThisApp()) {
        return orig_initWithNameSessionRole(self, _cmd, name, role);
    }
    if (CSMustLeaveRoleAlone(role)) {
        CSLog("leaving scene role %s alone: CarPlay built a real template scene "
                "for this app anyway — rewriting it here is what crashes it at "
                "launch", role.UTF8String);
        return orig_initWithNameSessionRole(self, _cmd, name, role);
    }

    CSLog("rewriting scene role %s -> %s (configuration name: %s)",
            role.UTF8String, UIWindowSceneSessionRoleApplication.UTF8String,
            name.length ? name.UTF8String : "(default)");

    // Drop the configuration name too: it would be a CarPlay-specific name that
    // the app's Info.plist does not contain, and nil means "the default
    // configuration for this role".
    id configuration = orig_initWithNameSessionRole(self, _cmd, nil,
                                                    UIWindowSceneSessionRoleApplication);

    // Belt and braces: even with the role rewritten, pin the scene and delegate
    // classes to the app's window-scene pair so UIKit cannot fall back to a
    // template scene.
    UISceneConfiguration *typed = configuration;
    if ([typed respondsToSelector:@selector(setSceneClass:)]) {
        typed.sceneClass = UIWindowScene.class;
    }
    return configuration;
}

static NSString *(*orig_sessionRole)(id, SEL);

static NSString *cs_sessionRole(id self, SEL _cmd) {
    NSString *role = orig_sessionRole(self, _cmd);
    if (!CSIsCarSceneRole(role) || !CSBridgingEnabledForThisApp()) return role;
    if (CSMustLeaveRoleAlone(role)) return role;

    // Remember this session so the trait and scale code can recognise the car
    // scene later, when its role no longer looks like CarPlay's.
    CSMarkSessionBridged(self);
    return UIWindowSceneSessionRoleApplication;
}

#pragma mark - Multi-scene support

static BOOL (*orig_supportsMultipleScenes)(id, SEL);

static BOOL cs_supportsMultipleScenes(id self, SEL _cmd) {
    if (!CSBridgingEnabledForThisApp()) return orig_supportsMultipleScenes(self, _cmd);
    // The phone scene and the car scene have to coexist; without this UIKit
    // refuses to connect the second one.
    return YES;
}

#pragma mark - Manifest configuration fallback

// Rewriting the role is usually enough, because the app's Info.plist has a
// configuration for the ordinary window-scene role. Apps with no scene manifest
// at all have nothing for UIKit to find, and the lookup throws
// "Info.plist contained no UIScene configuration dictionary". This catches that
// case and hands back the default window-scene configuration instead.

static id (*orig_configurationForRole)(id, SEL, NSString *);

/// +configurationWithName:sessionRole: below can re-enter this lookup. One level
/// of recursion is enough to know the synthesis path is already running.
static _Thread_local BOOL gSynthesizing = NO;

static id cs_configurationForRole(id self, SEL _cmd, NSString *role) {
    id configuration = orig_configurationForRole(self, _cmd, role);
    if (configuration || gSynthesizing || !CSBridgingEnabledForThisApp()) {
        return configuration;
    }

    if (!CSIsCarSceneRole(role) &&
        ![role isEqualToString:UIWindowSceneSessionRoleApplication]) {
        return configuration;
    }

    // Synthesize the configuration UIKit would have built for a plain window
    // scene. delegateClass is left nil: in compatibility mode there is no scene
    // delegate, and CSMirror transplants the UI into the resulting empty scene.
    gSynthesizing = YES;
    UISceneConfiguration *synthetic =
        [UISceneConfiguration configurationWithName:nil
                                       sessionRole:UIWindowSceneSessionRoleApplication];
    gSynthesizing = NO;
    synthetic.sceneClass = UIWindowScene.class;

    CSLog("synthesized a window-scene configuration for role %s", role.UTF8String);
    return synthetic;
}

#pragma mark - Viewport

CGRect CSCarViewportForWindow(UIWindow *window, UIWindowScene *scene,
                              CSAppOptions *options, CGSize sourceSize,
                              BOOL autoHorizontal, UIEdgeInsets *outSafeArea,
                              BOOL *outPortrait) {
    CGRect sceneBounds = scene.coordinateSpace.bounds;

    // Measure against the whole display first: safeAreaInsets only describes the
    // chrome a window actually overlaps, so a window that has already been shrunk
    // reports smaller insets and the rectangle would creep inward on every pass.
    window.layer.transform = CATransform3DIdentity;
    window.frame = sceneBounds;
    [window layoutIfNeeded];

    // Inset by every edge, not just the leading one: a landscape head unit puts
    // CarPlay's chrome in a left sidebar, a portrait unit puts it along the
    // bottom, and some units add a status strip on top.
    UIEdgeInsets safeArea = window.safeAreaInsets;
    CGRect usableFrame = UIEdgeInsetsInsetRect(sceneBounds, safeArea);
    if (usableFrame.size.width < 1.0 || usableFrame.size.height < 1.0) {
        // Insets that consume the display are not describing chrome. Trust the
        // display instead of handing the app a one-point window.
        CSLog("car scene reported unusable safe area (l=%.0f t=%.0f r=%.0f b=%.0f) "
                "for a %.0fx%.0f display — using the full display",
                safeArea.left, safeArea.top, safeArea.right, safeArea.bottom,
                sceneBounds.size.width, sceneBounds.size.height);
        safeArea = UIEdgeInsetsZero;
        usableFrame = sceneBounds;
    }

    BOOL portrait = options.layoutMode == CSLayoutModeVertical ||
                    (options.layoutMode == CSLayoutModeAuto && !autoHorizontal &&
                     sourceSize.height > sourceSize.width);

    // A physically portrait head unit already *is* a vertical viewport, so fill
    // what the car gave us. Only a landscape display needs a 9:16 column carved
    // out of it — doing that on a portrait screen wastes both sides.
    if (portrait && usableFrame.size.width > usableFrame.size.height) {
        CGFloat portraitWidth = usableFrame.size.height * (9.0 / 16.0);
        usableFrame.origin.x += (usableFrame.size.width - portraitWidth) * 0.5;
        usableFrame.size.width = portraitWidth;
    }

    // Every input to the decision, because a viewport that comes out wrong is
    // otherwise indistinguishable from an app that lays out wrong. A head unit
    // has been seen reporting a 240pt-tall screen where it reports 360 in every
    // other session, which sizes the window to two thirds of the display and
    // makes a fullscreen video overflow it.
    UIScreen *screen = scene.screen;
    CGRect nativeBounds = screen.nativeBounds;
    CGSize modeSize = screen.currentMode.size;
    CSLog("viewport %.0fx%.0f at (%.0f,%.0f) from scene %.0fx%.0f "
          "(screen %.0fx%.0f, native %.0fx%.0f @%.1fx, mode %.0fx%.0f, "
          "safe l=%.0f t=%.0f r=%.0f b=%.0f, portrait=%d)",
          usableFrame.size.width, usableFrame.size.height,
          usableFrame.origin.x, usableFrame.origin.y,
          sceneBounds.size.width, sceneBounds.size.height,
          screen.bounds.size.width, screen.bounds.size.height,
          nativeBounds.size.width, nativeBounds.size.height, screen.scale,
          modeSize.width, modeSize.height,
          safeArea.left, safeArea.top, safeArea.right, safeArea.bottom, portrait);

    if (outSafeArea) *outSafeArea = safeArea;
    if (outPortrait) *outPortrait = portrait;
    return usableFrame;
}

void CSNeutralizeResidualSafeArea(UIWindow *window) {
    UIViewController *root = window.rootViewController;
    if (!root) return;

    // The window now sits entirely inside the safe rectangle, so anything UIKit
    // still reports is the same chrome counted twice — it shows up as a status-bar
    // strip across the top of the app's content and a matching gap at the bottom.
    // Cancel exactly what is left over, measured rather than assumed, so a head
    // unit that reports nothing here is left alone.
    root.additionalSafeAreaInsets = UIEdgeInsetsZero;
    [window layoutIfNeeded];

    UIEdgeInsets residual = window.safeAreaInsets;
    if (residual.top < 0.5 && residual.left < 0.5 &&
        residual.bottom < 0.5 && residual.right < 0.5) {
        return;
    }

    root.additionalSafeAreaInsets = UIEdgeInsetsMake(-MAX(0.0, residual.top),
                                                     -MAX(0.0, residual.left),
                                                     -MAX(0.0, residual.bottom),
                                                     -MAX(0.0, residual.right));
    [window layoutIfNeeded];
    CSVLog("cancelled doubled safe area l=%.0f t=%.0f r=%.0f b=%.0f (content now "
             "l=%.0f t=%.0f r=%.0f b=%.0f)",
             residual.left, residual.top, residual.right, residual.bottom,
             root.view.safeAreaInsets.left, root.view.safeAreaInsets.top,
             root.view.safeAreaInsets.right, root.view.safeAreaInsets.bottom);
}

#pragma mark - Scale

void CSApplyScaleToCarScene(UIWindowScene *scene, CSAppOptions *options) {
    CGFloat scale = options.scale > 0.01 ? options.scale : 1.0;

    for (UIWindow *window in scene.windows) {
        CGRect sceneBounds = scene.coordinateSpace.bounds;
        if (sceneBounds.size.width <= 0 || sceneBounds.size.height <= 0) continue;
        CGSize originalSize = window.bounds.size;

        UIEdgeInsets safeArea = UIEdgeInsetsZero;
        BOOL portrait = NO;
        CGRect visibleFrame = CSCarViewportForWindow(window, scene, options,
                                                     originalSize, NO,
                                                     &safeArea, &portrait);

        // Grow the window's logical size by 1/scale and shrink it visually by
        // scale: the app lays out for a larger canvas, and the result is
        // fitted inside the selected viewport. scale < 1 shows more UI.
        window.frame = visibleFrame;
        window.bounds = CGRectMake(0, 0, visibleFrame.size.width / scale,
                                   visibleFrame.size.height / scale);
        window.layer.anchorPoint = CGPointZero;
        window.layer.position = visibleFrame.origin;
        window.layer.transform = CATransform3DMakeScale(scale, scale, 1.0);

        CSVLog("configured car window to %.0fx%.0f at (%.0f,%.0f), %.2fx, portrait=%d, "
                 "display %.0fx%.0f, safe l=%.0f t=%.0f r=%.0f b=%.0f",
                 window.bounds.size.width, window.bounds.size.height,
                 window.layer.position.x, window.layer.position.y, scale, portrait,
                 sceneBounds.size.width, sceneBounds.size.height,
                 safeArea.left, safeArea.top, safeArea.right, safeArea.bottom);

        CSNeutralizeResidualSafeArea(window);
    }
}

#pragma mark - Scene lifecycle

static void CSCarSceneConnected(UIScene *scene) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    CSAppOptions *options = [CSConfig.sharedConfig optionsForBundle:bundleID];

    CSBridgeMode mode = options.mode;
    if (mode == CSBridgeModeAuto) {
        mode = CSAppIsSingleWindowOnly() ? CSBridgeModeMirror : CSBridgeModeScene;
    }

    CSLog("car scene connected (mode=%ld, scale=%.2f, layout=%ld)",
            (long)mode, options.scale, (long)options.layoutMode);

    if (![scene isKindOfClass:UIWindowScene.class]) {
        CSLog("car scene is a %s, not a UIWindowScene — role rewrite did not "
                "take effect; nothing to present", object_getClassName(scene));
        return;
    }

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    gCarScreen = windowScene.screen;

    // Installed here, not from the dylib constructor: reaching UIScreen that
    // early — even through class_getInstanceMethod — runs +[UIScreen initialize],
    // which blocks in -[_UIApplicationConfigurationLoader _loadInitializationContext]
    // on a dispatch_once UIKit has not reached yet, and the app dies on the
    // 20-second launch watchdog. Device-verified, twice.
    static dispatch_once_t displayLinkOnce;
    dispatch_once(&displayLinkOnce, ^{ CSInstallDisplayLinkBridge(); });
    if (mode == CSBridgeModeMirror) {
        CSStartMirroringIntoScene(windowScene, options);
    } else {
        // The app's own scene delegate has already built its UI by now; all that
        // is left is the geometry adjustment.
        CSApplyScaleToCarScene(windowScene, options);
    }
}

static void CSCarSceneDisconnected(UIScene *scene) {
    // Drops this session out of CSHasActiveCarScene and lets a reconnect of the
    // same session be treated as a fresh scene that gets its geometry applied.
    [gConfiguredScenes removeObject:CSSceneIdentifier(scene)];
    if (gConfiguredScenes.count == 0) atomic_store(&gBridgingForCar, false);
    gCarScreen = nil;
    CSLog("car scene disconnected");
    CSStopMirroring();
}

static void CSObserveSceneLifecycle(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    // Activation, not connection: at connect time the app's scene delegate has
    // not yet created its window, so there would be nothing to scale.
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        UIScene *scene = note.object;
        NSString *identifier = CSSceneIdentifier(scene);
        BOOL bridged = CSIsBridgedCarScene(scene);
        // Every early return below is otherwise indistinguishable from the
        // notification never arriving: all three look like silence. That
        // ambiguity is what made the reconnect bug above expensive to find.
        CSVLog("scene activated %s (bridged=%d, already configured=%d)",
               identifier.UTF8String, bridged,
               [gConfiguredScenes containsObject:identifier]);
        if (!bridged) return;
        if (!gConfiguredScenes) gConfiguredScenes = [NSMutableSet new];
        if ([gConfiguredScenes containsObject:identifier]) return;
        [gConfiguredScenes addObject:identifier];
        CSCarSceneConnected(scene);
    }];

    [center addObserverForName:UISceneDidDisconnectNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        UIScene *scene = note.object;
        BOOL bridged = CSIsBridgedCarScene(scene);
        CSVLog("scene disconnected %s (bridged=%d)",
               CSSceneIdentifier(scene).UTF8String, bridged);
        if (!bridged) return;
        CSCarSceneDisconnected(scene);
    }];
}

#pragma mark - Install

void CSInstallSceneBridge(void) {
    BOOL configuration = CSSwizzleInstanceMethod(
        UISceneConfiguration.class, @selector(initWithName:sessionRole:),
        (IMP)cs_initWithNameSessionRole, (IMP *)&orig_initWithNameSessionRole);

    BOOL role = CSSwizzleInstanceMethod(
        UISceneSession.class, @selector(role),
        (IMP)cs_sessionRole, (IMP *)&orig_sessionRole);

    Class manifest = CSLookupClass("UIApplicationSceneManifest");
    BOOL multiScene = CSSwizzleInstanceMethod(
        manifest, @selector(supportsMultipleScenes),
        (IMP)cs_supportsMultipleScenes, (IMP *)&orig_supportsMultipleScenes);

    // The lookup selector has moved across releases; take whichever exists.
    static const char *const kRoleLookupSelectors[] = {
        "configurationForRole:", "sceneConfigurationForRole:", "_configurationForRole:",
    };
    for (size_t i = 0; i < sizeof(kRoleLookupSelectors) / sizeof(*kRoleLookupSelectors); i++) {
        SEL sel = sel_getUid(kRoleLookupSelectors[i]);
        if (!CSHasInstanceMethod(manifest, sel)) continue;
        CSSwizzleInstanceMethod(manifest, sel, (IMP)cs_configurationForRole,
                                  (IMP *)&orig_configurationForRole);
        break;
    }

    CSObserveSceneLifecycle();

    CSLog("scene bridge installed (configuration=%d, role=%d, multiScene=%d)",
            configuration, role, multiScene);

    if (!configuration && !role) {
        CSLog("WARNING: neither role-rewrite hook landed; this app cannot be "
                "bridged. Run tools/carsurf-audit on this device.");
    }
    if (!multiScene) {
        CSLog("WARNING: UIApplicationSceneManifest.supportsMultipleScenes not "
                "hooked; the car scene may be refused while the app is on screen.");
    }
}
