#!/usr/bin/env python3
"""Check that the GPUI parity matrix still covers the checked-in API surface.

This is intentionally a source-ledger check, not a claim that the APIs are
behaviorally equivalent.  It compares the public module and re-export
statements in GPUI's checked-in ``gpui.rs`` with immutable inventory markers in
``docs/GPUI_PARITY_MATRIX.md``.  It also validates the evidence syntax used by
future ``Complete`` rows.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GPUI = ROOT / ".references/gpui/crates/gpui/src/gpui.rs"
MATRIX = ROOT / "docs/GPUI_PARITY_MATRIX.md"


def normalized(value: str) -> str:
    return " ".join(value.split())


def public_region(source: str) -> str:
    """Remove GPUI's nested private re-export module from the scan region."""
    start = source.index("pub use proptest;")
    end = source.index("pub trait AppContext")
    region = source[start:end]
    private = re.search(r"pub mod private\s*\{.*?\n\}", region, re.S)
    if private:
        region = region[: private.start()] + region[private.end() :]
    return region


def source_inventory() -> tuple[set[str], set[str]]:
    source = GPUI.read_text(encoding="utf-8")
    modules = set(re.findall(r"^pub mod\s+(\w+);", source, re.M))
    region = public_region(source)
    reexports = {
        normalized(match.group(0))
        for match in re.finditer(r"pub use\s+.*?;", region, re.S)
    }
    return modules, reexports


def marker_values(text: str, marker: str) -> set[str]:
    return set(re.findall(rf"^<!-- {re.escape(marker)}: (.*?) -->$", text, re.M))


def source_family(reexport: str) -> str:
    value = reexport.removeprefix("pub use ").removesuffix(";")
    return value.split("::", 1)[0].split("{", 1)[0].strip()


def fail(message: str) -> None:
    print(f"gpui parity matrix: FAIL: {message}", file=sys.stderr)


def main() -> int:
    if not GPUI.is_file():
        fail(f"missing GPUI source: {GPUI}")
        return 1
    if not MATRIX.is_file():
        fail(f"missing matrix: {MATRIX}")
        return 1

    text = MATRIX.read_text(encoding="utf-8")
    expected_modules, expected_reexports = source_inventory()
    recorded_modules = marker_values(text, "gpui-module")
    recorded_reexports = marker_values(text, "gpui-reexport")

    missing_modules = sorted(expected_modules - recorded_modules)
    stale_modules = sorted(recorded_modules - expected_modules)
    missing_reexports = sorted(expected_reexports - recorded_reexports)
    stale_reexports = sorted(recorded_reexports - expected_reexports)
    errors: list[str] = []
    if missing_modules:
        errors.append("missing public module inventory: " + ", ".join(missing_modules))
    if stale_modules:
        errors.append("stale public module inventory: " + ", ".join(stale_modules))
    if missing_reexports:
        errors.append("missing public re-export inventory: " + "; ".join(missing_reexports))
    if stale_reexports:
        errors.append("stale public re-export inventory: " + "; ".join(stale_reexports))

    expected_families = expected_modules | {source_family(item) for item in expected_reexports}
    recorded_families = marker_values(text, "gpui-source-family")
    missing_families = sorted(expected_families - recorded_families)
    stale_families = sorted(recorded_families - expected_families)
    if missing_families:
        errors.append("missing GPUI source-family inventory: " + ", ".join(missing_families))
    if stale_families:
        errors.append("stale GPUI source-family inventory: " + ", ".join(stale_families))

    export_maps: dict[str, str] = {}
    for mapping in marker_values(text, "gpui-export-map"):
        source, separator, counterpart = mapping.partition(" => ")
        if not separator or not source or not counterpart:
            errors.append("malformed GPUI export map: " + mapping)
        else:
            export_maps[source] = counterpart
    missing_maps = sorted(expected_reexports - export_maps.keys())
    stale_maps = sorted(export_maps.keys() - expected_reexports)
    if missing_maps:
        errors.append("missing per-export ZUI comparison: " + "; ".join(missing_maps))
    if stale_maps:
        errors.append("stale per-export ZUI comparison: " + "; ".join(stale_maps))

    gates = {
        gate_id: command
        for gate_id, command in re.findall(
            r"^<!-- gpui-gate: id=([^ ]+) command=(.*?) -->$", text, re.M
        )
    }
    if not gates:
        errors.append("no executable GPUI parity gate is declared")
    for line in text.splitlines():
        if not line.startswith("|") or line.startswith("| ---"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 3 or cells[1].lower() != "complete":
            continue
        evidence = cells[2]
        referenced = re.findall(r"gate:([A-Za-z0-9_-]+)", evidence)
        if not referenced:
            errors.append(f"Complete row has no gate reference: {cells[0]}")
            continue
        for gate_id in referenced:
            if gate_id not in gates:
                errors.append(f"Complete row references undeclared gate {gate_id}: {cells[0]}")
            elif not gates[gate_id].strip():
                errors.append(f"declared gate {gate_id} has no command")
        if not re.search(r"evidence:[^ ]", evidence):
            errors.append(f"Complete row has no evidence label: {cells[0]}")

    if errors:
        for error in errors:
            fail(error)
        return 1

    print(
        "gpui parity matrix: PASS "
        f"({len(expected_modules)} public modules, "
        f"{len(expected_reexports)} public re-exports, "
        f"{len(expected_families)} source families, {len(gates)} executable gates)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
