#import "CSConfigLocation.h"

static NSString *const kPrefsPath =
    @"/var/mobile/Library/Preferences/com.pavunato.carsurf.plist";

/// Ordered by reachability from an app sandbox, not by preference. Location is
/// what matters: the old /var/tmp relay was already mode 0644 and still
/// unreadable from an app, because the sandbox — not the filesystem — refused
/// it. /var/jb is reachable, /Library covers a rootful install, /var/tmp is
/// kept last for compatibility with relays older installs already wrote.
static NSString *const kRelayPaths[] = {
    @"/var/jb/Library/CarSurf/relay.plist",
    @"/Library/CarSurf/relay.plist",
    @"/var/tmp/.carsurf-relay.plist",
};

NSString *CSPreferencesPath(void) {
    return kPrefsPath;
}

NSString *CSRelayMirrorPath(void) {
    return kRelayPaths[0];
}

NSArray<NSString *> *CSConfigCandidatePaths(void) {
    static NSArray *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *all = [NSMutableArray arrayWithObject:kPrefsPath];
        for (size_t i = 0; i < sizeof(kRelayPaths) / sizeof(*kRelayPaths); i++) {
            [all addObject:kRelayPaths[i]];
        }
        paths = [all copy];
    });
    return paths;
}

NSString *CSConfigChangeNotification(void) {
    return @"com.pavunato.carsurf/reload";
}
