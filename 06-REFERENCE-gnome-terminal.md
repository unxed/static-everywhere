# REFERENCE — GNOME Terminal, the static GTK reference application

**Status: build recipe in progress.** The target is a real GNOME application
whose GTK3 user-interface stack is linked statically into the executable and
delivered as a relocatable bundle.

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
versions are interchangeable. A reproducible build must populate one staging
root from those pins and install both static archives and matching pkg-config
files below its logical `/usr` prefix.

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
the GTK code dynamic. Profile H's glibc runtime ABI is a separate, explicit
runtime boundary: a dependency graph may produce split glibc entries such as
`libresolv.so.2`, and those standard runtime SONAMEs are allowlisted by name.

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
and builds the Layer-1 archives in dependency order. `--prefix` is the physical
CI staging root; every dependency is configured with the runtime prefix `/usr`
and installed with `DESTDIR`. The recipe rewrites only the installed
pkg-config metadata to point at the staging tree for the next build. This
keeps CI paths out of compiled code while still forcing each consumer to use
the staged headers and archives. The hybrid boundary is
the Profile H glibc runtime ABI plus X11 client libraries and the Profile H
OpenGL/EGL runtime ABI. The GUI portion remains limited to X11/OpenGL/EGL;
the glibc entries are runtime ABI, not additional desktop libraries.
GTK's accessibility bridge is disabled for this PoC; D-Bus remains a protocol
used through static GLib rather than a host library dependency.

`tools/build-gnome-terminal.sh` accepts:

```sh
./tools/build-gnome-terminal.sh \
  --src ./gnome-terminal-src \
  --deps-prefix ./out/gnome-terminal/static-prefix \
  --out ./out/gnome-terminal
```

The dependency staging root must contain a `usr/` tree with static GTK3, GLib, Pango, Cairo, GdkPixbuf,
FreeType, HarfBuzz, Fontconfig, VTE and libhandy archives with their headers
and `.pc` files. `--print-plan` emits the complete Meson invocation without
requiring a source checkout, compiler or dependency prefix.

The generated Meson native file pins the glibc target, enables PIE, full RELRO,
BIND_NOW, a non-executable stack and static C/C++ runtimes. It also applies
source-prefix remapping to the source, build, output and dependency staging
trees; this includes paths reached through installed headers and generated
sources, not only the GNOME checkout. It keeps the dependency prefix ahead of
system library directories. The dependency producer applies the captured GLib
source patch before configuration; the consumer applies the captured GNOME
Terminal patches and links the shared glibc-baseline compatibility object into
the final targets. The first GNOME patch preserves GNOME Terminal's
`pk-gtk-module` block when GLib is an archive without relying on an unsupported
linker interposition flag. The second is captured from the pinned GNOME
checkout and redirects every GNOME-owned `TERM_*` install-path consumer below
the runtime bundle when `GNOME_TERMINAL_PORTABLE_ROOT` is set. Together they
cover both the known static-linking issue and the class of relocatable-resource
path failures.

The libhandy recipe also applies a captured source diff that makes its
GResource generation manual-registerable and calls that registration from
`hdy_init()`. This is required for any archive-linked library whose embedded
resources are otherwise reachable only through a constructor in an object the
static linker is free to discard. The smoke test therefore exercises the
resource-backed libhandy theme during normal portable startup, not merely the
link and ELF checks.

## 5. Verification

After the build, the script exports both the server and client ELF files and
runs the static verifier on each:

```sh
./tools/verify-gnome-terminal-static.sh ./out/gnome-terminal/gnome-terminal-server
./tools/verify-gnome-terminal-static.sh ./out/gnome-terminal/gnome-terminal-client
```

The verifier requires a Profile H `PT_INTERP`, hardening, no RPATH/RUNPATH and
no dynamic GTK/UI-stack SONAMEs. A passing plan check is useful before a
multi-hour build; only a passing artifact check proves the link boundary.
The strict audit also rejects embedded absolute CI staging paths; this is why
the dependency producer separates logical `/usr` installation from physical
`DESTDIR` storage instead of adding an audit waiver.

The final artifact is not an install image. It is an unpack-and-run bundle:

```
package/
  gnome-terminal                       # supported entrypoint
  usr/bin/gnome-terminal                # symlink to ../../gnome-terminal
  usr/bin/gnome-terminal.bin            # actual client ELF
  usr/libexec/gnome-terminal-server     # actual server ELF
  usr/libexec/gnome-terminal-preferences
  usr/lib/gnome-terminal/gschemas.compiled
  usr/share/...
```

The logical `/usr` prefix is retained only while compiling and inside the
bundle layout. The tracked `gnome-terminal` entrypoint derives its own bundle
directory, sets the relocation root and bundled schema/data paths, clears host
GTK/GIO module overrides, then starts the server directly. It passes both
programs the bundle-only D-Bus application ID
`org.gnome.Terminal.StaticEverywhere`. The standard service and systemd files
are deliberately omitted from the bundle because their upstream absolute
`/usr` commands cannot describe a relocatable tree.

The hosted smoke test runs this entrypoint from the unpacked `package`
directory under Xvfb and a session D-Bus. It never copies files into `/usr` and
does not set the relocation variables itself. During the live run it reads the
PID owning `org.gnome.Terminal.StaticEverywhere`, resolves `/proc/<PID>/exe`,
and requires the exact path `package/usr/libexec/gnome-terminal-server`. This
distinguishes the bundle server from the system `org.gnome.Terminal` service;
matching version text alone is insufficient because the pinned build is also
version 3.52.0.
