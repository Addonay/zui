#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zui-zlay-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

(cd "$ROOT" && cargo run --manifest-path tools/taffy_oracle/Cargo.toml --quiet) > "$TMP/taffy.txt"
(cd "$ROOT" && zig build zlay-probe) > "$TMP/zlay.txt" 2>&1

diff -u "$TMP/taffy.txt" "$TMP/zlay.txt"
printf 'zlay parity: matched external Taffy fixture\n'
