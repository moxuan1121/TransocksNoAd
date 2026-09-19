TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = Transocks-iOS

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TransocksNoAd
TransocksNoAd_FILES = Engine/TNAGlob.c Engine/TNAPattern.m Engine/TNAHooks.m
TransocksNoAd_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
TransocksNoAd_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
