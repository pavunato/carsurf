#define CS_TAG "system"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <mach-o/loader.h>
#import <objc/runtime.h>

/// YES when CarPlay admission is granted through the LaunchServices/scene hooks
/// (iOS 16/17) rather than the CarKit declaration factory (iOS 18+). Both are
/// runtime paths — nothing is patched on disk any more — but they need different
/// hooks: on iOS <18 the full LSBundleProxy scene-manifest spoof, on iOS 18+ only
/// the minimal manifest-role accessor (the full spoof sits on hot Foundation
/// paths and crash-loops SpringBoard into safe mode on 18.5). This is only a
/// release selector; it must NOT be forced true or the wrong hook installs.
static BOOL CSUsesRuntimeCarPlayAdmission(void) {
    static BOOL runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        runtime = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18;
    });
    return runtime;
}

static BOOL CSIsSpringBoard(void) {
    return [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"];
}

/// carkitd is the one process where a LaunchServices accessor hook is known to
/// be fatal: an earlier entitlement spoof there put the head unit into an
/// endless connecting loop (docs/ios18-runtime-carplay-admission.md states the
/// rule without qualification). CSCarKitPolicy already treats the daemon as
/// observe-only for the same reason; the manifest-role spoof is a broader,
/// hotter accessor than that policy hook, so it is not installed there at all.
static BOOL CSIsCarKitDaemon(void) {
    return [NSProcessInfo.processInfo.processName isEqualToString:@"carkitd"];
}

static void CSInstallCarPlayHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    CSTimingLog("hook installation begin");

    // iOS 16/17 admission: DashBoard's _proxyPassesInclusionFilter asks
    // LSBundleProxy for entitlements, so an app can be admitted at runtime with no
    // on-disk change. Required on RootHide, where the on-disk route is impossible —
    // jbctl refuses to trustcache anything under /var/containers/Bundle/Application,
    // so a re-signed app binary can never launch.
    //
    // Strictly version-gated. On iOS 18 CarKit never consults LaunchServices, so
    // these hooks cannot admit anything there — and they are not free to leave
    // installed: LSBundleProxy sits on hot Foundation paths, and an earlier
    // version of this file crash-looped SpringBoard into safe mode on 18.5.
    // Where they cannot help, they do not run.
    if (CSUsesRuntimeCarPlayAdmission()) {
        CSInstallSceneManifestSpoof();
    } else {
        CSLog("iOS 18+ — CarKit ignores LaunchServices; declaration-factory "
              "runtime admission is installed by the CarKit policy hook");
        // Admission and launch are separate gates on iOS 18. CarKit builds
        // the declaration through the factory hook, while the launch broker
        // still reads UIApplicationSceneManifest to obtain a CarPlay window
        // role. Install only that role accessor; the older entitlement and
        // cached-value hooks stay disabled because they sit on hot LS paths.
        //
        // The broker runs in SpringBoard and the CarPlay UI processes, which
        // all still get it — carkitd never needed it and must not have it.
        if (CSIsCarKitDaemon()) {
            CSLog("carkitd — manifest role spoof withheld; the launch broker "
                  "runs in SpringBoard and the CarPlay hosts");
        } else {
            CSInstallSceneManifestRoleSpoof();
        }
    }

    // iOS 18-era path; the two below are no-ops when their classes are
    // absent, so both generations are covered by one build.
    // Gate G1's admission check is +[CRCarPlayAppDeclaration requiredEntitlementKeys]:
    // an app qualifies by holding CARCapableApp, SBStarkCapable, or one of the
    // com.apple.developer.carplay-* entitlements. On iOS 18 the declaration
    // factory receives LSBundleInfoCachedValues; CSCarKitPolicy retries that
    // factory with a per-call proxy for enabled apps, so the bundle itself need
    // not be re-signed. The policy hook then promotes the resulting declaration.
    CSInstallCarKitPolicyHook();
    CSInstallEntitlementSpoof();
    CSInstallAppListFilter();
    CSTimingLog("hook installation end");
}

/// Fires for every image the process maps. CarPlaySupport is loaded lazily, well
/// after the tweak is injected, so this is where the hooks actually go in.
static void CSImageLoaded(const struct mach_header *header) {
    // CarKit on iOS 18, CarPlaySupport on older releases. Either arriving is the
    // cue to install.
    if (!objc_getClass("CRCarPlayAppPolicyEvaluator") && !objc_getClass("CARApplication") &&
        !objc_getClass("CRSIconLayoutService") && !objc_getClass("CRSIconLayoutController")) return;
    CSTimingLog("CarPlay framework image loaded — installing hooks");
    CSInstallCarPlayHooks();
}

__attribute__((constructor))
static void CSSystemInit(void) {
    @autoreleasepool {
        CSConfig *config = CSConfig.sharedConfig;

        // LaunchServices has the authoritative installed-app roster in
        // SpringBoard. Prune entries left behind by an uninstall before any
        // CarPlay roster admission or relay mirroring reads the config.
        if (CSIsSpringBoard()) {
            [config pruneMissingApplications];
        }

        CSTimingLog("system init begin process=%s enabled=%d allowlisted=%lu",
                NSProcessInfo.processInfo.processName.UTF8String,
                config.isEnabled,
                (unsigned long)config.enabledBundleIdentifiers.count);

        // The kill switch and CS_SAFE are honoured before a single hook goes in,
        // so a device that boot-loops can be recovered over SSH by touching
        // /var/mobile/Library/Preferences/.carsurf-disable.
        if (!config.isEnabled) {
            CSLog("inactive — no hooks installed");
            return;
        }

        if (CSIsSpringBoard()) {
            CSStartRelay();
        }

        // Self-gated to the CarPlay host. Must go in before DashBoard builds
        // its workspace, so it cannot wait for the CarPlay hooks below.
        CSInstallCarLaunch();

        // Capture the abort reason for the CarPlay-host launch crash. The host
        // exits with SIGABRT and respawns before ReportCrash can persist an .ips,
        // so record name/reason/backtrace to carsurf.log ourselves. Host UI
        // processes only; SpringBoard and carkitd are left untouched.
        NSString *proc = NSProcessInfo.processInfo.processName;
        if ([proc isEqualToString:@"CarPlay"] ||
            [proc isEqualToString:@"CarPlayApp"] ||
            [proc isEqualToString:@"CarPlayTemplateUIHost"]) {
            CSInstallCrashDiagnostics();
        }

        if (objc_getClass("CRCarPlayAppPolicyEvaluator") || objc_getClass("CARApplication") ||
            objc_getClass("CRSIconLayoutService") || objc_getClass("CRSIconLayoutController")) {
            CSInstallCarPlayHooks();
        } else {
            objc_addLoadImageFunc(CSImageLoaded);
        }
        CSTimingLog("system init end");
    }
}
