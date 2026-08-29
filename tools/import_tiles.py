#!/usr/bin/env python3
"""Import the map's hex ground tiles from the `foundation_tiles` art pack.

Like import_emoji.py, this is an **import** of
third-party art rather than a regeneration step: the output is somebody else's
drawing, not something derived from parameters here. So alongside the images it
records provenance - which source file became which, at what size, under what
terms (MANIFEST.json, CREDITS.txt).

The tile list is not declared here. It is parsed out of `main/theme.lua`, which
is the single source of truth for everything the game can draw:

    M.TILES    terrain name -> the pack's own file suffix
    M.BIOMES   the five ground palettes

Run this after changing either table, or after pointing --src at a new pack:

    main/assets/tiles/tile_<biome>_<terrain>.png   one per pair, native size
    main/assets/tiles/MANIFEST.json                which source became which
    main/assets/tiles/CREDITS.txt                  attribution, and the licence gap
    main/tiles.atlas                               generated, never hand-edited

**The images are copied at their native 238x207 and never resized or trimmed.**
That is not laziness: 238x207 is exactly the bounding box of a flat-top hexagon
of size 119 (2s wide by sqrt(3)*s tall, = 238 x 206.1), which is what lets plain
sprite quads tessellate with no gaps. Resizing to a round number, or letting
Defold trim the transparent corners, would break the tiling. Hence
SPRITE_TRIM_MODE_OFF in the atlas below - it is load-bearing, not a default.

Note the texture profile: realm.texture_profiles must mipmap /main/tiles.atlas
by name. A profile matches the *generated* texture, not the source directory, so
listing main/assets/tiles/** would silently do nothing - the same trap
import_emoji.py documents for /main/emoji.atlas.
"""
import argparse
import json
import os
import re
import shutil
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
THEME = os.path.join(ROOT, "main", "theme.lua")
OUT_DIR = os.path.join(ROOT, "main", "assets", "tiles")
ATLAS = os.path.join(ROOT, "main", "tiles.atlas")

DEFAULT_SRC = os.path.expanduser("~/Downloads/foundation_tiles")

# The flat-top hex the whole layout maths assumes, read from main/theme.lua so
# there is one declaration of it rather than two. Asserted rather than trusted: a
# pack drawn to a different aspect would tile with gaps, and the failure looks
# like a rendering bug several days later, nowhere near the import that caused it.

# Margin and extrude are larger than main/emoji.atlas's 2px because this atlas
# is mipmapped and every image is opaque edge to edge along four of its six
# sides. At high mip levels a 2px extrude is not enough to stop a neighbouring
# biome bleeding a stripe of the wrong colour along a hex edge.
MARGIN = 4
EXTRUDE = 4


def tile_px():
    """`M.TILE_PX = { w = ..., h = ... }` out of main/theme.lua."""
    src = open(THEME).read()
    m = re.search(r"^M\.TILE_PX\s*=\s*\{([^}]*)\}", src, re.M)
    if not m:
        sys.exit("import_tiles: no M.TILE_PX in main/theme.lua")
    got = dict(re.findall(r"(\w+)\s*=\s*(\d+)", m.group(1)))
    return int(got["w"]), int(got["h"])


def theme_table(name, pattern):
    """Parse one `M.<name> = { ... }` block out of main/theme.lua.

    Anchored at the start of a line (re.M) for the reason import_emoji.py gives:
    an unanchored pattern is free to match inside a longer table name and hand
    back the wrong vocabulary, and everything downstream would still run.

    Closed on the first `}` rather than on a `\n}` at column zero, because
    M.BIOMES is a one-line table. The stricter form runs straight past it to the
    end of the *next* table and parses that instead - which is not an error, just
    the wrong answer, and it surfaces as a missing directory named after an emoji
    codepoint. None of these tables nest, so the first brace is the right one.
    """
    src = open(THEME).read()
    block = re.search(r"^M\.%s\s*=\s*\{(.*?)\}" % name, src, re.S | re.M)
    if not block:
        sys.exit("import_tiles: no M.%s block found in main/theme.lua" % name)
    found = re.findall(pattern, block.group(1))
    if not found:
        sys.exit("import_tiles: M.%s block parsed empty" % name)
    return found


def source_path(src, biome, suffix):
    """Locate `<n>-<biome>_<suffix>.png`, whatever number the pack gave it.

    Globbing on the suffix rather than hardcoding the numbers: the ordinal is
    the artist's, it carries no meaning here, and pinning it would make this
    break on any pack that renumbers.
    """
    want = "%s_%s.png" % (biome, suffix)
    folder = os.path.join(src, biome)
    if not os.path.isdir(folder):
        sys.exit("import_tiles: no biome directory %s" % folder)
    hits = [f for f in sorted(os.listdir(folder)) if f.endswith(want)]
    if len(hits) != 1:
        sys.exit("import_tiles: %d matches for *%s in %s" % (len(hits), want, folder))
    return os.path.join(folder, hits[0])


def write_atlas(names):
    """Rewrite main/tiles.atlas from the imported tiles.

    Generated rather than hand-maintained, exactly like main/ui.atlas and
    main/emoji.atlas: adding a terrain or a biome is one command and cannot be
    half-done. Written from the names main/theme.lua declared rather than from a
    directory listing, so a file left behind by an older run cannot creep back
    into the build. No `max_page_size` line - bob 1.13 rejects the field outright
    rather than ignoring it.
    """
    blocks = [
        'images {\n  image: "/main/assets/tiles/%s.png"\n'
        "  sprite_trim_mode: SPRITE_TRIM_MODE_OFF\n}" % n
        for n in names
    ]
    body = "\n".join(blocks) + "\nmargin: %d\nextrude_borders: %d\ninner_padding: 0\n" % (
        MARGIN, EXTRUDE)
    with open(ATLAS, "w") as f:
        f.write(body)
    print("main/tiles.atlas: %d images" % len(names))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC,
                    help="the foundation_tiles pack (default: %(default)s)")
    args = ap.parse_args()

    tiles = dict(theme_table("TILES", r'(\w+)\s*=\s*"([\w-]+)"'))
    biomes = theme_table("BIOMES", r'"([\w-]+)"')
    tile_w, tile_h = tile_px()

    os.makedirs(OUT_DIR, exist_ok=True)

    manifest = {}
    names = []
    for biome in biomes:
        for terrain in sorted(tiles):
            name = "tile_%s_%s" % (biome, terrain)
            src = source_path(args.src, biome, tiles[terrain])
            size = Image.open(src).size
            if size != (tile_w, tile_h):
                sys.exit("import_tiles: %s is %dx%d, but main/theme.lua's "
                         "M.TILE_PX says %dx%d - the hex layout maths depends "
                         "on it" % (src, size[0], size[1], tile_w, tile_h))
            shutil.copyfile(src, os.path.join(OUT_DIR, name + ".png"))
            manifest[name] = {"biome": biome, "terrain": terrain,
                              "source": os.path.relpath(src, args.src)}
            names.append(name)

    # A terrain or biome dropped from main/theme.lua leaves its PNG behind, and a
    # stale one on disk is indistinguishable from a live one when you go looking.
    wanted = set(n + ".png" for n in names)
    for stale in sorted(os.listdir(OUT_DIR)):
        if stale.endswith(".png") and stale not in wanted:
            os.remove(os.path.join(OUT_DIR, stale))
            print("removed stale %s" % stale)

    print("main/assets/tiles/: %d tiles (%d biomes x %d terrain) at %dx%d"
          % (len(names), len(biomes), len(tiles), tile_w, tile_h))
    write_atlas(names)

    with open(os.path.join(OUT_DIR, "CREDITS.txt"), "w") as f:
        f.write("""Hex ground tiles
================

Hand-drawn hexagonal terrain tiles from the "foundation_tiles" pack, imported
from %s. The artwork is unmodified: the files are copied
byte for byte at their native %dx%d, because that is exactly the bounding box of
a flat-top hexagon of size %d and the map's tiling depends on it.

Only the *ground* types are imported - water, plains, forest, woods, hills and
mountains, in each of %d biome palettes. The pack also draws villages, cities,
keeps, ruins and crystals as tiles; those are places rather than ground, and the
map draws them as Noto emoji on top of the hex instead (main/theme.lua M.EMOJI).

Which source file became which tile is recorded in MANIFEST.json beside this
file, and both are regenerated together by tools/import_tiles.py, so the mapping
and the art cannot drift apart.

LICENCE: NOT ESTABLISHED. The pack as received carries no licence file, no
author attribution and no terms of use - fine for a prototype, and a thing that
must be resolved before anything ships. Whoever resolves it should record the
outcome here.

This is now the **only** unresolved licence in the project.
main/assets/portraits/ was the other one and no longer is: those faces are Noto
emoji under Apache 2.0, imported by tools/import_emoji.py.
""" % (args.src, tile_w, tile_h, tile_w // 2, len(biomes)))

    with open(os.path.join(OUT_DIR, "MANIFEST.json"), "w") as f:
        json.dump({"source": args.src, "tile_width": tile_w, "tile_height": tile_h,
                   "margin": MARGIN, "extrude_borders": EXTRUDE,
                   "biomes": biomes, "terrain": tiles, "tiles": manifest},
                  f, indent=1, sort_keys=True)
        f.write("\n")
    print("MANIFEST.json, CREDITS.txt written")


if __name__ == "__main__":
    main()
