"""TrekPay launcher icon sources from the official Kerrigan logo
(graphics/Kerrigan/logo.svg): the purple mark with the green triangle,
in its own colors, on a light lavender backdrop.

The logo is sized so its wing tips stay inside the 66 dp circle that
every launcher mask keeps.

Writes 1024 px sources for flutter_launcher_icons, which scales them to
every Android density (mdpi..xxxhdpi), every iOS size and the desktop
icons:

- icon.png                 iOS / Windows / Linux: full bleed (the
                           platforms apply their own corner mask).
- macos-icon.png           macOS / Android legacy: rounded tile on
                           transparent with a small margin.
- adaptive_foreground.png  Android 8+ foreground: the logo.
- adaptive_background.png  Android 8+ background: the lavender backdrop.
- adaptive_monochrome.png  Android 13 themed icon: the logo's silhouette.

With a store directory (Graphics/GooglePlay), also the store icons there:
trekpay_app_icon_googleplay_512x512.png, trekpay_app_icon_appstore_1024x1024.png
(no alpha; also asset_sources/other/playstore_icon/trekpay/app_icon-playstore.png)
and trekpay_app_button_rounded_1024x1024.png (corners cut, for web pages
and posts).

Usage: python make_icon.py <logo.svg> <out dir> [store dir]
(needs inkscape, pillow and numpy)
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
STORE = Path(sys.argv[3]) if len(sys.argv) > 3 else None
OUT.mkdir(parents=True, exist_ok=True)
S = 1024

# --- the logo, rendered big and cropped to its shapes
with tempfile.TemporaryDirectory() as tmp:
    png = Path(tmp) / "logo.png"
    subprocess.run(
        ["inkscape", str(SRC), "--export-type=png", f"--export-filename={png}", "-w", "2048", "-h", "2048"],
        check=True,
        capture_output=True,
    )
    src = Image.open(png).convert("RGBA")
    src.load()
ys, xs = np.nonzero(np.asarray(src)[..., 3] > 8)
logo = src.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
yy, xx = np.nonzero(np.asarray(logo)[..., 3] > 8)
REACH = np.sqrt((xx - logo.width / 2) ** 2 + (yy - logo.height / 2) ** 2).max()  # wing tips


def placed(n, radius):
    """The logo centred on n px, its wing tips `radius` px from the centre."""
    k = radius / REACH
    w, h = round(logo.width * k), round(logo.height * k)
    small = logo.convert("RGBa").resize((w, h), Image.LANCZOS).convert("RGBA")
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.alpha_composite(small, ((n - w) // 2, (n - h) // 2))
    return out


def backdrop(n, scale=1.0):
    """The lavender radial backdrop on n px; `scale` < 1 shows only the
    middle of the adaptive layer (launchers show its middle 72 of 108 dp)."""
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32) / n - 0.5
    r = np.sqrt(xx**2 + yy**2) * scale
    t = np.clip(r / 0.62, 0, 1) ** 1.3
    c, e = np.array((255, 255, 255), np.float32), np.array((226, 218, 250), np.float32)
    img = c[None, None] * (1 - t[..., None]) + e[None, None] * t[..., None]
    return Image.fromarray(img.round().clip(0, 255).astype(np.uint8), "RGB")


# Wing tips 30.5 dp from the centre: inside the 66 dp safe circle.
TIPS_DP = 30.5

# --- adaptive layers (108 dp)
backdrop(S).save(OUT / "adaptive_background.png", optimize=True)
fg = placed(S, TIPS_DP / 108 * S)
fg.save(OUT / "adaptive_foreground.png", optimize=True)

# --- icon.png: what a launcher shows of the adaptive icon, full bleed (72 dp)
icon = backdrop(S, 72 / 108).convert("RGBA")
icon.alpha_composite(placed(S, TIPS_DP / 72 * S))
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

# --- monochrome: the logo's silhouette (mark and triangle)
mono = Image.merge("LA", (Image.new("L", (S, S), 255), fg.getchannel("A")))
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
    canvas.alpha_composite(layer_fg)
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
