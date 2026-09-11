#define CS_TAG "carlaunch"

#import "CSSystemInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <mach-o/loader.h>
#import <notify.h>
#import <objc/message.h>

// Launching an app on the *car* display from a shell is not something the
// system offers: /var/jb/usr/bin/uiopen goes through the phone's workspace and
// has no way to attribute a launch to the CarPlay screen. Retesting anything
// scene-related therefore meant a person tapping the head unit, which is why
// every CarPlay-side bug in docs/TODO.md is either "not reproducible" or was
// only ever observed once.
//
// DashBoard's own launch path is three objects, all inside the CarPlay process
// this dylib is already injected into:
//
//   DBApplicationController.sharedInstance -applicationWithBundleIdentifier:
//   -[DBMutableWorkspaceStateChangeRequest activateApplication:]
//   -[DBWorkspace requestStateChange:]
//
// That is exactly what an icon tap does, so a launch driven from here is the
// same launch — not a synthesised approximation that might diverge from the
// case being debugged.

/// One notification for every app, with the bundle identifier passed beside it
/// in a file. notify(3) names are fixed strings, so the alternative is a token
/// per enabled app plus re-registration on every config change — state that
/// would have to stay correct for a debug tool to work.
static const char *const kLaunchNotification = "com.pavunato.carsurf/carlaunch";

/// Sibling of CSConfig's relay, and the same candidate order, so the tool
/// writes where the tweak already reads on both rootless and rootful installs.
static NSString *const kRequestPaths[] = {
    @"/var/jb/Library/CarSurf/carlaunch",
    @"/Library/CarSurf/carlaunch",
};

/// The live workspace, captured at -init. Weak: a workspace is invalidated when
/// the vehicle disconnects, and a launch request against a dead one should fail
/// loudly rather than resurrect it.
static __weak id gWorkspace;

static BOOL CSIsCarPlayHost(void) {
    // DBApplicationController and DashBoard's workspace both live here; the
    // template-UI host and SpringBoard have neither.
    return [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"];
}

#pragma mark - Capturing the workspace

// A connected instrument cluster creates another DBWorkspace. Only the
// dashboard owner can present applications on the main CarPlay display.
// Capturing every -init makes the last-created (cluster) workspace win.

static id (*orig_workspaceInitWithOwner)(id, SEL, id);

static void CSNoteWorkspace(id workspace, id owner) {
    if (!workspace) return;
    Class dashboardOwner = CSLookupClass("DBDashboardWorkspaceOwner");
    if (!dashboardOwner || ![owner isKindOfClass:dashboardOwner]) {
        CSLog("ignored DBWorkspace %p owner=%s", workspace,
              owner ? object_getClassName(owner) : "nil");
        return;
    }
    gWorkspace = workspace;
    CSLog("captured dashboard DBWorkspace %p owner=%s", workspace,
          object_getClassName(owner));
}

static id cs_workspaceInitWithOwner(id self, SEL _cmd, id owner) {
    id result = orig_workspaceInitWithOwner(self, _cmd, owner);
    CSNoteWorkspace(result, owner);
    return result;
}

/// YES once the workspace initialisers are hooked. DashBoard may not be mapped
/// when this dylib's constructor runs, and the hook is worthless if it lands
/// after DashBoard has already built its workspace — so it is attempted at
/// constructor time and retried from a load-image callback, never lazily at
/// launch time.
static BOOL CSInstallWorkspaceCapture(void) {
    static BOOL installed = NO;
    if (installed) return YES;

    Class workspace = CSLookupClass("DBWorkspace");
    if (!workspace) return NO;

    BOOL owner = CSSwizzleInstanceMethod(workspace, @selector(initWithOwner:),
                                         (IMP)cs_workspaceInitWithOwner,
                                         (IMP *)&orig_workspaceInitWithOwner);
    if (!owner) {
        CSLog("WARNING: DBWorkspace has no -initWithOwner:; "
              "carlaunch cannot reach the car workspace on this release");
        return NO;
    }

    installed = YES;
    CSLog("dashboard workspace capture installed (initWithOwner=%d)", owner);
    return YES;
}

static void CSCarLaunchImageLoaded(const struct mach_header *header) {
    CSInstallWorkspaceCapture();
}

#pragma mark - Performing the launch

static NSString *CSReadRequestedBundleIdentifier(void) {
    for (size_t i = 0; i < sizeof(kRequestPaths) / sizeof(*kRequestPaths); i++) {
        NSString *contents = [NSString stringWithContentsOfFile:kRequestPaths[i]
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
        NSString *bundleID = [contents stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (bundleID.length > 0) return bundleID;
    }
    return nil;
}

static void CSCarLaunch(NSString *bundleID) {
    id workspace = gWorkspace;
    if (!workspace) {
        CSLog("carlaunch %s: no live DBWorkspace — is a vehicle connected?",
              bundleID.UTF8String);
        return;
    }

    Class controllerClass = CSLookupClass("DBApplicationController");
    SEL sharedSelector = @selector(sharedInstance);
    SEL appForIDSelector = @selector(applicationWithBundleIdentifier:);
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) return;
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
    if (![controller respondsToSelector:appForIDSelector]) return;

    // The dashboard's own roster, so an app that is not enabled (or whose
    // in-place add has not landed yet) fails here rather than half-launching.
    id application = ((id (*)(id, SEL, id))objc_msgSend)(controller, appForIDSelector,
                                                         bundleID);
    if (!application) {
        CSLog("carlaunch %s: not in DBApplicationController — enable it first",
              bundleID.UTF8String);
        return;
    }

    Class requestClass = CSLookupClass("DBMutableWorkspaceStateChangeRequest");
    SEL activateSelector = @selector(activateApplication:);
    SEL changeSelector = @selector(requestStateChange:);
    if (!requestClass || ![workspace respondsToSelector:changeSelector]) {
        CSLog("carlaunch %s: DashBoard workspace API missing on this release",
              bundleID.UTF8String);
        return;
    }
    id request = [requestClass new];
    if (![request respondsToSelector:activateSelector]) return;

    ((void (*)(id, SEL, id))objc_msgSend)(request, activateSelector, application);
    ((void (*)(id, SEL, id))objc_msgSend)(workspace, changeSelector, request);
    CSLog("carlaunch %s: activation requested", bundleID.UTF8String);
    __weak id requestedWorkspace = workspace;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        id liveWorkspace = requestedWorkspace;
        SEL stateSelector = @selector(state);
        SEL activeSelector = @selector(activeBundleIdentifier);
        if (![liveWorkspace respondsToSelector:stateSelector]) return;
        id state = ((id (*)(id, SEL))objc_msgSend)(liveWorkspace, stateSelector);
        if (![state respondsToSelector:activeSelector]) {
            CSLog("carlaunch %s: dashboard active app unavailable", bundleID.UTF8String);
            return;
        }
        NSString *active = ((id (*)(id, SEL))objc_msgSend)(state, activeSelector);
        CSLog("carlaunch %s: dashboard active=%s matched=%d", bundleID.UTF8String,
              active.UTF8String ?: "nil", [active isEqualToString:bundleID]);
    });
}

void CSInstallCarLaunch(void) {
    static BOOL installed = NO;
    if (installed || !CSIsCarPlayHost()) return;
    installed = YES;

    if (!CSInstallWorkspaceCapture()) {
        // DashBoard is not mapped yet. Its classes appear during image load,
        // still well before the workspace itself is constructed.
        objc_addLoadImageFunc(CSCarLaunchImageLoaded);
    }

    int token = 0;
    notify_register_dispatch(kLaunchNotification, &token, dispatch_get_main_queue(),
                             ^(int t) {
        NSString *bundleID = CSReadRequestedBundleIdentifier();
        if (bundleID.length == 0) {
            CSLog("carlaunch posted with no bundle identifier on file");
            return;
        }
        CSCarLaunch(bundleID);
    });
    CSLog("carlaunch listener installed");
}
