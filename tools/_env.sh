#!/usr/bin/bash
# ============================================================
# _env.sh —— 所有脚本共用的「读私密配置」入口
#
#   source "$(dirname "$0")/_env.sh"
#
# 它做的事：
#   ① 找 .env（先看 ios-port/.env，再看工作区根 .env）
#   ② 找到就 source 进来
#   ③ 没找到 / 关键项缺失 ⇒ 给出**可照抄的修复步骤**并退出
#
# ★ 为什么要有这个文件：
#   以前 4 个脚本各自硬编码口令，
#   密码散在 4 处、还会被 git 带走。
#   现在只有一个 .env（600 权限、已 gitignore），脚本里一个字符都没有。
#
# ★ 脚本里**绝不**回退到任何默认口令 —— 宁可报错退出。
#   因为「悄悄用旧密码」比「直接失败」危险得多。
# ============================================================

_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_ENV_ROOT="$(cd "$_ENV_DIR/.." && pwd)"

# ★ 只在本项目里找，不做跨项目 fallback。
#   理由：跨目录兜底会让"别的项目复制了脚本"意外读到这边的主机/口令，
#   排查起来极其费解（尼尼自己踩过）。
#   要显式指定别处，用环境变量：FDM_ENV=/path/to/.env ./tools/xxx.sh
for _cand in \
    "${FDM_ENV:-}" \
    "$_ENV_ROOT/.env"
do
    [ -n "$_cand" ] || continue
    if [ -f "$_cand" ]; then
        # shellcheck disable=SC1090
        . "$_cand"
        ENV_FILE_USED="$_cand"
        break
    fi
done

# ---- 提示：还没建 .env ----
if [ -z "${ENV_FILE_USED:-}" ]; then
    cat >&2 <<'EOF'
❌ 找不到 .env 配置文件

  修复（一次性）：
      cd /workspace/ios-port
      cp .env.example .env
      chmod 600 .env
      # 然后编辑 .env，把 IPHONE_PW 改成真实密码

  说明：脚本不再内置任何默认口令，必须显式配置。
EOF
    return 1 2>/dev/null || exit 1
fi

# ---- 校验：必需项 ----
_missing=""
[ -z "${IPHONE_HOST:-}" ] && _missing="$_missing IPHONE_HOST"
[ -z "${IPHONE_USER:-}" ] && _missing="$_missing IPHONE_USER"
[ -z "${IPHONE_PW:-}" ]   && _missing="$_missing IPHONE_PW"
[ -z "${APP_DOCS:-}" ]    && _missing="$_missing APP_DOCS"

if [ -n "$_missing" ]; then
    printf '❌ %s 里缺少：%s\n' "$ENV_FILE_USED" "$_missing" >&2
    printf '   打开它补上即可（模板见 .env.example）\n' >&2
    return 1 2>/dev/null || exit 1
fi

# ---- 导出成脚本里习惯用的短名字 ----
HOST="${IPHONE_HOST}"
PORT="${IPHONE_PORT:-2222}"
USER="${IPHONE_USER}"
PW="${IPHONE_PW}"

# App 沙盒路径：.env 里给了就用，没给就退回内置默认（这个不是秘密）
# ★ 2026-10-25 去掉了内置的容器 UUID 兜底：那玩意是装置标识，不该写进脚本。
#   缺了就**报错退出**（和「绝不回退到默认口令」同一个原则）。
APP_DOCS="${APP_DOCS:-}"

export HOST PORT USER PW APP_DOCS

# ============================================================
# ★★ 2026-10-25 安全修复：口令不要出现在任何进程的 argv 里
#
#   问题 1（本地）：`sshpass -p "$PW" ssh ...`
#     口令会出现在**本机** `ps aux` 的命令行里。
#     改成 `sshpass -e`（从环境变量 SSHPASS 读）⇒ 只剩 /proc/<pid>/environ，
#     argv 干净。
#
#   问题 2（远端，更严重）：sshsu 里 `... echo '$PW' | sudo -S ...`
#     `$PW` 在本地展开后被拼进**发到设备的命令行串** ⇒ 执行那一两秒，
#     设备上任何能跑 `ps` 的进程（包括宿主 App）都能看到明文口令。
#     现在改成：脚本内容走 stdin 落临时文件，口令单独走 stdin 喂 sudo -S。
#
#   ⚠️ 改完之后 tools/*.sh 里**不应该**再出现 `sshpass -p` 或 `echo "$PW"`。
# ============================================================
export SSHPASS="$PW"

# 权限检查（只警告一次，不打断）
if [ -f "$ENV_FILE_USED" ]; then
    _perm=$(stat -c %a "$ENV_FILE_USED" 2>/dev/null || echo "?")
    case "$_perm" in
        600|400) : ;;
        *)
            printf '⚠️  %s 权限是 %s，建议收紧：chmod 600 %s\n' \
                   "$ENV_FILE_USED" "$_perm" "$ENV_FILE_USED" >&2
            ;;
    esac
fi
