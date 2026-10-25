TARGET = iphone:clang:15.6:15.0
ARCHS = arm64
# Rootless/普通都没关系：我们只要那个 .dylib 交给 TrollFools
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FDMProbe
FDMProbe_FILES = FDMProbe.m
FDMProbe_CFLAGS = -fobjc-arc
FDMProbe_FRAMEWORKS = Foundation UIKit
FDMProbe_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
