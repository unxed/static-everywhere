#!/bin/sh
# Static Everywhere — minimal conformance audit for ELF binaries.
# Usage: ./audit.sh <binary> [max-glibc]        e.g. ./audit.sh ./myapp 2.28
# Exit: 0 pass, 1 fail.  A stopgap until `onebin audit` exists.
# License: CC0.

set -eu

BIN="${1:?usage: audit.sh <binary> [max-glibc]}"
MAX="${2:-2.28}"
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }

command -v readelf >/dev/null || { say "readelf not found (install binutils)"; exit 1; }

ALLOWED='ld-linux-x86-64.so.2|ld-linux-aarch64.so.1|libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1'

say "== $BIN =="

# ---------------------------------------------------------------- DT_NEEDED
NEEDED=$(readelf -dW "$BIN" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' || true)
if [ -z "$NEEDED" ]; then
  ok "no DT_NEEDED — fully static (Profile S)"
  PROFILE=S
else
  PROFILE=H
  say "  DT_NEEDED:"
  for lib in $NEEDED; do
    if printf '%s' "$lib" | grep -Eq "^($ALLOWED)$"; then
      ok "  $lib"
    else
      bad "  $lib  — not in the allowlist; link it statically or dlopen it"
    fi
  done
fi

# ------------------------------------------------------------ glibc baseline
if [ "$PROFILE" = H ]; then
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

# --------------------------------------------------------- static glibc trap
if [ "$PROFILE" = S ] && readelf -sW "$BIN" 2>/dev/null | grep -q '__libc_start_main'; then
  if readelf -sW "$BIN" 2>/dev/null | grep -q '__nss_\|_nss_files'; then
    bad "statically linked glibc detected — getaddrinfo/NSS will break at runtime; use musl"
  fi
fi

# ----------------------------------------------------------- dlopen in Prof.S
if [ "$PROFILE" = S ] && readelf -sW "$BIN" 2>/dev/null | grep -qw 'dlopen'; then
  bad "dlopen referenced in a fully static binary — it is a stub in static musl; use Profile H"
fi

# ------------------------------------------------------------- RPATH/RUNPATH
RPATH=$(readelf -dW "$BIN" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)
if [ -z "$RPATH" ]; then
  ok "no RPATH/RUNPATH"
elif printf '%s' "$RPATH" | grep -q '\$ORIGIN'; then
  warn "RPATH is \$ORIGIN-relative: $RPATH"
else
  bad "absolute RPATH/RUNPATH leaks the build machine: $RPATH"
fi

# ------------------------------------------------------------------ hardening
readelf -lW "$BIN" 2>/dev/null | grep -q GNU_RELRO \
  && ok "RELRO present" || bad "no GNU_RELRO (add -Wl,-z,relro)"
readelf -dW "$BIN" 2>/dev/null | grep -q 'BIND_NOW\|NOW' \
  && ok "BIND_NOW set" || bad "no BIND_NOW (add -Wl,-z,now)"
if readelf -lW "$BIN" 2>/dev/null | grep GNU_STACK | grep -q 'RWE'; then
  bad "executable stack (add -Wl,-z,noexecstack)"
else
  ok "non-executable stack"
fi
readelf -hW "$BIN" 2>/dev/null | grep -q 'Type:.*DYN' \
  && ok "position independent" || warn "not PIE (add -fPIE -pie, or -static-pie for Profile S)"

# ------------------------------------------------------- build path hygiene
LEAK=$(strings -a "$BIN" 2>/dev/null | grep -E '^/(home|root|build|Users)/' | head -5 || true)
[ -z "$LEAK" ] && ok "no build-machine paths in .rodata" \
               || { warn "build paths leaked (use -ffile-prefix-map):"; printf '        %s\n' $LEAK; }

DISTROPATH=$(strings -a "$BIN" 2>/dev/null | grep -E '^/usr/lib/(x86_64-linux-gnu|aarch64-linux-gnu)/' | head -5 || true)
[ -n "$DISTROPATH" ] && { warn "hardcoded distro library paths:"; printf '        %s\n' $DISTROPATH; }

# -------------------------------------------------------------- host contract
say "  dlopen'd host contract found in strings:"
HOST=$(strings -a "$BIN" 2>/dev/null \
       | grep -E '^lib(GL|GLX|GLESv2|EGL|OpenGL|vulkan|cuda|nvidia-ml|OpenCL|va|vdpau|asound|pulse|pipewire-0\.3|jack|udev)\.so' \
       | sort -u || true)
[ -n "$HOST" ] && printf '        %s\n' $HOST || say "        (none)"

say ""
[ "$FAIL" = 0 ] && say "PASS — Static Everywhere Level 1 (Profile $PROFILE)" \
                || say "FAIL — see above"
exit "$FAIL"
