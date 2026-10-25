"""Export the "Fuel Delta" donation art for assets/donation/.

The sources are one 2048 x 2048 picture per tier and style, already cut
out (graphics/Kerrigan/Donation, see delta_mascot_progression_states.md
there): dark_* is the shielded Delta (paid from the shielded balance),
light_* the transparent one; *_custom_* is the custom amount, *_success_*
the screen after a donation. Each is trimmed to what it shows, put in a
square with the figure on the bottom edge and scaled to 1024 px.

Usage (needs `pip install pillow numpy`):

    python make_donation_assets.py <source dir> <out dir>

<out dir>/assets/*.webp go to assets/donation/; <out dir>/preview_*.png
show them on the screen's stage colours.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
(OUT / "assets").mkdir(parents=True, exist_ok=True)

# The stage shows Delta at up to 215 logical px: 1024 px stays sharp up
# to 4.7x.
SIDE = 1024

# Asset name: source name without the style prefix.
TIERS = {
    "private": {
        "t1": "01_1usd_tiny_shield",
        "t5": "02_5usd_shield_cell",
        "t10": "03_10usd_cyber_node",
        "t20": "04_20usd_zero_knowledge_aegis",
        "t50": "05_50usd_quantum_aegis",
        "t100": "06_100usd_stealth_flight",
        "custom": "07_custom_infinite_citadel",
        "thanks": "08_success_thanks",
    },
    "public": {
        "t1": "01_1usd_tiny_spark",
        "t5": "02_5usd_power_cell",
        "t10": "03_10usd_cyber_console",
        "t20": "04_20usd_quantum_hyperdrive",
        "t50": "05_50usd_cosmic_surge",
        "t100": "06_100usd_astro_flight",
        "custom": "07_custom_limitless_nova",
        "thanks": "08_success_thank_you",
    },
}
PREFIX = {"private": "dark", "public": "light"}
# Stage backdrops of the donation screen, for the previews.
STAGES = {"private": (26, 16, 51), "public": (16, 30, 58)}


def trim(img: Image.Image) -> Image.Image:
    alpha = np.asarray(img.getchannel("A"))
    ys, xs = np.nonzero(alpha > 8)
    return img.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def square(content: Image.Image) -> Image.Image:
    w, h = content.size
    side = int(max(w, h) * 1.02)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    # Figures stand on the bottom edge of the box.
    sq.paste(content, ((side - w) // 2, side - h - (side - max(w, h)) // 2))
    if side > SIDE:
        sq = sq.convert("RGBa").resize((SIDE, SIDE), Image.LANCZOS).convert("RGBA")
    return sq


for style, tiers in TIERS.items():
    previews = []
    for name, source in tiers.items():
        src = Image.open(SRC / f"{PREFIX[style]}_{source}.png").convert("RGBA")
        sq = square(trim(src))
        sq.save(OUT / "assets" / f"{style}_{name}.webp", quality=90, method=6)
        print(style, name, sq.size)
        pv = Image.new("RGBA", sq.size, STAGES[style] + (255,))
        pv.alpha_composite(sq)
        previews.append(pv.convert("RGB").resize((300, 300), Image.LANCZOS))
    sheet = Image.new("RGB", (300 * len(previews), 300))
    for i, pv in enumerate(previews):
        sheet.paste(pv, (300 * i, 0))
    sheet.save(OUT / f"preview_{style}.png")
