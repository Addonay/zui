#!/usr/bin/env python3
"""Extract the compiled WGSL sources from upstream's generated Rust module.

Reads the `compiled_shaders.rs` emitted by `vello_gpu_shaders`'s build script
(raw string constants) and writes one `.wgsl` file per shader root plus a
manifest with SHA-256 hashes and provenance. Idempotent.

Usage: tools/extract_shaders.py COMPILED_SHADERS_RS OUT_DIR [REVISION]
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

RAW = re.compile(
    r'pub const (\w+): &str = r(?P<hashes>#+)"(?P<body>.*?)"(?P=hashes);',
    re.DOTALL,
)

# Upstream module names (upper-case const) -> lower-case file stem.
KNOWN = {
    "BLEND": "blend",
    "CLEAR": "clear",
    "COPY": "copy",
    "FILTER": "filter",
    "RENDER": "render",
}


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    revision = sys.argv[3] if len(sys.argv) > 3 else "unknown"
    text = source.read_text()

    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = {"source": str(source), "revision": revision, "shaders": {}}
    found = {}
    for match in RAW.finditer(text):
        name = match.group(1)
        stem = KNOWN.get(name)
        if stem is None:
            continue
        body = match.group("body")
        # Raw strings are literal; a minified shader should not contain the
        # raw-string terminator. Guard anyway.
        hashes = match.group("hashes")
        if ('"' + hashes) in body:
            print(f"error: {name} contains its raw-string terminator", file=sys.stderr)
            return 1
        path = out_dir / f"{stem}.wgsl"
        path.write_text(body)
        digest = hashlib.sha256(body.encode()).hexdigest()
        manifest["shaders"][stem] = {
            "const": name,
            "bytes": len(body),
            "sha256": digest,
        }
        found[stem] = True

    missing = set(KNOWN.values()) - found.keys()
    if missing:
        print(f"error: missing shader roots: {sorted(missing)}", file=sys.stderr)
        return 1

    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    for stem in sorted(manifest["shaders"]):
        info = manifest["shaders"][stem]
        print(f"{stem}.wgsl: {info['bytes']} bytes sha256={info['sha256'][:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
