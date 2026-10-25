#!/usr/bin/bash
# ============================================================
# free.sh —— 给 DeepSeek 腾内存 + 启动（iPhone 7P 只有 2GB）
#
#   ./free.sh            清理 + 启动 App
#   ./free.sh -c         只清理，不启动
#
# ⚠️ 两个已知的「假崩溃」（都跟代码无关）：
#   ① 内存 < 150MB → 系统静默拒绝启动，无崩溃日志
#   ② **设备锁屏** → uiopen 返回成功但进程不出现，日志一片空白
#   判断方法：看日志有没有「==================== 启动 ====================」
#     有 → 模块跑了，是模块的问题
#     没有 → 压根没启动，先解锁 / 腾内存
# ============================================================
set -u
# ★ 口令/主机来自 .env（脚本里不再有明文口令）
. "$(dirname "$0")/_env.sh" || exit 1
# ★ 2026-10-25 不写死容器 UUID（.env 里有）
: "${APP_DOCS:?APP_DOCS 未设置，看 .env}"
SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
run() { sshpass -e ssh $SSH_OPTS "$USER@$HOST" "$@" 2>&1 | grep -v "^Warning:"; }

echo "--- 清理前 ---"
run 'vm_stat | grep "Pages free"'

echo "--- 杀掉耗内存的后台 ---"
run 'killall -9 mediaanalysisd-service mediaanalysisd assistantd searchd \
  amsengagementd cloudd duetexpertd appstored chronod TodayExtension \
  WidgetExtension ScreenTimeWidgetExtension TestFlightServiceExtension \
  com.apple.DocumentManager.Service Filza Preferences 2>/dev/null; sleep 2'

echo "--- 清理后 ---"
run 'vm_stat | grep "Pages free"'

if [ "${1:-}" != "-c" ]; then
    echo "--- 启动 DeepSeek ---"
    run 'uiopen --bundleid com.deepseek.chat >/dev/null 2>&1; sleep 20'
    P=$(run 'ps aux | grep "DeepSeek Chat.app" | grep -v grep | sed "s/  */ /g" | cut -d" " -f2 | head -1')
    if [ -n "$P" ]; then
        echo "  ✅ 启动成功 pid=$P"
        echo "--- 模块日志（判断 hook 是否跑起来）---"
        run "grep -E '启动|构建时间|\[bg\]|\[photo\]' '$APP_DOCS/fdm.log' 2>/dev/null | tail -12"
    else
        echo "  ❌ 没起来。两个常见原因："
        echo "     ① 设备锁屏了 —— 请先解锁手机再试"
        echo "     ② 内存不足 —— 再跑一次 ./free.sh"
        echo "--- 日志最后一行（判断模块有没有跑）---"
        run "tail -3 '$APP_DOCS/fdm.log' 2>/dev/null"
        echo "  （如果日志里没有「启动」，说明 App 压根没启动）"
    fi
fi
