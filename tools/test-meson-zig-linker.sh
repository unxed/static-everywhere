#!/usr/bin/env bash
# Regression test for Meson's linker detection with the Zig compiler wrappers.
#
# Meson 1.3.2 identifies a compiler's linker from the first line printed by
# `-Wl,--version`. Zig 0.13 prints `zig ld ...`, which Meson does not recognise,
# even though Zig uses LLD underneath. The wrappers translate only that probe
# to Meson's LLD spelling; ordinary compile and link invocations still go
# through Zig unchanged.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
TOOLCHAIN="${REPO_ROOT}/onebin/toolchain"
NATIVE_FILE="${TOOLCHAIN}/onebin-linux-hybrid-meson.ini"
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${PROBE}/zig-global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-${PROBE}/zig-local}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

for tool in meson ninja zig; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '%s is required for this test\n' "$tool" >&2
        exit 1
    fi
done

export PATH="${TOOLCHAIN}:${PATH}"

for compiler in zig-cc zig-c++; do
    version=$(
        "${TOOLCHAIN}/${compiler}" \
            -Wl,--version -target x86_64-linux-gnu.2.28 \
            -static-libgcc -Wl,--gc-sections -Wl,-z,relro \
            -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,nodelete -pie -s \
            -L/usr/lib/x86_64-linux-gnu -L/usr/lib -L/lib/x86_64-linux-gnu
    )
    case "$version" in
        LLD|LLD\ *) ;;
        *)
            printf '%s did not expose an LLD linker signature: %s\n' \
                "$compiler" "$version" >&2
            exit 1
            ;;
    esac
done

mkdir -p "${PROBE}/src"
cat >"${PROBE}/src/meson.build" <<'MESON'
project('meson-zig-linker-probe', 'c')
executable('probe-c', 'probe.c')
MESON
printf '%s\n' 'int main(void) { return 0; }' >"${PROBE}/src/probe.c"

meson setup "${PROBE}/build" "${PROBE}/src" \
    --native-file "$NATIVE_FILE" --buildtype release \
    >"${PROBE}/configure.log" 2>&1 \
    || { sed 's/^/  /' "${PROBE}/configure.log" >&2; exit 1; }
meson compile -C "${PROBE}/build" \
    >"${PROBE}/build.log" 2>&1 \
    || { sed 's/^/  /' "${PROBE}/build.log" >&2; exit 1; }

test -x "${PROBE}/build/probe-c"
printf 'Meson Zig linker detection: pass\n'
