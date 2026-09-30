#!/usr/bin/env python3
"""Fail closed on missing, corrupt, or nearly uniform PNG evidence."""
import struct, sys, zlib
from pathlib import Path

p = Path(sys.argv[1])
try:
    data = p.read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    pos, packed, width, height, bpp = 8, bytearray(), 0, 0, 0
    while pos < len(data):
        n = struct.unpack_from('>I', data, pos)[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', chunk)
            assert depth == 8 and color in (2, 6) and interlace == 0
            bpp = 3 if color == 2 else 4
        elif kind == b'IDAT':
            packed.extend(chunk)
        pos += n + 12
    assert width >= 200 and height >= 200 and bpp
    raw = zlib.decompress(packed)
    stride = width * bpp
    assert len(raw) == height * (stride + 1)
    prev = bytearray(stride)
    colors = set()
    off = 0
    for y in range(height):
        filt = raw[off]
        row = bytearray(raw[off + 1:off + 1 + stride])
        off += stride + 1
        assert filt <= 4
        for x in range(stride):
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if filt == 1: row[x] = (row[x] + a) & 255
            elif filt == 2: row[x] = (row[x] + b) & 255
            elif filt == 3: row[x] = (row[x] + ((a + b) // 2)) & 255
            elif filt == 4:
                q = a + b - c
                pa, pb, pc = abs(q-a), abs(q-b), abs(q-c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        if y % max(1, height // 80) == 0:
            for x in range(0, width, max(1, width // 80)):
                colors.add(bytes(row[x*bpp:x*bpp+3]))
        prev = row
    assert len(colors) >= 20, f'only {len(colors)} sampled colors'
    print(f'content {width}x{height} colors={len(colors)}')
except (OSError, AssertionError, ValueError, IndexError, struct.error, zlib.error) as exc:
    print(f'invalid screenshot {p}: {exc}', file=sys.stderr)
    sys.exit(1)
