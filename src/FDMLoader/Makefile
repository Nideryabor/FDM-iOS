TARGET = iphone:clang:15.6:15.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FDMLoader
FDMLoader_FILES = FDMLoader.m
FDMLoader_CFLAGS = -fobjc-arc
FDMLoader_FRAMEWORKS = Foundation UIKit
FDMLoader_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
