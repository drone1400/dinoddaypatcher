#!/usr/bin/env python3
"""
crc_tune.py -- force a VTF to a byte-palindromic checksum.

    python crc_tune.py in.vtf out.vtf

Dino D-Day's custom-file system is inconsistent about byte order: the server
writes <N-big-endian>.dat while the client's render path wants
<N-little-endian>.vtf, where N is the bitwise-NOT of the file's CRC-32.

If N has the form 0xAABBBBAA, the two spellings are identical and the
mismatch cancels. This tool tweaks four unused padding bytes inside the VTF
header until that holds.

CRC-32 is affine over GF(2), so the required padding value is solved directly
rather than searched for -- 33 hashes total, regardless of file size. The
bytes live in header padding (inside headerSize, after every defined 7.2
field), so image data is untouched and the file stays structurally valid.
"""

import binascii
import struct
import sys

PATCH_OFFSET = 68   # unused padding in the 7.2 header
PATCH_LEN = 4


def crc_with_patch(prefix_crc, patch, suffix):
    c = binascii.crc32(patch, prefix_crc)
    return binascii.crc32(suffix, c) & 0xFFFFFFFF


def solve_patch(data, offset, target_crc):
    """Find the 4 bytes at `offset` that make crc32(file) == target_crc."""
    prefix_crc = binascii.crc32(data[:offset]) & 0xFFFFFFFF
    suffix = data[offset + PATCH_LEN:]

    base = crc_with_patch(prefix_crc, b"\x00" * PATCH_LEN, suffix)

    # Effect of flipping each individual bit of the patch word.
    basis = []
    for i in range(32):
        p = struct.pack("<I", 1 << i)
        basis.append(crc_with_patch(prefix_crc, p, suffix) ^ base)

    # Gaussian elimination over GF(2): find combination summing to target^base.
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

    if cur != 0:
        return None
    return struct.pack("<I", tag)


def names(data):
    crc = binascii.crc32(data) & 0xFFFFFFFF
    n = (~crc) & 0xFFFFFFFF
    be = "%08x" % n                       # what the server writes
    le = n.to_bytes(4, "little").hex()    # what the client reads
    return crc, n, be, le


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    data = bytearray(open(sys.argv[1], "rb").read())

    if data[:4] != b"VTF\x00":
        print("not a VTF", file=sys.stderr)
        return 1

    hsize, = struct.unpack_from("<I", data, 12)
    if PATCH_OFFSET + PATCH_LEN > hsize:
        print(f"no padding room: header is only {hsize} bytes", file=sys.stderr)
        return 1
    if any(data[PATCH_OFFSET:PATCH_OFFSET + PATCH_LEN]):
        print("warning: padding bytes are not zero; overwriting anyway",
              file=sys.stderr)

    crc, n, be, le = names(bytes(data))
    print(f"before:  crc=%08X  N=%08X" % (crc, n))
    print(f"         server writes {be}.dat")
    print(f"         client reads  {le}.vtf   -> MISMATCH")

    # Keep the outer and inner byte pairs from the original N for a stable,
    # recognisable name: 0xAABBBBAA built from N's own first two bytes.
    a = (n >> 24) & 0xFF
    b = (n >> 16) & 0xFF
    target_n = (a << 24) | (b << 16) | (b << 8) | a
    target_crc = (~target_n) & 0xFFFFFFFF

    patch = solve_patch(bytes(data), PATCH_OFFSET, target_crc)
    if patch is None:
        print("unsolvable (should not happen)", file=sys.stderr)
        return 1

    data[PATCH_OFFSET:PATCH_OFFSET + PATCH_LEN] = patch

    crc, n, be, le = names(bytes(data))
    print(f"after:   crc=%08X  N=%08X" % (crc, n))
    print(f"         server writes {be}.dat")
    print(f"         client reads  {le}.vtf")
    print("         -> MATCH" if be == le else "         -> STILL MISMATCHED")

    open(sys.argv[2], "wb").write(bytes(data))
    print(f"wrote {sys.argv[2]}  ({len(data)} bytes, patched at offset {PATCH_OFFSET})")
    return 0 if be == le else 1


if __name__ == "__main__":
    sys.exit(main())
