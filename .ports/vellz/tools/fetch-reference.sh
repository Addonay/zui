#!/usr/bin/env bash
# Reconstruct the pinned upstream Vello checkout used as the oracle.
#
# The checkout lives in .reference/vello and is never distributed or required
# for a normal package build. It is needed only for:
#   - the differential test harness (tools/oracle),
#   - regenerating fixtures,
#   - inspecting upstream sources while porting.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/pin.env

dir=".reference/vello"

if [ -d "$dir/.git" ]; then
    echo "reference already present: $dir"
    have="$(git -C "$dir" rev-parse HEAD)"
    if [ "$have" != "$VELLO_REV" ]; then
        echo "error: $dir is at $have, expected $VELLO_REV" >&2
        echo "delete $dir and re-run to reconstruct" >&2
        exit 1
    fi
    exit 0
fi

mkdir -p .reference
# Full clone so arbitrary existing revisions and history are inspectable; the
# repository is small enough that a filtered clone is not necessary.
git clone "$VELLO_REPO" "$dir"
git -C "$dir" checkout --detach "$VELLO_REV"
actual="$(git -C "$dir" rev-parse HEAD)"
if [ "$actual" != "$VELLO_REV" ]; then
    echo "error: checkout is at $actual, expected $VELLO_REV" >&2
    exit 1
fi
echo "ok: vello at $VELLO_REV ($VELLO_DESCRIBE, $VELLO_DATE)"
