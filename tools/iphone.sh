#!/usr/bin/bash
# ============================================================
# iPhone 远程控制（SSH）
#
#   ./iphone.sh restart      重启 DeepSeek Chat
#   ./iphone.sh log [n]      看最近 n 行日志（默认 60）
#   ./iphone.sh tail         实时日志
#   ./iphone.sh crash        看最新崩溃日志摘要
#   ./iphone.sh ls           列 Documents
#   ./iphone.sh pull         拉全部日志到本地
#   ./iphone.sh run '<cmd>'  执行任意命令
#
# 配置：全部从 .env 读（见 .env.example）
#           IPHONE_PW（来自 .env，必填）
# ============================================================
set -u
# ★ 口令/主机/沙盒路径全部来自 .env（脚本里不再有任何明文口令）
# shellcheck source=tools/_env.sh
. "$(dirname "$0")/_env.sh" || exit 1

SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
ssh_run() {
    sshpass -e ssh $SSH_OPTS "$USER@$HOST" "$@" 2>&1 | grep -v "^Warning:" | grep -v "^Permanently"
}

case "${1:-}" in

restart)
    echo "=== 重启 DeepSeek Chat ==="
    ssh_run 'killall "DeepSeek Chat" 2>/dev/null; echo killed; sleep 2'
    sleep 1
    ssh_run 'uiopen --bundleid com.deepseek.chat 2>&1; echo opened'
    sleep 3
    PID=$(ssh_run 'ps aux | grep "DeepSeek Chat.app/DeepSeek Chat" | grep -v grep | sed "s/  */ /g" | cut -d" " -f2 | head -1')
    echo "=== 新 PID: ${PID:-（未启动）} ==="
    ;;

log)
    N="${2:-60}"
    ssh_run "tail -$N '$APP_DOCS/fdm.log' 2>&1"
    ;;

tail)
    echo "=== 实时日志（Ctrl+C 退出）==="
    sshpass -e ssh $SSH_OPTS "$USER@$HOST" "tail -f '$APP_DOCS/fdm.log'" 2>/dev/null
    ;;

crash)
    echo "=== 最新崩溃日志 ==="
    F=$(ssh_run 'ls -t /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -i "^DeepSeek Chat" | head -1')
    if [ -z "$F" ]; then echo "（没有崩溃日志）"; exit 0; fi
    echo "文件: $F"
    ssh_run "head -c 3000 '/var/mobile/Library/Logs/CrashReporter/$F' 2>&1"
    ;;

ls)
    ssh_run "ls -la '$APP_DOCS' 2>&1 | head -30"
    ;;

pull)
    DEST=/workspace/ios-port/iphone
    mkdir -p "$DEST"
    echo "=== 拉日志 ==="
    for f in fdm.log fdm.log.1 fdm-ui.txt; do
        sshpass -e scp $SSH_OPTS "$USER@$HOST:$APP_DOCS/$f" "$DEST/$f" 2>/dev/null \
            && echo "  ✅ $f" || true
    done
    ls -la "$DEST" 2>/dev/null | tail -6
    ;;

run)
    shift
    ssh_run "$@"
    ;;

*)
    sed -n '2,16p' "$0"
    ;;
esac
