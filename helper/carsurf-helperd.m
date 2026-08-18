// carsurf-helperd — root helper whose one job is to publish the app-readable
// preferences relay.
//
// CarPlay admission is done entirely at runtime now, on every supported release:
// before iOS 18 through the LaunchServices/scene hooks, and on iOS 18+ through the
// CarKit declaration factory + DBApplicationInfo roster injection (CSSystem.m and
// CSCarKitPolicy.m). Nothing has to be re-signed, trustcached, or written to an
// app bundle any more — so this daemon no longer patches, reverts, reconciles, or
// touches any bundle at all. That machinery has been removed; the CarKit policy
// hook gates promotion on the runtime admission itself, not on an on-disk patch.
//
// The one thing that still requires a root process is the relay. A sandboxed app
// cannot read /var/mobile/Library/Preferences/com.pavunato.carsurf.plist, so
// without a copy at /var/jb/Library/CarSurf/relay.plist every app tweak reads
// enabled=0 and renders a blank CarPlay screen. SpringBoard's CSRelay.m writes the
// same file, but only once it has been injected and not at all on RootHide, so a
// fresh install or a device that has not resprung would have no relay. This daemon
// runs from boot and re-runs on every preference change, making the relay
// independent of SpringBoard's injection state.

#define CS_TAG "helperd"

#import <Foundation/Foundation.h>
#import "CSConfigLocation.h"
#import "CSLog.h"
#import <errno.h>
#import <notify.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kStateDirectory = @"/var/jb/Library/CarSurf";


#pragma mark - Relay

/// Mirrors the preferences to a path a sandboxed app can actually read.
///
/// An app sandbox refuses /var/mobile/Library/Preferences outright, so without
/// this file CSConfig finds nothing, every app tweak decides it is not enabled,
/// and the car scene is never bridged — the app reaches the CarPlay dashboard on
/// the strength of runtime admission alone and then renders a blank screen.
///
/// CSRelay.m does the same job from SpringBoard, but only from SpringBoard: a
/// fresh install that has not resprung yet has no relay at all, which is exactly
/// how the blank-screen failure was reproduced on RootHide. This daemon runs from
/// boot and re-runs on every preference change, so writing it here as well makes
/// the relay independent of SpringBoard's injection state.
static void CSWriteRelay(void) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:CSPreferencesPath()];
    if (!preferences) {
        CSLog("no preferences at %s; leaving relay untouched", CSPreferencesPath().UTF8String);
        return;
    }

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:preferences
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&error];
    if (!data) {
        CSLog("relay serialization failed: %s", error.localizedDescription.UTF8String);
        return;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    [fileManager createDirectoryAtPath:kStateDirectory
           withIntermediateDirectories:YES
                            attributes:@{ NSFilePosixPermissions : @(0755) }
                                 error:NULL];
    // The directory may predate this code (or have been created by the package's
    // postinst) with tighter permissions; an app that cannot traverse it cannot
    // read the relay no matter how the file itself is chmodded.
    chmod(kStateDirectory.fileSystemRepresentation, 0755);

    // Write-then-rename so a reader never observes a half-written file. Unique
    // temporary name and rename(2) rather than a fixed ".tmp" plus
    // remove-then-move: SpringBoard writes this same file (CSRelay.m) and both
    // sides raced, each losing write logging a failure and leaving the relay one
    // edit stale.
    NSString *temporary = [NSString stringWithFormat:@"%@.%@.tmp", CSRelayMirrorPath(),
                           NSUUID.UUID.UUIDString];
    if (![data writeToFile:temporary atomically:NO]) {
        CSLog("relay write to %s failed", temporary.UTF8String);
        return;
    }
    chmod(temporary.fileSystemRepresentation, 0644);

    if (rename(temporary.fileSystemRepresentation,
               CSRelayMirrorPath().fileSystemRepresentation) != 0) {
        CSLog("relay rename failed (errno %d: %s)", errno, strerror(errno));
        [fileManager removeItemAtPath:temporary error:NULL];
        return;
    }

    CSLog("relay updated at %s (%lu bytes)", CSRelayMirrorPath().UTF8String,
          (unsigned long)data.length);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CSLog("helper started (uid %d) — relay only; CarPlay admission is runtime, "
              "no patching", getuid());

        [NSFileManager.defaultManager createDirectoryAtPath:kStateDirectory
                               withIntermediateDirectories:YES attributes:nil error:NULL];

        // Publish the app-readable config at boot, then keep it current on every
        // preference change. Registering no patch handlers also means a stray
        // "patch now" request from an older Settings build cannot touch a bundle.
        CSWriteRelay();

        int reloadToken = 0;
        notify_register_dispatch(CSConfigChangeNotification().UTF8String, &reloadToken,
                                 dispatch_get_main_queue(), ^(int t) {
            CSLog("preferences changed");
            CSWriteRelay();
        });

        dispatch_main();
    }
    return 0;
}
