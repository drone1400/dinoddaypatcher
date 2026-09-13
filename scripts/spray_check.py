#!/usr/bin/env python3
"""
spraycheck.py -- structural validation + .dat naming for Source engine sprays.

Usage:
    python spraycheck.py <file.vtf> [file2.vtf ...]
    python spraycheck.py --pack <outdir> <file.vtf> ...   # also emit <crc>.dat

Exit code 0 if every file passes, 1 otherwise.

This is a FIRST-PASS FILTER, not a security boundary. A file that passes here
is still attacker-controlled data. The safe workflow is to decode submissions
to PNG and re-encode them to VTF yourself; use this to reject the obviously
broken before you spend time on them, and to sanity-check your own output.
"""

import sys
import os
import struct
import binascii
import shutil

MAX_CUSTOM_FILE_SIZE = 524288  # engine cap for a custom file
MAX_DIM = 512                  # practical spray ceiling

# VTFImageFormat enum -> (name, bits per pixel, dxt block bytes or None)
FORMATS = {
    0:  ("RGBA8888", 32, None),
    1:  ("ABGR8888", 32, None),
    2:  ("RGB888", 24, None),
    3:  ("BGR888", 24, None),
    4:  ("RGB565", 16, None),
    5:  ("I8", 8, None),
    6:  ("IA88", 16, None),
    7:  ("P8", 8, None),
    8:  ("A8", 8, None),
    9:  ("RGB888_BLUESCREEN", 24, None),
    10: ("BGR888_BLUESCREEN", 24, None),
    11: ("ARGB8888", 32, None),
    12: ("BGRA8888", 32, None),
    13: ("DXT1", 4, 8),
    14: ("DXT3", 8, 16),
    15: ("DXT5", 8, 16),
    16: ("BGRX8888", 32, None),
    17: ("BGR565", 16, None),
    18: ("BGRX5551", 16, None),
    19: ("BGRA4444", 16, None),
    20: ("DXT1_ONEBITALPHA", 4, 8),
    21: ("BGRA5551", 16, None),
    22: ("UV88", 16, None),
    23: ("UVWQ8888", 32, None),
    24: ("RGBA16161616F", 64, None),
    25: ("RGBA16161616", 64, None),
    26: ("UVLX8888", 32, None),
}

# Formats a spray should plausibly use. Anything else is suspicious even if legal.
SANE_SPRAY_FORMATS = {13, 14, 15, 20, 0, 11, 12, 16}


def mip_size(w, h, fmt):
    """Bytes for one mip level in the given format."""
    name, bpp, block = FORMATS[fmt]
    if block is not None:
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * block
    return (w * h * bpp + 7) // 8


def is_pow2(n):
    return n > 0 and (n & (n - 1)) == 0


def dat_name(data):
    """Engine filename: bitwise-NOT of CRC32, written little-endian, lowercase hex."""
    crc = binascii.crc32(data) & 0xFFFFFFFF
    return ((~crc) & 0xFFFFFFFF).to_bytes(4, "little").hex() + ".dat"


def check(path):
    errors = []
    warnings = []
    info = {}

    try:
        data = open(path, "rb").read()
    except OSError as e:
        return [f"cannot read: {e}"], [], {}

    n = len(data)
    info["size"] = n

    if n > MAX_CUSTOM_FILE_SIZE:
        errors.append(
            f"file is {n} bytes, over the {MAX_CUSTOM_FILE_SIZE}-byte custom file cap "
            "(it will import but silently fail to transfer)"
        )
    if n < 64:
        return ["file is too small to contain a VTF header"], [], info

    if data[:4] != b"VTF\x00":
        return ["missing VTF signature"], [], info

    vmaj, vmin, hsize = struct.unpack_from("<III", data, 4)
    info["version"] = f"{vmaj}.{vmin}"
    info["header_size"] = hsize

    if vmaj != 7:
        errors.append(f"unexpected major version {vmaj}")
    if vmin > 2:
        errors.append(
            f"version 7.{vmin} is newer than the 7.2 this engine branch reads; "
            "re-export as 7.2"
        )
    if hsize < 63 or hsize > n:
        return [f"header_size {hsize} is out of range for a {n}-byte file"], warnings, info

    w, h, flags, frames, first_frame = struct.unpack_from("<HHIHH", data, 16)
    fmt, = struct.unpack_from("<I", data, 52)
    mip_count, = struct.unpack_from("<B", data, 56)
    lo_fmt, = struct.unpack_from("<i", data, 57)
    lo_w, lo_h = struct.unpack_from("<BB", data, 61)

    info.update(dict(width=w, height=h, flags=flags, frames=frames,
                     mips=mip_count, low_res=f"{lo_w}x{lo_h}"))
    info["format"] = FORMATS.get(fmt, (f"UNKNOWN({fmt})", 0, None))[0]

    if fmt not in FORMATS:
        return [f"unknown image format id {fmt}"], warnings, info
    if fmt not in SANE_SPRAY_FORMATS:
        warnings.append(f"unusual format for a spray: {FORMATS[fmt][0]}")
    if not is_pow2(w) or not is_pow2(h):
        errors.append(f"dimensions {w}x{h} are not powers of two")
    if w > MAX_DIM or h > MAX_DIM:
        errors.append(f"dimensions {w}x{h} exceed {MAX_DIM}x{MAX_DIM}")
    if frames != 1:
        warnings.append(f"{frames} frames; animated sprays behave inconsistently")

    # Expected payload size. This is the check that matters most: a declared
    # mip chain larger than the actual file is the classic malformed-image case.
    expected = hsize

    if lo_fmt != -1 and lo_w and lo_h:
        if lo_fmt not in FORMATS:
            errors.append(f"unknown low-res format id {lo_fmt}")
        else:
            expected += mip_size(lo_w, lo_h, lo_fmt)

    levels = max(1, mip_count)
    for i in range(levels):
        mw = max(1, w >> (levels - 1 - i))
        mh = max(1, h >> (levels - 1 - i))
        expected += mip_size(mw, mh, fmt) * frames

    info["expected_size"] = expected

    if expected > n:
        errors.append(
            f"header declares {expected} bytes of image data but the file is {n} "
            "-- truncated or deliberately malformed"
        )
    elif expected < n:
        extra = n - expected
        errors.append(
            f"{extra} trailing bytes after the declared image data "
            "-- appended payload or a non-standard exporter"
        )

    info["dat"] = dat_name(data)
    return errors, warnings, info


def main():
    argv = sys.argv[1:]
    packdir = None
    if argv and argv[0] == "--pack":
        if len(argv) < 2:
            print("--pack needs an output directory", file=sys.stderr)
            return 2
        packdir = argv[1]
        argv = argv[2:]
        os.makedirs(packdir, exist_ok=True)

    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    all_ok = True
    for path in argv:
        errors, warnings, info = check(path)
        status = "FAIL" if errors else ("WARN" if warnings else "OK")
        if errors:
            all_ok = False

        print(f"\n=== {os.path.basename(path)} -- {status}")
        if info:
            bits = []
            for k in ("version", "width", "height", "format", "mips", "frames",
                      "low_res", "size", "expected_size", "dat"):
                if k in info:
                    bits.append(f"{k}={info[k]}")
            print("    " + "  ".join(bits))
        for e in errors:
            print(f"    [error] {e}")
        for wmsg in warnings:
            print(f"    [warn ] {wmsg}")

        if packdir and not errors:
            dest = os.path.join(packdir, info["dat"])
            shutil.copyfile(path, dest)
            print(f"    -> wrote {dest}")

    print()
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
