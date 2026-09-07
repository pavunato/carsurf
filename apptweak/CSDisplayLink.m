#define CS_TAG "clock"

// Gate G4: give the app a frame clock that belongs to the display it is on.
//
// Measured on device — YouTube Music on a connected head unit, phone display
// asleep, app foreground-active on the car scene:
//
//     displayLink main=0 car=60 tick(s)/s
//
// A CADisplayLink created the ordinary way belongs to the *main* display, and
// the main display is asleep for the whole drive. So every bridged app has a
// stopped frame clock on the head unit: a scrubber that never advances, a
// synced-lyrics list that never scrolls, any custom animation frozen — while
// the same app's timer-driven UI keeps working, which is what makes the symptom
// look app-specific rather than systemic.
//
// A bridged app is therefore handed a link that follows whichever display is
// actually running. The car screen's link drives it; a link on the screen the
// app originally asked for stands by and takes over if the car one stops — the
// vehicle is unplugged, the app stays alive on the phone, and the link it has
// been holding since the drive has to keep working. The app sees one ordinary
// CADisplayLink and never learns about the second.

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

/// How long the standby link waits after the last car-screen tick before it
/// starts delivering. Six frames at 60Hz: long enough that a normally running
/// car link never lets it through, short enough to be invisible when the car
/// display goes away mid-animation.
static const CFTimeInterval kCSStandbyGrace = 0.1;

static const void *kCSPairKey = &kCSPairKey;

/// Creating the pair re-enters both hooks (they are how the two links are made).
static _Thread_local BOOL gBuilding = NO;

@interface CSDisplayLinkPair : NSObject
- (instancetype)initWithTarget:(id)target selector:(SEL)selector;
- (void)adoptPrimary:(CADisplayLink *)primary standby:(CADisplayLink *)standby;
- (void)addStandbyToRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode;
- (void)removeStandbyFromRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode;
- (void)invalidateStandby;
@end

@implementation CSDisplayLinkPair {
    id _target;                    // strong, exactly as CADisplayLink retains it
    SEL _selector;
    __weak CADisplayLink *_primary; // the app holds this one; weak breaks the cycle
    CADisplayLink *_standby;
    CFTimeInterval _lastPrimaryTick;
}

- (instancetype)initWithTarget:(id)target selector:(SEL)selector {
    self = [super init];
    if (!self) return nil;
    _target = target;
    _selector = selector;
    return self;
}

- (void)adoptPrimary:(CADisplayLink *)primary standby:(CADisplayLink *)standby {
    _primary = primary;
    _standby = standby;
}

- (void)addStandbyToRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode {
    [_standby addToRunLoop:runLoop forMode:mode];
}

- (void)removeStandbyFromRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode {
    [_standby removeFromRunLoop:runLoop forMode:mode];
}

- (void)invalidateStandby {
    [_standby invalidate];
    _standby = nil;      // releases the link that retains this pair
    _target = nil;
}

- (void)csForward:(CADisplayLink *)link {
    id target = _target;
    if (!target) return;
    // The app's selector may take the link or no argument at all; an extra
    // argument to a method that ignores it is harmless.
    ((void (*)(id, SEL, CADisplayLink *))objc_msgSend)(target, _selector, link);
}

- (void)csPrimaryTick:(CADisplayLink *)link {
    _lastPrimaryTick = CACurrentMediaTime();
    [self csForward:link];
}

- (void)csStandbyTick:(CADisplayLink *)link {
    CADisplayLink *primary = _primary;
    // Paused is the app's decision and applies to the pair, not to one link.
    if (!primary || primary.isPaused) return;
    if (CACurrentMediaTime() - _lastPrimaryTick < kCSStandbyGrace) return;
    if (link.preferredFramesPerSecond != primary.preferredFramesPerSecond) {
        link.preferredFramesPerSecond = primary.preferredFramesPerSecond;
    }
    [self csForward:link];
}

@end

static void CSLogBridgedClockOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CSLog("display links are now driven by the head unit's screen, with the "
              "app's original screen on standby");
    });
}

/// Returns the link to hand back to the app, or nil to let the original
/// implementation answer.
static CADisplayLink *CSMakeBridgedLink(UIScreen *carScreen, UIScreen *originalScreen,
                                        id target, SEL selector) {
    if (gBuilding || !target || !selector || !carScreen) return nil;

    CSDisplayLinkPair *pair = [[CSDisplayLinkPair alloc] initWithTarget:target
                                                               selector:selector];
    gBuilding = YES;
    CADisplayLink *primary = [carScreen displayLinkWithTarget:pair
                                                     selector:@selector(csPrimaryTick:)];
    CADisplayLink *standby = originalScreen && originalScreen != carScreen
        ? [originalScreen displayLinkWithTarget:pair
                                       selector:@selector(csStandbyTick:)]
        : nil;
    gBuilding = NO;

    if (!primary) return nil;
    [pair adoptPrimary:primary standby:standby];
    // Ties the pair's lifetime to the link the app holds.
    objc_setAssociatedObject(primary, kCSPairKey, pair, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CSLogBridgedClockOnce();
    return primary;
}

static CSDisplayLinkPair *CSPairForLink(CADisplayLink *link) {
    return objc_getAssociatedObject(link, kCSPairKey);
}

#pragma mark - Hooks

static CADisplayLink *(*orig_classDisplayLink)(id, SEL, id, SEL);

static CADisplayLink *cs_classDisplayLink(id self, SEL _cmd, id target, SEL selector) {
    CADisplayLink *bridged = CSMakeBridgedLink(CSCarScreen(), UIScreen.mainScreen,
                                               target, selector);
    return bridged ?: orig_classDisplayLink(self, _cmd, target, selector);
}

static CADisplayLink *(*orig_screenDisplayLink)(UIScreen *, SEL, id, SEL);

static CADisplayLink *cs_screenDisplayLink(UIScreen *self, SEL _cmd, id target,
                                           SEL selector) {
    UIScreen *car = CSCarScreen();
    if (self == car) return orig_screenDisplayLink(self, _cmd, target, selector);
    CADisplayLink *bridged = CSMakeBridgedLink(car, self, target, selector);
    return bridged ?: orig_screenDisplayLink(self, _cmd, target, selector);
}

// The standby link has to be registered, unregistered and torn down exactly as
// the app does it to the link it holds — including never firing at all if the
// app never puts its link in a run loop.

static void (*orig_addToRunLoop)(CADisplayLink *, SEL, NSRunLoop *, NSRunLoopMode);

static void cs_addToRunLoop(CADisplayLink *self, SEL _cmd, NSRunLoop *runLoop,
                            NSRunLoopMode mode) {
    orig_addToRunLoop(self, _cmd, runLoop, mode);
    [CSPairForLink(self) addStandbyToRunLoop:runLoop forMode:mode];
}

static void (*orig_removeFromRunLoop)(CADisplayLink *, SEL, NSRunLoop *, NSRunLoopMode);

static void cs_removeFromRunLoop(CADisplayLink *self, SEL _cmd, NSRunLoop *runLoop,
                                 NSRunLoopMode mode) {
    orig_removeFromRunLoop(self, _cmd, runLoop, mode);
    [CSPairForLink(self) removeStandbyFromRunLoop:runLoop forMode:mode];
}

static void (*orig_invalidate)(CADisplayLink *, SEL);

static void cs_invalidate(CADisplayLink *self, SEL _cmd) {
    [CSPairForLink(self) invalidateStandby];
    orig_invalidate(self, _cmd);
}

#pragma mark - Install

void CSInstallDisplayLinkBridge(void) {
    // Looked up, never messaged. This runs from a dylib constructor, and
    // +[UIScreen class] there sends +initialize, which walks into
    // -[_UIApplicationConfigurationLoader _loadInitializationContext...] and
    // blocks on a dispatch_once UIKit has not reached yet: the app dies on the
    // 20-second process-launch watchdog, every launch. Device-verified.
    Class screen = CSLookupClass("UIScreen");
    Class link = CSLookupClass("CADisplayLink");

    // All five hooks defer to the original implementation until a car scene is
    // live, so installing them costs a bridged-app launch nothing.
    BOOL classLink = CSSwizzleClassMethod(
        link, @selector(displayLinkWithTarget:selector:),
        (IMP)cs_classDisplayLink, (IMP *)&orig_classDisplayLink);
    BOOL screenLink = CSSwizzleInstanceMethod(
        screen, @selector(displayLinkWithTarget:selector:),
        (IMP)cs_screenDisplayLink, (IMP *)&orig_screenDisplayLink);
    BOOL add = CSSwizzleInstanceMethod(
        link, @selector(addToRunLoop:forMode:),
        (IMP)cs_addToRunLoop, (IMP *)&orig_addToRunLoop);
    BOOL remove = CSSwizzleInstanceMethod(
        link, @selector(removeFromRunLoop:forMode:),
        (IMP)cs_removeFromRunLoop, (IMP *)&orig_removeFromRunLoop);
    BOOL invalidate = CSSwizzleInstanceMethod(
        link, @selector(invalidate),
        (IMP)cs_invalidate, (IMP *)&orig_invalidate);

    CSLog("display link bridge installed (class=%d screen=%d add=%d remove=%d "
          "invalidate=%d)", classLink, screenLink, add, remove, invalidate);

    if (!classLink && !screenLink) {
        CSLog("WARNING: no display-link hook landed; animations an app drives "
              "from a display link will stay frozen on the head unit.");
    }
}
