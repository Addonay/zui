#!/usr/bin/env bash
# Re-import the byte-exact upstream fixtures used by vellz tests.
#
# The reference checkout must be present (tools/fetch-reference.sh) and Git LFS
# must be available if snapshots are needed (not yet the case).
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/pin.env

ref=".reference/vello"
if [ ! -d "$ref/.git" ]; then
    echo "error: $ref missing; run tools/fetch-reference.sh" >&2
    exit 1
fi
have="$(git -C "$ref" rev-parse HEAD)"
if [ "$have" != "$VELLO_REV" ]; then
    echo "error: reference at $have, expected $VELLO_REV" >&2
    exit 1
fi

dest="tests/fixtures/upstream"
mkdir -p "$dest"
cp "$ref/vello_common/assets/probe.rgba" "$dest/probe.rgba"
cp "$ref/vello_common/assets/probe.png" "$dest/probe.png"
cp "$ref/assets/roboto/Roboto-Regular.ttf" "$dest/Roboto-Regular.ttf"
cp "$ref/assets/roboto/LICENSE.txt" "$dest/Roboto-LICENSE.txt"
cp "$ref/assets/noto_color_emoji/NotoColorEmoji-Subset.ttf" "$dest/NotoColorEmoji-Subset.ttf"
cp "$ref/assets/noto_color_emoji/NotoColorEmoji-CBTF-Subset.ttf" "$dest/NotoColorEmoji-CBTF-Subset.ttf"
cp "$ref/assets/noto_color_emoji/LICENSE.txt" "$dest/NotoColorEmoji-LICENSE.txt"
cp "$ref/assets/colr_test_glyphs/test_glyphs-glyf_colr_1.ttf" "$dest/test_glyphs-glyf_colr_1.ttf"
cp "$ref/assets/colr_test_glyphs/LICENSE.txt" "$dest/colr_test_glyphs-LICENSE.txt"
cp "$ref/assets/inconsolata/Inconsolata.ttf" "$dest/Inconsolata.ttf"
cp "$ref/assets/inconsolata/LICENSE.txt" "$dest/Inconsolata-LICENSE.txt"
sha256sum \
    "$dest/probe.rgba" \
    "$dest/probe.png" \
    "$dest/Roboto-Regular.ttf" \
    "$dest/NotoColorEmoji-Subset.ttf" \
    "$dest/NotoColorEmoji-CBTF-Subset.ttf" \
    "$dest/test_glyphs-glyf_colr_1.ttf" \
    "$dest/colr_test_glyphs-LICENSE.txt" \
    "$dest/Inconsolata.ttf" \
    "$dest/Inconsolata-LICENSE.txt"
echo "ok: upstream fixtures imported from $VELLO_REV"
