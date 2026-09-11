#!/usr/bin/env bash
# Copy the pinned upstream headers into include/webgpu/ and regenerate the
# WGPU_*_INIT shims. Run this after tools/fetch-reference.sh when updating the
# pin, then commit the updated headers.
#
# Usage: tools/sync-headers.sh [reference-checkout]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=pin.env
source "$ROOT/tools/pin.env"

REF="${1:-$ROOT/.reference/wgpu-native}"

if [[ ! -f "$REF/ffi/wgpu.h" ]]; then
    echo "error: no wgpu-native checkout at $REF (run tools/fetch-reference.sh)" >&2
    exit 1
fi

actual_commit="$(git -C "$REF" rev-parse HEAD)"
actual_headers="$(git -C "$REF" rev-parse "HEAD:ffi/webgpu-headers")"
if [[ "$actual_commit" != "$WGPU_NATIVE_COMMIT" || "$actual_headers" != "$WEBGPU_HEADERS_COMMIT" ]]; then
    echo "error: $REF is not at the pinned revision" >&2
    echo "  wgpu-native:    $actual_commit (expected $WGPU_NATIVE_COMMIT)" >&2
    echo "  webgpu-headers: $actual_headers (expected $WEBGPU_HEADERS_COMMIT)" >&2
    exit 1
fi

mkdir -p "$ROOT/include/webgpu"
cp "$REF/ffi/webgpu-headers/webgpu.h" "$ROOT/include/webgpu/webgpu.h"
cp "$REF/ffi/wgpu.h" "$ROOT/include/webgpu/wgpu.h"
python3 "$ROOT/tools/gen_init_shims.py"

check() {
    local file="$1" expected="$2"
    local actual
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    if [[ "$actual" != "$expected" ]]; then
        echo "error: $file has unexpected hash $actual" >&2
        echo "       expected $expected" >&2
        echo "       update tools/pin.env if the pin really changed" >&2
        exit 1
    fi
}
check "$ROOT/include/webgpu/webgpu.h" "$WEBGPU_H_SHA256"
check "$ROOT/include/webgpu/wgpu.h" "$WGPU_H_SHA256"

echo "ok: vendored headers and include/wgpu_init.h are in sync with $WGPU_NATIVE_TAG"
