#!/usr/bin/env bash
# Clone the pinned wgpu-native revision (with its webgpu-headers submodule)
# into .reference/wgpu-native.
#
# This is only needed for the "build the native library from source" route and
# for regenerating the vendored headers. Ordinary package consumption does not
# require this checkout; supply a prebuilt library instead.
#
# Usage: tools/fetch-reference.sh [destination]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=pin.env
source "$ROOT/tools/pin.env"

DEST="${1:-$ROOT/.reference/wgpu-native}"

if [[ -d "$DEST/.git" ]]; then
    actual_commit="$(git -C "$DEST" rev-parse HEAD)"
    if [[ "$actual_commit" != "$WGPU_NATIVE_COMMIT" ]]; then
        echo "error: wgpu-native is at $actual_commit, expected $WGPU_NATIVE_COMMIT: $DEST" >&2
        echo "remove that checkout explicitly, then run this script again" >&2
        exit 1
    fi
    echo "reference already present: $DEST"
else
    mkdir -p "$(dirname "$DEST")"
    echo "cloning $WGPU_NATIVE_REPO at $WGPU_NATIVE_TAG ..."
    git clone --branch "$WGPU_NATIVE_TAG" --recurse-submodules "$WGPU_NATIVE_REPO" "$DEST"
    git -C "$DEST" checkout --recurse-submodules --quiet "$WGPU_NATIVE_COMMIT"
    git -C "$DEST" submodule update --init --recursive --quiet
fi

actual_commit="$(git -C "$DEST" rev-parse HEAD)"
actual_headers="$(git -C "$DEST" rev-parse "HEAD:ffi/webgpu-headers")"

if [[ "$actual_commit" != "$WGPU_NATIVE_COMMIT" ]]; then
    echo "error: wgpu-native is at $actual_commit, expected $WGPU_NATIVE_COMMIT" >&2
    exit 1
fi
if [[ "$actual_headers" != "$WEBGPU_HEADERS_COMMIT" ]]; then
    echo "error: webgpu-headers submodule is at $actual_headers, expected $WEBGPU_HEADERS_COMMIT" >&2
    exit 1
fi

echo "wgpu-native:     $WGPU_NATIVE_TAG ($actual_commit)"
echo "webgpu-headers:  $actual_headers"
echo "ok: $DEST"
