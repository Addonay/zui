#!/usr/bin/env bash
# Re-import the byte-exact upstream fixtures used by vellz tests.
#
# The reference checkout must be present (tools/fetch-reference.sh) and Git LFS
# must be available if snapshots are needed (not yet the case).
#
# CFF fixtures (Source Serif 4) are not in the Vello checkout; they are
# downloaded from the pinned Adobe Fonts release commit and verified by
# SHA-256. Network access is required for those two files.
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

# CFF fixtures: Source Serif 4 (OFL-1.1) from the Adobe Fonts release branch,
# pinned in tools/pin.env. These files are not Git LFS objects (the
# checked-in copies are plain OTFs).
source_serif_base="$SOURCE_SERIF_REPO/raw/$SOURCE_SERIF_REV"
echo "downloading Source Serif 4 fixtures from $SOURCE_SERIF_REV..."
curl -fsSL "$source_serif_base/OTF/SourceSerif4-Regular.otf" -o "$dest/SourceSerif4-Regular.otf"
curl -fsSL "$source_serif_base/VAR/SourceSerif4Variable-Roman.otf" -o "$dest/SourceSerif4Variable-Roman.otf"
curl -fsSL "$source_serif_base/LICENSE.md" -o "$dest/SourceSerif4-LICENSE.md"

sha256sum \
    "$dest/probe.rgba" \
    "$dest/probe.png" \
    "$dest/Roboto-Regular.ttf" \
    "$dest/NotoColorEmoji-Subset.ttf" \
    "$dest/NotoColorEmoji-CBTF-Subset.ttf" \
    "$dest/test_glyphs-glyf_colr_1.ttf" \
    "$dest/colr_test_glyphs-LICENSE.txt" \
    "$dest/SourceSerif4-Regular.otf" \
    "$dest/SourceSerif4Variable-Roman.otf" \
    "$dest/SourceSerif4-LICENSE.md"
echo "ok: upstream fixtures imported from $VELLO_REV + source-serif $source_serif_rev"
