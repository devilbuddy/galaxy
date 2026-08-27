#!/usr/bin/env python3
"""Offline render of a generated galaxy, in the emoji theme.

A design sketch, not the game renderer: it exists so generation and the visual
treatment can be judged without an engine build in the loop. The layer order
here is the spec the Defold renderer follows:

    parchment -> region wash -> dotted lanes -> shadows -> emoji -> labels

Systems are drawn as Google Noto color emoji, resolved by main/theme.lua and
carried in the JSON (`stars[].emoji` naming into the top-level `emoji` table of
codepoints). Glyphs are downloaded on demand into build/emoji_cache/ (gitignored),
pinned to NOTO_REF. Star sizes use the same CORE_SCALE x KIND_SCALE maths as
main/galaxy.script, so a size approved here transfers to the engine 1:1.

Usage: render_map.py map.json out.png [detail]
  detail  render at 3x and crop the central third - roughly the game's
          mid-zoom, for judging glyphs at play scale.
"""
import functools, json, os, sys, urllib.request
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

NOTO_REF = "v2.047"
NOTO_URL = "https://raw.githubusercontent.com/googlefonts/noto-emoji/%s/png/512/emoji_u%s.png"
CACHE = os.path.join(os.path.dirname(__file__), "..", "build", "emoji_cache")
FONT_PATH = "/System/Library/Fonts/Supplemental/Futura.ttc"

# The parchment ground. The engine's clear colour and the regenerated backdrop
# texture both come from these numbers (see the plan in CLAUDE.md's rendering
# section once landed).
PARCHMENT = np.array([0.935, 0.870, 0.745])
MOTTLE = np.array([0.860, 0.765, 0.590])
SHADOW = np.array([0.25, 0.19, 0.11])
INK = (58, 52, 40)
# Two lane inks only: interior sepia, border slate. Region-tinted lanes turn a
# light map into spaghetti; border-vs-interior is the strategic distinction.
LANE_INK = ((0.45, 0.36, 0.24), 0.55)
LANE_BORDER = ((0.35, 0.36, 0.42), 0.50)

# Mirrors main/galaxy.script's sizing so approved constants transfer 1:1:
# half-extent (world units) = CORE_SCALE * world * kind_scale * (0.85 + 0.3*r).
CORE_SCALE = 0.0034
KIND_SCALE = {"colony": 1.45, "outpost": 1.15, "waypoint": 0.70}
CAPITAL_SCALE = 1.9
DOT_SPACING = 0.006  # of world size, between lane dots


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


def _glyph_path(codepoint):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, "emoji_u%s.png" % codepoint)
    if not os.path.exists(path):
        url = NOTO_URL % (NOTO_REF, codepoint)
        urllib.request.urlretrieve(url, path)
    return path


@functools.lru_cache(maxsize=512)
def _glyph(codepoint, px):
    im = Image.open(_glyph_path(codepoint)).convert("RGBA")
    return im.resize((px, px), Image.LANCZOS)


def star_half_wu(s, world):
    """Half-extent in world units - the same maths the engine will use."""
    scale = CAPITAL_SCALE if s["emoji"] == "capital" else KIND_SCALE[s["kind"]]
    return CORE_SCALE * world * scale * (0.85 + 0.3 * s["r"])


# The bow's amplitude, as a signed fraction of the lane's length. A pure
# function of the endpoint indices - portable to Lua verbatim (no bit ops, no
# floats in the hash) - so sketch and engine draw the same curve.
def lane_bulge(ia, ib):
    h = (ia * 7919 + ib * 104729) % 997
    return (h / 997.0 - 0.5) * 0.14


def lane_dots(ia, ib, pa, pb, spacing):
    """Dot centres along the lane's bezier, one per `spacing` of arc length."""
    mx, my = (pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2
    dx, dy = pb[0] - pa[0], pb[1] - pa[1]
    dist = (dx * dx + dy * dy) ** 0.5
    if dist < 1e-6:
        return []
    # Control point: midpoint pushed out along the perpendicular.
    amp = lane_bulge(ia, ib) * dist
    cx, cy = mx - dy / dist * amp, my + dx / dist * amp

    def at(t):
        u = 1 - t
        return (u * u * pa[0] + 2 * u * t * cx + t * t * pb[0],
                u * u * pa[1] + 2 * u * t * cy + t * t * pb[1])

    # Walk the curve at fine steps, dropping a dot each `spacing` of arc,
    # inset half a step from each end so no dot peeks out from under a glyph.
    steps = max(8, int(dist / 3))
    pts, acc, nxt = [], 0.0, spacing * 0.5
    lx, ly = at(0)
    for i in range(1, steps + 1):
        x, y = at(i / steps)
        acc += ((x - lx) ** 2 + (y - ly) ** 2) ** 0.5
        while acc >= nxt:
            pts.append((x, y))
            nxt += spacing
        lx, ly = x, y
    return pts


def render(data, size=1400, labels=True):
    world = data["world"]
    scale = size / world
    half = size / 2
    codepoints = data["emoji"]

    def px(x, y):
        return (x * scale + half, half - y * scale)

    stars = data["stars"]
    regions = data["regions"]

    # --- parchment ----------------------------------------------------------
    # A flat base with two octaves of blurred mottle, seeded from the map seed
    # so a given galaxy always sketches identically. The engine gets the same
    # treatment as a texture over a clear colour that IS the base.
    buf = np.tile(PARCHMENT.astype(np.float32), (size, size, 1))
    rng = np.random.default_rng(data["seed"])
    for cells, strength in ((12, 0.34), (48, 0.14), (160, 0.06)):
        n = rng.random((cells, cells))
        m = Image.fromarray((n * 255).astype(np.uint8)).resize((size, size), Image.BICUBIC)
        m = np.asarray(m, dtype=np.float32) / 255.0
        a = np.clip(m - 0.45, 0, 1) * strength
        buf += (MOTTLE - buf) * a[..., None]

    # --- region wash --------------------------------------------------------
    # One soft disc per star, accumulated per region then blurred, so the
    # overlaps merge into an organic territory outline. Tints darkened for the
    # light ground. (In a game the same layer shows ownership, saturated and
    # stronger, with a dotted ink border traced along the union - see
    # build_lanes in main/galaxy.script.)
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
        a = np.clip(m, 0, 1) ** 0.85 * 0.16
        col = np.array(regions[rid - 1]["colour"], dtype=np.float32) * 0.60 + 0.25
        buf += (col - buf) * a[..., None]

    # --- dotted lanes -------------------------------------------------------
    # Ink dots every DOT_SPACING of the world, along a gentle bow rather than a
    # ruler line - a hand-drawn path, not a circuit diagram. The bow is a
    # quadratic bezier whose bulge is a pure function of the lane's endpoint
    # indices, so the same seed always draws the same curves with no RNG
    # stream, and the engine reproduces it from the same formula. Amplitude is
    # kept small (<= ~7% of the lane) because captains and route previews are
    # positioned along the *straight* line; a marker must never sit visibly
    # off its own path.
    spacing = DOT_SPACING * world * scale
    dot_r = max(1.4, size * 0.0015)
    groups = {LANE_INK: [], LANE_BORDER: []}
    for l in data["lanes"]:
        a, b = stars[l["a"] - 1], stars[l["b"] - 1]
        pa, pb = px(a["x"], a["y"]), px(b["x"], b["y"])
        groups[LANE_BORDER if l["border"] else LANE_INK].append((l["a"], l["b"], pa, pb))

    for (col, alpha), segs in groups.items():
        def draw(d, segs=segs):
            for ia, ib, pa, pb in segs:
                for x, y in lane_dots(ia, ib, pa, pb, spacing):
                    d.ellipse([x - dot_r, y - dot_r, x + dot_r, y + dot_r], fill=255)

        m = _mask(size, draw)
        buf += (np.array(col, dtype=np.float32) - buf) * (m * alpha)[..., None]

    # --- shadows ------------------------------------------------------------
    # A soft dark ellipse under each glyph, offset down-right, is what makes
    # emoji read as stickers on paper rather than floating clip art.
    def draw(d):
        for s in stars:
            x, y = px(s["x"], s["y"])
            g = star_half_wu(s, world) * scale
            r = g * 1.15
            ox, oy = g * 0.16, g * 0.20
            d.ellipse([x - r + ox, y - r + oy, x + r + ox, y + r + oy], fill=255)

    m = _mask(size, draw, blur=size * 0.0035)
    buf += (SHADOW - buf) * (m * 0.30)[..., None]

    img = Image.fromarray(
        (np.clip(buf, 0, 1) ** (1 / 1.05) * 255).astype(np.uint8)).convert("RGBA")

    # --- emoji --------------------------------------------------------------
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    for s in stars:
        x, y = px(s["x"], s["y"])
        gpx = int(round(2 * star_half_wu(s, world) * scale))
        if gpx < 3:
            gpx = 3
        g = _glyph(codepoints[s["emoji"]], gpx)
        overlay.alpha_composite(g, (int(x - gpx / 2), int(y - gpx / 2)))
    img = Image.alpha_composite(img, overlay)

    # --- labels -------------------------------------------------------------
    if labels:
        d = ImageDraw.Draw(img)
        f_star = font(int(size * 0.0098))
        f_reg = font(int(size * 0.019))
        # A name is not scenery (the game labels by relevance, capped at 22):
        # the sketch labels capitals plus a dozen or so of the largest
        # non-waypoint systems, with greedy overlap rejection. Naming all 220
        # is a wall of words with the map buried underneath.
        candidates = [s for s in stars if s["emoji"] == "capital"]
        majors = sorted((s for s in stars if s["kind"] != "waypoint"
                         and s["emoji"] != "capital"), key=lambda s: -s["r"])
        candidates += majors[:14]
        placed = []
        for s in candidates:
            x, y = px(s["x"], s["y"])
            tw = d.textlength(s["name"], font=f_star)
            box = (x + size * 0.006, y - size * 0.008, x + size * 0.006 + tw, y + size * 0.006)
            if any(not (box[2] < p[0] or box[0] > p[2] or box[3] < p[1] or box[1] > p[3])
                   for p in placed):
                continue
            placed.append(box)
            d.text((box[0], box[1]), s["name"], font=f_star, fill=INK)
        for r in regions:
            x, y = px(r["cx"], r["cy"])
            t = r["name"].upper()
            tw = d.textlength(t, font=f_reg)
            col = tuple(int(255 * c * 0.55) for c in r["colour"])
            d.text((x - tw / 2, y - size * 0.011), t, font=f_reg, fill=col)
    return img.convert("RGB")


if __name__ == "__main__":
    data = json.load(open(sys.argv[1]))
    if len(sys.argv) > 3 and sys.argv[3] == "detail":
        big = 4200
        img = render(data, size=big)
        third = big // 3
        img = img.crop((third, third, 2 * third, 2 * third))
    else:
        img = render(data)
    img.save(sys.argv[2])
    print(sys.argv[2])
