#!/usr/bin/env python3
"""Import the map's emoji glyphs from Google Noto emoji.

Like import_portraits.py, this is an import of third-party art rather than a
regeneration step - the output is Noto's drawings, not something derived from
parameters here - so alongside the sheet it records provenance: which glyphs,
from which release, packed into which cells (MANIFEST.json), under what terms
(NotoEmoji-LICENSE.txt, CREDITS.txt).

The glyph list is not declared here: it is parsed out of `main/theme.lua`, which
is the single source of truth for what the game can draw. There are two
vocabularies there and they land in two different places, because the map and
the interface draw glyphs by entirely different mechanisms:

  M.EMOJI       the *map*, drawn as mesh quads that sample one packed sheet by
                UV rect (main/shaders/emoji.fp).
  M.UNIT_EMOJI  the *interface*, drawn as GUI box nodes. A GUI node plays a whole
                named atlas image and cannot be handed a UV rect, so these are
                exported one PNG apiece into an atlas of their own. They are
                deliberately not in the sheet: it is a 4x4 grid with no cells to
                spare, and mesh UVs must not shift when an icon is added.

Run this after changing either table. It writes:

    main/assets/emoji/sheet.png           4x4 grid of 256px cells, 1024x1024
    main/assets/emoji/ui/emoji_<name>.png one 192px glyph apiece, for the GUI
    main/assets/emoji/MANIFEST.json       provenance + cell assignments
    main/assets/emoji/CREDITS.txt         attribution
    main/assets/emoji/NotoEmoji-LICENSE.txt
    main/emoji_sheet.lua                  name -> UV rect (generated, never
                                          hand-edited - like main/ui.atlas)
    main/emoji_ui.lua                     name -> atlas image id, the GUI twin
    main/emoji.atlas                      generated from main/assets/emoji/ui/

Sheet glyphs are downscaled 512 -> 224 (LANCZOS) and centred, leaving a 16px
transparent gutter per cell; the UV rects are inset a further 8px so linear
sampling and mip generation never bleed a neighbouring glyph into an edge.
Everything is straight alpha - Defold premultiplies at build time, the same
contract as every other texture in the project.

Note the texture profile: realm.texture_profiles mipmaps /main/assets/emoji/**,
which is what the sheet needs and what a GUI atlas does not. A profile matches
the *generated* texture, and that is /main/emoji.atlas - which falls under `**`
and gets the default no-mip profile. Nothing to configure; worth remembering if
the atlas ever moves under main/assets/.
"""
import io
import json
import os
import re
import sys
import urllib.request

from PIL import Image

NOTO_REF = "v2.047"
NOTO_URL = "https://raw.githubusercontent.com/googlefonts/noto-emoji/%s/png/512/emoji_u%s.png"
LICENSE_URL = "https://raw.githubusercontent.com/googlefonts/noto-emoji/%s/LICENSE"

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
THEME = os.path.join(ROOT, "main", "theme.lua")
OUT_DIR = os.path.join(ROOT, "main", "assets", "emoji")
SHEET = os.path.join(OUT_DIR, "sheet.png")
UI_DIR = os.path.join(OUT_DIR, "ui")
UV_MODULE = os.path.join(ROOT, "main", "emoji_sheet.lua")
UI_MODULE = os.path.join(ROOT, "main", "emoji_ui.lua")
UI_ATLAS = os.path.join(ROOT, "main", "emoji.atlas")
CACHE = os.path.join(ROOT, "build", "emoji_cache")

GRID = 4          # cells per side
CELL = 256        # px per cell
GLYPH = 224       # glyph size inside the cell (16px gutter each side)
INSET = 8         # UV inset from the cell edge, px
SHEET_PX = GRID * CELL

# One unpacked glyph, for the atlas. Serves both vocabularies now, so it is
# sized for the larger claim: a map glyph sits on a 238px hex tile and is drawn
# at a fraction of it, while a tile-sheet slot is 94 design units - 188
# physical pixels on a 2x framebuffer. Declared in main/theme.lua beside the
# tile size, because the renderer derives its sprite scale from both.
UI_PX = int(re.search(r"^M\.GLYPH_PX\s*=\s*(\d+)", open(THEME).read(), re.M).group(1))

# Defold flips PNGs to GL convention at build time, so v=0 is the bottom of
# the image. If the first engine build shows the castle upside down, this is
# the one switch to flip.
FLIP_V = True


def theme_table(name):
    """name -> codepoint, parsed from one `M.<name> = { ... }` block.

    Anchored at the start of a line (re.M), because an unanchored pattern for
    EMOJI is free to match inside a longer table name and hand back the wrong
    vocabulary. Everything downstream would still run.
    """
    src = open(THEME).read()
    block = re.search(r"^M\.%s\s*=\s*\{(.*?)\n\}" % name, src, re.S | re.M)
    if not block:
        sys.exit("import_emoji: no M.%s block found in main/theme.lua" % name)
    pairs = re.findall(r'(\w+)\s*=\s*"([0-9a-f_]+)"', block.group(1))
    if not pairs:
        sys.exit("import_emoji: M.%s block parsed empty" % name)
    return dict(pairs)


def fetch(url, path):
    if os.path.exists(path):
        return open(path, "rb").read()
    print("fetch %s" % url)
    with urllib.request.urlopen(url) as r:
        if r.status != 200:
            sys.exit("import_emoji: %d for %s" % (r.status, url))
        data = r.read()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return data


def write_ui_atlas(names):
    """Rewrite main/emoji.atlas from the exported GUI glyphs.

    Generated rather than hand-maintained, exactly like main/ui.atlas: adding an
    interface glyph is one command and cannot be half-done. Written from the
    names main/theme.lua declared rather than from a directory listing, so a
    file left behind by an older run cannot creep back into the build. Same
    margin and extrude as that atlas, and no `max_page_size` line - bob 1.13
    rejects the field outright rather than ignoring it.
    """
    blocks = [
        'images {\n  image: "/main/assets/emoji/ui/emoji_%s.png"\n'
        "  sprite_trim_mode: SPRITE_TRIM_MODE_OFF\n}" % n
        for n in names
    ]
    body = "\n".join(blocks) + "\nmargin: 2\nextrude_borders: 2\ninner_padding: 0\n"
    with open(UI_ATLAS, "w") as f:
        f.write(body)
    print("main/emoji.atlas: %d images" % len(names))


def export_atlas(glyphs):
    """One PNG per glyph, plus the atlas and the name -> image-id module.

    Both vocabularies land here now. The map used to sample UV rects out of a
    packed sheet, which a mesh shader can do and a GUI node cannot - that
    asymmetry is the whole reason there were two outputs. Drawing the map with
    *sprites* removes it, because a sprite cannot be handed a UV rect either. So
    there is one atlas, one name -> id table, and no sheet to keep in step with
    them.
    """
    names = sorted(glyphs)
    os.makedirs(UI_DIR, exist_ok=True)

    # A glyph dropped from main/theme.lua leaves its PNG behind, and a stale one
    # on disk is indistinguishable from a live one when you go looking.
    wanted = set("emoji_%s.png" % n for n in names)
    for stale in sorted(os.listdir(UI_DIR)):
        if stale.endswith(".png") and stale not in wanted:
            os.remove(os.path.join(UI_DIR, stale))
            print("removed stale %s" % stale)

    for name in names:
        cp = glyphs[name]
        raw = fetch(NOTO_URL % (NOTO_REF, cp),
                    os.path.join(CACHE, "emoji_u%s.png" % cp))
        img = Image.open(io.BytesIO(raw)).convert("RGBA")
        img = img.resize((UI_PX, UI_PX), Image.LANCZOS)
        img.save(os.path.join(UI_DIR, "emoji_%s.png" % name))
    print("main/assets/emoji/ui/: %d glyphs at %dpx" % (len(names), UI_PX))

    write_ui_atlas(names)

    # Name -> atlas image id, for every glyph the game can draw: the map's
    # sprites and the interface's GUI nodes both need an image *name*. Nothing
    # but a string connects main/theme.lua to the art, and tools/test_wire.lua
    # checks the join across this table.
    lines = [
        "-- Generated by tools/import_emoji.py - do not edit by hand.",
        "-- Noto emoji %s exported one glyph apiece into /main/emoji.atlas." % NOTO_REF,
        "-- Covers both vocabularies: M.EMOJI (map sprites) and M.UNIT_EMOJI (GUI).",
        "return {",
    ]
    for name in names:
        lines.append('\t%s = "emoji_%s",' % (name, name))
    lines.append("}")
    with open(UI_MODULE, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("main/emoji_ui.lua: %d entries" % len(names))


def main():
    emoji = theme_table("EMOJI")
    units = theme_table("UNIT_EMOJI")
    names = sorted(emoji)
    if len(names) > GRID * GRID:
        sys.exit("import_emoji: %d glyphs do not fit a %dx%d sheet"
                 % (len(names), GRID, GRID))

    sheet = Image.new("RGBA", (SHEET_PX, SHEET_PX), (0, 0, 0, 0))
    manifest_cells = {}
    for i, name in enumerate(names):
        cp = emoji[name]
        raw = fetch(NOTO_URL % (NOTO_REF, cp),
                    os.path.join(CACHE, "emoji_u%s.png" % cp))
        img = Image.open(io.BytesIO(raw)).convert("RGBA")
        img = img.resize((GLYPH, GLYPH), Image.LANCZOS)
        col, row = i % GRID, i // GRID
        pad = (CELL - GLYPH) // 2
        sheet.paste(img, (col * CELL + pad, row * CELL + pad))
        manifest_cells[name] = {"codepoint": cp, "cell": i}

    os.makedirs(OUT_DIR, exist_ok=True)
    sheet.save(SHEET)
    print("sheet.png %dx%d, %d glyphs" % (SHEET_PX, SHEET_PX, len(names)))

    # UV rects, inset from the cell so sampling never reaches a neighbour.
    # v0 is the glyph's bottom edge and v1 its top, matching how
    # build_tiles hands corners to meshbuild's quad().
    lines = [
        "-- Generated by tools/import_emoji.py - do not edit by hand.",
        "-- Noto emoji %s packed into /main/assets/emoji/sheet.png;" % NOTO_REF,
        "-- see MANIFEST.json there for which glyph sits in which cell.",
        "return {",
    ]
    for i, name in enumerate(names):
        col, row = i % GRID, i // GRID
        x0 = (col * CELL + INSET) / SHEET_PX
        x1 = ((col + 1) * CELL - INSET) / SHEET_PX
        yt = (row * CELL + INSET) / SHEET_PX          # top edge, image space
        yb = ((row + 1) * CELL - INSET) / SHEET_PX    # bottom edge, image space
        if FLIP_V:
            v0, v1 = 1.0 - yb, 1.0 - yt
        else:
            v0, v1 = yb, yt
        lines.append("\t%s = { u0 = %.6f, v0 = %.6f, u1 = %.6f, v1 = %.6f },"
                     % (name, x0, v0, x1, v1))
    lines.append("}")
    with open(UV_MODULE, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("main/emoji_sheet.lua: %d entries" % len(names))

    # One atlas, both vocabularies. A name in both tables would export one PNG
    # and silently give one of the two the other's glyph, so it is a hard error
    # rather than a last-writer-wins merge.
    clash = sorted(set(emoji) & set(units))
    if clash:
        sys.exit("import_emoji: %s in both M.EMOJI and M.UNIT_EMOJI"
                 % ", ".join(clash))
    merged = dict(emoji)
    merged.update(units)
    export_atlas(merged)

    license_text = fetch(LICENSE_URL % NOTO_REF,
                         os.path.join(CACHE, "LICENSE-%s" % NOTO_REF)).decode()
    with open(os.path.join(OUT_DIR, "NotoEmoji-LICENSE.txt"), "w") as f:
        f.write("Copyright 2013 Google LLC (https://github.com/googlefonts/noto-emoji)\n\n"
                "The Noto emoji artwork in this directory is licensed under the\n"
                "Apache License, Version 2.0. The license is copied below, and is\n"
                "also available at http://www.apache.org/licenses/LICENSE-2.0\n\n\n")
        f.write(license_text)

    with open(os.path.join(OUT_DIR, "CREDITS.txt"), "w") as f:
        f.write("""Map emoji
=========

Google Noto color emoji, from the googlefonts/noto-emoji repository at tag
%s. The artwork itself is unmodified; only its size and packing changed.

  sheet.png   the map's glyphs, downscaled to %dpx and centred in %dpx cells.
              Sampled by UV rect from a mesh shader.
  ui/         the interface's glyphs, one %dpx PNG apiece, packed by Defold
              into /main/emoji.atlas. A GUI node draws a whole named image and
              cannot be handed a UV rect, which is why these are not in the
              sheet.

Which glyphs each vocabulary uses is decided by main/theme.lua, and
MANIFEST.json here records exactly which codepoint became which.

LICENCE: Apache License, Version 2.0 - see NotoEmoji-LICENSE.txt beside this
file. Re-running the importer after editing main/theme.lua regenerates the
sheet, main/emoji_sheet.lua, main/emoji.atlas and main/emoji_ui.lua together,
so the mapping and the art cannot drift apart.
""" % (NOTO_REF, GLYPH, CELL, UI_PX))

    with open(os.path.join(OUT_DIR, "MANIFEST.json"), "w") as f:
        json.dump({"ref": NOTO_REF, "grid": GRID, "cell": CELL, "glyph": GLYPH,
                   "uv_inset": INSET, "flip_v": FLIP_V, "glyphs": manifest_cells,
                   "ui_px": UI_PX,
                   "ui_glyphs": {n: {"codepoint": units[n]} for n in units}},
                  f, indent=1, sort_keys=True)
        f.write("\n")
    print("MANIFEST.json, CREDITS.txt, NotoEmoji-LICENSE.txt written")


if __name__ == "__main__":
    main()
