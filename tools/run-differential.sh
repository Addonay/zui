#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zui-gpui-differential.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

rustc --edition=2021 -O "$ROOT/tools/differential/gpui_oracle.rs" -o "$TMP/gpui-oracle"
(cd "$ROOT" && "$TMP/gpui-oracle") > "$TMP/gpui.jsonl"
(cd "$ROOT" && zig build differential-zui) > "$TMP/zui.jsonl"
python3 "$ROOT/tools/differential/compare.py" --left "$TMP/gpui.jsonl" --right "$TMP/zui.jsonl"

if [[ "${ZUI_DIFFERENTIAL_KEEP:-0}" == 1 ]]; then
    cp "$TMP/gpui.jsonl" "$ROOT/.zig-cache/gpui-differential.jsonl"
    cp "$TMP/zui.jsonl" "$ROOT/.zig-cache/zui-differential.jsonl"
    printf 'records retained under .zig-cache/*-differential.jsonl\n'
fi
