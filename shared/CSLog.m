#define CS_TAG "log"

#import "CSLog.h"
#import "CSConfigLocation.h"
#import <notify.h>
#import <os/log.h>
#import <stdarg.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <unistd.h>
#import <mach/mach_time.h>

// iOS ships no `log` binary, so os_log output is effectively unreadable on a
// device without extra tooling (and on zsh, `log` is a shell built-in that
// silently swallows `log show ...`). Everything therefore also goes to a plain
// text file.
//
// Paths are tried in order. SpringBoard and CarPlay.app run as mobile and can
// write the shared locations; sandboxed apps fall back to their own container,
// which carsurf-logs collects.
static NSString *const kSharedLogPaths[] = {
    @"/var/mobile/Library/Logs/carsurf.log",
    @"/var/tmp/carsurf.log",
};

static os_log_t CSLogHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.pavunato.carsurf", "tweak");
    });
    return handle;
}

/// Reads the preference directly. CSConfig depends on this file, so it cannot be
/// used here without a cycle — but the *locations* are shared (CSConfigLocation),
/// because a private copy of that list is exactly how this went wrong: it lacked
/// the jailbreak-root relay, the only candidate readable from an App Store app's
/// sandbox, so every macro below compiled to a no-op in precisely the processes
/// the tweak exists for.
static BOOL CSReadVerbosePreference(void) {
    for (NSString *path in CSConfigCandidatePaths()) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        if (prefs) return [prefs[@"verboseLogging"] boolValue];
    }
    return NO;
}

BOOL CSVerboseEnabled(void) {
    // The environment override is absolute and cannot be revoked by a config
    // change; the preference below can, so it is re-read rather than frozen.
    static BOOL forcedByEnvironment;
    static atomic_bool enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *env = getenv("CS_VERBOSE");
        forcedByEnvironment = env && *env && *env != '0';
        atomic_store(&enabled, forcedByEnvironment || CSReadVerbosePreference());

        // Without this the value was fixed for the life of the process: turning
        // verbose logging on in Settings did nothing until every affected
        // process was restarted. It also self-heals the boot race, where an app
        // launching before SpringBoard has written the relay would otherwise
        // stay silent forever — the next config change re-reads it.
        int token = 0;
        notify_register_dispatch(CSConfigChangeNotification().UTF8String, &token,
                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                                 ^(int t) {
            atomic_store(&enabled, forcedByEnvironment || CSReadVerbosePreference());
        });
    });
    return atomic_load(&enabled);
}

/// The first writable log path for this process, resolved once.
static NSString *CSLogFilePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fileManager = NSFileManager.defaultManager;

        for (size_t i = 0; i < sizeof(kSharedLogPaths) / sizeof(*kSharedLogPaths); i++) {
            NSString *candidate = kSharedLogPaths[i];
            NSString *directory = candidate.stringByDeletingLastPathComponent;
            if (![fileManager fileExistsAtPath:directory]) continue;
            if (access(directory.fileSystemRepresentation, W_OK) != 0) continue;
            // A writable directory is not enough: carsurf-helperd runs as root
            // and creates this file 0644 root-owned, after which SpringBoard and
            // CarPlay.app (mobile) can no longer append to it. fopen just fails
            // and every line from those processes is lost — which is exactly how
            // the CarPlay policy and manifest hooks came to leave no trace at
            // all while helperd filled the same file with thousands of lines.
            if ([fileManager fileExistsAtPath:candidate] &&
                access(candidate.fileSystemRepresentation, W_OK) != 0) {
                continue;
            }
            path = candidate;
            return;
        }

        // Always writable, but inside the app's own container.
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"carsurf.log"];
    });
    return path;
}

static void CSAppendToFile(const char *line) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.pavunato.carsurf.log", DISPATCH_QUEUE_SERIAL);
    });

    NSString *entry = [NSString stringWithUTF8String:line];
    if (!entry) return;

    dispatch_async(queue, ^{
        NSString *path = CSLogFilePath();
        BOOL existed = access(path.fileSystemRepresentation, F_OK) == 0;
        FILE *file = fopen(path.fileSystemRepresentation, "a");
        if (!file) return;
        // Whoever creates the shared log decides who else can use it. root gets
        // there first (helperd starts at boot), so widen it immediately rather
        // than lock every mobile process out of the file it just made.
        if (!existed) chmod(path.fileSystemRepresentation, 0666);
        fputs(entry.UTF8String, file);
        fputc('\n', file);
        fclose(file);
    });
}

void CSLogImpl(const char *tag, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char *body = NULL;
    if (vasprintf(&body, fmt, args) < 0) body = NULL;
    va_end(args);
    if (!body) return;

    const char *process = NSProcessInfo.processInfo.processName.UTF8String ?: "?";

    os_log(CSLogHandle(), "[%{public}s/%{public}s] %{public}s", tag, process, body);

    // Timestamped, because the file accumulates across resprings.
    char *line = NULL;
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                    dateStyle:NSDateFormatterShortStyle
                                                    timeStyle:NSDateFormatterMediumStyle];
    if (asprintf(&line, "%s [%s/%s] %s", stamp.UTF8String ?: "?", tag, process, body) >= 0) {
        CSAppendToFile(line);
        free(line);
    }

    free(body);
}

void CSLogTimingImpl(const char *tag, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char *body = NULL;
    if (vasprintf(&body, fmt, args) < 0) body = NULL;
    va_end(args);
    if (!body) return;

    static uint64_t startTicks;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        startTicks = mach_absolute_time();
        mach_timebase_info(&timebase);
    });
    uint64_t delta = mach_absolute_time() - startTicks;
    double seconds = ((double)delta * (double)timebase.numer /
                      (double)timebase.denom) / 1000000000.0;
    CSLogImpl(tag, "TIMING +%.3fs %s", seconds, body);
    free(body);
}
