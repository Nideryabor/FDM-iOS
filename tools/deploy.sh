#!/usr/bin/bash
# ============================================================
# FDM 一键部署 v2（ElleKit / TweakInject 路线）
#
#   ./deploy.sh              编译 → 上传 → 装进 TweakInject → 重启 → 读日志
#   ./deploy.sh -s           只重启（不编译）
#   ./deploy.sh -l           只看日志
#
# ★ 为什么换路线（2026-10-17 的血泪）：
#   老路线靠 TrollFools 注入的 FDMLoader，它在启动后 2 秒**只尝试一次**
#   dlopen("/var/jb/usr/lib/fdm-hot.dylib")。实测偶发出现
#   `跳过（不存在）: /var/jb/usr/lib/fdm-hot.dylib` —— 文件明明在，沙盒却说不在。
#   一次偶发 = 整个 App 会话模块全废，而且看起来像「功能没生效」。
#
#   现在改用设备自带的 ElleKit 注入器：
#     /var/jb/usr/lib/TweakInject/FDM.dylib  +  FDM.plist (Filter.Bundles=com.deepseek.chat)
#   注入发生在 dyld 装载阶段，由系统驱动，比「自己 stat 路径」可靠得多。
#   （dylib 构造函数已改为「只调度延迟块」，避免 dyld 阶段碰 ObjC 崩溃）
# ============================================================
set -u
# ★ 口令/主机来自 .env（脚本里不再有明文口令）
. "$(dirname "$0")/_env.sh" || exit 1
# ★ 2026-10-25 绝不把设备容器 UUID 写死在脚本里（那是装置标识）
APP="$APP_DOCS"
TI="/var/jb/usr/lib/TweakInject"
TIDYLIB="$TI/FDM.dylib"
TIPLIST="$TI/FDM.plist"

SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
sshdo() { sshpass -e ssh $SSH_OPTS "$USER@$HOST" "$@" 2>&1 | grep -v "^Warning:"; }

# ★ 用 stdin 传密码 + 单独脚本文件执行，彻底避开引号地狱
# ★ 2026-10-25 安全修复：口令**绝不**进远端命令行
#   旧写法 "... && echo '$PW' | sudo -S ..." ⇒ 本地展开后被拼进发到设备的命令串，
#   执行那一两秒设备上 `ps aux` 能直接看到明文（任何进程都行，含宿主 App）。
#   新写法分两步，argv 里只剩 "sudo -S -p '' sh /tmp/xxx"：
#     ① 脚本内容走 stdin 落到临时文件（内容里不含口令）
#     ② 口令单独走 stdin 喂给 sudo -S
sshsu() {
    local tmp="/tmp/_fdm_$$.sh"
    printf '%s\n' "$1" | sshpass -e ssh $SSH_OPTS "$USER@$HOST" "cat > $tmp" 2>&1 \
        | grep -v "^Warning:" | grep -v "^Permanently"
    printf '%s\n' "$PW" | sshpass -e ssh $SSH_OPTS "$USER@$HOST" \
        "sudo -S -p '' sh $tmp; rm -f $tmp" 2>&1 \
        | grep -v "^Warning:" | grep -v "^Permanently" | grep -v "^Password:"
}

do_restart() {
    echo "--- 重启 App ---"
    sshdo 'killall "DeepSeek Chat" 2>/dev/null; sleep 2; uiopen --bundleid com.deepseek.chat >/dev/null 2>&1; true'
    sleep 9
    P=$(sshdo 'ps aux | grep "DeepSeek Chat.app/DeepSeek" | grep -v grep' | head -1)
    [ -n "$P" ] && echo "  PID 起来了" || echo "  ⚠️ 没起来"
}

do_log() {
    echo "--- 版本 + 钩子 ---"
    sshdo "grep -E '构建时间|sqlite 静态钩子|strip\\] 安装完成|\\[sync\\] ★|配置：' '$APP/fdm.log' 2>/dev/null | tail -8"
    echo "--- 是否加载（ElleKit 路线，loader.log 失败也无所谓）---"
    sshdo "ls -l '$TIDYLIB' '$TIPLIST' 2>/dev/null"
}

case "${1:-}" in
-s) do_restart; echo; do_log ;;
-l) do_log ;;
*)
    echo "=== ① 编译 ==="
    source /workspace/ios-port/env.sh >/dev/null 2>&1
    cd /workspace/ios-port/src/FDMProbe5 || exit 1
    make clean >/dev/null 2>&1
    if ! make 2>&1 | grep -E "error:" ; then :; else echo "❌ 编译失败"; exit 1; fi
    D=.theos/obj/debug/arm64/FDMProbe.dylib
    [ -f "$D" ] || { echo "❌ 没产物"; exit 1; }
    echo "  ✅ $(stat -c%s $D) 字节"
    cp "$D" /workspace/ios-port/out/latest.dylib

    echo "=== ② 上传 ==="
    python3 /workspace/ios-port/tools/wd.py put /workspace/ios-port/out/latest.dylib "$APP" >/dev/null 2>&1
    echo "  ✅ 已上传"

    echo "=== ③ 装进 TweakInject + 签名 ==="
    sshsu "cp '$APP/latest.dylib' '$TIDYLIB' && chmod 755 '$TIDYLIB' && chown root:wheel '$TIDYLIB' && ldid -S '$TIDYLIB' && echo OK" | tail -2

    # ★ 关键自检：装完必须回读验证（老版本就是因为「文件不见了却报成功」坑过）
    SZ=$(sshdo "ls -l '$TIDYLIB' 2>/dev/null | awk '{print \$5}'")
    if [ -z "$SZ" ]; then
        echo "  ❌ 部署后 $TIDYLIB 不存在！"
        exit 1
    fi
    echo "  ✅ 已部署 ${SZ} 字节（回读验证通过）"

    # plist 只在缺失时补（内容固定，不用每次覆盖）
    HAVE=$(sshdo "test -f '$TIPLIST' && echo yes")
    if [ "$HAVE" != "yes" ]; then
        echo "  ⚠️ 缺 FDM.plist，正在创建"
        sshsu "cat > '$TIPLIST' <<'PLISTEOF'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Filter</key>
	<dict>
		<key>Bundles</key>
		<array>
			<string>com.deepseek.chat</string>
		</array>
	</dict>
</dict>
</plist>
PLISTEOF
chmod 644 '$TIPLIST' && chown root:wheel '$TIPLIST' && echo PLIST_OK" | tail -1
    fi

    do_restart
    echo
    do_log
    ;;
esac
