#!/usr/bin/bash
# ============================================================
# dep-troll.sh —— 把产物替换进 TrollFools 注入点
#
#   ./dep-troll.sh              用 dist/FDM-<最新>-trollfools/FDM.dylib
#   ./dep-troll.sh <文件.dylib>  用指定文件
#
# 为什么单独一个脚本（而不是复用 dep.sh）：
#   dep.sh 装的是 /var/jb/usr/lib/TweakInject/FDM.dylib（ElleKit 路线），
#   而当前设备走的是 **TrollFools 注入**：
#     它把 Alamofire 打了补丁 → 链到自建的 CydiaSubstrate.framework →
#     由它加载 App 包里的 Frameworks/FDM-troll.dylib
#   ⇒ 要换版本，替换的就是那个文件，别的都不用动。
#
# ★ 铁律：替换前先备份（同名 .bak-<时间>），替换后**回读大小**。
# ============================================================
set -u
. "$(dirname "$0")/_env.sh" || exit 1

SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"
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

# ---------- ① 找 App 包 ----------
APP=$(sshdo "ls -d /var/containers/Bundle/Application/*/DeepSeek*.app 2>/dev/null | head -1" | tr -d '\r')
if [ -z "$APP" ]; then
    APP=$(sshdo "ls -d /var/mobile/Containers/Bundle/Application/*/DeepSeek*.app 2>/dev/null | head -1" | tr -d '\r')
fi
if [ -z "$APP" ]; then echo "❌ 找不到 DeepSeek Chat.app"; exit 1; fi
TARGET="$APP/Frameworks/FDM-troll.dylib"
echo "=== App: $APP"
echo "=== 目标: Frameworks/FDM-troll.dylib"

# ---------- ② 选源文件 ----------
SRC="${1:-}"
if [ -z "$SRC" ]; then
    SRC=$(ls -t /workspace/ios-port/dist/FDM-*-trollfools/FDM.dylib 2>/dev/null | head -1)
fi
[ -f "$SRC" ] || { echo "❌ 源文件不存在: $SRC"; exit 1; }
LOCAL_SZ=$(stat -c%s "$SRC")
echo "=== 源: $SRC（$LOCAL_SZ 字节）"

# ---------- ③ 备份 + 上传 ----------
STAMP=$(date +%m%d-%H%M%S)
echo "=== 备份现有文件 ==="
sshsu "cp '$TARGET' '$TARGET.bak-$STAMP' && ls -l '$TARGET.bak-$STAMP' | sed 's/.* [0-9]* //' && echo BACKUP_OK" | tail -2

echo "=== 上传到 /tmp ==="
sshdo "cat > /tmp/FDM-new.dylib" < "$SRC"
UP_SZ=$(sshdo "wc -c < /tmp/FDM-new.dylib" | tr -d ' \r')
echo "  设备收到 $UP_SZ 字节"
if [ "$UP_SZ" != "$LOCAL_SZ" ]; then echo "❌ 上传不完整"; exit 1; fi

# ---------- ④ 替换 ----------
echo "=== 替换 ==="
sshsu "cp /tmp/FDM-new.dylib '$TARGET' && chmod 755 '$TARGET' && chown _installd:_installd '$TARGET' 2>/dev/null || chown mobile:mobile '$TARGET'; ldid -S '$TARGET' 2>/dev/null; echo DONE" | tail -2

# ---------- ⑤ 回读验证 ----------
SIZE=$(sshdo "wc -c < '$TARGET'" | tr -d ' \r')
echo "=== 回读: $SIZE 字节（本地 $LOCAL_SZ）==="
if [ -z "$SIZE" ] || [ "$SIZE" -lt "$LOCAL_SZ" ]; then
    echo "❌ 回读异常，可能没写进去"; exit 1
fi
echo "✅ 部署完成（ldid 签名可能 +192 字节，属正常）"
