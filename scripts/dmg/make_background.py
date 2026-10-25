"""Draws the DMG window's background (660x420, plus @2x) in SubFloor's colours.

usage: python3 scripts/dmg/make_background.py OUT_DIR   (needs Pillow)
Writes OUT_DIR/background.png and background@2x.png; make_dmg.sh joins them into one TIFF.
Icon slots (window points): SubFloor at (180, 196), Applications at (480, 196), 128 pt icons.
"""
import math, os, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ACCENT, VFO, GREEN, INK, MUTED = (92, 214, 255), (255, 184, 71), (77, 219, 120), (236, 242, 250), (150, 168, 190)

def font(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f

def draw(scale):
    W, H = 660 * scale, 420 * scale
    s = lambda v: int(v * scale)
    img = Image.new("RGB", (W, H))
    px = img.load()
    top, bottom = (9, 13, 26), (18, 30, 52)
    for y in range(H):
        for x in range(W):
            t = min(1, (x / W) * 0.3 + (y / H) * 0.7)
            px[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    img = img.convert("RGBA")
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    for cx, cy, r, c, a in [(180, 190, 150, ACCENT, 70), (480, 190, 150, GREEN, 45), (620, 20, 120, VFO, 40)]:
        g.ellipse((s(cx - r), s(cy - r), s(cx + r), s(cy + r)), fill=c + (a,))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(s(60))))

    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # Spectrum trace along the bottom, with the amber VFO marker.
    random.seed(3)
    base, pts = 392, []
    for x10 in range(0, 6601, 6):
        x = x10 / 10
        y = base - random.uniform(0, 4)
        for p, h in [(110, 26), (205, 14), (330, 36), (455, 18), (560, 30)]:
            y -= h * math.exp(-((x - p) / 2.6) ** 2)
        pts.append((s(x), s(y)))
    d.polygon(pts + [(W, H), (0, H)], fill=ACCENT + (30,))
    d.line(pts, fill=ACCENT + (190,), width=max(1, s(1)))
    d.line((s(330), s(350), s(330), H), fill=VFO + (180,), width=max(1, s(1.5)))
    # A pill under each icon's label: Finder draws the labels, black in light mode and white in dark.
    for cx, half in [(180, 66), (480, 74)]:
        d.rounded_rectangle((s(cx - half), s(263), s(cx + half), s(293)), radius=s(15), fill=(104, 116, 134, 235))
    # Arrow from SubFloor to Applications.
    y = 196
    d.line((s(262), s(y), s(392), s(y)), fill=INK + (220,), width=s(5))
    d.polygon([(s(398), s(y)), (s(380), s(y - 13)), (s(380), s(y + 13))], fill=INK + (230,))
    img = Image.alpha_composite(img, layer)

    t = ImageDraw.Draw(img)
    title = "Drag SubFloor to Applications"
    f = font(s(24), "Bold")
    t.text(((W - t.textlength(title, font=f)) / 2, s(44)), title, font=f, fill=INK)
    note = "Needs the SDRplay API 3.15 · sdrplay.com/api"
    f2 = font(s(13), "Medium")
    t.text(((W - t.textlength(note, font=f2)) / 2, s(318)), note, font=f2, fill=MUTED)
    return img.convert("RGB")

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    draw(1).save(os.path.join(out, "background.png"))
    draw(2).save(os.path.join(out, "background@2x.png"))
    print("backgrounds in", out)
