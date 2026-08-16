#!/bin/sh
# Static Everywhere — minimal conformance audit for ELF binaries.
#
# Usage: ./audit.sh [-m] [-p S|H|M] <file> [max-glibc]
#          -m, --module        audit as a shared module (plugin, dlopen'd backend)
#          -p, --profile P     force S (static), H (hybrid) or M (module)
#        e.g. ./audit.sh ./myapp 2.28
#             ./audit.sh -m ./Plugins/foo.so
#
# Exit: 0 pass, 1 fail, 2 usage.  A stopgap until `onebin audit` exists.
# License: CC0.

set -eu

MODE=auto
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--module)  MODE=M; shift ;;
    -p|--profile) MODE="${2:?-p needs S, H or M}"; shift 2 ;;
    --)           shift; break ;;
    -*)           printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)            break ;;
  esac
done

BIN="${1:?usage: audit.sh [-m] [-p S|H|M] <file> [max-glibc]}"
MAX="${2:-2.28}"
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
info() { printf '  info  %s\n' "$*"; }

command -v readelf >/dev/null || { say "readelf not found (install binutils)"; exit 1; }

ALLOWED='ld-linux-x86-64.so.2|ld-linux-aarch64.so.1|libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1'

say "== $BIN =="

DYN=$(readelf -dW "$BIN" 2>/dev/null || true)
SEG=$(readelf -lW "$BIN" 2>/dev/null || true)
EHDR=$(readelf -hW "$BIN" 2>/dev/null || true)

NEEDED=$(printf '%s\n' "$DYN" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' || true)
SONAME=$(printf '%s\n' "$DYN" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p' || true)
HAS_INTERP=$(printf '%s\n' "$SEG" | grep -c 'INTERP' || true)
HAS_PIE=$(printf '%s\n' "$DYN" | grep 'FLAGS_1' | grep -c 'PIE' || true)
IS_DYN=$(printf '%s\n' "$EHDR" | grep -c 'Type:.*DYN' || true)

# ---------------------------------------------------------------- profile
# Same ladder as 01-SPEC-audit.md 7.3 and 02-REFERENCE-elf.md 3.  Getting this
# wrong is not academic: under the old rule (S when there is no DT_NEEDED, H
# otherwise) every dlopen'd plugin came out as a hybrid executable, because a
# CMake MODULE library has DT_NEEDED, no PT_INTERP, and -- the part that
# catches people -- no DT_SONAME either.
if [ "$MODE" = auto ]; then
  if [ "$HAS_INTERP" -gt 0 ]; then
    PROFILE=H
  elif [ "$HAS_PIE" -gt 0 ]; then
    PROFILE=S                       # linker marked it an executable: static-PIE
  elif [ "$IS_DYN" -gt 0 ] && { [ -n "$SONAME" ] || [ -n "$NEEDED" ]; }; then
    PROFILE=M
  elif printf '%s\n' "$EHDR" | grep -q 'Shared object file'; then
    PROFILE=M                       # binutils >= 2.35 tells us outright
  else
    PROFILE=S
    # A self-contained module is byte-identical to a static-PIE executable.
    # Say so rather than guessing silently.
    [ "$IS_DYN" -gt 0 ] && info "cannot tell a static-PIE from a self-contained module; assuming S (use -m to override)"
  fi
else
  PROFILE="$MODE"
fi

case "$PROFILE" in
  S) say "  profile: S -- fully static" ;;
  H) say "  profile: H -- hybrid, pinned libc baseline" ;;
  M) say "  profile: M -- shared module; executable-only checks skipped" ;;
  *) say "unknown profile: $PROFILE (want S, H or M)"; exit 2 ;;
esac

# ---------------------------------------------------------------- DT_NEEDED
# Applies to modules exactly as it does to executables: a plugin that drags in
# libstdc++.so.6 is as wrong as a program that does.
if [ -z "$NEEDED" ]; then
  ok "no DT_NEEDED"
else
  say "  DT_NEEDED:"
  for lib in $NEEDED; do
    if printf '%s' "$lib" | grep -Eq "^($ALLOWED)$"; then
      ok "  $lib"
    else
      bad "  $lib  -- not in the allowlist; link it statically or dlopen it"
    fi
  done
fi

[ -n "$SONAME" ] && info "SONAME: $SONAME" || true

# ------------------------------------------------------------ glibc baseline
if [ "$PROFILE" != S ]; then
  HIGH=$(readelf -W --dyn-syms "$BIN" 2>/dev/null \
         | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' \
         | sort -t. -k1,1n -k2,2n -u | tail -1 || true)
  if [ -z "$HIGH" ]; then
    ok "no versioned GLIBC symbols"
  elif [ "$(printf '%s\n%s\n' "$HIGH" "$MAX" | sort -t. -k1,1n -k2,2n | tail -1)" = "$MAX" ]; then
    ok "highest GLIBC symbol $HIGH <= baseline $MAX"
  else
    bad "highest GLIBC symbol $HIGH > baseline $MAX"
    readelf -W --dyn-syms "$BIN" | grep "GLIBC_$HIGH" | awk '{print "        " $8}' | sort -u | head -20
  fi
fi

# ------------------------------------------------------ executable-only checks
if [ "$PROFILE" = S ]; then
  if readelf -sW "$BIN" 2>/dev/null | grep -q '__libc_start_main'; then
    if readelf -sW "$BIN" 2>/dev/null | grep -q '__nss_\|_nss_files'; then
      bad "statically linked glibc detected -- getaddrinfo/NSS will break at runtime; use musl"
    fi
  fi
  # A module may dlopen whatever it likes.  A fully static binary may not:
  # dlopen is a stub in static musl.
  if readelf -sW "$BIN" 2>/dev/null | grep -qw 'dlopen'; then
    bad "dlopen referenced in a fully static binary -- it is a stub in static musl; use Profile H"
  fi
fi

if [ "$PROFILE" = H ] && [ "$HAS_INTERP" -eq 0 ]; then
  bad "no PT_INTERP -- you asked for hybrid and got something else"
fi

# ------------------------------------------------------------- RPATH/RUNPATH
RPATH=$(printf '%s\n' "$DYN" | grep -E 'RPATH|RUNPATH' || true)
if [ -z "$RPATH" ]; then
  ok "no RPATH/RUNPATH"
elif printf '%s' "$RPATH" | grep -q '\$ORIGIN'; then
  warn "RPATH is \$ORIGIN-relative: $RPATH"
else
  bad "absolute RPATH/RUNPATH leaks the build machine: $RPATH"
fi

# ------------------------------------------------------------------ hardening
printf '%s\n' "$SEG" | grep -q GNU_RELRO \
  && ok "RELRO present" || bad "no GNU_RELRO (add -Wl,-z,relro)"
printf '%s\n' "$DYN" | grep -q 'BIND_NOW\|NOW' \
  && ok "BIND_NOW set" || bad "no BIND_NOW (add -Wl,-z,now)"
if printf '%s\n' "$SEG" | grep GNU_STACK | grep -q 'RWE'; then
  bad "executable stack (add -Wl,-z,noexecstack)"
else
  ok "non-executable stack"
fi
if [ "$PROFILE" = M ]; then
  ok "position independent (a shared module always is)"
elif [ "$IS_DYN" -gt 0 ]; then
  ok "position independent"
else
  warn "not PIE (add -fPIE -pie, or -static-pie for Profile S)"
fi

# ------------------------------------------------------- build path hygiene
LEAK=$(strings -a "$BIN" 2>/dev/null | grep -E '^/(home|root|build|Users)/' | head -5 || true)
[ -z "$LEAK" ] && ok "no build-machine paths in .rodata" \
               || { warn "build paths leaked (use -ffile-prefix-map):"; printf '        %s\n' $LEAK; }

DISTROPATH=$(strings -a "$BIN" 2>/dev/null | grep -E '^/usr/lib/(x86_64-linux-gnu|aarch64-linux-gnu)/' | head -5 || true)
[ -n "$DISTROPATH" ] && { warn "hardcoded distro library paths:"; printf '        %s\n' $DISTROPATH; } || true

# -------------------------------------------------------------- host contract
say "  dlopen'd host contract found in strings:"
HOST=$(strings -a "$BIN" 2>/dev/null \
       | grep -E '^lib(GL|GLX|GLESv2|EGL|OpenGL|vulkan|cuda|nvidia-ml|OpenCL|va|vdpau|asound|pulse|pipewire-0\.3|jack|udev)\.so' \
       | sort -u || true)
[ -n "$HOST" ] && printf '        %s\n' $HOST || say "        (none)"

say ""
[ "$FAIL" = 0 ] && say "PASS -- Static Everywhere Level 1 (Profile $PROFILE)" \
                || say "FAIL -- see above"
exit "$FAIL"
