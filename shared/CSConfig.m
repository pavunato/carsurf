#define CS_TAG "config"

#import "CSConfig.h"
#import "CSConfigLocation.h"
#import "CSLog.h"
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>

static NSString *const kKillSwitchPath =
    @"/var/mobile/Library/Preferences/.carsurf-disable";

#pragma mark - Options

@implementation CSAppOptions

- (instancetype)initWithBundleIdentifier:(NSString *)bundleID
                              dictionary:(NSDictionary *)dict {
    if ((self = [super init])) {
        _bundleIdentifier = [bundleID copy];

        NSInteger mode = [dict[@"mode"] integerValue];
        _mode = (mode >= CSBridgeModeAuto && mode <= CSBridgeModeMirror)
                    ? (CSBridgeMode)mode
                    : CSBridgeModeAuto;

        CGFloat scale = dict[@"scale"] ? [dict[@"scale"] doubleValue] : 1.0;
        if (!isfinite(scale)) scale = 1.0;
        _scale = MIN(MAX(scale, kCSMinScale), kCSMaxScale);

        // iPhone spoofing helps far more apps than it hurts, so it remains the
        // default. Read the former boolean when upgrading an existing plist.
        if (dict[@"idiomMode"]) {
            NSInteger idiomMode = [dict[@"idiomMode"] integerValue];
            _idiomMode = (idiomMode >= CSIdiomModeAuto &&
                          idiomMode <= CSIdiomModePad)
                             ? (CSIdiomMode)idiomMode
                             : CSIdiomModePhone;
        } else if (dict[@"forceIdiomPhone"]) {
            _idiomMode = [dict[@"forceIdiomPhone"] boolValue]
                             ? CSIdiomModePhone : CSIdiomModeAuto;
        } else {
            _idiomMode = CSIdiomModePhone;
        }
        if (dict[@"layoutMode"]) {
            NSInteger layoutMode = [dict[@"layoutMode"] integerValue];
            _layoutMode = (layoutMode >= CSLayoutModeAuto &&
                           layoutMode <= CSLayoutModeVertical)
                              ? (CSLayoutMode)layoutMode
                              : CSLayoutModeHorizontal;
        } else {
            // Compatibility with the short-lived boolean Vertical option.
            _layoutMode = [dict[@"portraitLayout"] boolValue]
                              ? CSLayoutModeVertical
                              : CSLayoutModeHorizontal;
        }
        _allowIndependentRotation = [dict[@"allowIndependentRotation"] boolValue];
    }
    return self;
}

@end

#pragma mark - Config

@implementation CSConfig {
    NSDictionary *_root;
    NSMutableDictionary<NSString *, CSAppOptions *> *_optionsCache;
    dispatch_queue_t _queue;
    BOOL _safeMode;
}

+ (NSString *)changeNotificationName { return CSConfigChangeNotification(); }

+ (CSConfig *)sharedConfig {
    static CSConfig *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[CSConfig alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.pavunato.carsurf.config", DISPATCH_QUEUE_CONCURRENT);
        _optionsCache = [NSMutableDictionary new];

        const char *safe = getenv("CS_SAFE");
        _safeMode = (safe && *safe && *safe != '0');
        if (_safeMode) CSLog("CS_SAFE set — tweak inactive in this process");

        [self grantPreferencesAccessIfNeeded];
        [self reload];
        [self observeChanges];
    }
    return self;
}

/// App sandboxes deny the shared Preferences directory. libSandy, when present,
/// grants it; without libSandy we fall back to the relay file in -loadRoot.
- (void)grantPreferencesAccessIfNeeded {
    if (getuid() == 0) return; // SpringBoard / CarPlay.app: already unrestricted

    static const char *candidates[] = {
        "/var/jb/usr/lib/libsandy.dylib",
        "/usr/lib/libsandy.dylib",
        "/var/jb/usr/lib/libSandy.dylib",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(*candidates); i++) {
        void *handle = dlopen(candidates[i], RTLD_LAZY);
        if (!handle) continue;
        int (*applyProfile)(const char *) = dlsym(handle, "libSandy_applyProfile");
        if (applyProfile) {
            int result = applyProfile("SystemGroupContainers");
            CSVLog("libSandy_applyProfile -> %d (%s)", result, candidates[i]);
        }
        return;
    }
    CSVLog("libSandy unavailable; will try the relay file");
}

- (void)observeChanges {
    int token = 0;
    notify_register_dispatch(CSConfigChangeNotification().UTF8String, &token,
                             dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                             ^(int t) { [self reload]; });
}

- (NSDictionary *)loadRoot {
    NSArray<NSString *> *candidates = CSConfigCandidatePaths();
    for (NSString *path in candidates) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict) {
            // Logged once, unconditionally: "config unreadable" presents as the
            // tweak silently doing nothing, which cost a long debugging detour.
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                CSLog("config loaded from %s (%lu keys)", path.UTF8String,
                        (unsigned long)dict.count);
            });
            return dict;
        }
    }

    static dispatch_once_t onceFailed;
    dispatch_once(&onceFailed, ^{
        CSLog("no readable config (tried %lu paths) — tweak inactive here",
                (unsigned long)candidates.count);
    });
    return @{};
}

- (void)reload {
    NSDictionary *root = [self loadRoot];
    BOOL killed = [[NSFileManager defaultManager] fileExistsAtPath:kKillSwitchPath];
    if (killed) CSLog("kill switch present at %s", kKillSwitchPath.UTF8String);

    dispatch_barrier_sync(_queue, ^{
        _root = killed ? @{} : root;
        [_optionsCache removeAllObjects];
    });
}

- (void)pruneMissingApplications {
    // LaunchServices is the source of truth only in SpringBoard. In CarPlay,
    // app, and preferences processes a partial/sandboxed view could make a
    // healthy entry look absent and accidentally delete the user's choice.
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        return;
    }

    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    SEL defaultWorkspaceSelector = sel_registerName("defaultWorkspace");
    SEL allApplicationsSelector = sel_registerName("allApplications");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultWorkspaceSelector]) {
        CSLog("preference prune skipped: LSApplicationWorkspace unavailable");
        return;
    }

    id workspace = ((id (*)(Class, SEL))objc_msgSend)(workspaceClass,
                                                       defaultWorkspaceSelector);
    NSArray *installedApplications =
        (workspace && [workspace respondsToSelector:allApplicationsSelector])
            ? ((id (*)(id, SEL))objc_msgSend)(workspace, allApplicationsSelector)
            : nil;
    if (![installedApplications isKindOfClass:NSArray.class]) {
        CSLog("preference prune skipped: LaunchServices returned no application list");
        return;
    }

    NSMutableSet<NSString *> *installedIdentifiers = [NSMutableSet setWithCapacity:installedApplications.count];
    SEL identifierSelector = sel_registerName("applicationIdentifier");
    for (id proxy in installedApplications) {
        if (!proxy || ![proxy respondsToSelector:identifierSelector]) continue;
        id identifier = ((id (*)(id, SEL))objc_msgSend)(proxy, identifierSelector);
        if ([identifier isKindOfClass:NSString.class] && [(NSString *)identifier length] > 0) {
            [installedIdentifiers addObject:(NSString *)identifier];
        }
    }

    // An empty list means LaunchServices is not ready yet, not that every app
    // was removed. Waiting here avoids wiping the plist during early boot.
    if (installedIdentifiers.count == 0) {
        CSLog("preference prune skipped: LaunchServices list is empty");
        return;
    }

    __block NSDictionary *root = nil;
    dispatch_sync(_queue, ^{ root = _root; });
    NSDictionary *savedApps = [root[@"apps"] isKindOfClass:NSDictionary.class]
                                   ? root[@"apps"] : nil;
    NSArray *savedDisabled = [root[@"dashboardDisabled"] isKindOfClass:NSArray.class]
                                  ? root[@"dashboardDisabled"] : @[];
    NSMutableDictionary *apps = [savedApps mutableCopy] ?: [NSMutableDictionary new];
    NSMutableArray<NSString *> *removed = [NSMutableArray new];
    for (id key in savedApps.allKeys) {
        if (![key isKindOfClass:NSString.class] || ![installedIdentifiers containsObject:key]) {
            [apps removeObjectForKey:key];
            if ([key isKindOfClass:NSString.class]) [removed addObject:key];
        }
    }
    NSMutableArray *disabled = [savedDisabled mutableCopy];
    NSMutableArray<NSString *> *removedDisabled = [NSMutableArray new];
    for (id identifier in [savedDisabled copy]) {
        if (![identifier isKindOfClass:NSString.class] ||
            ![installedIdentifiers containsObject:identifier]) {
            [disabled removeObject:identifier];
            if ([identifier isKindOfClass:NSString.class]) [removedDisabled addObject:identifier];
        }
    }
    if (removed.count == 0 && removedDisabled.count == 0) return;

    NSMutableDictionary *updatedRoot = [root mutableCopy] ?: [NSMutableDictionary new];
    if (apps.count > 0) {
        updatedRoot[@"apps"] = apps;
    } else {
        [updatedRoot removeObjectForKey:@"apps"];
    }
    if (disabled.count > 0) {
        updatedRoot[@"dashboardDisabled"] = disabled;
    } else {
        [updatedRoot removeObjectForKey:@"dashboardDisabled"];
    }

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:updatedRoot
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (!data || ![data writeToFile:CSPreferencesPath() options:NSDataWritingAtomic error:&error]) {
        CSLog("preference prune write failed: %s", error.localizedDescription.UTF8String);
        return;
    }
    chmod(CSPreferencesPath().fileSystemRepresentation, 0644);

    dispatch_barrier_sync(_queue, ^{
        _root = updatedRoot;
        [_optionsCache removeAllObjects];
    });
    notify_post(CSConfigChangeNotification().UTF8String);
    if (removed.count > 0) {
        CSLog("pruned %lu uninstalled app preference entr%s: %s",
              (unsigned long)removed.count,
              removed.count == 1 ? "y" : "ies",
              [[removed componentsJoinedByString:@", "] UTF8String]);
    }
    if (removedDisabled.count > 0) {
        CSLog("pruned %lu disabled-dashboard tombstone entr%s: %s",
              (unsigned long)removedDisabled.count,
              removedDisabled.count == 1 ? "y" : "ies",
              [[removedDisabled componentsJoinedByString:@", "] UTF8String]);
    }
}

- (BOOL)isEnabled {
    if (_safeMode) return NO;
    __block BOOL enabled = NO;
    dispatch_sync(_queue, ^{
        // Absent key means "not configured yet" -> off, so a fresh install is
        // inert until the user opts in.
        enabled = [_root[@"enabled"] boolValue];
    });
    return enabled;
}

- (NSArray<NSString *> *)enabledBundleIdentifiers {
    __block NSArray *result = @[];
    dispatch_sync(_queue, ^{
        NSDictionary *apps = _root[@"apps"];
        if (![apps isKindOfClass:NSDictionary.class]) return;
        NSMutableArray *ids = [NSMutableArray new];
        [apps enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] &&
                [value isKindOfClass:NSDictionary.class] &&
                [value[@"enabled"] boolValue]) {
                [ids addObject:key];
            }
        }];
        result = ids;
    });
    return result;
}

- (NSArray<NSString *> *)dashboardDisabledBundleIdentifiers {
    __block NSArray *result = @[];
    dispatch_sync(_queue, ^{
        id value = _root[@"dashboardDisabled"];
        if ([value isKindOfClass:NSArray.class]) result = [value copy];
    });
    return result;
}

- (BOOL)isBundleEnabled:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0 || !self.isEnabled) return NO;
    __block BOOL enabled = NO;
    dispatch_sync(_queue, ^{
        NSDictionary *apps = _root[@"apps"];
        NSDictionary *entry = [apps isKindOfClass:NSDictionary.class]
                                  ? apps[bundleIdentifier] : nil;
        enabled = [entry isKindOfClass:NSDictionary.class] && [entry[@"enabled"] boolValue];
    });
    return enabled;
}

- (CSAppOptions *)optionsForBundle:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) bundleIdentifier = @"";
    __block CSAppOptions *cached = nil;
    dispatch_sync(_queue, ^{ cached = _optionsCache[bundleIdentifier]; });
    if (cached) return cached;

    // Per-app values win; anything the user did not override per app comes from
    // the global defaults, so the prefs UI can expose one set of sliders that
    // applies everywhere and still allow a single app to deviate.
    __block NSMutableDictionary *merged = [NSMutableDictionary new];
    dispatch_sync(_queue, ^{
        NSDictionary *defaults = _root[@"defaults"];
        if ([defaults isKindOfClass:NSDictionary.class]) [merged addEntriesFromDictionary:defaults];

        NSDictionary *apps = _root[@"apps"];
        if ([apps isKindOfClass:NSDictionary.class]) {
            id candidate = apps[bundleIdentifier];
            if ([candidate isKindOfClass:NSDictionary.class]) {
                [merged addEntriesFromDictionary:candidate];
            }
        }
    });

    CSAppOptions *options = [[CSAppOptions alloc] initWithBundleIdentifier:bundleIdentifier
                                                                   dictionary:merged];
    dispatch_barrier_async(_queue, ^{ _optionsCache[bundleIdentifier] = options; });
    return options;
}

@end
