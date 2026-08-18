# REFERENCE — far2l, the reference application

**Read this before touching anything related to far2l. Everything you need is in this file.**

The agent continuing this work has **no internet access** and cannot read far2l's
sources, its README, or its issue tracker. This document therefore restates every
fact about far2l that the work depends on. It was compiled on 2026-08-16 from
far2l's own `README.md`, its top-level `CMakeLists.txt`, its `HACKING.md`, and its
GitHub releases page. §11 records how to re-verify each fact when a network is
available; until then, **treat this file as the source of truth and do not guess
beyond it.**

---

## 1. Why far2l

The manifesto claims that any Linux application can ship as one binary if you sort
its dependencies into three layers. That claim is cheap while the only thing we
test it on is a 200 KB linter that we wrote ourselves. far2l is the counter-example
we go looking for on purpose:

| It has | Which stresses |
|---|---|
| Three completely different UI backends (terminal, wxWidgets, SDL) in one executable | Layer 3, and the "protocol first, `dlopen` only where physics demands it" rule |
| A **plugin ABI**: ~20 plugins that are `dlopen`'d and resolve symbols **exported by the main executable** | The "one file" claim, and Profile S's total absence of `dlopen` |
| A helper process (`far2l_ttyx.broker`) and two `argv[0]`-multiplexed personalities (`far2l_askpass`, `far2l_sudoapp`) | The assumption that an app is a single process |
| Host data it must read to look right: fonts via fontconfig, terminfo, locales, clipboard tools | Layer 2 |
| External programs it shells out to (`7z`, `xclip`, `sudo`, `adb`) | Layer 3 "by process", which the manifesto currently does not discuss |
| ~15 optional third-party libraries, several of them hostile to static linking | The library cheat sheet, honestly |
| A GPLv2 licence, a bundled non-free UnRAR, and an Apache-2.0 OpenSSL dependency | Manifesto §9 (licensing), which is the section most likely to be wrong |
| An existing musl build path, existing portable builds, existing OpenWrt and Termux builds | Our claim that this is a habit, not a law — somebody already did most of it |

It is also a **file manager**, i.e. exactly the kind of program a person wants to
scp onto a server that has a glibc from 2014 and no package manager they are
allowed to use. If Static Everywhere is right about anything, it is right about
far2l.

**Non-goal:** we are not forking far2l and we are not "fixing" it. Any change we
need must be small enough to be offered upstream as a patch. See §8.

---

## 2. Facts

| | |
|---|---|
| Upstream | `https://github.com/elfmz/far2l` — maintainer: elfmz |
| What it is | Linux/macOS/BSD fork of FAR Manager v2 (`http://farmanager.com/`) |
| Licence | **GNU GPL v2** (`LICENSE.txt` in its tree) |
| Language | C++17, some C99. `WinPort` is a Win32-API compatibility layer partly derived from WINE |
| Build system | CMake. Top-level `CMakeLists.txt` declares `cmake_minimum_required(VERSION 3.5.0)`; its README says ">= 3.2.2". Assume **3.5**. |
| Release tags | `v_<major>.<minor>.<patch>` — note the **underscore**: `v_2.8.0`, not `v2.8.0` |
| Latest release when this file was written | **`v_2.8.0`**, published 2026-03-23, commit `483dea0` |
| Release cadence | Roughly two per year (`v_2.6.0` 2024-02, `v_2.6.5` 2025-03, `v_2.7.0` 2025-10, `v_2.8.0` 2026-03) |
| Stability | Every release is labelled "BETA" by upstream; `master` is explicitly *unstable*. **The latest `v_*` tag is what "latest stable" means for far2l.** |
| Version source | `packaging/version` in the tree, cross-checked against `git describe --tag` (see §6.8) |

**Pin, don't float.** Our reference build pins `v_2.8.0` as the known-good tag and
takes a newer tag only after somebody has run the full matrix on it. The README
instructions show how to resolve the newest tag, because a user asked for "the
latest stable far2l"; our CI uses the pin.

---

## 2.5 What far2l actually is — read this before designing anything for it

**This section exists because the audit tool was designed, specified and
built before anyone read far2l's source properly.** The result was a
reference-application plan that was wrong in its premises, not merely
optimistic. Corrected here from the actual code at `v_2.8.0`.

far2l is not "a file manager with plugins". It is a **multi-process
system that launches, brokers and re-executes processes**, and that shape
is load-bearing in the core, not in optional subsystems:

| Behaviour | Where | Consequence |
|---|---|---|
| Runs commands through the system shell | `far2l/src/execute.cpp:208` — `execl("/bin/sh", "sh", "-c", ...)` | `/bin/sh` is a **hard runtime dependency**. The built-in terminal is not emulated; it shells out. |
| Allocates PTYs and forks | `utils/src/MakePTYAndFork.cpp`, `utils/src/ExecAsync.cpp` (`fork`+`execvp`), `utils/src/POpen.cpp` | Core, not optional. |
| Forks/execs a **separate broker binary** | `WinPort/src/Backend/TTY/TTYXGlue.cpp:153` — `execl(broker_path, ...)` | `far2l_ttyx.broker` is a second executable the first one must locate and launch. |
| **Re-executes itself under `sudo`** | `WinPort/src/sudo/sudo_client.cpp:161` — `execlp("sudo", "-n", "-A", "-k", g_sudo_app, ipc, ...)` | `g_sudo_app` is `far2l_sudoapp`, a **symlink to `bin/far2l`**; `SUDO_ASKPASS` is `far2l_askpass`, also a symlink to `bin/far2l`. far2l launches `sudo`, which launches far2l again in another mode, which talks back over IPC. `sudo` is a host dependency. |
| Shells out for clipboard and printing | `WinPort/src/Backend/ExtClipboardBackend.cpp` (`system`/`popen`), `TTY/TTYPrinterSupport.cpp` (`system`) | `xclip`/`wl-copy`/`lpr` etc. are host dependencies. |
| Forks/execs a notification script | `WinPort/src/Backend/NotifySh.cpp:43` | ditto. |
| **Resurrect**: survives an SSH disconnect and re-attaches on next launch | (feature-level; implied by the detach/reattach design) | Structurally requires a surviving process and attaching to it. |

Two consequences that invalidate specific earlier claims in this
document:

**1. `dlsym(RTLD_DEFAULT, ...)` is in the core and is not NULL-checked.**
`utils/src/InstallPath.cpp:47` resolves `GetPathTranslationPrefix` **out
of the main executable's own dynamic symbol table** and calls the result
immediately:

```c
static tGetPathTranslationPrefix pGetPathTranslationPrefix =
    (tGetPathTranslationPrefix)dlsym(RTLD_DEFAULT, "GetPathTranslationPrefix");
return TranslateInstallPathT(path, dir_from, dir_to, pGetPathTranslationPrefix());
```

`utils` is linked into everything. In a fully static binary there is no
dynamic symbol table, `dlsym` returns `NULL`, and the very next statement
calls it. So **Profile S far2l does not "fail an audit" — it segfaults at
startup**, the first time any install path is translated (which is during
startup, locating `share/far2l`). §6.1's original "no plugins and no GUI,
because Profile S has no dlopen" was not merely optimistic; it described
a build that cannot run at all.

**2. NSS is a core dependency, not an edge case.** `getpwuid` at
`utils/src/InMy.cpp:69` (locating the home directory, at startup),
`getpwuid`/`getpwnam`/`getgrnam` in `far2l/src/fileowner.cpp` (the panel's
owner/group columns — a defining file-manager feature), `getpwuid` in
`far2l/src/mix/CachedCreds.cpp`. Under musl there is no NSS at all, so on
any host using LDAP/AD/SSSD the owner column degrades to numeric IDs;
under static glibc this is precisely the `OB0034` case.

### The measurement error this exposes

The host contract, the allowlist, and `onebin`'s entire notion of
"dependencies" are about **shared libraries**. far2l's real host
dependencies are **executables**: `/bin/sh`, `sudo`, `xclip`/`wl-copy`,
its own broker, and its own binary re-invoked through `sudo`. A
statically linked far2l with an empty `DT_NEEDED` would score a perfect
Level 1 and still be unable to run a single command, copy to the
clipboard, or elevate privileges without a host that provides all of
those.

**"Zero dependencies" was being measured in the wrong units.** Passing
this project's own audit is necessary, not sufficient, and for a program
shaped like far2l it is not even close to sufficient. Any future
"conformance level" work has to account for the executables a program
requires, not only the libraries it links. That is a gap in
`01-SPEC-audit.md`, not a gap in far2l.

### What this means for the reference-application plan

- **Profile S is categorically wrong for far2l**, not merely difficult.
  Do not attempt `far2l-tiny` again in that form.
- **Profile H is the only viable target**, and even it needs the host
  contract extended to name `/bin/sh` and `sudo` explicitly.
- far2l remains a good reference application precisely *because* it broke
  these assumptions — but the sections written before this was understood
  (§6.1 especially) reflect the earlier misunderstanding and are corrected
  in place rather than quietly rewritten.

---

## 3. Architecture you must know

### 3.1 Process model

far2l is a **multi-call binary**. The installed tree contains symlinks pointing
back at the same executable, and it dispatches on `argv[0]`:

```
bin/far2l                     the executable
bin/far2ledit          -> far2l          editor mode
lib/far2l/far2l_askpass -> ../../bin/far2l   SSH/sudo password prompt
lib/far2l/far2l_sudoapp -> ../../bin/far2l   privilege elevation helper
```

This is good news: far2l already accepts that one file can be several programs.
When we need a helper that today is a separate ELF file, `argv[0]` dispatch is the
established local idiom — use it rather than inventing a new one.

`far2l_ttyx.broker` is **not** a symlink. It is a separate executable that links
`libX11`/`libXi` and is spawned as a child process purely so that the X11
dependency lives in a process the main binary can survive without. That is the
Layer-3 doctrine implemented by hand, three years before we wrote it down.

### 3.2 UI backends

Selected at runtime, with automatic downgrade **GUI ⇒ TTY|Xi ⇒ TTY|X ⇒ TTY** when
components or system libraries are missing.

| Backend | Artifact | Extra runtime deps | Forced by |
|---|---|---|---|
| **GUI\|WX** | `far2l_gui.so` (`dlopen`'d) | wxWidgets → GTK3 → the whole desktop stack | `far2l --notty` |
| **GUI\|SDL** *(experimental)* | `far2l_sdl.so` (`dlopen`'d) | SDL2, FreeType, HarfBuzz, Fontconfig | `far2l --SDL` |
| **TTY\|Xi** | `far2l_ttyx.broker` (child process) | `libX11`, `libXi` | `far2l --tty` |
| **TTY\|X** | same broker | `libX11` | `far2l --tty --nodetect=xi` |
| **TTY** | none — built into the executable | none | `far2l --tty --nodetect=x` |

Two observations that matter to us:

1. **The graphical backends are `dlopen`'d modules, not linked into the binary.**
   Upstream did this so that a terminal-only user does not drag in GTK. It means
   the "one file" story cannot be told by linking flags alone (§7.5).
2. **GUI|SDL's dependency set — SDL2 + FreeType + HarfBuzz + Fontconfig — says it
   rasterises text itself** instead of delegating to a toolkit. That makes it the
   ideal backend for us: every one of those four is statically linkable, and
   fontconfig reads the *host's* fonts, which is Layer 2 working exactly as
   advertised. **GUI|SDL is our recommended GUI configuration.** GUI|WX is kept
   in the matrix as the documented failure case (§7.4).

### 3.3 Plugin ABI — the part that will bite you

From far2l's `HACKING.md`, restated: *only the main executable links WinPort
statically; the executable also **exports** WinPort's functionality, so plugins use
it without carrying their own copy. A plugin binary must therefore not statically
link WinPort.*

Consequences, in order of how much trouble they cause:

- The far2l executable must be linked with an **exported dynamic symbol table**
  (`-rdynamic` / `-Wl,--export-dynamic`, or an explicit version script). Plugins
  have undefined symbols that only the executable can satisfy.
- Therefore **`-Wl,--exclude-libs,ALL` — which the manifesto's Quick Start
  recommends — breaks far2l's plugins.** It strips exactly the symbols the
  plugins need. This is a real finding, not a footnote: see §7.1.
- Plugins are ordinary `ET_DYN` shared objects with unusual names:
  `*.far-plug-wide` (UTF-16 plugin API) and `*.far-plug-mb` (multibyte API).
  They are loaded with `dlopen` through WinPort's `LoadLibraryEx` shim.
- Because they are built by CMake as *modules*, they generally carry **no
  `DT_SONAME`** — which breaks our auditor's shared-object detection. See §7.6.

### 3.4 Installed layout

```
<prefix>/bin/far2l                        the executable
<prefix>/bin/far2ledit                    symlink
<prefix>/lib/far2l/far2l_gui.so           WX backend        (if USEWX=yes)
<prefix>/lib/far2l/far2l_sdl.so           SDL backend       (if USESDL=yes)
<prefix>/lib/far2l/far2l_ttyx.broker      X11 helper        (if TTYX enabled)
<prefix>/lib/far2l/far2l_askpass          symlink to bin/far2l
<prefix>/lib/far2l/far2l_sudoapp          symlink to bin/far2l
<prefix>/lib/far2l/Plugins/<name>/plug/<name>.far-plug-{wide,mb}
<prefix>/share/far2l/                     .lng, .hlf, themes, colorer schemes, python plugins
```

Default `CMAKE_INSTALL_PREFIX` is `/usr` on Linux and `/usr/local` on macOS/BSD.

**A build tree is also a working tree.** After `cmake --build .`, far2l runs
directly from `_build/install/far2l` with everything beside it — the executable
locates its modules and data relative to itself, so both the flat `install/`
layout and the split `bin/` + `lib/far2l/` + `share/far2l/` layout work. That is
what makes a relocatable, `$ORIGIN`-relative bundle possible at all.

Per-user configuration lives in `$XDG_CONFIG_HOME/far2l` (default
`~/.config/far2l`) and is created on first run.

### 3.5 Host data far2l reads at runtime (Layer 2)

Fonts (via fontconfig, in the SDL and WX backends) · terminfo/`TERM` · locale and
charset environment · the X11 or Wayland display socket · `$XDG_CONFIG_HOME` ·
the clipboard, by whichever of four mechanisms is available (far2l extensions,
X11 selections, OSC 52, or an external tool).

### 3.6 External programs far2l executes (Layer 3, by process)

`7z`/`7za` (archives via multiarc and arclite) · `xclip`/`xsel` (clipboard in
plain TTY) · `sudo` (elevation, through `far2l_sudoapp`) · `adb` (ADB plugin) ·
the user's `$SHELL` (the command line is the point of a file manager).

**These do not go away when you link statically, and they should not.** A binary
that shells out to the host's `7z` is behaving correctly under the doctrine: it is
using a service, not an ABI. The manifesto does not currently say this; §5 of
`STATIC-EVERYWHERE.md` was amended to say it because of far2l.

---

## 4. Build system reference

### 4.1 Invocation

```sh
git clone --depth 1 --branch v_2.8.0 https://github.com/elfmz/far2l
cd far2l && mkdir -p _build && cd _build
cmake -DCMAKE_BUILD_TYPE=Release -DUSEWX=yes ..
cmake --build . -j"$(nproc)"
# result runs in place: ./install/far2l
```

Ninja works: add `-G Ninja`. `cmake --install .` installs. `cmake --build .
--target package` produces `.deb`/`.tar.gz` via CPack.

### 4.2 Options — complete list as of `v_2.8.0`

| Option | Default | Effect |
|---|---|---|
| `-DUSEWX` | `YES` | Build `far2l_gui.so` (wxWidgets). `no` drops the wxWidgets build dependency entirely. |
| `-DUSESDL` | `NO` | Build `far2l_sdl.so`. Combine with `-DUSEWX=NO` for SDL only. |
| `-DTTYX` | *(auto)* | X11 TTY extensions. Unset ⇒ built if `find_package(X11)` succeeds. `no` force-disables. |
| `-DTTYXI` | *(auto)* | The Xi part of the above. `no` disables only Xi. |
| `-DMUSL` | *(unset)* | Adds `-D__MUSL__` to C and C++ flags. **Set this for every musl build.** |
| `-DTAR_LIMITED_ARGS` | *(unset)* | Adds `-D__TAR_LIMITED_ARGS__`, for hosts with a busybox-class `tar`. |
| `-DICU_MODE` | `prebuilt` | `prebuilt` = hardcoded Unicode tables, **no ICU at build or run time** (use this). `build` = regenerate with the build host's libicu. `runtime` = `-DRUNTIME_ICU`, requires libicu on the target. |
| `-DUSEUCD` | `yes` | libuchardet charset autodetection. `no` removes the dependency. |
| `-DCOLORER` | `yes` | Colorer plugin; pulls libxml2. |
| `-DNETROCKS` | `yes` | Network plugin; pulls libssh, OpenSSL, libsmbclient, libnfs, neon, optionally aws-sdk-cpp. Each protocol degrades independently if its library is missing. |
| `-DMULTIARC` | `yes` | Archive plugin; uses libarchive if found. |
| `-DUNRAR` | `bundled` | `bundled` = vendored UnRAR sources, `lib` = libunrar, `no` = leave RAR to libarchive. **See §7.7.** |
| `-DPYTHON` | `no` | Python plugin subsystem; needs `python3-dev` + `python3-cffi`. **Leave off** — embedded CPython `dlopen`s native extension modules and drags a whole runtime. |
| `-DFAR2MACRO` | `ON` | Macro subsystem. |
| `-DLEGACY` | `YES` | `-DWINPORT_REGISTRY`, old settings migration. |
| `-DFARFTP` | `no` | Obsolete FTP plugin; forces `LEGACY=YES` when enabled. |
| `-DTESTING` | `NO` | Upstream's test hooks. |
| Per-plugin toggles | `yes` | `ADB ALIGN ARCLITE AUTOWRAP CALC COMPARE DRAWLINE EDITCASE EDITORCOMP EDSORT FILECASE HEXITOR IMAGEVIEWER INCSRCH INSIDE MEMO OPENWITH SIMPLEINDENT TMPPANEL TRUNCATE` — each `-DNAME=no` skips it. Note there is no `GITGUTTER` toggle in the top-level file. |

### 4.3 Flags far2l sets for itself

Know these, because several of them collide with ours:

```
-Wall -fPIC -Wno-unused-function -D_FILE_OFFSET_BITS=64
-ffunction-sections -fdata-sections            (non-Darwin)
-Wl,--gc-sections                              (non-Clang only!)
C++: -std=c++17, no GNU extensions             (CMAKE_CXX_EXTENSIONS OFF)
C:   -std=c99
Release: -O2
CMAKE_C_VISIBILITY_PRESET   hidden
CMAKE_CXX_VISIBILITY_PRESET hidden
```

Two traps:

- `-Wl,--gc-sections` is added **only when the compiler is not Clang**. `zig cc`
  identifies as Clang, so far2l will *not* add it for us and we must pass it in
  `CMAKE_EXE_LINKER_FLAGS` ourselves.
- Visibility is hidden by default, so the plugin exports come from explicit
  visibility attributes in WinPort's headers, not from the default. Do not
  "fix" this by making everything visible.

### 4.4 Output tree

`_build/install/` holds the runnable tree: `far2l`, `far2l_gui.so`,
`far2l_sdl.so`, `far2l_ttyx.broker`, `Plugins/*/plug/*.far-plug-*`, plus the data
files. **Everything under it is an audit target** — see §9.

---

## 5. Dependency table

"Verdict" is the Static Everywhere disposition, not far2l's opinion.

| Library | Needed for | Verdict for our build |
|---|---|---|
| wxWidgets 3.0/3.2 (`libwxgtk3.2-dev`) | GUI\|WX | ⚠️ static build works but inherits GTK. **Excluded from the Level-1 configurations**; kept as the documented failure case. |
| GTK3 (transitively) | GUI\|WX | ❌ unbundleable by design — GIO modules, pixbuf loaders, IM modules, print backends all `dlopen` from host paths. |
| SDL2 (`libsdl2-dev`) | GUI\|SDL | ✅✅ static (`-DSDL_STATIC=ON -DSDL_SHARED=OFF`). SDL `dlopen`s X11, Wayland, GL, ALSA, Pulse, PipeWire itself. |
| FreeType, HarfBuzz | GUI\|SDL text | ✅ static, trivial. |
| Fontconfig | GUI\|SDL font lookup | ✅ static — **but it reads the host's `/etc/fonts` and font directories.** Layer 1 code, Layer 2 data. Do not bundle fonts. |
| libX11, libXi | TTY\|X, TTY\|Xi | Only ever linked into `far2l_ttyx.broker`, never the main binary. Prefer XCB where a choice exists; here there is none. |
| libxml2 | Colorer plugin | ✅ static. `-DCOLORER=no` removes it. |
| libuchardet | charset autodetect | ✅ static, small. `-DUSEUCD=no` removes it. |
| libssh | NetRocks SFTP/SCP | ✅ static; needs a crypto backend. |
| OpenSSL | NetRocks FTPS, S3 | ✅ static (`no-shared no-dso`) — **but see the licence note in §7.7.** Never bundle CA certificates: read the host's. |
| libsmbclient (Samba) | NetRocks SMB | ❌ practically unbundleable: huge, `dlopen`s its own modules, drags Kerberos. **Disable it** — NetRocks degrades gracefully. |
| libnfs | NetRocks NFS | ✅ static, small. |
| neon | NetRocks WebDAV | ✅ static. |
| aws-sdk-cpp | NetRocks S3 | ❌ enormous C++ SDK. Leave it out. |
| libarchive | multiarc | ✅ static; configure it down to the formats you want. |
| libunrar / bundled UnRAR | RAR in multiarc | ⚠️ licence, see §7.7. |
| libicu | only with `ICU_MODE=build/runtime` | Avoided entirely by the default `ICU_MODE=prebuilt`. |
| python3 + cffi | Python plugins | ❌ for us. Embedded CPython requires `dlopen` for native extensions. |
| `7z` binary | archives at runtime | Layer 3 by process. Not a link-time dependency. Do not bundle it. |

**Build-host tools:** cmake ≥ 3.5, pkg-config, a C++17 compiler, git, and `m4`/`gawk`
for some generated sources.

---

## 6. Target configurations

Four builds. Each has a name used everywhere else in this repository.

### 6.1 `far2l-tiny` — Profile S, Level 1

Fully static musl, static-PIE, zero host dependencies, runs on `FROM scratch`.
**No plugins and no GUI**, because Profile S has no `dlopen` (§7.3).

> **Correction, from an actual build (`--fetch`'d, built to completion,
> audited for real).** This configuration as specified below does **not**
> achieve Profile S. The resulting binary contains musl's literal
> `"Dynamic loading not supported"` dlopen stub string regardless of every
> plugin/GUI flag being off, and `onebin audit` correctly FAILs it on
> `OB0033`. far2l calls `dlopen` from code no cmake flag disables — most
> likely WinPort's `LoadLibrary` shim and/or the `resurrect` feature
> (detach/reattach across an SSH disconnect, which structurally requires
> attaching to a running process). **Do not re-attempt this as a quick
> fix**; it needs either an upstream patch removing the call, or retargeting
> this configuration at Profile H and dropping the zero-findings claim.
> far2l's real Level-1 targets are `far2l-tty` and `far2l-sdl` below, where
> `dlopen` is expected and allowed by design.

```sh
cmake -DCMAKE_TOOLCHAIN_FILE=<repo>/onebin/toolchain/onebin-linux-static.cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DMUSL=1 -DUSEWX=no -DUSESDL=no -DTTYX=no -DTTYXI=no \
      -DUSEUCD=no -DCOLORER=no -DNETROCKS=no -DMULTIARC=no -DARCLITE=no \
      -DPYTHON=no -DUNRAR=no -DICU_MODE=prebuilt \
      -DADB=no -DALIGN=no -DAUTOWRAP=no -DCALC=no -DCOMPARE=no -DDRAWLINE=no \
      -DEDITCASE=no -DEDITORCOMP=no -DEDSORT=no -DFILECASE=no -DHEXITOR=no \
      -DIMAGEVIEWER=no -DINCSRCH=no -DINSIDE=no -DMEMO=no -DOPENWITH=no \
      -DSIMPLEINDENT=no -DTMPPANEL=no -DTRUNCATE=no ..
```

Audit target: one file, `onebin audit --profile static --level 1`, no findings.
This is the configuration to hand somebody who says "I just want a file manager on
this ancient server".

### 6.2 `far2l-tty` — Profile H, Level 1

glibc 2.28 baseline, everything except the six allowed sonames static, plugins
present as `$ORIGIN`-relative modules, TTY|X and TTY|Xi via the broker.

```sh
cmake -DCMAKE_TOOLCHAIN_FILE=<repo>/onebin/toolchain/onebin-linux-hybrid.cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DUSEWX=no -DUSESDL=no -DPYTHON=no -DUNRAR=no -DICU_MODE=prebuilt ..
```

### 6.3 `far2l-sdl` — Profile H, Level 1 — **the headline demo**

Everything in `far2l-tty`, plus a graphical backend whose only host dependencies
are the ones SDL `dlopen`s. A GUI application with no toolkit on the target
system, no `DT_NEEDED` beyond libc, and native-looking text because fontconfig
reads the host's fonts.

```sh
cmake -DCMAKE_TOOLCHAIN_FILE=<repo>/onebin/toolchain/onebin-linux-hybrid.cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DUSEWX=no -DUSESDL=YES -DPYTHON=no -DUNRAR=no -DICU_MODE=prebuilt ..
```

### 6.4 `far2l-wx` — Profile H, Level 0 only, **expected to fail Level 1**

Built solely so the failure is measured rather than asserted. Record its actual
`DT_NEEDED` list in the CI artifact; that list *is* the argument for the GTK row
in the cheat sheet.

```sh
cmake -DCMAKE_TOOLCHAIN_FILE=<repo>/onebin/toolchain/onebin-linux-hybrid.cmake \
      -DCMAKE_BUILD_TYPE=Release -DUSEWX=yes -DUSESDL=no ..
```

---

## 7. Collisions with the doctrine, and what we decided

This section is the actual deliverable of the far2l exercise. Each item is a place
where the manifesto met a real program and had to be more specific.

### 7.1 `--exclude-libs,ALL` breaks plugin ABIs

The Quick Start recommends `-Wl,--exclude-libs,ALL` for hygiene. far2l's plugins
resolve symbols **from the executable**. Excluding those symbols from the dynamic
symbol table produces a binary that starts, shows a panel, and fails on every
plugin with `undefined symbol: …`.

**Decision.** `--exclude-libs,ALL` is a *default*, not a rule. An application that
exports an ABI to its own modules must instead use an explicit version script
listing what it exports, and must pass `-Wl,--export-dynamic` or equivalent. The
audit must not treat a populated `.dynsym` in an executable as a defect. The
manifesto and the toolchain files were amended accordingly.

### 7.2 Hidden visibility is right, and it is not enough

far2l already sets `CMAKE_*_VISIBILITY_PRESET hidden`, so its export surface is
deliberate. Keep it. Do not add `-fvisibility=default` to "make plugins work" —
if a plugin fails to link, the missing symbol needs an export attribute upstream,
which is a patch worth sending.

### 7.3 Profile S means no plugins, and we say so out loud

Static musl has no dynamic loader; `dlopen` is a stub. There is no clever way
around this and we are not going to write an in-process ELF loader (`DESIGN-onebin.md`
§11 risk 1). Therefore Profile S far2l is the terminal-only, plugin-less
`far2l-tiny`, and that is a legitimate, useful product rather than a degraded one.

The alternative — statically linking the plugins into the executable and
registering them through a table — requires upstream changes to far2l's plugin
manager. **Do not attempt it in this milestone.** Record it as an upstream
proposal.

### 7.4 GTK is where the doctrine stops

`far2l-wx` will show a `DT_NEEDED` list dozens of entries long. That is not our
bug and not far2l's bug; it is the toolkit's architecture. The value of building
it is the artifact: a measured list beats an assertion in an argument with a
GTK developer.

### 7.5 "One file" vs. a binary plus modules

Profile H far2l is honestly *one executable and N modules*. Three ways to close
the gap, in increasing order of ambition:

1. **Ship a directory.** Executable plus `far2l.d/` beside it, `$ORIGIN`-relative
   `DT_RUNPATH`. Honest, boring, works today, and is what `far2l-tty` and
   `far2l-sdl` do for v0.1. The audit already permits `$ORIGIN`-relative
   `RUNPATH` (`OB0041`, warn).
2. **`onebin pack` + extract to a cache.** Append the modules to the executable;
   on first run, unpack them into `$XDG_CACHE_HOME/far2l/<build-id>/` and
   `dlopen` from there. One file for the user, a directory on disk. This is
   AppImage's idea without the FUSE mount. Planned for v0.4.
3. **`memfd_create` + `dlopen("/proc/self/fd/N")`.** No files on disk at all.
   Genuinely works on Linux with a dynamic glibc, and genuinely breaks under
   hardened kernels, some seccomp policies, SELinux `execmem` rules, and anything
   without `/proc`. **This is an open question, not a plan** — record it in
   `DESIGN-onebin.md` §11, do not build it on the strength of this paragraph.

### 7.6 far2l's modules break our shared-object detection

`01-SPEC-audit.md` §12 says a shared library is `ET_DYN` + `DT_SONAME` + no
`PT_INTERP`. CMake builds far2l's plugins and GUI backends as *module* libraries,
which typically get **no `DT_SONAME`**. Under the old rule every one of them
auto-detects as Profile H and earns a spurious `OB0036` ("no `PT_INTERP`") error.

**Decision.** The spec now has an explicit **Profile M (module)** with its own
auto-detection rule and finding IDs `OB0038`/`OB0039`. See `01-SPEC-audit.md`
§7.3 and §12, and `03-TESTPLAN.md` §4.3. This is the first bug far2l found in our
own work, before a single far2l object file was compiled.

### 7.7 Licensing — read this before shipping anything

far2l is **GPLv2** (v2 only, as far as its `LICENSE.txt` states). Three
consequences:

- **OpenSSL 3.x is Apache-2.0**, which is *not* GPLv2-compatible, and static
  linking gives you no "system library" exception. Either build NetRocks without
  OpenSSL, or use a GPL-compatible TLS stack, or don't redistribute that
  configuration. Our reference builds take the first option.
- **The bundled UnRAR sources are under the UnRAR licence**, which is not free
  software and is not GPL-compatible. Our builds pass `-DUNRAR=no`; RAR is then
  handled by libarchive where it can be.
- **Static linking does not change GPLv2's terms for far2l itself** — it is
  already copyleft, so shipping a static binary obliges us to offer the complete
  corresponding source, which we do by pinning an upstream tag and publishing the
  build script and the dependency manifest. That is a *feature* of the exercise:
  it forces the SBOM to be real.

Nothing here is legal advice; it is a list of things that must be checked by
somebody who is allowed to give it, before any binary is published.

### 7.8 Reproducibility: clone the tag exactly

far2l's CMake runs `git describe --tag`. If the result equals `v_${VERSION}` from
`packaging/version`, the version string is clean. Otherwise it **appends the
commit date and hash**, which makes two builds of the same source produce
different binaries and different strings in `.rodata`.

So: `git clone --depth 1 --branch v_2.8.0` (which does fetch that tag), never a
detached commit or a tarball without `.git`. Also pass `-ffile-prefix-map` so the
build directory does not end up in the binary and trip `OB0060`.

---

## 8. Patches to far2l: policy

Zero patches is the goal, because a reference build that needs a fork proves
nothing. If a patch is unavoidable:

- it lives in `contrib/far2l/patches/NNNN-short-name.patch`, in `git am` format;
- its commit message says what breaks without it and why it is not a far2l bug;
- it must be plausibly acceptable upstream — no vendoring, no build-system
  rewrites, no `#ifdef ONEBIN` scattered through the sources;
- `tools/build-far2l.sh` applies the directory in order and fails loudly if a
  patch does not apply, never with `--force` or a fuzz factor.

Anything that cannot meet that bar is an *upstream proposal*, recorded in
`contrib/far2l/UPSTREAM.md` as prose, not carried as a patch.

---

## 9. What `onebin audit` must say

The build script audits every artifact in `_build/install/`. Expected results:

| Artifact | Profile | Expected |
|---|---|---|
| `far2l` (`far2l-tiny`) | S | clean; `OB0011` info ("fully static") |
| `far2l` (`far2l-tty`, `far2l-sdl`) | H | only the six allowed sonames; `OB0041` warn for the `$ORIGIN` runpath; `OB0070` info for whatever SDL `dlopen`s |
| `far2l_sdl.so` | M | `OB0038` info; same soname allowlist; **no** `OB0036` |
| `far2l_gui.so` | M | in `far2l-wx` only: a long list of `OB0010` errors. Expected and recorded. |
| `far2l_ttyx.broker` | H | `libX11.so.6`, `libXi.so.6` — allowed **only** via an explicit `--allow`, and only for this artifact. Document the exception in the CI config so nobody quietly widens the global allowlist. |
| `*.far-plug-*` | M | `OB0038` info; clean otherwise |

The audit runs with `--level 1 --strict` for `far2l-tiny`, `far2l-tty` and
`far2l-sdl`, and with `--level 0` for `far2l-wx`.

---

## 10. `tools/build-far2l.sh` — required interface

Not yet written. This is the contract it must satisfy; the task is listed in
`00-AGENT-TASK.md`.

```
tools/build-far2l.sh --config tiny|tty|sdl|wx
                     [--src DIR]        default ./far2l-src
                     [--tag v_2.8.0]    what to check out if --src is absent
                     [--out DIR]        default ./out/far2l-<config>
                     [--jobs N]
                     [--deps-prefix DIR]  where static third-party libs live
                     [--no-fetch]       fail instead of touching the network
                     [--print-plan]     print every command and exit 0
                     [--audit-only]     audit an existing tree and exit
```

Hard requirements:

- **`--print-plan` must work with no network, no far2l checkout, and no
  compiler.** It is the only part of this script that can be tested offline, so
  it is the part that gets a golden-file test.
- `--no-fetch` is the default in CI. The script must never silently download.
- Every third-party dependency version is read from
  `contrib/far2l/deps.lock` — one `name version sha256 url` per line — never
  hardcoded in the script and never "latest".
- The script fails if `git describe --tag` in the source tree does not match a
  `v_*` tag (§7.8).
- After a successful build it runs the §9 audits and exits non-zero if any fail.
- It is POSIX `sh`, not bash, and it passes `shellcheck` cleanly.

---

## 11. Provenance, and how to re-verify

Every fact above came from one of these, on 2026-08-16. An agent with network
access should re-check the starred ones before a release; an agent without
network must not "update" them from memory.

| Fact | Source |
|---|---|
| Backends, dependency list, build commands, options | far2l `README.md` on `master` |
| Compiler flags, install rules, symlinks, option defaults, `MUSL`, `ICU_MODE` | far2l top-level `CMakeLists.txt` on `master` |
| Plugin ABI and the WinPort export rule | far2l `HACKING.md` |
| ★ Latest release `v_2.8.0`, 2026-03-23, commit `483dea0`, tag scheme | `https://github.com/elfmz/far2l/releases` |
| Prior evidence that this is feasible | third-party portable, OpenWrt (musl), Termux and Flatpak builds of far2l exist |

To resolve the newest tag without cloning:

```sh
git ls-remote --tags --refs https://github.com/elfmz/far2l 'refs/tags/v_*' \
  | awk -F/ '{print $NF}' | sort -V | tail -1
```

If that command returns something newer than `v_2.8.0`, **do not silently adopt
it**: build it, run the §9 audits, and only then move the pin in
`contrib/far2l/deps.lock` and in this file.

---

## 12. Prior art: `far2l-portable`, and what it proves about Profile D

There is already a project that ships far2l as one downloadable thing that runs
on any Linux: **[far2l-portable](https://github.com/spvkgn/far2l-portable)**
(`spvkgn/far2l-portable`, pinned for this document at `628b094`, 2026-07-15). It
is not a Static Everywhere build, and reading it is worth more than reading
another conforming project would be — because it solves the same user-facing
problem from the **opposite pole of the doctrine**, and in doing so it maps a
constraint our own Profile D proposal has to live with.

### 12.1 The approach: depend on everything, but bring it all with you

Static Everywhere says *link statically and depend on almost nothing*.
far2l-portable says *link normally and carry every single thing you depend on,
including the loader*. Both end at "one artifact, any Linux". `make_standalone.sh`
is the whole method, and it is short enough to summarise exactly:

1. Find every ELF in the install tree; `strip` each one.
2. `ldd $file | awk '/=>/ {print $3}' | xargs -I{} cp -vL {} lib/` — copy every
   resolved dependency, dereferenced, into a flat `lib/`.
3. `patchelf --set-rpath '$ORIGIN/<...>/lib'` — depth-aware, so a plugin three
   directories down gets `$ORIGIN/../../../lib`.
4. `patchelf --set-interpreter '<...>/lib/ld-musl-x86_64.so.1'` — **a relative
   `PT_INTERP`**. See §12.2; this is the interesting part.
5. Copy the loader itself (`ld-musl-*` or `ld-linux-*`) into `lib/`, then make a
   second pass over `lib/*` setting their RPATH to `$ORIGIN`.
6. On glibc, additionally copy `libnss*` by hand
   (`dpkg -L libc6 | grep libnss`) — the NSS problem `01-SPEC-audit.md §7.3`'s
   `OB0034` is about, solved by *shipping* NSS rather than by avoiding it.
7. `libtree -pvv` over everything into `libtree.txt`, shipped alongside as a
   dependency manifest.

Then `makeself --keep-umask --nomd5 --nocrc standalone far2l.run "FAR2L File
Manager" ./far2l` wraps the directory into a self-extracting archive.

### 12.2 The finding that matters: `PT_INTERP` does not expand `$ORIGIN`

`DT_RPATH`/`DT_RUNPATH` support `$ORIGIN` because the **dynamic linker** expands
them. `PT_INTERP` is opened by the **kernel**, in `load_elf_binary`, with a plain
`open_exec()` on the literal bytes. There is no expansion of anything.

So a binary that carries its own loader can only name it:

- by an **absolute path** — useless for something meant to be relocatable; or
- by a path **relative to the current working directory** — not to the binary.

far2l-portable takes the second, which is why the deliverable is a `.run` and not
a directory you can drop anywhere: makeself extracts to a temporary directory,
`chdir`s into it, and runs `./far2l` from there. `cd /tmp/far2l-dir && ./far2l`
works. `/tmp/far2l-dir/far2l` from any other directory **does not** — the kernel
looks for `lib/ld-musl-x86_64.so.1` relative to wherever you happen to be.

**This is the constraint our own Profile D proposal (`DESIGN-onebin.md §13`) has
to answer, and it is a point in that proposal's favour that it already does.**
§13 never sets `PT_INTERP` at all: a static stub locates its own payload and
`execve`s the loader *explicitly*, passing the real program as an argument. That
route has no CWD dependency and needs no wrapper script, at the cost of one extra
`execve` and the `memfd`/cache-directory machinery §13 describes. far2l-portable
is the empirical demonstration of why that extra machinery is worth its
complexity rather than gold-plating.

The third option — a shell or C wrapper that `exec`s `"$(dirname "$0")/lib/ld-musl-x86_64.so.1" "$(dirname "$0")/far2l" "$@"` —
is not what far2l-portable does, and is worth listing whenever this design comes
up again, because it is the cheapest of the three and costs only "the thing the
user runs is not the thing that is the program".

### 12.3 Numbers worth having

Both `.run` builds are **TTY-only** (`WXGUI: false`); the wx build is the
AppImage, which is out of scope here.

| Build | Container | Baseline | Architectures | Size |
|---|---|---|---|---|
| `far2l-<arch>-musl.run` | Alpine 3.18 | musl | x86_64, x86, aarch64, armhf, armv7 | ~20 MB |
| `far2l-<arch>-glibc.run` | Ubuntu 20.04 | glibc 2.31 | x86_64, aarch64 | ~35 MB |

That is a measured **~15 MB delta between musl and glibc for the same
application**, i.e. the glibc bundle is roughly 75% larger — and it is a
bring-everything comparison, so it measures the libc *stack* (libc, NSS modules,
and everything `ldd` dragged in), not the libc alone. It is the closest thing to
a controlled musl-vs-glibc size experiment this project has found in the wild,
and it belongs in any future discussion of D-musl versus D-glibc
(`DESIGN-onebin.md §13`'s table).

Note also which architectures each reaches: musl/Alpine covers five, glibc/Ubuntu
covers two. That asymmetry is about how easy each ecosystem makes cross-arch
containers, not about the doctrine, but it is real and it is the kind of thing
that decides what a small project actually ships.

### 12.4 How it would score under our own audit, and why that is not a criticism

Honestly: **Level 0**. Dozens of `DT_NEEDED` entries far outside the allowlist
(`OB0010`), an unrecognised interpreter path (`OB0037`), `$ORIGIN` RPATH on
every file (`OB0041`, warn — the one thing it does exactly the way we would).

And yet it demonstrably works, has users, and covers five architectures. The
lesson to take is not that our levels are wrong but that **they measure
conformance to this doctrine, not "does this work for people"** — a distinction
`CONFORMING.md` should keep making out loud. A bring-everything bundle and a
static binary are two different bets about where fragility lives: the bundle
moves every dependency into your artifact and accepts the size and the loader
problem; Static Everywhere removes the dependencies instead and accepts a
narrower host contract. far2l-portable is the strongest available argument that
the first bet is viable, and the reference build in this document should be
compared against it — size, startup time, architecture coverage — rather than
graded against it.

### 12.5 Provenance

Read from `spvkgn/far2l-portable` at `628b094`:
`make_standalone.sh`, `build_far2l.sh`, `README.md`,
`.github/workflows/build.yml`, `patches/series`. Re-verify with
`git -C <clone> show 628b094:<path>`.
