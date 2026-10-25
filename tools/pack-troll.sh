#!/usr/bin/bash
# ============================================================
# pack-troll.sh —— 打一个 TrollFools 可直接注入的 dylib 包
#
#   ./pack-troll.sh            出 v<时间戳> 包
#   ./pack-troll.sh v22        指定版本名
#
# 做四件事：
#   ① clean 重编（TROLL=1，install_name 走 @executable_path）
#   ② 校验 install_name / 依赖 / 构造函数段
#   ③ 拷进 dist/FDM-<版本>-trollfools/
#   ④ 把 install_name 换回绝对路径重编一次（恢复 hot-reload 版）
#
# ⚠️ 为什么要第 ④ 步：TROLL=1 只改链接参数，产物同名同路径。
#    不恢复的话，下次 `make` 出来的就是"注入版"，
#    部署到 /var/jb 之后 ElleKit dlopen 会按 @executable_path 找不到自己。
# ============================================================
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SRC="$ROOT/src/FDMProbe5"
OUT="$SRC/.theos/obj/debug/arm64/FDMProbe.dylib"
VER="${1:-v$(date +%m%d-%H%M)}"
DIST="$ROOT/dist/FDM-${VER}-trollfools"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }

# shellcheck disable=SC1091
source "$ROOT/env.sh" >/dev/null 2>&1

OD=""
for c in llvm-objdump-18 llvm-objdump; do
    command -v "$c" >/dev/null 2>&1 && { OD="$c"; break; }
done

iname() {
    [ -n "$OD" ] || { echo "?"; return; }
    $OD -p "$1" 2>/dev/null | sed -n '/LC_ID_DYLIB/,+2p' \
      | grep "name " | sed 's/.*name //;s/ (offset.*//'
}

# ---------------- ① 编 ----------------
say "1/4 编译（TROLL=1）"
( cd "$SRC" && make clean >/dev/null 2>&1 )
BUILD=$( cd "$SRC" && make TROLL=1 2>&1 )
if echo "$BUILD" | grep -qE "error:"; then
    echo "$BUILD" | grep -E "error:" | head -20
    bad "编译失败"
    exit 1
fi
[ -f "$OUT" ] || { bad "产物不存在：$OUT"; exit 1; }
ok "产物 $(stat -c %s "$OUT") 字节"

# ---------------- ② 校验 ----------------
say "2/4 校验"
ID=$(iname "$OUT")
echo "  install_name = $ID"
case "$ID" in
    @executable_path/*) ok "相对路径正确" ;;
    *) bad "install_name 不是 @executable_path —— 注入会失败"; exit 2 ;;
esac

if [ -n "$OD" ]; then
    if $OD -h "$OUT" 2>/dev/null | grep -q "mod_init_func"; then
        ok "__mod_init_func 存在（构造函数会跑）"
    else
        bad "缺 __mod_init_func —— 注入后不会初始化"
        exit 2
    fi
    DEPS=$($OD -p "$OUT" 2>/dev/null | grep "name /" | grep -vc -e "name /System" -e "name /usr/lib")
    if [ "$DEPS" = 0 ]; then ok "依赖全是系统库"; else bad "$DEPS 条非系统依赖"; fi
fi

# ---------------- ③ 打包 ----------------
say "3/4 打包"
mkdir -p "$DIST"
cp "$OUT" "$DIST/FDM.dylib"
chmod 755 "$DIST/FDM.dylib"
# 附上说明和自检脚本
#   模板目录优先用 dist/_trollfools-template/（每次改版更新这一份），
#   没有才退回老的 v22 目录（向后兼容）。
TPLDIR="$ROOT/dist/_trollfools-template"
[ -d "$TPLDIR" ] || TPLDIR="$ROOT/dist/FDM-v22-trollfools"
for f in README.md check.sh; do
    [ -f "$TPLDIR/$f" ] && cp "$TPLDIR/$f" "$DIST/$f"
done
chmod +x "$DIST/check.sh" 2>/dev/null
ok "$DIST/FDM.dylib"
md5sum "$DIST/FDM.dylib" | sed 's/^/  /'

# ---------------- ④ 恢复 hot-reload 版 ----------------
say "4/4 恢复 hot-reload 版（install_name 换回绝对路径）"
( cd "$SRC" && make clean >/dev/null 2>&1 && make >/dev/null 2>&1 )
RESTORED=$(iname "$OUT")
echo "  现在的 install_name = $RESTORED"
case "$RESTORED" in
    /usr/lib/*) ok "已恢复（/var/jb 部署用这份）" ;;
    *) bad "恢复失败，下次 make 会出错！手动：cd src/FDMProbe5 && make clean && make" ;;
esac

say "完成"
echo "  注入包：$DIST/"
echo "  注入用 FDM.dylib，按 README 走 TrollFools 即可"
