# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WeatherPadPrefs
WeatherPadPrefs_FILES = WPRootListController.m
WeatherPadPrefs_FRAMEWORKS = UIKit
WeatherPadPrefs_PRIVATE_FRAMEWORKS = Preferences
WeatherPadPrefs_INSTALL_PATH = /Library/PreferenceBundles
WeatherPadPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
