# REFERENCE — GNOME Terminal, the static GTK reference application

**Status: build recipe in progress.** The target is a real GNOME application
whose GTK3 user-interface stack is linked statically into the executable.

## 1. Why GNOME Terminal

GNOME Terminal is a useful reference target because it is a substantial GTK
application rather than a toy: it exercises VTE, a PTY, GSettings schemas,
session D-Bus and the font/rendering stack. The recipe therefore tests whether
the Static Everywhere rules work for a desktop application without weakening
the Layer 1 rule for code.

## 2. Pinned target

The initial target is GNOME Terminal 3.52.0, the version recorded in
`contrib/gnome-terminal/deps.lock`.

| Component | Version or role |
|---|---|
| GNOME Terminal | 3.52.0 |
| GTK | 3.24 |
| libhandy | 1.8.3 |
| VTE | 0.76.0 |
| Build system | Meson |
| Binary profile | H, glibc baseline 2.28 (`gnome-terminal-server`) |

The lock file is a source inventory, not a claim that the newest dependency
versions are interchangeable. A reproducible build must populate one prefix
from those pins and install both static archives and matching pkg-config files.

## 3. Static boundary

The following code is built into the executable and must not occur in its
`DT_NEEDED` list:

- GTK3, GLib/GObject/GIO and libhandy;
- VTE, Pango, Cairo and GdkPixbuf;
- FreeType, HarfBuzz, Fontconfig, PCRE2 and their image/text dependencies.

GdkPixbuf loaders are built in, and GTK print backends are selected explicitly
when the dependency prefix is produced. The final link uses `--prefer-static`,
`-Ddefault_library=static` and `pkg-config` data from that prefix before any
system search path. `tools/verify-gnome-terminal-static.sh` rejects a toolkit
SONAME if one slips through.

The display server, GPU driver, fonts, schemas and session services are runtime
inputs by design. They are data, protocols or services, not a reason to make
the GTK code dynamic.

The pinned source also has a small, separate build-time host contract. Its
`meson.build` needs the `gsettings-desktop-schemas` pkg-config metadata, and
`data/meson.build` uses `i18n.itstool_join`; the workflow supplies these as
`gsettings-desktop-schemas-dev` and `itstool`. This is build metadata/tooling
and desktop data only. GLib generators and `gdbus-codegen` come from the
static prefix, and no host GTK/UI library is added by this contract.

## 4. Build interface

First produce the prefix from the commit pins:

```sh
./tools/build-gnome-terminal-deps.sh \
  --prefix ./out/gnome-terminal/static-prefix \
  --work ./out/gnome-terminal/deps-work
```

The producer verifies every source checkout against `contrib/gnome-terminal/deps.lock`
and builds the Layer-1 archives in dependency order. The hybrid boundary is
limited to X11 client libraries and the Profile H OpenGL/EGL runtime ABI.
GTK's accessibility bridge is disabled for this PoC; D-Bus remains a protocol
used through static GLib rather than a host library dependency.

`tools/build-gnome-terminal.sh` accepts:

```sh
./tools/build-gnome-terminal.sh \
  --src ./gnome-terminal-src \
  --deps-prefix ./out/gnome-terminal/static-prefix \
  --out ./out/gnome-terminal
```

The dependency prefix must contain static GTK3, GLib, Pango, Cairo, GdkPixbuf,
FreeType, HarfBuzz, Fontconfig, VTE and libhandy archives with their headers
and `.pc` files. `--print-plan` emits the complete Meson invocation without
requiring a source checkout, compiler or dependency prefix.

The generated Meson native file pins the glibc target, enables PIE, full RELRO,
BIND_NOW, a non-executable stack and static C/C++ runtimes. It also applies
source-prefix remapping and keeps the dependency prefix ahead of system
library directories.

## 5. Verification

After installation the script copies `gnome-terminal-server` to the requested output
path and runs:

```sh
./tools/verify-gnome-terminal-static.sh ./out/gnome-terminal/gnome-terminal-server
```

The verifier requires a Profile H `PT_INTERP`, hardening, no RPATH/RUNPATH and
no dynamic GTK/UI-stack SONAMEs. A passing plan check is useful before a
multi-hour build; only a passing artifact check proves the link boundary.
