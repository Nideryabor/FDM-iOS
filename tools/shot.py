#!/usr/bin/env python3
"""shot.py <out.png> —— 截图到本地文件（PNG/JPEG 自动识别）"""
import json, sys, base64, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp2 import call

d = call("screenshot", {}, timeout=60)
res = d.get("result", d)
if d.get("error"): print("❌", d["error"]); raise SystemExit(1)
for c in res.get("content", []):
    if c.get("type") == "image":
        b = base64.b64decode(c.get("data",""))
        out = sys.argv[1]
        open(out, "wb").write(b)
        print("✅", out, len(b), "bytes")
        raise SystemExit(0)
    if c.get("type") == "text":
        print("ℹ️", c.get("text","")[:200])
print("⚠️ 无图片:", json.dumps(res, ensure_ascii=False)[:300])
