#!/usr/bin/bash
# ============================================================
# mcp.sh —— 调用设备上的 ios-mcp（46 个工具）🐲
#
#   ./mcp.sh tools                    列出所有工具
#   ./mcp.sh shot [文件名]            截图（回传 Base64 → 存 png）
#   ./mcp.sh ui                       当前屏幕 UI 元素
#   ./mcp.sh front                    前台 App
#   ./mcp.sh syslog [秒]              实时系统日志（解决日志级别问题）
#   ./mcp.sh call <工具> '<json参数>'  任意工具
#   ./mcp.sh run '<shell命令>'        设备上执行命令
#
# 原理：ios-mcp 是装在设备上的 MCP 服务器（SpringBoard 注入），
#      监听 8090，提供截图 / UI树 / 触控 / 系统日志 / 文件读写。
#      尼尼直接用 curl 走 JSON-RPC，不需要改 MCP 客户端配置。
# ============================================================
set -u
# ★ 主机/端口来自 .env（找不到就用 localhost，别写死别人的局域网 IP）
# shellcheck source=tools/_env.sh
if [ -f "$(dirname "$0")/_env.sh" ]; then
    . "$(dirname "$0")/_env.sh" 2>/dev/null || true
fi
HOST="${IOS_MCP_HOST:-${IPHONE_HOST:-127.0.0.1}}"
PORT="${IOS_MCP_PORT:-8090}"
BASE="http://$HOST:$PORT"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${IOS_MCP_OUT:-/workspace/ios-port/tmp/mcp-out}"
mkdir -p "$OUT"

_post() {
    curl -s -m "${IOS_MCP_TIMEOUT:-30}" -X POST "$BASE/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "$1"
}

# 从 JSON-RPC 响应里抽 JSON（兼容 SSE 的 data: 前缀）
_onlyjson() {
    python3 -c '
import sys, json
raw = sys.stdin.read()
out = None
for line in raw.split("\n"):
    s = line.strip()
    if s.startswith("data:"):
        s = s[5:].strip()
    if s.startswith("{"):
        try:
            json.loads(s)
            out = s
        except Exception:
            pass
if out is None:
    out = raw.strip()
print(out)
'
}

call() {
    local name="$1"
    local args="${2-}"
    [ -z "$args" ] && args='{}' 
    local payload
    payload=$(python3 -c '
import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
  "params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}, ensure_ascii=False))
' "$name" "$args")
    _post "$payload" | _onlyjson
}

case "${1:-}" in
tools)
    _post '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | _onlyjson \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
for t in d.get("result",{}).get("tools",[]):
    print("%-22s %s" % (t["name"], (t.get("description") or "")[:70]))
'
    ;;

shot)
    FN="${2:-shot-$(date +%H%M%S).png}"
    call screenshot '{}' > "$OUT/.shot.json" 2>&1
    python3 - "$OUT/.shot.json" "$OUT/$FN" <<'PY'
import json, sys, base64, os
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, encoding="utf-8", errors="replace").read()
# 可能是 JSON-RPC 包装，也可能直接是 result
try:
    d = json.loads(raw)
except Exception:
    print("❌ 响应不是 JSON:", raw[:200]); sys.exit(1)
res = d.get("result", d)
if d.get("error"):
    print("❌ 错误:", d["error"]); sys.exit(1)
content = res.get("content", [])
for c in content:
    if c.get("type") == "image":
        b = c.get("data", "")
        with open(dst, "wb") as f:
            f.write(base64.b64decode(b))
        print(f"✅ 截图已存 {dst}（{os.path.getsize(dst)} 字节）")
        sys.exit(0)
    if c.get("type") == "text":
        print("ℹ️", c.get("text", "")[:200])
print("⚠️ 没拿到图片，原始:", json.dumps(res, ensure_ascii=False)[:300])
PY
    ;;

ui)
    call get_ui_elements '{}' | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
if d.get("error"): print("❌", d["error"]); raise SystemExit
for c in d.get("result",{}).get("content",[]):
    t=c.get("text","")
    if t: print(t[:4000])
'
    ;;

front)
    call get_frontmost_app '{}' | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
for c in d.get("result",{}).get("content",[]):
    print(c.get("text","")[:500])
'
    ;;

syslog)
    SEC="${2:-5}"
    call get_syslog "{\"duration\":$SEC}" | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
if d.get("error"): print("❌", d["error"]); raise SystemExit
for c in d.get("result",{}).get("content",[]):
    t=c.get("text","")
    if t: print(t[:20000])
'
    ;;

run)
    call run_command "{\"command\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1],ensure_ascii=False))' "$2")}" \
    | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
if d.get("error"): print("❌", d["error"]); raise SystemExit
r = d.get("result",{})
# run_command 通常直接返回 {exitCode, output}
if "output" in r:
    print(r.get("output","")[:8000]); raise SystemExit
sc = r.get("structuredContent") or {}
if "output" in sc:
    print(sc.get("output","")[:8000]); raise SystemExit
for c in r.get("content",[]):
    print(c.get("text","")[:8000])
'
    ;;

call)
    A3="${3-}"
    [ -z "$A3" ] && A3='{}'
    call "$2" "$A3"
    ;;

*)
    sed -n '2,16p' "$0"
    ;;
esac
