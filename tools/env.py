#!/usr/bin/env python3
"""env.py —— Python 侧的 .env 读取器（和 tools/_env.sh 读同一个文件）

用法：
    from env import ENV
    ENV.get("IPHONE_HOST", "127.0.0.1")

设计：
    · 只读，不改环境变量（避免污染）
    · 解析 KEY=VALUE，跳过注释和空行，去掉成对引号
    · 找不到 .env 也不炸 —— 用调用方给的默认值
"""

import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)

_CANDIDATES = [
    os.environ.get("FDM_ENV", ""),
    os.path.join(_ROOT, ".env"),
]


def _parse(path):
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[k] = v
    except OSError:
        pass
    return out


class _Env:
    def __init__(self):
        self.data = {}
        self.source = None
        for cand in _CANDIDATES:
            if cand and os.path.isfile(cand):
                self.data = _parse(cand)
                self.source = cand
                break

    def get(self, key, default=None):
        return self.data.get(key) or default

    def host(self):
        """ios-mcp 的 host（不含端口）"""
        return self.get("IOS_MCP_HOST", self.get("IPHONE_HOST", "127.0.0.1"))

    def port(self):
        return int(self.get("IOS_MCP_PORT", "8090"))


ENV = _Env()

if __name__ == "__main__":
    print("source:", ENV.source or "(未找到 .env)")
    for k, v in ENV.data.items():
        # 口令永远不打印
        if "PW" in k or "PASS" in k.upper():
            print("%-14s = ***（%d 字符）" % (k, len(v)))
        else:
            print("%-14s = %s" % (k, v))
