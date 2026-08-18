#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Patches CARAppEntitlements so allowlisted apps look CarPlay-capable (gate G1,
/// first half). No-op if CarPlaySupport is not loaded in this process.
void CSInstallEntitlementSpoof(void);

/// Upstream half of gate G1 on iOS 18.x: reports UIWindowSceneSessionRoleCarPlay
/// in allowlisted apps' scene manifests so CarKit builds a declaration for them
/// at all. Without this the policy hook below is never consulted.
void CSInstallSceneManifestSpoof(void);

/// iOS 18 still needs a CarPlay window-scene role when runtime declaration
/// admission promotes an ordinary phone app. Install only the manifest-role
/// accessor; do not install the older LaunchServices entitlement hooks.
void CSInstallSceneManifestRoleSpoof(void);

/// Gate G1 on iOS 18.x: CarKit's CRCarPlayAppPolicyEvaluator decides which apps
/// may appear on the car screen. No-op on releases that predate CarKit's policy
/// API, where the CARApplication path below applies instead.
void CSInstallCarKitPolicyHook(void);

/// Patches the CARApplication class-level app list so the dashboard sees the
/// genuine CarPlay apps plus the user's allowlist, and nothing else (gate G1,
/// second half).
void CSInstallAppListFilter(void);

/// SpringBoard mirrors the effective preferences to a world-readable relay file
/// so sandboxed app processes without libSandy can still read them.
void CSStartRelay(void);

/// Listens for com.pavunato.carsurf/carlaunch in the CarPlay host and drives
/// DashBoard's own workspace activation for the bundle identifier named in
/// /var/jb/Library/CarSurf/carlaunch. Lets carsurf-launch open an app on the
/// car screen over SSH; no-op outside the CarPlay process.
void CSInstallCarLaunch(void);

/// Installs a synchronous uncaught-exception + fatal-signal handler that records
/// the abort reason (name/reason/backtrace) to carsurf.log before the process
/// dies. Debug diagnostic for the CarPlay-host SIGABRT on app launch; no-op on a
/// success path. Idempotent.
void CSInstallCrashDiagnostics(void);

NS_ASSUME_NONNULL_END
