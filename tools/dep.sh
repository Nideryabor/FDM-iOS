#!/usr/bin/bash
# ============================================================
# dep.sh —— 编译产物 → 设备 /var/jb/usr/lib/TweakInject/FDM.dylib
#
#   ./dep.sh          只部署（不编译）
#   ./dep.sh -b       先编译再部署
#
# 为什么要单独一个脚本：
#   deploy.sh 会 make clean + 重启 App，太慢；
#   调试时我们通常已经手动 make 好了，只想要「上传 + 签名 + 回读验证」。
#
# ★ 铁律：部署后必须**回读大小**。历史上出现过
#   「cp 报成功但文件其实没变」⇒ 一直测旧版本。
# ============================================================
set -u
# ★ 口令/主机/沙盒路径全部来自 .env（脚本里不再有任何明文口令）
# shellcheck source=tools/_env.sh
. "$(dirname "$0")/_env.sh" || exit 1
APP="$APP_DOCS"
TI="/var/jb/usr/lib/TweakInject"
SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"
SRC="/workspace/ios-port/src/FDMProbe5/.theos/obj/debug/arm64/FDMProbe.dylib"

sshdo() { sshpass -e ssh $SSH_OPTS "$USER@$HOST" "$@" 2>&1 | grep -v "^Warning:" | grep -v "^Permanently"; }
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

if [ "${1:-}" = "-b" ]; then
    echo "=== 编译 ==="
    source /workspace/ios-port/env.sh >/dev/null 2>&1
    cd /workspace/ios-port/src/FDMProbe5 || exit 1
    if make 2>&1 | grep -E "error:"; then
        echo "❌ 编译失败"
        exit 1
    fi
    echo "  ✅ 编译完成"
fi

[ -f "$SRC" ] || { echo "❌ 产物不存在: $SRC"; exit 1; }
LOCAL_SZ=$(stat -c%s "$SRC")
echo "=== 上传（$LOCAL_SZ 字节）==="
sshdo "cat > $APP/new.dylib" < "$SRC"
sshdo "ls -l $APP/new.dylib | sed 's/.* //'"

echo "=== 安装 + 签名 ==="
sshsu "cp $APP/new.dylib $TI/FDM.dylib && chmod 755 $TI/FDM.dylib && chown root:wheel $TI/FDM.dylib && ldid -S $TI/FDM.dylib && echo OK" | tail -2

echo "=== 回读验证 ==="
SIZE=$(sshdo "wc -c < $TI/FDM.dylib" | tr -d ' \r')
SIZE=${SIZE%% *}
if [ -z "$SIZE" ]; then
    echo "  ❌ $TI/FDM.dylib 不存在！"
    exit 1
fi
# ldid 会追加签名，所以设备端应该 = 本地 + 约 192 字节
if [ "$SIZE" -lt "$LOCAL_SZ" ]; then
    echo "  ❌ 大小异常：设备 $SIZE < 本地 $LOCAL_SZ"
    exit 1
fi
echo "  ✅ 已部署 $SIZE 字节（本地 $LOCAL_SZ + 签名 $((SIZE - LOCAL_SZ))）"
