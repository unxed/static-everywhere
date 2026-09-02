#!/usr/bin/env bash
# Which -Wl, arguments does zig cc's linker driver refuse?
#
# Why this exists
# ---------------
# zig cc parses -Wl, arguments itself and errors on any it does not
# recognise ("error: unsupported linker arg: X"), where GNU ld and lld
# would accept them. This project has now hit that three times, each time at
# the end of a long build:
#
#   -Wl,-rpath-link  from Conan's AutotoolsDeps generator, during elfutils
#   -Wl,--exclude-libs  added by f4 itself, at the final link of f4-qt-host
#   -Wl,--fatal-warnings  added by KDE compiler settings, during KDocTools
#
# Discovering these one build at a time is the expensive way. The set is
# enumerable in about a second, so enumerate it, and keep the answer where
# the next person will find it instead of rediscovering it.
#
# Run it after a zig upgrade too: the set is a property of the zig version,
# not of this project.
#
# Usage: zig-linker-arg-survey.sh [target-triple]

set -uo pipefail

TARGET="${1:-x86_64-linux-gnu.2.27}"

if ! command -v zig >/dev/null 2>&1; then
    echo "zig not found on PATH" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
printf 'int main(void){return 0;}\n' >"$WORK/m.c"

# Arguments a CMake, libtool, Meson or autotools build might plausibly
# emit. Not exhaustive -- nothing could be -- but wide enough that a new
# one showing up in a build is a surprise rather than the norm.
ARGS="
--as-needed --no-as-needed --gc-sections --no-gc-sections
--exclude-libs,ALL --exclude-libs=ALL
-z,relro -z,now -z,noexecstack -z,defs
--no-undefined --allow-shlib-undefined --unresolved-symbols=ignore-all
-rpath,/tmp -rpath-link,/tmp --enable-new-dtags --disable-new-dtags
--build-id --build-id=none -O1 --sort-common
--hash-style=gnu --hash-style=sysv --no-copy-dt-needed-entries
--warn-common --fatal-warnings
--version-script,/dev/null --dynamic-list,/dev/null
--whole-archive --no-whole-archive --start-group --end-group
-Bsymbolic -Bsymbolic-functions -Bstatic -Bdynamic
--strip-all --strip-debug --wrap,malloc --defsym,foo=0
-Map,/dev/null --print-map --no-keep-memory --reduce-memory-overheads
--compress-debug-sections=zlib --icf=all --threads
"

echo "zig $(zig version), target ${TARGET}"
echo

rejected=0
accepted=0
for arg in $ARGS; do
    # Capture first, then test. Piping zig straight into grep under
    # `set -o pipefail` returns zig's own non-zero exit even when grep
    # matched, so every rejection reported as an acceptance -- this
    # printed a confident "0 rejected" while a hand-run loop found
    # fourteen.
    out=$(zig cc -target "$TARGET" "$WORK/m.c" -o /dev/null "-Wl,$arg" 2>&1 || true)
    if printf '%s' "$out" | grep -q 'unsupported linker arg'; then
        printf 'REJECTED  -Wl,%s\n' "$arg"
        rejected=$((rejected + 1))
    else
        accepted=$((accepted + 1))
    fi
done

echo
echo "${rejected} rejected, ${accepted} accepted, of $((rejected + accepted)) tried"
echo
echo "Rejection is not permission to discard. Before filtering one in the"
echo "wrappers, establish that dropping it cannot change the output --"
echo "--wrap, --defsym, --dynamic-list, -Bsymbolic-functions and"
echo "--unresolved-symbols all alter what the link produces, and silently"
echo "dropping any of them would trade a loud failure for a wrong binary."
