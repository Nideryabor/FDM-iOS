#!/usr/bin/bash
# ============================================================
# elikit.sh —— 开关 ElleKit 对 FDM 的注入注册
#
#   ./elikit.sh off    摘掉注册（改名 .disabled），只留 TrollFools 那份
#   ./elikit.sh on     恢复注册（改回原名）
#   ./elikit.sh status 看当前状态
#
# 为什么要有这个：
#   TrollFools 注入的是 App.app/Frameworks/FDM.dylib，
#   ElleKit 注入的是 /var/jb/usr/lib/TweakInject/FDM.dylib，
#   **两个不同路径 = 两个 dyld image** ⇒ 构造函数各跑一次。
#   静态变量（那个纯 C 原子锁）是每个 image 各自的副本，跨份不共享，
#   所以「防重」实测挡不住这种情况（只有 ObjC 类名锁能挡，但它 3.5s 后才生效）。
#
#   ⇒ 试 TrollFools 版时，先把 ElleKit 这条摘掉，保证只有一份。
#
# 备份：FDM.plist.bak-troll / FDM.dylib.bak-troll（首次 off 时自动建）
# ============================================================
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tools/_env.sh
. "$(dirname "$0")/_env.sh" || exit 1

TI=/var/jb/usr/lib/TweakInject
SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR"

# 用 stdin 传脚本给 sudo sh（避免引号地狱）
# ★ 2026-10-25 安全修复：口令**绝不**进远端命令行
#   旧写法 "... && echo '$PW' | sudo -S ..." ⇒ 本地展开后被拼进发到设备的命令串，
#   执行那一两秒设备上 `ps aux` 能直接看到明文（任何进程都行，含宿主 App）。
#   新写法分两步，argv 里只剩 "sudo -S -p '' sh /tmp/xxx"：
#     ① 脚本内容走 stdin 落到临时文件（内容里不含口令）
#     ② 口令单独走 stdin 喂给 sudo -S
ssu() {
    local tmp="/tmp/_fdm_$$.sh"
    printf '%s\n' "$1" | sshpass -e ssh $SSH_OPTS "$USER@$HOST" "cat > $tmp" 2>&1 \
        | grep -v "^Warning:" | grep -v "^Permanently"
    printf '%s\n' "$PW" | sshpass -e ssh $SSH_OPTS "$USER@$HOST" \
        "sudo -S -p '' sh $tmp; rm -f $tmp" 2>&1 \
        | grep -v "^Warning:" | grep -v "^Permanently" | grep -v "^Password:"
}

# 把 FDMLoader 会蹭到的所有 fdm-hot.dylib 隔离掉
# （App bundle 里那个 FDMLoader 会按顺序找这几个路径，找到就 dlopen）
stale_hot() {
    local act="$1"
    if [ "$act" = "off" ]; then
        ssu "for p in /var/tmp/fdm-hot.dylib /var/mobile/Media/fdm-hot.dylib /var/mobile/Documents/fdm-hot.dylib /var/jb/usr/lib/fdm-hot.dylib; do
  [ -f \"\$p\" ] && mv \"\$p\" \"\${p}.old-disabled\" && echo \"  ✓ 隔离 \$p\" 
done; echo '  旧 fdm-hot.dylib 已全部隔离'"
    else
        ssu "for p in /var/tmp /var/mobile/Media /var/mobile/Documents /var/jb/usr/lib; do
  [ -f \"\$p/fdm-hot.dylib.old-disabled\" ] && mv \"\$p/fdm-hot.dylib.old-disabled\" \"\$p/fdm-hot.dylib\" && echo \"  ✓ 恢复 \$p/fdm-hot.dylib\"
done; echo done"
    fi
}

case "${1:-status}" in
  off)
    echo "=== 备份 + 摘掉 ElleKit 注册 ==="
    ssu "set -e
cd $TI
[ -f FDM.plist.bak-troll ] || cp -a FDM.plist FDM.plist.bak-troll
[ -f FDM.dylib.bak-troll ] || cp -a FDM.dylib FDM.dylib.bak-troll
echo '  备份就绪'
[ -f FDM.plist ] && mv FDM.plist FDM.plist.disabled && echo '  ✓ FDM.plist → .disabled'
[ -f FDM.dylib ] && mv FDM.dylib FDM.dylib.disabled && echo '  ✓ FDM.dylib → .disabled'
echo '--- 现状 ---'
ls -l | grep -i fdm"
    echo
    echo "=== 隔离旧 fdm-hot.dylib（防 FDMLoader 加载老版本）==="
    stale_hot off
    ;;
  on)
    echo "=== 恢复 ElleKit 注册 ==="
    ssu "set -e
cd $TI
[ -f FDM.plist.disabled ] && mv FDM.plist.disabled FDM.plist && echo '  ✓ FDM.plist 已恢复'
[ -f FDM.dylib.disabled ] && mv FDM.dylib.disabled FDM.dylib && echo '  ✓ FDM.dylib 已恢复'
echo '--- 现状 ---'
ls -l | grep -i fdm"
    ;;
  status|*)
    echo "=== ElleKit / TweakInject 现状 ==="
    ssu "cd $TI; ls -l | grep -i fdm || echo '  (没有 FDM 相关文件)'"
    ;;
esac
