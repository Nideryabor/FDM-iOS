#!/usr/bin/env python3
"""rc.py <shell命令> —— 在设备上执行（参数原样传，不用自己转义引号）"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp2 import call
cmd = sys.argv[1]
d = call("run_command", {"command": cmd}, timeout=60)
res = d.get("result", d)
if d.get("error"): print("❌", d["error"]); raise SystemExit(1)
sc = res.get("structuredContent") or {}
if "output" in sc: print(sc["output"]); raise SystemExit(0)
if "output" in res: print(res["output"]); raise SystemExit(0)
for c in res.get("content", []):
    t = c.get("text","")
    if t:
        try:
            import json as J; o = J.loads(t)
            print(o.get("output") or J.dumps(o, ensure_ascii=False)[:2000])
        except Exception:
            print(t[:4000])
