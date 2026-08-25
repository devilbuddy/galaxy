#!/usr/bin/env python3
"""Generate the interface atlas into main/assets/ui/.

Everything here is a shape, not artwork: rounded panels used as 9-slices, and a
set of monochrome glyphs. Generating them keeps the look consistent (one corner
radius, one stroke weight, one optical size) and means a change to the design
language is a change to this file rather than to twenty PNGs.

All images are white with straight alpha, so the GUI node's colour is the only
thing that decides what tint they come out as - the same panel texture is a
card, a divider, a progress bar and a badge.

Run after changing anything below:  python3 tools/make_ui_textures.py
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "main", "assets", "ui")
ATLAS = os.path.join(ROOT, "main", "ui.atlas")

# Everything is drawn at this multiple and downsampled, which is cheaper to
# write than analytic antialiasing and indistinguishable at these sizes.
SS = 4

PANEL = 64          # 9-slice panels
PANEL_RADIUS = 18
ICON = 72           # glyphs
STROKE = 6          # glyph stroke weight, in icon units


def canvas(size):
    img = Image.new("RGBA", (size * SS, size * SS), (255, 255, 255, 0))
    return img, ImageDraw.Draw(img)


def save(img, name, size):
    img = img.resize((size, size), Image.LANCZOS)
    path = os.path.join(OUT, name + ".png")
    img.save(path)
    print(f"{name}.png {size}x{size}")


def white(alpha=255):
    return (255, 255, 255, alpha)


# Panels -----------------------------------------------------------------------

def rounded(name, radius, stroke=None):
    """A filled or stroked rounded rectangle, for use as a 9-slice."""
    img, d = canvas(PANEL)
    box = [0, 0, PANEL * SS - 1, PANEL * SS - 1]
    if stroke:
        inset = stroke * SS / 2
        d.rounded_rectangle([box[0] + inset, box[1] + inset,
                             box[2] - inset, box[3] - inset],
                            radius=radius * SS, outline=white(), width=stroke * SS)
    else:
        d.rounded_rectangle(box, radius=radius * SS, fill=white())
    save(img, name, PANEL)


# Glyphs -----------------------------------------------------------------------
#
# Each is drawn in a 72-unit box with a little breathing room, so a set of icons
# at the same node size reads as the same weight.

def poly(d, points, fill=True, width=STROKE, close=True):
    pts = [(x * SS, y * SS) for x, y in points]
    if fill:
        d.polygon(pts, fill=white())
    else:
        if close:
            pts = pts + [pts[0]]
        d.line(pts, fill=white(), width=width * SS, joint="curve")


def circle(d, cx, cy, r, fill=True, width=STROKE):
    box = [(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS]
    if fill:
        d.ellipse(box, fill=white())
    else:
        d.ellipse(box, outline=white(), width=width * SS)


def line(d, a, b, width=STROKE):
    d.line([(a[0] * SS, a[1] * SS), (b[0] * SS, b[1] * SS)],
           fill=white(), width=width * SS)


CLEAR = (0, 0, 0, 0)


def cut_line(d, a, b, width=3):
    """Punch a transparent seam. White-on-white detail is invisible, so any
    interior edge has to be taken *out* of the glyph rather than drawn on it."""
    d.line([(a[0] * SS, a[1] * SS), (b[0] * SS, b[1] * SS)],
           fill=CLEAR, width=width * SS)


def cut_circle(d, cx, cy, r):
    d.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS],
              fill=CLEAR)


def icon_metal():
    """An isometric ingot: mass you dig up."""
    img, d = canvas(ICON)
    poly(d, [(36, 12), (60, 26), (36, 40), (12, 26)])
    poly(d, [(12, 26), (36, 40), (36, 62), (12, 48)])
    poly(d, [(60, 26), (60, 48), (36, 62), (36, 40)])
    # Without these the three faces merge into one hexagonal blob.
    cut_line(d, (36, 40), (36, 63))
    cut_line(d, (12, 26), (36, 40))
    cut_line(d, (60, 26), (36, 40))
    return img


def icon_fuel():
    """A droplet."""
    img, d = canvas(ICON)
    poly(d, [(36, 10), (58, 40), (58, 46), (36, 62), (14, 46), (14, 40)])
    return img


def icon_research():
    """A hexagon around a nucleus: knowledge as something structured."""
    img, d = canvas(ICON)
    pts = [(36 + 26 * math.cos(math.radians(a)),
            36 + 26 * math.sin(math.radians(a))) for a in range(-90, 270, 60)]
    poly(d, pts, fill=False, width=6)
    circle(d, 36, 36, 8)
    return img


def icon_warship():
    """A dart, pointing the way it is going."""
    img, d = canvas(ICON)
    poly(d, [(36, 8), (58, 56), (36, 46), (14, 56)])
    return img


def icon_freighter():
    """A blunt hull with cargo cells: obviously not a warship."""
    img, d = canvas(ICON)
    poly(d, [(10, 22), (62, 22), (53, 54), (19, 54)])
    for x in (26, 36, 46):
        cut_circle(d, x, 38, 4)
    return img


def icon_check():
    img, d = canvas(ICON)
    d.line([(16 * SS, 38 * SS), (30 * SS, 52 * SS), (57 * SS, 22 * SS)],
           fill=white(), width=8 * SS, joint="curve")
    return img


def icon_lock():
    img, d = canvas(ICON)
    d.rounded_rectangle([16 * SS, 34 * SS, 56 * SS, 62 * SS],
                        radius=6 * SS, fill=white())
    d.arc([24 * SS, 12 * SS, 48 * SS, 44 * SS], 180, 360,
          fill=white(), width=7 * SS)
    return img


def icon_close():
    img, d = canvas(ICON)
    line(d, (20, 20), (52, 52), width=7)
    line(d, (52, 20), (20, 52), width=7)
    return img


def icon_chevron_right():
    img, d = canvas(ICON)
    d.line([(26 * SS, 16 * SS), (48 * SS, 36 * SS), (26 * SS, 56 * SS)],
           fill=white(), width=7 * SS, joint="curve")
    return img


def icon_chevron_left():
    return icon_chevron_right().transpose(Image.FLIP_LEFT_RIGHT)


def icon_attack():
    """Crosshair."""
    img, d = canvas(ICON)
    circle(d, 36, 36, 22, fill=False, width=6)
    line(d, (36, 4), (36, 20), width=6)
    line(d, (36, 52), (36, 68), width=6)
    line(d, (4, 36), (20, 36), width=6)
    line(d, (52, 36), (68, 36), width=6)
    return img


def icon_defence():
    """Shield."""
    img, d = canvas(ICON)
    poly(d, [(36, 8), (60, 18), (60, 38), (36, 64), (12, 38), (12, 18)])
    return img


def icon_speed():
    """Bolt."""
    img, d = canvas(ICON)
    poly(d, [(42, 6), (18, 40), (33, 40), (28, 66), (54, 30), (38, 30)])
    return img


def icon_industry():
    """Gear."""
    img, d = canvas(ICON)
    for i in range(8):
        a = math.radians(i * 45)
        cx, cy = 36 + 25 * math.cos(a), 36 + 25 * math.sin(a)
        d.rounded_rectangle([(cx - 6) * SS, (cy - 6) * SS,
                             (cx + 6) * SS, (cy + 6) * SS],
                            radius=2 * SS, fill=white())
    circle(d, 36, 36, 21)
    # Punch the hub out so it reads as a gear and not a blob.
    box = [(36 - 8) * SS, (36 - 8) * SS, (36 + 8) * SS, (36 + 8) * SS]
    d.ellipse(box, fill=(255, 255, 255, 0))
    return img


def icon_growth():
    """A figure: population."""
    img, d = canvas(ICON)
    circle(d, 36, 20, 11)
    poly(d, [(18, 64), (22, 44), (50, 44), (54, 64)])
    return img


def icon_vision():
    """Eye."""
    img, d = canvas(ICON)
    d.ellipse([8 * SS, 20 * SS, 64 * SS, 52 * SS], outline=white(), width=6 * SS)
    circle(d, 36, 36, 9)
    return img


def icon_trade():
    """Two arrows, out and back: a route rather than a journey."""
    img, d = canvas(ICON)
    d.line([(14 * SS, 24 * SS), (58 * SS, 24 * SS)], fill=white(), width=6 * SS)
    poly(d, [(48, 14), (62, 24), (48, 34)])
    d.line([(58 * SS, 48 * SS), (14 * SS, 48 * SS)], fill=white(), width=6 * SS)
    poly(d, [(24, 38), (10, 48), (24, 58)])
    return img


def icon_capacity():
    """A world with a latitude line: how many people somewhere holds."""
    img, d = canvas(ICON)
    circle(d, 36, 36, 26, fill=False, width=6)
    d.arc([12 * SS, 22 * SS, 60 * SS, 50 * SS], 0, 360, fill=white(), width=3 * SS)
    line(d, (11, 36), (61, 36), width=3)
    return img


def icon_star():
    """Four-pointed star: a system."""
    img, d = canvas(ICON)
    poly(d, [(36, 4), (44, 28), (68, 36), (44, 44), (36, 68), (28, 44),
             (4, 36), (28, 28)])
    return img


def icon_flag():
    """Pennant: something held."""
    img, d = canvas(ICON)
    d.line([(20 * SS, 8 * SS), (20 * SS, 66 * SS)], fill=white(), width=6 * SS)
    poly(d, [(24, 12), (58, 22), (24, 34)])
    return img


def icon_clock():
    img, d = canvas(ICON)
    circle(d, 36, 36, 26, fill=False, width=6)
    line(d, (36, 36), (36, 20), width=5)
    line(d, (36, 36), (49, 42), width=5)
    return img


def icon_menu():
    img, d = canvas(ICON)
    for y in (22, 36, 50):
        d.rounded_rectangle([16 * SS, (y - 3) * SS, 56 * SS, (y + 3) * SS],
                            radius=3 * SS, fill=white())
    return img


def icon_plus():
    """Zoom in. A plus, not a magnifier with a plus in it: at 60 units square
    the lens reads as a smudge and the sign inside it is unreadable."""
    img, d = canvas(ICON)
    d.rounded_rectangle([16 * SS, 33 * SS, 56 * SS, 39 * SS],
                        radius=3 * SS, fill=white())
    d.rounded_rectangle([33 * SS, 16 * SS, 39 * SS, 56 * SS],
                        radius=3 * SS, fill=white())
    return img


def icon_minus():
    img, d = canvas(ICON)
    d.rounded_rectangle([16 * SS, 33 * SS, 56 * SS, 39 * SS],
                        radius=3 * SS, fill=white())
    return img


def icon_frame():
    """Four corner brackets: fit the whole galaxy on screen."""
    img, d = canvas(ICON)
    near, far, arm, weight = 15, 57, 16, 6
    for x_out, y_out in ((near, near), (far, near), (near, far), (far, far)):
        x_in = x_out + (arm if x_out == near else -arm)
        y_in = y_out + (arm if y_out == near else -arm)
        x_cap = x_out + (weight if x_out == near else -weight)
        y_cap = y_out + (weight if y_out == near else -weight)
        for box in ([x_out, y_out, x_in, y_cap], [x_out, y_out, x_cap, y_in]):
            d.rounded_rectangle(
                [min(box[0], box[2]) * SS, min(box[1], box[3]) * SS,
                 max(box[0], box[2]) * SS, max(box[1], box[3]) * SS],
                radius=3 * SS, fill=white())
    return img


def icon_play():
    """Solid triangle, optically centred - a play glyph balanced on its
    bounding box reads as sitting too far left, because the mass is."""
    img, d = canvas(ICON)
    d.polygon([(26 * SS, 16 * SS), (58 * SS, 36 * SS), (26 * SS, 56 * SS)],
              fill=white())
    return img


def icon_pause():
    img, d = canvas(ICON)
    for x in (22, 40):
        d.rounded_rectangle([x * SS, 16 * SS, (x + 10) * SS, 56 * SS],
                            radius=3 * SS, fill=white())
    return img


ICONS = {
    "icon_metal": icon_metal,
    "icon_fuel": icon_fuel,
    "icon_research": icon_research,
    "icon_warship": icon_warship,
    "icon_freighter": icon_freighter,
    "icon_check": icon_check,
    "icon_lock": icon_lock,
    "icon_close": icon_close,
    "icon_chevron_right": icon_chevron_right,
    "icon_chevron_left": icon_chevron_left,
    "icon_attack": icon_attack,
    "icon_defence": icon_defence,
    "icon_speed": icon_speed,
    "icon_industry": icon_industry,
    "icon_growth": icon_growth,
    "icon_vision": icon_vision,
    "icon_trade": icon_trade,
    "icon_capacity": icon_capacity,
    "icon_star": icon_star,
    "icon_flag": icon_flag,
    "icon_clock": icon_clock,
    "icon_menu": icon_menu,
    "icon_plus": icon_plus,
    "icon_minus": icon_minus,
    "icon_frame": icon_frame,
    "icon_play": icon_play,
    "icon_pause": icon_pause,
}


def write_atlas():
    """Rewrite main/ui.atlas from whatever is in the output directory.

    Generated rather than hand-maintained so adding a glyph is one command and
    cannot be half-done. Note there is no `max_page_size` line: bob 1.13
    rejects the field outright rather than ignoring it.
    """
    names = sorted(n for n in os.listdir(OUT) if n.endswith(".png"))
    blocks = [
        'images {\n  image: "/main/assets/ui/%s"\n'
        "  sprite_trim_mode: SPRITE_TRIM_MODE_OFF\n}" % n
        for n in names
    ]
    # extrude_borders stops bilinear sampling pulling in a neighbouring image
    # when a 9-slice stretches an edge row.
    body = "\n".join(blocks) + "\nmargin: 2\nextrude_borders: 2\ninner_padding: 0\n"
    with open(ATLAS, "w") as f:
        f.write(body)
    print(f"main/ui.atlas: {len(names)} images")


def main():
    os.makedirs(OUT, exist_ok=True)

    # 9-slices. The radius is the whole visual identity of the interface, so
    # there is exactly one of it, plus a pill for chips and badges.
    rounded("panel", PANEL_RADIUS)
    rounded("panel_line", PANEL_RADIUS, stroke=2)
    rounded("pill", PANEL // 2)
    rounded("pill_line", PANEL // 2, stroke=2)

    # A plain square, for dividers, bars and anything that wants no radius.
    img, d = canvas(8)
    d.rectangle([0, 0, 8 * SS, 8 * SS], fill=white())
    save(img, "solid", 8)

    for name, fn in sorted(ICONS.items()):
        save(fn(), name, ICON)

    write_atlas()


if __name__ == "__main__":
    main()
