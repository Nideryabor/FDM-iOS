#!/usr/bin/env python3
"""Mach-O 感知的 strings / 关键词扫描器（无 otool/nm 时的替代品）
用法:
  python3 mstr.py <文件>                 # 打印架构 + 段表
  python3 mstr.py <文件> --grep 关键词 [关键词2 ...]
  python3 mstr.py <文件> --dump 输出.txt  # 全量可打印字符串落盘
"""
import sys, struct, re

MH_MAGIC    = 0xfeedface
MH_CIGAM    = 0xcefaedfe
MH_MAGIC_64 = 0xfeedfacf
MH_CIGAM_64 = 0xcffaedfe
FAT_MAGIC   = 0xcafebabe
FAT_CIGAM   = 0xbebafeca
FAT_MAGIC_64= 0xcafebabf

CPU = {12: 'ARM', 16777228: 'arm64', 7: 'x86', 16777223: 'x86_64'}
LC_SEGMENT    = 0x1
LC_SEGMENT_64 = 0x19


def rd(f, off, n):
    f.seek(off)
    return f.read(n)


def parse_slices(data):
    """返回 [(cpu, name, fileoff, filesize)]"""
    if len(data) < 8:
        return []
    magic = struct.unpack('>I', data[:4])[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack('>I', data[4:8])[0]
        esz = 32 if magic == FAT_MAGIC_64 else 20
        out = []
        for i in range(n):
            e = data[8 + i * esz: 8 + (i + 1) * esz]
            cpu = struct.unpack('>I', e[0:4])[0]
            off = struct.unpack('>I', e[8:12])[0]
            size = struct.unpack('>I', e[12:16])[0]
            out.append((cpu, CPU.get(cpu, hex(cpu)), off, size))
        return out
    m = struct.unpack('<I', data[:4])[0]
    if m in (MH_MAGIC_64, MH_MAGIC):
        cpu = struct.unpack('<I', data[4:8])[0]
        return [(cpu, CPU.get(cpu, hex(cpu)), 0, len(data))]
    return []


def segments(data, base):
    """解析 Mach-O header 后的 LC_SEGMENT(_64)，返回 [(segname, fileoff, filesize)]"""
    magic = struct.unpack('<I', data[base:base + 4])[0]
    is64 = magic == MH_MAGIC_64
    hdr = 32 if is64 else 28
    ncmds = struct.unpack('<I', data[base + 16:base + 20])[0]
    p = base + hdr
    segs = []
    for _ in range(ncmds):
        if p + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack('<II', data[p:p + 8])
        if cmd == (LC_SEGMENT_64 if is64 else LC_SEGMENT):
            name = data[p + 8:p + 24].split(b'\0')[0].decode('latin1')
            if is64:
                fo = struct.unpack('<Q', data[p + 40:p + 48])[0]
                fs = struct.unpack('<Q', data[p + 48:p + 56])[0]
            else:
                fo = struct.unpack('<I', data[p + 32:p + 36])[0]
                fs = struct.unpack('<I', data[p + 36:p + 40])[0]
            segs.append((name, fo, fs))
        if cmdsize <= 0:
            break
        p += cmdsize
    return segs


STR_RE = re.compile(rb'[\x20-\x7e]{4,}')


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    path = sys.argv[1]
    data = open(path, 'rb').read()
    sl = parse_slices(data)
    print(f'# 文件: {path}  ({len(data)} 字节)')
    print(f'# 架构切片: {sl if sl else "非 Mach-O / 未知"}')

    mode = sys.argv[2] if len(sys.argv) > 2 else None

    # 收集所有切片的所有段
    regions = []
    for cpu, nm, off, size in sl:
        segs = segments(data, off)
        if mode is None:
            print(f'\n## 切片 {nm} @ 0x{off:x}  段:')
            for sname, sfo, sfs in segs:
                print(f'   {sname:12s} fileoff=0x{sfo:x} size=0x{sfs:x}')
        for sname, sfo, sfs in segs:
            if sfs:
                regions.append((nm, sname, sfo, sfs))

    if mode == '--grep':
        kws = [k.encode() for k in sys.argv[3:]]
        seen = set()
        for nm, sname, sfo, sfs in regions:
            chunk = data[sfo:sfo + sfs]
            for m in STR_RE.finditer(chunk):
                s = m.group()
                for kw in kws:
                    if kw in s:
                        key = s
                        if key in seen:
                            break
                        seen.add(key)
                        print(f'[{nm}/{sname}] {s.decode("latin1", "replace")}')
                        break
        print(f'\n# 命中 {len(seen)} 条（去重后）')
    elif mode == '--dump':
        out = sys.argv[3]
        with open(out, 'wb') as w:
            for nm, sname, sfo, sfs in regions:
                chunk = data[sfo:sfo + sfs]
                for m in STR_RE.finditer(chunk):
                    w.write(m.group() + b'\n')
        print(f'# 已写入 {out}')


if __name__ == '__main__':
    main()
