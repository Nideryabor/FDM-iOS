#!/usr/bin/bash
# ============================================================
# 拉日志：从 iPhone App 容器把 Documents 同步回小窝
#
#   bash tools/pull.sh              拉全部
#   bash tools/pull.sh fdm7         只拉含 fdm7 的
#   bash tools/pull.sh --watch      每 20 秒自动拉
#
# 日志落在 /workspace/ios-port/iphone/
# ============================================================
set -u
# ★ WebDAV 地址也从 .env 推导（换机器只改 .env）
if [ -f "$(dirname "$0")/_env.sh" ]; then
    . "$(dirname "$0")/_env.sh" 2>/dev/null || true
fi
export WD_HOST="${WD_HOST:-${IPHONE_HOST:-127.0.0.1}:8080}"
TOOLS=/workspace/ios-port/tools
DROP=/workspace/ios-port/iphone
APP_BASE="/var/mobile/Containers/Data/Application"
# ★ 2026-10-25 不写死容器 UUID：从 .env 的 APP_DOCS 里取
APP_UUID="${APP_UUID:-$(basename "$(dirname "${APP_DOCS:-}")")}"
APP="$APP_BASE/$APP_UUID/Documents"

mkdir -p "$DROP"
WD="python3 $TOOLS/wd.py"

pull_once() {
    local kw="${1:-}"
    echo "──────── $(date +%H:%M:%S) 同步 ────────"
    local listing
    listing=$($WD ls "$APP" 2>/dev/null) || { echo "  ⚠️ 读不到目录"; return 1; }
    [ -z "$listing" ] && { echo "  ⚠️ 目录为空"; return 1; }

    local n=0
    # 日志类文件
    for f in $(echo "$listing" | awk '{print $NF}' | sed 's|.*/||' | grep -E '\.(log|txt|json|bin)$'); do
        [ -n "$kw" ] && case "$f" in *"$kw"*) ;; *) continue ;; esac
        local rsize
        rsize=$(echo "$listing" | grep "/$f\$" | awk '{print $2}')
        if [ -f "$DROP/$f" ] && [ "$(stat -c%s "$DROP/$f")" = "$rsize" ]; then continue; fi
        $WD get "$APP/$f" "$DROP/$f" >/dev/null 2>&1 && n=$((n+1))
    done

    # MMKV 数据文件（离线解析）
    # ★ 2026-10-25 不写死用户 UUID：目录里有什么就拉什么
    MMKV_UIDS=$(sshpass -e ssh -p "$PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$USER@$HOST" \
        "ls \"$APP/mmkv\" 2>/dev/null" 2>/dev/null | tr "\n" " ")
    for f in mmkv.default $MMKV_UIDS; do
        $WD get "$APP/mmkv/$f" "$DROP/mmap-$f" >/dev/null 2>&1
    done

    echo "  更新 $n 个 → $DROP"
    ls -lat "$DROP" 2>/dev/null | head -6 | tail -n +2 | awk '{printf "    %s  %s\n", $5, $9}'
}

case "${1:-}" in
--watch) while true; do pull_once "${2:-}"; sleep 20; done ;;
-h|--help) sed -n '2,10p' "$0" ;;
*) pull_once "${1:-}" ;;
esac
