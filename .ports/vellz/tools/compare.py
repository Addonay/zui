#!/usr/bin/env python3
"""Image comparison for vellz differential tests.

Compares a candidate image against an oracle image and reports both exact and
tolerance-based metrics. Never silently accepts a mismatch: the tolerance is
explicit on the command line and the exit code reflects the verdict.

Usage:
    tools/compare.py ORACLE CANDIDATE [--max-abs-diff N] [--max-diff-pixels N]
                     [--diff-out PATH]

Exit codes:
    0  images are byte-identical (or within the requested tolerance)
    1  images differ beyond the requested tolerance, or dimensions differ
    2  usage / decode error
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print("compare.py: Pillow is required (python3 -m pip install pillow)", file=sys.stderr)
    sys.exit(2)


def load(path: Path) -> Image.Image:
    try:
        img = Image.open(path)
    except Exception as exc:  # noqa: BLE001
        print(f"compare.py: cannot decode {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    if img.mode not in ("RGBA", "RGB", "L", "P"):
        img = img.convert("RGBA")
    if img.mode == "P":
        img = img.convert("RGBA")
    return img


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oracle", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument(
        "--max-abs-diff",
        type=int,
        default=0,
        help="maximum per-channel absolute difference tolerated (default: 0, exact)",
    )
    parser.add_argument(
        "--max-diff-pixels",
        type=int,
        default=0,
        help="maximum number of pixels allowed to exceed --max-abs-diff (default: 0)",
    )
    parser.add_argument(
        "--diff-out",
        type=Path,
        default=None,
        help="write an amplified difference image to this path",
    )
    args = parser.parse_args()

    a = load(args.oracle)
    b = load(args.candidate)
    if a.size != b.size:
        print(
            f"compare.py: dimension mismatch: oracle={a.size} candidate={b.size}",
            file=sys.stderr,
        )
        return 1
    if a.mode != b.mode:
        b = b.convert(a.mode)

    pa = a.tobytes()
    pb = b.tobytes()
    n_channels = len(a.getbands())
    if len(pa) != len(pb):  # pragma: no cover - same size+mode implies same length
        print("compare.py: internal mismatch in byte lengths", file=sys.stderr)
        return 2

    total = len(pa)
    diff_pixels = 0
    max_abs = 0
    sum_abs = 0
    hist = {}
    diff_bytes = bytearray(total) if args.diff_out else None

    for i in range(total):
        d = abs(pa[i] - pb[i])
        sum_abs += d
        if d > 0:
            max_abs = max(max_abs, d)
            hist[d] = hist.get(d, 0) + 1
            if args.max_abs_diff > 0 and d > args.max_abs_diff:
                pix = i // n_channels
                if i % n_channels == 0:
                    diff_pixels += 1
        if diff_bytes is not None:
            diff_bytes[i] = min(255, d * 8)

    # Count exact-diff pixels (used when tolerance is zero).
    exact_diff_pixels = 0
    if args.max_abs_diff == 0:
        for i in range(0, total, n_channels):
            if pa[i : i + n_channels] != pb[i : i + n_channels]:
                exact_diff_pixels += 1
        diff_pixels = exact_diff_pixels

    pixels = total // n_channels
    width, height = a.size

    print(f"image: {width}x{height}, {n_channels} channels, {pixels} pixels")
    print(f"channels differing: {sum_abs} / {total} ({100.0 * sum_abs / total:.6f}%)")
    print(f"max abs channel diff: {max_abs}")
    print(f"mean abs channel diff: {sum_abs / total:.6f}")
    if args.max_abs_diff == 0:
        print(f"pixels not exactly equal: {diff_pixels} / {pixels}")
    else:
        print(
            f"pixels exceeding {args.max_abs_diff}: {diff_pixels} / {pixels}"
            f" (allowed {args.max_diff_pixels})"
        )
    if hist:
        top = sorted(hist.items(), reverse=True)[:8]
        print("top channel diffs: " + ", ".join(f"{d}:{c}" for d, c in top))

    if args.diff_out is not None and diff_bytes is not None:
        args.diff_out.parent.mkdir(parents=True, exist_ok=True)
        Image.frombytes(a.mode, a.size, bytes(diff_bytes)).save(args.diff_out)
        print(f"diff image written: {args.diff_out}")

    within = (
        diff_pixels <= args.max_diff_pixels
        if args.max_abs_diff > 0
        else diff_pixels == 0
    )
    if within:
        print("verdict: PASS")
        return 0
    print("verdict: FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
