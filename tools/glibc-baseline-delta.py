#!/usr/bin/env python3
"""List the glibc symbols a newer baseline has and an older one does not.

Why this exists
---------------
`zig cc -target x86_64-linux-gnu.<ver>` versions the *symbol stubs* but
not the *headers*: the headers always describe the newest glibc zig
ships. So any library that decides whether a function exists in the
preprocessor -- typically a bare `#ifdef` on a kernel UAPI macro --
compiles a call that the older stub cannot satisfy, and the build fails
at link time, often hundreds of targets after the cause. Qt has done
this twice: `statx()` behind `STATX_BASIC_STATS`, and `close_range()`
behind `CLOSE_RANGE_CLOEXEC`.

The obvious question is "how many more of these are there", and the
obvious way to answer it is to ask the stubs rather than to reason. Note
the trap this exists to prevent: an earlier answer of "seven symbols"
came from diffing *only* `libc.so.6` between 2.27 and 2.28. Both halves
were wrong. glibc 2.34 merged libpthread, libdl, librt and libresolv
into libc, so a libc-only diff invents hundreds of arrivals that were
merely relocated; and 2.28 is not the ceiling -- the headers describe
the newest glibc zig knows, so that is the version to compare against.
This script unions every stub library and defaults the ceiling to zig's
newest.

Usage:
    glibc-baseline-delta.py [OLD] [NEW] [--zig PATH] [--target ARCH]

Defaults: OLD=2.27, NEW=2.39, ARCH=x86_64-linux-gnu.

Needs `zig` and `readelf` on PATH. Builds a trivial program for each
version into a private cache so the generated stubs can be read.
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile


def stub_symbols(zig, target, version, workdir):
    """Every symbol *defined* by any stub library for one glibc version."""
    cache = os.path.join(workdir, f"cache-{version}")
    src = os.path.join(workdir, "probe.c")
    with open(src, "w") as f:
        f.write("int main(void){return 0;}\n")

    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=cache)
    out = os.path.join(workdir, f"probe-{version}")
    r = subprocess.run(
        [zig, "cc", "-target", f"{target}.{version}", src, "-o", out],
        env=env, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"zig cc failed for {target}.{version}:\n{r.stderr.strip()}")

    libs = glob.glob(os.path.join(cache, "**", "*.so*"), recursive=True)
    if not libs:
        sys.exit(f"no stub libraries generated for {version}")

    symbols = set()
    for lib in libs:
        r = subprocess.run(["readelf", "--dyn-syms", "-W", lib],
                           capture_output=True, text=True)
        for line in r.stdout.splitlines()[3:]:
            fields = line.split()
            # Ndx (field 6) of UND means "referenced", not "provided".
            if len(fields) >= 8 and fields[6] != "UND":
                symbols.add(fields[7].split("@")[0])
    return symbols, len(libs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old", nargs="?", default="2.27")
    ap.add_argument("new", nargs="?", default="2.39")
    ap.add_argument("--zig", default="zig")
    ap.add_argument("--target", default="x86_64-linux-gnu")
    args = ap.parse_args()

    if not shutil.which(args.zig):
        sys.exit(f"{args.zig} not found on PATH")
    if not shutil.which("readelf"):
        sys.exit("readelf not found on PATH")

    workdir = tempfile.mkdtemp(prefix="glibc-delta-")
    try:
        old, n_old = stub_symbols(args.zig, args.target, args.old, workdir)
        new, n_new = stub_symbols(args.zig, args.target, args.new, workdir)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    delta = sorted(new - old)
    print(f"{args.target}.{args.old}: {len(old)} symbols across "
          f"{n_old} stub libraries")
    print(f"{args.target}.{args.new}: {len(new)} symbols across "
          f"{n_new} stub libraries")
    print(f"\nIn {args.new} but not {args.old}: {len(delta)}\n")
    for name in delta:
        print(name)


if __name__ == "__main__":
    main()
