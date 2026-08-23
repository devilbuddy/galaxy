#!/usr/bin/env python3
"""Offline render of a generated galaxy.

A design sketch, not the game renderer: it exists so generation and the visual
treatment can be judged without an engine build in the loop. The layer order
here is the spec the Defold renderer follows:

    background -> region wash -> lanes -> star glow (additive) -> cores -> labels
"""
import json, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

BG = np.array([0.026, 0.030, 0.055])
FONT_PATH = "/System/Library/Fonts/Supplemental/Futura.ttc"


def font(sz):
    try:
        return ImageFont.truetype(FONT_PATH, sz)
    except Exception:
        return ImageFont.load_default()


def _mask(size, draw_fn, blur=0.0):
    """Rasterise into a float [0,1] single-channel array."""
    im = Image.new("L", (size, size), 0)
    draw_fn(ImageDraw.Draw(im))
    if blur > 0:
        im = im.filter(ImageFilter.GaussianBlur(blur))
    return np.asarray(im, dtype=np.float32) / 255.0


def render(data, size=1200, labels=True):
    world = data["world"]
    scale = size / world
    half = size / 2

    def px(x, y):
        return (x * scale + half, half - y * scale)

    stars = data["stars"]
    regions = data["regions"]
    buf = np.tile(BG.astype(np.float32), (size, size, 1))

    # --- region wash ------------------------------------------------------
    # One soft disc per star, accumulated per region then blurred, so the
    # overlaps merge into an organic territory outline instead of a circle.
    by_region = {}
    for s in stars:
        by_region.setdefault(s["region"], []).append(s)

    blob_r = size * 0.026
    for rid in sorted(by_region):
        pts = by_region[rid]

        def draw(d, pts=pts):
            for s in pts:
                x, y = px(s["x"], s["y"])
                d.ellipse([x - blob_r, y - blob_r, x + blob_r, y + blob_r], fill=255)

        m = _mask(size, draw, blur=size * 0.020)
        # Gamma sharpens the falloff into something with a readable edge.
        a = np.clip(m, 0, 1) ** 0.85 * 0.30
        col = np.array(regions[rid - 1]["colour"], dtype=np.float32)
        buf += (col - buf) * a[..., None]

    # --- lanes ------------------------------------------------------------
    # Drawn per colour group so each region's lanes keep its tint, with border
    # lanes a neutral grey to mark the chokepoints between territories.
    groups = {}
    lw = max(1, int(round(size / 1100)))
    for l in data["lanes"]:
        a, b = stars[l["a"] - 1], stars[l["b"] - 1]
        if l["border"]:
            key = (0.46, 0.50, 0.62, 0.55)
        else:
            c = regions[a["region"] - 1]["colour"]
            key = (min(1, c[0] * 1.5 + 0.22), min(1, c[1] * 1.5 + 0.24),
                   min(1, c[2] * 1.5 + 0.30), 0.75)
        groups.setdefault(key, []).append((px(a["x"], a["y"]), px(b["x"], b["y"])))

    for key, segs in sorted(groups.items()):
        def draw(d, segs=segs):
            for pa, pb in segs:
                d.line([pa, pb], fill=255, width=lw)

        m = _mask(size, draw)
        col = np.array(key[:3], dtype=np.float32)
        a = m * key[3]
        buf += (col - buf) * a[..., None]

    # --- star glow (additive) --------------------------------------------
    # Two tight passes: a small bright halo and a wider faint one. Kept small
    # deliberately - a large glow per star merges the whole field into milk.
    for spread, gain, rmul in ((0.0045, 0.55, 1.9), (0.011, 0.22, 3.4)):
        acc = np.zeros((size, size, 3), dtype=np.float32)
        by_colour = {}
        for s in stars:
            c = tuple(round(v, 2) for v in s["c"])
            by_colour.setdefault(c, []).append(s)
        for c, group in sorted(by_colour.items()):
            def draw(d, group=group):
                for s in group:
                    x, y = px(s["x"], s["y"])
                    gr = size * 0.0016 * s["r"] * rmul * (0.7 + 0.5 * s["glow"])
                    d.ellipse([x - gr, y - gr, x + gr, y + gr], fill=255)

            m = _mask(size, draw, blur=size * spread)
            acc += m[..., None] * np.array(c, dtype=np.float32)
        buf += acc * gain

    # --- cores ------------------------------------------------------------
    by_colour = {}
    for s in stars:
        by_colour.setdefault(tuple(round(v, 2) for v in s["c"]), []).append(s)
    for c, group in sorted(by_colour.items()):
        def draw(d, group=group):
            for s in group:
                x, y = px(s["x"], s["y"])
                cr = size * 0.0021 * s["r"] * 1.35
                d.ellipse([x - cr, y - cr, x + cr, y + cr], fill=255)

        m = _mask(size, draw)
        # Cores read as near-white with a tint, the way a bright source does.
        col = np.clip(np.array(c, dtype=np.float32) * 0.45 + 0.62, 0, 1)
        buf += (col - buf) * m[..., None]

    img = Image.fromarray((np.clip(buf, 0, 1) ** (1 / 1.05) * 255).astype(np.uint8))

    # --- labels -----------------------------------------------------------
    if labels:
        d = ImageDraw.Draw(img)
        f_star = font(int(size * 0.0098))
        f_reg = font(int(size * 0.019))
        # Greedy overlap rejection, biggest stars first: matches what the game
        # does at runtime, where label budget is limited by screen space.
        placed = []
        for s in sorted(stars, key=lambda s: -s["r"]):
            x, y = px(s["x"], s["y"])
            tw = d.textlength(s["name"], font=f_star)
            box = (x + size * 0.005, y - size * 0.008, x + size * 0.005 + tw, y + size * 0.006)
            if any(not (box[2] < p[0] or box[0] > p[2] or box[3] < p[1] or box[1] > p[3])
                   for p in placed):
                continue
            placed.append(box)
            d.text((box[0], box[1]), s["name"], font=f_star, fill=(188, 200, 228))
            if len(placed) > 70:
                break
        for r in regions:
            x, y = px(r["cx"], r["cy"])
            t = r["name"].upper()
            tw = d.textlength(t, font=f_reg)
            col = tuple(min(255, int(255 * (c * 0.45 + 0.55))) for c in r["colour"])
            d.text((x - tw / 2, y - size * 0.011), t, font=f_reg, fill=col)
    return img


if __name__ == "__main__":
    render(json.load(open(sys.argv[1]))).save(sys.argv[2])
    print(sys.argv[2])
