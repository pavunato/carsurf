#define CS_TAG "mirror"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSPrivate.h"
#import "CSRuntime.h"
#import <objc/message.h>

// Apps with no UIApplicationSceneManifest run in UIKit's single-window
// compatibility mode: their delegate owns exactly one UIWindow and there is no
// scene delegate to build a second UI. The car scene still connects (see
// CSSceneBridge.m) but arrives empty.
//
// Rather than host the phone window's CAContext in a CALayerHost and hand-forward
// touches — which loses gestures, keyboard, and presentation contexts — this
// *transplants* the app's root view controller into the car window and puts it
// back on disconnect. Touch, gestures, modals, and the keyboard then work with no
// forwarding code at all, because UIKit is doing its normal job on a window that
// happens to live on the head unit.
//
// The trade-off is that the phone screen goes blank while the app is bridged. A
// view controller can only belong to one window, and duplicating the render tree
// is what the layer-hosting approach buys at the cost of an inert UI. For a screen
// you are not supposed to be looking at while driving, blank is the right answer.

static UIWindow *gSourceWindow;
static UIViewController *gTransplantedRoot;
static UIWindow *gCarWindow;
static __weak UIWindowScene *gCarScene;
static CSAppOptions *gCarOptions;
static CGSize gSourceSize;
static __weak id gWindowOwningDelegate;
static BOOL gDelegateWindowReassigned;
static BOOL gCompatibilityHooksInstalled;
static NSUInteger gGeometryReconcileGeneration;
static NSUInteger gSourceRootAliasCount;
static UIViewController *(*gOriginalWindowRootViewController)(UIWindow *, SEL);
static void (*gOriginalViewDidAppear)(UIViewController *, SEL, BOOL);
static void (*gOriginalViewDidDisappear)(UIViewController *, SEL, BOOL);
static void (*gOriginalPresent)(UIViewController *, SEL, UIViewController *, BOOL,
                                void (^)(void));
static void (*gOriginalDismiss)(UIViewController *, SEL, BOOL, void (^)(void));

static UIEdgeInsets CSConfigureTransplantWindow(UIWindow *window,
                                                  UIWindowScene *scene,
                                                  CSAppOptions *options,
                                                  CGSize sourceSize,
                                                  BOOL autoHorizontal,
                                                  BOOL *outPortrait);

/// Keep legacy application-window discovery coherent after transplantation.
/// UIKit still owns exactly one real root: the car window. Only reads through
/// the now-empty source window are aliased, and only while that exact root is
/// actively transplanted. This repairs callers that start from delegate.window
/// without changing UIApplication.keyWindow or redirecting presentations.
static UIViewController *cs_windowRootViewController(UIWindow *self, SEL _cmd) {
    UIViewController *root = gOriginalWindowRootViewController(self, _cmd);
    if (!root && self == gSourceWindow && gCarWindow && gTransplantedRoot) {
        gSourceRootAliasCount++;
        if (gSourceRootAliasCount <= 8) {
            CSLog("aliased empty source-window root to transplanted root "
                  "(read=%lu root=%s)",
                  (unsigned long)gSourceRootAliasCount,
                  object_getClassName(gTransplantedRoot));
        }
        return gTransplantedRoot;
    }
    return root;
}

/// What the presenting hierarchy was attached to before a modal presentation.
///
/// A full-screen presentation is allowed to detach the views underneath it — the
/// app itself does this to free the player, and UIKit does it for the snapshotted
/// branches it replaces. What the app then owes is symmetry: everything it took
/// apart on the way in goes back together on the way out. On the phone that
/// second half is driven by the geometry change the dismissal brings with it. A
/// transplanted app never gets one: the car window is a fixed landscape canvas
/// that neither rotates nor resizes, so a restore that waits for a size or
/// orientation transition waits forever and a branch stays detached.
///
/// So the ledger records the attachment of every loaded child controller's view
/// before the presentation and puts back whatever is still missing once the
/// dismissal has settled. Only controllers that are *still children* of a
/// controller back on the car window are restored: a branch the app tore down for
/// real has no parent left to be restored under, and rebuilding it is the app's
/// job, not ours.
@interface CSViewAttachment : NSObject
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) UIView *view;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic) NSUInteger index;
@property (nonatomic) CGRect frame;
@end

@implementation CSViewAttachment
@end

static NSMutableArray<CSViewAttachment *> *gPresentationAttachments;

static void CSRecordAttachments(UIViewController *controller,
                                NSMutableArray<CSViewAttachment *> *into) {
    if (into.count >= 512) return;

    UIView *view = controller.viewIfLoaded;
    UIView *superview = view.superview;
    if (superview && view.window == gCarWindow) {
        CSViewAttachment *attachment = [CSViewAttachment new];
        attachment.controller = controller;
        attachment.view = view;
        attachment.superview = superview;
        attachment.index = [superview.subviews indexOfObject:view];
        attachment.frame = view.frame;
        [into addObject:attachment];
    }

    // Children only. The presented branch has its own lifetime and is not part
    // of what the presentation displaces.
    for (UIViewController *child in controller.childViewControllers) {
        CSRecordAttachments(child, into);
    }
}

/// The modal still standing over the car window, if any. A dismissal that only
/// uncovers another modal has not put the app back yet.
static UIViewController *CSCarWindowPresentedController(void) {
    return gCarWindow.rootViewController.presentedViewController;
}

/// Run repeatedly across a dismissal: once as it starts, again as it reveals
/// something, and a last time once it has settled. Every attachment is guarded on
/// the view actually being detached right now, so an early pass fills in what is
/// already missing — the title and view count under a watch page, in practice —
/// and a later pass catches anything the app took longer to drop. Only the final
/// pass spends the ledger.
static void CSRestoreDisplacedAttachments(const char *trigger, BOOL final) {
    NSArray<CSViewAttachment *> *ledger = gPresentationAttachments;
    if (final) gPresentationAttachments = nil;
    if (!gCarWindow || ledger.count == 0) return;

    NSUInteger restored = 0;
    for (CSViewAttachment *attachment in ledger) {
        UIViewController *controller = attachment.controller;
        UIView *view = attachment.view;
        UIView *superview = attachment.superview;
        if (!controller || !view || view.superview) continue;

        // Merely detached, not torn down: still a child of a controller whose
        // own view is back on the car window, and its old container is too.
        UIViewController *parent = controller.parentViewController;
        if (!parent || parent.viewIfLoaded.window != gCarWindow) continue;
        if (!superview || superview.window != gCarWindow) continue;

        [superview insertSubview:view
                         atIndex:MIN(attachment.index, superview.subviews.count)];
        // The app slid this view out of the way before dropping it; put it back
        // where it was. A container that lays its subviews out itself will
        // overwrite this on the next pass, which is the correct outcome either way.
        view.frame = attachment.frame;
        restored++;
        CSLog("restored %s under %s (index=%lu frame=%.0fx%.0f), displaced by a "
              "presentation and never re-attached",
              object_getClassName(controller), object_getClassName(superview),
              (unsigned long)attachment.index,
              attachment.frame.size.width, attachment.frame.size.height);
    }

    if (restored > 0) {
        [gCarWindow.rootViewController.view setNeedsLayout];
        CSLog("presentation restore complete (restored=%lu of %lu recorded, "
              "trigger=%s)", (unsigned long)restored,
              (unsigned long)ledger.count, trigger);
    }
}

/// A phone leaves fullscreen by rotating back, and the window size change that
/// comes with it is what makes every controller recompute its layout. The car
/// window never changes size, so that transition never fires and an app keeps
/// whatever geometry it cached while it was fullscreen: YouTube's player returns
/// at video aspect — width x 9/16, 670pt inside a 480pt window — filling the
/// width with the picture running off the bottom. Opening the same video from
/// scratch lays it out correctly at 265pt, so the app is not confused by the
/// canvas; it is simply never told to look at it again.
///
/// Move the window off its size and back to deliver that transition. Nothing
/// about this is specific to one app: any app that recomputes layout on a size
/// change is waiting for the same signal, and one that does not is unaffected.
/// Armed the moment a dismissal starts on the car window, spent as soon as the
/// controller it reveals has appeared. Waiting on a timer instead costs the whole
/// guessed delay on top of the app's exit animation, which reads as the layout
/// visibly correcting itself a beat after the video is already back.
static BOOL gPendingSizeTransition = NO;

static void CSDeliverSizeTransition(void) {
    if (!gCarWindow) return;

    CGRect bounds = gCarWindow.bounds;
    if (bounds.size.height < 2.0) return;

    CGRect nudged = bounds;
    nudged.size.height -= 1.0;
    gCarWindow.bounds = nudged;
    [gCarWindow layoutIfNeeded];
    gCarWindow.bounds = bounds;
    [gCarWindow layoutIfNeeded];

    CSLog("delivered a size transition at %.0fx%.0f after a fullscreen dismissal",
          bounds.size.width, bounds.size.height);
}

/// Everything a fullscreen dismissal leaves to put right, in one place: views the
/// presentation displaced, then the size transition that makes the app lay the
/// result out again. Both triggers call this; whichever arrives once the
/// dismissal is genuinely over does the work.
static void CSDeliverPendingRepair(const char *trigger, BOOL final) {
    if (!gCarWindow || CSCarWindowPresentedController()) return;

    if (gPresentationAttachments) CSRestoreDisplacedAttachments(trigger, final);
    if (gPendingSizeTransition) {
        gPendingSizeTransition = NO;
        CSDeliverSizeTransition();
    }
}

static void cs_present(UIViewController *self, SEL _cmd,
                       UIViewController *controller, BOOL animated,
                       void (^completion)(void)) {
    // Only the outermost presentation is recorded, and a stale ledger left by a
    // dismissal that never reached this hook is replaced rather than trusted:
    // nothing is covering the window, so nothing it describes is displaced.
    if (gCarWindow && gTransplantedRoot && !CSCarWindowPresentedController() &&
        self.viewIfLoaded.window == gCarWindow) {
        NSMutableArray<CSViewAttachment *> *ledger = [NSMutableArray array];
        CSRecordAttachments(gTransplantedRoot, ledger);
        gPresentationAttachments = ledger;
        CSVLog("presentation by %s over %s: %lu attached controller view(s) recorded",
               object_getClassName(self), object_getClassName(controller),
               (unsigned long)ledger.count);
    }
    gOriginalPresent(self, _cmd, controller, animated, completion);
}

static void cs_dismiss(UIViewController *self, SEL _cmd, BOOL animated,
                       void (^completion)(void)) {
    BOOL onCar = gCarWindow && self.viewIfLoaded.window == gCarWindow;
    if (onCar) gPendingSizeTransition = YES;
    void (^wrapped)(void) = ^{
        if (onCar) {
            // After the dismissal has settled, so the app's own restore runs
            // first and this only corrects what it left behind.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // Fallback: a dismissal that reveals nothing gets no
                // did-appear, and an app that restores late is caught here.
                CSDeliverPendingRepair("dismissal settled", YES);
            });
        }
        if (completion) completion();
    };
    gOriginalDismiss(self, _cmd, animated, wrapped);

    // The views the presentation displaced are already detached and the modal
    // covering them is on its way out, so put them back now rather than at the
    // end of the exit animation. Waiting until the reveal has finished is what
    // reads as lag: the watch page slides in with a hole where its title and
    // view count belong and only fills once the animation is over. Not routed
    // through CSDeliverPendingRepair because the modal is still presented at
    // this point, which is exactly the case that guard exists to reject.
    if (onCar) CSRestoreDisplacedAttachments("dismissal started", NO);
}

static void CSLogTransplantedStateAfterTransition(void) {
    if (!gCarWindow || !gCarScene || !gCarOptions || !gTransplantedRoot) return;

    CGSize mainSize = UIScreen.mainScreen.bounds.size;
    CGSize carSize = gCarScene.screen.bounds.size;
    // Traits and orientation alongside the geometry, because an app picks its
    // layout from these and not from the bounds. A landscape window that
    // reports itself portrait gets the app's portrait layout: content stacked
    // top-to-bottom in a canvas that has no height to stack in.
    UITraitCollection *traits = gCarWindow.traitCollection;
    CSLog("transplanted state after controller transition "
          "(root=%s window=%.0fx%.0f interfaceOrientation=%ld "
          "idiom=%ld hSize=%ld vSize=%ld "
          "mainScreen=%.0fx%.0f carScreen=%.0fx%.0f)",
          object_getClassName(gTransplantedRoot),
          gCarWindow.bounds.size.width, gCarWindow.bounds.size.height,
          (long)gCarScene.interfaceOrientation,
          (long)traits.userInterfaceIdiom,
          (long)traits.horizontalSizeClass, (long)traits.verticalSizeClass,
          mainSize.width, mainSize.height, carSize.width, carSize.height);
}

static void CSScheduleTransplantedLayoutReconciliation(UIViewController *controller) {
    if (!gCarWindow || controller.viewIfLoaded.window != gCarWindow) return;

    NSUInteger generation = ++gGeometryReconcileGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gGeometryReconcileGeneration) return;
        CSLogTransplantedStateAfterTransition();
    });
}

static void cs_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    gOriginalViewDidAppear(self, _cmd, animated);
    if (self.viewIfLoaded.window == gCarWindow) {
        CSLog("controller transition did-appear class=%s parent=%s presenting=%s "
              "presented=%s frame=%.0fx%.0f",
              object_getClassName(self),
              self.parentViewController
                  ? object_getClassName(self.parentViewController) : "nil",
              self.presentingViewController
                  ? object_getClassName(self.presentingViewController) : "nil",
              self.presentedViewController
                  ? object_getClassName(self.presentedViewController) : "nil",
              self.viewIfLoaded.bounds.size.width,
              self.viewIfLoaded.bounds.size.height);
        // The app has finished putting back whatever the fullscreen presentation
        // covered, so this is the earliest point the size transition can land
        // without being overwritten by that restore. Next turn, so this appear
        // pass completes first.
        dispatch_async(dispatch_get_main_queue(), ^{
            CSDeliverPendingRepair("did-appear", NO);
        });
    }
    CSScheduleTransplantedLayoutReconciliation(self);
}

static void cs_viewDidDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    gOriginalViewDidDisappear(self, _cmd, animated);
    if (self.viewIfLoaded.window == gCarWindow) {
        CSLog("controller transition did-disappear class=%s parent=%s "
              "presenting=%s presented=%s frame=%.0fx%.0f",
              object_getClassName(self),
              self.parentViewController
                  ? object_getClassName(self.parentViewController) : "nil",
              self.presentingViewController
                  ? object_getClassName(self.presentingViewController) : "nil",
              self.presentedViewController
                  ? object_getClassName(self.presentedViewController) : "nil",
              self.viewIfLoaded.bounds.size.width,
              self.viewIfLoaded.bounds.size.height);
    }
    CSScheduleTransplantedLayoutReconciliation(self);
}

static void CSInstallTransplantCompatibilityHooks(void) {
    if (gCompatibilityHooksInstalled) return;
    gCompatibilityHooksInstalled = YES;

    BOOL root = CSSwizzleInstanceMethod(UIWindow.class,
        @selector(rootViewController), (IMP)cs_windowRootViewController,
        (IMP *)&gOriginalWindowRootViewController);
    BOOL appeared = CSSwizzleInstanceMethod(UIViewController.class,
        @selector(viewDidAppear:), (IMP)cs_viewDidAppear,
        (IMP *)&gOriginalViewDidAppear);
    BOOL disappeared = CSSwizzleInstanceMethod(UIViewController.class,
        @selector(viewDidDisappear:), (IMP)cs_viewDidDisappear,
        (IMP *)&gOriginalViewDidDisappear);
    BOOL present = CSSwizzleInstanceMethod(UIViewController.class,
        @selector(presentViewController:animated:completion:), (IMP)cs_present,
        (IMP *)&gOriginalPresent);
    BOOL dismiss = CSSwizzleInstanceMethod(UIViewController.class,
        @selector(dismissViewControllerAnimated:completion:), (IMP)cs_dismiss,
        (IMP *)&gOriginalDismiss);
    CSLog("generic transplant compatibility installed "
          "(sourceRoot=%d appear=%d disappear=%d present=%d dismiss=%d)",
          root, appeared, disappeared, present, dismiss);
}

/// Positions the actual app window inside whatever CarPlay's persistent chrome
/// leaves free — a leading sidebar on a landscape head unit, a bottom bar on a
/// portrait one — then applies the user's render scale inside that rectangle. The app's
/// own root controller remains the window root so its menus and presentations
/// use their normal UIKit hierarchy.
static UIEdgeInsets CSConfigureTransplantWindow(UIWindow *window,
                                                  UIWindowScene *scene,
                                                  CSAppOptions *options,
                                                  CGSize sourceSize,
                                                  BOOL autoHorizontal,
                                                  BOOL *outPortrait) {
    // Explicit layout modes are hard constraints. Only Auto is allowed to switch
    // from the source window's natural portrait shape to horizontal for video.
    UIEdgeInsets sceneSafeArea = UIEdgeInsetsZero;
    CGRect usableFrame = CSCarViewportForWindow(window, scene, options, sourceSize,
                                                autoHorizontal, &sceneSafeArea,
                                                outPortrait);

    CGFloat scale = options.scale > 0.01 ? options.scale : 1.0;
    window.frame = usableFrame;
    window.bounds = CGRectMake(0, 0, usableFrame.size.width / scale,
                               usableFrame.size.height / scale);
    window.layer.anchorPoint = CGPointZero;
    window.layer.position = usableFrame.origin;
    window.layer.transform = CATransform3DMakeScale(scale, scale, 1.0);
    [window layoutIfNeeded];
    CSNeutralizeResidualSafeArea(window);
    return sceneSafeArea;
}

BOOL CSAppIsSingleWindowOnly(void) {
    static BOOL singleWindow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *manifest = NSBundle.mainBundle.infoDictionary[@"UIApplicationSceneManifest"];
        NSDictionary *configurations = [manifest isKindOfClass:NSDictionary.class]
                                           ? manifest[@"UISceneConfigurations"] : nil;

        // Template roles do not count. Some native CarPlay apps declare a
        // manifest whose only configurations are
        // CPTemplateApplication* ones, so counting them called it multi-scene
        // and left it in independent-scene mode. Nothing then builds the car
        // UI: the app has no plain window-scene delegate to answer the role
        // rewrite with, and CSSceneManifestSpoof.m has already hidden its
        // template roles and entitlements from CarPlay, so the template path is
        // gone too. The scene connected and stayed empty. Counting only the
        // app's non-template configurations puts these apps in transplant mode,
        // which is the one path that does not depend on the app cooperating.
        // The same prefix is what the host side strips; see
        // CSConfigurationsWithoutTemplateRoles in CSSceneManifestSpoof.m.
        NSUInteger phoneConfigurations = 0;
        if ([configurations isKindOfClass:NSDictionary.class]) {
            for (NSString *role in configurations.allKeys) {
                if (![role isKindOfClass:NSString.class]) continue;
                if ([role hasPrefix:@"CPTemplateApplication"]) continue;
                phoneConfigurations++;
            }
        }

        singleWindow = phoneConfigurations == 0;
        CSVLog("scene manifest %s, %lu non-template configuration(s) -> %s mode",
                 [configurations isKindOfClass:NSDictionary.class] ? "present"
                                                                   : "absent/empty",
                 (unsigned long)phoneConfigurations,
                 singleWindow ? "transplant" : "independent scene");
    });
    return singleWindow;
}

/// Logs every window the app owns and where it lives. When CarPlay launches an app
/// that was not already running, "no UI to transplant" is ambiguous between the app
/// having built nothing and our having looked in the wrong place; this settles it.
static void CSLogWindowInventory(void) {
    UIApplication *application = UIApplication.sharedApplication;

    id delegate = application.delegate;
    UIWindow *delegateWindow = nil;
    if ([delegate respondsToSelector:@selector(window)]) {
        delegateWindow = [delegate performSelector:@selector(window)];
    }
    CSLog("inventory: delegate=%s delegate.window=%s rootVC=%s",
            object_getClassName(delegate),
            delegateWindow ? object_getClassName(delegateWindow) : "nil",
            delegateWindow.rootViewController ? object_getClassName(delegateWindow.rootViewController)
                                              : "nil");

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        CSLog("inventory: scene %s role=%s bridged=%d windows=%lu",
                object_getClassName(scene), scene.session.role.UTF8String,
                CSIsBridgedCarScene(scene), (unsigned long)windowScene.windows.count);
        for (UIWindow *window in windowScene.windows) {
            CSLog("inventory:   window %s rootVC=%s hidden=%d",
                    object_getClassName(window),
                    window.rootViewController ? object_getClassName(window.rootViewController)
                                              : "nil",
                    window.hidden);
        }
    }
}

/// A window whose root view controller we can move to the head unit.
///
/// Searched widest-first, because in single-window compatibility mode UIKit hands
/// the app's only window to the delegate rather than to a scene we can enumerate:
///   1. the delegate's own -window (compatibility mode)
///   2. any window on a scene that is not the car scene
///   3. any window on the car scene — meaning UIKit already placed the app's UI
///      there, in which case nothing needs moving at all
static UIWindow *CSTransplantSourceWindow(UIWindowScene *carScene,
                                            BOOL *outAlreadyOnCarScene) {
    if (outAlreadyOnCarScene) *outAlreadyOnCarScene = NO;
    UIApplication *application = UIApplication.sharedApplication;

    id delegate = application.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        UIWindow *window = [delegate performSelector:@selector(window)];
        if (window.rootViewController && window != gCarWindow) {
            if (window.windowScene == carScene && outAlreadyOnCarScene) {
                *outAlreadyOnCarScene = YES;
            }
            return window;
        }
    }

    UIWindow *onCarScene = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            if (!window.rootViewController || window == gCarWindow) continue;
            if (scene == carScene || CSIsBridgedCarScene(scene)) {
                onCarScene = onCarScene ?: window;
                continue;
            }
            return window; // a genuine phone-side window: prefer it
        }
    }

    if (onCarScene && outAlreadyOnCarScene) *outAlreadyOnCarScene = YES;
    return onCarScene;
}

static void CSAttemptTransplant(UIWindowScene *scene, CSAppOptions *options,
                                  NSInteger attemptsLeft);

void CSStartMirroringIntoScene(UIWindowScene *scene, CSAppOptions *options) {
    if (gCarWindow) {
        CSLog("already transplanted; ignoring duplicate request");
        return;
    }
    CSInstallTransplantCompatibilityHooks();
    CSAttemptTransplant(scene, options, 10);
}

static void CSAttemptTransplant(UIWindowScene *scene, CSAppOptions *options,
                                  NSInteger attemptsLeft) {
    if (gCarWindow) return;
    if (scene.activationState == UISceneActivationStateUnattached) {
        CSLog("car scene went away before the transplant could run");
        return;
    }

    BOOL alreadyOnCarScene = NO;
    UIWindow *source = CSTransplantSourceWindow(scene, &alreadyOnCarScene);
    UIViewController *root = source.rootViewController;
    if (!root) {
        // When CarPlay is what launched the app, its window may not exist yet.
        // Retry briefly rather than giving up on the first frame.
        if (attemptsLeft > 0) {
            CSVLog("no window with a root view controller yet; retrying (%ld left)",
                     (long)attemptsLeft);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CSAttemptTransplant(scene, options, attemptsLeft - 1);
            });
            return;
        }
        CSLog("nothing to transplant — window inventory follows:");
        CSLogWindowInventory();
        return;
    }

    if (alreadyOnCarScene) {
        // UIKit already attached the app's only window to the car scene. Moving it
        // would be a no-op at best; just make sure it is actually on screen.
        source.hidden = NO;
        [source makeKeyAndVisible];
        CSApplyScaleToCarScene(scene, options);
        CSLog("app's window was already on the car scene (%s) — made it visible "
                "instead of transplanting", object_getClassName(root));
        return;
    }

    gSourceWindow = source;
    gTransplantedRoot = root;
    gCarScene = scene;
    gCarOptions = options;
    gSourceSize = source.bounds.size;

    // Detach before re-attaching: UIKit asserts if a view controller is set as the
    // root of two windows at once.
    source.rootViewController = nil;

    UIWindow *car = [[UIWindow alloc] initWithWindowScene:scene];
    car.frame = scene.coordinateSpace.bounds;
    car.rootViewController = root;
    [car makeKeyAndVisible];
    gCarWindow = car;

    // Compatibility-mode apps commonly treat applicationDelegate.window as
    // their canonical UI context. Once its root moves, leaving that property
    // aimed at the empty placeholder window gives newly built controllers the
    // wrong scene, screen, and traits. Move the ownership reference with the
    // hierarchy and restore it on disconnect.
    id appDelegate = UIApplication.sharedApplication.delegate;
    SEL windowSelector = @selector(window);
    SEL setWindowSelector = @selector(setWindow:);
    if ([appDelegate respondsToSelector:windowSelector] &&
        [appDelegate respondsToSelector:setWindowSelector]) {
        UIWindow *delegateWindow =
            ((UIWindow *(*)(id, SEL))objc_msgSend)(appDelegate, windowSelector);
        if (delegateWindow == source) {
            ((void (*)(id, SEL, UIWindow *))objc_msgSend)(appDelegate,
                                                         setWindowSelector, car);
            gWindowOwningDelegate = appDelegate;
            gDelegateWindowReassigned = YES;
            CSLog("application delegate window reassigned to transplant");
        }
    }

    BOOL portrait = NO;
    UIEdgeInsets sceneSafeArea =
        CSConfigureTransplantWindow(car, scene, options, gSourceSize,
                                      NO,
                                      &portrait);
    UIEdgeInsets contentSafeArea = root.view.safeAreaInsets;

    CSLog("transplanted %s as the window root (%.0fx%.0f at (%.0f,%.0f), portrait=%d, "
            "scene safe l=%.0f t=%.0f r=%.0f b=%.0f, "
            "content safe l=%.0f t=%.0f r=%.0f b=%.0f)",
            object_getClassName(root), car.bounds.size.width, car.bounds.size.height,
            car.layer.position.x, car.layer.position.y, portrait,
            sceneSafeArea.left, sceneSafeArea.top,
            sceneSafeArea.right, sceneSafeArea.bottom,
            contentSafeArea.left, contentSafeArea.top,
            contentSafeArea.right, contentSafeArea.bottom);
}

void CSStopMirroring(void) {
    if (!gTransplantedRoot) return;

    UIViewController *root = gTransplantedRoot;
    UIWindow *source = gSourceWindow;

    gCarWindow.rootViewController = nil;
    gCarWindow.hidden = YES;
    gCarWindow = nil;

    // Put the UI back on the phone. If the source window went away while we were
    // bridged there is nothing to restore it to, and the app will rebuild its own
    // UI on next activation.
    if (source) {
        source.rootViewController = root;
        if (gDelegateWindowReassigned && gWindowOwningDelegate &&
            [gWindowOwningDelegate respondsToSelector:@selector(setWindow:)]) {
            ((void (*)(id, SEL, UIWindow *))objc_msgSend)(
                gWindowOwningDelegate, @selector(setWindow:), source);
        }
        [source makeKeyAndVisible];
        CSLog("restored %s to the phone display", object_getClassName(root));
    } else {
        CSLog("source window is gone; leaving restoration to the app");
    }

    gTransplantedRoot = nil;
    gSourceWindow = nil;
    gCarScene = nil;
    gCarOptions = nil;
    gSourceSize = CGSizeZero;
    gWindowOwningDelegate = nil;
    gDelegateWindowReassigned = NO;
    gGeometryReconcileGeneration++;
    gSourceRootAliasCount = 0;
    gPresentationAttachments = nil;
}
