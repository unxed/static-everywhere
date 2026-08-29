#!/usr/bin/env bash
# Build GNOME Terminal under the Static Everywhere doctrine.
#
# STATUS: interface and plan only. This script renders the full build plan and
# refuses to execute it. That is deliberate and follows the precedent set by
# tools/build-far2l.sh (README "Status" note): the plan is reviewable, testable
# and quotable long before the build works, and a half-written builder that
# fails at minute ninety teaches less than a plan somebody can read in a
# minute. See 06-REFERENCE-gnome-terminal.md for what each step must do.
#
# The probe (tools/build-gt-probe.sh) is the part that works today, and it is
# what gates this: there is no reason to start a multi-hour Meson build of the
# GNOME stack while the questions the probe answers are still open.

set -uo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

SRC=""
OUT="${REPO_ROOT}/out/gnome-terminal"
BASELINE=2.28
PRINT_PLAN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --src)  SRC="$2"; shift 2 ;;
        --out)  OUT="$2"; shift 2 ;;
        --baseline) BASELINE="$2"; shift 2 ;;
        --print-plan) PRINT_PLAN=1; shift ;;
        --help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "build-gnome-terminal.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Order is the dependency order Meson needs, and each entry names the thing
# this project has already measured about it.
cat <<PLAN
# --- toolchain
${REPO_ROOT}/onebin/toolchain/zig-cc -target x86_64-linux-gnu.${BASELINE}   (Profile H)

# --- Layer 1, built static, in this order
glib          -Ddefault_library=static -Dlibmount=disabled
              # GIO module loading must be disabled at runtime, not here:
              # probe report I, D1 -- GIO_MODULE_DIR=/nonexistent drops the
              # host's four modules to zero mappings, at the cost of the
              # proxy resolver, the TLS backend and dconf, each of which has
              # to be bought back by linking its client statically.
pcre2         -Ddefault_library=static
freetype      -Ddefault_library=static
fontconfig    -Ddefault_library=static
              # reads the HOST's fonts at runtime: Layer 2, and the reason
              # gt-probe asserts non-zero pango ink extents.
harfbuzz      -Ddefault_library=static
cairo         -Ddefault_library=static
pango         -Ddefault_library=static
gdk-pixbuf    -Ddefault_library=static -Dbuiltin_loaders=all
              # builtin_loaders is what stops a host loader module being
              # dlopen'd; gt-probe proves it by encoding a real PNG rather
              # than by listing formats, because the format list comes from
              # the module cache and can lie.
gtk3          -Ddefault_library=static -Dprint_backends=none
libhandy      -Ddefault_library=static
vte           -Ddefault_library=static -Dgnutls=false -Dsystemd=false
gnome-terminal

# --- schemas: compiled in, not extracted
glib-compile-schemas over gnome-terminal's schemas including the two
relocatable ones (org.gnome.Terminal.Legacy.Profile/.Keybindings), then
either a private tmpfs in a user namespace or extraction to
\$XDG_RUNTIME_DIR -- probe report I, C3: the namespace path works
unprivileged but is disabled on some hardened kernels, so BOTH are needed.

# --- link
no -rdynamic. probe report I, A2: exporting our own symbols makes mesa's
libxml2/ICU bind to ours. GNOME Terminal has no plugin ABI and must not
export anything.

# --- app-id
org.gnome.Terminal must NOT be claimed by a bundled build, or the host's
running gnome-terminal-server answers instead and the user silently gets
theirs. probe report I, E1.

# --- verify
${REPO_ROOT}/tools/audit.sh ${OUT}/gnome-terminal ${BASELINE}
${OUT}/gt-probe --contract contrib/gnome-terminal/probe/host-contract.txt --strict
PLAN

if [ "$PRINT_PLAN" = 1 ]; then
    exit 0
fi

echo >&2
echo "build-gnome-terminal.sh: not implemented yet -- the plan above is the spec." >&2
echo "  Run tools/preflight-gnome-terminal.sh and tools/build-gt-probe.sh instead;" >&2
echo "  they answer the open questions this build depends on." >&2
[ -n "$SRC" ] && echo "  (--src ${SRC} was accepted and ignored)" >&2
exit 3
