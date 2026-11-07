#!/usr/bin/env python3
"""Generates Resources/AppIcon.iconset, AppIcon.icns and icon-1024.png (needs Pillow).
Run from repo root: python3 tools/make_icon.py"""
import os
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources")
S = 4096                     # draw large, downsample for smooth edges
os.makedirs(OUT, exist_ok=True)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# macOS-style squircle (824/1024 of the canvas, ~22.4% corner radius)
m = int(S * 100 / 1024); size = S - 2 * m; r = int(size * 0.2237)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle((m, m, m + size, m + size), r, fill=255)

# vertical blue gradient
grad = Image.new("RGBA", (S, S))
top, bot = (84, 176, 255), (10, 104, 245)
gd = ImageDraw.Draw(grad)
for y in range(S):
    gd.line([(0, y), (S, y)], fill=lerp(top, bot, y / S) + (255,))
canvas.paste(grad, (0, 0), mask)

# soft drop shadow for the bubble
cx, cy = S // 2, int(S * 0.47)
bw, bh = int(S * 0.56), int(S * 0.40)
box = (cx - bw // 2, cy - bh // 2, cx + bw // 2, cy + bh // 2)
tail = [(cx - int(S * 0.17), cy + bh // 2 - int(S * 0.03)),
        (cx - int(S * 0.27), cy + bh // 2 + int(S * 0.13)),
        (cx - int(S * 0.04), cy + bh // 2 - int(S * 0.01))]

def bubble(draw, fill):
    draw.rounded_rectangle(box, int(bh * 0.5), fill=fill)
    draw.polygon(tail, fill=fill)

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bubble(ImageDraw.Draw(shadow), (0, 30, 90, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.012)).transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -int(S * 0.012)))
canvas = Image.alpha_composite(canvas, Image.composite(shadow, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))

ImageDraw.Draw(canvas)
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bubble(ImageDraw.Draw(layer), (255, 255, 255, 255))
canvas = Image.alpha_composite(canvas, layer)

# three "typing" dots
d = ImageDraw.Draw(canvas)
dr = int(S * 0.034)
for i in (-1, 0, 1):
    x = cx + i * int(S * 0.115)
    d.ellipse((x - dr, cy - dr, x + dr, cy + dr), fill=(10, 104, 245, 255))

base = canvas.resize((1024, 1024), Image.LANCZOS)
base.save(os.path.join(OUT, "icon-1024.png"))

iconset = os.path.join(OUT, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        base.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
base.save(os.path.join(OUT, "AppIcon.icns"))
print("wrote", OUT)
