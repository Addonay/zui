#!/usr/bin/env python3
"""Run cozmic (Zig) + cosmic-text (Rust criterion) benches and render a
side-by-side comparison.

Default output is a box-drawn, column-aligned table for the terminal.
Use --format md (or --out table.md) for a Markdown table.

Sections:
  CONNECTED      cozmic bench matched to the same upstream workload
  COZMIC-ONLY    zig bench with no equivalent upstream bench yet
  UPSTREAM-ONLY  criterion bench with no equivalent cozmic bench yet

Progress streams to stderr per bench as it completes, so long runs never
look hung. Pass -q/--quiet to silence it.

Zig rows are captured from `zig build bench -- --format json` and cached to
zig-out/bench-zig.jsonl; reuse with --zig-json PATH. Criterion rows are read
from .reference/cosmic-text/target/criterion (so --no-rust still shows them).

Usage:
    python3 tools/bench_compare.py [--no-zig] [--no-rust] [--iters N]
        [--warmup N] [--measurement-time S] [--zig-json PATH] [-q]
        [--format table|md] [--out FILE]

Requires: zig, cargo (cargo only when not --no-rust).
"""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / ".reference" / "cosmic-text"
CRITERION = REF / "target" / "criterion"
DEFAULT_ZIG_JSON = ROOT / "zig-out" / "bench-zig.jsonl"


class ProcResult:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


# ---------------------------------------------------------------------------
# Runners
# ---------------------------------------------------------------------------


def run_streaming(cmd, cwd, prefix, on_line=None, quiet=False):
    """Run a command, streaming merged stdout/stderr line by line.

    `on_line(line)` sees every line so callers can report progress while the
    bench runs. Progress and the final timing line go to stderr; stdout stays
    clean for the comparison table. Returns a ProcResult with full output.
    """
    out = []
    t0 = time.monotonic()
    p = subprocess.Popen(
        cmd, cwd=str(cwd), stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    assert p.stdout is not None
    for line in p.stdout:
        out.append(line)
        if not quiet and on_line is not None:
            on_line(line)
    rc = p.wait()
    if not quiet:
        print(
            f"[{prefix}] finished in {time.monotonic() - t0:.1f}s (exit {rc})",
            file=sys.stderr,
        )
    return ProcResult(rc, "".join(out), "")


def zig_benches(iters, warmup, save_path, quiet=False):
    cmd = [
        "zig", "build", "bench", "-Doptimize=ReleaseFast",
        "--", "--format", "json", "--iter", str(iters), "--warmup", str(warmup),
    ]
    rows = []

    def on_line(line):
        stripped = line.strip()
        if not stripped:
            return
        if stripped.startswith('{"bench"'):
            try:
                r = json.loads(stripped)
            except json.JSONDecodeError:
                return
            rows.append(r)
            print(
                f"  [cozmic] {r['bench']:<38} {fmt_ns(r['mean_ns']):>10}"
                f"  ({r.get('glyphs', '?')} glyphs)",
                file=sys.stderr,
            )
        elif "error" in stripped.lower() or "failed" in stripped.lower():
            print(f"  [cozmic] {stripped}", file=sys.stderr)

    p = run_streaming(cmd, ROOT, "cozmic", on_line, quiet)
    if rows and save_path is not None:
        save_path.parent.mkdir(parents=True, exist_ok=True)
        with save_path.open("w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    return rows, p


def load_zig_json(path):
    rows = []
    p = Path(path)
    if not p.exists():
        return rows
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return rows


def rust_benches(measurement_time, quiet=False):
    # `cargo bench` uses the bench profile by default (no --release flag on
    # this cargo). Pass --bench explicitly so criterion flags don't hit the
    # libtest harness; --noplot keeps it headless (no gnuplot dependency).
    procs = []
    for bench in ("layout", "text_shaping_benchmarks"):
        cmd = ["cargo", "bench", "--bench", bench, "--",
               "--noplot", "--measurement-time", str(measurement_time)]

        def on_line(line, _bench=bench):
            l = line.rstrip()
            if l.startswith("Benchmarking "):
                name = l[len("Benchmarking "):].split(":")[0]
                print(f"  [cosmic/{_bench}] {name} ...", file=sys.stderr)
            elif "time:" in l:
                print(f"  [cosmic/{_bench}] {l.strip()}", file=sys.stderr)
            elif l.startswith(("Compiling ", "Finished ", "Running ")):
                print(f"  [cosmic/{_bench}] {l}", file=sys.stderr)
            elif l.startswith("error"):
                print(f"  [cosmic/{_bench}] {l}", file=sys.stderr)

        procs.append(run_streaming(cmd, REF, f"cosmic/{bench}", on_line, quiet))
    last = procs[-1]
    last.stdout = "\n".join(p.stdout for p in procs)
    last.stderr = "\n".join(p.stderr for p in procs)
    return last


def criterion_rows():
    rows = []
    if not CRITERION.is_dir():
        return rows
    for est in sorted(CRITERION.rglob("new/estimates.json")):
        try:
            d = json.loads(est.read_text())
            rel = est.relative_to(CRITERION)
            rows.append({
                "group": rel.parts[0],
                "bench": rel.parts[1],
                "mean_ns": float(d["mean"]["point_estimate"]),
                "median_ns": float(d["median"]["point_estimate"]),
            })
        except Exception:
            continue
    return rows


# ---------------------------------------------------------------------------
# Matching cozmic rows to upstream criterion rows
# ---------------------------------------------------------------------------

LAYOUT_SAMPLE = {
    "small": "small amount of text",
    "moby": "large amount of text",
    "arabic": "arabic text",
    "hebrew": "hebrew text",
    "emoji": "emoji text",
}

SHAPING_MATCH = {
    "ascii-fast-path": lambda g, b: g.startswith("shapeline_ascii fast path"),
    "bidi-mixed": lambda g, b: g.startswith("shapeline_bidi processing"),
    "hello-mixed": lambda g, b: g == "bench_lang_mixed" or "mixed-language" in b,
    "layout-heavy": lambda g, b: g.startswith("shapeline_layout heavy"),
    "combined-stress": lambda g, b: g.startswith("shapeline_combined stress"),
    "bidi-paras-ascii": lambda g, b: g.startswith("bidiparagraphs_ascii"),
    "bidi-paras-mixed": lambda g, b: g.startswith("bidiparagraphs_mixed"),
    # "arabic": no direct cozmic shaping bench maps to an upstream shaping
    # group; the nearest is the layout bench (different harness work).
}


def match_rust(zig_bench, rust_rows):
    """Return the best-matching criterion row, or None."""
    zl = zig_bench.lower()
    m = re.match(r"layout/([^/]+)/wrap\(([^)]+)\)", zl)
    if m:
        sample, wrap = m.group(1), m.group(2)
        shape = None
        if "," in wrap:
            wrap, shape = (part.strip() for part in wrap.split(",", 1))
        want = LAYOUT_SAMPLE.get(sample)
        if want is None:
            return None
        candidates = []
        for rr in rust_rows:
            g = rr["group"].lower().replace(" ", "")
            if not g.startswith("wrap("):
                continue
            if f"wrap({wrap}," not in g:
                continue
            if rr["bench"].lower() != want:
                continue
            if shape and f",{shape})" not in g:
                continue
            candidates.append(rr)
        if shape:
            return candidates[0] if candidates else None
        # Legacy rows (before the shaping dimension) ran .advanced.
        for rr in candidates:
            if "advanced" in rr["group"].lower():
                return rr
        return candidates[0] if candidates else None
    if "loadfontsystem" in zl.replace(" ", ""):
        for rr in rust_rows:
            blob = f"{rr['group']} {rr['bench']}".lower().replace(" ", "")
            if "fontsystem" in blob:
                return rr
        return None
    m = re.match(r"shaping/(.+)", zl)
    if m:
        case = m.group(1)
        pred = SHAPING_MATCH.get(case)
        if pred is None:
            return None
        for rr in rust_rows:
            if pred(rr["group"].lower(), rr["bench"].lower()):
                return rr
    return None


# ---------------------------------------------------------------------------
# Ordering + formatting
# ---------------------------------------------------------------------------

SAMPLE_ORDER = ["small", "moby", "arabic", "hebrew", "emoji", "hello_mixed"]
WRAP_ORDER = ["none", "glyph", "word", "word_or_glyph"]
SHAPING_ORDER = [
    "ascii-fast-path", "bidi-mixed", "hello-mixed", "layout-heavy",
    "combined-stress", "arabic", "bidi-paras-ascii", "bidi-paras-mixed",
]


def zig_sort_key(name):
    m = re.match(r"layout/([^/]+)/wrap\(([^)]+)\)", name.lower())
    if m:
        s, w = m.groups()
        shape = ""
        if "," in w:
            w, shape = (part.strip() for part in w.split(",", 1))
        si = SAMPLE_ORDER.index(s) if s in SAMPLE_ORDER else 99
        wi = WRAP_ORDER.index(w) if w in WRAP_ORDER else 99
        shi = {"simple": 0, "advanced": 1}.get(shape, 0)
        return (0, si, wi, shi, name)
    m = re.match(r"shaping/(.+)", name.lower())
    if m:
        c = m.group(1)
        ci = SHAPING_ORDER.index(c) if c in SHAPING_ORDER else 99
        return (1, ci, 0, 0, name)
    if "loadfontsystem" in name.lower().replace(" ", ""):
        return (2, 0, 0, 0, name)
    return (3, 0, 0, 0, name)


def fmt_ns(ns):
    if ns >= 1e9:
        return f"{ns / 1e9:.2f} s"
    if ns >= 1e6:
        return f"{ns / 1e6:.2f} ms"
    if ns >= 1e3:
        return f"{ns / 1e3:.2f} µs"
    return f"{ns:.0f} ns"


def rust_label(rr):
    if rr["bench"] == "new":
        return rr["group"]
    return f"{rr['group']} / {rr['bench']}"


def render_box(headers, rows):
    widths = []
    for i, h in enumerate(headers):
        w = len(h)
        for r in rows:
            w = max(w, len(str(r[i])))
        widths.append(w)
    top = "┌" + "┬".join("─" * (w + 2) for w in widths) + "┐"
    mid = "├" + "┼".join("─" * (w + 2) for w in widths) + "┤"
    bot = "└" + "┴".join("─" * (w + 2) for w in widths) + "┘"

    def row(cells):
        return "│ " + " │ ".join(
            str(c).ljust(widths[i]) for i, c in enumerate(cells)
        ) + " │"

    out = [top, row(headers), mid]
    for r in rows:
        out.append(row(r))
    out.append(bot)
    return out


def render_md(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-zig", action="store_true",
                    help="skip running zig benches (still uses --zig-json file)")
    ap.add_argument("--no-rust", action="store_true",
                    help="skip running cargo; still reads existing criterion data")
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--measurement-time", type=int, default=5)
    ap.add_argument("--zig-json", default=str(DEFAULT_ZIG_JSON),
                    help="cache file for zig rows (read and written)")
    ap.add_argument("-q", "--quiet", action="store_true",
                    help="suppress per-bench progress on stderr")
    ap.add_argument("--format", choices=["table", "md"], default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    zig_json = Path(args.zig_json)

    # ---- gather zig rows ----
    if args.no_zig:
        zig_rows = load_zig_json(zig_json)
        zig_proc = None
        if not args.quiet:
            print(
                f"[cozmic] skipped; using {len(zig_rows)} cached rows from "
                f"{zig_json}",
                file=sys.stderr,
            )
    else:
        if not args.quiet:
            print(
                "=== cozmic benches: zig build bench -Doptimize=ReleaseFast "
                f"-- --format json --iter {args.iters} --warmup {args.warmup}",
                file=sys.stderr,
            )
            print("    (first run may compile; benches stream as they finish)",
                  file=sys.stderr)
        zig_rows, zig_proc = zig_benches(
            args.iters, args.warmup, zig_json, args.quiet
        )

    # ---- gather criterion rows (always from disk) ----
    rust_rows = criterion_rows()
    rust_proc = None
    if not args.no_rust:
        if not args.quiet:
            print(
                "=== cosmic-text benches: cargo bench --bench layout --bench "
                f"text_shaping_benchmarks -- --noplot --measurement-time "
                f"{args.measurement_time}",
                file=sys.stderr,
            )
        rust_proc = rust_benches(args.measurement_time, args.quiet)
        rust_rows = criterion_rows()
    elif not args.quiet:
        print(
            f"[cosmic] skipped; using {len(rust_rows)} cached criterion rows "
            f"from {CRITERION}",
            file=sys.stderr,
        )

    # ---- build comparison records ----
    matched = []
    zig_only = []
    used_rust = set()
    for zr in sorted(zig_rows, key=lambda r: zig_sort_key(r["bench"])):
        rr = match_rust(zr["bench"], rust_rows)
        if rr is None:
            zig_only.append((zr, None))
            continue
        used_rust.add((rr["group"], rr["bench"]))
        matched.append((zr, rr))

    rust_only = [
        rr for rr in rust_rows
        if (rr["group"], rr["bench"]) not in used_rust
    ]
    rust_only.sort(key=lambda r: (r["group"].lower(), r["bench"].lower()))

    # ---- format ----
    fmt = args.format
    if fmt is None:
        fmt = "md" if (args.out or "").endswith((".md", ".markdown")) else "table"
    render = render_box if fmt == "table" else render_md

    lines = []
    lines.append("cozmic vs cosmic-text — mean time per iteration (lower is better)")
    lines.append("")
    if zig_proc is not None and zig_proc.returncode != 0:
        lines.append(f"WARNING: zig benches exited {zig_proc.returncode}")
    if rust_proc is not None and rust_proc.returncode != 0:
        lines.append(f"WARNING: cargo benches exited {rust_proc.returncode}")
    lines.append("")
    lines.append("NOTE: cozmic benches use the vendored sample corpus while")
    lines.append("cosmic-text runs on system fonts via fontconfig + HarfBuzz, so")
    lines.append("ratios are harness-level until deterministic fonts are wired.")
    lines.append("loadFontSystem: metadata scan vs fontdb face loading.")
    lines.append("")

    # Connected table.
    lines.append(f"CONNECTED — {len(matched)} matched workloads")
    lines.append("")
    if matched:
        headers = ["cozmic bench", "cozmic mean", "upstream bench",
                   "upstream mean", "ratio", "glyphs"]
        rows = []
        for zr, rr in matched:
            ratio = zr["mean_ns"] / rr["mean_ns"] if rr["mean_ns"] else float("nan")
            rows.append([
                zr["bench"],
                fmt_ns(zr["mean_ns"]),
                rust_label(rr),
                fmt_ns(rr["mean_ns"]),
                f"{ratio:.2f}x",
                str(zr.get("glyphs", "")),
            ])
        lines.extend(render(headers, rows))
    else:
        lines.append("(no matches — enable zig benches and criterion data)")
    lines.append("")

    # cozmic-only.
    lines.append(f"COZMIC-ONLY — {len(zig_only)} benches without an upstream counterpart")
    lines.append("")
    if zig_only:
        headers = ["cozmic bench", "mean", "glyphs", "note"]
        rows = []
        for zr, _ in zig_only:
            note = "no upstream bench at this width"
            if "word_or_glyph" in zr["bench"]:
                note = "no upstream bench row (Wrap::WordOrGlyph exists upstream)"
            elif zr["bench"].startswith("layout/hello_mixed"):
                note = "upstream hello.txt bench is shaping-only"
            elif zr["bench"] == "shaping/arabic":
                note = "nearest upstream row is the layout bench"
            rows.append([zr["bench"], fmt_ns(zr["mean_ns"]),
                         str(zr.get("glyphs", "")), note])
        lines.extend(render(headers, rows))
    else:
        lines.append("(none)")
    lines.append("")

    # upstream-only.
    lines.append(f"UPSTREAM-ONLY — {len(rust_only)} benches not covered by cozmic yet")
    lines.append("")
    if rust_only:
        headers = ["upstream bench", "mean", "note"]
        rows = []
        for rr in rust_only:
            note = ""
            g = rr["group"].lower()
            if "simple" in g:
                note = "cozmic benches only run Advanced shaping"
            elif "fontsystem" in g.replace(" ", ""):
                note = "font loading bench (fontconfig)"
            rows.append([rust_label(rr), fmt_ns(rr["mean_ns"]), note])
        lines.extend(render(headers, rows))
    else:
        lines.append("(none)")
    lines.append("")

    out = "\n".join(lines) + "\n"
    if args.out:
        Path(args.out).write_text(out)
        print(f"wrote {args.out}")
    else:
        print(out)

    code = 0
    if zig_proc is not None and zig_proc.returncode != 0:
        code = 1
        print("--- zig output tail ---", file=sys.stderr)
        print((zig_proc.stdout or "")[-3000:], file=sys.stderr)
    if rust_proc is not None and rust_proc.returncode != 0:
        code = 1
        print("--- cargo output tail ---", file=sys.stderr)
        print((rust_proc.stdout or "")[-3000:], file=sys.stderr)
    sys.exit(code)


if __name__ == "__main__":
    main()
