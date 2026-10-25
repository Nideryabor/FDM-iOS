#!/usr/bin/env python3
"""arm64 ADRP+ADD 字符串交叉引用扫描器（无 IDA 时的替代品）
用法:
  python3 xref.py <macho> --find "字符串1" "字符串2" ...
  python3 xref.py <macho> --at 0xCODE_ADDR [--ctx 4096]   # 看该地址附近引用了哪些字符串
"""
import struct, sys, re

LC_SEGMENT_64 = 0x19

def parse(path):
    data = open(path, 'rb').read()
    assert struct.unpack('<I', data[:4])[0] == 0xfeedfacf, '不是 arm64 Mach-O'
    ncmds = struct.unpack('<I', data[16:20])[0]
    p = 32
    segs, sects = [], []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', data[p:p+8])
        if cmd == LC_SEGMENT_64:
            name = data[p+8:p+24].split(b'\0')[0].decode()
            vmaddr, vmsize = struct.unpack('<QQ', data[p+24:p+40])
            fileoff, filesize = struct.unpack('<QQ', data[p+40:p+56])
            nsects = struct.unpack('<I', data[p+64:p+68])[0]
            segs.append((name, vmaddr, vmsize, fileoff, filesize))
            sp = p + 72
            for _s in range(nsects):
                sn = data[sp:sp+16].split(b'\0')[0].decode()
                saddr, ssize = struct.unpack('<QQ', data[sp+32:sp+48])
                soff = struct.unpack('<I', data[sp+48:sp+52])[0]
                sects.append((name, sn, saddr, ssize, soff))
                sp += 80
        if cmdsize <= 0: break
        p += cmdsize
    return data, segs, sects

def v2o(segs, va):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + vmsize:
            return fileoff + (va - vmaddr)
    return None

def o2v(segs, off):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if fileoff <= off < fileoff + filesize:
            return vmaddr + (off - fileoff)
    return None

def build_xrefs(data, sects):
    text = [s for s in sects if s[1] == '__text']
    if not text:
        return {}
    _, _, taddr, tsize, toff = text[0]
    code = data[toff:toff+tsize]
    xr = {}
    n = len(code) // 4
    for i in range(n):
        ins = struct.unpack_from('<I', code, i*4)[0]
        if (ins & 0x9F000000) != 0x90000000:
            continue
        immlo = (ins >> 29) & 3
        immhi = (ins >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20): imm -= (1 << 21)
        rd = ins & 0x1F
        pc = taddr + i*4
        page = (pc & ~0xFFF) + (imm << 12)
        for j in (1, 2, 3, 4):
            if i + j >= n: break
            ins2 = struct.unpack_from('<I', code, (i+j)*4)[0]
            if (ins2 & 0x7F000000) != 0x11000000 or not (ins2 >> 31) & 1:
                continue
            if ((ins2 >> 5) & 0x1F) != rd: continue
            imm12 = (ins2 >> 10) & 0xFFF
            sh = (ins2 >> 22) & 1
            xr.setdefault(page + (imm12 << (12 if sh else 0)), []).append(pc)
            break
    return xr

def find_str_addr(data, segs, sects, s):
    pat = s.encode() + b'\0'
    cstr = [x for x in sects if x[1] == '__cstring']
    start = 0
    while True:
        i = data.find(pat, start)
        if i < 0: return None
        va = o2v(segs, i)
        if va is not None:
            if cstr and not any(x[2] <= va < x[2]+x[3] for x in cstr):
                start = i + 1; continue
            return va
        start = i + 1

def ns(data, segs, va):
    o = v2o(segs, va)
    if o is None: return None
    e = data.find(b'\0', o)
    s = data[o:e]
    if not s or len(s) > 400: return None
    try: return s.decode('utf-8')
    except: return None

def main():
    path = sys.argv[1]
    data, segs, sects = parse(path)
    xr = build_xrefs(data, sects)
    print(f'# 收集到 {len(xr)} 个唯一引用目标', file=sys.stderr)

    if sys.argv[2] == '--find':
        for s in sys.argv[3:]:
            va = find_str_addr(data, segs, sects, s)
            if va is None:
                print(f'!! {s}: 找不到字符串'); continue
            hits = xr.get(va, [])
            print(f'\n=== {s}  @ 0x{va:x}  引用 {len(hits)} 处 ===')
            for h in hits[:10]:
                print(f'   代码 0x{h:x}')
    elif sys.argv[2] == '--at':
        addr = int(sys.argv[3], 16)
        ctx = int(sys.argv[5]) if len(sys.argv) > 5 else 8192
        print(f'=== 0x{addr:x} ±{ctx} 范围内引用的字符串 ===')
        for tgt, srcs in sorted(xr.items()):
            if any(abs(sa - addr) <= ctx for sa in srcs):
                t = ns(data, segs, tgt)
                if t:
                    print(f'  [0x{tgt:x}] {t}')

if __name__ == '__main__':
    main()
