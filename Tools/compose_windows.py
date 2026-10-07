#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""把同一进程的几张按窗口 ID 截下的图，按各自的屏幕位置拼成一张（主窗口在下、sheet / 确认框在上）。
用法：compose_windows.py <manifest> <out.png>；manifest 每行「文件 x y 宽 高」（点坐标），第一行是最大的窗口。
截图是 Retina 2×，按第一张图与其点宽度的比例换算。macOS 26 里附着的 sheet / 确认框按 ID 截出来的是
「父窗口连同 sheet」整幅（尺寸等于父窗口），这种就按父窗口的位置贴；真正只有自己那一小块的窗口按自己的位置贴。
透明处保留 alpha（与按窗口 ID 单截一致）。"""
import sys
from PIL import Image

manifest, out = sys.argv[1], sys.argv[2]
rows = []
for line in open(manifest, encoding="utf-8"):
    parts = line.split()
    if len(parts) != 5:
        continue
    rows.append((parts[0], float(parts[1]), float(parts[2]), float(parts[3]), float(parts[4])))
if not rows:
    sys.exit("没有窗口可拼")
images = [Image.open(r[0]).convert("RGBA") for r in rows]
main_x, main_y, main_w, main_h = rows[0][1], rows[0][2], rows[0][3], rows[0][4]
scale = images[0].width / main_w if main_w else 2.0
placed = []
for (path, x, y, w, h), image in zip(rows, images):
    if image.size == images[0].size and (w, h) != (main_w, main_h):
        placed.append((image, main_x, main_y, main_w, main_h))   # 父窗口连同 sheet 的整幅
    else:
        placed.append((image, x, y, image.width / scale, image.height / scale))
left = min(p[1] for p in placed)
top = min(p[2] for p in placed)
right = max(p[1] + p[3] for p in placed)
bottom = max(p[2] + p[4] for p in placed)
canvas = Image.new("RGBA", (round((right - left) * scale), round((bottom - top) * scale)), (0, 0, 0, 0))
for image, x, y, _, _ in placed:
    canvas.alpha_composite(image, (round((x - left) * scale), round((y - top) * scale)))
canvas.save(out)
