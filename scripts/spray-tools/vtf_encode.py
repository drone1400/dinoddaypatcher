#!/usr/bin/env python3
"""
vtf_encode.py -- turn a submitted image into a clean 7.2 VTF spray.

    python vtf_encode.py in.png out.vtf [--size 256]

No native texture library involved. The image is decoded to a pixel buffer and
a brand-new VTF is written from those pixels, so nothing from the submitted
file's container survives into the output. Emits uncompressed BGRA8888, which
at 256x256 with a full mip chain lands around 350 KB -- inside the engine's
512 KB custom-file cap, with no block compressor needed.

The decode step is the risky part. Run this in a sandboxed subprocess with
resource limits, not inside your web worker.
"""

import argparse
import binascii
import struct
import sys

from PIL import Image

# Only expose the decoders we actually need.
ALLOWED_FORMATS = ["PNG", "JPEG", "BMP", "GIF", "WEBP"]

# A spray is small. Refuse anything that smells like a decompression bomb.
Image.MAX_IMAGE_PIXELS = 16 * 1024 * 1024

IMAGE_FORMAT_BGRA8888 = 12
IMAGE_FORMAT_DXT1 = 13

FLAG_CLAMPS = 0x00000004
FLAG_CLAMPT = 0x00000008
FLAG_NOLOD = 0x00000200
FLAG_EIGHTBITALPHA = 0x00002000

HEADER_SIZE = 80  # 7.2 header, padded to a 16-byte boundary


def load_clean(path, size):
    """Decode to a pixel buffer and rebuild the image from raw pixels only.

    Going through tobytes()/frombytes() drops every scrap of container
    metadata -- EXIF, ICC profiles, ancillary chunks, trailing data.
    """
    with Image.open(path, formats=ALLOWED_FORMATS) as src:
        src.load()
        rgba = src.convert("RGBA")
        raw = rgba.tobytes()
        img = Image.frombytes("RGBA", rgba.size, raw)

    if img.width != size or img.height != size:
        img = img.resize((size, size), Image.LANCZOS)
    return img


def mip_chain(img):
    """Mips from full size down to 1x1, largest first."""
    levels = [img]
    w, h = img.size
    while w > 1 or h > 1:
        w = max(1, w // 2)
        h = max(1, h // 2)
        levels.append(img.resize((w, h), Image.LANCZOS))
    return levels


def bgra_bytes(img):
    b, g, r, a = img.split()[2], img.split()[1], img.split()[0], img.split()[3]
    return Image.merge("RGBA", (b, g, r, a)).tobytes()


def dxt1_solid_block(rgb):
    """A single DXT1 block of one flat colour, for the low-res thumbnail.

    The thumbnail is a tiny preview the engine barely uses; a flat average
    colour is legitimate and avoids pulling in a real block compressor.
    """
    r, g, b = rgb
    c = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    return struct.pack("<HHI", c, c, 0)


def build_lowres(img, size=16):
    small = img.resize((size, size), Image.LANCZOS).convert("RGB")
    avg = tuple(
        sum(small.getdata(i)) // (size * size) for i in range(3)
    )
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
    struct.pack_into("<II", header, 4, 7, 2)          # version 7.2
    struct.pack_into("<I", header, 12, HEADER_SIZE)
    struct.pack_into("<HH", header, 16, w, h)
    struct.pack_into("<I", header, 20, flags)
    struct.pack_into("<HH", header, 24, 1, 0)         # frames, first frame
    struct.pack_into("<fff", header, 32, 1.0, 1.0, 1.0)  # reflectivity
    struct.pack_into("<f", header, 48, 1.0)           # bumpmap scale
    struct.pack_into("<I", header, 52, IMAGE_FORMAT_BGRA8888)
    struct.pack_into("<B", header, 56, mip_count)
    struct.pack_into("<i", header, 57, IMAGE_FORMAT_DXT1)
    struct.pack_into("<BB", header, 61, lo_dim, lo_dim)
    struct.pack_into("<H", header, 63, 1)             # depth

    out = bytes(header) + lowres_data
    # Image data is stored smallest mip first.
    for level in reversed(levels):
        out += bgra_bytes(level)
    return out


def dat_name(data):
    crc = binascii.crc32(data) & 0xFFFFFFFF
    return ((~crc) & 0xFFFFFFFF).to_bytes(4, "little").hex() + ".dat"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--size", type=int, default=256, choices=[64, 128, 256])
    args = ap.parse_args()

    img = load_clean(args.infile, args.size)
    data = encode(img)

    with open(args.outfile, "wb") as f:
        f.write(data)

    print(f"wrote {args.outfile}  {len(data)} bytes  {args.size}x{args.size} BGRA8888")
    print(f"server file: {dat_name(data)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
