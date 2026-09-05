#!/usr/bin/env bash
# Every compiler and linker flag the kde-builder config hands to CMake
# must be one the zig wrappers accept -- checked by running them.
#
# Why this exists
# ---------------
# -Wl,--trace was added to CMAKE_MODULE_LINKER_FLAGS to name which archive
# satisfies a symbol. zig 0.13 rejects it ("unsupported linker arg"), and
# the first shared-object link in the graph, kiconthemes, died on it. The
# flag went in without ever passing through the wrapper. This extracts
# every flag-bearing CMAKE_*_FLAGS value from the rendered config and
# compiles and links a trivial program with it, so an unsupported flag
# fails here in a second instead of an hour into the build.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CC="${REPO_ROOT}/onebin/toolchain/zig-cc"
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

if ! command -v zig >/dev/null 2>&1; then printf 'zig unavailable; skipping\n'; exit 0; fi

PROBE=$(mktemp -d); trap 'rm -rf "$PROBE"' EXIT
printf 'int main(void){ return 0; }\n' >"$PROBE/m.c"
cp "$PROBE/m.c" "$PROBE/m.cpp"
printf 'int f(void){ return 1; }\n' >"$PROBE/s.c"

# Every -DCMAKE_<X>_FLAGS=<value> and -DCMAKE_<X>_LINKER_FLAGS=<value> in
# the template, with placeholders neutralised.
mapfile -t flagsets < <(
    sed -E 's/@[A-Z_]+@/x/g' "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" \
    | grep -oE -- '-DCMAKE_(C|CXX|EXE_LINKER|SHARED_LINKER|MODULE_LINKER)_FLAGS(_INIT)?=[^[:space:]]+' \
    | sort -u)

status=0
for entry in "${flagsets[@]}"; do
    var=${entry%%=*}; var=${var#-D}
    value=${entry#*=}
    # shellcheck disable=SC2206  # the value is a flag list by definition
    flags=($value)
    case "$var" in
        CMAKE_C_FLAGS*)      out=$("$CC"  -target x86_64-linux-gnu.2.28 "${flags[@]}" -c "$PROBE/m.c"   -o "$PROBE/o.o" 2>&1) || status=1 ;;
        CMAKE_CXX_FLAGS*)    out=$("$CXX" -target x86_64-linux-gnu.2.28 "${flags[@]}" -c "$PROBE/m.cpp" -o "$PROBE/o.o" 2>&1) || status=1 ;;
        CMAKE_EXE_LINKER_FLAGS*)
            out=$("$CC" -target x86_64-linux-gnu.2.28 "$PROBE/m.c" "${flags[@]}" -o "$PROBE/exe" 2>&1) || status=1 ;;
        CMAKE_SHARED_LINKER_FLAGS*|CMAKE_MODULE_LINKER_FLAGS*)
            out=$("$CC" -target x86_64-linux-gnu.2.28 -fPIC -shared "$PROBE/s.c" "${flags[@]}" -o "$PROBE/lib.so" 2>&1) || status=1 ;;
        *) continue ;;
    esac
    if printf '%s' "$out" | grep -qiE 'unsupported|unknown argument|error'; then
        printf '%s=%s is rejected by the wrapper:\n' "$var" "$value" >&2
        printf '%s\n' "$out" | head -3 | sed 's/^/  /' >&2
        status=1
    fi
done

[ "$status" -eq 0 ] && printf 'config flags: %s CMAKE_*_FLAGS values compile and link through the wrappers\n' "${#flagsets[@]}"
exit "$status"
