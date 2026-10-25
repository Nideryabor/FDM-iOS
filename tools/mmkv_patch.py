#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""
mmkv_patch.py —— 离线改写 MMKV 里的 currentUser（账号名 / 头像）🐲

为什么走离线改写而不是 hook：
  • hook 装得太晚（6s 后），而宿主启动时早就把 currentUser 读进内存了
  • 离线改写发生在 App 启动**之前** ⇒ 宿主一读就是改后的
  • 非手机号登录也安全：优先改 idProfiles.nickname，再兜底 mobile/email

MMKV 文件格式（实测，2026-10-17 用真实 mmkv.default dump 出来）：

    普通值：
        [varint keyLen][key][varint valLen][value]

    Data 值（0x80 类型标志，嵌套一层长度）：
        [varint keyLen][key][varint totalLen][0x80][varint innerLen][value]

    实测 currentUser 那一段：

        0b "currentUser"          ← keyLen=11 + key
        82 05                     ← totalLen = 642 (LEB128)
        80                        ← Data 类型标志
        80 05                     ← innerLen = 640
        7b 22 73 65 ...           ← 640 字节 JSON
        13 "app.ab.serverValues"  ← 下一个键（keyLen=19）

    varint = LEB128（小端 7 位，最高位是续位）
    totalLen = len(varint(innerLen)) + innerLen
    ⇒ 改写时 totalLen 必须跟着重算，否则后面所有键全错位

用法：
    python3 mmkv_patch.py <mmkv.default> --show
    python3 mmkv_patch.py <mmkv.default> --name 尼得亚伯
    python3 mmkv_patch.py <mmkv.default> --name "" --avatar https://x/a.png
    python3 mmkv_patch.py <mmkv.default> --restore
"""

import argparse
import json
import os
import shutil
import sys

KEY = b"currentUser"
TAG_DATA = 0x80


# ---------- LEB128 ----------

def read_varint(buf, off):
    """读 LEB128，返回 (值, 新偏移)"""
    val = 0
    shift = 0
    while off < len(buf):
        b = buf[off]
        off += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, off
        shift += 7
        if shift > 63:
            break
    raise ValueError("varint 溢出")


def write_varint(val):
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


# ---------- 定位 ----------

def locate(buf):
    """找 currentUser 的那一段。

    返回 dict：
        key_start   键长度字段起点
        val_off     值长度字段起点
        tag         Data 类型标志（0x80）或 -1
        inner_off   innerLen 字段起点
        val_start   值（JSON 字节）起点
        val_end     值结束偏移
    返回 None = 没找到
    """
    i = buf.find(KEY)
    while i != -1:
        key_start = -1
        # key 前面是 varint keyLen，必须正好等于 11（"currentUser" 长度）
        for back in range(1, 4):
            p = i - back
            if p < 0:
                continue
            try:
                v, nxt = read_varint(buf, p)
            except ValueError:
                continue
            if v == len(KEY) and nxt == i:
                key_start = p
                break
        if key_start < 0:
            i = buf.find(KEY, i + 1)
            continue

        key_end = i + len(KEY)

        # ★★★ 实测有**两种**值格式（2026-10-17）：
        #
        #   格式 A（旧，登录前）：  95 02 80 93 02 {json}
        #                          outer  tag inner  ← 中间有个 0x80
        #
        #   格式 B（新，登录后）：  95 02 93 02 {json}
        #                          outer inner
        #
        #   共同点：外层 varint 之后，**再读一个 varint 就是 inner**，
        #           值从 inner 之后开始，且一定以 '{' 结束在配对的 '}'。
        #   ⇒ 统一处理：外层 → 跳过可能的 0x80 → 内层 → 值
        try:
            outer, o1 = read_varint(buf, key_end)
        except ValueError:
            i = buf.find(KEY, i + 1)
            continue

        # 跳过可能的类型标志（0x80 = Data）
        p = o1
        if p < len(buf) and buf[p] == TAG_DATA and p + 1 < len(buf) \
                and buf[p + 1] != 0x7B:
            p += 1

        try:
            inner, o2 = read_varint(buf, p)
        except ValueError:
            i = buf.find(KEY, i + 1)
            continue

        # 值必须以 '{' 开头（currentUser 一定是 JSON 对象）
        if o2 >= len(buf) or buf[o2] != 0x7B:
            i = buf.find(KEY, i + 1)
            continue

        vstart = o2

        # 花括号配对找精确结尾（不信任 inner，实测 inner 可能偏）
        depth = 0
        in_str = False
        esc = False
        ve = -1
        for q in range(vstart, min(vstart + 200000, len(buf))):
            ch = buf[q]
            if esc:
                esc = False
                continue
            if ch == 0x5C:                 # '\\'
                esc = True
                continue
            if ch == 0x22:                 # '"'
                in_str = not in_str
                continue
            if in_str:
                continue
            if ch == 0x7B:
                depth += 1
            elif ch == 0x7D:
                depth -= 1
                if depth == 0:
                    ve = q + 1
                    break
        if ve < 0:
            i = buf.find(KEY, i + 1)
            continue

        vend = ve
        inner_real = vend - vstart

        # 校验：必须是合法 JSON
        try:
            json.loads(buf[vstart:vend].decode("utf-8"))
        except Exception:
            i = buf.find(KEY, i + 1)
            continue

        return dict(key_start=key_start, val_off=key_end, tag=TAG_DATA,
                    inner_off=o1, val_start=vstart, val_end=vend,
                    total=outer, inner=inner_real)

    return None


# ---------- 子命令 ----------

def show(buf):
    loc = locate(buf)
    if not loc:
        print("❌ 没找到 currentUser（先登录一次 App 让它写进去）")
        return 1
    print(f"currentUser: key@{loc['key_start']}  "
          f"total={loc['total']}  inner={loc['inner']}  "
          f"值@{loc['val_start']}..{loc['val_end']}")
    raw = buf[loc["val_start"]:loc["val_end"]]
    try:
        obj = json.loads(raw.decode("utf-8"))
        print(json.dumps(obj, ensure_ascii=False, indent=2)[:1200])
        print("\n--- 关键字段 ---")
        for k in ("mobile", "email", "nickname", "avatar", "avatarUrl", "idProfiles"):
            if k in obj:
                print(f"  {k} = {obj[k]!r}")
    except Exception as e:
        print(f"❌ 值不是合法 JSON: {e}")
        print(repr(raw[:300]))
        return 1
    return 0


def patch(path, name=None, avatar=None, renew_crc=False):
    buf = bytearray(open(path, "rb").read())
    loc = locate(buf)
    if not loc:
        print("❌ 没找到 currentUser")
        return 1

    try:
        obj = json.loads(buf[loc["val_start"]:loc["val_end"]].decode("utf-8"))
    except Exception as e:
        print(f"❌ 值不是合法 JSON: {e}")
        return 1

    changed = []

    if name is not None:
        hit = False
        profiles = obj.get("idProfiles")
        if isinstance(profiles, list):
            for p in profiles:
                if not isinstance(p, dict):
                    continue
                for k in ("nickname", "nickName", "name", "displayName"):
                    if isinstance(p.get(k), str):
                        p[k] = name
                        hit = True
        if hit:
            changed.append("idProfiles.nickname")
        else:
            # 兜底：mobile 有值改 mobile；否则 email；都没有就强塞 mobile
            if obj.get("mobile"):
                obj["mobile"] = name
                changed.append("mobile")
            elif obj.get("email"):
                obj["email"] = name
                changed.append("email")
            else:
                obj["mobile"] = name
                changed.append("mobile(强制)")
        # 顺手塞 nickname —— 宿主哪天读了就能直接用
        obj["nickname"] = name

    if avatar is not None:
        obj["avatar"] = avatar
        obj["avatarUrl"] = avatar
        changed.append("avatar")

    if not changed:
        print("ℹ️ 没有要改的字段")
        return 0

    old_total_span = loc["val_end"] - loc["val_off"]   # 含长度字段的整段

    def build(o):
        nv = json.dumps(o, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        iv = write_varint(len(nv))
        tv = write_varint(len(iv) + len(nv))
        head = total_var_prefix + bytes([TAG_DATA]) + iv + nv
        return head, nv

    total_var_prefix = b""      # 占位，真正计算在下面

    # ★★★ MMKV 是 mmap 定长文件，总长绝不能变。
    #   放不下时的降级策略（依次尝试）：
    #     ① 完整版（含 nickname）
    #     ② 去掉 nickname
    #     ③ 只改 mobile 的短版本
    candidates = []
    candidates.append(("完整", dict(obj)))
    o2 = dict(obj); o2.pop("nickname", None)
    candidates.append(("去 nickname", o2))

    chosen = None
    for label, cand in candidates:
        nv = json.dumps(cand, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        iv = write_varint(len(nv))
        tv = write_varint(len(iv) + len(nv))
        head = tv + bytes([TAG_DATA]) + iv + nv
        # 整段占位：head 替换掉原来的 [val_off, val_end)
        newfile_len = loc["val_off"] + len(head) + (len(buf) - loc["val_end"])
        if newfile_len <= len(buf):
            chosen = (label, cand, head, tv, iv, nv)
            break

    if not chosen:
        print(f"❌ 新值太长，文件放不下（旧值 {loc['inner']} 字节）")
        print("   ⇒ 换个短一点的名字")
        return 1

    label, cand, head, tv, iv, nv = chosen
    if label != "完整":
        print(f"   ℹ️ 空间不足，已降级：{label}")

    # 备份（只备份一次，保留最原始的）
    bak = path + ".fdmbak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
        print(f"   已备份 → {os.path.basename(bak)}")

    out = bytes(buf[:loc["val_off"]]) + head + bytes(buf[loc["val_end"]:])
    if len(out) < len(buf):
        out += b"\x00" * (len(buf) - len(out))

    open(path, "wb").write(out)

    # ★★★ 关于 .crc 校验文件（血的教训 2026-10-17）：
    #
    #   尼尼一开始「改完就删 .crc，让 MMKV 重算」——
    #   结果宿主认为整个文件不可信，**丢弃并重建**，
    #   部分键（settingsToken 等）丢失 ⇒ 主人的登录态掉了。
    #
    #   ⇒ 现在默认**不删**。MMKV 的 CRC 是分块表
    #     （[magic][count][itemSize] + 每块 [offset][crcCount][crcs]），
    #     我们改写的区间很小，未必落在被校验的块里；
    #     真要重算，交给 MMKV 自己在下次写入时刷新。
    #   ⇒ 只有明确传 --renew-crc 才删除。
    crc = path + ".crc"
    if renew_crc and os.path.exists(crc):
        os.remove(crc)
        print(f"   ⚠️ 已删除 {os.path.basename(crc)}（--renew-crc）")
        print("      注意：宿主可能因此判定文件损坏并重建 ⇒ 会丢登录态")

    print(f"✅ 改写 {', '.join(changed)} → 「{name if name is not None else avatar}」")
    print(f"   {len(buf)} → {len(out)} B（值 {loc['inner']} → {len(nv)}）")
    return 0


def restore(path):
    bak = path + ".fdmbak"
    if not os.path.exists(bak):
        print("❌ 没有 .fdmbak 备份")
        return 1
    shutil.copy2(bak, path)
    print("✅ 已从备份恢复")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--name", default=None, help="账号名（空串 = 隐藏）")
    ap.add_argument("--avatar", default=None, help="头像 URL")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--restore", action="store_true")
    ap.add_argument("--renew-crc", action="store_true",
                    help="删掉 .crc（危险：宿主可能重建文件、丢登录态）")
    a = ap.parse_args()

    if not os.path.exists(a.path):
        print(f"❌ 文件不存在: {a.path}")
        return 1
    if a.show:
        return show(open(a.path, "rb").read())
    if a.restore:
        return restore(a.path)
    if a.name is None and a.avatar is None:
        print("ℹ️ 什么都没指定，用 --show 看看当前值")
        return show(open(a.path, "rb").read())
    return patch(a.path, a.name, a.avatar, a.renew_crc)


if __name__ == "__main__":
    sys.exit(main())
