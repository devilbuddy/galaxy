#!/usr/bin/env python3
"""Import commander portraits from a source set into the project.

Unlike make_textures.py and make_ui_textures.py, this is **not** a regeneration
step: the output is third-party art, not something derived from parameters in
this file. It exists so the provenance of what is in main/assets/portraits/ is
recorded and reproducible - which forty of the source images were taken, at what
size, and in what order.

The order is what matters. A commander's portrait is chosen by the same index as
their surname (galaxy/sim/commanders.lua), so the nth officer a player raises
always has both the same name and the same face. Reordering or reducing this set
silently reassigns every existing commander's portrait, so don't.

Usage:
    python3 tools/import_portraits.py ~/Downloads/PORTRAITS
"""

import os
import sys
from collections import deque

from PIL import Image, ImageDraw

# One per surname in galaxy/sim/commanders.lua. Kept equal on purpose: the two
# lists are indexed together.
COUNT = 40
# Design units are roughly 0.57dp, so a 72-unit portrait is ~113px on a 2.75x
# phone. 128 is the next sensible power of two above that.
SIZE = 128
SOURCE_COUNT = 500

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


def picks(total, count):
    """An even spread through the source set.

    The set is ordered by character, with several variants of each in a row, so
    taking the first N would give forty portraits of a dozen faces. Spreading
    them out is what makes the roster look like a roster.
    """
    return [round(i * total / count) + 1 for i in range(count)]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    source = os.path.expanduser(sys.argv[1])
    if not os.path.isdir(source):
        sys.exit("no such directory: " + source)

    os.makedirs(OUT_DIR, exist_ok=True)
    names = []
    for slot, index in enumerate(picks(SOURCE_COUNT, COUNT), start=1):
        src = os.path.join(source, "%d.png" % index)
        if not os.path.exists(src):
            sys.exit("missing source image: " + src)
        name = "portrait_%02d" % slot
        with Image.open(src) as im:
            # Background first, at full resolution: keying after a resample
            # would leave a dark fringe where the edge pixels were blended.
            out = strip_background(im.copy())
            out = make_round(out, SIZE)
            out.save(os.path.join(OUT_DIR, name + ".png"))
        names.append(name)

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

    print("wrote %d portraits to %s and %s" % (len(names), OUT_DIR, ATLAS))


if __name__ == "__main__":
    main()
