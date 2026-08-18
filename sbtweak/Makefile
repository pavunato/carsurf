include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CSSystem

CSSystem_FILES  = CSSystem.m
CSSystem_FILES += CSCrashDiag.m
CSSystem_FILES += CSCarKitPolicy.m
CSSystem_FILES += CSSceneManifestSpoof.m
CSSystem_FILES += CSEntitlementSpoof.m
CSSystem_FILES += CSAppList.m
CSSystem_FILES += CSRelay.m
CSSystem_FILES += CSCarLaunch.m
CSSystem_FILES += ../shared/CSConfig.m
CSSystem_FILES += ../shared/CSRuntime.m
CSSystem_FILES += ../shared/CSLog.m
CSSystem_FILES += ../shared/CSConfigLocation.m
CSSystem_FILES += ../shared/CSAppFilter.m

CSSystem_CFLAGS = -fobjc-arc -I../shared -Wno-deprecated-declarations
# Deliberately no link against CarPlaySupport: every symbol is resolved through
# CSRuntime's guarded lookup, so injecting into SpringBoard (which does not
# otherwise load CarPlaySupport) cannot drag the framework in.
CSSystem_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
