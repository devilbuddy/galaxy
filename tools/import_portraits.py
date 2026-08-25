#!/usr/bin/env python3
"""Import commander portraits from a source set into the project, by race.

Unlike make_textures.py and make_ui_textures.py, this is **not** a regeneration
step: the output is third-party art, not something derived from parameters in
this file. It exists so the provenance of what is in main/assets/portraits/ is
recorded and reproducible - which of the source images were taken, at what size,
and in what order.

**Portraits are grouped by race.** The source set is not labelled, but it is
drawn in species: crimson devils, green orc-folk, violet tentacled things,
cyan ice-people, gold-armoured nobles, blue-uniformed soldiers. Every one of the
six races in galaxy/sim/races.lua already declares a colour, and they land on
those groups almost exactly - so the grouping is done by measuring each image's
dominant hue rather than by classifying five hundred pictures by hand.

    terran    blue      uniformed, armoured humanoids - a navy
    vorn      red       devils and revenants
    ashai     green     orc and plant folk
    kepler    violet    tentacled, scholarly, strange
    cartel    gold      ornate and flashy
    silicate  cyan      ice and glass

Two things are traded off inside a band, and both matter:

  * **fit** - how much of the subject is actually the band's hue, so a race
    reads as one species rather than a colour-wash;
  * **variety** - the source is ordered by character with several variants of
    each in a row, so the best-fitting dozen are usually one person twelve
    times. Picks are therefore kept a minimum id apart.

The order is what matters. A commander's portrait is chosen by their race plus
the same index as their surname (galaxy/sim/commanders.lua), so the nth officer
a player of a given race raises always has both the same name and the same face.
Changing the bands, the count, or the tie-breaks silently reassigns every
existing commander's portrait - the manifest written alongside the images is
what records the set that is actually in the repository.

Usage:
    python3 tools/import_portraits.py ~/Downloads/PORTRAITS
"""

import json
import os
import sys
from collections import deque, Counter
import colorsys

from PIL import Image, ImageDraw

# Per race. Not one per surname any more: with six races that would be 240
# images, and a player currently raises exactly one officer. Twelve is enough
# that a four-player game never repeats a face, and the index wraps past it.
PER_RACE = 12
# Design units are roughly 0.57dp, so a 72-unit portrait is ~113px on a 2.75x
# phone. 128 is the next sensible power of two above that.
SIZE = 128
SOURCE_COUNT = 500

# Hue window (degrees, wrapping) and the minimum average saturation to sit in
# it. Gold needs a higher floor than the rest because unsaturated skin tones and
# bone land in the same window, and a cartel of bare skulls is not the intent.
BANDS = [
    ("terran",   205, 248, 0.30),
    ("vorn",     330,  15, 0.30),
    ("ashai",     60, 165, 0.30),
    ("kepler",   248, 330, 0.30),
    ("cartel",    15,  60, 0.45),
    ("silicate", 165, 205, 0.30),
]
# How far apart two picks must be in the source ordering to count as different
# characters. Relaxed only if a band is too thin to fill at that spacing.
MIN_SPACING = 10
# Anything below this value is outline or background and says nothing about
# what colour the subject is.
HUE_FLOOR_VALUE = 0.18
HUE_FLOOR_SAT = 0.30

# ui.CARD_ALT, so a portrait sits on a row without a seam. Kept in step by hand:
# there is no way to read a Lua table from here, and it changes about never.
BACKING = (20, 31, 53, 255)   # 0x141F35

OUT_DIR = os.path.join("main", "assets", "portraits")
ATLAS = os.path.join("main", "portraits.atlas")


# Anything this dark, reached from the edge of the image, is background.
BACKGROUND_THRESHOLD = 28
# The mask is built at this multiple of the output size and then downsampled,
# which is what gives the circle a clean edge instead of a stepped one.
MASK_SUPERSAMPLE = 4


def strip_background(im):
    """Make the baked-in black background transparent.

    The source art is opaque: a portrait dropped straight onto a card reads as a
    black square glued to it. Keying out *every* black pixel is not an option -
    this is pixel art and its outlines are black, so that punches holes through
    the character. Flooding inward from the border instead only ever removes
    what is actually behind the subject.
    """
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    seen = bytearray(w * h)
    queue = deque()

    def is_background(x, y):
        r, g, b, a = px[x, y]
        return (a > 0 and r <= BACKGROUND_THRESHOLD
                and g <= BACKGROUND_THRESHOLD and b <= BACKGROUND_THRESHOLD)

    def push(x, y):
        if not seen[y * w + x] and is_background(x, y):
            seen[y * w + x] = 1
            queue.append((x, y))

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)

    while queue:
        x, y = queue.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                push(nx, ny)
    return im


def circular_mask(size):
    """A round alpha mask with a smooth edge, at `size` square."""
    big = size * MASK_SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, big - 1, big - 1), fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def make_round(im, size):
    """Crop a portrait to a disc, over a faint backing.

    The art is a bust in a square frame, so a disc clips the outer shoulders -
    which is what a portrait medallion looks like anyway. The backing matters:
    without it the clipped shoulders end at nothing and the head appears to
    float, where a disc reads as a frame the character is sitting inside.
    """
    im = im.convert("RGBA").resize((size, size), Image.LANCZOS)
    backing = Image.new("RGBA", (size, size), BACKING)
    plate = Image.alpha_composite(backing, im)
    plate.putalpha(circular_mask(size))
    return plate


def dominant_hue(path):
    """What colour the *subject* is, ignoring the black plate behind it.

    A histogram rather than a mean: averaging a green face against a red cloak
    gives a muddy yellow that belongs to neither. The most common hue bucket is
    what a person would name if asked what colour the character is.

    Returns (hue in degrees, how much of the subject is that hue, mean
    saturation) - or None for an image with nothing lit in it.
    """
    with Image.open(path) as raw:
        im = raw.convert("RGB").resize((64, 64), Image.LANCZOS)
        pixels = list(im.get_flattened_data()
                      if hasattr(im, "get_flattened_data") else im.getdata())

    hues = Counter()
    saturation, lit = 0.0, 0
    for r, g, b in pixels:
        if r < 30 and g < 30 and b < 30:
            continue                      # background, or the art's outlines
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if v < HUE_FLOOR_VALUE:
            continue
        lit += 1
        saturation += s
        if s > HUE_FLOOR_SAT:
            hues[int(h * 360) // 15] += 1
    if lit == 0:
        return None
    top = hues.most_common(1)
    return (
        top[0][0] * 15 + 7 if top else -1,
        top[0][1] / lit if top else 0.0,
        saturation / lit,
    )


def in_band(hue, low, high):
    """Hue windows wrap, so red spans the seam at zero."""
    return low <= hue < high if low < high else (hue >= low or hue < high)


def choose(profiles):
    """The set actually imported: {race: [source index, ...]}.

    Strongest examples of each band first, but never two picks closer together
    than MIN_SPACING in the source order - which is what stops a race being
    twelve portraits of one character in slightly different armour. The spacing
    is relaxed, and only as far as it has to be, for a band too thin to fill.
    """
    out = {}
    for race, low, high, min_sat in BANDS:
        band = [n for n, p in profiles.items()
                if in_band(p[0], low, high) and p[2] >= min_sat]
        band.sort(key=lambda n: (-profiles[n][1], n))
        chosen = []
        for spacing in (MIN_SPACING, 6, 3, 1):
            for n in band:
                if len(chosen) >= PER_RACE:
                    break
                if all(abs(n - c) >= spacing for c in chosen):
                    chosen.append(n)
            if len(chosen) >= PER_RACE:
                break
        if len(chosen) < PER_RACE:
            sys.exit("only %d portraits in the %s band; widen it or lower "
                     "PER_RACE" % (len(chosen), race))
        out[race] = sorted(chosen[:PER_RACE])
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    source = os.path.expanduser(sys.argv[1])
    if not os.path.isdir(source):
        sys.exit("no such directory: " + source)

    profiles = {}
    for n in range(1, SOURCE_COUNT + 1):
        path = os.path.join(source, "%d.png" % n)
        if not os.path.exists(path):
            sys.exit("missing source image: " + path)
        p = dominant_hue(path)
        if p:
            profiles[n] = p
    picked = choose(profiles)

    os.makedirs(OUT_DIR, exist_ok=True)
    names, manifest = [], {}
    for race, _, _, _ in BANDS:
        manifest[race] = picked[race]
        for slot, index in enumerate(picked[race], start=1):
            src = os.path.join(source, "%d.png" % index)
            name = "portrait_%s_%02d" % (race, slot)
            with Image.open(src) as im:
                # Background first, at full resolution: keying after a resample
                # would leave a dark fringe where the edge pixels were blended.
                out = strip_background(im.copy())
                out = make_round(out, SIZE)
                out.save(os.path.join(OUT_DIR, name + ".png"))
            names.append(name)

    # The bands are a method, not a record. Which images they actually selected
    # is what has to survive - a tweak to a threshold silently reassigns every
    # commander's face, and this is the only way to see that it happened.
    with open(os.path.join(OUT_DIR, "MANIFEST.json"), "w") as f:
        json.dump({"per_race": PER_RACE, "size": SIZE,
                   "source_count": SOURCE_COUNT, "picked": manifest},
                  f, indent=1, sort_keys=True)
        f.write("\n")

    with open(ATLAS, "w") as f:
        for name in names:
            f.write('images {\n')
            f.write('  image: "/%s/%s.png"\n' % (OUT_DIR.replace(os.sep, "/"), name))
            f.write('  sprite_trim_mode: SPRITE_TRIM_MODE_OFF\n')
            f.write('}\n')
        # A portrait is never scaled below its drawn size, and bleeding would
        # smear the pixel art's hard edges, so neither is enabled.
        f.write("margin: 0\n")
        f.write("extrude_borders: 2\n")
        f.write("inner_padding: 0\n")

    print("wrote %d portraits (%d races x %d) to %s and %s"
          % (len(names), len(BANDS), PER_RACE, OUT_DIR, ATLAS))
    for race, _, _, _ in BANDS:
        print("  %-9s %s" % (race, " ".join(str(n) for n in picked[race])))


if __name__ == "__main__":
    main()
