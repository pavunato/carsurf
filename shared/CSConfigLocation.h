#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Where the configuration lives, and how a process hears that it changed.
//
// This is a leaf: it depends on neither CSLog nor CSConfig, so both can use it.
// That is the whole point of the file. CSConfig owns *reading* the config and
// CSLog owns writing the log, but both need to know which files to look in —
// and when the two kept their own copies of that list, they drifted. CSLog's
// copy was missing the jailbreak-root relay, which is the only candidate an App
// Store app's sandbox can actually read, so CSVerboseEnabled() returned NO in
// every sandboxed app and silently turned all app-side logging into a no-op.
// One definition, three consumers, no way to update one and forget the others.

/// Where the preferences are authored. SpringBoard, the prefs bundle and
/// carsurf-helperd all write here; app sandboxes cannot read it.
NSString *CSPreferencesPath(void);

/// The world-readable mirror SpringBoard and carsurf-helperd produce so
/// sandboxed processes can still read the config. First candidate below.
NSString *CSRelayMirrorPath(void);

/// Every file that may hold the effective configuration, in the order they
/// should be tried: the real preferences first, then the mirrors. Reachability
/// is what orders the mirrors — the jailbreak root is readable from inside an
/// app sandbox because every tweak dylib is itself loaded out of it, while
/// /var/tmp is not and is kept last only for older installs.
NSArray<NSString *> *CSConfigCandidatePaths(void);

/// Posted whenever the configuration changes. Anything caching a value derived
/// from the files above must re-read it on this notification.
NSString *CSConfigChangeNotification(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
