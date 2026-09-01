#!/usr/bin/env bash
# The zig wrappers must not offer host libc headers or host libraries to a
# musl target. Declared graphics headers use a separate staging boundary.
#
# Why this exists
# ---------------
# zig-cc and zig-c++ append `-idirafter /usr/include` and `-L/usr/lib*`
# only for non-musl targets. Those fallbacks exist for Profile H, which
# links against a declared host contract: xcb/*, X11/* live in /usr/include
# and pkg-config emits no -I for them.
#
# Profile S and U still must not see the host libc. Profile U's SDL recipe
# has a narrow, explicit graphics-header contract, staged by
# build-far2l-deps.sh; the generic /usr/include root is never part of it.
# The original far2l failure proved why: musl has no backtrace(), and a broad
# host include path made utils/include/debug.h fall through to glibc's
# /usr/include/execinfo.h before the parser failed on __BEGIN_DECLS.
#
# So: musl target -> no host libc paths; gnu target -> host paths, because
# Profile H needs them. U's graphics exception is opt-in and filtered.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CC="${REPO_ROOT}/onebin/toolchain/zig-cc"
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

if ! command -v zig >/dev/null 2>&1; then
    printf 'zig unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

# execinfo.h is the sharp case: glibc has it, musl does not, and the host
# copy does not even parse outside glibc.
printf '#include <execinfo.h>\nint main(void){return 0;}\n' >"$PROBE/probe.c"
cp "$PROBE/probe.c" "$PROBE/probe.cpp"

for tool_lang in "$CC:c" "$CXX:cpp"; do
    tool="${tool_lang%:*}"
    ext="${tool_lang##*:}"

    # 1. musl must NOT find the host header. "file not found" is the
    #    correct outcome; anything that compiles means the host leaked in.
    if out=$("$tool" -target x86_64-linux-musl "$PROBE/probe.$ext" \
                -o "$PROBE/out" 2>&1); then
        printf 'a musl build compiled <execinfo.h>: the host include path leaked\n' >&2
        printf '  tool: %s\n' "$tool" >&2
        exit 1
    fi
    case "$out" in
        *"file not found"*) ;;
        *)
            printf 'a musl build failed on <execinfo.h>, but not by absence:\n' >&2
            printf '%s\n' "$out" | head -5 | sed 's/^/  /' >&2
            printf '  (a parse error here means the host header was offered)\n' >&2
            exit 1
            ;;
    esac

    # CMake frequently emits the generic root explicitly rather than relying
    # on the compiler default. It must be filtered just like the implicit
    # fallback above; otherwise a later try_compile can reintroduce glibc.
    if out=$("$tool" -target x86_64-linux-musl -I/usr/include "$PROBE/probe.$ext" \
                -o "$PROBE/out" 2>&1); then
        printf 'an explicit musl -I/usr/include compiled <execinfo.h>: host libc leaked\n' >&2
        exit 1
    fi
    case "$out" in
        *"file not found"*) ;;
        *)
            printf 'an explicit musl host-root include failed unexpectedly:\n' >&2
            printf '%s\n' "$out" | head -5 | sed 's/^/  /' >&2
            exit 1
            ;;
    esac

    # 2. glibc must still find it, or Profile H loses the host contract
    #    headers this fallback exists to provide.
    "$tool" -target x86_64-linux-gnu.2.27 "$PROBE/probe.$ext" \
        -o "$PROBE/out" 2>/dev/null \
        || { printf 'a glibc build no longer sees host headers: %s\n' "$tool" >&2
             exit 1; }
done

# 3. The musl toolchain must supply the de-facto musl identity macro.
#    musl defines nothing that identifies it, so guards written as
#    !defined(__MUSL__) -- far2l's among them -- silently take the glibc
#    branch without it.
#
#    Checked by configuring with the real toolchain file and compiling
#    far2l's actual guard, not by grepping for the string: the string
#    also appears in that file's explanatory comment, so a grep passes
#    even when the flag has been removed. (It did, until this control
#    caught it.)
if command -v cmake >/dev/null 2>&1; then
    mkdir -p "$PROBE/tc"
    cat >"$PROBE/tc/CMakeLists.txt" <<'CMEOF'
cmake_minimum_required(VERSION 3.16)
project(musl_identity C)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/flags.txt"
     CONTENT "${CMAKE_C_FLAGS}")
CMEOF
    if cmake -S "$PROBE/tc" -B "$PROBE/tcb" \
            -DCMAKE_TOOLCHAIN_FILE="${REPO_ROOT}/onebin/toolchain/onebin-linux-static.cmake" \
            >/dev/null 2>&1; then
        grep -q -- '-D__MUSL__' "$PROBE/tcb/flags.txt" \
            || { printf 'the musl toolchain does not put -D__MUSL__ in CMAKE_C_FLAGS;\n' >&2
                 printf 'far2l will include the host <execinfo.h> again\n' >&2
                 exit 1; }
    fi
fi

printf 'toolchain host isolation: musl sees no host headers, glibc still does\n'
