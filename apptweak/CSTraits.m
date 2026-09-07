#define CS_TAG "traits"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSPrivate.h"
#import "CSRuntime.h"

// Gate G3. Apps that switch on traitCollection.userInterfaceIdiom see
// UIUserInterfaceIdiomCarPlay and either fall through to a default branch with
// no layout or refuse to build a UI at all. Reporting Phone keeps them on the
// code path they were written for.
//
// This used to also point +[UIScreen mainScreen] at the car screen, for apps
// that lay out against mainScreen.bounds rather than their scene's coordinate
// space. That was an opt-in per-app switch, and it is gone: the viewport is
// measured from the head unit's own scene now (CSCarViewportForWindow), so the
// override bought nothing but a phone-side UI laying out wrongly while bridged.

static CSAppOptions *CSOptionsForThisApp(void) {
    static CSAppOptions *options;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        options = [CSConfig.sharedConfig optionsForBundle:bundleID];
    });
    return options;
}

#pragma mark - Idiom

static UIUserInterfaceIdiom (*orig_userInterfaceIdiom)(id, SEL);
static UIUserInterfaceIdiom (*orig_deviceUserInterfaceIdiom)(id, SEL);

/// Both getters are process-global, so an override installed for the head unit
/// also answers every query the app's own phone-side UI makes. Settings is where
/// that bit: with no car scene of its own it still reported Pad, so
/// -[PSListController showConfirmationViewForSpecifier:] took the iPad branch,
/// threw building the "Forget This Car" alert, and aborted Preferences on every
/// tap — the car could not be forgotten at all. Bound to an actual car session
/// instead, which is also true from scene configuration onwards and so still
/// covers a CarPlay-launched app deciding its layout.
static UIUserInterfaceIdiom CSForcedIdiom(UIUserInterfaceIdiom original) {
    if (!CSIsBridgingForCar()) return original;

    switch (CSOptionsForThisApp().idiomMode) {
        case CSIdiomModePhone: return UIUserInterfaceIdiomPhone;
        case CSIdiomModePad:   return UIUserInterfaceIdiomPad;
        case CSIdiomModeAuto:  return original;
    }
    return original;
}

/// Once for each outcome rather than once overall, because the gate flips when a
/// car scene appears and a single line cannot show both sides of it.
static void CSLogIdiomOverrideOnce(const char *source,
                                     UIUserInterfaceIdiom original,
                                     UIUserInterfaceIdiom forced) {
    static dispatch_once_t appliedOnce;
    static dispatch_once_t leftAloneOnce;
    if (forced != original) {
        dispatch_once(&appliedOnce, ^{
            CSLog("idiom query via %s: original=%ld forced=%ld", source,
                    (long)original, (long)forced);
        });
    } else {
        dispatch_once(&leftAloneOnce, ^{
            CSLog("idiom query via %s: original=%ld left alone (bridgingForCar=%d)",
                    source, (long)original, CSIsBridgingForCar());
        });
    }
}

static UIUserInterfaceIdiom cs_userInterfaceIdiom(id self, SEL _cmd) {
    UIUserInterfaceIdiom idiom = orig_userInterfaceIdiom(self, _cmd);
    UIUserInterfaceIdiom forced = CSForcedIdiom(idiom);
    CSLogIdiomOverrideOnce("UITraitCollection", idiom, forced);
    return forced;
}

static UIUserInterfaceIdiom cs_deviceUserInterfaceIdiom(id self, SEL _cmd) {
    UIUserInterfaceIdiom idiom = orig_deviceUserInterfaceIdiom(self, _cmd);
    UIUserInterfaceIdiom forced = CSForcedIdiom(idiom);
    CSLogIdiomOverrideOnce("UIDevice", idiom, forced);
    return forced;
}

#pragma mark - Install

void CSInstallTraitOverrides(void) {
    CSAppOptions *options = CSOptionsForThisApp();

    BOOL traitIdiom = NO;
    BOOL deviceIdiom = NO;
    if (options.idiomMode != CSIdiomModeAuto) {
        traitIdiom = CSSwizzleInstanceMethod(UITraitCollection.class,
                                              @selector(userInterfaceIdiom),
                                              (IMP)cs_userInterfaceIdiom,
                                              (IMP *)&orig_userInterfaceIdiom);
        deviceIdiom = CSSwizzleInstanceMethod(UIDevice.class,
                                               @selector(userInterfaceIdiom),
                                               (IMP)cs_deviceUserInterfaceIdiom,
                                               (IMP *)&orig_deviceUserInterfaceIdiom);
    }

    CSLog("trait overrides installed (traitIdiom=%d deviceIdiom=%d mode=%ld)",
          traitIdiom, deviceIdiom, (long)options.idiomMode);
}
