TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = Browser

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZoomableNoAd
ZoomableNoAd_FILES = Engine/ZNAGlob.c Engine/ZNAPattern.m Engine/ZNAHooks.m
ZoomableNoAd_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
ZoomableNoAd_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
