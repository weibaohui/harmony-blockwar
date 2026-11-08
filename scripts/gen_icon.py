#!/usr/bin/env python3
"""生成方块战争应用图标（分层图标 foreground/background + 普通图标）。

用法: python3 scripts/gen_icon.py
输出: entry/src/main/resources/base/media/ 与 AppScope/resources/base/media/
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SIZE = 1024
ENTRY_MEDIA = os.path.join(ROOT, 'entry/src/main/resources/base/media')
APP_MEDIA = os.path.join(ROOT, 'AppScope/resources/base/media')

# 2×2 四色方块（经典俄罗斯方块配色）
BLOCKS = [
    (33, 201, 222),   # 青 I
    (232, 81, 81),    # 红 Z
    (247, 197, 49),   # 黄 O
    (83, 198, 83),    # 绿 S
]


def make_background() -> Image.Image:
    """深色对角渐变背景"""
    img = Image.new('RGB', (SIZE, SIZE))
    d = ImageDraw.Draw(img)
    top = (27, 33, 68)     # #1B2144
    bottom = (11, 14, 30)  # #0B0E1E
    # 逐行绘制垂直渐变
    for y in range(SIZE):
        t = y / (SIZE - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b))
    # 对角提亮（左上角更亮）
    highlight = Image.new('L', (SIZE, SIZE), 0)
    hd = ImageDraw.Draw(highlight)
    hd.ellipse((-500, -500, 900, 900), fill=46)
    bright = Image.new('RGB', (SIZE, SIZE), (74, 120, 200))
    img = Image.composite(Image.blend(img, bright, 0.25), img, highlight)
    return img


def make_foreground() -> Image.Image:
    """透明前景：2×2 圆角彩色方块"""
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    block = 400
    gap = 44
    x0 = (SIZE - block * 2 - gap) // 2
    y0 = x0
    radius = 84
    pos = [(x0, y0), (x0 + block + gap, y0), (x0, y0 + block + gap), (x0 + block + gap, y0 + block + gap)]
    for (x, y), color in zip(pos, BLOCKS):
        # 主块
        d.rounded_rectangle((x, y, x + block, y + block), radius=radius, fill=color + (255,))
        # 顶部高光
        d.rounded_rectangle(
            (x + 56, y + 44, x + block - 56, y + 150),
            radius=48, fill=(255, 255, 255, 66))
        # 底部阴影条
        d.rounded_rectangle(
            (x + 40, y + block - 90, x + block - 40, y + block - 44),
            radius=28, fill=(0, 0, 0, 60))
    return img


def composite(fg: Image.Image, bg: Image.Image, size: int) -> Image.Image:
    out = bg.resize((size, size), Image.LANCZOS).convert('RGBA')
    out.alpha_composite(fg.resize((size, size), Image.LANCZOS))
    return out.convert('RGB')


def main() -> None:
    bg = make_background()
    fg = make_foreground()

    os.makedirs(ENTRY_MEDIA, exist_ok=True)
    os.makedirs(APP_MEDIA, exist_ok=True)

    fg.save(os.path.join(ENTRY_MEDIA, 'foreground.png'))
    bg.save(os.path.join(ENTRY_MEDIA, 'background.png'))
    fg.save(os.path.join(APP_MEDIA, 'foreground.png'))
    bg.save(os.path.join(APP_MEDIA, 'background.png'))

    composite(fg, bg, 256).save(os.path.join(ENTRY_MEDIA, 'startIcon.png'))
    composite(fg, bg, 216).save(os.path.join(ENTRY_MEDIA, 'icon.png'))
    composite(fg, bg, 216).save(os.path.join(APP_MEDIA, 'app_icon.png'))
    print('icons generated OK')


if __name__ == '__main__':
    main()
