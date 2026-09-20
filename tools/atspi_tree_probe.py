#!/usr/bin/env python3
"""Inspect one running ZUI application through the live AT-SPI registry."""

from __future__ import annotations

import argparse
import sys
import time

import pyatspi


def find_application(desktop, name: str):
    for index in range(desktop.childCount):
        app = desktop.getChildAtIndex(index)
        if app is not None and app.name == name:
            return app
    return None


def describe(obj, depth: int, output: list[str], limit: list[int]) -> None:
    if obj is None or depth > 8 or limit[0] >= 512:
        return
    limit[0] += 1
    actions: list[str] = []
    try:
        interface = obj.queryAction()
        actions = [interface.getName(i) for i in range(interface.nActions)]
    except Exception:
        pass
    output.append(
        f"{'  ' * depth}{obj.getRoleName()} name={obj.name!r} "
        f"children={obj.childCount} actions={actions!r}"
    )
    for index in range(obj.childCount):
        describe(obj.getChildAtIndex(index), depth + 1, output, limit)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("application", help="AT-SPI application name, for example todo")
    parser.add_argument("--wait", type=float, default=8.0)
    args = parser.parse_args()

    desktop = pyatspi.Registry.getDesktop(0)
    deadline = time.monotonic() + max(args.wait, 0)
    app = None
    while app is None and time.monotonic() < deadline:
        app = find_application(desktop, args.application)
        if app is None:
            time.sleep(0.1)
    if app is None:
        print(f"AT-SPI application not found: {args.application}", file=sys.stderr)
        return 1

    lines: list[str] = []
    describe(app, 0, lines, [0])
    for line in lines:
        print(line)
    if len(lines) < 2:
        print("AT-SPI application has no semantic children", file=sys.stderr)
        return 1
    if not any("actions=['click'" in line for line in lines):
        print("AT-SPI tree has no observed actionable click node", file=sys.stderr)
        return 1
    print(f"AT-SPI semantic probe: PASS ({len(lines)} nodes observed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
