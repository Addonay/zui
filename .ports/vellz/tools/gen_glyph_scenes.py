#!/usr/bin/env python3
"""Generate the M3 `glyph_run` scenes under `tests/scenes/`.

The scenes carry explicit positioned glyph lists (this port never shapes), so
the generator only needs the font's cmap (character -> glyph id) and hmtx
(advances), read through the existing `vellz-cli --dump-cmap` /
`--dump-glyphs` dumps. Run it after changing a layout below, then regenerate
the fixtures with:

    tools/render_corpus.sh --png

Scene parameters mirror the pinned upstream `vello_tests/tests/glyph.rs`
cases (`glyphs_filled_unhinted`, `glyphs_skewed_unhinted`,
`glyphs_scaled_unhinted`, `glyphs_glyph_transform_unhinted`,
`glyphs_stroked_unhinted`, `glyphs_small_unhinted`,
`glyphs_transform_composition_rows_outline`, `glyphs_with_gradient`), with
hinting forced off because the interpreter is not ported yet.
"""

import json
import math
import os
import struct
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "zig-out", "bin", "vellz-cli")
FONT_REL = "../fixtures/upstream/Roboto-Regular.ttf"
FONT = os.path.join(ROOT, "tests", "fixtures", "upstream", "Roboto-Regular.ttf")
UPEM = 2048.0

# CSS palette values used by the upstream tests.
REBECCA_PURPLE = [102, 51, 153, 255]
REBECCA_PURPLE_HALF = [102, 51, 153, 128]
BLACK = [0, 0, 0, 255]
BLUE = [0, 0, 255, 255]
GREEN = [0, 128, 0, 255]
RED = [255, 0, 0, 255]
YELLOW = [255, 255, 0, 255]


# ---------------------------------------------------------------- geometry
# `kurbo::Affine` composition: `mul(a, b)` applies `b` first, then `a`.


def translate(x, y):
    return [1.0, 0.0, 0.0, 1.0, x, y]


def scale(s):
    return [s, 0.0, 0.0, s, 0.0, 0.0]


def rotate(theta):
    c, s = math.cos(theta), math.sin(theta)
    return [c, s, -s, c, 0.0, 0.0]


def skew(skew_x, skew_y):
    return [1.0, skew_y, skew_x, 1.0, 0.0, 0.0]


def mul(a, b):
    return [
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    ]


# ---------------------------------------------------------------- font data


def run_cli(args):
    return subprocess.run(
        [CLI, *args], check=True, capture_output=True, text=True
    ).stdout


def dump_cmap(codepoints):
    text = run_cli(
        [
            "--dump-cmap",
            "--font",
            FONT,
            "--codepoints",
            ",".join(str(cp) for cp in sorted(set(codepoints))),
        ]
    )
    mapping = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "cp" and parts[2] == "gid":
            mapping[int(parts[1])] = None if parts[3] == "none" else int(parts[3])
    return mapping


def dump_advances(glyph_ids):
    text = run_cli(
        [
            "--dump-glyphs",
            "--font",
            FONT,
            "--size",
            "2048",
            "--gids",
            ",".join(str(g) for g in sorted(set(glyph_ids))),
        ]
    )
    advances = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 8 or parts[0] != "gid":
            continue
        advance = parts[-1]
        # `--dump-glyphs` prints the f32 bit pattern as a hexadecimal word in
        # natural (big-endian) order, so decode it big-endian. Decoding
        # little-endian yields ~1e-38 denormals and collapses every run to
        # x = 0; the M3 baseline scenes were generated that way (see the T5
        # report; regenerating them is a separate task).
        advances[int(parts[1])] = (
            0.0
            if advance == "none"
            else struct.unpack(">f", bytes.fromhex(advance))[0]
        )
    return advances


class Layout:
    """Explicitly positions glyphs using hmtx advances (no shaping/kerning)."""

    def __init__(self):
        self.cmap = {}
        self.advances = {}

    def prepare(self, texts):
        codepoints = [ord(c) for text in texts for c in text if c != "\n"]
        self.cmap = dump_cmap(codepoints)
        ids = [self.cmap[cp] for cp in codepoints if self.cmap.get(cp) is not None]
        self.advances = dump_advances(ids)

    def run(self, text, size, origin_x=0.0, origin_y=0.0):
        glyphs = []
        x = origin_x
        y = origin_y
        for ch in text:
            if ch == "\n":
                y += size
                x = origin_x
                continue
            gid = self.cmap.get(ord(ch))
            if gid is None:
                raise SystemExit(f"glyph missing for {ch!r}")
            glyphs.append({"id": gid, "x": round(x, 6), "y": round(y, 6)})
            x += self.advances[gid] * size / UPEM
        return glyphs


# ------------------------------------------------------------- scene output


def glyph_run(
    glyphs,
    font_size,
    *,
    hint=False,
    atlas_cache=False,
    style="fill",
    glyph_transform=None,
):
    command = {
        "op": "glyph_run",
        "font": {"asset": FONT_REL, "index": 0},
        "font_size": font_size,
        "hint": hint,
        "atlas_cache": atlas_cache,
        "style": style,
        "glyphs": glyphs,
    }
    if glyph_transform is not None:
        command["glyph_transform"] = glyph_transform
    return command


def scene(width, height, commands):
    return {
        "version": 1,
        "width": width,
        "height": height,
        "settings": {"mode": "quality", "threads": 0, "level": "fallback"},
        "target_init": "clear",
        "commands": commands,
    }


def write(name, document):
    path = os.path.join(ROOT, "tests", "scenes", name)
    with open(path, "w") as handle:
        json.dump(document, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"wrote {os.path.relpath(path, ROOT)}")


def decorated_run(layout, text, size, *, offset, decor_size, buffer, cache, glyph_transform=None):
    """A fill run plus a skip-ink decoration, matching upstream
    `render_decorated_text` (with hinting forced off; see module docstring)."""
    glyphs = layout.run(text, size)
    x_end = glyphs[-1]["x"] + size * 0.6 if glyphs else 0.0
    command = glyph_run(glyphs, size, atlas_cache=cache, glyph_transform=glyph_transform)
    command["decoration"] = {
        "x_range": [0.0, round(x_end, 6)],
        "baseline_y": 0.0,
        "offset": offset,
        "size": decor_size,
        "buffer": buffer,
    }
    return [
        {"op": "set_paint", "rgba8": REBECCA_PURPLE},
        command,
    ]


def fill_run(layout, text, size, baseline, color, cache, style="fill", glyph_transform=None):
    return [
        {"op": "set_paint", "rgba8": color},
        {"op": "set_transform", "affine": translate(0.0, baseline)},
        glyph_run(
            layout.run(text, size),
            size,
            atlas_cache=cache,
            style=style,
            glyph_transform=glyph_transform,
        ),
    ]


def main():
    if not os.path.exists(CLI):
        raise SystemExit(f"missing {CLI}; run `zig build vellz-cli` first")

    layout = Layout()
    layout.prepare(
        [
            "Hello, world!",
            "Hello,\nworld!",
            "Lorem ipsum dolor sit amet,",
            "consectetur adipiscing elit.",
            "Sed ornare arcu lectus.",
            "Hello World",
            "Happy joyful",
            "HELLO",
            "Happy",
        ]
    )

    # glyphs_filled_unhinted (+ cache-on variant).
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        write(
            f"glyph_run_filled_unhinted{suffix}_300x70.json",
            scene(
                300,
                70,
                fill_run(layout, "Hello, world!", 50.0, 50.0, REBECCA_PURPLE_HALF, cache),
            ),
        )

    # glyphs_small_unhinted.
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        write(
            f"glyph_run_small_unhinted{suffix}_64x16.json",
            scene(
                64,
                16,
                fill_run(layout, "Hello, world!", 10.0, 10.0, REBECCA_PURPLE, cache),
            ),
        )

    # glyphs_skewed_unhinted (fake italic via glyph transform).
    slant = skew(math.tan(-20.0 / 180.0 * math.pi), 0.0)
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        write(
            f"glyph_run_skewed_unhinted{suffix}_300x70.json",
            scene(
                300,
                70,
                fill_run(
                    layout,
                    "Hello, world!",
                    50.0,
                    50.0,
                    REBECCA_PURPLE_HALF,
                    cache,
                    glyph_transform=slant,
                ),
            ),
        )

    # glyphs_scaled_unhinted / glyphs_glyph_transform_unhinted: the run
    # transform carries `translate(0, size).then_scale(2)`; the uniform scale
    # is absorbed into the draw font size.
    two_lines = layout.run("Hello,\nworld!", 25.0)
    scaled_transform = mul(scale(2.0), translate(0.0, 25.0))
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        write(
            f"glyph_run_scaled_unhinted{suffix}_150x125.json",
            scene(
                150,
                125,
                [
                    {"op": "set_paint", "rgba8": REBECCA_PURPLE_HALF},
                    {"op": "set_transform", "affine": scaled_transform},
                    glyph_run(two_lines, 25.0, atlas_cache=cache),
                ],
            ),
        )
        write(
            f"glyph_run_glyph_transform_unhinted{suffix}_150x125.json",
            scene(
                150,
                125,
                [
                    {"op": "set_paint", "rgba8": REBECCA_PURPLE_HALF},
                    {"op": "set_transform", "affine": scaled_transform},
                    glyph_run(
                        two_lines,
                        25.0,
                        atlas_cache=cache,
                        glyph_transform=translate(10.0, 10.0),
                    ),
                ],
            ),
        )

    # glyphs_stroked_unhinted: outlines are never atlas-cached.
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        write(
            f"glyph_run_stroked_unhinted{suffix}_300x70.json",
            scene(
                300,
                70,
                [
                    {"op": "set_paint", "rgba8": REBECCA_PURPLE_HALF},
                    {"op": "set_stroke", "width": 1.0},
                    {"op": "set_transform", "affine": translate(0.0, 50.0)},
                    glyph_run(
                        layout.run("Hello, world!", 50.0),
                        50.0,
                        atlas_cache=cache,
                        style="stroke",
                    ),
                ],
            ),
        )

    # glyphs_transform_composition_rows_outline (unhinted): 13 rows covering
    # absorption, translation, rotation, skew and axis flips. Upstream uses
    # `reverse_x_shift = 100.0` for the mirrored rows.
    reverse_x_shift = 100.0
    rows = [
        ([1, 0, 0, 1, 0, 0], 20.0, [1, 0, 0, 1, 0, 0]),
        (scale(20.0), 1.0, [1, 0, 0, 1, 0, 0]),
        ([1, 0, 0, 1, 0, 0], 10.0, scale(2.0)),
        (scale(2.0), 5.0, scale(2.0)),
        (translate(-4.0, 0.0), 20.0, translate(4.0, 0.0)),
        (mul(translate(-4.0, 0.0), scale(4.0)), 5.0, translate(1.0, 0.0)),
        (translate(-1.0, 0.0), 40.0, mul(scale(0.5), translate(2.0, 0.0))),
        (
            [1, 0, 0, 1, 0, 0],
            20.0,
            mul(translate(10.0, -10.0), mul(rotate(math.pi / 4.0), translate(-10.0, 10.0))),
        ),
        (
            [1, 0, 0, 1, 0, 0],
            20.0,
            mul(translate(10.0, -10.0), mul(skew(0.35, 0.0), translate(-10.0, 10.0))),
        ),
        (
            [1, 0, 0, 1, 0, 0],
            20.0,
            mul(translate(10.0, -10.0), mul(skew(0.0, 0.2), translate(-10.0, 10.0))),
        ),
        (mul([1, 0, 0, -1, 0, 0], translate(0.0, 20.0)), 20.0, [1, 0, 0, 1, 0, 0]),
        (mul([-1, 0, 0, 1, 0, 0], translate(-reverse_x_shift, 0.0)), 20.0, [1, 0, 0, 1, 0, 0]),
        (mul([-1, 0, 0, -1, 0, 0], translate(-reverse_x_shift, 20.0)), 20.0, [1, 0, 0, 1, 0, 0]),
    ]
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        commands = [{"op": "set_paint", "rgba8": BLACK}]
        y = 28.35
        for run_transform, font_size, glyph_transform in rows:
            commands.append(
                {"op": "set_transform", "affine": mul(translate(16.0, y), run_transform)}
            )
            commands.append(
                glyph_run(
                    layout.run("Hello, world!", font_size),
                    font_size,
                    atlas_cache=cache,
                    glyph_transform=glyph_transform,
                )
            )
            y += 30.0
        write(
            f"glyph_run_transform_composition_unhinted{suffix}_300x420.json",
            scene(300, 420, commands),
        )

    # glyphs_decoration_offset_values / _size_values / _no_descenders:
    # mirrors `vello_tests/tests/glyph.rs` with hinting forced off. The oracle
    # renders these scenes exactly as written (the decoration pass uses the
    # same `hint` flag as the fill pass here).
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        commands = []
        for i, offset in enumerate([-6.0, -2.0, 0.0, 8.0, 15.0]):
            y = 30.0 + i * 32.0
            commands.append({"op": "set_transform", "affine": translate(0.0, y)})
            commands.extend(
                decorated_run(
                    layout,
                    "Happy joyful",
                    30.0,
                    offset=offset,
                    decor_size=1.5,
                    buffer=1.5,
                    cache=cache,
                )
            )
        write(
            f"glyph_run_decoration_offset_values{suffix}_300x180.json",
            scene(300, 180, commands),
        )

    commands = []
    for i, decor_size in enumerate([0.5, 1.0, 2.0, 4.0]):
        y = 30.0 + i * 38.0
        commands.append({"op": "set_transform", "affine": translate(0.0, y)})
        commands.extend(
            decorated_run(
                layout,
                "Happy joyful",
                30.0,
                offset=-2.0,
                decor_size=decor_size,
                buffer=1.5,
                cache=False,
            )
        )
    write("glyph_run_decoration_size_values_180x180.json", scene(180, 180, commands))

    for cache in (False, True):
        suffix = "_cache" if cache else ""
        commands = [{"op": "set_transform", "affine": translate(0.0, 50.0)}]
        commands.extend(
            decorated_run(
                layout,
                "HELLO",
                50.0,
                offset=-2.0,
                decor_size=2.0,
                buffer=1.5,
                cache=cache,
            )
        )
        write(
            f"glyph_run_decoration_no_descenders{suffix}_180x70.json",
            scene(180, 70, commands),
        )

    # glyphs_decoration_transformed: run-level scale absorption, glyph-level
    # scale, Y-flip and a rotated run. `buffer` doubles as the row advance.
    rows = [
        (scale(2.0), 12.0, None, 30.0),
        ([1, 0, 0, 1, 0, 0], 10.0, scale(1.2), 40.0),
        (mul([1, 0, 0, -1, 0, 0], translate(0.0, 20.0)), 20.0, None, 10.0),
        (rotate(math.pi / 4.0), 12.0, None, 40.0),
    ]
    commands = []
    y = 30.0
    for run_transform, font_size, glyph_transform, buffer in rows:
        commands.append(
            {"op": "set_transform", "affine": mul(translate(16.0, y), run_transform)}
        )
        commands.extend(
            decorated_run(
                layout,
                "Happy",
                font_size,
                offset=-1.0,
                decor_size=1.0,
                buffer=1.0,
                cache=False,
                glyph_transform=glyph_transform,
            )
        )
        y += buffer
    write("glyph_run_decoration_transformed_100x150.json", scene(100, 150, commands))

    # glyphs_with_gradient: complex paints are never atlas-cached and exercise
    # the relative paint transform on all four composition rows.
    commands = [
        {
            "op": "set_paint",
            "gradient": {
                "kind": {"linear": {"start": [0, 0], "end": [150, 0]}},
                "stops": [
                    {"offset": 0.0, "rgba8": BLUE},
                    {"offset": 0.33, "rgba8": GREEN},
                    {"offset": 0.66, "rgba8": RED},
                    {"offset": 1.0, "rgba8": YELLOW},
                ],
                "extend": "pad",
            },
        },
        {"op": "set_stroke", "width": 1.5},
    ]
    centered_x = 100.0
    baseline = 42.0
    for use_render_transform, shift_gradient in [
        (False, False),
        (True, False),
        (False, True),
        (True, True),
    ]:
        glyph_x = 0.0 if use_render_transform else centered_x
        commands.append(
            {"op": "set_transform", "affine": translate(centered_x if use_render_transform else 0.0, baseline)}
        )
        commands.append(
            {"op": "set_paint_transform", "affine": translate(centered_x if shift_gradient else 0.0, 0.0)}
        )
        commands.append(
            glyph_run(layout.run("Hello World", 36.0, origin_x=glyph_x), 36.0)
        )
        baseline += 40.0
    write("glyph_run_gradient_unhinted_300x180.json", scene(300, 180, commands))


if __name__ == "__main__":
    main()
