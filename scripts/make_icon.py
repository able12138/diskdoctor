#!/usr/bin/env python3
"""生成 DiskDoctor 应用图标。

绘制一个简洁的硬盘 + 放大镜图标，输出为 macOS iconset 所需的多尺寸 PNG。
依赖：仅使用标准库 + 由调用方提供的 PNG 编码能力。
本脚本不依赖 Pillow，直接写 PNG（RGBA）。
"""
import struct
import zlib
import sys
import os
import math


def write_png(path, width, height, pixels):
    """pixels: list of rows, each row list of (r,g,b,a) tuples."""
    raw = b''
    for row in pixels:
        raw += b'\x00' + b''.join(struct.pack('BBBB', *px) for px in row)

    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def lerp(a, b, t):
    """在两个 RGB 颜色间线性插值，返回带 alpha 的 RGBA。"""
    return (
        int(round(a[0] + (b[0] - a[0]) * t)),
        int(round(a[1] + (b[1] - a[1]) * t)),
        int(round(a[2] + (b[2] - a[2]) * t)),
        255,
    )


def make_icon(size):
    """绘制 size x size 的图标像素。"""
    s = size
    px = [[(0, 0, 0, 0) for _ in range(s)] for _ in range(s)]

    # 圆角矩形背景：渐变蓝
    pad = int(s * 0.06)
    radius = int(s * 0.22)
    top = (52, 120, 246)
    bottom = (24, 62, 156)

    def in_rounded(x, y):
        if x < pad or y < pad or x >= s - pad or y >= s - pad:
            return False
        cx = min(max(x, pad + radius), s - pad - radius - 1)
        cy = min(max(y, pad + radius), s - pad - radius - 1)
        return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2

    for y in range(s):
        t = y / max(s - 1, 1)
        row_px = lerp(top, bottom, t)
        for x in range(s):
            if in_rounded(x, y):
                px[y][x] = row_px

    # 硬盘主体（白色圆角矩形）
    body_x0, body_x1 = int(s * 0.20), int(s * 0.80)
    body_y0, body_y1 = int(s * 0.28), int(s * 0.72)
    br = int(s * 0.06)
    for y in range(body_y0, body_y1):
        for x in range(body_x0, body_x1):
            cx = min(max(x, body_x0 + br), body_x1 - br - 1)
            cy = min(max(y, body_y0 + br), body_y1 - br - 1)
            if (x - cx) ** 2 + (y - cy) ** 2 <= br ** 2:
                px[y][x] = (255, 255, 255, 255)

    # 硬盘上的指示灯（绿色圆点）
    led_cx, led_cy = int(s * 0.30), int(s * 0.62)
    led_r = max(1, int(s * 0.035))
    for y in range(led_cy - led_r, led_cy + led_r + 1):
        for x in range(led_cx - led_r, led_cx + led_r + 1):
            if 0 <= x < s and 0 <= y < s and (x - led_cx) ** 2 + (y - led_cy) ** 2 <= led_r ** 2:
                px[y][x] = (34, 197, 94, 255)

    # 放大镜（右下角）
    g_cx, g_cy = int(s * 0.66), int(s * 0.62)
    g_r = int(s * 0.19)
    ring = max(2, int(s * 0.055))
    for y in range(max(0, g_cy - g_r - 2), min(s, g_cy + g_r + 3)):
        for x in range(max(0, g_cx - g_r - 2), min(s, g_cx + g_r + 3)):
            if 0 <= x < s and 0 <= y < s:
                d = math.hypot(x - g_cx, y - g_cy)
                if g_r - ring <= d <= g_r:
                    px[y][x] = (255, 255, 255, 255)
                elif d < g_r - ring:
                    # 镜片内部半透明
                    if px[y][x][3] > 0:
                        px[y][x] = (255, 255, 255, 60)
    # 手柄
    hx0, hy0 = int(s * 0.79), int(s * 0.75)
    hx1, hy1 = int(s * 0.90), int(s * 0.86)
    hw = max(2, int(s * 0.05))
    for y in range(hy0, hy1):
        for x in range(hx0, hx1):
            if 0 <= x < s and 0 <= y < s:
                if abs((y - hy0) - (x - hx0) * (hy1 - hy0) / max(1, (hx1 - hx0))) <= hw:
                    px[y][x] = (255, 255, 255, 255)

    return px


def main():
    if len(sys.argv) < 2:
        print("用法: make_icon.py <iconset 目录>")
        return 1
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)

    sizes = [
        (16, 'icon_16x16.png'), (32, 'icon_16x16@2x.png'),
        (32, 'icon_32x32.png'), (64, 'icon_32x32@2x.png'),
        (128, 'icon_128x128.png'), (256, 'icon_128x128@2x.png'),
        (256, 'icon_256x256.png'), (512, 'icon_256x256@2x.png'),
        (512, 'icon_512x512.png'), (1024, 'icon_512x512@2x.png'),
    ]
    cache = {}
    for size, name in sizes:
        if size not in cache:
            cache[size] = make_icon(size)
        write_png(os.path.join(outdir, name), size, size, cache[size])
        print(f"  {name} ({size}x{size})")
    return 0


if __name__ == '__main__':
    sys.exit(main())
