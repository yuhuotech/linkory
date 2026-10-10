#!/usr/bin/env python3
"""从 assets/brand/linkory-logo.svg 生成全部平台图标（仅 Python 标准库）。

运行：python3 tools/gen_icons.py
传入目录时，仅输出通用 app/tray 图标，兼容旧用法。
"""
import json
import math
from pathlib import Path
import struct
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'linkory-app'
SVG = ET.parse(ROOT / 'assets/brand/linkory-logo.svg').getroot()
NS = {'s': 'http://www.w3.org/2000/svg'}
RECT = SVG.find('s:rect', NS)
WIDTH = float(RECT.get('width'))
RADIUS = float(RECT.get('rx')) / WIDTH
# Read material colors from the brand SVG, keeping it the source of truth.
COLORS = tuple(tuple(bytes.fromhex(stop.get('stop-color')[1:]))
               for stop in SVG.findall("s:defs/s:linearGradient[@id='orange']/s:stop", NS))
GROUP = SVG.find('s:g', NS)
STROKE = float(GROUP.get('stroke-width')) / WIDTH
RINGS = [(float(c.get('cx')) / WIDTH, float(c.get('cy')) / WIDTH,
          float(c.get('r')) / WIDTH) for c in GROUP]


def png(path, size, rgba, opaque=False):
    channels = 3 if opaque else 4
    data = bytes(rgba) if not opaque else bytes(v for i, v in enumerate(rgba) if i % 4 != 3)
    raw = b''.join(b'\0' + data[y*size*channels:(y+1)*size*channels] for y in range(size))
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
    payload = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2 if opaque else 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


CACHE = {}
def render(size, mode='app'):
    if (size, mode) in CACHE:
        return CACHE[size, mode]
    out = bytearray(size * size * 4)
    ss = 3
    for y in range(size):
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    u, v = (x+(sx+.5)/ss)/size, (y+(sy+.5)/ss)/size
                    # Maskable/Android foreground keep all glyphs inside the safe zone.
                    scale = .8 if mode == 'maskable' else .66 if mode == 'foreground' else 1/1.08 if mode == 'tray' else 1
                    gu, gv = (u-.5)/scale+.5, (v-.5)/scale+.5
                    distance = min(abs(math.hypot(gu-cx, gv-cy)-r)-STROKE/2 for cx, cy, r in RINGS)
                    glyph = distance <= 0
                    qx, qy = abs(u-.5)-(.5-RADIUS), abs(v-.5)-(.5-RADIUS)
                    inside = math.hypot(max(qx, 0), max(qy, 0)) <= RADIUS
                    if mode in ('tray', 'foreground'):
                        c = ((0, 0, 0, 255) if mode == 'tray' else (255, 255, 255, 255)) if glyph else (0, 0, 0, 0)
                    elif inside or mode in ('opaque', 'maskable'):
                        if glyph:
                            t = max(0, min(1, (gv-.27)/.46))
                            c = (255, round(255-10*t), round(255-20*t), 255)
                        else:
                            t = (u+v)/2
                            a, b = COLORS[:2] if t <= .48 else COLORS[1:]
                            t = t/.48 if t <= .48 else (t-.48)/.52
                            color = [a[i]+(b[i]-a[i])*t for i in range(3)]
                            # Soft, short shadow under the complete union of both rings.
                            d = min(abs(math.hypot(gu-cx, gv-.005-cy)-r)-STROKE/2 for cx, cy, r in RINGS)
                            shadow = .18 * math.exp(-max(0, d)**2/(2*.005**2))
                            color = [color[i]*(1-shadow)+(139, 48, 8)[i]*shadow for i in range(3)]
                            # Subpixel edge lighting; no hard outline at small sizes.
                            edge = RADIUS-math.hypot(max(qx, 0), max(qy, 0))-min(max(qx, qy), 0)
                            rim = math.exp(-max(0, edge)/.0015)
                            light = .24*(1-v)*rim
                            shade = .12*v*rim
                            c = (*[round(k*(1-light-shade)+255*light+(139, 48, 8)[i]*shade) for i, k in enumerate(color)], 255)
                    else:
                        c = (0, 0, 0, 0)
                    for i in range(4):
                        acc[i] += c[i]
            offset = (y*size+x)*4
            if acc[3]:
                out[offset:offset+3] = bytes(min(255, round(acc[i]*255/acc[3])) for i in range(3))
            out[offset+3] = round(acc[3]/(ss*ss))
    CACHE[size, mode] = out
    return out


def write(path, size, mode='app'):
    png(path, size, render(size, mode), opaque=mode in ('opaque', 'maskable'))


def ico(path):
    images = []
    with tempfile.TemporaryDirectory() as tmp:
        for size in (16, 24, 32, 48, 64, 128, 256):
            file = Path(tmp) / f'{size}.png'
            write(file, size)
            images.append((size, file.read_bytes()))
    offset = 6 + 16*len(images)
    header = struct.pack('<HHH', 0, 1, len(images))
    entries = b''
    for size, data in images:
        entries += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    Path(path).write_bytes(header + entries + b''.join(data for _, data in images))


def main():
    base = Path(sys.argv[1]) if len(sys.argv) > 1 else APP / 'assets/icons'
    base.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        write(base / f'app_{size}.png', size)
    # macOS template at 18pt with a 2x variant (DesktopShell selects @2x explicitly).
    write(base / 'tray.png', 18, 'tray')
    write(base / 'tray@2x.png', 36, 'tray')
    ico(base / 'app.ico')
    if len(sys.argv) > 1:
        return
    for size in (32, 64, 128, 256, 512, 1024):
        write(ROOT / f'assets/brand/linkory-logo-{size}.png', size)
    for platform in ('macos', 'ios'):
        directory = APP / platform / 'Runner/Assets.xcassets/AppIcon.appiconset'
        for item in json.loads((directory / 'Contents.json').read_text())['images']:
            size = round(float(item['size'].split('x')[0]) * float(item['scale'][:-1]))
            write(directory / item['filename'], size, 'opaque' if platform == 'ios' else 'app')
    ico(APP / 'windows/runner/resources/app_icon.ico')
    for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
        write(APP / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png', size)
        write(APP / f'android/app/src/main/res/drawable-{density}/ic_launcher_foreground.png', round(size*108/48), 'foreground')
    for size in (192, 512):
        write(APP / f'web/icons/Icon-{size}.png', size)
        write(APP / f'web/icons/Icon-maskable-{size}.png', size, 'maskable')
    write(APP / 'web/favicon.png', 32)
    print('已生成 macOS / Windows / Android / iOS / Web 与托盘图标')


if __name__ == '__main__':
    main()
