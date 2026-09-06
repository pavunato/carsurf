#define CS_TAG "app"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <notify.h>
#import <stdlib.h>
#import <Security/Security.h>

// SecTask.h ships on macOS but not in the public iOS SDK, even though the
// symbols are real exports of the iOS Security.framework this process already
// links. Declare just what's needed rather than pull in a private header.
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement,
                                                CFErrorRef *error);

// Injected into every UIKit process, so the first job is to get out of the way
// again as fast as possible. Only a process that is (a) a real app, (b) not part
// of the system UI, and (c) on the user's allowlist installs a single hook.

static BOOL CSProcessIsBridgeableApp(void) {
    NSBundle *main = NSBundle.mainBundle;
    NSString *bundleID = main.bundleIdentifier;
    if (bundleID.length == 0) return NO;

    // SpringBoard and the CarPlay hosts get the system-side dylib, not this
    // app bridge. Preferences is deliberately not excluded: when the user
    // enables it, CarPlay must receive the same plain-window bridge as any
    // other admitted app; all bridge/keyboard/trait changes remain gated on a
    // live CarPlay scene, so ordinary phone Settings is left alone.
    static NSSet *excluded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        excluded = [NSSet setWithArray:@[
            @"com.apple.springboard",
            @"com.apple.CarPlayApp",
            @"com.apple.CarPlayTemplateUIHost",
        ]];
    });
    if ([excluded containsObject:bundleID.lowercaseString] ||
        [excluded containsObject:bundleID]) {
        return NO;
    }

    // Extensions, daemons and XPC services share UIKit but can never own a
    // CarPlay scene.
    NSString *path = main.bundlePath;
    if ([path hasSuffix:@".appex"] || [path hasSuffix:@".xpc"]) return NO;
    if (main.infoDictionary[@"NSExtension"]) return NO;

    return YES;
}

/// Every enabled app is bridged, native CarPlay support or not: putting the
/// app's own phone interface on the head unit is the entire point of the tweak,
/// and an app that ships a CarPlay template UI needs it more than most, not
/// less — that UI is usually a cut-down version of the app.
///
/// What makes it safe for a native app is that CSSceneManifestSpoof.m hides its
/// template entitlements and scene roles from CarPlay, so CarPlay hands it a
/// plain CarPlay window scene rather than building a template scene. Rewriting a
/// real template scene here is what tripped the assertion in
/// +[UIScene _sceneForFBSScene:create:withSession:connectionOptions:] and killed
/// Waze, and later Vietmap on both iOS 16.7.12 and 18.5 — hence
/// CSSetLeavesTemplateScenesAlone below, which declines that rewrite if a
/// template scene reaches this process anyway.
static NSArray<NSString *> *CSKnownCarPlayEntitlementKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *mutable = [NSMutableArray arrayWithObjects:
            @"CARCapableApp", @"com.apple.developer.playable-content", nil];
        // The full set CarKit's admission gate recognises — see
        // +[CRCarPlayAppDeclaration requiredEntitlementKeys].
        NSArray *suffixes = @[ @"parking", @"communication", @"audio", @"public-safety",
                               @"charging", @"driving-task", @"maps", @"protocols",
                               @"messaging", @"calling", @"quick-ordering", @"fueling" ];
        for (NSString *suffix in suffixes) {
            [mutable addObject:[@"com.apple.developer.carplay-" stringByAppendingString:suffix]];
        }
        keys = mutable;
    });
    return keys;
}

static BOOL CSAppHasNativeCarPlayCapability(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return NO;

    BOOL found = NO;
    for (NSString *key in CSKnownCarPlayEntitlementKeys()) {
        CFTypeRef value = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)key, NULL);
        if (!value) continue;
        id boxed = (__bridge_transfer id)value; // transfers ownership; releases value
        if ([boxed respondsToSelector:@selector(boolValue)] && [boxed boolValue]) {
            found = YES;
            break;
        }
    }
    CFRelease(task);
    return found;
}

__attribute__((constructor))
static void CSAppInit(void) {
    @autoreleasepool {
        CSTimingLog("app init begin process=%s bundle=%s",
                    NSProcessInfo.processInfo.processName.UTF8String,
                    NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "(none)");
        if (!CSProcessIsBridgeableApp()) {
            CSTimingLog("app init end not-bridgeable");
            return;
        }

        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        CSConfig *config = CSConfig.sharedConfig;

        // Logged unconditionally, and before the checks below. Previously a
        // sandbox that hid the preferences made this function return in silence,
        // which was indistinguishable in the log from the dylib never having been
        // injected at all — two very different bugs.
        CSLog("loaded into %s (enabled=%d, allowlisted=%d)", bundleID.UTF8String,
                config.isEnabled, [config isBundleEnabled:bundleID]);

        if (!config.isEnabled) {
            CSTimingLog("app init end globally-disabled");
            return;
        }
        if (![config isBundleEnabled:bundleID]) {
            CSTimingLog("app init end not-allowlisted bundle=%s", bundleID.UTF8String);
            return;
        }

        BOOL native = CSAppHasNativeCarPlayCapability();

        CSLog("bridging enabled for %s%s", bundleID.UTF8String,
                native ? " (native CarPlay app — bridged instead of left on its "
                         "own template UI)" : "");
        // The per-app Settings page posts this cooperative close request after
        // changing display options. It avoids a whole-device respring and does
        // not require Preferences to hold process-management privileges.
        NSString *closeNotification =
            [@"com.pavunato.carsurf/close/" stringByAppendingString:bundleID];
        int closeToken = 0;
        notify_register_dispatch(closeNotification.UTF8String, &closeToken,
                                 dispatch_get_main_queue(), ^(int token) {
            CSLog("close requested from per-app display settings");
            exit(0);
        });

        // A config notification updates the dashboard roster, but it cannot
        // revoke a scene that UIKit has already connected to this process.
        // Re-read after the relay writer and CSConfig's observer have settled;
        // if this process is actually on the car, exiting lets CarPlay tear down
        // the stale bridged scene. A phone-only app is left untouched.
        int configToken = 0;
        notify_register_dispatch(CSConfig.changeNotificationName.UTF8String,
                                 &configToken, dispatch_get_main_queue(), ^(int token) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [config reload];
                if (CSHasActiveCarScene() &&
                    (!config.isEnabled || ![config isBundleEnabled:bundleID])) {
                    CSLog("config disabled while CarPlay scene is active; exiting app");
                    exit(0);
                }
            });
        });

        // A native app should be handed a plain CarPlay window scene, because
        // CSSceneManifestSpoof.m hides its template roles and template
        // entitlements from CarPlay. If a template scene turns up regardless,
        // rewriting it is fatal — leave it to the app.
        CSSetLeavesTemplateScenesAlone(native);

        CSInstallSceneBridge();
        CSInstallTraitOverrides();
        CSInstallKeyboardSupport();
        CSTimingLog("app init end bridge-installed bundle=%s", bundleID.UTF8String);
    }
}
