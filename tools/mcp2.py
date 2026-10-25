#!/usr/bin/env python3
"""mcp2.py —— 直接调设备 ios-mcp，把结果写文件（避免 shell 截断/引号地狱）
用法:
  ./mcp2.py <tool> [json]            → 打印文本结果
  ./mcp2.py <tool> [json] --raw FILE → 原始 JSON 存 FILE
"""
import json, sys, os, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from env import ENV

# ★ 主机/端口来自 .env（不写死，换网络只改一处）
HOST = ENV.host(); PORT = ENV.port()

def call(tool, args=None, timeout=40):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                       "params":{"name":tool,"arguments":args or {}}}).encode()
    req = urllib.request.Request("http://%s:%d/mcp" % (HOST, PORT), data=body,
        headers={"Content-Type":"application/json",
                 "Accept":"application/json, text/event-stream"})
    raw = urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8","replace")
    for line in raw.split("\n"):
        s = line.strip()
        if s.startswith("data:"): s = s[5:].strip()
        if s.startswith("{"):
            try: return json.loads(s)
            except Exception: pass
    return json.loads(raw)

if __name__ == "__main__":
    tool = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != "-" else {}
    d = call(tool, args)
    if "--raw" in sys.argv:
        f = sys.argv[sys.argv.index("--raw")+1]
        open(f, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=1))
        print("saved", f, len(json.dumps(d)))
    else:
        res = d.get("result", d)
        if d.get("error"): print("❌", d["error"]); raise SystemExit(1)
        for c in res.get("content", []):
            if c.get("type") == "text": print(c.get("text",""))
            elif c.get("type") == "image": print("[image %d bytes b64]" % len(c.get("data","")))
