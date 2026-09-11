#!/usr/bin/env python3
"""Exact/tolerance comparison for raw premultiplied RGBA8 buffers.

Companion to `compare.py` for the oracle corpus, where both sides are raw
`.rgba` files (no PNG decoder variance). Optionally writes an amplified diff
image when the size is known.

Usage:
    tools/compare_raw.py ORACLE.rgba CANDIDATE.rgba --size WxH
                        [--max-abs-diff N] [--max-diff-pixels N]
                        [--diff-out OUT.png]

Exit codes: 0 within tolerance, 1 mismatch, 2 usage/decode error.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_size(text: str) -> tuple[int, int]:
    try:
        w, h = text.lower().split("x")
        return int(w), int(h)
    except Exception as exc:  # noqa: BLE001
        raise argparse.ArgumentTypeError(f"bad --size {text!r} (expected WxH)") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oracle", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--size", type=parse_size, required=True)
    parser.add_argument("--max-abs-diff", type=int, default=0)
    parser.add_argument("--max-diff-pixels", type=int, default=0)
    parser.add_argument("--diff-out", type=Path, default=None)
    args = parser.parse_args()

    width, height = args.size
    expected = width * height * 4
    try:
        a = args.oracle.read_bytes()
        b = args.candidate.read_bytes()
    except OSError as exc:
        print(f"compare_raw.py: {exc}", file=sys.stderr)
        return 2
    if len(a) != expected or len(b) != expected:
        print(
            f"compare_raw.py: size mismatch: oracle={len(a)} candidate={len(b)} "
            f"expected={expected} ({width}x{height})",
            file=sys.stderr,
        )
        return 1

    diff_pixels = 0
    max_abs = 0
    sum_abs = 0
    hist: dict[int, int] = {}
    diff_bytes = bytearray(len(a)) if args.diff_out else None

    for i in range(0, len(a), 4):
        pixel_differs = False
        for c in range(4):
            d = abs(a[i + c] - b[i + c])
            if d:
                pixel_differs = True
                max_abs = max(max_abs, d)
                sum_abs += d
                hist[d] = hist.get(d, 0) + 1
            if diff_bytes is not None:
                diff_bytes[i + c] = min(255, d * 8)
        if pixel_differs:
            diff_pixels += 1

    pixels = width * height
    print(f"raw image: {width}x{height}, premultiplied RGBA8")
    print(f"channels differing: {sum_abs} / {len(a)} ({100.0 * sum_abs / len(a):.6f}%)")
    print(f"max abs channel diff: {max_abs}")
    print(f"mean abs channel diff: {sum_abs / len(a):.6f}")
    if args.max_abs_diff == 0:
        print(f"pixels not exactly equal: {diff_pixels} / {pixels}")
    else:
        print(
            f"pixels exceeding {args.max_abs_diff}: "
            f"{'see channel diffs' if max_abs > args.max_abs_diff else 0} "
            f"(channel diffs above threshold only; allowed {args.max_diff_pixels})"
        )
    if hist:
        top = sorted(hist.items(), reverse=True)[:8]
        print("top channel diffs: " + ", ".join(f"{d}:{c}" for d, c in top))

    if args.diff_out is not None and diff_bytes is not None:
        args.diff_out.parent.mkdir(parents=True, exist_ok=True)
        try:
            from PIL import Image
        except ImportError:
            print("compare_raw.py: Pillow missing; skipping --diff-out", file=sys.stderr)
        else:
            Image.frombytes("RGBA", (width, height), bytes(diff_bytes)).save(args.diff_out)
            print(f"diff image written: {args.diff_out}")

    if max_abs == 0:
        print("verdict: PASS (byte-exact)")
        return 0

    # Tolerance semantics: every differing pixel must be within max-abs-diff
    # per channel, and the total number of differing pixels is bounded.
    if (
        args.max_abs_diff > 0
        and max_abs <= args.max_abs_diff
        and diff_pixels <= args.max_diff_pixels
    ):
        print("verdict: PASS (within tolerance)")
        return 0

    print("verdict: FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
