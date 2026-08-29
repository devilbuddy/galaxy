#!/usr/bin/env python3
"""Offline render of a generated map, in the hex-tile theme.

A design sketch, not the game renderer: it exists so generation and the visual
treatment can be judged without an engine build in the loop. The layer order
here is the spec the Defold renderer follows:

    sea hexes -> land hexes -> emoji glyphs -> labels

Both art layers use the *same names the engine resolves*, carried in the JSON by
tools/preview_map.lua from main/theme.lua - `tiles[].tile` into
main/assets/tiles/, `tiles[].emoji` into the Noto set. So this is a sketch of
the same decisions the renderer makes rather than a parallel guess at them, and
a look approved here transfers.

Glyphs are downloaded on demand into build/emoji_cache/ (gitignored), pinned to
NOTO_REF; tiles are read straight out of the repo.

Usage: render_map.py map.json out.png [detail]
  detail  render at 3x and crop the central third - roughly the game's
          mid-zoom, for judging glyphs at play scale.
"""
import functools, json, math, os, sys, urllib.request
from PIL import Image, ImageDraw, ImageFont

NOTO_REF = "v2.047"
NOTO_URL = "https://raw.githubusercontent.com/googlefonts/noto-emoji/%s/png/512/emoji_u%s.png"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CACHE = os.path.join(ROOT, "build", "emoji_cache")
TILE_DIR = os.path.join(ROOT, "main", "assets", "tiles")
FONT_PATH = "/Tile/Library/Fonts/Supplemental/Futura.ttc"

# The paper the hexes sit on. Mirrors game.project's [render] clear colour, which
# is the only backdrop the map has now - the parchment mottle mesh went with the
# rest of the custom shaders.
PAPER = (239, 222, 190)
INK = (58, 52, 40)

# A tile PNG is 238x207: exactly the bounding box of a flat-top hexagon of size
# 119 (2s by sqrt(3)*s = 238 x 206.1, rounded up a pixel). Drawing it at that
# size at each hex centre is the whole tiling - see tools/test_hex.lua.
TILE_W, TILE_H = 238, 207
HEX_SIZE = TILE_W / 2.0

# Emoji size as a fraction of the tile width. A glyph has to read as sitting *on*
# the hex rather than covering it, and the hex's own art is the thing saying what
# the ground is.
EMOJI_SCALE = {"city": 0.46, "holding": 0.40, "wilds": 0.0}
SEAT_SCALE = 0.56


def font(sz):
    try:
        return ImageFont.truetype(FONT_PATH, sz)
    except Exception:
        return ImageFont.load_default()


def _glyph_path(codepoint):
    return os.path.join(CACHE, "emoji_u%s.png" % codepoint)


@functools.lru_cache(maxsize=None)
def glyph(codepoint, px):
    path = _glyph_path(codepoint)
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        url = NOTO_URL % (NOTO_REF, codepoint)
        sys.stderr.write("fetch %s\n" % url)
        with urllib.request.urlopen(url) as r:
            data = r.read()
        with open(path, "wb") as f:
            f.write(data)
    return Image.open(path).convert("RGBA").resize((px, px), Image.LANCZOS)


@functools.lru_cache(maxsize=None)
def tile(name, w, h):
    path = os.path.join(TILE_DIR, name + ".png")
    if not os.path.exists(path):
        sys.exit("render_map: no tile %s (run tools/import_tiles.py)" % path)
    return Image.open(path).convert("RGBA").resize((w, h), Image.LANCZOS)


def render(data, size=1500, labels=True):
    tiles = data["tiles"]
    water = data["water"]
    emoji_cp = data["emoji"]
    sea_name = data["sea_tile"]
    hex_size = data["hex_size"]

    # Frame the whole field - land and sea - so the continent sits in its ocean
    # rather than being cropped to its own bounding box.
    xs = [t["x"] for t in tiles] + [w["x"] for w in water]
    ys = [t["y"] for t in tiles] + [w["y"] for w in water]
    pad = hex_size * 1.2
    minx, maxx = min(xs) - pad, max(xs) + pad
    miny, maxy = min(ys) - pad, max(ys) + pad

    scale = size / (maxx - minx)
    height = int((maxy - miny) * scale)
    img = Image.new("RGBA", (size, height), PAPER + (255,))

    # World units per tile-pixel, so a hex drawn at `tw` covers exactly the
    # ground its neighbours leave for it.
    tw = max(2, int(round(2 * hex_size * scale)))
    th = max(2, int(round(tw * TILE_H / float(TILE_W))))

    def place(x, y):
        """Top-left pixel for a tile centred on world (x, y). Y flips: world y
        is up, image y is down."""
        px = (x - minx) * scale
        py = (maxy - y) * scale
        return int(round(px - tw / 2.0)), int(round(py - th / 2.0))

    # Sea first, then land: a land hex's transparent corners fall on sea, which
    # is exactly the overlap the tiling depends on.
    sea = tile(sea_name, tw, th)
    for w in water:
        img.alpha_composite(sea, place(w["x"], w["y"]))
    for t in tiles:
        img.alpha_composite(tile(t["tile"], tw, th), place(t["x"], t["y"]))

    # Glyphs on top. Open country resolves to null and gets nothing.
    for t in tiles:
        name = t.get("emoji")
        if not name:
            continue
        cp = emoji_cp.get(name)
        if not cp:
            sys.exit("render_map: theme named %r with no codepoint" % name)
        frac = SEAT_SCALE if t.get("seat") else EMOJI_SCALE.get(t["kind"], 0.40)
        px = max(4, int(round(tw * frac)))
        gx, gy = place(t["x"], t["y"])
        img.alpha_composite(glyph(cp, px),
                            (gx + (tw - px) // 2, gy + (th - px) // 2))

    if labels:
        draw = ImageDraw.Draw(img)
        fnt = font(max(9, int(tw * 0.13)))
        # Only places worth naming, same rule the HUD uses: a seat, a city,
        # a holding. Naming open country is what turned the old map into a wall
        # of words with the geography buried underneath.
        for t in tiles:
            if not t.get("seat") and t["kind"] == "wilds":
                continue
            gx, gy = place(t["x"], t["y"])
            cx = gx + tw / 2.0
            ty = gy + th * 0.80
            w = draw.textlength(t["name"], font=fnt)
            draw.text((cx - w / 2.0 + 1, ty + 1), t["name"], font=fnt,
                      fill=(255, 255, 255, 170))
            draw.text((cx - w / 2.0, ty), t["name"], font=fnt, fill=INK + (255,))

    return img.convert("RGB")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    data = json.load(open(sys.argv[1]))
    detail = len(sys.argv) > 3 and sys.argv[3] == "detail"
    img = render(data, size=4500 if detail else 1500, labels=True)
    if detail:
        w, h = img.size
        img = img.crop((w // 3, h // 3, 2 * w // 3, 2 * h // 3))
    img.save(sys.argv[2])
    print("%s  %dx%d" % (sys.argv[2], img.size[0], img.size[1]))


if __name__ == "__main__":
    main()
