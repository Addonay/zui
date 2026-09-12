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

# COLR fixtures (M3 T4 / G3c).
NOTO_FONT_REL = "../fixtures/upstream/NotoColorEmoji-Subset.ttf"
NOTO_FONT = os.path.join(ROOT, "tests", "fixtures", "upstream", "NotoColorEmoji-Subset.ttf")
NOTO_UPEM = 1024.0
COLR_TEST_FONT_REL = "../fixtures/upstream/test_glyphs-glyf_colr_1.ttf"
COLR_TEST_FONT = os.path.join(
    ROOT, "tests", "fixtures", "upstream", "test_glyphs-glyf_colr_1.ttf"
)
COLR_TEST_UPEM = 1000.0

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


def scale_non_uniform(sx, sy):
    return [sx, 0.0, 0.0, sy, 0.0, 0.0]


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


def dump_cmap(codepoints, font=FONT):
    text = run_cli(
        [
            "--dump-cmap",
            "--font",
            font,
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


def dump_advances(glyph_ids, font=FONT, size=2048):
    text = run_cli(
        [
            "--dump-glyphs",
            "--font",
            font,
            "--size",
            str(size),
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
        advances[int(parts[1])] = (
            0.0
            if advance == "none"
            else struct.unpack("<f", bytes.fromhex(advance))[0]
        )
    return advances


class Layout:
    """Explicitly positions glyphs using hmtx advances (no shaping/kerning)."""

    def __init__(self, font=FONT, upem=UPEM):
        self.font = font
        self.upem = upem
        self.cmap = {}
        self.advances = {}

    def prepare(self, texts):
        codepoints = [ord(c) for text in texts for c in text if c != "\n"]
        self.cmap = dump_cmap(codepoints, self.font)
        ids = [self.cmap[cp] for cp in codepoints if self.cmap.get(cp) is not None]
        self.advances = dump_advances(ids, self.font, int(self.upem))

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
            x += self.advances[gid] * size / self.upem
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
    font_rel=FONT_REL,
):
    command = {
        "op": "glyph_run",
        "font": {"asset": font_rel, "index": 0},
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


# ---------------------------------------------------------------- COLR scenes


def noto_colr_run(noto, size, cache, transform=None, style="fill", glyphs=None):
    """One Noto COLR run, mirroring `render_colr_noto_with_transform`."""
    commands = [{"op": "set_paint", "rgba8": BLACK}]
    if transform is not None:
        commands.append({"op": "set_transform", "affine": transform})
    commands.append(
        glyph_run(
            noto.run("✅👀🎉🤠", size) if glyphs is None else glyphs,
            size,
            atlas_cache=cache,
            style=style,
            font_rel=NOTO_FONT_REL,
        )
    )
    return commands


def write_colr_scenes(noto):
    """G3c scenes mirroring upstream `glyphs_colr_noto*`,
    `glyphs_transform_composition_rows_colr` and `glyphs_colr_test_glyphs`.
    Hinting is forced off (G3b is not ported); upstream already disables it for
    the Noto COLR scenes.
    """
    fs = 50.0
    cases = [
        ("colr_noto", 250, 70, translate(0.0, fs)),
        ("colr_noto_scaled_2x", 500, 140, mul(scale(2.0), translate(0.0, fs))),
        ("colr_noto_scaled_half", 125, 35, mul(scale(0.5), translate(0.0, fs))),
        (
            "colr_noto_rotated",
            350,
            350,
            mul(translate(175.0, 100.0), rotate(math.pi / 4.0)),
        ),
        (
            "colr_noto_rotated_scaled",
            600,
            600,
            mul(translate(300.0, 150.0), mul(rotate(math.pi / 4.0), scale(2.0))),
        ),
        (
            "colr_noto_scaled_non_uniform",
            250,
            140,
            mul(translate(0.0, fs), scale_non_uniform(1.0, 2.0)),
        ),
        (
            "colr_noto_rotated_scaled_non_uniform",
            300,
            300,
            mul(
                translate(150.0, 150.0),
                mul(rotate(math.pi / 4.0), scale_non_uniform(1.0, 2.0)),
            ),
        ),
    ]
    for base, width, height, transform in cases:
        for cache in (False, True):
            suffix = "_cache" if cache else ""
            write(
                f"glyph_run_{base}{suffix}_{width}x{height}.json",
                scene(width, height, noto_colr_run(noto, fs, cache, transform)),
            )
        # Upstream's `glyphs_colr_noto_stroked` really renders a fill; exercise
        # the stroke entry point as well (COLR strokes are always filled) so
        # the delegation is gated too.
        write(
            f"glyph_run_{base}_stroked_250x70.json",
            scene(250, 70, noto_colr_run(noto, fs, False, transform, style="stroke")),
        )

    # glyphs_colr_noto_overflow_centered: a single overflowed glyph.
    check_gid = noto.cmap[ord("✅")]
    centered = [{"id": check_gid, "x": -25.0, "y": 125.0}]
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        write(
            f"glyph_run_colr_noto_overflow_centered{suffix}_100x100.json",
            scene(100, 100, noto_colr_run(noto, 150.0, cache, glyphs=centered)),
        )

    # glyphs_transform_composition_rows_colr: the same 13 rows as the outline
    # scene, with the Noto COLR glyphs.
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
                    noto.run("✅👀🎉🤠", font_size),
                    font_size,
                    atlas_cache=cache,
                    glyph_transform=glyph_transform,
                    font_rel=NOTO_FONT_REL,
                )
            )
            y += 30.0
        write(
            f"glyph_run_colr_transform_composition{suffix}_210x410.json",
            scene(210, 410, commands),
        )

    # glyphs_colr_test_glyphs: every COLR glyph of the color-fonts test font in
    # a 10-column grid, then blue/green foreground rows.
    fs = 40.0
    cols = 10.0
    width = int(fs * cols)
    for cache in (False, True):
        suffix = "_cache" if cache else ""
        commands = [{"op": "set_paint", "rgba8": BLACK}]
        cur_x = 0.0
        cur_y = fs

        def emit(gid, x, y, commands=commands, cache=cache):
            commands.append(
                {"op": "set_transform", "affine": translate(x, y)}
            )
            commands.append(
                glyph_run(
                    [{"id": gid, "x": 0.0, "y": 0.0}],
                    fs,
                    atlas_cache=cache,
                    font_rel=COLR_TEST_FONT_REL,
                )
            )

        for gid in range(0, 222):
            if 0 <= gid <= 7 or 161 <= gid <= 165 or 170 <= gid <= 176:
                continue
            if cur_x >= width:
                cur_x = 0.0
                cur_y += fs
            emit(gid, cur_x, cur_y)
            cur_x += fs
        cur_y += fs
        for color in (BLUE, GREEN):
            cur_x = 0.0
            cur_y += fs
            commands.append({"op": "set_paint", "rgba8": color})
            for gid in range(148, 154):
                emit(gid, cur_x, cur_y)
                cur_x += fs
        write(
            f"glyph_run_colr_test_glyphs{suffix}_400x960.json",
            scene(400, 960, commands),
        )


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

    # G3c COLR scenes (Noto Color Emoji + the color-fonts test font).
    noto = Layout(NOTO_FONT, NOTO_UPEM)
    noto.prepare(["✅👀🎉🤠"])
    write_colr_scenes(noto)


if __name__ == "__main__":
    main()
