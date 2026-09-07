#import "CSRootListController.h"
#import "CSAppListController.h"
#import "CSPrefsStore.h"
#import "CSConfig.h"
#import "CSLayoutSegmentCell.h"
#import "CSScaleSliderCell.h"
#import "CSLog.h"
#import <objc/message.h>
#import <objc/runtime.h>

@implementation CSRootListController {
    // Built once and returned directly. Going through -setSpecifiers: and then
    // [super specifiers] relies on PSListController's private ivar surviving the
    // round trip; returning our own array cannot come back empty.
    NSArray<PSSpecifier *> *_carsurfSpecifiers;
    BOOL _carsurfReentering;
}

- (NSArray<PSSpecifier *> *)specifiers {
    // Settings tears down PSListController's own specifier state when the pane is
    // backgrounded and rebuilt on resume. The conventional theos pattern survives
    // that by caching in PS's private _specifiers ivar, which is not exported, so
    // instead: trust PS's state when it has any, and re-apply ours when it does
    // not. Without this the pane comes back blank after a trip to the home screen.
    if (_carsurfReentering) return _carsurfSpecifiers ?: @[];

    _carsurfReentering = YES;
    NSArray<PSSpecifier *> *stored = [super specifiers];
    _carsurfReentering = NO;
    if (stored.count > 0) return stored;

    if (!_carsurfSpecifiers) _carsurfSpecifiers = [self buildSpecifiers];

    _carsurfReentering = YES;
    [self setSpecifiers:_carsurfSpecifiers];
    _carsurfReentering = NO;

    CSLogImpl("prefs", "%s restored %lu specifiers after PS state was cleared",
                object_getClassName(self), (unsigned long)_carsurfSpecifiers.count);
    return _carsurfSpecifiers;
}

- (NSArray<PSSpecifier *> *)buildSpecifiers {
    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray new];

    // --- Master switch -----------------------------------------------------
    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:nil];
    [header setProperty:@"Puts any app you choose on the CarPlay display. "
                        @"Changes take effect after a respring."
                 forKey:@"footerText"];
    [specifiers addObject:header];

    [specifiers addObject:[self switchNamed:@"Enable CarSurf"
                                        key:@"enabled"
                                      scope:@"global"]];

    // --- App picker --------------------------------------------------------
    // One link, one list: tap an app, flip its switch. See CSAppListController
    // for why this used to be two separate screens.
    PSSpecifier *appsGroup = [PSSpecifier groupSpecifierWithName:@"Apps"];
    [appsGroup setProperty:@"Only the apps you turn on here appear on the car screen. "
                           @"Everything else on the dashboard stays as CarPlay left it."
                    forKey:@"footerText"];
    [specifiers addObject:appsGroup];

    PSSpecifier *picker = [PSSpecifier preferenceSpecifierNamed:@"Apps"
                                                        target:self
                                                           set:NULL
                                                           get:@selector(enabledAppSummary:)
                                                        detail:CSAppListController.class
                                                          cell:PSLinkListCell
                                                          edit:Nil];
    [specifiers addObject:picker];

    // --- Display defaults --------------------------------------------------
    PSSpecifier *displayGroup = [PSSpecifier groupSpecifierWithName:@"Display"];
    [displayGroup setProperty:@"Defaults for every enabled app; each app can "
                              @"override them. Scale below 1.0 fits more of the "
                              @"app on screen, above 1.0 makes controls easier to "
                              @"hit while driving."
                       forKey:@"footerText"];
    [specifiers addObject:displayGroup];

    PSSpecifier *scale = [PSSpecifier preferenceSpecifierNamed:@"Scale"
                                                       target:self
                                                          set:@selector(setValue:specifier:)
                                                          get:@selector(readValue:)
                                                       detail:Nil
                                                         cell:PSSliderCell
                                                         edit:Nil];
    [scale setProperty:@"scale" forKey:@"carsurfKey"];
    [scale setProperty:@"defaults" forKey:@"carsurfScope"];
    [scale setProperty:@(kCSMinScale) forKey:@"min"];
    [scale setProperty:@(kCSMaxScale) forKey:@"max"];
    [scale setProperty:@(1.0) forKey:@"default"];
    [scale setProperty:CSScaleSliderCell.class forKey:@"cellClass"];
    [scale setProperty:@(84.0) forKey:@"height"];
    [specifiers addObject:[self layoutModeSpecifierForScope:@"defaults"]];

    [specifiers addObject:[self idiomModeSpecifierForScope:@"defaults"]];

    [specifiers addObject:scale];

    // --- Diagnostics -------------------------------------------------------
    PSSpecifier *diagnosticsGroup = [PSSpecifier groupSpecifierWithName:@"Diagnostics"];
    [diagnosticsGroup setProperty:@"Verbose logging records CarSurf's admission and "
                                  @"scene-bridge activity to /var/mobile/Library/Logs/"
                                  @"carsurf.log for troubleshooting."
                           forKey:@"footerText"];
    [specifiers addObject:diagnosticsGroup];

    [specifiers addObject:[self switchNamed:@"Verbose Logging"
                                        key:@"verboseLogging"
                                      scope:@"global"]];

    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:@"Respring"
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:Nil
                                                            cell:PSButtonCell
                                                            edit:Nil];
    respring.buttonAction = @selector(respring);
    [respring setProperty:@YES forKey:@"isDestructive"];
    [specifiers addObject:respring];

    return specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    CSLogImpl("prefs", "root controller viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CSLogImpl("prefs", "root controller viewWillAppear (specifiers=%lu)",
                (unsigned long)[[self specifiers] count]);
}

#pragma mark - Specifier helpers

- (PSSpecifier *)switchNamed:(NSString *)name key:(NSString *)key scope:(NSString *)scope {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                           target:self
                                                              set:@selector(setValue:specifier:)
                                                              get:@selector(readValue:)
                                                           detail:Nil
                                                             cell:PSSwitchCell
                                                             edit:Nil];
    [specifier setProperty:key forKey:@"carsurfKey"];
    [specifier setProperty:scope forKey:@"carsurfScope"];
    return specifier;
}

- (PSSpecifier *)layoutModeSpecifierForScope:(NSString *)scope {
    PSSpecifier *specifier =
        [PSSpecifier preferenceSpecifierNamed:@"Orientation"
                                        target:self
                                           set:@selector(setValue:specifier:)
                                           get:@selector(readValue:)
                                        detail:Nil
                                          cell:PSSegmentCell
                                          edit:Nil];
    [specifier setProperty:@"layoutMode" forKey:@"carsurfKey"];
    [specifier setProperty:scope forKey:@"carsurfScope"];
    [specifier setProperty:CSLayoutSegmentCell.class forKey:@"cellClass"];
    [specifier setProperty:@(84.0) forKey:@"height"];
    return specifier;
}

- (PSSpecifier *)idiomModeSpecifierForScope:(NSString *)scope {
    PSSpecifier *specifier =
        [PSSpecifier preferenceSpecifierNamed:@"Layout"
                                        target:self
                                           set:@selector(setValue:specifier:)
                                           get:@selector(readValue:)
                                        detail:Nil
                                          cell:PSSegmentCell
                                          edit:Nil];
    [specifier setProperty:@"idiomMode" forKey:@"carsurfKey"];
    [specifier setProperty:scope forKey:@"carsurfScope"];
    [specifier setProperty:@[ @"Auto", @"iPhone", @"iPad" ] forKey:@"carsurfItems"];
    [specifier setProperty:CSLayoutSegmentCell.class forKey:@"cellClass"];
    [specifier setProperty:@(84.0) forKey:@"height"];
    return specifier;
}

#pragma mark - Value plumbing

- (id)readValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"carsurfKey"];
    NSString *scope = [specifier propertyForKey:@"carsurfScope"];
    CSPrefsStore *store = CSPrefsStore.sharedStore;

    id value = [scope isEqualToString:@"defaults"] ? [store defaultValueForKey:key]
                                                   : [store globalValueForKey:key];
    if (value) return value;

    // Mirror CSConfig's own defaults so the UI never shows a value the tweak
    // would not actually use.
    if ([key isEqualToString:@"scale"]) return @(1.0);
    if ([key isEqualToString:@"layoutMode"]) return @(CSLayoutModeHorizontal);
    if ([key isEqualToString:@"idiomMode"]) return @(CSIdiomModePhone);
    return @NO;
}

- (void)setValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"carsurfKey"];
    NSString *scope = [specifier propertyForKey:@"carsurfScope"];
    CSPrefsStore *store = CSPrefsStore.sharedStore;

    if ([scope isEqualToString:@"defaults"]) {
        [store setDefaultValue:value forKey:key];
    } else {
        [store setGlobalValue:value forKey:key];
    }
}

- (id)enabledAppSummary:(PSSpecifier *)specifier {
    NSUInteger count = CSPrefsStore.sharedStore.enabledAppCount;
    if (count == 0) return @"None";
    return count == 1 ? @"1 app" : [NSString stringWithFormat:@"%lu apps", (unsigned long)count];
}

#pragma mark - Respring

- (void)respring {
    // Settings cannot spawn processes, so ask the system to restart the render
    // server the same way the Reset Settings flow does.
    Class actionClass = NSClassFromString(@"SBSRelaunchAction");
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    if (!actionClass || !serviceClass) {
        NSLog(@"[CarSurf] respring unavailable; relaunch SpringBoard manually");
        return;
    }

    // options 4 = restart the render server, i.e. an ordinary respring.
    id action = ((id (*)(Class, SEL, NSString *, NSUInteger, NSURL *))objc_msgSend)(
        actionClass, @selector(actionWithReason:options:targetURL:), @"CarSurf", 4, nil);
    if (!action) return;

    id service = ((id (*)(Class, SEL))objc_msgSend)(serviceClass, @selector(sharedService));
    ((void (*)(id, SEL, NSSet *, id))objc_msgSend)(
        service, @selector(sendActions:withResult:), [NSSet setWithObject:action], nil);
}

@end
