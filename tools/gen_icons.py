#!/usr/bin/env python3
"""Generate Linkory brand icons (stdlib only): orange rounded square + two interlocked white rings."""
import math, struct, sys, zlib

def png(path, size, rgba):
    raw = b''.join(b'\x00' + bytes(rgba[y * size * 4:(y + 1) * size * 4]) for y in range(size))
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

def ring(px, py, cx, cy, r, w):
    d = math.hypot(px - cx, py - cy)
    return abs(d - r) <= w / 2

def render(size, mode):
    """mode: 'app' = orange tile with white rings, 'tray' = black template (alpha only)."""
    ss = 3
    out = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    u = (x + (sx + .5) / ss) / size
                    v = (y + (sy + .5) / ss) / size
                    # rounded square
                    rr = 0.22
                    qx, qy = abs(u - .5) - (.5 - rr), abs(v - .5) - (.5 - rr)
                    inside = (max(qx, 0) ** 2 + max(qy, 0) ** 2) ** .5 - rr <= 0
                    r1 = ring(u, v, .40, .5, .17, .075)
                    r2 = ring(u, v, .60, .5, .17, .075)
                    glyph = r1 or r2
                    if mode == 'app':
                        if inside:
                            c = (255, 255, 255, 255) if glyph else (249, 115, 22, 255)
                        else:
                            c = (0, 0, 0, 0)
                    else:
                        c = (0, 0, 0, 255) if glyph else (0, 0, 0, 0)
                    for i in range(4):
                        acc[i] += c[i]
            n = ss * ss
            a = acc[3] / n
            o = (y * size + x) * 4
            if a:
                out[o:o + 3] = bytes(int(acc[i] / (a * n / 255) ) if mode == 'app' else 0 for i in range(3)) if False else bytes(min(255, int(acc[i] / n * 255 / a)) for i in range(3))
            out[o + 3] = int(a)
    return out

if __name__ == '__main__':
    base = sys.argv[1]
    for s in (16, 32, 64, 128, 256, 512, 1024):
        png(f'{base}/app_{s}.png', s, render(s, 'app'))
    png(f'{base}/tray.png', 32, render(32, 'tray'))
    png(f'{base}/tray@2x.png', 64, render(64, 'tray'))
