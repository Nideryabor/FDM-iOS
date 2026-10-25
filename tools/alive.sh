#!/usr/bin/bash
# ============================================================
#  alive.sh —— 宿主还活着吗？（**别再拿进程数直接判崩溃**）
#
#  2026-10-25 血案：
#    看到 `ps ... | wc -l` = 0，我判定「App 崩了」，还回滚了版本。
#    真相：**设备息屏**，App 被系统挂起/回收 —— 完全正常。
#    没有崩溃日志（CrashReporter 里一条新的都没有）就是最强的反证。
#
#  正确判据（按顺序）：
#    ① 有没有**新的**崩溃日志   → 有 = 真崩了
#    ② 进程在不在              → 不在 + 无崩溃日志 ⇒ 九成是息屏
#    ③ 屏幕锁没锁              → 锁定 ⇒ 上面那条就是息屏
#    ④ 日志末行时间 vs 现在     → 差很多且停在固定间隔 ⇒ 被挂起
# ============================================================
set -u
. "$(dirname "$0")/_env.sh" || exit 1
SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
r() { sshpass -e ssh $SSH_OPTS "$USER@$HOST" "$@" 2>&1 | grep -v "^Warning:" | grep -v "^Permanently"; }

echo "── ① 进程 ──"
N=$(r 'ps aux | grep "DeepSeek Chat.app/DeepSeek Chat" | grep -v grep | wc -l' | tr -d ' \r')
echo "   进程数: $N"

echo "── ② 最近 30 分钟有新的崩溃日志吗 ──"
CRASH=$(r 'find /var/mobile/Library/Logs/CrashReporter -name "DeepSeek*" -mmin -30 2>/dev/null | head -3')
if [ -n "$CRASH" ]; then
    echo "   ❌ 有崩溃日志："; echo "$CRASH" | sed 's/^/      /'
else
    echo "   ✅ 无（这条最重要 —— 没有崩溃日志就基本不是崩）"
fi

echo "── ③ 屏幕锁定状态 ──"
LOCK=$(r 'ioreg -l 2>/dev/null | grep -i "IOHIDSystem" -A20 | grep -i "HIDIdleTime"' | head -1 | tr -d ' ')
echo "   ${LOCK:-（读不到，iOS 15 下正常）}"

echo "── ④ 日志末行时间 ──"
r "date '+   现在: %H:%M:%S'"
r "tail -1 '$APP_DOCS/fdm.log' 2>/dev/null | cut -c1-60 | sed 's/^/   末行: /'"

echo
if [ "$N" = "0" ] && [ -z "$CRASH" ]; then
    echo "⇒ 判定：**大概率是息屏/被系统回收**，不是崩溃。"
    echo "   处理：亮屏 + uiopen --bundleid com.deepseek.chat"
elif [ -n "$CRASH" ]; then
    echo "⇒ 判定：**真崩了**，看上面的崩溃日志。"
else
    echo "⇒ 判定：进程正常在跑。"
fi
