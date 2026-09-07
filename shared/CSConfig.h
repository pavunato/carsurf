#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How a given app should be put on the head-unit display.
typedef NS_ENUM(NSInteger, CSBridgeMode) {
    /// Pick per-app based on whether the app declares a scene manifest.
    CSBridgeModeAuto = 0,
    /// Give the app a real, independent UIWindowScene on the car display.
    CSBridgeModeScene = 1,
    /// Mirror the app's existing key window onto the car display.
    CSBridgeModeMirror = 2,
};

/// Aspect policy for the app viewport on the landscape head unit.
typedef NS_ENUM(NSInteger, CSLayoutMode) {
    /// Follow the app's existing window shape where one exists.
    CSLayoutModeAuto = 0,
    /// Fill the landscape area to the right of the CarPlay sidebar.
    CSLayoutModeHorizontal = 1,
    /// Use a centered 9:16 portrait viewport.
    CSLayoutModeVertical = 2,
};

/// Interface family reported to app code while it builds the bridged UI.
typedef NS_ENUM(NSInteger, CSIdiomMode) {
    /// Keep UIKit's original idiom (normally CarPlay on the external scene).
    CSIdiomModeAuto = 0,
    /// Present the bridged UI as an iPhone app.
    CSIdiomModePhone = 1,
    /// Present the bridged UI as an iPad app.
    CSIdiomModePad = 2,
};

/// Bounds of the render scale, shared by the settings sliders and the clamp the
/// tweak applies when reading a stored value, so a slider can never offer a
/// scale the tweak will silently refuse. The floor is deliberately far below
/// anything useful on a large head unit: a small display needs a lot of
/// shrinking before an app's UI fits it at all.
static const CGFloat kCSMinScale = 0.1;
static const CGFloat kCSMaxScale = 2.0;

/// Per-app options. Values are clamped on read, so a hand-edited plist cannot
/// produce a scale of 0 or a negative rotation.
@interface CSAppOptions : NSObject
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly) CSBridgeMode mode;
/// Render scale applied to the car scene, kCSMinScale–kCSMaxScale. 1.0 = native.
@property (nonatomic, readonly) CGFloat scale;
/// Auto, iPhone, or iPad interface family reported to the app.
@property (nonatomic, readonly) CSIdiomMode idiomMode;
/// Auto, horizontal, or centered 9:16 vertical viewport.
@property (nonatomic, readonly) CSLayoutMode layoutMode;
/// Permit the car scene to rotate independently of the device.
@property (nonatomic, readonly) BOOL allowIndependentRotation;
@end

/// Reads the tweak's configuration. Safe to use from SpringBoard, CarPlay.app,
/// and sandboxed app processes; when the configuration cannot be read at all the
/// object reports everything as disabled, so a sandbox failure degrades to
/// "tweak inactive" rather than to undefined behaviour.
@interface CSConfig : NSObject

@property (class, nonatomic, readonly) CSConfig *sharedConfig;

/// NO if the master switch is off, the kill-switch file exists, or CS_SAFE is
/// set in this process's environment.
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;

/// Bundle identifiers the user has opted in to bridging.
@property (nonatomic, readonly, copy) NSArray<NSString *> *enabledBundleIdentifiers;

/// Carsurf-managed bundle identifiers deliberately disabled on the CarPlay
/// dashboard. This small persistent tombstone set lets the icon-layout host
/// filter stale icons after it restarts before it can query the dashboard
/// controller.
@property (nonatomic, readonly, copy) NSArray<NSString *> *dashboardDisabledBundleIdentifiers;

- (BOOL)isBundleEnabled:(nullable NSString *)bundleIdentifier;
- (CSAppOptions *)optionsForBundle:(NSString *)bundleIdentifier;

/// Re-reads from disk. Called automatically on the change notification.
- (void)reload;

/// Removes per-app preference entries whose bundle identifiers are no longer
/// present in LaunchServices. This is intentionally a no-op outside
/// SpringBoard, where the installed-app database is authoritative. Call this
/// once during SpringBoard startup so an uninstall followed by a respring does
/// not leave a stale enabled app in the saved plist.
- (void)pruneMissingApplications;

/// Posted by the prefs bundle after a write.
@property (class, nonatomic, readonly) NSString *changeNotificationName;

@end

NS_ASSUME_NONNULL_END
