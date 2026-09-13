#!/usr/bin/env python3
"""
spray_encode.py -- turn a submitted image into a ready-to-ship Dino D-Day spray.

    python spray_encode.py in.png out.vtf [options]
    python spray_encode.py --pack ./serverpack sprays/*.png

Combines the two halves of the pipeline:

  1. Decode the image to a pixel buffer and write a brand-new VTF from those
     pixels. Nothing from the submitted file's container survives, so
     appended or embedded payloads are destroyed rather than inspected.
  2. Tune four unused header padding bytes so the file's checksum is
     byte-palindromic, which cancels the engine's byte-order bug and makes
     the server-written .dat name and the client-read .vtf name identical.

Output is uncompressed BGRA8888. At 256x256 with a full mip chain that lands
around 350 KB, inside the engine's 512 KB custom-file cap, with no block
compressor needed anywhere in the chain.

The decode step is the risky part -- it is the only place attacker-controlled
bytes are parsed. Run it in a sandboxed subprocess with resource limits, not
inside a web worker.

Options:
    --size N        64, 128 or 256 (default 256)
    --pack DIR      also write <crc>.dat into DIR for the server
    --no-tune       skip checksum tuning (produces a file needing both names)
    --quiet         only print output paths
"""

import argparse
import binascii
import os
import shutil
import struct
import sys

from PIL import Image

# ----------------------------------------------------------------- constants

ALLOWED_FORMATS = ["PNG", "JPEG", "BMP", "GIF", "WEBP"]
Image.MAX_IMAGE_PIXELS = 16 * 1024 * 1024   # a spray is small; refuse bombs

MAX_CUSTOM_FILE_SIZE = 524288               # engine cap for a custom file

IMAGE_FORMAT_BGRA8888 = 12
IMAGE_FORMAT_DXT1 = 13

FLAG_CLAMPS = 0x00000004
FLAG_CLAMPT = 0x00000008
FLAG_NOLOD = 0x00000200
FLAG_EIGHTBITALPHA = 0x00002000

HEADER_SIZE = 80        # 7.2 header, padded to a 16-byte boundary
PATCH_OFFSET = 68       # unused padding, after every defined 7.2 field
PATCH_LEN = 4

# ------------------------------------------------------------------- decoding


def load_clean(path, size):
    """Decode to pixels and rebuild from raw bytes only.

    tobytes()/frombytes() drops every scrap of container metadata -- EXIF,
    ICC profiles, ancillary chunks, trailing data.
    """
    with Image.open(path, formats=ALLOWED_FORMATS) as src:
        src.load()
        rgba = src.convert("RGBA")
        img = Image.frombytes("RGBA", rgba.size, rgba.tobytes())

    if img.width != size or img.height != size:
        img = img.resize((size, size), Image.LANCZOS)
    return img


# ------------------------------------------------------------------- encoding


def mip_chain(img):
    levels = [img]
    w, h = img.size
    while w > 1 or h > 1:
        w = max(1, w // 2)
        h = max(1, h // 2)
        levels.append(img.resize((w, h), Image.LANCZOS))
    return levels


def bgra_bytes(img):
    r, g, b, a = img.split()
    return Image.merge("RGBA", (b, g, r, a)).tobytes()


def dxt1_solid_block(rgb):
    """One DXT1 block of a flat colour, for the low-res thumbnail.

    The thumbnail is a tiny preview the engine barely uses, so a flat average
    is legitimate and avoids pulling in a real block compressor.
    """
    r, g, b = rgb
    c = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    return struct.pack("<HHI", c, c, 0)


def build_lowres(img, size=16):
    small = img.resize((size, size), Image.LANCZOS).convert("RGB")
    raw = small.tobytes()
    n = size * size
    avg = tuple(sum(raw[i::3]) // n for i in range(3))
    blocks = (size // 4) * (size // 4)
    return dxt1_solid_block(avg) * blocks, size


def encode(img, lowres_size=16):
    levels = mip_chain(img)
    mip_count = len(levels)
    w, h = img.size

    lowres_data, lo_dim = build_lowres(img, lowres_size)
    flags = FLAG_CLAMPS | FLAG_CLAMPT | FLAG_NOLOD | FLAG_EIGHTBITALPHA

    header = bytearray(HEADER_SIZE)
    struct.pack_into("<4s", header, 0, b"VTF\x00")
    struct.pack_into("<II", header, 4, 7, 2)             # version 7.2
    struct.pack_into("<I", header, 12, HEADER_SIZE)
    struct.pack_into("<HH", header, 16, w, h)
    struct.pack_into("<I", header, 20, flags)
    struct.pack_into("<HH", header, 24, 1, 0)            # frames, first frame
    struct.pack_into("<fff", header, 32, 1.0, 1.0, 1.0)  # reflectivity
    struct.pack_into("<f", header, 48, 1.0)              # bumpmap scale
    struct.pack_into("<I", header, 52, IMAGE_FORMAT_BGRA8888)
    struct.pack_into("<B", header, 56, mip_count)
    struct.pack_into("<i", header, 57, IMAGE_FORMAT_DXT1)
    struct.pack_into("<BB", header, 61, lo_dim, lo_dim)
    struct.pack_into("<H", header, 63, 1)                # depth

    out = bytes(header) + lowres_data
    for level in reversed(levels):      # smallest mip first
        out += bgra_bytes(level)
    return out


# -------------------------------------------------------------- checksum work


def spray_names(data):
    """Return (crc, N, server_name, client_name).

    N is the bitwise-NOT of the CRC-32. The server writes N big-endian, the
    client reads N little-endian -- the engine's byte-order bug.
    """
    crc = binascii.crc32(data) & 0xFFFFFFFF
    n = (~crc) & 0xFFFFFFFF
    return crc, n, "%08x" % n, n.to_bytes(4, "little").hex()


def _crc_with_patch(prefix_crc, patch, suffix):
    return binascii.crc32(suffix, binascii.crc32(patch, prefix_crc)) & 0xFFFFFFFF


def solve_patch(data, offset, target_crc):
    """Four bytes at `offset` that make crc32(file) == target_crc.

    CRC-32 is affine over GF(2), so this is a linear solve rather than a
    search: 33 hashes total regardless of file size.
    """
    prefix_crc = binascii.crc32(data[:offset]) & 0xFFFFFFFF
    suffix = data[offset + PATCH_LEN:]
    base = _crc_with_patch(prefix_crc, b"\x00" * PATCH_LEN, suffix)

    basis = [
        _crc_with_patch(prefix_crc, struct.pack("<I", 1 << i), suffix) ^ base
        for i in range(32)
    ]

    pivots = {}
    for i in range(32):
        cur, tag = basis[i], (1 << i)
        for bit in range(31, -1, -1):
            if not (cur >> bit) & 1:
                continue
            if bit in pivots:
                pv, pt = pivots[bit]
                cur ^= pv
                tag ^= pt
            else:
                pivots[bit] = (cur, tag)
                break

    cur, tag = (target_crc ^ base), 0
    for bit in range(31, -1, -1):
        if (cur >> bit) & 1 and bit in pivots:
            pv, pt = pivots[bit]
            cur ^= pv
            tag ^= pt

    return None if cur != 0 else struct.pack("<I", tag)


def tune(data):
    """Patch header padding so N is byte-palindromic (0xAABBBBAA)."""
    data = bytearray(data)
    _, n, _, _ = spray_names(bytes(data))

    a = (n >> 24) & 0xFF
    b = (n >> 16) & 0xFF
    target_n = (a << 24) | (b << 16) | (b << 8) | a
    target_crc = (~target_n) & 0xFFFFFFFF

    patch = solve_patch(bytes(data), PATCH_OFFSET, target_crc)
    if patch is None:
        raise RuntimeError("checksum solve failed")

    data[PATCH_OFFSET:PATCH_OFFSET + PATCH_LEN] = patch
    return bytes(data)


# ----------------------------------------------------------------------- main


def process(infile, outfile, size, do_tune, packdir, quiet):
    img = load_clean(infile, size)
    data = encode(img)

    if do_tune:
        data = tune(data)

    if len(data) > MAX_CUSTOM_FILE_SIZE:
        raise RuntimeError(
            f"{len(data)} bytes exceeds the {MAX_CUSTOM_FILE_SIZE}-byte cap; "
            "use a smaller --size"
        )

    _, _, server_name, client_name = spray_names(data)

    with open(outfile, "wb") as f:
        f.write(data)

    dat_paths = []
    if packdir:
        os.makedirs(packdir, exist_ok=True)
        wanted = {server_name, client_name}       # one entry if tuned
        for name in sorted(wanted):
            p = os.path.join(packdir, name + ".dat")
            shutil.copyfile(outfile, p)
            dat_paths.append(p)

    if quiet:
        print(outfile)
        for p in dat_paths:
            print(p)
    else:
        print(f"\n{os.path.basename(infile)} -> {outfile}")
        print(f"  {size}x{size} BGRA8888, {len(data)} bytes")
        if server_name == client_name:
            print(f"  checksum tuned: both names are {server_name}")
            print(f"  server file   : {server_name}.dat")
        else:
            print(f"  NOT tuned -- names differ, ship both:")
            print(f"    server writes {server_name}.dat")
            print(f"    client reads  {client_name}.vtf")
        for p in dat_paths:
            print(f"  wrote {p}")

    return True


def main():
    ap = argparse.ArgumentParser(
        description="Encode an image into a Dino D-Day spray VTF.")
    ap.add_argument("inputs", nargs="+", help="input image(s)")
    ap.add_argument("output", nargs="?",
                    help="output .vtf (single input only; "
                         "otherwise named after each input)")
    ap.add_argument("--size", type=int, default=256, choices=[64, 128, 256])
    ap.add_argument("--pack", metavar="DIR",
                    help="also write <crc>.dat here for the server")
    ap.add_argument("--no-tune", action="store_true",
                    help="skip checksum tuning")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    inputs = list(args.inputs)
    output = args.output

    # "in.png out.vtf" -- argparse puts both in inputs when output looks like
    # another input, so pull the trailing .vtf back out.
    if output is None and len(inputs) > 1 and inputs[-1].lower().endswith(".vtf"):
        output = inputs.pop()

    if output and len(inputs) > 1:
        print("cannot name a single output for multiple inputs", file=sys.stderr)
        return 2

    ok = True
    for path in inputs:
        out = output or (os.path.splitext(path)[0] + ".vtf")
        try:
            process(path, out, args.size, not args.no_tune, args.pack, args.quiet)
        except Exception as e:
            print(f"{os.path.basename(path)}: {e}", file=sys.stderr)
            ok = False

    if not args.quiet:
        print()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
