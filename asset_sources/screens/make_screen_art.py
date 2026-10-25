"""Cut TrekPay's screen artwork (Delta on the welcome and add wallet
screens) out of its dark background and export density variants for
Flutter.

Same matting as ../persona/make_persona_assets.py: alpha = max(AI matte,
colour key against the backdrop), colour-keyed pixels decontaminated.
The backdrop here is a gradient (navy at the corners, purple behind
Delta), so each pixel is keyed against a smooth estimate of the backdrop
around it rather than one colour.
Each image is cropped to its content (keeping its aspect ratio) and
scaled to fit a BASE x BASE logical box at 1x.

Usage (needs `pip install "rembg[cpu]" pillow numpy scipy`):

    python make_screen_art.py <src dir> <out dir>

<src dir> holds welcome.jpeg and wallet_create.jpeg (Graphics/Mascot);
<out dir>/assets/ goes to assets/persona/ and <out dir>/full/ to
asset_sources/screens/.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from rembg import new_session, remove
from scipy import ndimage

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
BASE = 280
DENSITIES = {"": 1.0, "1.5x": 1.5, "2.0x": 2.0, "3.0x": 3.0, "4.0x": 4.0}
BLOCK = 32

session = new_session("birefnet-general")

JOBS = [
    ("delta_welcome", "welcome.jpeg"),
    ("delta_add_wallet", "wallet_create.jpeg"),
]


def backdrop(rgb, ai):
    """The backdrop colour at every pixel: the median of each block's
    backdrop pixels (sparkles don't move it), filled in under Delta from
    the blocks around, smoothed and scaled back up."""
    h, w, _ = rgb.shape
    free = ndimage.binary_erosion(ai < 0.02, iterations=BLOCK // 2)
    gh, gw = h // BLOCK, w // BLOCK
    grid = np.zeros((gh, gw, 3), np.float32)
    valid = np.zeros((gh, gw), bool)
    for y in range(gh):
        for x in range(gw):
            sl = np.s_[y * BLOCK:(y + 1) * BLOCK, x * BLOCK:(x + 1) * BLOCK]
            if free[sl].mean() > 0.5:
                grid[y, x] = np.median(rgb[sl][free[sl]], axis=0)
                valid[y, x] = True
    # A block far off its neighbours is a glow the matte missed.
    near = np.where(valid[..., None], grid, np.nan)
    near = np.stack([ndimage.generic_filter(near[..., c], np.nanmedian, size=7,
                                            mode="nearest") for c in range(3)], axis=2)
    valid &= np.linalg.norm(grid - near, axis=2) < 25
    # Fill the gaps from the nearest blocks first, then from further away.
    for s in (2, 4, 8, 16):
        wsum = ndimage.gaussian_filter(valid.astype(np.float32), s)
        est = ndimage.gaussian_filter(grid * valid[..., None], (s, s, 0))
        todo = ~valid & (wsum > 1e-3)
        grid[todo] = est[todo] / wsum[todo][:, None]
        valid |= todo
    grid = ndimage.gaussian_filter(grid, (1, 1, 0))
    return ndimage.zoom(grid, (h / gh, w / gw, 1), order=3)[:h, :w]


def cut(path: Path):
    img = Image.open(path).convert("RGB")
    rgb = np.asarray(img).astype(np.float32)

    ai = np.asarray(remove(img, session=session, only_mask=True)).astype(np.float32) / 255
    bg = backdrop(rgb, ai)
    dist = np.linalg.norm(rgb - bg, axis=2)
    t0, t1 = 14.0, 70.0
    ck = np.clip((dist - t0) / (t1 - t0), 0, 1)
    # The matte only near what it's sure of (holes filled: keyholes stay
    # solid). Its faint haze around the glows would keep the dark backdrop.
    sure = ndimage.binary_fill_holes(ai > 0.9)
    ai = np.where(ndimage.binary_dilation(sure, iterations=4),
                  np.clip((ai - 0.3) / 0.4, 0, 1), 0)

    alpha = np.maximum(ai, ck)
    a = np.clip(alpha, 1e-3, 1)[..., None]
    fg = np.clip((rgb - (1 - a) * bg) / a, 0, 255)
    out_rgb = np.where((ck > ai)[..., None], fg, rgb)
    alpha[alpha < 0.02] = 0

    # Crop to what is visible: rows/columns with a few clearly opaque
    # pixels (stray faint JPEG noise near the edges doesn't count), and
    # clear everything outside.
    solid = alpha > 0.25
    cols = np.nonzero(solid.sum(axis=0) >= 3)[0]
    rows = np.nonzero(solid.sum(axis=1) >= 3)[0]
    box = (cols.min(), rows.min(), cols.max() + 1, rows.max() + 1)
    print(path.name, "faint pixels outside the crop:",
          int((alpha > 0.03).sum() - (alpha[box[1]:box[3], box[0]:box[2]] > 0.03).sum()))
    keep = np.zeros_like(alpha)
    x0, y0, x1, y1 = box
    m = int(max(x1 - x0, y1 - y0) * 0.01)
    keep[max(y0 - m, 0):y1 + m, max(x0 - m, 0):x1 + m] = 1
    alpha *= keep
    rgba = np.dstack([out_rgb, alpha * 255]).round().astype(np.uint8)
    im = Image.fromarray(rgba, "RGBA")
    return im, box, bg


for name, src in JOBS:
    im, box, bg = cut(SRC / src)
    x0, y0, x1, y1 = box
    pad = int(max(x1 - x0, y1 - y0) * 0.01)
    content = im.crop((max(x0 - pad, 0), max(y0 - pad, 0),
                       min(x1 + pad, im.width), min(y1 + pad, im.height)))
    print(name, "backdrop", bg.min(axis=(0, 1)).round(), "to",
          bg.max(axis=(0, 1)).round(), "content", content.size)
    full = OUT / "full"
    full.mkdir(parents=True, exist_ok=True)
    content.save(full / f"{name}.png", optimize=True)
    cw, ch = content.size
    for folder, scale in DENSITIES.items():
        f = BASE * scale / max(cw, ch)
        size = (round(cw * f), round(ch * f))
        d = OUT / "assets" / folder
        d.mkdir(parents=True, exist_ok=True)
        content.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA").save(
            d / f"{name}.png", optimize=True)
    for tag, col in [("dark", (10, 4, 20)), ("oled", (0, 0, 0)), ("light", (245, 245, 247))]:
        pv = Image.new("RGBA", content.size, col + (255,))
        pv.alpha_composite(content)
        pv.convert("RGB").resize((cw * 600 // ch, 600), Image.LANCZOS).save(
            OUT / f"preview_{name}_{tag}.png")

# The send animation (assets/persona/delta_tx_send.webp) is the artwork
# video Graphics/Mascot/delta_final_animation.mp4 as a looping animated
# WebP, so Image.asset plays it on every platform without a video plugin.
# Its sound is the video's audio cut to one loop, with a short fade:
#   ffmpeg -i delta_final_animation.mp4 -an \
#     -vf "fps=24,scale=960:-2:flags=lanczos" \
#     -c:v libwebp -q:v 72 -compression_level 6 -loop 0 delta_tx_send.webp
#   ffmpeg -i delta_final_animation.mp4 -vn -t 5.04 \
#     -af "afade=t=out:st=4.99:d=0.05" -c:a aac -b:a 128k \
#     -movflags +faststart delta_tx_send.m4a
