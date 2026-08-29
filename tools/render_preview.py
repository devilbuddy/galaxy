#!/usr/bin/env python3
"""Render a dumped realm JSON to a PNG, for eyeballing generation offline."""
import json, sys, math
from PIL import Image, ImageDraw, ImageFilter

def render(path, out, size=900):
    d = json.load(open(path))
    pts = d["points"]
    img = Image.new("RGB", (size, size), (6, 7, 14))
    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    dr = ImageDraw.Draw(img)

    def to_px(p):
        return ((p["x"] * 0.5 + 0.5) * size, (1.0 - (p["y"] * 0.5 + 0.5)) * size)

    # tiles underneath, if present
    for e in d.get("tiles", []):
        a, b = to_px(pts[e[0] - 1]), to_px(pts[e[1] - 1])
        dr.line([a, b], fill=(58, 74, 120), width=1)

    for p in pts:
        x, y = to_px(p)
        gd.ellipse([x - 5, y - 5, x + 5, y + 5], fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(6))
    img = Image.composite(Image.new("RGB", (size, size), (120, 140, 220)), img, glow)

    dr = ImageDraw.Draw(img)
    for p in pts:
        x, y = to_px(p)
        dr.ellipse([x - 2.2, y - 2.2, x + 2.2, y + 2.2], fill=(255, 226, 168))
    img.save(out)
    return len(pts)

if __name__ == "__main__":
    n = render(sys.argv[1], sys.argv[2])
    print(f"{sys.argv[2]}: {n} points")
