#!/usr/bin/env python3
"""Deterministic generator for the Milestone 2 scene assets.

Usage (from the repository root):

    python3 tests/scenes/assets/generate.py

Writes ``checker16.rgba`` and ``mask16.rgba`` next to this script. The outputs
are 16x16 straight-alpha RGBA8, row-major, no padding (1024 bytes each). The
generator is intentionally free of randomness and platform-dependent code so
the committed bytes can be reproduced exactly.

checker16.rgba
    4x4-pixel checkerboard cells (magenta / cyan), except:
      - top-right 8x8 quadrant (x >= 8, y < 8): fully transparent,
      - bottom-left 8x8 quadrant (x < 8, y >= 8): straight-alpha ramp
        ``a = 15 + 16 * (x + (y - 8))`` (15..239).

mask16.rgba
    Constant color (255, 64, 0) with a radial straight-alpha ramp,
    ``a = round(255 * (1 - d / d_max))`` around the image center (7.5, 7.5),
    where ``d_max`` is the center-to-corner distance. Used by both the alpha
    and the luminance mask scenes; a colored mask makes the two conversions
    produce different coverage.
"""

from pathlib import Path
import math

HERE = Path(__file__).resolve().parent


def checker16() -> bytes:
    pixels = bytearray()
    for y in range(16):
        for x in range(16):
            cell_x, cell_y = x // 4, y // 4
            if (cell_x + cell_y) % 2 == 0:
                r, g, b = 255, 0, 255
            else:
                r, g, b = 0, 255, 255
            a = 255
            if x >= 8 and y < 8:
                r = g = b = a = 0
            elif x < 8 and y >= 8:
                a = 15 + 16 * (x + (y - 8))
            pixels += bytes((r, g, b, a))
    return bytes(pixels)


def mask16() -> bytes:
    pixels = bytearray()
    center = 7.5
    max_d = math.hypot(center, center)
    for y in range(16):
        for x in range(16):
            d = math.hypot(x - center, y - center)
            a = int(math.floor(255.0 * (1.0 - d / max_d) + 0.5))
            pixels += bytes((255, 64, 0, max(0, min(255, a))))
    return bytes(pixels)


def main() -> None:
    (HERE / "checker16.rgba").write_bytes(checker16())
    (HERE / "mask16.rgba").write_bytes(mask16())


if __name__ == "__main__":
    main()
