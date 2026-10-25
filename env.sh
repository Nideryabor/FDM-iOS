#!/usr/bin/bash
# FDM iOS 交叉编译环境（小窝 Ubuntu 24.04 aarch64 → iOS arm64）
# 用法：  source /workspace/ios-port/env.sh
#
# 关键配置说明：
#   /opt/theos/toolchain/linux/iphone/bin/   ← Theos 期望的交叉工具链目录
#      clang / clang++  包装脚本：
#         -mlinker-version=711  → 让 clang 发 -platform_version（ld64.lld 必需）
#         -Wl,-adhoc_codesign   → 让 ld64.lld 直接产 ad-hoc 签名（免 ldid）
#      ld / ld64.lld    包装 → /usr/lib/llvm-18/bin/ld64.lld
#      ldid             占位（链接器已签名，仅让 Theos 签名步骤不报错）

export B=/opt/theos/toolchain/linux/iphone/bin
export THEOS=/opt/theos
export PATH=$B:/usr/lib/llvm-18/bin:/opt/theos/bin:$PATH
export THEOS_MAKE_PATH=$THEOS/makefiles

# 默认目标
export TARGET_DEFAULT=iphone:clang:15.6:15.0
export ARCHS_DEFAULT=arm64

alias fdm-build='make clean && make'
echo "[env] THEOS=$THEOS"
echo "[env] SDK=$(ls -d $THEOS/sdks/*.sdk 2>/dev/null | head -1)"
echo "[env] clang=$(which clang)  ld=$B/ld"
