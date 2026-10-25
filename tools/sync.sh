#!/usr/bin/bash
# ============================================================
# 尼尼的一键同步（iPhone WebDAV ↔ 小窝）
#
#   ./sync.sh push [版本]   编译 + 上传 dylib 到 TrollDecrypt
#   ./sync.sh ls           列 iPhone 上的投递目录 / App 日志目录
#   ./sync.sh config       查看/写 iPhone 上的配置
#
# 约定：
#   投递目录（放 dylib 给主人注入） = /var/mobile/Documents/TrollDecrypt
#   App 日志目录（dylib 自己写的）  = <App容器>/Documents
#
# 环境变量 WD_HOST（默认从 .env 的 IPHONE_HOST 推导 :8080）
# ============================================================
set -u
# ★ WebDAV 地址也从 .env 推导（换机器只改 .env）
if [ -f "$(dirname "$0")/_env.sh" ]; then
    . "$(dirname "$0")/_env.sh" 2>/dev/null || true
fi
export WD_HOST="${WD_HOST:-${IPHONE_HOST:-127.0.0.1}:8080}"

TOOLS=/workspace/ios-port/tools
OUT=/workspace/ios-port/out
DROP=/workspace/ios-port/iphone
TROLL="/var/mobile/Documents/TrollDecrypt"
APP_BASE="/var/mobile/Containers/Data/Application"
# ★ 2026-10-25 不写死容器 UUID：从 .env 的 APP_DOCS 里取
APP_UUID="${APP_UUID:-$(basename "$(dirname "${APP_DOCS:-}")")}"
APP_DOCS="$APP_BASE/$APP_UUID/Documents"

mkdir -p "$DROP"
WD="python3 $TOOLS/wd.py"

case "${1:-}" in

push)
    VER="${2:-}"
    [ -z "$VER" ] && { echo "用法: ./sync.sh push <版本，如 0.7>"; exit 1; }
    SRC=$(ls -d /workspace/ios-port/src/FDMProbe* 2>/dev/null | tail -1)
    echo "=== 编译 $SRC ==="
    source /workspace/ios-port/env.sh >/dev/null 2>&1
    (cd "$SRC" && make clean >/dev/null 2>&1 && make 2>&1 | grep -E "Compiling|Linking|Signing|error:") || true
    D="$SRC/.theos/obj/debug/arm64/FDMProbe.dylib"
    [ -f "$D" ] || { echo "❌ 编译失败"; exit 1; }

    NAME="FDMProbe-v$VER.dylib"
    cp "$D" "$OUT/$NAME"
    cp "$D" /tool_outputs/"$NAME" 2>/dev/null || true

    echo "=== 清理 iPhone 上的旧 dylib ==="
    for old in $($WD ls "$TROLL" 2>/dev/null | awk '{print $NF}' | sed 's|.*/||' | grep -E '^FDMProbe-.*\.dylib$'); do
        [ "$old" = "$NAME" ] && continue
        $WD rm "$TROLL/$old" >/dev/null 2>&1 && echo "  已删 $old"
    done

    echo "=== 上传 ==="
    $WD put "$OUT/$NAME" "$TROLL"

    echo "=== 校验 ==="
    $WD get "$TROLL/$NAME" /tmp/_verify.dylib >/dev/null 2>&1
    a=$(sha256sum "$OUT/$NAME" | cut -d' ' -f1)
    b=$(sha256sum /tmp/_verify.dylib 2>/dev/null | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "✅ sha256 一致 $a" || echo "❌ 不一致！$a vs $b"
    ;;

ls)
    echo "=== 投递目录 $TROLL ==="
    $WD ls "$TROLL" 2>&1
    echo
    echo "=== App 日志目录 ==="
    $WD ls "$APP_DOCS" 2>&1 | awk '{printf "  %-10s %s\n", $1, $NF}' | sed 's|.*/||'
    ;;

config)
    echo "=== App 配置 ==="
    for f in fdm-override.json fdm-inject.json fdm-net.json; do
        printf "--- %s ---\n" "$f"
        $WD cat "$APP_DOCS/$f" 2>/dev/null || echo "  (不存在)"
    done
    ;;

*)
    sed -n '2,14p' "$0"
    ;;
esac
