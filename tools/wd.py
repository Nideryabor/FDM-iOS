#!/usr/bin/env python3
"""iPhone WebDAV 客户端（Filza 自带服务端）

用法：
  wd.py ls   <远程路径>             列出目录
  wd.py get  <远程路径> [本地路径]   下载（默认存 /workspace/ios-port/iphone/）
  wd.py put  <本地路径> <远程目录>   上传
  wd.py cat  <远程路径>             直接打印内容
  wd.py rm   <远程路径>             删除
  wd.py find <远程目录> <关键词>     递归查找文件名

环境变量：WD_HOST（默认从 .env 的 IPHONE_HOST 推导 :8080）
"""

import os, sys, urllib.request, urllib.parse, xml.etree.ElementTree as ET

import sys as _sys
_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from env import ENV
# ★ 默认值也是从 .env 的 IPHONE_HOST 拼出来的，不再写死
_H = ENV.get("WD_HOST") or (ENV.get("IPHONE_HOST", "127.0.0.1") + ":8080")
HOST = os.environ.get("WD_HOST", _H)
BASE = f"http://{HOST}"
LOCAL_DROP = "/workspace/ios-port/iphone"

NS = {"D": "DAV:"}


def req(method, path, data=None, headers=None, raw=False, timeout=30):
    url = BASE + urllib.parse.quote(path)
    r = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        body = resp.read()
        return resp.status, (body if raw else body.decode("utf-8", "replace"))


def ls(path):
    st, body = req("PROPFIND", path, headers={"Depth": "1"})
    root = ET.fromstring(body)
    rows = []
    for r in root.findall("D:response", NS):
        href = r.find("D:href", NS).text
        prop = r.find("D:propstat/D:prop", NS)
        if prop is None:
            continue
        isdir = prop.find("D:resourcetype/D:collection", NS) is not None
        size = prop.find("D:getcontentlength", NS)
        name = urllib.parse.unquote(href)
        rows.append((isdir, int(size.text) if size is not None and size.text else 0, name))
    return rows


def walk(path, depth=0, maxdepth=6, out=None):
    if out is None:
        out = []
    if depth > maxdepth:
        return out
    try:
        for isdir, size, name in ls(path):
            if name.rstrip("/") == path.rstrip("/"):
                continue
            out.append((isdir, size, name))
            if isdir:
                walk(name, depth + 1, maxdepth, out)
    except Exception as e:
        out.append((False, 0, f"(错误 {e})"))
    return out


def get(path, local=None):
    st, body = req("GET", path, raw=True)
    if local is None:
        os.makedirs(LOCAL_DROP, exist_ok=True)
        local = os.path.join(LOCAL_DROP, os.path.basename(path.rstrip("/")))
    with open(local, "wb") as f:
        f.write(body)
    return local, len(body)


def put(local, remote_dir):
    """PUT 上传，带重试 + MOVE 兜底（Filza 对 App 容器偶发 403）"""
    data = open(local, "rb").read()
    base = os.path.basename(local)
    target = remote_dir.rstrip("/") + "/" + base

    for attempt in range(1, 4):
        try:
            st, _ = req("PUT", target, data=data,
                        headers={"Content-Type": "application/octet-stream"}, raw=True)
            if st in (200, 201, 204):
                return st, target, len(data)
        except Exception as e:
            err = e

        # 兜底：先写公共目录，再 MOVE 过去
        try:
            tmp = "/var/mobile/Documents/_wd_tmp_" + base
            st2, _ = req("PUT", tmp, data=data,
                         headers={"Content-Type": "application/octet-stream"}, raw=True)
            if st2 in (200, 201, 204):
                st3, _ = req("MOVE", tmp, headers={"Destination": BASE + target}, raw=True)
                if st3 in (200, 201, 204):
                    return st3, target, len(data)
                req("DELETE", tmp, raw=True)
        except Exception as e2:
            err = e2

        import time as _t
        _t.sleep(1.5)

    return 403, target, 0


def rm(path):
    st, _ = req("DELETE", path, raw=True)
    return st


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    cmd = sys.argv[1]
    arg = sys.argv[2]

    if cmd == "ls":
        for isdir, size, name in ls(arg):
            print(f"  {'DIR ' if isdir else '    '} {size:>10}  {urllib.parse.unquote(name)}")

    elif cmd == "cat":
        st, body = req("GET", arg)
        print(body)

    elif cmd == "get":
        local = sys.argv[3] if len(sys.argv) > 3 else None
        p, n = get(arg, local)
        print(f"✅ {n} B → {p}")

    elif cmd == "put":
        if len(sys.argv) < 4:
            print("用法: wd.py put <本地文件> <远程目录>"); return
        st, t, n = put(arg, sys.argv[3])
        print(f"✅ PUT {st}  {n} B → {t}")

    elif cmd == "rm":
        print(f"DELETE → {rm(arg)}")

    elif cmd == "find":
        kw = sys.argv[3].lower()
        root = arg
        for isdir, size, name in walk(root):
            if kw in os.path.basename(name).lower():
                print(f"  {'DIR ' if isdir else '    '} {size:>10}  {urllib.parse.unquote(name)}")

    else:
        print(__doc__)


if __name__ == "__main__":
    main()
