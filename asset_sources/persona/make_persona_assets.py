"""Cut the two Delta mascots out of the mascot sheet
(graphics/Kerrigan/Mascot/Gemini_Generated_Image_k508fxk508fxk508.jpeg:
the light, transparent Delta on the left, the dark, shielded one on the
right, on a navy grid) and export density variants for Flutter
(1x = 140 logical px).

The sheet's backdrop is a grid with glows, so only the AI matte
(BiRefNet) decides: a colour key would keep the grid lines. The light
Delta's left hand floats apart from it and the matte of the whole figure
drops it: a matte of just the hand's box is added.

Usage (needs `pip install "rembg[cpu]" pillow numpy`; downloads the
BiRefNet model once):

    python make_persona_assets.py <mascot sheet> <out dir>

<out dir>/assets/ then goes to assets/persona/ and <out dir>/full/ to
asset_sources/persona/.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from rembg import new_session, remove

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
BASE = 140
DENSITIES = {"": 1.0, "1.5x": 1.5, "2.0x": 2.0, "3.0x": 3.0, "4.0x": 4.0}

# Each Delta's box on the 2752 x 1536 sheet, clear of the title and the
# captions under them.
BOXES = {
    "delta_public": (130, 300, 1290, 1400),
    "delta_private": (1450, 230, 2680, 1400),
}

# Boxes (in the figure's box) whose own matte is added.
EXTRA = {"delta_public": [(70, 380, 280, 600)]}

session = new_session("birefnet-general")
sheet = Image.open(SRC).convert("RGB")
assert sheet.size == (2752, 1536), sheet.size


def matte(img: Image.Image) -> np.ndarray:
    return np.asarray(remove(img, session=session, only_mask=True)).astype(np.float32) / 255


def cut(img: Image.Image, extra) -> Image.Image:
    rgb = np.asarray(img).astype(np.float32)
    ai = matte(img)
    for x0, y0, x1, y1 in extra:
        part = ai[y0:y1, x0:x1]
        ai[y0:y1, x0:x1] = np.maximum(part, matte(img.crop((x0, y0, x1, y1))))
    # Harden the matte: its soft tail over the backdrop is haze.
    alpha = np.clip((ai - 0.3) / 0.4, 0, 1)
    alpha[alpha < 0.02] = 0
    im = Image.fromarray(np.dstack([rgb, alpha * 255]).round().astype(np.uint8), "RGBA")
    ys, xs = np.nonzero(alpha > 0.03)
    return im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def square(content: Image.Image) -> Image.Image:
    w, h = content.size
    side = int(max(w, h) * 1.02)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(content, ((side - w) // 2, (side - h) // 2))
    return sq


for name, box in BOXES.items():
    sq = square(cut(sheet.crop(box), EXTRA.get(name, [])))
    print(name, "square", sq.size)
    full = OUT / "full"
    full.mkdir(parents=True, exist_ok=True)
    sq.save(full / f"{name}.png", optimize=True)
    for folder, scale in DENSITIES.items():
        px = round(BASE * scale)
        d = OUT / "assets" / folder
        d.mkdir(parents=True, exist_ok=True)
        small = sq.convert("RGBa").resize((px, px), Image.LANCZOS).convert("RGBA")
        small.save(d / f"{name}.png", optimize=True)
    # Previews on light and dark cards.
    for tag, col in [("dark", (32, 26, 52)), ("light", (245, 245, 247))]:
        pv = Image.new("RGBA", sq.size, col + (255,))
        pv.alpha_composite(sq)
        pv.convert("RGB").resize((500, 500), Image.LANCZOS).save(OUT / f"preview_{name}_{tag}.png")
