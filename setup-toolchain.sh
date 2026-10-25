#!/usr/bin/bash
# ============================================================
# FDM iOS 交叉编译环境一键搭建（小窝 Ubuntu 24.04 aarch64）
# 已在 2026-10-16 实测跑通。整个流程约 15~25 分钟（看网速）。
#
# 用法：bash /workspace/ios-port/setup-toolchain.sh
# 之后：source /workspace/ios-port/env.sh
# ============================================================
set -u

echo "===== [1/6] 修 hosts（github 换可用 IP）====="
cp /etc/hosts /etc/hosts.bak.$(date +%s) 2>/dev/null || true
for h in "20.205.243.166 github.com" "140.82.112.6 api.github.com"; do
    grep -q "^$h\$" /etc/hosts || echo "$h" >> /etc/hosts
done
# raw.githubusercontent 在国内多被 RST，Theos 走 git clone 所以不影响

echo "===== [2/6] apt 源换 USTC（arm64 用 ubuntu-ports）====="
sed -i 's|http://ports.ubuntu.com/ubuntu-ports/|https://mirrors.ustc.edu.cn/ubuntu-ports/|g' \
    /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
apt-get -o Acquire::http::Timeout=30 -o Acquire::ForceIPv4=true update -qq 2>&1 | tail -3

echo "===== [3/6] 装工具链（clang/lld/llvm/cmake/ninja/git）====="
DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing \
    clang lld llvm libplist-dev libssl-dev cmake ninja-build git curl xz-utils 2>&1 | tail -5

echo "===== [4/6] Theos ====="
if [ ! -d /opt/theos ]; then
    rm -rf /opt/theos
    git clone --depth 1 https://github.com/theos/theos.git /opt/theos 2>&1 | tail -2
fi
cd /opt/theos && git submodule update --init --recursive 2>&1 | tail -3
# 注意：不要跑 bin/update-theos —— 它拒绝 root 运行。子模块手动拉即可。

echo "===== [5/6] iOS 15.6 SDK（sparse，只拉一个）====="
if [ ! -d /opt/theos/sdks/iPhoneOS15.6.sdk ]; then
    rm -rf /opt/sdktmp && mkdir -p /opt/sdktmp && cd /opt/sdktmp
    git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/theos/sdks.git s 2>&1 | tail -2
    cd s && git sparse-checkout set iPhoneOS15.6.sdk 2>&1 | tail -2
    mv iPhoneOS15.6.sdk /opt/theos/sdks/
    cd / && rm -rf /opt/sdktmp
fi

echo "===== [6/6] 交叉工具链包装 ====="
B=/opt/theos/toolchain/linux/iphone/bin
mkdir -p "$B" && cd "$B"
# 符号链接
ln -sf /usr/bin/ar ar; ln -sf /usr/bin/ranlib ranlib
for t in llvm-strip:strip llvm-nm:nm llvm-objdump:objdump llvm-objcopy:objcopy \
         llvm-lipo:lipo llvm-install-name-tool:install_name_tool \
         llvm-strings:strings llvm-size:size; do
    src=${t%%:*}; dst=${t##*:}
    [ -e /usr/lib/llvm-18/bin/$src ] && ln -sf /usr/lib/llvm-18/bin/$src "$dst"
done
# Mach-O 链接器包装
cat > ld <<'EOF'
#!/bin/sh
exec /usr/lib/llvm-18/bin/ld64.lld "$@"
EOF
cp ld ld64.lld
# clang 包装：① 补 -mlinker-version 让 clang 发 -platform_version
#             ② 链接时补 -Wl,-adhoc_codesign 直接产 ad-hoc 签名（免 ldid）
cat > clang <<'EOF'
#!/usr/bin/bash
B=/opt/theos/toolchain/linux/iphone/bin
mode=link
for a in "$@"; do
  case "$a" in
    -c|-E|-S|-M|-MM|--version|-dumpversion|-dumpmachine) mode=notlink; break ;;
  esac
done
has_o=0; for a in "$@"; do [ "$a" = "-o" ] && has_o=1; done
if [ "$mode" = link ] && [ "$has_o" = 1 ]; then
  exec -a "$B/clang" /usr/bin/clang -mlinker-version=711 -Wl,-adhoc_codesign "$@"
fi
exec -a "$B/clang" /usr/bin/clang -mlinker-version=711 "$@"
EOF
cat > clang++ <<'EOF'
#!/usr/bin/bash
B=/opt/theos/toolchain/linux/iphone/bin
mode=link
for a in "$@"; do
  case "$a" in
    -c|-E|-S|-M|-MM|--version|-dumpversion|-dumpmachine) mode=notlink; break ;;
  esac
done
has_o=0; for a in "$@"; do [ "$a" = "-o" ] && has_o=1; done
if [ "$mode" = link ] && [ "$has_o" = 1 ]; then
  exec -a "$B/clang++" /usr/bin/clang++ -mlinker-version=711 -Wl,-adhoc_codesign "$@"
fi
exec -a "$B/clang++" /usr/bin/clang++ -mlinker-version=711 "$@"
EOF
# ldid 占位（链接器已签名）
printf '#!/bin/sh\nexit 0\n' > ldid
chmod +x clang clang++ ld ld64.lld ldid

echo
echo "===== 完成 ====="
source /workspace/ios-port/env.sh
cat <<'TIPS'

自检：
  cd /workspace/ios-port/build-test && make clean && make
  应看到 Compiling / Linking / Signing 三步全绿，并产出 hello.dylib

TIPS
