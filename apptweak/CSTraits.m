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

static UIUserInterfaceIdiom CSForcedIdiom(UIUserInterfaceIdiom original) {
    switch (CSOptionsForThisApp().idiomMode) {
        case CSIdiomModePhone: return UIUserInterfaceIdiomPhone;
        case CSIdiomModePad:   return UIUserInterfaceIdiomPad;
        case CSIdiomModeAuto:  return original;
    }
    return original;
}

static void CSLogIdiomOverrideOnce(const char *source,
                                     UIUserInterfaceIdiom original,
                                     UIUserInterfaceIdiom forced) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CSLog("idiom query via %s: original=%ld forced=%ld", source,
                (long)original, (long)forced);
    });
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
