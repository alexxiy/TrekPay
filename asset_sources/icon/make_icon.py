"""TrekPay launcher icon sources from the artwork
(graphics/Kerrigan/GooglePlay/app_icon_appstore_1024x1024.png: the
shielded Delta with the Kerrigan mark, no arms, on a navy backdrop with
a violet glow).

Writes 1024 px sources for flutter_launcher_icons, which scales them to
every Android density (mdpi..xxxhdpi), every iOS size and the desktop
icons:

- icon.png                 iOS / Windows: the artwork, full bleed (the
                           platforms apply their own corner mask).
- macos-icon.png           macOS / Android legacy: rounded tile on
                           transparent with a small margin.
- adaptive_foreground.png  Android 8+ foreground: Delta cut out.
- adaptive_background.png  Android 8+ background: the backdrop and glow.
- adaptive_monochrome.png  Android 13 themed icon: Delta's silhouette
                           with the eyes, mark and trims cut out.

The backdrop is a radial gradient: it's rebuilt from the artwork's own
background pixels (median colour per distance from the centre) and
stretched so that the part a launcher shows matches the artwork. Delta
(BiRefNet matte) sits on it as in the artwork, a little smaller so the
wing tips stay inside round masks.

Usage: python make_icon.py <app_icon_appstore_1024x1024.png> <out dir>
(needs `pip install "rembg[cpu]" pillow numpy`)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from rembg import new_session, remove

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
S = 1024

art = Image.open(SRC).convert("RGB").resize((S, S), Image.LANCZOS)
rgb = np.asarray(art).astype(np.float32)

# --- Delta's matte
matte = remove(art, session=new_session("birefnet-general"), only_mask=True)
m = np.asarray(matte).astype(np.float32) / 255
m = np.clip((m - 0.3) / 0.4, 0, 1)

# --- backdrop: median colour per ring around the centre
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S - 0.5
r = np.sqrt(xx**2 + yy**2)
bins = np.linspace(0, r.max() + 1e-6, 97)
centres = (bins[:-1] + bins[1:]) / 2
bgmask = m < 0.02
profile = np.zeros((len(centres), 3), np.float32)
known = np.zeros(len(centres), bool)
for i in range(len(centres)):
    sel = bgmask & (r >= bins[i]) & (r < bins[i + 1])
    if sel.sum() > 30:
        profile[i] = np.median(rgb[sel], axis=0)
        known[i] = True
# rings under Delta: interpolated from the known ones
for c in range(3):
    profile[:, c] = np.interp(centres, centres[known], profile[known, c])
# a little smoothing so the rings don't show
k = np.array([1, 2, 3, 2, 1], np.float32)
k /= k.sum()
for c in range(3):
    padded = np.pad(profile[:, c], 2, mode="edge")
    profile[:, c] = np.convolve(padded, k, mode="valid")


def backdrop(stretch: float) -> np.ndarray:
    rr = np.minimum(r * stretch, centres[-1])
    return np.dstack([np.interp(rr, centres, profile[:, c]) for c in range(3)])


# Launchers show the middle 72 of the layer's 108 dp.
adaptive_bg = backdrop(108 / 72)
Image.fromarray(np.clip(adaptive_bg, 0, 255).astype(np.uint8)).save(
    OUT / "adaptive_background.png", optimize=True
)

# Delta RGBA (original colours, matte alpha)
delta = Image.fromarray(np.dstack([rgb, m * 255]).round().astype(np.uint8), "RGBA")

# --- icon.png: the artwork as it is
art.save(OUT / "icon.png", optimize=True)

# --- macos-icon.png: rounded tile, ~6% margin
def rounded(img, radius_frac, scale=4):
    big = Image.new("L", (S * scale, S * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [0, 0, S * scale - 1, S * scale - 1], radius=round(S * scale * radius_frac), fill=255
    )
    out = img.convert("RGBA")
    out.putalpha(big.resize((S, S), Image.LANCZOS))
    return out

inner = round(S * 0.88)
tile = rounded(art, 0.2237).convert("RGBa").resize((inner, inner), Image.LANCZOS).convert("RGBA")
mac = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mac.alpha_composite(tile, ((S - inner) // 2, (S - inner) // 2))
mac.save(OUT / "macos-icon.png", optimize=True)

# --- adaptive foreground: Delta where it is in the artwork, at 90% around
# the centre (the layer is inset 16% and its middle 2/3 shows)
small = round(S * 0.90)
cut = delta.convert("RGBa").resize((small, small), Image.LANCZOS).convert("RGBA")
fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
fg.alpha_composite(cut, ((S - small) // 2, (S - small) // 2))
fg.save(OUT / "adaptive_foreground.png", optimize=True)

# --- monochrome: silhouette, the glowing parts (eyes, mark, trims) cut out
f = np.asarray(fg).astype(np.float32)
alpha = f[..., 3] / 255
bright = f[..., :3].max(axis=2)
hole = np.clip((bright - 140) / 50, 0, 1)
mono_a = alpha * (1 - hole)
mono = Image.merge(
    "LA",
    (Image.new("L", (S, S), 255), Image.fromarray((mono_a * 255).astype(np.uint8))),
)
mono.save(OUT / "adaptive_monochrome.png", optimize=True)

# --- preview sheet: Android circle / squircle, iOS, legacy, themed
def adaptive_preview(shape, layer_fg, layer_bg):
    canvas = layer_bg.convert("RGBA").copy()
    f2 = layer_fg.resize((round(S * 0.68),) * 2, Image.LANCZOS)
    canvas.alpha_composite(f2, ((S - f2.width) // 2, (S - f2.height) // 2))
    vis = round(S * 72 / 108)
    off = (S - vis) // 2
    canvas = canvas.crop((off, off, off + vis, off + vis)).resize((256, 256), Image.LANCZOS)
    mk = Image.new("L", (1024, 1024), 0)
    d = ImageDraw.Draw(mk)
    if shape == "circle":
        d.ellipse([0, 0, 1023, 1023], fill=255)
    else:
        d.rounded_rectangle([0, 0, 1023, 1023], radius=300, fill=255)
    canvas.putalpha(mk.resize((256, 256), Image.LANCZOS))
    return canvas

themed_bg = Image.new("RGB", (S, S), (40, 40, 52))
themed_fg = Image.merge(
    "RGBA",
    (
        Image.new("L", (S, S), 200),
        Image.new("L", (S, S), 190),
        Image.new("L", (S, S), 255),
        mono.getchannel("A"),
    ),
)
sheet = Image.new("RGBA", (256 * 5 + 60, 300), (236, 236, 240, 255))
sheet.alpha_composite(adaptive_preview("circle", fg, Image.open(OUT / "adaptive_background.png")), (10, 20))
sheet.alpha_composite(adaptive_preview("squircle", fg, Image.open(OUT / "adaptive_background.png")), (276, 20))
ios = rounded(art, 0.2237).resize((256, 256), Image.LANCZOS)
sheet.alpha_composite(ios, (542, 20))
sheet.alpha_composite(mac.resize((256, 256), Image.LANCZOS), (808, 20))
sheet.alpha_composite(adaptive_preview("circle", themed_fg, themed_bg), (1074, 20))
sheet.convert("RGB").save(OUT / "preview.png")
