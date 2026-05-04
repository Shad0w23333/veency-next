#!/usr/bin/env python3
"""把指定 dylib 中匹配的 LC_LOAD_DYLIB 改成 LC_LOAD_WEAK_DYLIB。
   用法: weaken-deps.py <dylib> <substring>...
   例:   weaken-deps.py libvncserver.dylib libjpeg libgcrypt"""
import struct, sys, os

LC_LOAD_DYLIB      = 0x0c
LC_REQ_DYLD        = 0x80000000
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD  # 0x80000018
MH_MAGIC_32  = 0xfeedface
MH_MAGIC_64  = 0xfeedfacf
FAT_MAGIC    = 0xcafebabe
FAT_MAGIC_BE = 0xbebafeca

def patch_macho(buf, base_off, size, patterns):
    magic = struct.unpack_from("<I", buf, base_off)[0]
    if magic == MH_MAGIC_32:
        ncmds, sizeofcmds = struct.unpack_from("<II", buf, base_off + 16)
        lc_off = base_off + 28
    elif magic == MH_MAGIC_64:
        ncmds, sizeofcmds = struct.unpack_from("<II", buf, base_off + 16)
        lc_off = base_off + 32
    else:
        print(f"  跳过(非 thin Mach-O,magic=0x{magic:x})")
        return 0
    changed = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, lc_off)
        if cmd == LC_LOAD_DYLIB:
            name_off, = struct.unpack_from("<I", buf, lc_off + 8)
            name_pos = lc_off + name_off
            name_end = buf.find(b"\x00", name_pos)
            name = buf[name_pos:name_end].decode("utf-8", "replace")
            if any(p in name for p in patterns):
                struct.pack_into("<I", buf, lc_off, LC_LOAD_WEAK_DYLIB)
                print(f"  ✅ {name}: LC_LOAD_DYLIB → LC_LOAD_WEAK_DYLIB")
                changed += 1
        lc_off += cmdsize
    return changed

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    path = sys.argv[1]
    patterns = sys.argv[2:]
    with open(path, "rb") as f:
        buf = bytearray(f.read())
    magic = struct.unpack_from(">I", buf, 0)[0]
    total = 0
    if magic in (FAT_MAGIC, FAT_MAGIC_BE):
        # fat header: 4 bytes magic + 4 bytes nfat_arch + N×fat_arch
        nfat_arch = struct.unpack_from(">I", buf, 4)[0]
        print(f"[+] fat binary, nfat_arch={nfat_arch}")
        for i in range(nfat_arch):
            arch_off = 8 + i * 20
            cputype, cpusubtype, off, sz, align = struct.unpack_from(">5I", buf, arch_off)
            print(f"  slice {i}: cputype=0x{cputype:x} off=0x{off:x} size=0x{sz:x}")
            total += patch_macho(buf, off, sz, patterns)
    else:
        total = patch_macho(buf, 0, len(buf), patterns)
    if total == 0:
        print("[!] 没有匹配项,文件未修改")
        return
    out = path + ".weak"
    with open(out, "wb") as f:
        f.write(buf)
    os.chmod(out, 0o755)
    print(f"[+] 写入 {out},共修改 {total} 处")

if __name__ == "__main__":
    main()
