include $(THEOS)/makefiles/common.mk

# Nothing in the tweak, prefs bundle, or helper ever spawns a process, so no
# tool here is a runtime dependency — they are all diagnostics. Only the three
# the shipped code actually points a user at go into a release:
#
#   carsurf-audit    README's "verify it works" step; named by CSAppList,
#                    CSEntitlementSpoof, and CSSceneBridge when a hook is missing
#   carsurf-classes  named by CSCarKitPolicy when the policy evaluator changes
#   carsurf-logs     README, and CSLog says it collects the per-container logs
#
# The rest are development-only and cost ~470 KB installed, so they are built
# for debug packages and left out of FINALPACKAGE. carsurf-notify is the one to
# watch: tools/device-test.sh needs it present on the device to post a toggle
# over SSH, which is fine because that is a debug-build workflow.
TOOL_NAME = carsurf-audit carsurf-classes

ifneq ($(FINALPACKAGE),1)
TOOL_NAME += carsurf-prefstest carsurf-apps carsurf-notify
endif

carsurf-audit_FILES = carsurf-audit.m
carsurf-audit_CFLAGS = -fobjc-arc
carsurf-audit_FRAMEWORKS = Foundation UIKit
carsurf-audit_INSTALL_PATH = /usr/local/bin
carsurf-audit_CODESIGN_FLAGS = -Sentitlements.plist

carsurf-classes_FILES = carsurf-classes.m
carsurf-classes_CFLAGS = -fobjc-arc
carsurf-classes_FRAMEWORKS = Foundation
carsurf-classes_INSTALL_PATH = /usr/local/bin
carsurf-classes_CODESIGN_FLAGS = -Sentitlements.plist

carsurf-prefstest_FILES = carsurf-prefstest.m
carsurf-prefstest_CFLAGS = -fobjc-arc
carsurf-prefstest_FRAMEWORKS = Foundation UIKit
carsurf-prefstest_INSTALL_PATH = /usr/local/bin
carsurf-prefstest_CODESIGN_FLAGS = -Sentitlements.plist

carsurf-apps_FILES = carsurf-apps.m ../shared/CSAppFilter.m
carsurf-apps_CFLAGS = -fobjc-arc -I../shared
carsurf-apps_FRAMEWORKS = Foundation
carsurf-apps_INSTALL_PATH = /usr/local/bin
carsurf-apps_CODESIGN_FLAGS = -Sentitlements.plist

carsurf-notify_FILES = np.m
carsurf-notify_INSTALL_PATH = /usr/local/bin
carsurf-notify_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/local/bin"$(ECHO_END)
	$(ECHO_NOTHING)cp carsurf-logs.sh "$(THEOS_STAGING_DIR)/usr/local/bin/carsurf-logs"$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 "$(THEOS_STAGING_DIR)/usr/local/bin/carsurf-logs"$(ECHO_END)
ifneq ($(FINALPACKAGE),1)
	$(ECHO_NOTHING)cp carsurf-vehicle.sh "$(THEOS_STAGING_DIR)/usr/local/bin/carsurf-vehicle"$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 "$(THEOS_STAGING_DIR)/usr/local/bin/carsurf-vehicle"$(ECHO_END)
	$(ECHO_NOTHING)cp carsurf-launch.sh "$(THEOS_STAGING_DIR)/usr/local/bin/carsurf-launch"$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 "$(THEOS_STAGING_DIR)/usr/local/bin/carsurf-launch"$(ECHO_END)
endif
