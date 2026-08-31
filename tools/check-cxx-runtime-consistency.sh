#!/usr/bin/env bash
# An archive handed across a toolchain boundary must reference the same
# C++ standard library the final link provides.
#
# Why this exists
# ---------------
# SoLo is built in an Alpine container with Alpine's clang, which
# defaults to libstdc++. far2l is linked with zig, which provides libc++.
# The mismatch surfaced only at the very end, after the whole program had
# compiled:
#
#   ld.lld: error: undefined symbol: std::__throw_length_error(char const*)
#   >>> referenced by basic_string.tcc:144
#   >>>   dlfcn.cpp.o:(...) in archive solo-src/libdlfcn.a
#
# — sixty of them, naming symbols that exist in no library on our side.
# The archive had been wrong since the moment it was produced, several
# minutes and one whole compile earlier.
#
# The two runtimes are trivially distinguishable in the mangled names:
# libstdc++ puts its string and container internals in the `__cxx11`
# inline namespace (`_ZNSt7__cxx11...`) and exports helpers like
# `_ZSt20__throw_length_errorPKc`; libc++ uses `__1` (`_ZNSt3__1...`).
# Verified on real objects from both compilers rather than assumed.
#
# So check the artifact where it is produced, not where it fails.
set -euo pipefail

if [ "$#" -lt 1 ]; then
    printf 'usage: %s <archive-or-object>...\n' "$0" >&2
    exit 2
fi

if ! command -v nm >/dev/null 2>&1; then
    printf 'nm unavailable; skipping the C++ runtime check\n'
    exit 0
fi

status=0
for artifact in "$@"; do
    if [ ! -f "$artifact" ]; then
        printf 'check-cxx-runtime: %s does not exist\n' "$artifact" >&2
        exit 1
    fi

    undefined=$(nm -u "$artifact" 2>/dev/null || true)

    # libstdc++ fingerprints. __cxx11 is the decisive one; the __throw_
    # and _Hash_bytes helpers are libstdc++-only spellings that appear
    # even when no string type is involved.
    gnu=$(printf '%s\n' "$undefined" \
          | grep -oE '_ZNSt7__cxx11[0-9A-Za-z_]*|_ZSt[0-9]+__throw[0-9A-Za-z_]*|_ZSt11_Hash_bytes[0-9A-Za-z_]*|_ZNK?St8__detail[0-9A-Za-z_]*' \
          | sort -u || true)

    if [ -n "$gnu" ]; then
        printf '%s references libstdc++, but this link provides libc++\n' \
            "$artifact" >&2
        printf 'Undefined symbols that only libstdc++ defines:\n' >&2
        printf '%s\n' "$gnu" | head -8 | sed 's/^/  /' >&2
        printf '\n' >&2
        printf 'Build this artifact with the same C++ runtime as the final\n' >&2
        printf 'link -- for the SoLo container, install libc++-dev and pass\n' >&2
        printf '-stdlib=libc++. Linking it as-is fails at the very end with\n' >&2
        printf 'dozens of undefined std:: symbols and no hint of the cause.\n' >&2
        status=1
        continue
    fi

    printf '%s: C++ runtime references are consistent with libc++\n' "$artifact"
done

exit "$status"
