#!/usr/bin/env python3
"""Generates Resources/AppIcon.iconset, AppIcon.icns and icon-1024.png (needs Pillow only).
Run from repo root: python3 tools/make_icon.py            (writes Resources/)
                    python3 tools/make_icon.py --preview DIR   (writes DIR/icon-1024.png only)

Everything is built from sampled parametric curves at 4096 px and downsampled, so edges are smooth:
a continuous-curvature squircle (superellipse) body on Apple's 824/1024 icon grid with the standard drop shadow,
and a speech bubble whose curved tail is blended into the body (blur + threshold fillet) instead of a hard triangle.
"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 4096
U = S / 1024.0          # 1 unit = 1 px on the 1024 canvas


def superellipse(cx, cy, a, b, n, steps=4000):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c) ** (2 / n), c), cy + b * math.copysign(abs(s) ** (2 / n), s)))
    return pts


def cubic(p0, p1, p2, p3, steps=400):
    out = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        out.append((mt**3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t**3 * p3[0],
                    mt**3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t**3 * p3[1]))
    return out


def continuous_rect(x0, y0, x1, y1, extent, n=4.0, steps=600):
    """Rounded rect with flat sides and continuous-curvature corners (each corner a superellipse quadrant that
    meets the sides tangentially with zero curvature) - the macOS/iOS icon shape, without the bulge of a full
    superellipse."""
    corners = [(x1 - extent, y0 + extent, 1, -1), (x0 + extent, y0 + extent, -1, -1),
               (x0 + extent, y1 - extent, -1, 1), (x1 - extent, y1 - extent, 1, 1)]
    pts = []
    for k, (cx, cy, sx, sy) in enumerate(corners):
        for i in range(steps + 1):
            t = (math.pi / 2) * i / steps
            if k % 2 == 1:
                t = math.pi / 2 - t
            c, s = math.cos(t), math.sin(t)
            u, v = c ** (2 / n), s ** (2 / n)
            # quadrant order so the outline is traversed continuously
            if k in (0, 2):
                u, v = (u, v) if k == 0 else (u, v)
            pts.append((cx + sx * extent * u, cy + sy * extent * v))
    return pts


def se_point(cx, cy, a, b, n, t):
    c, s = math.cos(t), math.sin(t)
    return (cx + a * math.copysign(abs(c) ** (2 / n), c), cy + b * math.copysign(abs(s) ** (2 / n), s))


def se_tangent(cx, cy, a, b, n, t, sign):
    """Unit tangent of the superellipse at t, in the direction of increasing (sign=1) or decreasing (-1) t."""
    h = 1e-4
    p, q = se_point(cx, cy, a, b, n, t), se_point(cx, cy, a, b, n, t + sign * h)
    dx, dy = q[0] - p[0], q[1] - p[1]
    l = math.hypot(dx, dy)
    return (dx / l, dy / l)


def mask_from(polys):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    for p in polys:
        d.polygon(p, fill=255)
    return m


def smooth(mask, radius):
    """Rounds every corner/junction of a mask: blur then re-threshold (a cheap morphological fillet)."""
    return mask.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: 255 if v >= 128 else 0)


def gradient(c0, c1, angle_deg=90):
    """Linear gradient across the canvas; angle 90 = top->bottom, 135 = top-left -> bottom-right."""
    g = Image.linear_gradient("L").resize((S, S))          # 0 at top, 255 at bottom
    if angle_deg != 90:
        big = Image.linear_gradient("L").resize((int(S * 1.5), int(S * 1.5)))
        big = big.rotate(90 - angle_deg, resample=Image.BICUBIC)
        o = (big.width - S) // 2
        g = big.crop((o, o, o + S, o + S))
    a = Image.new("RGBA", (S, S), c0 + (255,))
    b = Image.new("RGBA", (S, S), c1 + (255,))
    return Image.composite(b, a, g)


def render():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # --- body: continuous-corner rounded rect on the 824 grid (radius ~185 -> corner extent ~283), macOS shadow
    m0, m1 = 100 * U, 924 * U
    body = mask_from([continuous_rect(m0, m0, m1, m1, 283 * U)])
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(body.point(lambda v: v * 0.30))
    shadow = shadow.filter(ImageFilter.GaussianBlur(12 * U)).transform(
        (S, S), Image.AFFINE, (1, 0, 0, 0, 1, -10 * U))
    canvas = Image.alpha_composite(canvas, shadow)

    bg = gradient((78, 190, 255), (22, 98, 240), 120)
    # soft light from the top
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((S * 0.05, -S * 0.55, S * 0.95, S * 0.42), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(120 * U))
    bg = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), bg, glow.point(lambda v: v * 0.22))
    canvas.paste(bg, (0, 0), body)

    # --- bubble: superellipse body + curved tail, filleted together
    cx, cy = S / 2, 480 * U
    a, b = 292 * U, 226 * U
    n = 2.35
    blob = superellipse(cx, cy, a, b, n)
    # Tail: two cubics leaving the bubble outline tangentially (G1), so it reads as one shape. y grows downward,
    # so t in (90deg, 180deg) is the lower-left quarter; decreasing t walks toward the bottom centre.
    t_out, t_in = math.radians(166), math.radians(118)
    p_out, p_in = se_point(cx, cy, a, b, n, t_out), se_point(cx, cy, a, b, n, t_in)
    d_out, d_in = se_tangent(cx, cy, a, b, n, t_out, -1), se_tangent(cx, cy, a, b, n, t_in, -1)
    tip = (cx - 262 * U, cy + b + 44 * U)
    outer = cubic(p_out, (p_out[0] + d_out[0] * 80 * U, p_out[1] + d_out[1] * 80 * U),
                  (tip[0] - 4 * U, tip[1] - 34 * U), tip)
    inner = cubic(tip, (tip[0] + 46 * U, tip[1] - 2 * U),
                  (p_in[0] - d_in[0] * 55 * U, p_in[1] - d_in[1] * 55 * U), p_in)
    tail = outer + inner + [(cx - 60 * U, cy)]           # close through the bubble's interior
    bubble = smooth(mask_from([blob, tail]), 7 * U)

    # bubble shadow (soft, slightly below)
    bs = Image.new("RGBA", (S, S), (0, 20, 80, 0))
    bs.putalpha(bubble.point(lambda v: v * 0.28))
    bs = bs.filter(ImageFilter.GaussianBlur(22 * U)).transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -16 * U))
    canvas = Image.alpha_composite(canvas, Image.composite(bs, Image.new("RGBA", (S, S), (0, 0, 0, 0)), body))

    fill = gradient((255, 255, 255), (226, 238, 255), 90)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    layer.paste(fill, (0, 0), bubble)
    canvas = Image.alpha_composite(canvas, layer)

    # --- typing dots, same gradient as the background so they read as "cut out"
    dots = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(dots)
    r = 38 * U
    for i in (-1, 0, 1):
        x = cx + i * 118 * U
        d.ellipse((x - r, cy - r, x + r, cy + r), fill=255)
    dot_fill = gradient((56, 150, 255), (18, 92, 235), 90)
    canvas.paste(dot_fill, (0, 0), dots)

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    base = render()
    if len(sys.argv) == 3 and sys.argv[1] == "--preview":
        os.makedirs(sys.argv[2], exist_ok=True)
        base.save(os.path.join(sys.argv[2], "icon-1024.png"))
        print("wrote preview to", sys.argv[2])
        return
    out = os.path.join(ROOT, "Resources")
    iconset = os.path.join(out, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    base.save(os.path.join(out, "icon-1024.png"))
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            base.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    base.save(os.path.join(out, "AppIcon.icns"))
    print("wrote", out)


if __name__ == "__main__":
    main()
