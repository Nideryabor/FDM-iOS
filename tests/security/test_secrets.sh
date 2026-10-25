#!/usr/bin/env bash
# ============================================================
# 口令泄露回归测试（离线，不需要真机）
#
#   bash tests/security/test_secrets.sh
#
# 守的是 2026-10-25 那次修复的成果，三条红线：
#   ① 任何脚本都不许把口令拼进**远端命令行**（设备上 ps 会看到）
#   ② 任何脚本都不许用 `sshpass -p`（本机 ps 会看到）
#   ③ 除 .env* 之外，项目里不许有口令明文
#
# 为什么值得单独一个测试：
#   这三条都是「不会报错、只会在某一瞬间悄悄漏」的错，
#   靠人眼 review 极易漏掉（当初就是这么写了 4 个脚本的）。
# ============================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
fail=0
pass=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "── 红线 ①：口令不许进远端命令行 ──"
# 匹配 `echo '$PW' | sudo` 这种写法（含双引号版本）
hits=$(grep -rn --include='*.sh' -E "echo +['\"]?\\\$PW['\"]? *\| *sudo" "$ROOT/tools" 2>/dev/null \
       | grep -v '^.*#' || true)
if [ -z "$hits" ]; then
    ok "tools/*.sh 无 echo \$PW | sudo 写法"
else
    bad "发现把口令拼进远端命令行的写法："; printf '%s\n' "$hits" | sed 's/^/      /'
fi

echo "── 红线 ②：不许用 sshpass -p（本机 argv 泄露） ──"
hits=$(grep -rn --include='*.sh' 'sshpass -p' "$ROOT/tools" 2>/dev/null | grep -v '^.*#' || true)
if [ -z "$hits" ]; then
    ok "tools/*.sh 统一用 sshpass -e（走环境变量）"
else
    bad "还有 sshpass -p："; printf '%s\n' "$hits" | sed 's/^/      /'
fi

echo "── 红线 ②b：sshpass -e 的脚本必须 source _env.sh ──"
miss=""
for f in "$ROOT"/tools/*.sh; do
    grep -q 'sshpass -e' "$f" 2>/dev/null || continue
    grep -q '_env.sh' "$f" 2>/dev/null || miss="$miss $(basename "$f")"
done
if [ -z "$miss" ]; then
    ok "全部都有 source _env.sh（SSHPASS 有人给）"
else
    bad "这些脚本用了 sshpass -e 却没 source _env.sh：$miss"
fi

echo "── 红线 ③：除 .env* 外不许有口令明文 ──"
ENVF="$ROOT/.env"
if [ ! -f "$ENVF" ]; then
    ok "（没有 .env，跳过明文扫描）"
else
    P=$(awk -F= '/^IPHONE_PW=/{printf "%s",$2}' "$ENVF")
    if [ -z "$P" ]; then
        ok "（.env 里没有 IPHONE_PW，跳过）"
    else
        hits=$(grep -rl --binary-files=without-match -F "$P" "$ROOT" 2>/dev/null \
               | grep -v '/\.env' || true)
        if [ -z "$hits" ]; then
            ok "除 .env* 外 0 处明文（备份/脚本/文档都干净）"
        else
            bad "这些文件里还有口令明文："; printf '%s\n' "$hits" | sed 's/^/      /'
        fi
    fi
fi

echo "── 红线 ④：.env 权限必须是 600 ──"
if [ -f "$ENVF" ]; then
    perm=$(stat -c %a "$ENVF" 2>/dev/null || echo "?")
    case "$perm" in
        600|400) ok ".env 权限 $perm" ;;
        *)       bad ".env 权限是 $perm，应 chmod 600" ;;
    esac
    if grep -q '^/ios-port/\.env$\|^\.env$' "$ROOT/.gitignore" 2>/dev/null; then
        ok ".env 已被 .gitignore 挡住"
    else
        bad ".env 没在 .gitignore 里"
    fi
fi

echo "── 红线 ⑤：git 侧（.env 不许进库 / 不许进暂存区 / 不许进历史） ──"
cd "$ROOT/.." 2>/dev/null || cd "$ROOT"
if git rev-parse --git-dir >/dev/null 2>&1; then
    # 5a 已被跟踪的文件里不许有 .env 系
    tracked=$(git ls-files | grep -iE '(^|/)\.env($|\.)|\.env\.bak' || true)
    if [ -z "$tracked" ]; then
        ok "已跟踪文件里 0 个 .env 系"
    else
        bad "这些 .env 系文件已经被 git 跟踪："; printf '%s\n' "$tracked" | sed 's/^/      /'
    fi

    # 5b 暂存区不许有
    staged=$(git diff --cached --name-only 2>/dev/null | grep -iE '(^|/)\.env($|\.)' || true)
    if [ -z "$staged" ]; then
        ok "暂存区 0 个 .env 系"
    else
        bad "暂存区里出现了 .env："; printf '%s\n' "$staged" | sed 's/^/      /'
    fi

    # 5c 历史上从没出现过
    hist=$(git log --all --format='' --name-only 2>/dev/null | grep -E '(^|/)\.env($|\.)' | sort -u || true)
    if [ -z "$hist" ]; then
        ok "历史（所有分支）里 0 个 .env 系"
    else
        bad "历史里出现过 .env —— 需要考虑改写历史："; printf '%s\n' "$hist" | sed 's/^/      /'
    fi

    # 5d .env 必须被 ignore 规则命中
    if [ -f "$ROOT/.env" ]; then
        if git check-ignore -q "$ROOT/.env" 2>/dev/null; then
            ok ".env 被 ignore 规则命中（$(git check-ignore -v "$ROOT/.env" | cut -f2)）"
        else
            bad ".env 没被任何 ignore 规则命中！"
        fi
    fi
else
    ok "（不是 git 仓库，跳过）"
fi

echo "── 红线 ⑥：文本文件里不许出现**真实设备/用户标识** ──"
# 从 .env 的 APP_DOCS 里取容器 UUID（装置标识），从 iphone/ 下聊天库名取用户 UUID
CONTAINER=""
if [ -f "$ENVF" ]; then
    APPD=$(awk -F= '/^APP_DOCS=/{print $2}' "$ENVF")
    CONTAINER=$(basename "$(dirname "$APPD")" 2>/dev/null || true)
fi
USERUID=""
for db in "$ROOT/iphone/"*.db; do
    [ -f "$db" ] || continue
    b=$(basename "$db" .db)
    case "$b" in *-*-*-*-*) USERUID="$b"; break ;; esac
done

check_id() {
    local label="$1" val="$2"
    [ -n "$val" ] || { ok "（没取到 $label，跳过）"; return; }
    # 只扫「会进库」的文本：docs / README / VERSION / tools / src
    local hits
    hits=$(grep -rIl --binary-files=without-match -F "$val" \
             "$ROOT/docs" "$ROOT/README.md" "$ROOT/VERSION" \
             "$ROOT/tools" "$ROOT/src" 2>/dev/null || true)
    if [ -z "$hits" ]; then
        ok "$label 未出现在文档/脚本/源码里"
    else
        bad "$label 泄漏在这些文件里："; printf '%s\n' "$hits" | sed "s|$ROOT/|      |"
    fi
}
check_id "容器 UUID" "$CONTAINER"
check_id "用户 UUID" "$USERUID"

echo "── 红线 ⑦：数据类目录必须被 git 忽略 ──"
if git rev-parse --git-dir >/dev/null 2>&1; then
    for d in iphone analysis/mmkv-dump analysis/raw-evidence uitree tmp dist out backups app; do
        p="$ROOT/$d"
        [ -e "$p" ] || continue
        if git check-ignore -q "$p" 2>/dev/null; then
            ok "$d/ 已被忽略"
        else
            bad "$d/ 没被忽略 —— 里面有真实数据"
        fi
    done
else
    ok "（不是 git 仓库，跳过）"
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m安全基线全部通过 ✅（%d 项）\033[0m\n' "$pass"
    exit 0
else
    printf '\033[31m有 %d 项没过 ❌\033[0m\n' "$fail"
    exit 1
fi
