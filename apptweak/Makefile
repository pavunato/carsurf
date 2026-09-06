include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CSApp

CSApp_FILES  = CSApp.m
CSApp_FILES += CSSceneBridge.m
CSApp_FILES += CSTraits.m
CSApp_FILES += CSMirror.m
CSApp_FILES += CSKeyboard.m
CSApp_FILES += ../shared/CSConfig.m
CSApp_FILES += ../shared/CSRuntime.m
CSApp_FILES += ../shared/CSLog.m
CSApp_FILES += ../shared/CSConfigLocation.m

CSApp_CFLAGS = -fobjc-arc -I../shared -Wno-deprecated-declarations
CSApp_FRAMEWORKS = Foundation UIKit QuartzCore Security

include $(THEOS_MAKE_PATH)/tweak.mk
