#import "CSPrefsStore.h"
#import "CSConfigLocation.h"
#import <notify.h>
#import <sys/stat.h>

static NSString *const kApplicationLibraryChangeNotification =
    @"com.pavunato.carsurf/application-library-change";
static NSString *const kDashboardDisabledKey = @"dashboardDisabled";

@implementation CSPrefsStore {
    NSMutableDictionary *_root;
}

+ (CSPrefsStore *)sharedStore {
    static CSPrefsStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[CSPrefsStore alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:CSPreferencesPath()];
        _root = existing ? [existing mutableCopy] : [NSMutableDictionary new];
    }
    return self;
}

#pragma mark - Persistence

- (void)flush {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_root
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&error];
    if (!data) {
        NSLog(@"[CarSurf] preference serialization failed: %@", error);
        return;
    }
    if (![data writeToFile:CSPreferencesPath() options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[CarSurf] preference write failed: %@", error);
        return;
    }
    // SpringBoard's relay copy is what sandboxed apps read, so it needs to be
    // readable by them; the source plist stays owner-only.
    chmod(CSPreferencesPath().fileSystemRepresentation, 0644);

    notify_post(CSConfigChangeNotification().UTF8String);
}

/// Returns the mutable sub-dictionary at `key`, creating it if absent.
- (NSMutableDictionary *)mutableSectionForKey:(NSString *)key {
    id existing = _root[key];
    NSMutableDictionary *section;
    if ([existing isKindOfClass:NSDictionary.class]) {
        section = [existing mutableCopy];
    } else {
        section = [NSMutableDictionary new];
    }
    _root[key] = section;
    return section;
}

#pragma mark - Global

- (id)globalValueForKey:(NSString *)key { return _root[key]; }

- (void)setGlobalValue:(id)value forKey:(NSString *)key {
    if (value) {
        _root[key] = value;
    } else {
        [_root removeObjectForKey:key];
    }
    [self flush];
}

#pragma mark - Defaults

- (id)defaultValueForKey:(NSString *)key {
    id defaults = _root[@"defaults"];
    return [defaults isKindOfClass:NSDictionary.class] ? defaults[key] : nil;
}

- (void)setDefaultValue:(id)value forKey:(NSString *)key {
    NSMutableDictionary *defaults = [self mutableSectionForKey:@"defaults"];
    if (value) {
        defaults[key] = value;
    } else {
        [defaults removeObjectForKey:key];
    }
    [self flush];
}

#pragma mark - Per app

- (NSDictionary *)entryForApp:(NSString *)bundleIdentifier {
    id apps = _root[@"apps"];
    if (![apps isKindOfClass:NSDictionary.class]) return nil;
    id entry = apps[bundleIdentifier];
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}

- (BOOL)isAppEnabled:(NSString *)bundleIdentifier {
    return [[self entryForApp:bundleIdentifier][@"enabled"] boolValue];
}

- (void)setValue:(id)value key:(NSString *)key forApp:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return;

    NSMutableDictionary *apps = [self mutableSectionForKey:@"apps"];
    NSDictionary *existing = [apps[bundleIdentifier] isKindOfClass:NSDictionary.class]
                                 ? apps[bundleIdentifier] : nil;
    NSMutableDictionary *entry = existing ? [existing mutableCopy] : [NSMutableDictionary new];

    if (value) {
        entry[key] = value;
    } else {
        [entry removeObjectForKey:key];
    }

    // Drop the whole entry once it carries no information, so the plist does not
    // accumulate a row for every app the user has ever toggled.
    if (entry.count == 0 || (entry.count == 1 && entry[@"enabled"] &&
                             ![entry[@"enabled"] boolValue])) {
        [apps removeObjectForKey:bundleIdentifier];
    } else {
        apps[bundleIdentifier] = entry;
    }

    [self flush];
}

- (void)setApp:(NSString *)bundleIdentifier enabled:(BOOL)enabled {
    [self setValue:enabled ? @YES : nil key:@"enabled" forApp:bundleIdentifier];

    // Keep a small persistent tombstone for deliberately disabled Carsurf
    // entries. The CarPlayTemplateUIHost process can restart without a live
    // DBApplicationController, so a process-local removed-ID set alone cannot
    // filter a stale icon after a respring. Re-enabling removes the tombstone.
    NSMutableArray *disabled = [_root[kDashboardDisabledKey] isKindOfClass:NSArray.class]
                                    ? [_root[kDashboardDisabledKey] mutableCopy]
                                    : [NSMutableArray new];
    [disabled removeObject:bundleIdentifier];
    if (!enabled && bundleIdentifier.length > 0 && ![disabled containsObject:bundleIdentifier]) {
        [disabled addObject:bundleIdentifier];
    }
    if (disabled.count > 0) {
        _root[kDashboardDisabledKey] = disabled;
    } else {
        [_root removeObjectForKey:kDashboardDisabledKey];
    }
    [self flush];

    // This is the preference-side equivalent of FBSApplicationLibrary's
    // applicationsDidInstall:/applicationsDidUninstall: callback. The CarPlay
    // process listens for it and performs the same roster/controller refresh,
    // so an app enabled in Carsurf appears without unplugging or respringing.
    notify_post(kApplicationLibraryChangeNotification.UTF8String);
}

- (id)value:(NSString *)key forApp:(NSString *)bundleIdentifier {
    return [self entryForApp:bundleIdentifier][key];
}

- (NSUInteger)enabledAppCount {
    id apps = _root[@"apps"];
    if (![apps isKindOfClass:NSDictionary.class]) return 0;

    NSUInteger count = 0;
    for (id entry in [apps allValues]) {
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"enabled"] boolValue]) count++;
    }
    return count;
}

@end
