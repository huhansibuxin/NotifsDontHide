export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64

INSTALL_TARGET_PROCESSES = SpringBoard
export THEOS_PACKAGE_SCHEME = rootless
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

TWEAK_NAME = NotifsDontHide

NotifsDontHide_FILES = Tweak.xm
NotifsDontHide_CFLAGS = -fobjc-arc
NotifsDontHide_LIBRARIES += substrate
NotifsDontHide_LOGOSFLAGS += -c generator=MobileSubstrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	cp layout/Library/MobileSubstrate/DynamicLibraries/OneNotificationListFFS.dylib $(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/
	cp layout/Library/MobileSubstrate/DynamicLibraries/OneNotificationListFFS.plist $(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/
