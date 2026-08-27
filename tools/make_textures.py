#!/usr/bin/env python3
"""Generate the parchment backdrop into main/assets/.

The file is still called nebula.png - it feeds the same mesh through the same
material - but what it carries now is the paper: the *mottle deviation* over a
flat base that IS the clear colour (game.project [render] and the render
script's fallback, 0.935/0.870/0.745). RGB is the mottle tint and alpha its
strength, so the zoom fade that used to dissolve the nebula now reads as the
mottle fading to clean flat parchment up close - which is what magnifying
soft paper stains should do, and why a low-frequency texture is still the
right tool here where every shape layer is procedural (main/shaders/): blur
survives magnification, detail does not.

The tones mirror tools/render_map.py's PARCHMENT/MOTTLE constants - the sketch
is the spec.

Authored with straight alpha (Defold premultiplies at build time).
"""
import os
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "main", "assets")

# The sketch's MOTTLE tint (tools/render_map.py); the base parchment lives in
# the clear colour, not in this texture.
MOTTLE = (0.860, 0.765, 0.590)


def save(arr, name):
    img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), mode="RGBA")
    path = os.path.abspath(os.path.join(OUT, name))
    img.save(path)
    print(f"{name}: {img.size[0]}x{img.size[1]}")


def value_noise(shape, freq, rng):
    """Periodic value noise via a low-res lattice scaled up smoothly."""
    lattice = rng.random((freq, freq)).astype(np.float32)
    # Tile by one so bilinear interpolation wraps seamlessly.
    lattice = np.pad(lattice, ((0, 1), (0, 1)), mode="wrap")
    ys = np.linspace(0, freq, shape[0], endpoint=False)
    xs = np.linspace(0, freq, shape[1], endpoint=False)
    y0, x0 = np.floor(ys).astype(int), np.floor(xs).astype(int)
    fy, fx = (ys - y0)[:, None], (xs - x0)[None, :]
    # Quintic fade removes the visible lattice creasing.
    fy = fy ** 3 * (fy * (fy * 6 - 15) + 10)
    fx = fx ** 3 * (fx * (fx * 6 - 15) + 10)
    a = lattice[np.ix_(y0, x0)]
    b = lattice[np.ix_(y0, x0 + 1)]
    c = lattice[np.ix_(y0 + 1, x0)]
    d = lattice[np.ix_(y0 + 1, x0 + 1)]
    top = a + (b - a) * fx
    bot = c + (d - c) * fx
    return top + (bot - top) * fy


def fbm(shape, base_freq, octaves, rng):
    total = np.zeros(shape, dtype=np.float32)
    amp, norm, freq = 1.0, 0.0, base_freq
    for _ in range(octaves):
        total += amp * value_noise(shape, freq, rng)
        norm += amp
        amp *= 0.5
        freq *= 2
    return total / norm

def main():
    os.makedirs(os.path.abspath(OUT), exist_ok=True)

    # Parchment mottle: broad soft stains plus a finer grain, mirroring the
    # sketch renderer's (12, 0.34) / (48, 0.14) / (160, 0.06) octave weights.
    rng = np.random.default_rng(20260827)
    size = 512
    alpha = np.zeros((size, size), dtype=np.float32)
    for freq, octaves, strength in ((3, 4, 0.34), (12, 3, 0.14), (40, 2, 0.06)):
        n = fbm((size, size), freq, octaves, rng)
        alpha += np.clip(n - 0.45, 0, 1) * strength
    alpha = np.clip(alpha, 0, 1)

    rgb = np.ones((size, size, 3), dtype=np.float32) * np.array(MOTTLE, dtype=np.float32)
    save(np.dstack([rgb, alpha]), "nebula.png")


if __name__ == "__main__":
    main()
