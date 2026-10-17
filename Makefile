export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64e

INSTALL_TARGET_PROCESSES = SpringBoard
export ERROR_ON_WARNINGS = 0
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
# scheme 由 CI/环境变量决定（rootless 默认，roothide 构建时 CI 传 roothide）；
# 必须用 ?= 条件赋值——make 里普通赋值会覆盖环境变量，roothide job 会被打回 rootless
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME

TWEAK_NAME = NotifsDontHide

NotifsDontHide_FILES = Tweak.xm
NotifsDontHide_CFLAGS = -fobjc-arc -w
NotifsDontHide_LIBRARIES += substrate
NotifsDontHide_FRAMEWORKS = CoreFoundation UIKit CoreGraphics
NotifsDontHide_LOGOSFLAGS += -c generator=MobileSubstrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

