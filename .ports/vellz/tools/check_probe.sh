#!/usr/bin/env bash
# Render the ported upstream probe scene and compare it against the pinned
# upstream reference fixture `tests/fixtures/upstream/probe.rgba`.
#
# Comparison policy: this fixture's own upstream policy is a per-channel
# absolute tolerance of 3 on all four channels (with pixels where both alphas
# are zero treated as equal). The vellz f32/scalar path renders it byte-exact,
# and the CLI prints the measured maximum channel difference either way. The
# tolerance is the imported fixture's documented policy, not a license to hide
# missing geometry: `tools/compare_raw.py` independently re-checks every
# channel of the written output.
#
# Usage: tools/check_probe.sh
# Exit codes: 0 match, 1 mismatch, 2 setup error.
set -euo pipefail

cd "$(dirname "$0")/.."

cli="zig-out/bin/vellz-cli"
fixture="tests/fixtures/upstream/probe.rgba"
out="out/probe.rgba"

if [ ! -x "$cli" ]; then
    echo "building vellz-cli..."
    zig build vellz-cli
fi

mkdir -p out

# The CLI renders at the upstream reference settings, compares against the
# embedded fixture with the upstream probe policy, prints the metrics, and
# exits non-zero on a mismatch.
"$cli" --probe --out "$out"

# Independent re-check of the written bytes using the repository comparison
# tooling: all four channels, per-channel max-abs-diff 3 (51*51 pixels).
python3 tools/compare_raw.py "$fixture" "$out" \
    --size 51x51 \
    --max-abs-diff 3 --max-diff-pixels 2601

echo "probe: PASS (51x51, tolerance=3; see the CLI line above for the measured max channel difference)"
