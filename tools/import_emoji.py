#!/usr/bin/env python3
"""Import the game's emoji art from Google Noto emoji.

This is an import of third-party art rather than a regeneration step - the
output is Noto's drawings, not something derived from parameters here - so
alongside the art it records provenance: which glyphs, from which release,
packed where (MANIFEST.json), under what terms (NotoEmoji-LICENSE.txt,
CREDITS.txt).

Nothing here declares what to draw. Three vocabularies are parsed out of
`main/theme.lua`, which is the single source of truth, and they land in two
atlases because they are drawn at two scales:

  M.EMOJI       the *map*: a glyph on the places worth holding, drawn as a
                sprite scaled to the hex, so exported at M.GLYPH_PX.
  M.UNIT_EMOJI  the *interface*: what a theme's three unit types look like in
                the tile sheet's racks and the buy popup. GUI box nodes, drawn
                at most 94 design units across, so exported at M.UI_PX.
  M.FACE_EMOJI  the *officers*: eight faces per theme, composited onto a disc
                and masked round, filling the `portrait_<race>_NN` ids that
                `realm/sim/commanders.lua` names. These go to their own atlas,
                because ui.portrait draws a ring expecting exactly that disc.

Run this after changing any of the three. It writes:

    main/assets/emoji/sheet.png             4x4 grid of 256px cells, 1024x1024
    main/assets/emoji/ui/emoji_<name>.png   one glyph apiece, for the atlas
    main/assets/emoji/MANIFEST.json         provenance + cell assignments
    main/assets/emoji/CREDITS.txt           attribution
    main/assets/emoji/NotoEmoji-LICENSE.txt
    main/emoji_sheet.lua                    name -> UV rect (generated)
    main/emoji_ui.lua                       name -> atlas image id
    main/emoji.atlas                        generated from main/assets/emoji/ui/
    main/assets/portraits/portrait_*.png    one disc apiece, per theme
    main/assets/portraits/MANIFEST.json     which codepoint became which face
    main/assets/portraits/CREDITS.txt       attribution
    main/portraits.atlas                    generated from those discs

Everything is straight alpha - Defold premultiplies at build time, the same
contract as every other texture in the project.

**The faces replaced a set whose licence was never established.** They used to
be seventy-two pieces of third-party pixel art, imported by a tools/
import_portraits.py that grouped five hundred images into races by dominant
hue. That script is gone: the art it read had no terms attached, and Noto's are
Apache 2.0. A portrait is a role, not a medium - it is still the face standing
for an officer, and every id it fills is unchanged.

Note the texture profile: realm.texture_profiles mipmaps /main/emoji.atlas by
name. A profile matches the *generated* texture, so main/portraits.atlas falls
under `**` and gets the default no-mip profile, which is right - a portrait is
never drawn smaller than the strip's 62 units.
"""
import io
import json
import os
import re
import sys
import urllib.request

from PIL import Image, ImageDraw

NOTO_REF = "v2.047"
NOTO_URL = "https://raw.githubusercontent.com/googlefonts/noto-emoji/%s/png/512/emoji_u%s.png"
LICENSE_URL = "https://raw.githubusercontent.com/googlefonts/noto-emoji/%s/LICENSE"

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
THEME = os.path.join(ROOT, "main", "theme.lua")
RACES = os.path.join(ROOT, "realm", "sim", "races.lua")
COMMANDERS = os.path.join(ROOT, "realm", "sim", "commanders.lua")
OUT_DIR = os.path.join(ROOT, "main", "assets", "emoji")
SHEET = os.path.join(OUT_DIR, "sheet.png")
UI_DIR = os.path.join(OUT_DIR, "ui")
UV_MODULE = os.path.join(ROOT, "main", "emoji_sheet.lua")
UI_MODULE = os.path.join(ROOT, "main", "emoji_ui.lua")
UI_ATLAS = os.path.join(ROOT, "main", "emoji.atlas")
FACE_DIR = os.path.join(ROOT, "main", "assets", "portraits")
FACE_ATLAS = os.path.join(ROOT, "main", "portraits.atlas")
CACHE = os.path.join(ROOT, "build", "emoji_cache")

GRID = 4          # cells per side
CELL = 256        # px per cell
GLYPH = 224       # glyph size inside the cell (16px gutter each side)
INSET = 8         # UV inset from the cell edge, px
SHEET_PX = GRID * CELL

# ui.CARD_ALT, so a face sits on a row without a seam. Kept in step by hand:
# there is no way to read a Lua table from here, and it changes about never.
BACKING = (20, 31, 53, 255)   # 0x141F35

# How much of the disc the emoji fills. Not 1.0: an emoji is a glyph drawn to
# the edges of its own square, so at full size the round mask clips a farmer's
# hat and a wizard's staff. At 0.78 the whole drawing sits inside the ring.
FACE_FILL = 0.78

# The mask is built at this multiple of the output size and then downsampled,
# which is what gives the circle a clean edge instead of a stepped one.
MASK_SUPERSAMPLE = 4

# Defold flips PNGs to GL convention at build time, so v=0 is the bottom of
# the image. If the first engine build shows the castle upside down, this is
# the one switch to flip.
FLIP_V = True


def theme_number(name):
    """One `M.<name> = <integer>` out of main/theme.lua."""
    src = open(THEME).read()
    hit = re.search(r"^M\.%s\s*=\s*(\d+)" % name, src, re.M)
    if not hit:
        sys.exit("import_emoji: no M.%s in main/theme.lua" % name)
    return int(hit.group(1))


def theme_table(name):
    """name -> codepoint, parsed from one `M.<name> = { ... }` block.

    Anchored at the start of a line (re.M), because an unanchored pattern for
    EMOJI is free to match inside a longer table name and hand back the wrong
    vocabulary. Everything downstream would still run.

    The block ends at the first line that is exactly `}`, so every table this
    reads has to stay **flat**. That is why the per-theme art is keyed
    `<race>_<thing>` rather than nested by race: M.UNIT_NAME and M.BUILDING_NAME
    are nested precisely because nothing here parses them.
    """
    src = open(THEME).read()
    block = re.search(r"^M\.%s\s*=\s*\{(.*?)\n\}" % name, src, re.S | re.M)
    if not block:
        sys.exit("import_emoji: no M.%s block found in main/theme.lua" % name)
    pairs = re.findall(r'(\w+)\s*=\s*"([0-9a-f_]+)"', block.group(1))
    if not pairs:
        sys.exit("import_emoji: M.%s block parsed empty" % name)
    return dict(pairs)


def race_ids():
    """The race ids, in declaration order, out of realm/sim/races.lua."""
    ids = re.findall(r'^\t\tid = "(\w+)"', open(RACES).read(), re.M)
    if not ids:
        sys.exit("import_emoji: no race ids found in realm/sim/races.lua")
    return ids


def faces_per_race():
    """PORTRAITS_PER_RACE, out of realm/sim/commanders.lua.

    Read rather than declared, because it is the simulation that decides how
    many faces exist: `commanders.portrait` wraps an officer's number modulo
    this, so exporting a different number would silently leave the tail of every
    theme's cast unreachable, or name a face that is not there.
    """
    hit = re.search(r"^local PORTRAITS_PER_RACE\s*=\s*(\d+)",
                    open(COMMANDERS).read(), re.M)
    if not hit:
        sys.exit("import_emoji: no PORTRAITS_PER_RACE in realm/sim/commanders.lua")
    return int(hit.group(1))


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


def glyph_image(codepoint):
    """One Noto glyph as RGBA, from the cache or the network."""
    raw = fetch(NOTO_URL % (NOTO_REF, codepoint),
                os.path.join(CACHE, "emoji_u%s.png" % codepoint))
    return Image.open(io.BytesIO(raw)).convert("RGBA")


def sweep_stale(directory, wanted):
    """Delete PNGs the theme no longer names.

    A glyph dropped from main/theme.lua leaves its PNG behind, and a stale one
    on disk is indistinguishable from a live one when you go looking.
    """
    if not os.path.isdir(directory):
        return
    for stale in sorted(os.listdir(directory)):
        if stale.endswith(".png") and stale not in wanted:
            os.remove(os.path.join(directory, stale))
            print("removed stale %s" % stale)


def write_atlas(path, images, margin, label):
    """Rewrite an atlas from a list of project-absolute image paths.

    Generated rather than hand-maintained, exactly like main/ui.atlas: adding a
    glyph is one command and cannot be half-done. Written from the names
    main/theme.lua declared rather than from a directory listing, so a file left
    behind by an older run cannot creep back into the build. No `max_page_size`
    line - bob 1.13 rejects the field outright rather than ignoring it.
    """
    blocks = [
        'images {\n  image: "%s"\n  sprite_trim_mode: SPRITE_TRIM_MODE_OFF\n}' % p
        for p in images
    ]
    body = ("\n".join(blocks)
            + "\nmargin: %d\nextrude_borders: 2\ninner_padding: 0\n" % margin)
    with open(path, "w") as f:
        f.write(body)
    print("%s: %d images" % (label, len(images)))


def circular_mask(size):
    """A round alpha mask with a smooth edge, at `size` square."""
    big = size * MASK_SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, big - 1, big - 1), fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def make_face(img, size):
    """One emoji as a portrait medallion: centred on a disc, masked round.

    The backing matters for the same reason it did when these were painted
    busts - `ui.portrait` draws its ring *on top*, to cover the mask's soft
    edge, and a ring around nothing but a transparent glyph reads as a loose
    hoop rather than as a frame the officer is sitting inside.
    """
    inner = int(round(size * FACE_FILL))
    plate = Image.new("RGBA", (size, size), BACKING)
    plate.alpha_composite(img.resize((inner, inner), Image.LANCZOS),
                          ((size - inner) // 2, (size - inner) // 2))
    plate.putalpha(circular_mask(size))
    return plate


def export_faces(faces, size):
    """The officers' discs, plus main/portraits.atlas.

    Keys are `<race>_NN` and become `portrait_<race>_NN` - the ids
    `realm/sim/commanders.lua` already names, so nothing in the simulation, the
    wire or ui.portrait had to learn the art changed.

    Order is load-bearing and checked rather than assumed: a face is an
    officer's number modulo the cast, so a race short of a face would leave
    `commanders.portrait` naming an image the atlas lacks, and ui.portrait
    swallows a miss on purpose. tools/test_wire.lua is the other half of this.
    """
    per_race = faces_per_race()
    names, manifest = [], {}
    for race in race_ids():
        slots = sorted(k for k in faces if k.rsplit("_", 1)[0] == race)
        want = ["%s_%02d" % (race, i) for i in range(1, per_race + 1)]
        if slots != want:
            sys.exit("import_emoji: M.FACE_EMOJI %s has %s, wanted %s"
                     % (race, slots or "nothing", "%s_01..%02d" % (race, per_race)))
        manifest[race] = [faces[k] for k in want]
        names.extend("portrait_" + k for k in want)

    orphan = sorted(set(faces) - set(n[len("portrait_"):] for n in names))
    if orphan:
        sys.exit("import_emoji: M.FACE_EMOJI names no race in races.lua: %s"
                 % ", ".join(orphan))

    os.makedirs(FACE_DIR, exist_ok=True)
    sweep_stale(FACE_DIR, set(n + ".png" for n in names))
    for name in names:
        img = glyph_image(faces[name[len("portrait_"):]])
        make_face(img, size).save(os.path.join(FACE_DIR, name + ".png"))
    print("main/assets/portraits/: %d faces at %dpx (%d races x %d)"
          % (len(names), size, len(manifest), per_race))

    # A portrait is never scaled below its drawn size, and bleeding would smear
    # the disc's edge into the margin, so margin stays 0.
    write_atlas(FACE_ATLAS,
                ["/main/assets/portraits/%s.png" % n for n in names],
                0, "main/portraits.atlas")

    with open(os.path.join(FACE_DIR, "MANIFEST.json"), "w") as f:
        json.dump({"ref": NOTO_REF, "per_race": per_race, "size": size,
                   "fill": FACE_FILL, "faces": manifest},
                  f, indent=1, sort_keys=True)
        f.write("\n")


def export_atlas(glyphs, sizes):
    """One PNG per glyph, plus the atlas and the name -> image-id module.

    Both drawn vocabularies land here. The map used to sample UV rects out of a
    packed sheet, which a mesh shader can do and a GUI node cannot - that
    asymmetry is the whole reason there were two outputs. Drawing the map with
    *sprites* removes it, because a sprite cannot be handed a UV rect either.

    They are still exported at two *sizes*, because they are drawn at two: a map
    glyph is a sprite scaled to the hex and can fill the screen at the closest
    zoom, while an interface glyph never exceeds a 94-unit slot. Paying the map's
    size for six themes of unit art is the difference between one atlas page and
    two.
    """
    names = sorted(glyphs)
    os.makedirs(UI_DIR, exist_ok=True)
    sweep_stale(UI_DIR, set("emoji_%s.png" % n for n in names))

    for name in names:
        px = sizes[name]
        img = glyph_image(glyphs[name]).resize((px, px), Image.LANCZOS)
        img.save(os.path.join(UI_DIR, "emoji_%s.png" % name))
    tally = {}
    for n in names:
        tally[sizes[n]] = tally.get(sizes[n], 0) + 1
    print("main/assets/emoji/ui/: %s"
          % ", ".join("%d at %dpx" % (tally[p], p) for p in sorted(tally)))

    write_atlas(UI_ATLAS,
                ["/main/assets/emoji/ui/emoji_%s.png" % n for n in names],
                2, "main/emoji.atlas")

    # Name -> atlas image id, for every glyph the game can draw: the map's
    # sprites and the interface's GUI nodes both need an image *name*. Nothing
    # but a string connects main/theme.lua to the art, and tools/test_wire.lua
    # checks the join across this table.
    lines = [
        "-- Generated by tools/import_emoji.py - do not edit by hand.",
        "-- Noto emoji %s exported one glyph apiece into /main/emoji.atlas." % NOTO_REF,
        "-- Covers both drawn vocabularies: M.EMOJI (map sprites) and",
        "-- M.UNIT_EMOJI (GUI), the latter one entry per theme per unit type.",
        "return {",
    ]
    for name in names:
        lines.append('\t%s = "emoji_%s",' % (name, name))
    lines.append("}")
    with open(UI_MODULE, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("main/emoji_ui.lua: %d entries" % len(names))


def main():
    glyph_px = theme_number("GLYPH_PX")
    ui_px = theme_number("UI_PX")
    emoji = theme_table("EMOJI")
    units = theme_table("UNIT_EMOJI")
    faces = theme_table("FACE_EMOJI")
    names = sorted(emoji)
    if len(names) > GRID * GRID:
        sys.exit("import_emoji: %d glyphs do not fit a %dx%d sheet"
                 % (len(names), GRID, GRID))

    sheet = Image.new("RGBA", (SHEET_PX, SHEET_PX), (0, 0, 0, 0))
    manifest_cells = {}
    for i, name in enumerate(names):
        cp = emoji[name]
        img = glyph_image(cp).resize((GLYPH, GLYPH), Image.LANCZOS)
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

    # One atlas, both drawn vocabularies. A name in both tables would export one
    # PNG and silently give one of the two the other's glyph, so it is a hard
    # error rather than a last-writer-wins merge.
    clash = sorted(set(emoji) & set(units))
    if clash:
        sys.exit("import_emoji: %s in both M.EMOJI and M.UNIT_EMOJI"
                 % ", ".join(clash))
    merged = dict(emoji)
    merged.update(units)
    sizes = dict([(n, glyph_px) for n in emoji] + [(n, ui_px) for n in units])
    export_atlas(merged, sizes)

    # Faces share the interface size: ui.portrait draws them at 62 units in the
    # commander strip and 34 in the tile sheet, both under a unit slot.
    export_faces(faces, ui_px)

    license_text = fetch(LICENSE_URL % NOTO_REF,
                         os.path.join(CACHE, "LICENSE-%s" % NOTO_REF)).decode()
    header = ("Copyright 2013 Google LLC (https://github.com/googlefonts/noto-emoji)\n\n"
              "The Noto emoji artwork in this directory is licensed under the\n"
              "Apache License, Version 2.0. The license is copied below, and is\n"
              "also available at http://www.apache.org/licenses/LICENSE-2.0\n\n\n")
    for directory in (OUT_DIR, FACE_DIR):
        with open(os.path.join(directory, "NotoEmoji-LICENSE.txt"), "w") as f:
            f.write(header)
            f.write(license_text)

    with open(os.path.join(OUT_DIR, "CREDITS.txt"), "w") as f:
        f.write("""Map and interface emoji
=======================

Google Noto color emoji, from the googlefonts/noto-emoji repository at tag
%s. The artwork itself is unmodified; only its size and packing changed.

  sheet.png   the map's glyphs, downscaled to %dpx and centred in %dpx cells.
              A leftover of the mesh renderer; nothing reads it any more.
  ui/         one PNG apiece, packed by Defold into /main/emoji.atlas. Map
              glyphs at %dpx because a sprite is scaled to the hex; interface
              glyphs at %dpx because a rack slot is 94 design units.

Which glyphs each vocabulary uses is decided by main/theme.lua, and
MANIFEST.json here records exactly which codepoint became which.

LICENCE: Apache License, Version 2.0 - see NotoEmoji-LICENSE.txt beside this
file. Re-running the importer after editing main/theme.lua regenerates the
art, main/emoji.atlas and main/emoji_ui.lua together, so the mapping and the
art cannot drift apart.
""" % (NOTO_REF, GLYPH, CELL, glyph_px, ui_px))

    with open(os.path.join(FACE_DIR, "CREDITS.txt"), "w") as f:
        f.write("""Commander portraits
===================

Google Noto color emoji, from the googlefonts/noto-emoji repository at tag
%s. Each face is one unmodified Noto glyph, scaled to %.0f%% of a %dpx disc
of ui.CARD_ALT and masked round; ui.portrait draws its ring on top of that
edge.

Eight faces per theme, filling the `portrait_<race>_NN` ids
realm/sim/commanders.lua names. **The order is load-bearing**: an officer's
face is its number modulo the cast, so the nth officer a player raises always
has both the same name and the same face. Reordering a theme in
main/theme.lua's M.FACE_EMOJI silently reassigns every existing commander's
portrait; MANIFEST.json beside this file is what records which codepoint
became which face.

LICENCE: Apache License, Version 2.0 - see NotoEmoji-LICENSE.txt beside this
file.

This replaced seventy-two pieces of pixel art whose licence was never
established. It and its importer (tools/import_portraits.py) are gone; the ids
they filled are unchanged, which is why nothing in the simulation, the wire or
ui.portrait had to move.
""" % (NOTO_REF, FACE_FILL * 100, ui_px))

    with open(os.path.join(OUT_DIR, "MANIFEST.json"), "w") as f:
        json.dump({"ref": NOTO_REF, "grid": GRID, "cell": CELL, "glyph": GLYPH,
                   "uv_inset": INSET, "flip_v": FLIP_V, "glyphs": manifest_cells,
                   "glyph_px": glyph_px, "ui_px": ui_px,
                   "ui_glyphs": {n: {"codepoint": units[n]} for n in units}},
                  f, indent=1, sort_keys=True)
        f.write("\n")
    print("MANIFEST.json, CREDITS.txt, NotoEmoji-LICENSE.txt written")


if __name__ == "__main__":
    main()
