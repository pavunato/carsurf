#define CS_TAG "relay"

#import "CSSystemInternal.h"
#import "CSConfigLocation.h"
#import "CSLog.h"
#import <notify.h>
#import <sys/stat.h>


// App sandboxes deny the shared Preferences directory. libSandy is the clean fix,
// but it is only a Recommends, so SpringBoard also drops a world-readable copy of
// the preferences where a sandboxed app can reach it. Nothing secret lives in
// there — it is an allowlist of bundle identifiers and a few layout numbers.
//
// carsurf-helperd writes the identical file for the identical reason. That is
// deliberate redundancy, not a leftover: this copy only exists once SpringBoard
// has been restarted with the tweak injected, and a just-installed package that
// has not resprung yet would otherwise leave every app tweak inert. Both writers
// are atomic and produce the same bytes, so whichever runs last is correct.
static void CSWriteRelay(void) {
    // Source and destination both come from CSConfigLocation, so this writer
    // cannot drift from the readers: the mirror is by definition CSConfig's
    // first relay candidate, the one an app sandbox can reach.
    NSString *kPrefsPath = CSPreferencesPath();
    NSString *kRelayPath = CSRelayMirrorPath();

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!prefs) {
        CSVLog("no preferences at %s; leaving relay untouched", kPrefsPath.UTF8String);
        return;
    }

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&error];
    if (!data) {
        CSLog("relay serialization failed: %s", error.localizedDescription.UTF8String);
        return;
    }

    // The directory is ours to create on first run.
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:kRelayPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES
                                             attributes:@{ NSFilePosixPermissions : @(0755) }
                                                  error:&directoryError];

    // Write-then-rename so a reader never observes a half-written file. The
    // temporary name is unique per write and the swap is rename(2): a fixed
    // ".tmp" name plus remove-then-move raced both against this process (a burst
    // of preference notifications runs several of these at once) and against
    // carsurf-helperd, which writes the same file. Every loser of that race
    // logged "relay rename failed" and left the relay a write behind — invisible
    // until SpringBoard could write to the shared log at all. rename() replaces
    // the destination atomically, so there is no window to lose.
    NSString *temporary = [NSString stringWithFormat:@"%@.%@.tmp", kRelayPath,
                           NSUUID.UUID.UUIDString];
    if (![data writeToFile:temporary atomically:NO]) {
        CSLog("relay write to %s failed", temporary.UTF8String);
        return;
    }
    chmod(temporary.fileSystemRepresentation, 0644);

    if (rename(temporary.fileSystemRepresentation,
               kRelayPath.fileSystemRepresentation) != 0) {
        CSLog("relay rename failed (errno %d: %s)", errno, strerror(errno));
        [NSFileManager.defaultManager removeItemAtPath:temporary error:NULL];
        return;
    }

    CSVLog("relay updated (%lu bytes)", (unsigned long)data.length);
}

void CSStartRelay(void) {
    CSWriteRelay();

    int token = 0;
    notify_register_dispatch("com.pavunato.carsurf/reload", &token,
                             dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                             ^(int t) { CSWriteRelay(); });
}
