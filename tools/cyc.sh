#!/usr/bin/bash
# ============================================================
# cyc.sh —— 一轮完整迭代（尼尼的"流水线"）🐲
#
#   编译 → 部署 → 回读校验 → 重启 App → 进会话 → 截图 → 捞日志
#
#   为什么要这个脚本：
#     以前七个动作全靠手敲，最容易犯的错是「编译和部署并行跑」
#     ⇒ dep.sh 拿到的是上一版产物 ⇒ 测了半天旧代码（今晚踩了两次）。
#     现在一条命令串起来，且每一步都**校验完再走下一步**。
#
# 用法：
#   ./cyc.sh                  全流程（默认标签 now）
#   ./cyc.sh -t v4            指定产物标签（截图/回看都用它）
#   ./cyc.sh -n               不重启 App（只编+部署）
#   ./cyc.sh -s               只截图 + 捞日志（不编不部署）
#   ./cyc.sh -c 3             进"今天第 3 个会话"
#   ./cyc.sh -g 'sug|孤儿'    只捞匹配的日志行
#   ./cyc.sh -l D             先把设备日志级别切到 D（配合 -g 调试）
#   ./cyc.sh -S               不改代码，只强制重编（touch 所有源文件）
#
# 退出码：0 成功；非 0 在哪一步断的就在哪一步（1 编 2 传 3 校验 4 应用 5 截图）
# ============================================================
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
# ★ 2026-10-25 不写死容器 UUID：统一从 .env 读
. "$(dirname "$0")/_env.sh" >/dev/null 2>&1 || { echo "❌ 读不到 .env"; exit 1; }
APP="$APP_DOCS"
DYLIB=$ROOT/src/FDMProbe5/.theos/obj/debug/arm64/FDMProbe.dylib
OUT=$ROOT/tmp/mcp-out
TAG=now
DO_BUILD=1
DO_RESTART=1
DO_SHOT=1
CONV=""
GREP=""
LEVEL=""
FORCE=0
SKIP_DEPLOY=0

while getopts "t:c:g:l:nshS" o; do
  case $o in
    t) TAG=$OPTARG ;;
    c) CONV=$OPTARG ;;
    g) GREP=$OPTARG ;;
    l) LEVEL=$OPTARG ;;
    n) DO_RESTART=0 ;;
    s) DO_BUILD=0; DO_RESTART=0 ;;
    S) FORCE=1 ;;
    *) sed -n '2,26p' "$0"; exit 1 ;;
  esac
done

# 设备上 FDM.dylib 的字节数（读不到就输出空）
device_size() {
  local i sz
  # ① 先走 MCP（快，但**设备锁屏时 run_command 会被封**）
  for i in 1 2 3; do
    sz=$(timeout 40 ./tools/rc.py "ls -l /var/jb/usr/lib/TweakInject/FDM.dylib" 2>/dev/null \
         | tr -s ' ' | cut -d' ' -f5 | tr -dc '0-9')
    if [ -n "$sz" ]; then echo "$sz"; return 0; fi
    sleep 1
  done
  # ② 兜底走 SSH（锁屏不影响）
  sz=$(timeout 30 ./tools/iphone.sh run "ls -l /var/jb/usr/lib/TweakInject/FDM.dylib" 2>/dev/null \
       | tr -s ' ' | cut -d' ' -f5 | tr -dc '0-9')
  echo "${sz:-}"
}

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }

# ---------------- 1. 编译 ----------------
if [ "$DO_BUILD" = 1 ]; then
  say "1/7 编译"
  if [ "$FORCE" = 1 ]; then
    touch src/FDMProbe5/*.m
    echo "  （强制重编：已 touch 全部源文件）"
  fi
  # shellcheck disable=SC1091
  source "$ROOT/env.sh" >/dev/null 2>&1
  BEFORE=$( [ -f "$DYLIB" ] && stat -c %Y "$DYLIB" || echo 0 )
  BUILDOUT=$( cd src/FDMProbe5 && make 2>&1 )
  if echo "$BUILDOUT" | grep -qE "error:"; then
    echo "$BUILDOUT" | grep -E "error:" | head -20
    bad "编译失败"
    exit 1
  fi
  AFTER=$( [ -f "$DYLIB" ] && stat -c %Y "$DYLIB" || echo 0 )
  if [ "$AFTER" = "$BEFORE" ]; then
    # make 认为无需重编（源文件没动）。这不代表设备上就是它：
    #   · 设备上已经是同一份（大小差 ≤ 512 = 签名区）→ 跳过部署
    #   · 设备上是旧的                                → **继续部署**
    LOCAL_NOW=$(stat -c %s "$DYLIB" 2>/dev/null || echo 0)
    DEV_NOW=$(device_size)
    if [ "${DEV_NOW:-0}" -gt 0 ] && [ "${DEV_NOW:-0}" -ge "${LOCAL_NOW:-1}" ] \
       && [ $(( ${DEV_NOW:-0} - ${LOCAL_NOW:-0} )) -le 512 ]; then
      ok "无需重编，设备已是这份产物（$DEV_NOW 字节）→ 跳过部署"
      SKIP_DEPLOY=1
    else
      ok "无需重编，但设备是旧产物（设备 ${DEV_NOW:-?} / 本地 ${LOCAL_NOW}）→ 继续部署"
    fi
  else
    ok "产物 $(stat -c %s "$DYLIB") 字节 @ $(date -d @$AFTER +%H:%M:%S)"
  fi
else
  say "1/7 编译（跳过）"
fi

# ---------------- 2. 部署 ----------------
if [ "$DO_BUILD" = 1 ] && [ "$SKIP_DEPLOY" = 0 ]; then
  say "2/7 部署"
  DEP=$( ./tools/dep.sh 2>&1 )
  echo "$DEP" | tail -3
  if ! echo "$DEP" | grep -q "✅ 已部署"; then
    bad "部署失败"
    exit 2
  fi
  ok "已上传并签名"
else
  say "2/7 部署（跳过${SKIP_DEPLOY:+}）"
fi

# ---------------- 3. 回读校验 ----------------
say "3/7 回读校验"
LOCAL=$(stat -c %s "$DYLIB" 2>/dev/null || echo 0)
REMOTE=$(device_size)
if [ -z "${REMOTE:-}" ]; then
  bad "读不到设备端文件（MCP 可能掉线）"
  exit 3
fi
if [ "$REMOTE" -lt "$LOCAL" ]; then
  bad "设备 $REMOTE < 本地 $LOCAL（没传成功）"
  exit 3
fi
ok "设备 $REMOTE 字节（本地 $LOCAL + 签名 $((REMOTE - LOCAL))）"

# ---------------- 日志级别（可选） ----------------
if [ -n "$LEVEL" ]; then
  say "· 切日志级别 → $LEVEL"
  timeout 40 ./tools/rc.py "printf '%s' '$LEVEL' > $APP/fdm-log.txt" >/dev/null 2>&1
  ok "已写 fdm-log.txt（2 秒内生效，无需重启）"
fi

# ---------------- 4~5. 重启 App ----------------
if [ "$DO_RESTART" = 1 ]; then
  say "4/7 重启 App"
  timeout 40 ./tools/mcp2.py kill_app '{"bundle_id":"com.deepseek.chat"}' >/dev/null 2>&1
  sleep 2
  timeout 40 ./tools/mcp2.py launch_app '{"bundle_id":"com.deepseek.chat"}' >/dev/null 2>&1
  sleep 6
  FRONT=$(timeout 40 ./tools/mcp2.py get_frontmost_app 2>/dev/null | grep -c deepseek)
  if [ "$FRONT" = 0 ]; then
    # 再拉一次（7P 内存紧，第一次常被杀）
    timeout 40 ./tools/mcp2.py launch_app '{"bundle_id":"com.deepseek.chat"}' >/dev/null 2>&1
    sleep 5
    FRONT=$(timeout 40 ./tools/mcp2.py get_frontmost_app 2>/dev/null | grep -c deepseek)
  fi
  if [ "$FRONT" = 0 ]; then
    bad "DeepSeek 没起来"
    exit 4
  fi
  ok "已在前台"

  say "5/7 进会话${CONV:+（第 $CONV 个）}"
  # 侧栏 → 会话（坐标来自 414x736 的 7P）
  timeout 40 ./tools/mcp2.py tap_screen '{"x":33,"y":45}' >/dev/null 2>&1
  sleep 2
  if [ -z "$CONV" ]; then
    Y=191   # 默认第一个「今天」的会话
  else
    Y=$(( 191 + (CONV - 1) * 46 ))
  fi
  timeout 40 ./tools/mcp2.py tap_screen "{\"x\":163,\"y\":$Y}" >/dev/null 2>&1
  sleep 5
  ok "已进入（y=$Y）"
else
  say "4~5/7 重启（跳过）"
fi

# ---------------- 6. 截图 ----------------
if [ "$DO_SHOT" = 1 ]; then
  say "6/7 截图"
  SHOT="$OUT/$TAG.png"
  timeout 70 ./tools/shot.py "$SHOT" | sed 's/^/  /'
  if [ ! -f "$SHOT" ]; then
    bad "没拿到截图"
    exit 5
  fi
  ok "$SHOT"
fi

# ---------------- 7. 捞日志 ----------------
say "7/7 日志"
# 设备锁屏时 MCP 的 run_command 会被封 ⇒ 退回 SSH
_log_via_mcp() {
  local cmd="$1"
  local out
  out=$(timeout 45 ./tools/rc.py "$cmd" 2>/dev/null)
  # MCP 被 block 时返回的是 JSON 提示，不是正文
  case "$out" in
    *'"blocked"'*|*'device_locked_or_screen_off'*|"") return 1 ;;
  esac
  printf '%s\n' "$out"
  return 0
}
_log_via_ssh() {
  timeout 30 ./tools/iphone.sh run "$1" 2>/dev/null
}

if [ -n "$GREP" ]; then
  CMD="grep -E '$GREP' $APP/fdm.log | tail -25 | cut -c1-160"
else
  CMD="tail -20 $APP/fdm.log | cut -c1-160"
fi
if ! _log_via_mcp "$CMD"; then
  echo "  （MCP 被封/离线，改走 SSH）"
  _log_via_ssh "$CMD"
fi

printf '\n\033[1;36m════ 一轮结束：%s ════\033[0m\n' "$TAG"
