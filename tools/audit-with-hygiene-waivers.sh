#!/usr/bin/env bash
# Run an onebin audit, tolerating hygiene findings that originate in
# third-party prebuilt code we deliberately do not rebuild.
#
# Why this exists
# ---------------
# The host audit of f4-qt-host reaches 0 errors and fails only on
# OB0060 -- "embedded build-time path" -- warnings, under --strict. Every
# such path is a string compiled into a prebuilt Conan archive (Qt's own
# sources, libheif's temp paths), not into anything this project
# compiles. OB0060 is a pure string scan: the paths sit in .rodata and
# .debug_str, never in DT_NEEDED or RUNPATH, so they do not affect whether
# the binary runs anywhere. They are a build-hygiene and reproducibility
# matter, not a portability one -- which is exactly why onebin rates them
# WARN and not ERROR.
#
# We keep --strict because for OUR OWN code these paths are removable
# (-ffile-prefix-map) and their reappearance would be a regression worth
# failing on. So the tolerance is scoped to third-party origins, and it
# expires.
#
# What makes this a waiver and not a suppression
# ----------------------------------------------
# 1. It is keyed to OB0060 alone. Every other finding, and every error,
#    still fails the audit under --strict.
# 2. It matches by ORIGIN substring, not by exact path. Conan package
#    directories carry per-build hashes and temp paths carry random
#    suffixes; pinning exact strings would rot on the first dependency
#    bump and fail spuriously. The origins below are stable: the Conan
#    cache layout, Qt's source tree, libheif's temp names.
# 3. It only ever tolerates a THIRD-PARTY origin. An OB0060 path that
#    matches none of the origins -- for instance one from this project's
#    own compilation -- is NOT waived and fails the audit, loudly, which
#    is the regression signal we are keeping --strict for.
# 4. It expires by itself. If the audit comes back with zero OB0060
#    findings, this script FAILS with STALE WAIVER and says so: a
#    tolerance nobody is forced to revisit outlives the problem, so it is
#    wired to complain the moment upstream (or a dependency drop) removes
#    the paths.
# 5. It is never silent: every tolerated run prints each waived path, its
#    origin, and the reminder that this is a waiver.
#
# Usage: audit-with-hygiene-waivers.sh <onebin> [audit args... <file>]
#   The first argument is the onebin binary; the rest are passed through,
#   with --format json added. The audited FILE is the last argument.

set -uo pipefail

# ---------------------------------------------------------------------------
# Third-party origins whose OB0060 build paths are tolerated.
# One line per origin: "substring|why"
#
# To retire an entry: delete its line, once that dependency stops
# embedding the path (report filed upstream). Nothing else refers to it.
# ---------------------------------------------------------------------------
WAIVED_ORIGINS=(
# An origin beginning with '=' matches the subject by EXACT equality
# rather than substring. That is how the bare "/tmp/" prefix below is
# tolerated without also waiving every path that merely lives under /tmp
# -- including one our own code might someday emit.
".conan2/|Conan's package cache: absolute paths baked into prebuilt archives (Qt sources, libheif) that we consume rather than rebuild. Not our compilation units."
"/tmp/libheif|libheif bakes temp working paths into its own strings; upstream, not ours."
"perf-%1.map|a libheif/HEVC profiling artefact path string, from prebuilt code."
"/src/qtbase/|Qt's own source paths, __FILE__ in prebuilt Qt archives."
"=/tmp/|libheif's bare temp-prefix string (a format prefix it appends a name to at runtime). Matched exactly, so a real path UNDER /tmp is not waived."
"colorer4go/|colorer4go (f4's syntax highlighting): __FILE__ strings from Colorer (far2l) compiled to a .wasm module that ships as data inside the Go binary. Baked into the prebuilt wasm on the author's machine (/home/unxed/dev/...); unremovable without rebuilding Colorer. Third-party, not our compilation."
"/tmp/.X11-unix|an X11 protocol string table baked into prebuilt Qt (socket-path prefix concatenated with event names). Qt's, not ours."
)

if [ "$#" -lt 2 ]; then
    printf 'usage: %s <onebin> [audit args... <file>]\n' "$0" >&2
    exit 2
fi

ONEBIN="$1"; shift

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

# Run once, in JSON, so matching is on structured fields and not on the
# shape of the human-readable output.
"$ONEBIN" audit "$@" --format json >"$OUT" 2>/dev/null || true

# The audited file is the last positional argument to the wrapper.
AUDITED_FILE="${!#}"

if ! python3 - "$OUT" "$AUDITED_FILE" "${WAIVED_ORIGINS[@]}" <<'PY'
import json, sys

report_path = sys.argv[1]
audited_file = sys.argv[2]
origins = []
for entry in sys.argv[3:]:
    sub, _, why = entry.partition("|")
    origins.append((sub, why))

with open(report_path) as fh:
    data = json.load(fh)

findings = data.get("findings", [])
errors = data.get("counts", {}).get("error", 0)

# Always leave a full, human-readable report next to the audited file.
# stderr is not captured by the CI collector, so without this a failing
# audit is a dead end: you see it failed, not why. This file lands in the
# output dir and rides into the diagnostic artifact.
import os
if audited_file and os.path.exists(audited_file):
    try:
        with open(audited_file + ".audit.txt", "w") as rep:
            rep.write(f"onebin audit report for {audited_file}\n")
            rep.write(f"result: {data.get('result')}  counts: {data.get('counts')}\n\n")
            for f in findings:
                rep.write(f"{f.get('severity','?'):5} {f.get('id','?')}  "
                          f"{f.get('subject','') or f.get('message','')}\n")
    except OSError:
        pass

ob0060 = [f for f in findings if f.get("id") == "OB0060" and f.get("subject")]

# OB0061 ("embedded host-toolchain path") fires on substrings like
# /usr/lib/x86_64-linux-gnu/. In f4 the match is
# /usr/lib/x86_64-linux-gnu/libX11.so.6 -- a runtime dlopen path goffi
# uses to load X11. But the auditor truncates the finding subject to 200
# chars and the triggering substring can fall past that cut, so the
# subject alone cannot tell a load path from a leak. Inspect the BINARY
# instead: pull every toolchain-substring occurrence out of it and check
# each is part of a .so load path. All .so -> functional, waived. Any
# occurrence that is not (an -L dir, a compiler prefix) -> genuine leak,
# not waived, still fails.
ob0061 = [f for f in findings if f.get("id") == "OB0061"]

_TOOLCHAIN_SUBS = ("/usr/lib/x86_64-linux-gnu/", "/usr/lib/aarch64-linux-gnu/",
                   "/usr/lib64/", "/nix/store/", "/opt/rh/")
def ob0061_all_load_paths():
    """True if every toolchain-substring occurrence in the binary is a
    .so load path. Reads the binary's printable strings directly."""
    try:
        import subprocess, re
        raw = subprocess.run(["strings", audited_file], capture_output=True,
                             text=True, timeout=60).stdout
    except Exception:
        return False  # cannot verify -> do not waive
    found_any = False
    for sub in _TOOLCHAIN_SUBS:
        for m in re.finditer(re.escape(sub) + r"[A-Za-z0-9._+/-]*", raw):
            found_any = True
            token = m.group(0)
            # A load path contains a shared object name.
            if ".so" not in token:
                return False
    return found_any

ob0061_waivable = bool(ob0061) and ob0061_all_load_paths()
ob0061_waived = ob0061 if ob0061_waivable else []
ob0061_unwaived = [] if ob0061_waivable else ob0061

other_warns = [
    f for f in findings
    if f.get("severity") == "warn"
    and f.get("id") not in ("OB0060", "OB0061")
]

def origin_of(path):
    for sub, why in origins:
        if sub.startswith("="):
            if path == sub[1:]:
                return sub, why
        elif sub in path:
            return sub, why
    return None, None

waived, unwaived = [], []
for f in ob0060:
    sub, why = origin_of(f["subject"])
    (waived if sub else unwaived).append((f["subject"], sub, why))

# Any error, or any non-OB0060 warning, means this wrapper must not
# rescue the run: it is scoped to third-party hygiene only.
if errors > 0:
    # Name them. Printing only the count -- as an earlier version did --
    # sends the one fact that matters (which errors) to nowhere: the CI
    # collector does not capture this stderr, so "2 error(s)" left the
    # actual findings invisible and undiagnosable.
    error_findings = [f for f in findings if f.get("severity") == "error"]
    print(f"audit reports {errors} error(s); not waivable here:", file=sys.stderr)
    for f in error_findings:
        print(f"  {f.get('id','?')}  {f.get('subject','') or f.get('message','')}",
              file=sys.stderr)
    sys.exit(1)
if other_warns:
    print("audit reports warnings other than OB0060/OB0061; not waivable here:",
          file=sys.stderr)
    for f in other_warns:
        print(f"  {f['id']}  {f.get('subject','')}", file=sys.stderr)
    sys.exit(1)

# An OB0061 toolchain path whose matched substring is NOT a library-load
# path is a genuine leak (an -L directory, a compiler prefix) and must
# fail -- the narrow waiver above covers only functional dlopen paths.
if ob0061_unwaived:
    print("OB0061 toolchain paths that are not library-load paths and must be fixed:",
          file=sys.stderr)
    for f in ob0061_unwaived:
        print(f"  {f.get('subject','')}", file=sys.stderr)
    sys.exit(1)

# An OB0060 path from a non-third-party origin (e.g. our own compilation)
# is a real regression: -ffile-prefix-map should have stripped it.
if unwaived:
    print("OB0060 build paths that are NOT third-party and must be fixed",
          file=sys.stderr)
    print("(strip with -ffile-prefix-map; do not add them to the waiver):",
          file=sys.stderr)
    for path, _, _ in unwaived:
        print(f"  {path}", file=sys.stderr)
    sys.exit(1)

# Self-expiry: a waiver for a problem that no longer occurs is a defect.
if not ob0060 and not ob0061_waived:
    print("", file=sys.stderr)
    print("STALE WAIVER: the audit reports no OB0060/OB0061 hygiene paths.",
          file=sys.stderr)
    print("The third-party paths are gone -- delete the WAIVED_ORIGINS",
          file=sys.stderr)
    print(f"entries and drop this wrapper from the plan.", file=sys.stderr)
    print("This failure is deliberate: it is how the tolerance is removed",
          file=sys.stderr)
    print("once the dependencies stop embedding the paths.", file=sys.stderr)
    sys.exit(1)

# Tolerated, and said out loud.
print("audit passed except for third-party hygiene findings, which do not")
print("affect portability -- these strings live in .rodata, never in")
print("DT_NEEDED or RUNPATH.")
if waived:
    print("")
    print("OB0060 build paths waived by origin:")
    # Group by origin: the rationale is per-origin, so repeating it for
    # every path buries the log in duplicate paragraphs.
    by_origin = {}
    for path, sub, why in waived:
        by_origin.setdefault((sub, why), []).append(path)
    for (sub, why), paths in by_origin.items():
        print(f"  origin: {sub}  ({len(paths)} path(s))")
        print(f"    {why}")
        for path in paths:
            print(f"      {path[:110]}")
if ob0061_waived:
    print("")
    print("OB0061 toolchain matches waived as functional library-load paths")
    print("(goffi/f4 dlopen targets, not build-environment leaks):")
    for f in ob0061_waived:
        subj = f["subject"]
        print(f"  {subj[:100]}")
print("")
print("This is a waiver, not a pass. When a dependency stops embedding")
print("its paths, this wrapper fails with STALE WAIVER and the matching")
print("entry should be deleted.")
sys.exit(0)
PY
then
    exit 1
fi

exit 0
