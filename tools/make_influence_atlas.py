#!/usr/bin/env python3
"""Generate every non-empty six-edge political influence mask.

The output is deliberately parameter art: change the stroke here, regenerate,
and commit the PNGs and atlas together. Each 238x207 image matches a terrain
tile exactly, and contains white premultiplied-at-build-time line art for the
sprite tint to colour per player.

Run:
    python3 tools/make_influence_atlas.py
    python3 tools/make_influence_atlas.py --check
"""
import argparse
import io
import math
import os
import sys

from PIL import Image, ImageDraw


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_DIR = os.path.join(ROOT, "main", "assets", "influence")
ATLAS = os.path.join(ROOT, "main", "influence.atlas")

WIDTH, HEIGHT = 238, 207
STROKE = 8
INSET = 6
MASKS = range(1, 64)


def name(mask):
    return "influence_%02d" % mask


def inset_vertices():
    """Flat-top hex vertices, shifted INSET pixels towards the centre."""
    cx, cy = WIDTH / 2.0, HEIGHT / 2.0
    # The regular hex's apothem is sqrt(3)/2 times its 119px radius. The source
    # art rounds its ideal 206.114px height up to 207, so scale the ideal shape
    # about the actual image centre rather than accumulating that rounding on
    # one edge.
    apothem = math.sqrt(3.0) * (WIDTH / 2.0) / 2.0
    scale = (apothem - INSET) / apothem
    raw = [
        (WIDTH, cy), (WIDTH * 0.75, 0), (WIDTH * 0.25, 0),
        (0, cy), (WIDTH * 0.25, HEIGHT), (WIDTH * 0.75, HEIGHT),
    ]
    return [(cx + (x - cx) * scale, cy + (y - cy) * scale) for x, y in raw]


# Direction order matches realm.hex.DIRECTIONS. Image y points down, so the
# positive-world-y edges are at the top of the PNG.
EDGE_VERTICES = ((1, 0), (0, 5), (5, 4), (4, 3), (3, 2), (2, 1))


def png_bytes(mask):
    image = Image.new("RGBA", (WIDTH, HEIGHT), (255, 255, 255, 0))
    draw = ImageDraw.Draw(image)
    vertices = inset_vertices()
    radius = STROKE / 2.0
    for edge, (a, b) in enumerate(EDGE_VERTICES):
        if mask % (2 ** (edge + 1)) >= 2 ** edge:
            p0, p1 = vertices[a], vertices[b]
            draw.line((p0, p1), fill=(255, 255, 255, 255), width=STROKE)
            # ImageDraw's two-point line has square ends. Rounding every end is
            # also what joins adjacent selected sides without a hairline crack.
            for x, y in (p0, p1):
                draw.ellipse((x - radius, y - radius, x + radius, y + radius),
                             fill=(255, 255, 255, 255))
    out = io.BytesIO()
    image.save(out, "PNG", compress_level=9)
    return out.getvalue()


def atlas_text():
    blocks = [
        'images {\n  image: "/main/assets/influence/%s.png"\n'
        '  sprite_trim_mode: SPRITE_TRIM_MODE_OFF\n}' % name(mask)
        for mask in MASKS
    ]
    return "\n".join(blocks) + "\nmargin: 4\nextrude_borders: 4\ninner_padding: 0\n"


def check():
    failures = []
    generated = []
    for mask in MASKS:
        expected = png_bytes(mask)
        generated.append(expected)
        path = os.path.join(OUT_DIR, name(mask) + ".png")
        try:
            with open(path, "rb") as source:
                actual = source.read()
        except FileNotFoundError:
            failures.append("missing %s" % path)
            continue
        if actual != expected:
            failures.append("stale %s" % path)
    if len(set(generated)) != 63:
        failures.append("two masks generated identical PNG data")
    try:
        with open(ATLAS) as source:
            actual_atlas = source.read()
    except FileNotFoundError:
        actual_atlas = ""
    if actual_atlas != atlas_text():
        failures.append("stale or missing %s" % ATLAS)
    if failures:
        sys.exit("make_influence_atlas --check:\n  " + "\n  ".join(failures))
    print("influence atlas: deterministic and current (63 masks)")


def generate():
    os.makedirs(OUT_DIR, exist_ok=True)
    wanted = set()
    for mask in MASKS:
        filename = name(mask) + ".png"
        wanted.add(filename)
        with open(os.path.join(OUT_DIR, filename), "wb") as out:
            out.write(png_bytes(mask))
    for filename in os.listdir(OUT_DIR):
        if filename.endswith(".png") and filename not in wanted:
            os.remove(os.path.join(OUT_DIR, filename))
    with open(ATLAS, "w") as out:
        out.write(atlas_text())
    print("main/assets/influence/: 63 masks at %dx%d" % (WIDTH, HEIGHT))
    print("main/influence.atlas: 63 images")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="fail if committed output differs from a fresh generation")
    args = parser.parse_args()
    check() if args.check else generate()


if __name__ == "__main__":
    main()
