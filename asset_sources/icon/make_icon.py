"""TrekPay launcher icon sources from the artwork
(graphics/Kerrigan/GooglePlay/app_icon_appstore_1024x1024.png: the
shielded Delta with the Kerrigan mark, no arms).

Delta is cut out of the artwork (BiRefNet matte), its dark body lifted a
little, and set on a violet backdrop with a soft lavender glow and a
white outline, so it stands out on a phone's home screen.

Writes 1024 px sources for flutter_launcher_icons, which scales them to
every Android density (mdpi..xxxhdpi), every iOS size and the desktop
icons:

- icon.png                 iOS / Windows / Linux: full bleed (the
                           platforms apply their own corner mask).
- macos-icon.png           macOS / Android legacy: rounded tile on
                           transparent with a small margin.
- adaptive_foreground.png  Android 8+ foreground: Delta, glow, outline.
- adaptive_background.png  Android 8+ background: the violet backdrop.
- adaptive_monochrome.png  Android 13 themed icon: Delta's silhouette
                           with the eyes, mark and trims cut out.

With a store directory (Graphics/GooglePlay), also the store icons there:
trekpay_app_icon_googleplay_512x512.png, trekpay_app_icon_appstore_1024x1024.png
(no alpha; also asset_sources/other/playstore_icon/trekpay/app_icon-playstore.png)
and trekpay_app_button_rounded_1024x1024.png (corners cut, for web pages
and posts). The prefix keeps the artwork they're made from untouched.

Usage: python make_icon.py <app_icon_appstore_1024x1024.png> <out dir> [store dir]
(needs `pip install "rembg[cpu]" pillow numpy`)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from rembg import new_session, remove

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
STORE = Path(sys.argv[3]) if len(sys.argv) > 3 else None
OUT.mkdir(parents=True, exist_ok=True)
S = 1024

art = Image.open(SRC).convert("RGB").resize((S, S), Image.LANCZOS)
rgb = np.asarray(art).astype(np.float32)

# --- Delta's matte
matte = remove(art, session=new_session("birefnet-general"), only_mask=True)
m = np.asarray(matte).astype(np.float32) / 255
m = np.clip((m - 0.3) / 0.4, 0, 1)

# --- Delta brighter: the dark navy body lifted a little towards slate
# violet, keeping the shading, outlines, eyes and mark.
lum = rgb.mean(axis=2, keepdims=True)
w = np.clip((90 - lum) / 40, 0, 1) * 0.30
target = np.array((70, 70, 128), np.float32)[None, None] * np.clip(lum / 30, 0.6, 1.4)
lit = rgb * (1 - w) + target * w
delta = Image.fromarray(np.dstack([lit, m * 255]).clip(0, 255).round().astype(np.uint8), "RGBA")
plain = Image.fromarray(np.dstack([rgb, m * 255]).round().astype(np.uint8), "RGBA")

# Sizes are tuned for Delta 1014 px wide (the adaptive foreground).
TUNED = 1014


def placed(img, n, k):
    """The artwork-sized `img` at k x n px, centred on an n px canvas."""
    size = round(n * k)
    cut = img.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.alpha_composite(cut, ((n - size) // 2, (n - size) // 2))
    return out


def dilated(alpha, radius):
    """Round dilation of a silhouette by `radius` px, antialiased."""
    mask = np.asarray(alpha) > 110
    n = mask.shape[0]
    pad = np.pad(mask, radius)
    out = np.zeros_like(mask)
    for dy in range(-radius, radius + 1):
        w = int((radius**2 - dy**2) ** 0.5)
        for dx in range(-w, w + 1):
            out |= pad[radius + dy : radius + dy + n, radius + dx : radius + dx + n]
    return Image.fromarray((out * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(1.6))


def sticker(n, k):
    """Delta at k x n px on an n px canvas, with its glow and outline."""
    d = placed(delta, n, k)
    u = n * k / TUNED
    al = d.getchannel("A")
    grow = round(40 * u) | 1
    glow_a = al.filter(ImageFilter.MaxFilter(grow)).filter(ImageFilter.GaussianBlur(30 * u))
    glow = Image.new("RGBA", (n, n), (236, 222, 255, 0))
    glow.putalpha(glow_a.point(lambda v: min(255, int(v * 1.4))))
    line = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    line.putalpha(dilated(al, round(12 * u)))
    glow.alpha_composite(line)
    glow.alpha_composite(d)
    return glow


def backdrop(n, scale=1.0):
    """The violet radial backdrop on n px; `scale` < 1 shows only the
    middle of the adaptive layer (launchers show its middle 72 of 108 dp)."""
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32) / n - 0.5
    r = np.sqrt(xx**2 + yy**2) * scale
    t = np.clip(r / 0.62, 0, 1) ** 1.2
    c, e = np.array((176, 120, 240), np.float32), np.array((96, 54, 176), np.float32)
    img = c[None, None] * (1 - t[..., None]) + e[None, None] * t[..., None]
    return Image.fromarray(img.round().clip(0, 255).astype(np.uint8), "RGB")


# --- adaptive layers: Delta 99% of the layer (the layer is inset 16% and
# its middle 2/3 shows)
backdrop(S).save(OUT / "adaptive_background.png", optimize=True)
fg = sticker(S, 0.99)
fg.save(OUT / "adaptive_foreground.png", optimize=True)

# --- icon.png: what a launcher shows of the adaptive icon, full bleed
# (Delta 0.99 x 0.68 of the layer, the layer 108/72 of the icon)
icon = backdrop(S, 72 / 108).convert("RGBA")
icon.alpha_composite(sticker(S, 0.99 * 0.68 * 108 / 72))
icon = icon.convert("RGB")
icon.save(OUT / "icon.png", optimize=True)


def rounded(img, radius_frac, scale=4):
    big = Image.new("L", (S * scale, S * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [0, 0, S * scale - 1, S * scale - 1], radius=round(S * scale * radius_frac), fill=255
    )
    out = img.convert("RGBA")
    out.putalpha(big.resize((S, S), Image.LANCZOS))
    return out


# --- macos-icon.png: rounded tile, ~6% margin
inner = round(S * 0.88)
tile = rounded(icon, 0.2237).convert("RGBa").resize((inner, inner), Image.LANCZOS).convert("RGBA")
mac = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mac.alpha_composite(tile, ((S - inner) // 2, (S - inner) // 2))
mac.save(OUT / "macos-icon.png", optimize=True)

# --- monochrome: Delta's silhouette, the glowing parts (eyes, mark,
# trims) cut out
f = np.asarray(placed(plain, S, 0.99)).astype(np.float32)
alpha = f[..., 3] / 255
hole = np.clip((f[..., :3].max(axis=2) - 140) / 50, 0, 1)
mono = Image.merge(
    "LA",
    (Image.new("L", (S, S), 255), Image.fromarray((alpha * (1 - hole) * 255).astype(np.uint8))),
)
mono.save(OUT / "adaptive_monochrome.png", optimize=True)

# --- store icons
if STORE:
    STORE.mkdir(parents=True, exist_ok=True)
    icon.resize((512, 512), Image.LANCZOS).convert("RGBA").save(
        STORE / "trekpay_app_icon_googleplay_512x512.png", optimize=True
    )
    icon.save(STORE / "trekpay_app_icon_appstore_1024x1024.png", optimize=True)
    rounded(icon, 0.2237).save(STORE / "trekpay_app_button_rounded_1024x1024.png", optimize=True)


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
bg = Image.open(OUT / "adaptive_background.png")
sheet = Image.new("RGBA", (256 * 5 + 60, 300), (236, 236, 240, 255))
sheet.alpha_composite(adaptive_preview("circle", fg, bg), (10, 20))
sheet.alpha_composite(adaptive_preview("squircle", fg, bg), (276, 20))
sheet.alpha_composite(rounded(icon, 0.2237).resize((256, 256), Image.LANCZOS), (542, 20))
sheet.alpha_composite(mac.resize((256, 256), Image.LANCZOS), (808, 20))
sheet.alpha_composite(adaptive_preview("circle", themed_fg, themed_bg), (1074, 20))
sheet.convert("RGB").save(OUT / "preview.png")
