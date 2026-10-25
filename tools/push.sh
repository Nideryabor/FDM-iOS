#!/usr/bin/bash
# ============================================================
# push.sh —— 把本地文件推到手机（走 SSH，锁屏也能用）
#
#   ./push.sh <本地文件> <设备上的目标路径>
#   ./push.sh dist/FDM-v22-trollfools/FDM.dylib /var/mobile/Documents/FDM-troll.dylib
#
# 走的是 /var/mobile（mobile 用户可写），不需要 sudo。
# ============================================================
set -u
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=tools/_env.sh
. "$(dirname "$0")/_env.sh" || exit 1

SRC="${1:-}"
DST="${2:-}"
if [ -z "$SRC" ] || [ -z "$DST" ]; then
    sed -n '2,10p' "$0"
    exit 1
fi
[ -f "$SRC" ] || { echo "❌ 本地没有：$SRC"; exit 1; }

SSH_OPTS="-P $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR"

echo "推送：$SRC"
echo "  →  $USER@$HOST:$DST"
echo "  大小：$(stat -c %s "$SRC") 字节"

if sshpass -e scp $SSH_OPTS "$SRC" "$USER@$HOST:$DST" 2>&1 | grep -v "^Warning:" | grep -v "^Permanently"; then
    :
fi

# 回读校验（铁律：传完必须确认）
# ⚠️ 两个坑（都踩过）：
#   ① 不要把口令灌进 ssh 的 stdin —— 会占掉远端命令的 stdin，输出被污染
#   ② 设备上的 stat 是 **GNU coreutils**（/var/jb/usr/bin/stat），
#      要用 `stat -c %s`；用 BSD 的 `-f %z` 会输出文件系统信息（一长串数字）
SIZE=$(sshpass -e ssh -p "$PORT" \
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=20 -o LogLevel=ERROR "$USER@$HOST" \
       "stat -c %s '$DST' 2>/dev/null || wc -c < '$DST'" 2>/dev/null | tr -dc '0-9')

LOCAL=$(stat -c %s "$SRC")
if [ -z "${SIZE:-}" ]; then
    echo "❌ 回读失败：设备上读不到 $DST"
    exit 1
fi
if [ "$SIZE" != "$LOCAL" ]; then
    echo "❌ 大小不符：本地 $LOCAL / 设备 $SIZE"
    exit 1
fi

echo "✅ 已到位（$SIZE 字节）"
echo "   md5: $(md5sum "$SRC" | cut -d' ' -f1)"
