#!/usr/bin/env python3
"""Generate include/wgpu_init.h from the pinned upstream headers.

The WebGPU C headers define one compound-literal initializer macro per struct,
for example:

    WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;

`zig translate-c` cannot translate those macros (they expand to `(type){...}`
compound literals, which become `@compileError` stubs). Simply zeroing the
descriptor in Zig is NOT always equivalent: for example
WGPU_TEXTURE_DESCRIPTOR_INIT sets `mipLevelCount = 1` and `sampleCount = 1`,
and WGPU_BIND_GROUP_ENTRY_INIT sets `size = WGPU_WHOLE_SIZE`.

This script emits one `static inline` C function per `*_INIT` macro found in
the pinned headers. `zig translate-c` translates those functions into ordinary
Zig functions whose bodies contain the exact upstream field defaults, evaluated
for the build target. That keeps a single source of truth (the upstream
headers) and avoids hand-transcribing or drifting from the defaults.

The generated file is deterministic for a given pair of input headers.

Usage:
    python3 tools/gen_init_shims.py            # write include/wgpu_init.h
    python3 tools/gen_init_shims.py --check    # fail if out of date
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

MACRO_RE = re.compile(
    r"^#define[ \t]+(?P<macro>WGPU_[A-Z0-9_]+_INIT)[ \t]+"
    r"_wgpu_MAKE_INIT_STRUCT\((?P<type>\w+),",
    re.MULTILINE,
)

HEADER = """\
/*
 * wgpu_init.h - Zig-facing initializer shims for the wgpu-native C API.
 *
 * GENERATED FILE - DO NOT EDIT BY HAND.
 * Regenerate with:
 *
 *     python3 tools/gen_init_shims.py
 *
 * For every `WGPU_*_INIT` compound-literal macro in the pinned upstream
 * headers this header defines a `static inline` function returning that exact
 * initializer. `zig translate-c` turns each function into a Zig function, so
 * Zig consumers can obtain the upstream field defaults (which are not the same
 * as a zeroed struct) without transcribing them:
 *
 *     var desc = c.wgpu_zig_init_WGPUTextureDescriptor();
 *
 * The upstream headers are byte-for-byte copies of the pinned revision; see
 * README.md. The initializer bodies are evaluated by the C preprocessor and
 * therefore follow the defaults of the target being translated.
 */

#ifndef WGPU_ZIG_INIT_SHIMS_H_
#define WGPU_ZIG_INIT_SHIMS_H_

#include "webgpu/webgpu.h"
#include "webgpu/wgpu.h"

#ifdef __cplusplus
extern "C" {
#endif

"""

FOOTER = """\
#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WGPU_ZIG_INIT_SHIMS_H_ */
"""


def collect(include_dir: pathlib.Path) -> list[tuple[str, str, str]]:
    entries: list[tuple[str, str, str]] = []
    seen: set[str] = set()
    for name in ("webgpu/webgpu.h", "webgpu/wgpu.h"):
        path = include_dir / name
        text = path.read_text(encoding="utf-8")
        for match in MACRO_RE.finditer(text):
            macro = match.group("macro")
            if macro in seen:
                continue
            seen.add(macro)
            entries.append((macro, match.group("type"), name))
    if not entries:
        raise SystemExit(f"error: no WGPU_*_INIT macros found in {include_dir}")
    return entries


def render(entries: list[tuple[str, str, str]]) -> str:
    out = [HEADER]
    out.append(
        "/* %d initializer macros: %s */\n\n"
        % (
            len(entries),
            ", ".join(m for m, _, _ in entries),
        )
    )
    for macro, ctype, source in entries:
        func = "wgpu_zig_init_" + ctype
        out.append(f"/* {macro} (from {source}) */\n")
        out.append(f"static inline {ctype} {func}(void) {{\n")
        out.append(f"    {ctype} v = {macro};\n")
        out.append("    return v;\n")
        out.append("}\n\n")
    out.append(FOOTER)
    return "".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--include-dir",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent / "include",
        help="directory containing webgpu/webgpu.h and webgpu/wgpu.h",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=None,
        help="output path (default: <include-dir>/wgpu_init.h)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write; exit non-zero if the output would change",
    )
    args = parser.parse_args()

    include_dir: pathlib.Path = args.include_dir.resolve()
    output: pathlib.Path = args.output or (include_dir / "wgpu_init.h")
    generated = render(collect(include_dir))

    if args.check:
        try:
            current = output.read_text(encoding="utf-8")
        except FileNotFoundError:
            print(f"error: {output} does not exist", file=sys.stderr)
            return 1
        if current != generated:
            print(f"error: {output} is out of date; run tools/gen_init_shims.py", file=sys.stderr)
            return 1
        print(f"{output} is up to date")
        return 0

    output.write_text(generated, encoding="utf-8")
    count = generated.count("static inline ")
    print(f"wrote {output} ({count} initializer shims)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
