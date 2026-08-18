include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CSPrefs

CSPrefs_FILES  = CSRootListController.m
CSPrefs_FILES += CSAppListController.m
CSPrefs_FILES += CSAppOptionsController.m
CSPrefs_FILES += CSLayoutSegmentCell.m
CSPrefs_FILES += CSScaleSliderCell.m
CSPrefs_FILES += CSPrefsStore.m
CSPrefs_FILES += ../shared/CSLog.m
CSPrefs_FILES += ../shared/CSConfigLocation.m
CSPrefs_FILES += ../shared/CSAppFilter.m

CSPrefs_CFLAGS = -fobjc-arc -I../shared -DCARSURF_HIDE_SYSTEM_APPS=$(CARSURF_HIDE_SYSTEM_APPS)
CSPrefs_INSTALL_PATH = /Library/PreferenceBundles
CSPrefs_FRAMEWORKS = UIKit Foundation
CSPrefs_PRIVATE_FRAMEWORKS = Preferences
CSPrefs_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CarSurf.plist"$(ECHO_END)
