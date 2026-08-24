#!/usr/bin/env python3
"""Scan source trees for calls to glibc symbols newer than the baseline.

Why this exists
---------------
`zig cc -target x86_64-linux-gnu.<ver>` versions the symbol stubs but not
the headers, so a library that decides availability in the preprocessor
compiles a call the older stub cannot satisfy and the link fails, often
hundreds of targets later. Qt did this twice -- `statx()` behind
`STATX_BASIC_STATS`, `close_range()` behind `CLOSE_RANGE_CLOEXEC` -- and
each one cost a two-hour CI run to discover.

The symbols are enumerable (tools/glibc-baseline-delta.py) and the source
trees are on disk, so the collision is findable in seconds rather than
hours. This does not replace the link; it removes the class of surprise
where the answer was sitting in a file all along.

What it does *not* do: it reads text, so it sees `std::call_once` and
glibc's C11 `call_once()` alike. Hits are a shortlist to look at, not a
verdict -- check whether each is really the libc function before adding a
shim to contrib/f4-qt/compat/glibc-shims.c.

Usage:
    glibc-source-scan.py [--baseline 2.27] [--ceiling 2.39] PATH [PATH...]

Exits 0 when nothing plausible is found, 1 when there are hits to review.
"""

import argparse
import os
import re
import subprocess
import sys

# Names that collide with common C++ or local identifiers often enough
# that reporting them is noise. Each is here because it was observed as a
# false positive, not on suspicion.
NOISE = {
    # std::call_once in C++ is not glibc's C11 call_once().
    "call_once",
    # C11 threads. Nothing in this graph uses <threads.h>, and the names
    # collide with ordinary identifiers.
    "thrd_yield", "thrd_equal", "thrd_sleep", "thrd_current",
    # The stat family appears in the delta because glibc 2.33 began
    # exporting these directly instead of only the __xstat wrappers. It
    # is not a hazard here and the evidence is direct: a program calling
    # stat/lstat/fstat, compiled with `zig cc -target
    # x86_64-linux-gnu.2.27`, links, runs, and readelf shows the single
    # undefined symbol is __xstat@GLIBC_2.2.5. zig's headers redirect to
    # the old wrapper for old targets. Left unlisted, these three fire on
    # nearly every file that touches the filesystem and the whole report
    # becomes noise.
    "stat", "fstat", "lstat", "fstatat",
    "stat64", "fstat64", "lstat64", "fstatat64",
    "mknod", "mknodat",
}

SOURCE_EXTS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hxx", ".mm"}
SKIP_DIRS = {".git", "build", "build-portable-linux", "node_modules", ".cache"}


def delta_symbols(baseline, ceiling, here):
    """Ask glibc-baseline-delta.py for the symbol list."""
    tool = os.path.join(here, "glibc-baseline-delta.py")
    r = subprocess.run([sys.executable, tool, baseline, ceiling],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"glibc-baseline-delta.py failed:\n{r.stderr.strip()}")
    syms = []
    for line in r.stdout.splitlines():
        name = line.strip()
        # The tool prints a short header first; symbol lines are bare.
        if not name or " " in name or name.startswith("_"):
            continue
        if len(name) > 3 and name not in NOISE:
            syms.append(name)
    return syms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--baseline", default="2.27")
    ap.add_argument("--ceiling", default="2.39")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    syms = delta_symbols(args.baseline, args.ceiling, here)
    if not syms:
        sys.exit("no symbols in the delta -- that cannot be right")

    # Only a call looks like a call: `name(`. A bare mention in a comment
    # or a member named the same thing is not a link-time reference.
    pattern = re.compile(r"(?<![\w:.>])(" + "|".join(map(re.escape, syms)) + r")\s*\(")

    hits = {}
    scanned = 0
    for root in args.paths:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                if os.path.splitext(fn)[1] not in SOURCE_EXTS:
                    continue
                path = os.path.join(dirpath, fn)
                scanned += 1
                try:
                    text = open(path, errors="replace").read()
                except OSError:
                    continue
                for m in pattern.finditer(text):
                    hits.setdefault(m.group(1), set()).add(path)

    print(f"  scanned {scanned} source files against "
          f"{len(syms)} symbols added between glibc "
          f"{args.baseline} and {args.ceiling}")

    if not hits:
        print("  \033[32mok\033[0m   no calls to symbols newer than the baseline")
        return 0

    print(f"  \033[33m{len(hits)} symbol(s) to review\033[0m — confirm each is "
          f"really the libc function, then shim it:")
    for name in sorted(hits):
        where = sorted(hits[name])
        print(f"    {name:22} {where[0]}"
              + (f" (+{len(where) - 1} more)" if len(where) > 1 else ""))
    return 1


if __name__ == "__main__":
    sys.exit(main())
