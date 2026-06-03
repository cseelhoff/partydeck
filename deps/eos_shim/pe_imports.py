#!/usr/bin/env python3
"""Dump the PE import table of a Windows binary (exe/dll).

Lists every imported DLL and the function names bound from each. Used to seed
the shim .def files: every symbol the game imports must be re-exported by a
proxy DLL or the game won't load.

Usage:
    pe_imports.py <file.exe|file.dll> [--dll steam_api64.dll] [--names-only]

  --dll NAME    only print imports from the named DLL (repeatable)
  --names-only  print just the function names (one per line), no headers --
                suitable for piping into a .def generator.
"""
import struct, sys


def read_imports(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        raise SystemExit(f"{path}: not a PE (no MZ header)")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit(f"{path}: bad PE signature")
    coff = pe + 4
    nsec, = struct.unpack_from("<H", data, coff + 2)
    optsz, = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    magic, = struct.unpack_from("<H", data, opt)
    pe32plus = magic == 0x20B
    ddoff = opt + (112 if pe32plus else 96)   # DataDirectory[]; [1] = import
    imp_rva, imp_sz = struct.unpack_from("<II", data, ddoff + 8)   # [1] = import

    secs = []
    sh = opt + optsz
    for i in range(nsec):
        o = sh + i * 40
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, o + 8)
        secs.append((vaddr, vsize, rawptr, rawsize))

    def rva2off(rva):
        for vaddr, vsize, rawptr, rawsize in secs:
            # use the larger of virtual/raw size; some sections zero-pad
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                return rawptr + (rva - vaddr)
        return None

    def cstr(off):
        if off is None or off >= len(data):
            return None
        e = data.index(b"\0", off)
        return data[off:e].decode("latin1")

    ptr_sz = 8 if pe32plus else 4
    ord_flag = (1 << 63) if pe32plus else (1 << 31)
    out = {}
    o = rva2off(imp_rva)
    if o is None:
        return out
    while True:
        oft, tstamp, fwd, nameRva, fthunk = struct.unpack_from("<IIIII", data, o)
        if nameRva == 0:
            break
        dll = cstr(rva2off(nameRva))
        thunk_rva = oft if oft else fthunk      # prefer OriginalFirstThunk (ILT)
        to = rva2off(thunk_rva)
        names = []
        if to is not None:
            while True:
                if pe32plus:
                    val, = struct.unpack_from("<Q", data, to)
                else:
                    val, = struct.unpack_from("<I", data, to)
                if val == 0:
                    break
                if val & ord_flag:
                    names.append(f"#ordinal{val & 0xffff}")
                else:
                    fo = rva2off(val & 0x7FFFFFFF)
                    nm = cstr(fo + 2) if fo is not None else None     # skip Hint(2B)
                    names.append(nm if nm else f"<bad@{val:#x}>")
                to += ptr_sz
        out[dll or f"<unnamed@{nameRva:#x}>"] = names
        o += 20
    return out


def main(argv):
    if not argv:
        raise SystemExit(__doc__)
    only = []
    names_only = False
    path = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dll":
            i += 1; only.append(argv[i].lower())
        elif a == "--names-only":
            names_only = True
        else:
            path = a
        i += 1
    if not path:
        raise SystemExit(__doc__)
    imps = read_imports(path)
    if names_only:
        for dll, names in imps.items():
            if only and dll.lower() not in only:
                continue
            for n in sorted(names):
                print(n)
        return
    print(f"=== DLLs imported by {path} ===")
    for dll, names in sorted(imps.items()):
        print(f"  {dll}: {len(names)} funcs")
    print()
    for dll, names in sorted(imps.items()):
        if only and dll.lower() not in only:
            continue
        print(f"=== {dll} ({len(names)}) ===")
        for n in sorted(names):
            print("  ", n)


if __name__ == "__main__":
    main(sys.argv[1:])
