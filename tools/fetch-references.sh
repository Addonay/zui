#!/usr/bin/env bash
# Restore every ignored upstream source reference used by this checkout.
#
# Usage: bash tools/fetch-references.sh
# This never changes an existing reference checkout. Remove a reference
# directory yourself if you intentionally want it reconstructed at its pin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=references.env
source "$ROOT/tools/references.env"

fetch_reference() {
    local name="$1" repo="$2" rev="$3" destination="$4" actual
    if [[ -d "$destination/.git" ]]; then
        actual="$(git -C "$destination" rev-parse HEAD)"
        if [[ "$actual" != "$rev" ]]; then
            echo "error: $name is at $actual, expected $rev: $destination" >&2
            echo "remove that checkout explicitly, then run this script again" >&2
            return 1
        fi
        echo "ok: $name at $rev"
        return 0
    fi
    if [[ -e "$destination" ]]; then
        echo "error: reference destination exists but is not a Git checkout: $destination" >&2
        return 1
    fi
    mkdir -p "$(dirname "$destination")"
    echo "cloning $name at $rev ..."
    git clone --filter=blob:none --no-checkout "$repo" "$destination"
    git -C "$destination" checkout --detach --quiet "$rev"
    actual="$(git -C "$destination" rev-parse HEAD)"
    [[ "$actual" == "$rev" ]] || {
        echo "error: $name resolved to $actual, expected $rev" >&2
        return 1
    }
    echo "ok: $name at $rev"
}

fetch_reference gooey "$GOOEY_REPO" "$GOOEY_REV" "$ROOT/.references/gooey"
fetch_reference gpui "$GPUI_REPO" "$GPUI_REV" "$ROOT/.references/gpui"
fetch_reference sdl3 "$SDL3_REPO" "$SDL3_REV" "$ROOT/.references/sdl3"
fetch_reference dvui "$DVUI_REPO" "$DVUI_REV" "$ROOT/.references/dvui"
fetch_reference taffy "$TAFFY_REPO" "$TAFFY_REV" "$ROOT/.references/taffy"

bash "$ROOT/.ports/cozmic/tools/fetch-reference.sh"
bash "$ROOT/.ports/wgpu/tools/fetch-reference.sh"
bash "$ROOT/.ports/vellz/tools/fetch-reference.sh"
echo "all references restored"
