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

# Variable-font fixtures: Inconsolata (OFL) from the pinned vello checkout.
cp "$ref/assets/inconsolata/Inconsolata.ttf" "$dest/Inconsolata.ttf"
cp "$ref/assets/inconsolata/LICENSE.txt" "$dest/Inconsolata-LICENSE.txt"


# Noto Sans Regular from the notofonts "unhinted" build tree. This is the
# Engine::AutoFallback fixture: `fpgm`/`prep` are empty and
# `maxp.maxSizeOfInstructions == 0`, so skrifa selects the autohinter. The
# pinned revision is the notofonts.github.io commit recorded in the README;
# the license text comes from the source repository's OFL.txt.
NOTO_SANS_REV="28b15b4b43b7bed62b5cf6e6b0b5ff5846270535"
NOTO_SANS_LICENSE_REV="4bc63d7ebca1faed49c6c685f380ba0abc2c1941"
NOTO_SANS_BASE="https://raw.githubusercontent.com/notofonts/notofonts.github.io/$NOTO_SANS_REV/fonts/NotoSans/unhinted/ttf"
NOTO_SANS_LICENSE_URL="https://raw.githubusercontent.com/notofonts/latin-greek-cyrillic/$NOTO_SANS_LICENSE_REV/OFL.txt"
curl -fsSL "$NOTO_SANS_BASE/NotoSans-Regular.ttf" -o "$dest/NotoSans-Regular.ttf"
curl -fsSL "https://raw.githubusercontent.com/notofonts/notofonts.github.io/$NOTO_SANS_REV/fonts/NotoSansMono/unhinted/ttf/NotoSansMono-Regular.ttf" -o "$dest/NotoSansMono-Regular.ttf"
curl -fsSL "https://raw.githubusercontent.com/notofonts/notofonts.github.io/$NOTO_SANS_REV/fonts/NotoSansDevanagari/unhinted/ttf/NotoSansDevanagari-Regular.ttf" -o "$dest/NotoSansDevanagari-Regular.ttf"
curl -fsSL "$NOTO_SANS_LICENSE_URL" -o "$dest/NotoSans-OFL.txt"
expected_font="f3961a9cde016d41a4879aecda1474d3a36d6bf54fa0e4643de029cc2248b0e8"
expected_license="cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a"
expected_mono="87f8ce0522a6c99b743ee5fc75b4073cfdd575639119672828b7b9944b65b4f4"
expected_deva="216921eded5a97435fa0638deca66496bf51f52fa3467f566deb9938c25a71de"
got_font="$(sha256sum "$dest/NotoSans-Regular.ttf" | awk '{print $1}')"
got_mono="$(sha256sum "$dest/NotoSansMono-Regular.ttf" | awk '{print $1}')"
got_deva="$(sha256sum "$dest/NotoSansDevanagari-Regular.ttf" | awk '{print $1}')"
got_license="$(sha256sum "$dest/NotoSans-OFL.txt" | awk '{print $1}')"
if [ "$got_font" != "$expected_font" ] || [ "$got_mono" != "$expected_mono" ] || [ "$got_deva" != "$expected_deva" ] || [ "$got_license" != "$expected_license" ]; then
    echo "error: NotoSans fixture checksum mismatch" >&2
    echo "  regular:     $got_font (expected $expected_font)" >&2
    echo "  mono:        $got_mono (expected $expected_mono)" >&2
    echo "  devanagari:  $got_deva (expected $expected_deva)" >&2
    echo "  license:     $got_license (expected $expected_license)" >&2
    exit 1
fi

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
    "$dest/SourceSerif4-LICENSE.md" \
    "$dest/Inconsolata.ttf" \
    "$dest/Inconsolata-LICENSE.txt" \
    "$dest/NotoSans-Regular.ttf" \
    "$dest/NotoSansMono-Regular.ttf" \
    "$dest/NotoSansDevanagari-Regular.ttf" \
    "$dest/NotoSans-OFL.txt"
echo "ok: upstream fixtures imported from $VELLO_REV + source-serif $source_serif_rev"
