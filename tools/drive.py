#!/usr/bin/env python3
"""Drive a running debug build through the Automation Bridge.

Why this exists: before it, testing a change on the device meant guessing where
things were. Star positions were worked out by regenerating the galaxy offline
and solving for the camera from two reference taps; whether a tap had even
reached the game was answered by adding print statements and rebuilding. Both
are now questions the running engine will simply answer.

Select by meaning, never by coordinates - `click "SEND 1"` finds the node whose
text says that and clicks its centre. Coordinates change with the safe area, the
window size and the layout; text does not.

The bridge is debug-only: release builds expose neither the HTTP endpoint nor
the Lua module, so none of this ships.

    # device (forward the engine service port first)
    adb forward tcp:8001 tcp:8001
    python3 tools/drive.py find EMPIRE
    python3 tools/drive.py click RESUME
    python3 tools/drive.py shot /tmp/map.png

    # desktop, from the editor console line "Engine service started on port N"
    python3 tools/drive.py --port 60980 text
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..",
                                "automation-bridge-python"))

from automation_bridge import engine  # noqa: E402

DEFAULT_PORT = 8001


def connect(port, device=None):
    # A stable identity across invocations. The bridge leases the input
    # controller per session, so a fresh session per command means the second
    # one is refused with `input_controller_busy` - which is right for two
    # clients fighting, and wrong for one CLI used twice in a row.
    game = engine.Client(port, client_id="galaxy-drive", session_id="galaxy-drive")
    game.wait_ready()
    if device is None:
        # On a phone the game keys on `action.touch`: main/camera.script latches
        # `touch_driven` off the touch table and Druid's mobile path listens for
        # touch_multi, so a synthetic *mouse* click reaches neither. Match the
        # platform unless told otherwise.
        platform = (game.health().get("data", {}) or {}).get("platform", "")
        device = "touch" if platform == "android" or platform == "ios" else None
    game.default_device = device
    return game


def centre_of(element):
    """The element's screen centre in device pixels, or (None, None)."""
    c = getattr(element, "center", None) or {}
    if not c:
        bounds = getattr(element, "bounds", None)
        c = (getattr(bounds, "raw", bounds) or {}).get("center", {})
    return c.get("x"), c.get("y")


def text_elements(game):
    """Every text node on screen that says something."""
    out = []
    # The query paginates, and this project's HUD alone is well past the default
    # page: without a limit the sheet's own buttons are simply not in the answer.
    for e in game.elements(type="gui_node_text", visible=True, limit=1000):
        text = (e.text or "").strip()
        if text:
            out.append((text, e))
    return out


def visible_text(game):
    return [(t, *centre_of(e)) for t, e in text_elements(game)]


def cmd_text(game, _args):
    for text, x, y in visible_text(game):
        where = f"{x:7.0f},{y:7.0f}" if x is not None else "      ?,      ?"
        print(f"{where}  {text}")


def cmd_find(game, args):
    needle = args.what.lower()
    hits = [t for t in visible_text(game) if needle in t[0].lower()]
    if not hits:
        print(f"no visible text matching {args.what!r}")
        return 1
    for text, x, y in hits:
        where = f"{x:7.0f},{y:7.0f}" if x is not None else "      ?,      ?"
        print(f"{where}  {text}")
    return 0


def cmd_click(game, args):
    """Click the element whose text matches, and wait for the engine to say so.

    `wait="released"` is the whole point: the call returns once the engine has
    actually delivered press *and* release, so a screenshot taken afterwards is
    of the frame after the click rather than a race against a sleep.
    """
    needle = args.what.lower()
    hits = [(t, e) for t, e in text_elements(game) if needle in t.lower()]
    if not hits:
        print(f"no visible text matching {args.what!r}")
        return 1
    if len(hits) > 1 and not args.first:
        print(f"{args.what!r} is ambiguous ({len(hits)} matches); "
              f"pass --first or be more specific:")
        for t, _ in hits:
            print("   ", t)
        return 1
    label, target = hits[0]
    x, y = centre_of(target)
    game.click(target, wait="released", device=game.default_device)
    print(f"clicked {label!r} at {x:.0f},{y:.0f}")
    return 0


def cmd_tap(game, args):
    game.click((args.x, args.y), wait="released", device=game.default_device)
    print(f"tapped {args.x},{args.y}")


def cmd_shot(game, args):
    shot = game.screenshot(wait=True)
    data = shot.read() if hasattr(shot, "read") else shot
    if isinstance(data, (bytes, bytearray)):
        with open(args.path, "wb") as f:
            f.write(data)
    else:
        print(data)
        return 0
    print(f"wrote {args.path}")
    return 0


def view_state(game):
    """The transform the game publishes (main/automation.lua)."""
    snap = game.state("galaxy.view")
    return getattr(snap, "value", None) or {}


def world_to_device(v, wx, wy):
    """World position -> device pixel, exactly as the map projects it.

    This is why main/automation.lua exists. The bridge's own GUI bounds are in
    Defold's configured display space, which this project does not render in.
    """
    sx = (wx - v["camera_x"]) * v["zoom"] + v["view_width"] * 0.5
    sy = (wy - v["camera_y"]) * v["zoom"] + v["view_height"] * 0.5
    return (sx * v["pixel_width"] / v["view_width"],
            v["pixel_height"] - sy * v["pixel_height"] / v["view_height"])


def star_positions(seed):
    """Every star in the seed's galaxy, as name -> (x, y).

    Generated rather than transmitted: the galaxy is a pure function of the seed
    and the generator runs standalone under luajit, so there is no reason for the
    game to send two hundred positions it can regenerate in fifty milliseconds.
    """
    import subprocess
    lua = (
        'package.path="./?.lua;"..package.path '
        'local g=require("galaxy.generate").build(%d) '
        'for i=1,#g.stars do local s=g.stars[i] '
        'print(string.format("%%d\\t%%s\\t%%f\\t%%f",s.id,s.name,s.x,s.y)) end'
    ) % seed
    out = subprocess.run(["luajit", "-e", lua], capture_output=True, text=True,
                         cwd=os.path.join(os.path.dirname(__file__), ".."))
    if out.returncode != 0:
        raise SystemExit("could not generate the galaxy: " + out.stderr.strip())
    stars = {}
    for line in out.stdout.splitlines():
        sid, name, x, y = line.split("\t")
        stars[name] = (int(sid), float(x), float(y))
    return stars


def resolve_star(game, name):
    v = view_state(game)
    if not v:
        raise SystemExit("no galaxy.view state - is this a debug build on the map?")
    stars = star_positions(int(v["seed"]))
    needle = name.lower()
    hits = [(n, d) for n, d in stars.items() if needle in n.lower()]
    if not hits:
        raise SystemExit(f"no star matching {name!r}")
    if len(hits) > 1:
        exact = [h for h in hits if h[0].lower() == needle]
        if not exact:
            raise SystemExit(f"{name!r} is ambiguous: "
                             + ", ".join(sorted(n for n, _ in hits))[:200])
        hits = exact
    star_name, (sid, wx, wy) = hits[0]
    x, y = world_to_device(v, wx, wy)
    return star_name, sid, x, y


def cmd_star(game, args):
    name, sid, x, y = resolve_star(game, args.name)
    print(f"{name} (id {sid}) is at device {x:.0f},{y:.0f}")


def cmd_tapstar(game, args):
    name, sid, x, y = resolve_star(game, args.name)
    game.click((x, y), wait="released", device=game.default_device)
    print(f"tapped {name} (id {sid}) at {x:.0f},{y:.0f}")


def cmd_state(game, _args):
    import json
    v = view_state(game)
    if not v:
        print("no galaxy.view published (debug build? on the map screen?)")
        return 1
    print(json.dumps(v, indent=1, sort_keys=True))
    return 0


def cmd_health(game, _args):
    info = game.health()
    data = info.get("data", info)
    print("platform:", data.get("platform"), "| debug:", data.get("debug"))
    print("capabilities:", len(data.get("capabilities", [])))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", choices=("mouse", "touch"),
                    help="input device to synthesise; defaults to the platform's")
    ap.add_argument("--port", type=int, default=int(os.environ.get(
        "GALAXY_ENGINE_PORT", DEFAULT_PORT)))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("health")
    sub.add_parser("text", help="every visible text node and where it is")
    p = sub.add_parser("find", help="visible text matching a substring")
    p.add_argument("what")
    p = sub.add_parser("click", help="click the node whose text matches")
    p.add_argument("what")
    p.add_argument("--first", action="store_true",
                   help="take the first match when several fit")
    p = sub.add_parser("tap", help="click a raw screen point")
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    p = sub.add_parser("shot")
    p.add_argument("path")
    sub.add_parser("state", help="the transform and selection the game publishes")
    p = sub.add_parser("star", help="where a star is, in device pixels")
    p.add_argument("name")
    p = sub.add_parser("tapstar", help="click a star by name")
    p.add_argument("name")
    args = ap.parse_args()

    game = connect(args.port, args.device)
    return {
        "health": cmd_health, "text": cmd_text, "find": cmd_find,
        "click": cmd_click, "tap": cmd_tap, "shot": cmd_shot,
        "state": cmd_state, "star": cmd_star, "tapstar": cmd_tapstar,
    }[args.cmd](game, args) or 0


if __name__ == "__main__":
    sys.exit(main())
