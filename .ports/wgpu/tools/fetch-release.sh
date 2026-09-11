#!/usr/bin/env bash
# Download the pinned wgpu-native release binaries for the host platform and
# extract them into .reference/artifacts/prebuilt (include/, lib/, meta).
#
# This is a build-time convenience. Nothing is downloaded at application
# runtime; consumers either use an explicit -Dwgpu-native-prefix or one of the
# locations the package searches (see README.md).
#
# Usage: tools/fetch-release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=pin.env
source "$ROOT/tools/pin.env"

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
    Linux) platform_os=linux ;;
    Darwin) platform_os=macos ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
        platform_os=windows
        if [[ -z "${MSYSTEM:-}" ]]; then
            echo "error: on Windows this script only knows how to pick the GNU or MSVC asset from MSYSTEM" >&2
            exit 1
        fi
        ;;
    *)
        echo "error: unsupported OS: $os" >&2
        exit 1
        ;;
esac
case "$arch" in
    x86_64 | amd64 | AMD64) platform_arch=x86_64 ;;
    aarch64 | arm64 | ARM64) platform_arch=aarch64 ;;
    *)
        echo "error: unsupported architecture: $arch" >&2
        exit 1
        ;;
esac

asset="wgpu-${platform_os}-${platform_arch}-release.zip"
if [[ "$platform_os" == "windows" ]]; then
    if [[ "${MSYSTEM:-}" == MINGW* ]]; then
        asset="wgpu-windows-x86_64-gnu-release.zip"
    else
        asset="wgpu-windows-x86_64-msvc-release.zip"
    fi
fi

dest="$ROOT/.reference/artifacts"
archive="$dest/$asset"
url="https://github.com/gfx-rs/wgpu-native/releases/download/$WGPU_NATIVE_TAG/$asset"

mkdir -p "$dest"
if [[ ! -f "$archive" ]]; then
    echo "downloading $url ..."
    curl --fail --location --output "$archive" "$url"
fi

rm -rf "$dest/prebuilt"
mkdir -p "$dest/prebuilt"
unzip -q "$archive" -d "$dest/prebuilt"

tag_file="$dest/prebuilt/wgpu-native-meta/wgpu-native-git-tag"
if [[ -f "$tag_file" ]] && [[ "$(tr -d '[:space:]' < "$tag_file")" != "$WGPU_NATIVE_TAG" ]]; then
    echo "error: archive reports $(cat "$tag_file"), expected $WGPU_NATIVE_TAG" >&2
    exit 1
fi

echo "ok: $dest/prebuilt (use with -Dwgpu-native-prefix=$dest/prebuilt)"
