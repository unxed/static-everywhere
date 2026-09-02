#!/usr/bin/env bash
# The linker arguments CMake emits must be ones zig accepts.
#
# Why this exists
# ---------------
# far2l's Profile U link failed with
#
#   error: unsupported linker arg: --push-state
#
# after the whole program had compiled. Three separate defects, all of
# them a class rather than a one-off:
#
# 1. zig 0.13 accepts `-Wl,--whole-archive` and rejects the identical
#    `-Xlinker --whole-archive`. Every other driver treats the two
#    spellings as the same thing. CMake emits the -Xlinker form, so a
#    link that works by hand fails through the generator -- which is a
#    miserable thing to debug, because the flag is right there in
#    link.txt and works when pasted into a shell.
#
# 2. CMake's default WHOLE_ARCHIVE expansion brackets the item with
#    --push-state/--pop-state, which zig rejects in any spelling.
#
# 3. KDE's CMake settings add `-Wl,--fatal-warnings`, which zig 0.13 also
#    rejects although it only changes warning policy.
#
# The first two are fixed away from the call site: the wrappers translate
# -Xlinker, and the toolchains define WHOLE_ARCHIVE in terms zig accepts.
# The third is filtered by both compiler wrappers. This checks the outcome
# rather than the mechanism, so either fix can be rewritten without the test
# having to change.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

if ! command -v cmake >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1; then
    printf 'cmake or zig unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

printf 'int lib_sym(void){ return 1; }\n' >"$PROBE/l.c"
printf 'int main(void){ return 0; }\n' >"$PROBE/m.c"
cat >"$PROBE/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.24)
project(wa C)
add_library(mylib STATIC l.c)
add_executable(app m.c)
target_link_libraries(app PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,mylib>")
EOF

for toolchain in onebin-linux-static onebin-linux-hybrid; do
    tc="${REPO_ROOT}/onebin/toolchain/${toolchain}.cmake"
    [ -f "$tc" ] || continue
    build="$PROBE/b-${toolchain}"

    cmake -S "$PROBE" -B "$build" -DCMAKE_TOOLCHAIN_FILE="$tc" \
        >"$PROBE/cfg.log" 2>&1 \
        || { printf 'the probe did not configure with %s:\n' "$toolchain" >&2
             tail -5 "$PROBE/cfg.log" | sed 's/^/  /' >&2; exit 1; }

    link_line="$build/CMakeFiles/app.dir/link.txt"
    if grep -q -- '--push-state' "$link_line" 2>/dev/null; then
        printf '%s still emits --push-state, which zig rejects outright\n' \
            "$toolchain" >&2
        exit 1
    fi
    grep -q -- '--whole-archive' "$link_line" 2>/dev/null \
        || { printf '%s emits no --whole-archive; the feature is not being\n' \
                 "$toolchain" >&2
             printf 'applied at all, so the archive would not be linked whole\n' >&2
             exit 1; }

    # The point is that it links, not that the flags look plausible.
    cmake --build "$build" >"$PROBE/build.log" 2>&1 \
        || { printf 'the whole-archive link failed with %s:\n' "$toolchain" >&2
             grep -iE 'error|unsupported' "$PROBE/build.log" | head -5 \
                 | sed 's/^/  /' >&2
             exit 1; }
done

# And the -Xlinker spelling must reach the linker intact, since that is
# what CMake writes and what zig mishandles on its own.
printf 'int main(void){ return 0; }\n' >"$PROBE/x.c"
"${REPO_ROOT}/onebin/toolchain/zig-cc" -target x86_64-linux-musl \
    "$PROBE/x.c" -Xlinker --gc-sections -o "$PROBE/x" 2>"$PROBE/x.log" \
    || { printf '-Xlinker is not being translated for the linker:\n' >&2
         sed 's/^/  /' "$PROBE/x.log" >&2; exit 1; }

for compiler in zig-cc zig-c++; do
    case "$compiler" in
        zig-cc)  source="$PROBE/${compiler}.c" ;;
        zig-c++) source="$PROBE/${compiler}.cpp" ;;
    esac
    printf 'int main(void){ return 0; }\n' >"$source"
    "${REPO_ROOT}/onebin/toolchain/${compiler}" \
        -target x86_64-linux-gnu.2.27 "$source" -o "$PROBE/${compiler}" \
        -Wl,--fatal-warnings 2>"$PROBE/${compiler}.log" \
        || { printf '%s let unsupported --fatal-warnings reach zig:\n' "$compiler" >&2
             sed 's/^/  /' "$PROBE/${compiler}.log" >&2; exit 1; }
done

printf 'linker args: no --push-state, whole-archive links, -Xlinker survives, --fatal-warnings filtered\n'
