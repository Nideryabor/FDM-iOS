#!/usr/bin/env python3
"""ObjC selref (ADRP+LDR) 解析器 —— 找出「哪段代码调用了哪个方法」
用法:
  python3 selref.py <macho> --sel "stringForKey:" "mmkvWithID:"     # 找调用点
  python3 selref.py <macho> --near 0xADDR --ctx 1500                # 该点附近的 cstring/selref
"""
import struct, sys
import xref as X

def parse_all(path):
    global IMAGE_BASE
    data, segs, sects = X.parse(path)
    IMAGE_BASE = min(s[1] for s in segs if s[2] > 0)   # 第一个有实体的段 vmaddr
    return data, segs, sects

IMAGE_BASE = None   # Mach-O 首段 vmaddr

def read_ptr(data, segs, va):
    """读 8 字节并解码 dyld chained fixup (rebase / bind)"""
    o = X.v2o(segs, va)
    if o is None or o + 8 > len(data): return None
    v = struct.unpack_from('<Q', data, o)[0]
    if v == 0: return None
    if (v >> 63) & 1:            # dyld_chained_ptr_64_bind -> 导入符号，无 VA
        return ('bind', v & 0xFFFFFF)
    tgt = v & 0xFFFFFFFFF        # 36-bit rebase target
    high8 = (v >> 36) & 0xFF
    return (IMAGE_BASE + tgt) | (high8 << 56)

def build_selrefs(data, segs, sects):
    """__objc_selrefs: 槽位VA -> 选择器字符串"""
    out = {}
    for seg, sn, saddr, ssize, soff in sects:
        if sn != '__objc_selrefs': continue
        for i in range(ssize // 8):
            slot = saddr + i * 8
            ptr = read_ptr(data, segs, slot)
            if ptr:
                s = X.ns(data, segs, ptr)
                if s: out[slot] = s
    return out

def build_ldr(data, sects):
    """ADRP+LDR(64) -> {目标地址: [源代码地址]}"""
    text = [s for s in sects if s[1] == '__text']
    if not text: return {}
    _, _, taddr, tsize, toff = text[0]
    code = data[toff:toff + tsize]
    n = len(code) // 4
    out = {}
    for i in range(n):
        ins = struct.unpack_from('<I', code, i * 4)[0]
        if (ins & 0x9F000000) != 0x90000000: continue
        immlo = (ins >> 29) & 3
        immhi = (ins >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20): imm -= (1 << 21)
        rd = ins & 0x1F
        pc = taddr + i * 4
        page = (pc & ~0xFFF) + (imm << 12)
        for j in (1, 2, 3):
            if i + j >= n: break
            ins2 = struct.unpack_from('<I', code, (i + j) * 4)[0]
            if (ins2 & 0xFFC00000) != 0xF9400000: continue      # LDR imm64
            if ((ins2 >> 5) & 0x1F) != rd: continue
            off = ((ins2 >> 10) & 0xFFF) * 8
            out.setdefault(page + off, []).append(pc)
            break
    return out

def main():
    path = sys.argv[1]
    data, segs, sects = parse_all(path)
    sel = build_selrefs(data, segs, sects)
    ldr = build_ldr(data, sects)
    print(f'# selrefs={len(sel)}  LDR目标={len(ldr)}', file=sys.stderr)

    mode = sys.argv[2]
    if mode == '--sel':
        for name in sys.argv[3:]:
            slots = [k for k, v in sel.items() if v == name]
            if not slots:
                print(f'!! {name}: 无 selref'); continue
            codes = []
            for s in slots: codes += ldr.get(s, [])
            print(f'\n=== {name}  selref槽={[hex(s) for s in slots]}  调用点 {len(codes)} ===')
            for c in sorted(codes)[:12]: print(f'   0x{c:x}')
    elif mode == '--near':
        addr = int(sys.argv[3], 16)
        ctx = int(sys.argv[5]) if len(sys.argv) > 5 else 1500
        print(f'=== 0x{addr:x} ±{ctx} ===')
        sxr = X.build_xrefs(data, sects)
        for tgt, srcs in sorted(X.build_xrefs(data, sects).items()) if False else []:
            pass
        # cstring 引用
        for tgt, srcs in sorted(build_xrefs_cached(data, sects).items()):
            if any(abs(s - addr) <= ctx for s in srcs):
                t = X.ns(data, segs, tgt)
                if t: print(f'  [str 0x{tgt:x}] {t}')
        # selref 引用
        for slot, cs in ldr.items():
            if slot in sel and any(abs(c - addr) <= ctx for c in cs):
                print(f'  [sel 0x{slot:x}] {sel[slot]}')

_cache = {}
def build_xrefs_cached(data, sects):
    k = id(data)
    if k not in _cache:
        _cache[k] = X.build_xrefs(data, sects)
    return _cache[k]

if __name__ == '__main__':
    main()
