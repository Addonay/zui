#!/usr/bin/env bash
# M3 T2 gate: compare `vellz.glifo` glyph outlines and cmap mappings against
# the pinned upstream oracle (`tools/oracle-rs --dump-glyphs` /
# `--dump-cmap`) byte for byte.
#
# Invoked directly by `zig build glyphs` (the file must stay executable).
#
# Usage:
#   tools/compare_glyphs.sh [--update-manifest]
#
# Both sides print the same canonical text: coordinates as f32 bit patterns in
# lowercase hex. Any difference is a hard failure; there is no tolerance.
#
# `--update-manifest` additionally rewrites
# `tests/fixtures/glyphs/manifest.zig` with the SHA-256 of each oracle dump
# plus its element/coordinate counts, so `zig build test` can guard the same
# vectors without a Rust toolchain.
#
# Exit codes: 0 all vectors byte-identical, 1 mismatch, 2 setup error.
set -euo pipefail

cd "$(dirname "$0")/.."

oracle="tools/oracle-rs/target/release/vellz-oracle"
cli="zig-out/bin/vellz-cli"
fonts_dir="tests/fixtures/upstream"
out="out/glyphs"
manifest="tests/fixtures/glyphs/manifest.zig"

update_manifest=0
while [ $# -gt 0 ]; do
    case "$1" in
        --update-manifest) update_manifest=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# `cargo` is needed only to (re)build the oracle. rustup installs it under
# ~/.cargo/bin, which may not be on PATH in build-runner environments.
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
    PATH="$HOME/.cargo/bin:$PATH"
fi

if [ ! -d ".reference/vello" ]; then
    echo "error: .reference/vello missing; run tools/fetch-reference.sh" >&2
    exit 2
fi
# Rebuild when the binary is missing or predates the dump modes this gate
# needs: a stale `vellz-oracle` otherwise fails with "unknown argument".
needs_oracle_build=0
if [ ! -x "$oracle" ]; then
    needs_oracle_build=1
elif "$oracle" --dump-glyphs 2>&1 | grep -q "unknown argument"; then
    needs_oracle_build=1
else
    # Binary predating `--embolden` (or `--coords`) prints "unknown argument"
    # and exits non-zero; capture instead of piping so `set -o pipefail` does
    # not mask the match.
    probe_out="$("$oracle" --dump-glyphs --embolden 1,1 2>&1 || true)"
    case "$probe_out" in
        *"unknown argument"*) needs_oracle_build=1 ;;
    esac
fi
if [ "$needs_oracle_build" -eq 1 ]; then
    echo "building vellz-oracle..."
    (cd tools/oracle-rs && cargo build --release) || {
        echo "error: building tools/oracle-rs failed" >&2
        exit 2
    }
fi
if [ ! -x "$cli" ]; then
    echo "building vellz-cli..."
    zig build vellz-cli
fi

mkdir -p "$out" "$(dirname "$manifest")"

# font filename, size in px, first gid, last gid, hint (n = unhinted, h = hinted),
# optional typed tokens: `coords=X,Y` / bare `X,Y` for normalized coordinates and
# `emb=X,Y` for synthetic embolden (both default to none)
glyph_vectors=(
    "Roboto-Regular.ttf 12.0 0 1293"
    "Roboto-Regular.ttf 16.0 0 1293"
    "Roboto-Regular.ttf 23.5 0 1293"
    "Roboto-Regular.ttf 7.0 0 1293"
    "Roboto-Regular.ttf 14.5 0 1293"
    "Roboto-Regular.ttf 100.0 0 1293"
    "Roboto-Regular.ttf 0.5 0 1293"
    "Roboto-Regular.ttf 2048.0 0 1293"
    "NotoColorEmoji-Subset.ttf 12.0 0 43"
    "NotoColorEmoji-Subset.ttf 16.0 0 43"
    "NotoColorEmoji-Subset.ttf 48.0 0 43"
    "NotoColorEmoji-Subset.ttf 7.0 0 43"
    # G3b: hinted outlines through the TrueType interpreter. Same vectors as
    # the unhinted ones (fonts whose glyph programs fail with a typed error are
    # gated, never approximated).
    "Roboto-Regular.ttf 12.0 0 1293 h"
    "Roboto-Regular.ttf 16.0 0 1293 h"
    "Roboto-Regular.ttf 23.5 0 1293 h"
    "Roboto-Regular.ttf 7.0 0 1293 h"
    "Roboto-Regular.ttf 14.5 0 1293 h"
    "Roboto-Regular.ttf 100.0 0 1293 h"
    "Roboto-Regular.ttf 0.5 0 1293 h"
    "Roboto-Regular.ttf 2048.0 0 1293 h"
    # CFF/CFF2: Source Serif 4 (OFL-1.1). Unhinted only; CFF hinting is a
    # typed error in the port (see src/glifo/cff.zig).
    "SourceSerif4-Regular.otf 0.5 0 1463"
    "SourceSerif4-Regular.otf 12.0 0 1463"
    "SourceSerif4-Regular.otf 16.0 0 1463"
    "SourceSerif4-Regular.otf 100.0 0 1463"
    "SourceSerif4-Regular.otf 2048.0 0 1463"
    "SourceSerif4Variable-Roman.otf 0.5 0 1463"
    "SourceSerif4Variable-Roman.otf 12.0 0 1463"
    "SourceSerif4Variable-Roman.otf 16.0 0 1463"
    "SourceSerif4Variable-Roman.otf 100.0 0 1463"
    "SourceSerif4Variable-Roman.otf 2048.0 0 1463"
    # G3f: variable-font outlines through `gvar` (unhinted and hinted), with
    # normalized coordinates given as `[-1, 1]` values and converted with
    # `F2Dot14::from_f32` on both sides. The last entry exercises the
    # saturating out-of-range conversion.
    "Inconsolata.ttf 16.0 0 200 n"
    "Inconsolata.ttf 16.0 0 200 h"
    "Inconsolata.ttf 16.0 0 961 n 1.0"
    "Inconsolata.ttf 16.0 0 961 h 1.0"
    "Inconsolata.ttf 16.0 0 961 n -1.0"
    "Inconsolata.ttf 16.0 0 961 h -1.0"
    "Inconsolata.ttf 12.0 0 500 n 0.5,-0.5"
    "Inconsolata.ttf 12.0 0 500 h 0.5,-0.5"
    "Inconsolata.ttf 23.5 0 300 n 1.0,-1.0"
    "Inconsolata.ttf 23.5 0 300 h 1.0,-1.0"
    "Inconsolata.ttf 7.0 0 200 n 0.3"
    "Inconsolata.ttf 7.0 0 200 h 0.3"
    "Inconsolata.ttf 100.0 0 200 n -0.75,0.25"
    "Inconsolata.ttf 100.0 0 200 h -0.75,0.25"
    "Inconsolata.ttf 16.0 0 50 n 3.0"
    # Extra coordinates beyond the axis count are ignored (LocationRef), and
    # non-empty coordinates on a font without variation tables are a no-op.
    "Inconsolata.ttf 16.0 0 100 n 0.5,-0.5,0.75"
    "Roboto-Regular.ttf 16.0 0 1293 n 1.0,-1.0"
    "Roboto-Regular.ttf 16.0 0 1293 h 1.0,-1.0"
    # G3b autohint: the instruction-less OFL Noto Sans fixture takes
    # `Engine::AutoFallback` to the autohinter (fpgm/prep empty and
    # maxp.maxSizeOfInstructions == 0).
    "NotoSans-Regular.ttf 12.0 0 3883 h"
    "NotoSans-Regular.ttf 16.0 0 3883 h"
    "NotoSans-Regular.ttf 23.5 0 3883 h"
    "NotoSans-Regular.ttf 7.0 0 3883 h"
    "NotoSans-Regular.ttf 14.5 0 3883 h"
    "NotoSans-Regular.ttf 100.0 0 3883 h"
    "NotoSans-Regular.ttf 0.5 0 3883 h"
    "NotoSans-Regular.ttf 2048.0 0 3883 h"
    # G3b autohint coverage: monospace digits exercise the fixed-width /
    # same-width digit advance path, and Devanagari exercises the Indic
    # script group.
    "NotoSansMono-Regular.ttf 16.0 0 3919 h"
    "NotoSansMono-Regular.ttf 7.0 0 3919 h"
    "NotoSansDevanagari-Regular.ttf 16.0 0 844 h"
    "NotoSansDevanagari-Regular.ttf 7.0 0 844 h"
    # M3 embolden: `kurbo::expand_path` applied to the drawn (hinted or
    # unhinted) outline, matching `OutlineCache.getOrInsert`. Isotropic and
    # anisotropic amounts, both hint modes. Amounts are positive (upstream's
    # `expand_path` contract); a zero factor makes upstream produce NaN
    # geometry, whose NaN sign/payload is not stable across LLVM codegen
    # (rendering is unaffected because NaN path elements are ignored).
    "Roboto-Regular.ttf 16.0 0 300 n emb=1.0,1.0"
    "Roboto-Regular.ttf 16.0 0 300 h emb=1.0,1.0"
    "Roboto-Regular.ttf 23.5 300 600 n emb=2.0,1.0"
    "Roboto-Regular.ttf 12.0 600 900 h emb=0.5,1.5"
)

# font filename, first codepoint, last codepoint
cmap_vectors=(
    "Roboto-Regular.ttf 0 65535"
    "NotoColorEmoji-Subset.ttf 0 131071"
    "NotoColorEmoji-CBTF-Subset.ttf 0 131071"
    "SourceSerif4-Regular.otf 0 65535"
    "SourceSerif4Variable-Roman.otf 0 65535"
)

font_id() {
    case "$1" in
        Roboto-Regular.ttf) echo 0 ;;
        NotoColorEmoji-Subset.ttf) echo 1 ;;
        NotoColorEmoji-CBTF-Subset.ttf) echo 2 ;;
        SourceSerif4-Regular.otf) echo 3 ;;
        SourceSerif4Variable-Roman.otf) echo 4 ;;
        Inconsolata.ttf) echo 5 ;;
        NotoSans-Regular.ttf) echo 6 ;;
        NotoSansMono-Regular.ttf) echo 7 ;;
        NotoSansDevanagari-Regular.ttf) echo 8 ;;
        *) echo "unknown font $1" >&2; exit 2 ;;
    esac
}

# Number of f32 coordinates in a glyph dump.
coordinates() {
    awk '{ if ($1 == "M" || $1 == "L") n += 2; else if ($1 == "Q") n += 4; else if ($1 == "C") n += 6 } END { print n + 0 }' "$1"
}

elements() {
    grep -c '^[MLQCZ]' "$1" 2>/dev/null || true
}

failures=0
total_elements=0
total_coordinates=0

glyph_rows=""
for vector in "${glyph_vectors[@]}"; do
    read -r font size gid_start gid_end hint_flag spec1 spec2 <<<"$vector"
    name="${font%.*}_s${size}_${gid_start}-${gid_end}"
    coords=""
    embolden_spec=""
    for token in "${spec1:-}" "${spec2:-}"; do
        case "$token" in
            "") ;;
            emb=*) embolden_spec="${token#emb=}" ;;
            coords=*) coords="${token#coords=}" ;;
            -) ;;
            *) coords="$token" ;;
        esac
    done
    hint_arg=""
    manifest_hint="false"
    if [ "$hint_flag" = "h" ]; then
        name="${name}_hint"
        hint_arg="--hint"
        manifest_hint="true"
    fi
    coords_arg=()
    coords_suffix=""
    if [ -n "${coords:-}" ]; then
        coords_arg=(--coords "$coords")
        coords_suffix="_c$(printf '%s' "$coords" | tr ',.-' '___')"
    fi
    name="${name}${coords_suffix}"
    emb_arg=""
    manifest_emb_x="0"
    manifest_emb_y="0"
    if [ -n "${embolden_spec:-}" ] && [ "$embolden_spec" != "-" ]; then
        emb_arg="--embolden $embolden_spec"
        emb_x="${embolden_spec%,*}"
        emb_y="${embolden_spec#*,}"
        manifest_emb_x="$(python3 -c 'import struct,sys; print("0x%016x" % struct.unpack("<Q", struct.pack("<d", float(sys.argv[1])))[0])' "$emb_x")"
        manifest_emb_y="$(python3 -c 'import struct,sys; print("0x%016x" % struct.unpack("<Q", struct.pack("<d", float(sys.argv[1])))[0])' "$emb_y")"
        name="${name}_emb${emb_x//./p}_${emb_y//./p}"
    fi
    oracle_dump="$out/oracle_$name.txt"
    zig_dump="$out/zig_$name.txt"
    "$oracle" --dump-glyphs --font "$fonts_dir/$font" --size "$size" $hint_arg \
        "${coords_arg[@]}" $emb_arg --gids "$gid_start-$gid_end" >"$oracle_dump"
    "$cli" --dump-glyphs --font "$fonts_dir/$font" --size "$size" $hint_arg \
        "${coords_arg[@]}" $emb_arg --gids "$gid_start-$gid_end" >"$zig_dump"
    count_elements="$(elements "$oracle_dump")"
    count_coordinates="$(coordinates "$oracle_dump")"
    total_elements=$((total_elements + count_elements))
    total_coordinates=$((total_coordinates + count_coordinates))
    if cmp -s "$oracle_dump" "$zig_dump"; then
        printf 'PASS     %-40s elems=%-6s coords=%-7s\n' \
            "$name" "$count_elements" "$count_coordinates"
    else
        printf 'FAIL     %-40s\n' "$name"
        diff "$oracle_dump" "$zig_dump" | head -12 | sed 's/^/         /'
        failures=1
    fi
    if [ "$update_manifest" -eq 1 ]; then
        hex="$(sha256sum "$oracle_dump" | awk '{print $1}')"
        bytes="$(printf '%s' "$hex" | sed 's/../0x&, /g')"
        size_bits="$(python3 -c 'import struct,sys; print("%08x" % struct.unpack("<I", struct.pack("<f", float(sys.argv[1])))[0])' "$size")"
        manifest_coords=""
        if [ -n "${coords:-}" ]; then
            coords_bits="$(awk '/^coords / { for (i = 3; i <= NF; i++) printf "%s, ", $i }' "$oracle_dump")"
            manifest_coords=".coords = &.{ $coords_bits}, "
        fi
        glyph_rows+="    .{ .font = $(font_id "$font"), .size_bits = 0x$size_bits, .gid_start = $gid_start, .gid_end = $gid_end, .hint = $manifest_hint, $manifest_coords.embolden_x_bits = $manifest_emb_x, .embolden_y_bits = $manifest_emb_y, .elements = $count_elements, .coordinates = $count_coordinates, .sha256 = .{ $bytes} },\n"
    fi
done

cmap_rows=""
for vector in "${cmap_vectors[@]}"; do
    read -r font cp_start cp_end <<<"$vector"
    name="${font%.*}_cp${cp_start}-${cp_end}"
    oracle_dump="$out/oracle_$name.txt"
    zig_dump="$out/zig_$name.txt"
    "$oracle" --dump-cmap --font "$fonts_dir/$font" \
        --codepoints "$cp_start-$cp_end" >"$oracle_dump"
    "$cli" --dump-cmap --font "$fonts_dir/$font" \
        --codepoints "$cp_start-$cp_end" >"$zig_dump"
    mapping_count="$(grep -c '^cp ' "$oracle_dump" || true)"
    if cmp -s "$oracle_dump" "$zig_dump"; then
        printf 'PASS     %-40s mappings=%s\n' "$name" "$mapping_count"
    else
        printf 'FAIL     %-40s\n' "$name"
        diff "$oracle_dump" "$zig_dump" | head -12 | sed 's/^/         /'
        failures=1
    fi
    if [ "$update_manifest" -eq 1 ]; then
        hex="$(sha256sum "$oracle_dump" | awk '{print $1}')"
        bytes="$(printf '%s' "$hex" | sed 's/../0x&, /g')"
        cmap_rows+="    .{ .font = $(font_id "$font"), .cp_start = $cp_start, .cp_end = $cp_end, .count = $mapping_count, .sha256 = .{ $bytes} },\n"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "glyphs: FAIL (see $out)"
    exit 1
fi

if [ "$update_manifest" -eq 1 ]; then
    {
        echo "//! Generated by \`tools/compare_glyphs.sh --update-manifest\`; do not edit."
        echo "//!"
        echo "//! Each hash is the SHA-256 of the pinned oracle's canonical dump for"
        echo "//! one (font, size, gid range) or (font, codepoint range) vector."
        echo "//! \`zig build test\` regenerates the same text with \`vellz.glifo\` and"
        echo "//! compares both the hash and the element/coordinate counts."
        echo ""
        echo "pub const font_roboto: u8 = 0;"
        echo "pub const font_noto: u8 = 1;"
        echo "pub const font_noto_cbtf: u8 = 2;"
        echo "pub const font_source_serif: u8 = 3;"
        echo "pub const font_source_serif_variable: u8 = 4;"
        echo "pub const font_inconsolata: u8 = 5;"
        echo "pub const font_notosans: u8 = 6;"
        echo "pub const font_notosans_mono: u8 = 7;"
        echo "pub const font_notosans_devanagari: u8 = 8;"
        echo ""
        echo "pub const GlyphVector = struct {"
        echo "    font: u8,"
        echo "    size_bits: u32,"
        echo "    gid_start: u32,"
        echo "    gid_end: u32,"
        echo "    hint: bool,"
        echo "    /// Normalized F2Dot14 coordinates; empty for static vectors."
        echo "    coords: []const i16 = &.{},"
        echo "    embolden_x_bits: u64,"
        echo "    embolden_y_bits: u64,"
        echo "    elements: usize,"
        echo "    coordinates: usize,"
        echo "    sha256: [32]u8,"
        echo "};"
        echo ""
        echo "pub const glyph_vectors = [_]GlyphVector{"
        printf '%b' "$glyph_rows"
        echo "};"
        echo ""
        echo "pub const CmapVector = struct {"
        echo "    font: u8,"
        echo "    cp_start: u32,"
        echo "    cp_end: u32,"
        echo "    count: usize,"
        echo "    sha256: [32]u8,"
        echo "};"
        echo ""
        echo "pub const cmap_vectors = [_]CmapVector{"
        printf '%b' "$cmap_rows"
        echo "};"
    } >"$manifest"
    echo "manifest: wrote $manifest"
fi

echo "glyphs: PASS (${#glyph_vectors[@]} glyph vectors, ${#cmap_vectors[@]} cmap vectors,"
echo "                $total_elements elements, $total_coordinates coordinates, tolerance=0)"
