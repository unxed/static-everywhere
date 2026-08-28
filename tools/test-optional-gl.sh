#!/usr/bin/env bash
# Regression test: libGL must be optional, and its absence must select
# software rendering.
#
# What this pins, and why each half would otherwise rot silently:
#
#   1. The forwarder removes libGL from DT_NEEDED. Without this the
#      binary does not start at all where GL is missing -- the loader
#      resolves DT_NEEDED before main(), so no fallback of ours can run.
#   2. It still forwards correctly when GL IS present, for signatures a
#      C wrapper could not be written for without a prototype table:
#      float arguments, pointer returns, GLX entry points.
#   3. With GL absent, the startup policy sets QT_QUICK_BACKEND=software
#      and QT_XCB_GL_INTEGRATION=none -- and with GL present it sets
#      neither, because forcing software on a capable machine would be a
#      silent performance regression.
#   4. It never overrides a choice already made. The f4 tests set
#      QT_QUICK_BACKEND themselves.
#
# The absent-GL path cannot be exercised on a machine that has GL, so the
# forwarder and the policy both honour SE_FORWARD_SE_GL_SONAME. Without
# that hook half of this file would be untestable in CI, which is the
# same as untested.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

ZIGCC="${REPO_ROOT}/onebin/toolchain/zig-cc"
LIBGL=/usr/lib/x86_64-linux-gnu/libGL.so.1

if ! command -v zig >/dev/null 2>&1; then
    printf 'zig not on PATH; skipping\n'
    exit 0
fi
if [ ! -e "$LIBGL" ]; then
    printf 'libGL not installed; skipping\n'
    exit 0
fi

"${SCRIPT_DIR}/gen-optional-lib-forwarder.sh" libGL.so.1 se_gl "$LIBGL" \
    "$PROBE/fwd.c" >"$PROBE/gen.log"

cat >"$PROBE/main.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
extern void glColor4f(float, float, float, float);
extern const unsigned char *glGetString(unsigned);
extern void *glXGetProcAddress(const unsigned char *);
int se_gl_available(void);
int main(void)
{
    /* Signatures a prototype-free C wrapper could not have forwarded. */
    glColor4f(1.0f, 0.5f, 0.25f, 1.0f);
    (void)glGetString(0x1F00);
    void *p = glXGetProcAddress((const unsigned char *)"glClear");
    const char *backend = getenv("QT_QUICK_BACKEND");
    const char *xcbgl = getenv("QT_XCB_GL_INTEGRATION");
    printf("available=%d proc=%d backend=%s xcbgl=%s\n",
           se_gl_available(), p != 0,
           backend ? backend : "(unset)", xcbgl ? xcbgl : "(unset)");
    return 0;
}
EOF

"$ZIGCC" -target x86_64-linux-gnu.2.27 -O2 -pie \
    "$PROBE/main.c" "$PROBE/fwd.c" \
    "${REPO_ROOT}/contrib/f4-qt/compat/render-backend-fallback.c" \
    -o "$PROBE/app" 2>"$PROBE/link.log"

needed=$(readelf -d "$PROBE/app" 2>/dev/null | grep -oE '\[lib[^]]*\]' | tr -d '[]' | tr '\n' ' ')
case "$needed" in
    *libGL*)
        printf 'libGL is still a load-time dependency: %s\n' "$needed" >&2
        exit 1
        ;;
esac

# Negative control: without the forwarder the probe MUST depend on libGL,
# or the check above proves nothing. Its own source, because the main
# probe also calls se_gl_available(), which only the forwarder defines.
cat >"$PROBE/control.c" <<'EOF'
extern void glColor4f(float, float, float, float);
int main(void) { glColor4f(1.0f, 0.5f, 0.25f, 1.0f); return 0; }
EOF
"$ZIGCC" -target x86_64-linux-gnu.2.27 -O2 -pie \
    "$PROBE/control.c" -lGL -o "$PROBE/app_plain" 2>>"$PROBE/link.log"
plain=$(readelf -d "$PROBE/app_plain" 2>/dev/null | grep -oE '\[lib[^]]*\]' | tr -d '[]' | tr '\n' ' ')
case "$plain" in
    *libGL*) ;;
    *)
        printf 'the control build did not depend on libGL, so the probe proves nothing\n' >&2
        exit 1
        ;;
esac

with_gl=$("$PROBE/app")
case "$with_gl" in
    *"available=1"*) ;;
    *) printf 'GL was not resolved on a host that has it: %s\n' "$with_gl" >&2; exit 1 ;;
esac
case "$with_gl" in
    *"proc=1"*) ;;
    *) printf 'a GLX entry point did not forward: %s\n' "$with_gl" >&2; exit 1 ;;
esac
case "$with_gl" in
    *"backend=(unset)"*) ;;
    *) printf 'software rendering was forced on a GL-capable host: %s\n' "$with_gl" >&2; exit 1 ;;
esac

without_gl=$(SE_FORWARD_SE_GL_SONAME=libGL-absent.so.999 "$PROBE/app")
case "$without_gl" in
    *"available=0"*) ;;
    *) printf 'the absent-GL path was not taken: %s\n' "$without_gl" >&2; exit 1 ;;
esac
case "$without_gl" in
    *"backend=software"*) ;;
    *) printf 'software rendering was not selected without GL: %s\n' "$without_gl" >&2; exit 1 ;;
esac
case "$without_gl" in
    *"xcbgl=none"*) ;;
    *) printf 'the xcb GL integration was not disabled: %s\n' "$without_gl" >&2; exit 1 ;;
esac

# A choice already made is never overridden.
chosen=$(SE_FORWARD_SE_GL_SONAME=libGL-absent.so.999 QT_QUICK_BACKEND=rhi "$PROBE/app")
case "$chosen" in
    *"backend=rhi"*) ;;
    *) printf 'an explicit backend choice was overridden: %s\n' "$chosen" >&2; exit 1 ;;
esac

printf 'optional GL: not a load-time dependency, forwards when present, software when absent\n'
