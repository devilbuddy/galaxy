#!/usr/bin/env python3
"""Generate the nebula backdrop into main/assets/.

Only the nebula is a texture. Stars, halos, region washes and lanes are drawn
procedurally in their fragment shaders instead (main/shaders/), because a
sprite is only ever as sharp as its texture and the map is zoomable - a 64px
disc magnified by a deep zoom looks soft. A nebula is genuinely a soft cloud,
so a texture is the right tool there and blur costs nothing.

Authored with straight alpha (Defold premultiplies at build time) and white RGB,
so the mesh's vertex colour controls the tint.
"""
import os
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "main", "assets")


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

    # Nebula: a few tinted fbm layers over a dark field, used on one big
    # parallax quad behind the map.
    rng = np.random.default_rng(20260823)
    size = 512
    neb = np.zeros((size, size, 3), dtype=np.float32)
    for tint, freq, gain in (
        ((0.24, 0.16, 0.52), 3, 0.85),   # violet
        ((0.10, 0.24, 0.52), 5, 0.65),   # blue
        ((0.42, 0.20, 0.30), 7, 0.40),   # dusty red
        ((0.14, 0.30, 0.34), 11, 0.30),  # teal
    ):
        n = fbm((size, size), freq, 5, rng)
        # Raising to a power keeps the clouds wispy instead of filling the frame.
        n = np.clip((n - 0.42) / 0.58, 0, 1) ** 1.7
        neb += n[..., None] * np.array(tint, dtype=np.float32) * gain
    alpha = np.clip(neb.max(axis=2) * 1.5, 0, 1)
    # Divide the tint back out so the stored RGB is the cloud colour and the
    # renderer can control overall strength with the vertex alpha alone.
    rgb = np.where(alpha[..., None] > 1e-3, neb / np.maximum(alpha[..., None], 1e-3), 0)
    save(np.dstack([np.clip(rgb, 0, 1), alpha]), "nebula.png")


if __name__ == "__main__":
    main()
