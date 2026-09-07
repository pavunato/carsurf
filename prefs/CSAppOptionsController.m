#import "CSAppOptionsController.h"
#import "CSAppFilter.h"
#import "CSPrefsStore.h"
#import "CSConfig.h"
#import "CSLayoutSegmentCell.h"
#import "CSScaleSliderCell.h"
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>

@implementation CSAppOptionsController {
    NSArray<PSSpecifier *> *_carsurfSpecifiers;
    BOOL _carsurfReentering;
}

- (NSString *)bundleIdentifier {
    id value = [self.specifier propertyForKey:@"carsurfBundle"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.specifier.name ?: @"App Display";
}

- (BOOL)carsurfIsEnabled {
    return [CSPrefsStore.sharedStore isAppEnabled:self.bundleIdentifier];
}

/// YES for an app that already ships its own CarPlay support. Its binary is
/// never touched — carsurf-helperd records it native-bridged and CarSurf bridges
/// its phone screen — so this screen must not offer to patch it.
- (id)readEnabled:(PSSpecifier *)specifier {
    return @(self.carsurfIsEnabled);
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    [CSPrefsStore.sharedStore setApp:self.bundleIdentifier enabled:[value boolValue]];
}

- (NSArray<PSSpecifier *> *)specifiers {
    if (_carsurfReentering) return _carsurfSpecifiers ?: @[];

    _carsurfReentering = YES;
    NSArray<PSSpecifier *> *stored = [super specifiers];
    _carsurfReentering = NO;
    if (stored.count > 0) return stored;

    if (!_carsurfSpecifiers) {
        NSMutableArray<PSSpecifier *> *result = [NSMutableArray new];

        // The one thing this whole screen exists to do: everything below is
        // detail for an app that's already on.
        PSSpecifier *enableGroup = [PSSpecifier groupSpecifierWithName:nil];
        // On-disk patching is retired: CarPlay admission is done entirely at
        // runtime on every supported release, so the app's bytes are never
        // modified and there is no per-app patch status to show.
        [enableGroup setProperty:@"Puts this app on the CarPlay dashboard. "
                                 @"Nothing on disk is modified — the app keeps "
                                 @"its original signature."
                          forKey:@"footerText"];
        [result addObject:enableGroup];

        PSSpecifier *enable =
            [PSSpecifier preferenceSpecifierNamed:@"Enable for CarPlay"
                                            target:self
                                               set:@selector(setEnabled:specifier:)
                                               get:@selector(readEnabled:)
                                            detail:Nil
                                              cell:PSSwitchCell
                                              edit:Nil];
        [result addObject:enable];

        // The old "CarPlay Qualification" section (status line, "Patch Now"
        // button, per-app patch log) is gone: on-disk patching is retired and
        // every app is admitted to CarPlay at runtime, so there is no background
        // re-sign to trigger or report on. carsurf-helperd no longer services a
        // patch request at all.

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"CarPlay Display"];
        [group setProperty:@"Orientation picks the shape of the viewport on the "
                           @"head unit; Layout is the interface the app builds "
                           @"for it. Scale below 1.0 fits more of the app on "
                           @"screen, above 1.0 makes controls easier to hit."
                   forKey:@"footerText"];
        [result addObject:group];

        PSSpecifier *layout =
            [PSSpecifier preferenceSpecifierNamed:@"Orientation"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSegmentCell
                                              edit:Nil];
        [layout setProperty:@"layoutMode" forKey:@"carsurfKey"];
        [layout setProperty:CSLayoutSegmentCell.class forKey:@"cellClass"];
        [layout setProperty:@(84.0) forKey:@"height"];
        [result addObject:layout];

        PSSpecifier *idiom =
            [PSSpecifier preferenceSpecifierNamed:@"Layout"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSegmentCell
                                              edit:Nil];
        [idiom setProperty:@"idiomMode" forKey:@"carsurfKey"];
        [idiom setProperty:@[ @"Auto", @"iPhone", @"iPad" ] forKey:@"carsurfItems"];
        [idiom setProperty:CSLayoutSegmentCell.class forKey:@"cellClass"];
        [idiom setProperty:@(84.0) forKey:@"height"];
        [result addObject:idiom];

        PSSpecifier *scale =
            [PSSpecifier preferenceSpecifierNamed:@"Scale"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSliderCell
                                              edit:Nil];
        [scale setProperty:@"scale" forKey:@"carsurfKey"];
        [scale setProperty:@(kCSMinScale) forKey:@"min"];
        [scale setProperty:@(kCSMaxScale) forKey:@"max"];
        [scale setProperty:@(1.0) forKey:@"default"];
        [scale setProperty:CSScaleSliderCell.class forKey:@"cellClass"];
        [scale setProperty:@(84.0) forKey:@"height"];
        [result addObject:scale];

        PSSpecifier *applyGroup =
            [PSSpecifier groupSpecifierWithName:@"Apply Changes"];
        [applyGroup setProperty:@"Close the app after changing layout or scale. "
                                @"The next phone or CarPlay launch uses the new values."
                        forKey:@"footerText"];
        [result addObject:applyGroup];

        PSSpecifier *close =
            [PSSpecifier preferenceSpecifierNamed:@"Close App to Apply Changes"
                                            target:self
                                               set:NULL
                                               get:NULL
                                            detail:Nil
                                              cell:PSButtonCell
                                              edit:Nil];
        close.buttonAction = @selector(closeApp);
        [close setProperty:@YES forKey:@"isDestructive"];
        [result addObject:close];
        _carsurfSpecifiers = result;
    }

    _carsurfReentering = YES;
    [self setSpecifiers:_carsurfSpecifiers];
    _carsurfReentering = NO;
    return _carsurfSpecifiers;
}

- (id)readAppValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"carsurfKey"];
    CSPrefsStore *store = CSPrefsStore.sharedStore;
    id value = [store value:key forApp:self.bundleIdentifier];
    if (!value) value = [store defaultValueForKey:key];
    if (value) return value;
    if ([key isEqualToString:@"scale"]) return @(1.0);
    if ([key isEqualToString:@"layoutMode"]) return @(CSLayoutModeHorizontal);
    if ([key isEqualToString:@"idiomMode"]) return @(CSIdiomModePhone);
    return @NO;
}

- (void)setAppValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"carsurfKey"];
    [CSPrefsStore.sharedStore setValue:value key:key
                                  forApp:self.bundleIdentifier];
}

- (void)closeApp {
    NSString *bundleID = self.bundleIdentifier;
    if (bundleID.length == 0) return;
    NSString *notification =
        [@"com.pavunato.carsurf/close/" stringByAppendingString:bundleID];
    notify_post(notification.UTF8String);
}

@end
