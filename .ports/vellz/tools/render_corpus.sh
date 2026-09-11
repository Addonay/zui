#!/usr/bin/env bash
# Render the shared scene corpus with the pinned upstream oracle and verify
# that repeated runs are byte-identical (milestone G0).
#
# Usage:
#   tools/render_corpus.sh [--check] [--png]
#
#   --check   verify that committed fixture hashes still match; do not write
#   --png     also write PNG previews next to the .rgba fixtures
set -euo pipefail

cd "$(dirname "$0")/.."

oracle="tools/oracle-rs/target/release/vellz-oracle"
out_dir="tests/fixtures/oracle"
check_only=0
png_flag=()

for arg in "$@"; do
    case "$arg" in
        --check) check_only=1 ;;
        --png) png_flag=(--png) ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ ! -x "$oracle" ]; then
    echo "building vellz-oracle..."
    (cd tools/oracle-rs && cargo build --release)
fi

mkdir -p "$out_dir"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0
for scene in tests/scenes/*.json; do
    name="$(basename "$scene" .json)"
    fixture="$out_dir/$name.rgba"
    meta="$out_dir/$name.json"

    if [ "$check_only" -eq 1 ]; then
        if [ ! -f "$meta" ]; then
            echo "MISSING  $name (no fixture metadata)"
            failures=$((failures + 1))
            continue
        fi
        recorded="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["output_fnv1a"])' "$meta")"
        "$oracle" --scene "$scene" --out "$tmp_dir/$name.rgba" >/dev/null
        actual="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["output_fnv1a"])' "$tmp_dir/$name.json")"
        if [ "$recorded" != "$actual" ]; then
            echo "MISMATCH $name: recorded=$recorded actual=$actual"
            failures=$((failures + 1))
        else
            echo "ok       $name ($actual)"
        fi
        continue
    fi

    "$oracle" --scene "$scene" --out "$fixture" "${png_flag[@]}"
    # Determinism: render again into a temp file and compare hashes.
    "$oracle" --scene "$scene" --out "$tmp_dir/$name.rgba" >/dev/null
    if ! cmp -s "$fixture" "$tmp_dir/$name.rgba"; then
        echo "NON-DETERMINISTIC: $name"
        failures=$((failures + 1))
    else
        echo "ok       $name (deterministic)"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures corpus problem(s)"
    exit 1
fi
echo "corpus oracle render: all scenes deterministic"
