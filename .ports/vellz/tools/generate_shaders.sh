#!/usr/bin/env bash
# Regenerate src/gpu/shaders/*.wgsl from the pinned upstream shader sources.
#
# Requires the reference checkout and a Rust toolchain. The generated files are
# checked in so normal builds (including GPU builds) never need Cargo, WESL, or
# naga. Run this only when the pinned revision changes or when auditing.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/pin.env

ref=".reference/vello"
if [ ! -d "$ref/.git" ]; then
    echo "error: $ref missing; run tools/fetch-reference.sh first" >&2
    exit 1
fi
have="$(git -C "$ref" rev-parse HEAD)"
if [ "$have" != "$VELLO_REV" ]; then
    echo "error: reference at $have, expected $VELLO_REV" >&2
    exit 1
fi

echo "building vello_gpu_shaders at $VELLO_REV..."
(cd "$ref" && cargo build --release -p vello_gpu_shaders)

compiled="$(find "$ref/target/release/build" -path '*vello_gpu_shaders*/out/compiled_shaders.rs' | head -1)"
if [ -z "$compiled" ]; then
    echo "error: compiled_shaders.rs not found under $ref/target/release/build" >&2
    exit 1
fi

python3 tools/extract_shaders.py "$compiled" src/gpu/shaders "$VELLO_REV"
echo "ok: shaders regenerated from $VELLO_REV"
