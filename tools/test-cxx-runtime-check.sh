#!/usr/bin/env bash
# The C++ runtime checker must tell libstdc++ from libc++.
#
# Why this exists
# ---------------
# SoLo is built in an Alpine container whose clang defaults to
# libstdc++; far2l is linked by zig, which provides libc++. The archive
# crossed that boundary and the mismatch surfaced only at the final link:
#
#   ld.lld: error: undefined symbol: std::__throw_length_error(char const*)
#   >>> referenced by basic_string.tcc:144
#   >>>   dlfcn.cpp.o:(...) in archive solo-src/libdlfcn.a
#
# sixty times over, after the whole program had compiled, naming symbols
# that exist in no library on our side. The archive had been wrong since
# the moment it was produced.
#
# The two runtimes are distinguishable in the mangled names -- libstdc++
# uses the `__cxx11` inline namespace, libc++ uses `__1` -- but a rule
# like that decays into folklore unless something keeps proving it. So
# this builds one object with each real compiler and requires the checker
# to reach opposite conclusions.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CHECK="${REPO_ROOT}/tools/check-cxx-runtime-consistency.sh"

if ! command -v g++ >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1 \
   || ! command -v ar >/dev/null 2>&1 || ! command -v nm >/dev/null 2>&1; then
    printf 'g++, zig, ar or nm unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

# Uses std::string and an unordered_map, which is what pulls in the
# runtime-specific helpers the checker looks for.
cat >"$PROBE/probe.cpp" <<'EOF'
#include <string>
#include <unordered_map>
std::string probe(const char* s) {
    std::unordered_map<std::string, int> m;
    m[s] = 1;
    return s;
}
EOF

# g++ here means libstdc++ -- the shape of the archive that broke far2l.
g++ -c "$PROBE/probe.cpp" -o "$PROBE/gnu.o" 2>/dev/null \
    || { printf 'could not build the libstdc++ probe object\n' >&2; exit 1; }
ar rcs "$PROBE/gnu.a" "$PROBE/gnu.o"

# zig c++ means libc++ -- the shape the final link expects.
"${REPO_ROOT}/onebin/toolchain/zig-c++" -target x86_64-linux-musl \
    -c "$PROBE/probe.cpp" -o "$PROBE/llvm.o" 2>/dev/null \
    || { printf 'could not build the libc++ probe object\n' >&2; exit 1; }
ar rcs "$PROBE/llvm.a" "$PROBE/llvm.o"

if "$CHECK" "$PROBE/gnu.a" >/dev/null 2>&1; then
    printf 'the checker accepted a libstdc++ archive; it would not have\n' >&2
    printf 'caught the SoLo handoff that broke the far2l link\n' >&2
    exit 1
fi

"$CHECK" "$PROBE/llvm.a" >/dev/null 2>&1 \
    || { printf 'the checker rejected a libc++ archive, which is the runtime\n' >&2
         printf 'the link actually provides; it would fail every good build\n' >&2
         exit 1; }

# The rejection has to name the reason, or it sends the reader hunting.
message=$("$CHECK" "$PROBE/gnu.a" 2>&1 || true)
printf '%s' "$message" | grep -q 'libstdc++' \
    || { printf 'the rejection does not say which runtime was found:\n%s\n' \
             "$message" >&2; exit 1; }

printf 'cxx runtime check: libstdc++ rejected, libc++ accepted, reason named\n'
