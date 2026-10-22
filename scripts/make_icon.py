#!/usr/bin/env python3
"""Draws SubFloor's app icon (1024 px PNG): a spectrum trace and VFO marker above a waterfall, in
the app's theme colours, on a macOS-style rounded square. Usage: make_icon.py OUT.png"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048                     # drawn at 2x, downsampled at the end
BODY = int(S * 824 / 1024)   # Apple's icon grid: 824 of 1024, centred
OFF = (S - BODY) // 2
rng = np.random.default_rng(7)

ACCENT = np.array([92, 214, 255])   # Theme.accent
VFO = np.array([255, 184, 71])      # Theme.vfo
GREEN = np.array([77, 219, 120])    # Theme.modemBox


def squircle_mask(size, n=5.0):
    y, x = np.mgrid[0:size, 0:size]
    u = (x + 0.5) / size * 2 - 1
    v = (y + 0.5) / size * 2 - 1
    d = np.abs(u) ** n + np.abs(v) ** n
    # Soft edge, about one pixel wide.
    edge = 1 - np.clip((d - 1) / (n * 2 / size), 0, 1)
    return (edge * 255).astype(np.uint8)


def colormap(t):
    """Waterfall palette: black → deep blue → cyan → yellow → white."""
    stops = np.array([0, 0.25, 0.5, 0.75, 0.9, 1.0])
    cols = np.array([[3, 6, 14], [10, 30, 90], [20, 110, 190], [80, 220, 255], [255, 210, 90], [255, 250, 235]])
    t = np.clip(t, 0, 1)
    out = np.zeros(t.shape + (3,))
    for c in range(3):
        out[..., c] = np.interp(t, stops, cols[:, c])
    return out


B = BODY
img = np.zeros((B, B, 3))
yy, xx = np.mgrid[0:B, 0:B] / B

# Background: deep navy, lighter at the top, a cyan glow behind the main peak.
img[:] = (np.array([14, 24, 42]) * (1 - yy[..., None]) + np.array([4, 7, 14]) * yy[..., None])
glow = np.exp(-(((xx - 0.5) / 0.22) ** 2 + ((yy - 0.38) / 0.25) ** 2))
img += glow[..., None] * np.array([20, 70, 110])

# Signals: (centre x, strength, width), the main one at the VFO.
signals = [(0.5, 1.0, 0.018), (0.22, 0.45, 0.010), (0.33, 0.30, 0.007), (0.70, 0.55, 0.012), (0.84, 0.35, 0.008)]
floor_y = 0.60   # the "floor": the waterfall starts here

# Waterfall below the floor.
wf_top = int(B * floor_y)
rows = B - wf_top
wy = np.arange(rows)[:, None] / rows
wx = np.arange(B)[None, :] / B
level = 0.10 + 0.22 * rng.random((rows, B)) ** 2
level = np.array(Image.fromarray((level * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.5))) / 255.0
for cx, a, w in signals:
    # Each signal a streak, slightly wavering, keyed for the weaker ones.
    wobble = 0.0015 * np.sin(wy * 9 + cx * 50)
    streak = a * np.exp(-(((wx - cx - wobble) / (w * 1.4)) ** 2))
    if a < 0.5:
        streak *= (np.sin(wy * 60 + cx * 13) > -0.3)
    level = level + streak * 0.85
fade = np.clip(1 - wy * 0.9, 0, 1) ** 1.3
wf = colormap(level) * fade[..., None] + img[wf_top:] * (1 - fade[..., None]) * 0.6
img[wf_top:] = wf * 0.92

# Grid in the spectrum area.
for gx in np.linspace(0, 1, 7)[1:-1]:
    img[: wf_top, int(gx * B) - 1: int(gx * B) + 1] += 9
for gy in np.linspace(0.12, floor_y, 5)[:-1]:
    img[int(gy * B) - 1: int(gy * B) + 1, :] += 9

# Spectrum trace above the floor.
x = np.linspace(0, 1, B)
noise = np.convolve(rng.normal(0, 1, B + 40), np.ones(14) / 14, mode="same")[20:B + 20]
trace = floor_y - 0.05 + 0.012 * noise
for cx, a, w in signals:
    trace -= a * 0.42 * np.exp(-(((x - cx) / w) ** 2))
trace = np.clip(trace, 0.08, floor_y)

# Fill under the trace, a cyan gradient that brightens towards the trace.
fill = np.zeros((B, B))
ty = (trace * B).astype(int)
for i in range(B):
    if ty[i] < wf_top:
        col = np.linspace(1, 0, wf_top - ty[i]) ** 1.5
        fill[ty[i]:wf_top, i] = col
img += fill[..., None] * ACCENT * 0.33

out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert("RGBA")

# Glowing trace line and VFO marker on their own layers.
pts = [(i, trace[i] * B) for i in range(0, B, 2)]
line = Image.new("RGBA", (B, B), (0, 0, 0, 0))
ImageDraw.Draw(line).line(pts, fill=tuple(ACCENT) + (255,), width=int(B * 0.009), joint="curve")
for radius, strength in [(B * 0.03, 0.9), (B * 0.012, 1.0)]:
    g = line.filter(ImageFilter.GaussianBlur(radius))
    out = Image.alpha_composite(out, Image.eval(g, lambda v: int(min(255, v * strength))) if False else g)
core = Image.new("RGBA", (B, B), (0, 0, 0, 0))
ImageDraw.Draw(core).line(pts, fill=(225, 248, 255, 255), width=int(B * 0.0045), joint="curve")
out = Image.alpha_composite(out, line)
out = Image.alpha_composite(out, core)

# VFO marker: an amber line through the main peak, a passband tint, and a tab at the top.
vx = int(0.5 * B)
band = Image.new("RGBA", (B, B), (0, 0, 0, 0))
d = ImageDraw.Draw(band)
d.rectangle([vx - int(B * 0.06), 0, vx + int(B * 0.06), B], fill=tuple(VFO) + (28,))
ramp = np.clip((yy - 0.02) / 0.3, 0, 1)
band.putalpha(Image.fromarray((np.array(band.getchannel("A")) * ramp).astype(np.uint8)))
out = Image.alpha_composite(out, band)
marker = Image.new("RGBA", (B, B), (0, 0, 0, 0))
d = ImageDraw.Draw(marker)
d.line([(vx, int(B * 0.10)), (vx, B)], fill=tuple(VFO) + (235,), width=int(B * 0.006))
tab = int(B * 0.035)
d.polygon([(vx - tab, int(B * 0.065)), (vx + tab, int(B * 0.065)), (vx, int(B * 0.065) + int(tab * 1.3))],
          fill=tuple(VFO) + (255,))
out = Image.alpha_composite(out, marker.filter(ImageFilter.GaussianBlur(B * 0.01)))
out = Image.alpha_composite(out, marker)

# The floor line, a thin green rule (the modem's colour).
floor = Image.new("RGBA", (B, B), (0, 0, 0, 0))
ImageDraw.Draw(floor).line([(0, wf_top), (B, wf_top)], fill=tuple(GREEN) + (200,), width=int(B * 0.004))
out = Image.alpha_composite(out, floor.filter(ImageFilter.GaussianBlur(B * 0.006)))
out = Image.alpha_composite(out, floor)

# Glass: a soft highlight across the top and a thin bright rim.
hl = np.zeros((B, B, 4))
hl[..., :3] = 255
hl[..., 3] = 34 * np.clip(1 - yy / 0.45, 0, 1) ** 2
out = Image.alpha_composite(out, Image.fromarray(hl.astype(np.uint8)))

mask = squircle_mask(B)
inner = squircle_mask(B - 8)
rim = np.zeros((B, B), np.uint8)
rim_mask = mask.astype(int) - np.pad(inner, 4).astype(int)
rim = Image.fromarray(np.clip(rim_mask * 0.35, 0, 255).astype(np.uint8))
rim_layer = Image.new("RGBA", (B, B), (170, 220, 255, 0))
rim_layer.putalpha(rim)
out = Image.alpha_composite(out, rim_layer)
out.putalpha(Image.fromarray(mask))

# Canvas with Apple's drop shadow.
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh = Image.new("RGBA", (B, B), (0, 0, 0, 110))
sh.putalpha(Image.fromarray((mask * 0.45).astype(np.uint8)))
shadow.paste(sh, (OFF, OFF + int(S * 0.012)), sh)
canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(S * 0.014)))
canvas.alpha_composite(out, (OFF, OFF))

canvas.resize((1024, 1024), Image.LANCZOS).save(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
