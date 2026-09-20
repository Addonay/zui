#!/usr/bin/env python3
"""Compare deterministic GPUI/ZUI differential records.

The protocol is JSONL. Every record has:
  {"fixture": "...", "case": "...", "values": {...}}

Values are compared recursively. Numeric fields use the fixture's named
tolerance; arrays and strings are exact. Missing, duplicate, or extra records
are failures. This intentionally does not infer parity from a partial run.
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SPEC = Path(__file__).with_name("fixtures.json")


def load_spec(path: Path = SPEC) -> dict[str, Any]:
    spec = json.loads(path.read_text())
    if spec.get("schema") != 1 or not spec.get("fixtures"):
        raise ValueError("differential fixture schema must be version 1 with fixtures")
    for fixture in spec["fixtures"]:
        for key in ("id", "domain", "source", "tolerance", "cases"):
            if key not in fixture:
                raise ValueError(f"fixture missing {key}: {fixture!r}")
    return spec


def records(text: str) -> dict[tuple[str, str], dict[str, Any]]:
    found: dict[tuple[str, str], dict[str, Any]] = {}
    for line_no, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        record = json.loads(line)
        key = (record.get("fixture", ""), record.get("case", ""))
        if not all(key) or "values" not in record:
            raise ValueError(f"line {line_no}: record needs fixture, case, values")
        if key in found:
            raise ValueError(f"duplicate record {key}")
        found[key] = record
    return found


def _compare(a: Any, b: Any, tolerance: float, path: str, errors: list[str]) -> None:
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        if not math.isfinite(float(a)) or not math.isfinite(float(b)) or abs(float(a) - float(b)) > tolerance:
            errors.append(f"{path}: {a!r} != {b!r} (tol {tolerance})")
        return
    if type(a) is not type(b):
        errors.append(f"{path}: type {type(a).__name__} != {type(b).__name__}")
        return
    if isinstance(a, dict):
        if set(a) != set(b):
            errors.append(f"{path}: keys {sorted(a)} != {sorted(b)}")
            return
        for key in sorted(a):
            _compare(a[key], b[key], tolerance if key not in {"start", "end", "built"} else 0.0, f"{path}.{key}", errors)
    elif isinstance(a, list):
        if len(a) != len(b):
            errors.append(f"{path}: length {len(a)} != {len(b)}")
        for index, (left, right) in enumerate(zip(a, b)):
            _compare(left, right, tolerance, f"{path}[{index}]", errors)
    elif a != b:
        errors.append(f"{path}: {a!r} != {b!r}")


def compare(spec: dict[str, Any], left: str, right: str) -> list[str]:
    expected: dict[tuple[str, str], tuple[dict[str, Any], float]] = {}
    for fixture in spec["fixtures"]:
        tolerance = max((float(v) for v in fixture["tolerance"].values()), default=0.0)
        for case in fixture["cases"]:
            expected[(fixture["id"], case)] = (fixture, tolerance)
    lhs, rhs = records(left), records(right)
    errors: list[str] = []
    if set(lhs) != set(expected):
        errors.append(f"left record keys differ: missing={sorted(set(expected)-set(lhs))} extra={sorted(set(lhs)-set(expected))}")
    if set(rhs) != set(expected):
        errors.append(f"right record keys differ: missing={sorted(set(expected)-set(rhs))} extra={sorted(set(rhs)-set(expected))}")
    for key, (fixture, tolerance) in expected.items():
        if key not in lhs or key not in rhs:
            continue
        _compare(lhs[key]["values"], rhs[key]["values"], tolerance, ".".join(key), errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--left", type=Path, help="GPUI/oracle JSONL file")
    parser.add_argument("--right", type=Path, help="ZUI JSONL file")
    parser.add_argument("--spec", type=Path, default=SPEC)
    args = parser.parse_args()
    spec = load_spec(args.spec)
    if args.left and args.right:
        left, right = args.left.read_text(), args.right.read_text()
    else:
        parser.error("--left and --right are required")
    errors = compare(spec, left, right)
    if errors:
        print("differential parity: FAIL", file=sys.stderr)
        print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
        return 1
    print(f"differential parity: PASS ({len(records(left))} matched records)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
