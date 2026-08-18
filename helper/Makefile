include $(THEOS)/makefiles/common.mk

TOOL_NAME = carsurf-helperd

carsurf-helperd_FILES = carsurf-helperd.m ../shared/CSLog.m ../shared/CSConfigLocation.m
carsurf-helperd_CFLAGS = -fobjc-arc -I../shared
carsurf-helperd_FRAMEWORKS = Foundation
carsurf-helperd_INSTALL_PATH = /usr/local/libexec
carsurf-helperd_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
