#!/usr/bin/env bash
# Regression test: a goffi-based Go binary, built the way the plan builds
# f4, must be a hardened Profile H binary that passes a strict audit.
#
# Why the flags are what they are
# -------------------------------
# f4 reaches system libraries through goffi, which is built WITHOUT cgo
# and uses //go:cgo_import_dynamic to bind libc at load time. That
# directive makes the Go linker emit PT_INTERP and DT_NEEDED even under
# CGO_ENABLED=0, so the binary is dynamic by construction -- Profile H,
# not S, static in everything but the C runtime, with no glibc version
# requirement.
#
# A dynamic binary must carry RELRO and BIND_NOW or the audit fails
# OB0050/OB0051, both ERROR. External linking would provide them but
# needs cgo, which f4 avoids on purpose. Go's internal linker supplies
# both: -buildmode=pie emits PT_GNU_RELRO (and PIE, clearing OB0032),
# and -ldflags=-bindnow sets DT_BIND_NOW / DF_1_NOW.
#
# This test builds exactly that shape and asserts the ELF facts and a
# clean strict Profile H audit. It skips only if the Go toolchain or
# network to fetch goffi is unavailable -- it does not silently pass.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
ONEBIN="${REPO_ROOT}/onebin/build/onebin"

if ! command -v go >/dev/null 2>&1; then
    printf 'go toolchain unavailable; skipping\n'
    exit 0
fi
if [ ! -x "$ONEBIN" ]; then
    printf 'onebin not built; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
export GOPATH="$PROBE/gopath" GOCACHE="$PROBE/gocache" GOFLAGS=-mod=mod

cat >"$PROBE/go.mod" <<'EOF'
module goffiprobe
go 1.27
require github.com/go-webgpu/goffi v0.6.3
EOF
cat >"$PROBE/main.go" <<'EOF'
package main

import (
	"fmt"
	"github.com/go-webgpu/goffi/ffi"
)

// Exercise goffi's dynamic-loading path so the cgo_import_dynamic
// directive is actually pulled in, exactly as f4 does.
func main() {
	h, err := ffi.LoadLibrary("libc.so.6")
	if err != nil {
		panic(err)
	}
	defer ffi.FreeLibrary(h)
	if _, err := ffi.GetSymbol(h, "strlen"); err != nil {
		panic(err)
	}
	fmt.Println("ok")
}
EOF

if ! ( cd "$PROBE" && go mod tidy ) >"$PROBE/tidy.log" 2>&1; then
    printf 'could not fetch goffi (no network?); skipping\n'
    exit 0
fi

# The plan's flags, verbatim in spirit: no cgo, PIE for RELRO, -bindnow
# for BIND_NOW.
if ! ( cd "$PROBE" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        go build -trimpath -buildmode=pie -ldflags='-s -w -bindnow' \
        -o "$PROBE/bin" . ) >"$PROBE/build.log" 2>&1; then
    printf 'the goffi probe failed to build:\n' >&2
    sed 's/^/  /' "$PROBE/build.log" >&2
    exit 1
fi

relro=$(readelf -l "$PROBE/bin" 2>/dev/null | grep -c GNU_RELRO || true)
bindnow=$(readelf -d "$PROBE/bin" 2>/dev/null | grep -cE 'BIND_NOW|FLAGS_1.*NOW' || true)
[ "$relro" -ge 1 ] || { printf 'no RELRO despite -buildmode=pie\n' >&2; exit 1; }
[ "$bindnow" -ge 1 ] || { printf 'no BIND_NOW despite -ldflags=-bindnow\n' >&2; exit 1; }

# The whole point: it audits clean as Profile H with the C-runtime
# contract, under --strict, with zero findings.
audit=$("$ONEBIN" audit --profile hybrid --glibc-max 2.27 \
        --allow libc.so.6 --allow libdl.so.2 --allow libpthread.so.0 \
        --level 1 --strict "$PROBE/bin" 2>&1 || true)
case "$audit" in
    *"PASS  Level 1"*) ;;
    *)
        printf 'the hardened goffi binary did not pass a strict Profile H audit:\n' >&2
        printf '%s\n' "$audit" | sed 's/^/  /' >&2
        exit 1
        ;;
esac

# Negative control: WITHOUT the hardening flags it must fail, or the
# assertions above prove nothing about the flags.
if ( cd "$PROBE" && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
        -o "$PROBE/plain" . ) >/dev/null 2>&1; then
    plain=$("$ONEBIN" audit --profile hybrid --glibc-max 2.27 \
            --allow libc.so.6 --allow libdl.so.2 --allow libpthread.so.0 \
            --level 1 --strict "$PROBE/plain" 2>&1 || true)
    case "$plain" in
        *"OB0051"*) ;;  # expected: no BIND_NOW without the flag
        *)
            printf 'the un-hardened control unexpectedly passed; the flags prove nothing\n' >&2
            exit 1
            ;;
    esac
fi

# The assertions above prove the FLAGS work. They say nothing about
# whether the plan actually passes them -- and that gap is not
# hypothetical: the flags were once lost from the build line while this
# test stayed green, so CI shipped an ET_EXEC binary with no RELRO and no
# BIND_NOW and the audit failed two errors that the preflight had just
# declared fine. Assert against the real plan line too.
BUILD_LINE=$(grep -E 'plan_step .*go build .*f4_embedded_qt_host' \
             "${REPO_ROOT}/tools/build-f4-qt.sh" || true)
if [ -z "$BUILD_LINE" ]; then
    printf 'could not find the f4 go build step in the plan\n' >&2
    exit 1
fi
case "$BUILD_LINE" in
    *-buildmode=pie*) ;;
    *) printf 'the plan builds f4 without -buildmode=pie: no RELRO, no ASLR\n' >&2
       printf '  %s\n' "$BUILD_LINE" >&2; exit 1 ;;
esac
case "$BUILD_LINE" in
    *-bindnow*) ;;
    *) printf 'the plan builds f4 without -bindnow: OB0051 will fail\n' >&2
       printf '  %s\n' "$BUILD_LINE" >&2; exit 1 ;;
esac

printf 'goffi f4 build: PIE+bindnow gives RELRO and BIND_NOW, strict Profile H passes\n'
