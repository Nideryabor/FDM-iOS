TARGET = iphone:clang:15.6:15.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FDMProbe
FDMProbe_FILES = FLog.m FDMConfig.m FDMFeatures.m FDMBeauty.m FDMProbe.m FDMUI.m FDMXray.m FDMStrip.m FDMUITree.m FDMPhotoPicker.m FDMRichText.m FDMUserMeta.m FDMComposer.m FDMMusicCrypto.c FDMMusicCryptoIOS.m FDMMusicApi.m FDMPromptVars.c FDMPromptVarsIOS.m FDMPromptCard.c FDMPromptUI.m FDMLyric.c FDMLyricIOS.m FDMMusicModel.c FDMMusic.m FDMMiniBar.m FDMMusicLogin.m FDMGlassPolicy.c FDMGlassEarly.m FDMGlass.m FDMGlassHook.m FDMBubbleStyle.c FDMBubble.m FDMBubbleDiag.m FDMMap271.m FDMNoteModel.c FDMNote.m FDMFileCard.c FDMFileCardUI.m FDMAssistant.m
FDMProbe_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
FDMProbe_FRAMEWORKS = Foundation UIKit QuartzCore PhotosUI Security Metal AVFoundation
FDMProbe_INSTALL_PATH = /usr/lib

# ============================================================
# ★ TrollFools 注入版专用构建：
#
#   make TROLL=1
#
#   区别只在 install_name：
#     · hot-reload 版（默认）：/usr/lib/FDMProbe.dylib
#       —— 给 dlopen("/var/jb/...") 用，绝对路径无所谓
#     · TrollFools 版（TROLL=1）：@executable_path/Frameworks/FDM.dylib
#       —— 注入器会把这个 dylib 放进 App bundle 的 Frameworks/，
#          install_name 必须用 @executable_path 相对定位，
#          否则 dyld 找不到文件 ⇒ App 启动就崩
#
#   其余（源码、CFLAGS、构造函数）完全一样。
# ============================================================
ifeq ($(TROLL),1)
FDMProbe_LDFLAGS = -install_name @executable_path/Frameworks/FDM.dylib
endif

include $(THEOS_MAKE_PATH)/library.mk
