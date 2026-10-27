# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeatherPad
WeatherPad_FILES = Tweak.x
WeatherPad_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
