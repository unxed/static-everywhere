#!/usr/bin/env python3
"""Extract the ninja build statements for object files named in a build failure.

Why this exists
---------------
A link error names symbols and object files; it does not name the flags
those objects were compiled with. Twice now the flags were the answer:
`WrapOpenGL`/`EGL` came down to `find_library` search paths, and Qt's 26
undefined `_74` ICU symbols came down to an include directory that was
missing from a compile line. `build.ninja` holds every compile line
verbatim, but for a project the size of Qt it is far too large to ship
in a diagnostic artifact.

So ship only the part that the failure itself points at. The object
files are named in the error output; their build statements -- including
the `INCLUDES`, `FLAGS` and `DEFINES` variables CMake writes as indented
lines underneath -- are looked up in `build.ninja` by name. Nothing here
guesses which package broke, which files matter, or what a build system
calls anything: the same principle that replaced filename guessing with
Conan's own "Build folder" line.

Usage:
    ci-extract-compile-commands.py BUILD_LOG BUILD_DIR [BUILD_DIR ...]

Writes to stdout. Exits 0 even when it finds nothing -- a diagnostic
collector must never be the reason a job reports a different failure
than the real one.
"""

import os
import re
import sys

# Cap the output. A pathological failure can name hundreds of objects,
# and the whole point of this file is that it stays small enough to
# download on a mobile connection.
MAX_OBJECTS = 60
MAX_BYTES = 512 * 1024

# Matches both the bare form ld.lld uses when reporting an archive member
# ("qtimezonelocale.cpp.o:(...) in archive ...") and full relative paths
# as they appear in FAILED: lines and command echoes.
OBJ_RE = re.compile(r"[\w./+-]+\.(?:o|obj)\b")


# Deliberately strict. The first version of this matched any line
# containing "undefined" or "duplicate", which sounds right and is not:
# a real build log is full of *command echoes* carrying flags like
# `-no-undefined` and `-Wduplicate-enum`. On a real Qt failure that
# filled the entire budget with liblzma object names from a package that
# had built successfully twenty minutes earlier, and the three objects
# the failure actually named never appeared. Match the diagnostic forms
# -- with their punctuation -- not the bare words.
FAILURE_RE = re.compile(
    r"(?:^|\s)(?:error:|warning:\s+.*error:|FAILED:|ninja:\s+build stopped)"
    r"|undefined symbol:|duplicate symbol:|referenced by|^>>>"
)


def objects_from_log(path):
    """Object names named by a line that is genuinely a failure diagnostic.

    Returns the *last* names in file order. A build log is chronological
    and the failure is at the end; taking the first N would report on
    whatever packages happened to be noisy earliest.
    """
    found, seen = [], set()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if not FAILURE_RE.search(line):
                    continue
                for m in OBJ_RE.finditer(line):
                    name = m.group(0)
                    if name not in seen:
                        seen.add(name)
                        found.append(name)
    except OSError as e:
        print(f"# could not read build log {path}: {e}")
    return found


def statements(ninja_path):
    """Yield (outputs, text) for every build statement in a ninja file.

    A statement is the `build ...:` line plus the indented lines that
    follow it, which is where CMake puts INCLUDES/FLAGS/DEFINES.
    """
    try:
        with open(ninja_path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        print(f"# could not read {ninja_path}: {e}")
        return

    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.startswith("build "):
            i += 1
            continue
        start = i
        i += 1
        while i < n and (lines[i].startswith((" ", "\t"))
                         or lines[i].rstrip("\n").endswith("$")):
            i += 1
        text = "".join(lines[start:i])
        head = line[len("build "):].split(":", 1)[0]
        # Ninja escapes ':' in paths as '$:'; outputs are space separated.
        outs = [o.replace("$:", ":") for o in head.split()]
        yield outs, text


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 0

    log, build_dirs = argv[1], argv[2:]
    wanted = objects_from_log(log)
    if not wanted:
        print("# no object files named in any error line of the build log")
        return 0

    # Keep the LAST names: the failure is at the end of a build log.
    dropped = max(0, len(wanted) - MAX_OBJECTS)
    wanted = wanted[-MAX_OBJECTS:]
    if dropped:
        print(f"# {dropped} earlier object name(s) dropped to stay within "
              f"the {MAX_OBJECTS}-object cap; the failure is at the end of "
              f"the log, so the newest are kept")
    print(f"# {len(wanted)} object file(s) named in error lines; "
          f"looking each one up in build.ninja")
    for w in wanted:
        print(f"#   {w}")
    print()

    written, matched = 0, set()
    for d in build_dirs:
        ninja = os.path.join(d, "build.ninja")
        if not os.path.isfile(ninja):
            print(f"# {ninja}: no build.ninja "
                  f"(not a ninja build -- nothing to extract)")
            continue
        print(f"# ==== from {ninja} ====")
        for outs, text in statements(ninja):
            hit = next((w for w in wanted for o in outs
                        if o == w or o.endswith("/" + w)), None)
            if hit is None:
                continue
            matched.add(hit)
            if written < MAX_BYTES:
                print(f"# --- matched {hit} ---")
                print(text)
                written += len(text)

    missing = [w for w in wanted if w not in matched]
    if missing:
        print("# no build statement found for: " + " ".join(missing))
    if written >= MAX_BYTES:
        print(f"# output truncated at {MAX_BYTES} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
