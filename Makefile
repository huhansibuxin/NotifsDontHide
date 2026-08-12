export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64e

INSTALL_TARGET_PROCESSES = SpringBoard
export THEOS_PACKAGE_SCHEME = rootless
export ERROR_ON_WARNINGS = 0
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

TWEAK_NAME = NotifsDontHide

NotifsDontHide_FILES = Tweak.xm
NotifsDontHide_CFLAGS = -fobjc-arc -w
NotifsDontHide_LIBRARIES += substrate
NotifsDontHide_FRAMEWORKS = CoreFoundation
NotifsDontHide_LOGOSFLAGS += -c generator=MobileSubstrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

