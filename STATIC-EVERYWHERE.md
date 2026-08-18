# Static Everywhere

### One binary. Any Linux. No containers.

*A manifesto for C and C++ developers who are tired of shipping their software five times and still getting it wrong.*

**Status:** draft 0.1 — open for signatures, corrections and heresy.
**License:** CC0. Copy it, fork it, translate it, quote it in your README.

---

## The short version

If you only read one section, read this one.

1. **The unit of distribution is one file.** Not a package. Not an image. Not a runtime. One executable that a user can download, `chmod +x`, and run — on Debian oldstable, on Arch from this morning, on Alpine, on a corporate CentOS 7 box, on NixOS, inside a scratch container, on a distro that did not exist when you shipped.
2. **Link your code statically. Borrow the host's data. Talk to the host's services by protocol, not by ABI.** This one sentence is the whole doctrine. Everything below is an elaboration of it.
3. **glibc is not a portability layer. It is a portability hazard.** Its forward-only symbol versioning means "built on Ubuntu 24.04" is a *hard runtime dependency*, not a build detail. Either pin the baseline explicitly or leave glibc behind entirely.
4. **You must ship your own updates.** If your users have to wait for a distribution maintainer to notice, rebase, test, and release before they get a fix you wrote three weeks ago, you have outsourced your users' experience to volunteers who never agreed to it.
5. **Flatpak, Snap, AppImage, and Docker are not solutions to this problem. They are monuments to it.** They ship an entire operating system to work around the fact that we cannot ship an executable. We can. We just stopped trying.
6. **This does not require anyone's permission.** Not the distributions'. Not a standards committee's. Not the toolchain vendors'. Everything in this document works today, with tools that already exist, in an afternoon.

---

## Who this is for

You maintain a C or C++ program that end users run: a terminal tool, a daemon, a game, an editor, a GUI app. You have at some point:

- kept a CentOS 7 container around solely as a build environment;
- discovered your binary works on your machine and nowhere else, because of `GLIBC_2.38 not found`;
- been asked to produce `.deb`, `.rpm`, `.pkg.tar.zst`, AppImage, Flatpak and Snap of the same 4 MB program;
- received a bug report against a version you shipped two years ago because that's what a distro froze;
- watched a colleague reach for Electron and been unable to give a good reason not to.

This document is a way out.

---

## 1. The observation that started this

C was invented to make Unix portable. Today, the C ecosystem produces portable binaries everywhere **except** Unix.

**Windows** — the most maligned platform in this crowd — solved this in the 1990s and never unsolved it. Link the CRT statically (`/MT`), target a documented API baseline (`_WIN32_WINNT`), and your `.exe` runs from Windows 10 to whatever ships next decade. Microsoft treats the ability to run old binaries as a contractual obligation. You ship one file.

**macOS** solved it differently and just as effectively. There is exactly one system library, `libSystem`, it is versioned, and you declare which version you need (`-mmacosx-version-min`). Symbols newer than your baseline are weak-linked and testable at runtime. Everything above libSystem is yours to bundle. You ship one directory that behaves like one file, and users drag it where they want it.

**Go** solved it by refusing to participate. One static binary, no libc, `GOOS`/`GOARCH`, done. This is not a new invention — **Turbo Pascal and Delphi did it in 1985** and produced one `.exe` with the runtime inside. Free Pascal still does. **Cosmopolitan Libc** now does it *across operating systems*: one file that runs on Linux, macOS, Windows, and the BSDs.

**Linux** — the one platform whose entire premise is that you can build anything from source and run it anywhere — is the only one where "here is the program" is not a valid answer to "how do I run your program?"

Not because of anything intrinsic to Linux. The kernel's userspace ABI is the most stable in the industry; Linus enforces it with religious ferocity. Syscalls from 2005 still work. The break is *entirely above the kernel*: in glibc's symbol versioning, in the distribution model that pins every binary to the exact userland it was compiled against, and in a packaging culture that decided the correct place to solve dependency management is downstream of the people who wrote the code.

**The result is not that Linux desktop software is hard to ship. The result is Electron.** Developers did not choose Electron because it is a good GUI toolkit. It is a terrible GUI toolkit: 200 MB, half a gigabyte of RAM to show a text box, no native anything. They chose it because it is the only toolchain that reliably produces something a user can download and run. We lost the desktop to a browser engine because we could not ship an ELF file.

---

## 2. What went wrong, precisely

It's worth being exact, because vague complaints produce vague solutions.

### 2.1 glibc's symbol versioning is forward-only

glibc guarantees that a binary built against version *N* runs on *N* or later. It guarantees nothing about *N-1*. Because your linker always picks the *newest* version of every symbol available on the build machine, an innocent `memcpy` on a modern distro becomes `memcpy@GLIBC_2.14` and your binary refuses to start on anything older.

This means **your build machine's glibc version is a hard runtime requirement that you never declared and probably never noticed.** It is the single largest cause of "works here, not there" in the entire ecosystem.

The industry's workaround — build in a container running the oldest distro you support — is a *correct* fix wearing a humiliating costume. We are simulating a 2014 operating system in 2026 in order to emit a correct symbol version. There are now toolchains that let you simply *ask for* the baseline. Use them (§5).

### 2.2 Static glibc is a trap

"Just use `-static`" fails with glibc, and it fails *quietly*, which is worse:

- **NSS.** `getaddrinfo`, `getpwnam`, `gethostbyname` load `libnss_*.so` at runtime by design. Statically link glibc and hostname resolution either breaks or silently loads a *mismatched* NSS module from the host. Your program appears to work until it doesn't.
- **`iconv`** loads its converters as shared objects. Same story.
- **`dlopen`** from a statically linked glibc program is not supported in any meaningful sense.
- **License.** glibc is LGPL. Statically linking it imposes relinking obligations on your distribution (§9).

So the honest conclusion is not "static glibc" — it's "**not glibc**".

### 2.3 Some things genuinely cannot be bundled

Be honest about this, because the naive version of this manifesto dies here.

A GPU driver's userspace component is coupled to the kernel module on the machine. You cannot ship your own `libcuda.so` and expect it to talk to an arbitrary NVIDIA kernel driver; you cannot ship your own `libGL` and expect it to be the right one. **The host's GPU userspace must be loaded from the host, at runtime, by `dlopen`.**

This is not a footnote. It is the load-bearing constraint of the whole design, and it is why **"100% static like Go" is achievable for CLI tools and daemons but not for anything that touches a GPU.** (And it is precisely why statically-linked musl — which does not implement `dlopen` at all, by deliberate design — cannot be the answer for GUI apps.)

The correct response is not despair, and it is *definitely* not "therefore ship a whole OS image". The correct response is to notice that this is a very short list, and to draw a hard architectural line around it.

### 2.4 The containerized answers invert the layering

Flatpak, Snap and Docker say: *the host is unreliable, so bring your own host.* Then, because the app still needs the host's GPU, the host's fonts, the host's audio server, the host's file dialogs, the host's theme, the host's clipboard, and the host's keyring, they spend the next several years punching holes back through the wall they just built. Hence GL extensions per driver, hence themes that don't match, hence file pickers that can't see your files, hence 300 MB to ship a text editor, hence `/var/lib/flatpak` measured in gigabytes.

AppImage is the closest in spirit — it is one file you can run — but it inherits the same premise: bundle the userland, mount it as a filesystem, hope the pieces line up. It requires FUSE, it still needs an old-glibc build to be portable at all, and it does nothing about updates or integration. It's the right instinct with the wrong mechanism.

**The bundle is not the problem. Bundling the *wrong layer* is the problem.**

---

## 3. The doctrine: three layers

Every dependency your program has falls into exactly one of three categories. Sort them correctly and the whole problem dissolves.

### Layer 1 — CODE: yours, static, in the binary

Compression, parsing, crypto, image codecs, fonts rasterization, text shaping, HTTP, SQL, your UI toolkit, your language runtime. This is *your* code — you chose the versions, you tested against them, you are responsible for them. **It has no business being resolved on the user's machine.**

> Rule: if the library computes something, link it statically.

### Layer 2 — DATA: the host's, read at runtime from standard paths

Fonts. CA certificates. Icon themes. Locale data. MIME databases. Cursor themes. The user's colour scheme. Timezone data.

Bundling these is what makes containerized apps feel foreign: wrong font, wrong theme, wrong cursor, an outdated CA bundle, a file dialog that doesn't know your bookmarks. **The host's data is not a dependency to eliminate; it is the thing that makes your app look like it belongs.**

> Rule: if the file belongs to the user or the administrator, read it from XDG/FHS paths at runtime. Ship a fallback, never a replacement.

### Layer 3 — SERVICES & DEVICES: protocol first, `dlopen` only where physics demands it

The best-designed parts of the modern Linux desktop are all *protocols*, not ABIs:

| Service | Contract | Stability |
|---|---|---|
| Display | Wayland / X11 wire protocol over a socket | excellent, versioned, extensible |
| IPC / settings / notifications | D-Bus | excellent |
| File dialogs, screenshots, permissions | XDG Desktop Portals (over D-Bus) | good, improving |
| Audio | PipeWire / PulseAudio | protocol exists but is *de facto* consumed via a client library |
| Sandboxing, cgroups, devices | kernel syscalls, `/sys`, `/proc` | the most stable ABI on the planet |

A protocol is an ABI you can implement, version, and negotiate. A shared library is an ABI you must *match*. **Prefer the protocol every single time.**

That leaves a genuinely irreducible set that must be `dlopen`'d from the host:

```
libGL.so.1  libEGL.so.1  libGLESv2.so.2  libGLX.so.0   ← graphics
libvulkan.so.1                                          ← graphics
libcuda.so.1  libnvidia-ml.so.1  libOpenCL.so.1         ← compute
libva.so.2  libvdpau.so.1                               ← video accel
libasound.so.2  libpulse.so.0  libpipewire-0.3.so       ← audio (client libs)
```

That is the entire host contract. Roughly ten filenames. **Everything else in your dependency tree is yours to carry.**

> Rule: never *link* against anything that talks to a kernel driver. Load it at runtime, behind an interface, with a fallback, and degrade gracefully when it's absent.

**And one more contract, the oldest one: the process.** A file manager that runs the host's `7z` to open an archive, a mail client that runs `xdg-open`, an app that shells out to `sudo` or `ssh` — none of these is a portability defect, and bundling those programs would be a mistake. `execve` is a stable interface with a versioned contract (the command-line arguments), it fails legibly, and the user can substitute their own implementation. When a dependency is really a *tool* rather than a *library*, run it; don't link it, and don't ship a copy of the host's.

### The corollary that explains everything

> **Flatpak is what you get when you apply Layer-1 thinking to Layers 2 and 3.**

Once you see the three layers, the entire container-for-desktop-apps industry looks like a category error with a build system.

---

## 4. Two profiles

There is no single flag. There are two coherent build configurations, and you pick by whether you need `dlopen`.

### Profile S — **Static**: fully static, musl, zero host dependencies

For: CLI tools, servers, daemons, compilers, build tools, anything headless.

- libc: **musl**, statically linked
- Output: `ET_DYN` static-PIE, no `PT_INTERP`, no `DT_NEEDED` at all
- `ldd` says *"not a dynamic executable"*
- Runs on: every Linux with a kernel newer than roughly 3.2. Including `FROM scratch`.
- **`dlopen` does not work.** This is by design and is not a bug. If you need it, you need Profile H.

```bash
zig cc -target x86_64-linux-musl -O2 -static-pie \
       -ffunction-sections -fdata-sections -Wl,--gc-sections \
       -o myapp *.c
```

This is the Go-equivalent. It is exact, complete, and boring. **Most C and C++ programs in the world are eligible for Profile S today and would be strictly better off for it.**

### Profile H — **Hybrid**: baseline-pinned libc, everything else static, host contract via `dlopen`

For: GUI apps, games, anything using GPU, audio, or plugins.

- libc: **glibc pinned to an old baseline** (2.28 = Debian 10 / RHEL 8 / Ubuntu 18.10; 2.17 = RHEL 7 if you must)
- `libstdc++` and `libgcc`: **static** (`-static-libstdc++ -static-libgcc`)
- Every third-party library: **static**
- The host contract (§3, Layer 3): **`dlopen` at runtime, never `DT_NEEDED`**
- Allowed `DT_NEEDED` — and *nothing else*:

```
ld-linux-x86-64.so.2   libc.so.6   libm.so.6
libdl.so.2   libpthread.so.0   librt.so.1     (empty stubs on glibc ≥ 2.34)
```

```bash
zig cc -target x86_64-linux-gnu.2.28 -O2 \
       -static-libstdc++ -static-libgcc \
       -Wl,--as-needed -Wl,--exclude-libs,ALL \
       -Wl,-z,relro,-z,now -Wl,-z,noexecstack \
       -o myapp ...
```

Still one file. Still `chmod +x` and run. Still works on every distribution released since 2018. **This is what Telegram Desktop, Blender, Sublime Text and every game on Steam actually do**, and it is why they are the only Linux desktop software that never generates a "which distro are you on?" support thread.

### Choosing

| You need… | Profile |
|---|---|
| Nothing but syscalls | **S** |
| Networking, TLS, DNS | **S** |
| Loadable plugins | **H** |
| OpenGL / Vulkan / GPU compute | **H** |
| Audio | **H** (or S with pure-protocol PipeWire — advanced) |
| Wayland / X11 only (software rendering) | **S** is possible — both are socket protocols |
| Rich locale / `iconv` / ICU behaviour | **H**, or **S** with ICU bundled |
| `.local` mDNS, NIS, LDAP name resolution | **H** (musl has no NSS) |

Both profiles produce one file. That is the point. The user never learns which one you picked.

---

## 5. How to actually do it

### 5.1 The single most useful tool: `zig cc`

`zig cc` is a Clang distribution that bundles the headers and stub libraries for musl **and for every glibc version**, and cross-compiles to all of them from any host. It removes the entire "keep a CentOS 7 container as a build environment" ritual:

```bash
zig cc -target x86_64-linux-gnu.2.28   # pin glibc baseline, no old distro needed
zig cc -target aarch64-linux-musl      # fully static, cross-arch, no sysroot
zig cc -target x86_64-windows-gnu      # yes, really
```

You do not have to write a line of Zig. It is a C/C++ compiler that happens to ship in the same tarball. Use it as `CC`/`CXX` and keep your existing build system.

*Caveat:* `zig cc` passes `-nostdinc` when a target is given, so system headers under `/usr/include` are invisible — which is the point, but it means every dependency must be built from source too. That is the correct end state anyway.

If you prefer GCC: keep the old-distro container, and verify the baseline with the audit script (§6). The result is identical; the ergonomics are not.

### 5.2 CMake

```cmake
# Force the find_package machinery to prefer .a over .so
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
set(BUILD_SHARED_LIBS OFF)
set(OPENSSL_USE_STATIC_LIBS ON)
set(Boost_USE_STATIC_LIBS ON)
set(ZLIB_USE_STATIC_LIBS ON)
set(Protobuf_USE_STATIC_LIBS ON)

# C++ runtime and unwinder into the binary
add_link_options(-static-libstdc++ -static-libgcc)

# Profile S:
add_link_options(-static-pie)

# Hygiene: don't re-export symbols from static deps
add_link_options(-Wl,--exclude-libs,ALL -Wl,--as-needed)

# Size: strip everything unreachable
add_compile_options(-ffunction-sections -fdata-sections)
add_link_options(-Wl,--gc-sections)

# Hardening
add_compile_options(-fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE)
add_link_options(-Wl,-z,relro,-z,now -Wl,-z,noexecstack)

# Windows: static CRT
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
```

Do not use `-Wl,-Bstatic` piecemeal and hope. Use `pkg-config --static` where you must, and prefer building dependencies yourself with a superbuild (`FetchContent`, `ExternalProject`, vcpkg with `x64-linux` static triplet, or Conan with `shared=False`).

> **`--exclude-libs,ALL` is a default, not a law.** If your application exports an ABI to plugins it `dlopen`s itself, that flag deletes exactly the symbols the plugins need, and you will find out at the first plugin load rather than at link time. Applications with a plugin ABI want an explicit version script plus `-Wl,--export-dynamic`: export what you promised and nothing else. We learned this from far2l (§6.4), which is why it is a callout instead of a footnote.

### 5.3 Meson

```ini
[built-in options]
default_library = 'static'
prefer_static   = true
b_staticpic     = true
c_args   = ['-ffunction-sections', '-fdata-sections']
cpp_args = ['-ffunction-sections', '-fdata-sections']
c_link_args   = ['-static-libstdc++','-static-libgcc','-Wl,--gc-sections','-Wl,--exclude-libs,ALL']
cpp_link_args = ['-static-libstdc++','-static-libgcc','-Wl,--gc-sections','-Wl,--exclude-libs,ALL']
```

`meson setup build --prefer-static -Ddefault_library=static`

### 5.4 Autotools

```bash
./configure --enable-static --disable-shared \
  CC="zig cc -target x86_64-linux-musl" \
  CFLAGS="-O2 -ffunction-sections -fdata-sections" \
  LDFLAGS="-static-pie -Wl,--gc-sections"
```

### 5.5 Resources inside the binary

C23 has `#embed`. It is the single most underused feature in the standard:

```c
static const unsigned char icon_png[] = {
#embed "assets/icon.png"
};
```

Fallbacks: `xxd -i`, `ld -r -b binary`, `incbin.h`, or `objcopy --add-section`. Do not ship a `share/` directory next to your binary; you had one job.

### 5.6 The library cheat sheet

| Library | Verdict | How |
|---|---|---|
| **musl** | ✅ static, MIT | The default for Profile S. No NSS, no iconv modules, no licence obligations. |
| **glibc** | ⚠️ dynamic, pinned | Never static. Pin to 2.28 (or 2.17). Verify with the audit script. |
| **libstdc++ / libc++** | ✅ static | `-static-libstdc++ -static-libgcc`. Note: `pthread_cancel` on glibc pulls in `libgcc_s` at runtime; avoid cancellation or accept the `dlopen`. |
| **OpenSSL** | ✅ static | `./Configure no-shared no-dso`. **Do not bundle CA certs** — probe `SSL_CERT_FILE`, `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/cert.pem`, and only then fall back to an embedded bundle. |
| **BoringSSL / mbedTLS / rustls-ffi** | ✅ static | Smaller, static-by-nature alternatives. |
| **zlib, zstd, brotli, lz4, xz** | ✅ static | Trivial. |
| **SQLite** | ✅ static | The amalgamation is the reference example of how to ship a C library. |
| **libcurl** | ✅ static | `--disable-shared --enable-static`, define `CURL_STATICLIB`. Drop `libidn2`/`libssh` unless needed. |
| **libpng, libjpeg-turbo, libwebp, giflib** | ✅ static | Trivial. |
| **FreeType, HarfBuzz** | ✅ static | Trivial and essential — never depend on the host's version. |
| **Fontconfig** | ✅ static (Layer 2 data!) | Link statically, but let it read the **host's** `/etc/fonts` and font directories. This is what makes your text look native. |
| **ICU** | ✅ static | `--with-data-packaging=static`. Big; trim with `icutrim`/data filters. |
| **SDL2 / SDL3** | ✅✅ static, ideal | **The reference implementation of this manifesto.** SDL `dlopen`s X11, Wayland, GL, ALSA, PulseAudio and PipeWire at runtime by design. `-DSDL_STATIC=ON -DSDL_SHARED=OFF`. If you are starting a GUI/game project, start here. |
| **GLFW** | ✅ static | Modern versions load X11/Wayland dynamically. |
| **Qt** | ✅ static, ⚠️ licence | `configure -static`; static plugins need `Q_IMPORT_PLUGIN`. **LGPL static linking obligates you to ship relinkable objects** (§9) — or buy a commercial licence. |
| **GTK** | ❌ hostile | GIO modules, pixbuf loaders, input methods and print backends are all `dlopen`'d from host paths. GTK is architecturally opposed to being bundled. If portability is a goal, this is a toolkit choice, not a build flag. |
| **wxWidgets** | ⚠️ | Static build works; it inherits GTK's problems on Linux. |
| **OpenGL / EGL / GLES** | ⛔ never link | Use **glad** (dlopen mode) or **libepoxy**. `dlopen("libGL.so.1")` / `libEGL.so.1`. |
| **Vulkan** | ⛔ never link | Use **volk**; it `dlopen`s `libvulkan.so.1`. |
| **CUDA / ROCm / OpenCL** | ⛔ never link the driver | `libcudart_static.a` is fine; `libcuda.so.1` **must** be `dlopen`'d. |
| **ALSA / PulseAudio / PipeWire / JACK** | ⛔ never link | `dlopen` with fallback chain, exactly as SDL does. `libasound` itself loads plugins from host paths. |
| **X11** | ✅ static (prefer XCB) | `libxcb` is a pure socket protocol — safe to link statically. `libX11` loads locale/XIM modules; prefer XCB where you can. |
| **Wayland** | ✅ static | `libwayland-client` is a socket protocol implementation. Safe. Generate protocol code at build time. |
| **D-Bus** | ✅ static | Static `libdbus`, or `sd-bus`, or speak the wire protocol. Prefer this over `libnotify`, `libsecret`, GNOME/KDE-specific libraries. |
| **XDG Portals** | ✅✅ protocol | The correct way to do file dialogs, screenshots, screen sharing, permissions. Pure D-Bus. No ABI. |
| **libudev** | ⚠️ | Prefer reading `/sys` directly, or `dlopen` `libudev.so.1`. |
| **FFmpeg** | ✅ static | Static build is well supported. Mind codec licensing. |
| **libarchive** | ✅ static | Configure down to the formats you actually support; the default pulls in a lot. |
| **libssh / libssh2** | ✅ static | Fine; pick and pin the crypto backend rather than letting it find one. |
| **neon, libnfs, uchardet, libxml2** | ✅ static | Small, well-behaved, no runtime module loading. |
| **libsmbclient (Samba)** | ❌ hostile | Loads its own modules at runtime, drags Kerberos and a configuration stack, and is enormous. Speak SMB over a socket, or make the feature optional and degrade. |
| **Python / Lua / V8 embedding** | ⚠️ | Embedded Python needs `dlopen` for native extensions → Profile H. Lua is fine anywhere. |
| **glibc NSS (`getaddrinfo`)** | ⚠️ | musl resolves DNS itself — no NSS, but also no mDNS/`.local`, no NIS/LDAP. Know your users. |

### 5.7 Windows

You already had this right; don't regress.

```
MSVC:  /MT  (CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded)
MinGW: -static -static-libgcc -static-libstdc++
```

- Set `_WIN32_WINNT` / `WINVER` to your actual baseline and hold the line.
- Delay-load optional APIs (`/DELAYLOAD`) and `GetProcAddress` anything newer than the baseline.
- Never require a "Visual C++ Redistributable" download. That is a Windows-flavoured `GLIBC_2.38 not found`.
- Ship the `.exe`. Sign it. That's the deliverable.

### 5.8 macOS

Apple **forbids** statically linking `libSystem`, and that's fine — because they gave you the thing that actually matters instead:

```
-mmacosx-version-min=11.0    /    MACOSX_DEPLOYMENT_TARGET=11.0
-arch x86_64 -arch arm64     (universal2, or lipo two builds)
```

- Everything above libSystem: static.
- Use `__builtin_available` / weak linking for anything newer than the baseline.
- Verify with `otool -L` — only `/usr/lib/libSystem.B.dylib` and `/System/Library/Frameworks/*` are allowed.
- Ship a `.app` bundle, codesigned and notarized, with a hardened runtime. It's one draggable object; the user model is already right.

### 5.9 The extreme end: one file for *all* operating systems

**Cosmopolitan Libc** (Actually Portable Executable) produces a single file that runs on Linux, macOS, Windows, FreeBSD, OpenBSD and NetBSD. `cosmocc` is a drop-in `cc`. For CLI tools, this is not a stunt — it's a shipping strategy. It is the strongest available proof that the constraints we accept are self-imposed.

---

## 6. Verification: the part nobody does

Building it right and *proving* it is right are different jobs. Add this to CI and make it a hard gate.

### 6.1 The audit script

```bash
#!/bin/sh
# audit.sh <binary> [max-glibc]
set -eu
BIN="$1"; MAX="${2:-2.28}"

echo "== DT_NEEDED =="
readelf -d "$BIN" | grep NEEDED || echo "  (none — fully static)"

echo "== highest GLIBC_ symbol version required =="
readelf -W --dyn-syms "$BIN" 2>/dev/null \
  | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' \
  | sort -t. -k1,1n -k2,2n -u | tail -1

echo "== RPATH / RUNPATH (must be empty or \$ORIGIN) =="
readelf -d "$BIN" | grep -E 'RPATH|RUNPATH' || echo "  (none)"

echo "== hardening =="
readelf -lW "$BIN" | grep -E 'GNU_RELRO|GNU_STACK'
readelf -d "$BIN" | grep -q BIND_NOW && echo "  BIND_NOW: yes" || echo "  BIND_NOW: NO"

echo "== build-machine paths leaked into the binary =="
strings -a "$BIN" | grep -E '^/(home|root|build|Users)/' | head || echo "  (clean)"

echo "== dlopen'd host contract =="
strings -a "$BIN" | grep -E '^lib(GL|EGL|GLESv2|GLX|vulkan|cuda|asound|pulse|pipewire)' | sort -u
```

A binary that passes is a binary you can hand to a stranger.

### 6.2 The test matrix

Run the binary — not build it, **run** it — in the oldest and newest things you can find:

```yaml
strategy:
  matrix:
    image:
      - alpine:3.10        # musl, ancient
      - centos:7           # glibc 2.17
      - ubuntu:16.04       # glibc 2.23
      - debian:bullseye    # glibc 2.31
      - fedora:latest      # bleeding edge
      - archlinux:latest   # bleeding edge
      - opensuse/leap
      - nixos/nix          # no FHS at all — the real test
      - scratch            # Profile S only; the ultimate test
```

Yes, that uses containers. **We use containers to test, not to ship.** That's the entire difference.

### 6.3 Conformance levels

Adopt these publicly. Put the level in your README.

| Level | Name | Requirement |
|---|---|---|
| **0** | Baseline Pinned | Declared and verified libc baseline; no accidental `DT_NEEDED` |
| **1** | Self-Contained | One file; all non-host libraries static; passes the test matrix; PIE + RELRO + BIND_NOW |
| **2** | Self-Installing | Installs into `~/Apps` (§7.2); first-run integration into `~/.local` (desktop entry, icons, MIME); clean `--uninstall`; **never requires root** |
| **3** | Self-Updating | Signed, atomic, rollback-capable updates; published SBOM; updater disables itself when installed by a package manager |

```markdown
![Static Everywhere Level 3](https://img.shields.io/badge/Static%20Everywhere-Level%203-1f6feb)
```

### 6.4 The reference application

Everything above is a claim about programs in general, argued from programs the
author chose. So this project keeps a standing obligation to a program it did not
choose and cannot quietly simplify:

> **[far2l](https://github.com/elfmz/far2l) must build under this doctrine, in
> every UI mode it has, and the audit output must be published.**

far2l is a Linux fork of FAR Manager v2. It runs in a bare terminal, in a terminal
with X11 clipboard integration through a helper process, and as a desktop
application through either wxWidgets or SDL. It has a plugin ABI whose plugins
resolve symbols from the main executable, ~15 optional third-party libraries,
host data it must read to look native, external programs it shells out to, and a
GPLv2 licence with a bundled non-free decompressor. It is the shape of program
that "just link it statically" advice is usually waved at and then dropped.

Four configurations, and what each is for:

| Build | Profile | Level | Result |
|---|---|---|---|
| Terminal only, no plugins | S | 1 | One musl static-PIE file. Runs on `FROM scratch`. |
| Terminal + plugins + X11 helper | H | 1 | Executable plus `$ORIGIN`-relative modules. |
| SDL graphical backend | H | 1 | A GUI application with no toolkit on the target: SDL `dlopen`s X11/Wayland/GL, FreeType and HarfBuzz are static, fontconfig reads the **host's** fonts. |
| wxWidgets graphical backend | H | 0 | **Expected to fail Level 1.** GTK arrives through wxWidgets and cannot be bundled. We publish the `DT_NEEDED` list rather than asserting that GTK is a problem. |

The exercise has already paid for itself twice, before a single far2l object file
was compiled: it found a flag in this document's own CMake recipe that breaks any
application with a plugin ABI (§5.2), and a rule in our audit specification that
would have reported every one of far2l's plugins as a broken executable. Both are
fixed. Build instructions and the full write-up are in
[04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md).

**If you are reading this to decide whether the doctrine is serious, that document
is the honest place to look** — including §7, which is a list of the places where
a real program made this argument more complicated.

### 6.5 The Qt reference application

far2l is C++ with plugins and three UI backends. It says nothing about the
question every project asks once GTK is ruled out: **what does a static Qt
cost?**

So there is a second target, and this one we did not have to convince:
[f4-qt](https://github.com/Zoinen/f4/tree/zoin) already ships one executable per
OS with a fully static Qt Quick front end — QML modules, shaders, platform
plugins and image codecs inside the binary — and already enforces a written
portable-build policy in CI, with a glibc baseline and an audit script, arrived
at independently. Its link line is this document's, flag for flag.

Which makes it evidence rather than a demonstration, and the useful part is where
it corrects this document. Five things, in
[05-REFERENCE-f4-qt.md §7](./05-REFERENCE-f4-qt.md): a binary package cache does
not encode the glibc baseline, so **the baseline applies to every object in the
artifact rather than to the final link**; a static Qt application can pass every
`readelf` check and still fail to start, so **Level 1 needs a runtime gate**; a
`CGO_ENABLED=0` binary with no interpreter can still `dlopen`, so "Profile S
cannot" is a fact about the C toolchain; on macOS the unit is the signed bundle,
not one file; and "one binary" is a claim about the artifact the user downloads,
not about the process table.

---

## 7. Shipping and updating: the Telegram model

Level 1 makes your software *runnable*. Levels 2 and 3 make it *pleasant*, and that is the part that beats Electron.

**The user model we are aiming for:**

1. Download one file.
2. Drop it in `~/Apps` — the user-level Program Files (§7.2) — or anywhere else you like, including a USB stick.
3. Run it.
4. It appears in the launcher, with the right icon, using your fonts and your theme.
5. It updates itself, quietly, without root, without a package manager, without you noticing.
6. `--uninstall` removes every trace.

Nothing here is hard. All of it is neglected.

### 7.1 Self-update, done correctly

- **Sign everything.** Ed25519, minisign-compatible, public key embedded in the binary. An unsigned auto-updater is a remote code execution service you are running on behalf of whoever owns your CDN.
- **Rollback protection.** Monotonic sequence number and an expiry on the update manifest, so an attacker cannot serve you last year's vulnerable release forever.
- **Atomic install.** Write to a temp file in the same directory, `fsync`, verify, `rename(2)` over the running binary. On Linux this is safe: the running process keeps its inode. Keep `N-1` for rollback.
- **First-run canary.** If the new version fails to reach a "healthy" checkpoint on first launch, restore the previous binary automatically.
- **Deltas.** `zstd --patch-from` gives you 200 KB updates for a 30 MB binary — *if* your builds are reproducible (`SOURCE_DATE_EPOCH`, `-ffile-prefix-map`, sorted inputs). Reproducibility pays for itself here.
- **Never require root. Never install a daemon. Never phone home with anything you wouldn't put in a log the user can read.**

### 7.2 Where it lives: `~/Apps`

Every other desktop operating system has a per-user place for programs the user
installed themselves, and on every one of them it is **visible**:

| System | Per-user application directory | Who already uses it |
|---|---|---|
| Windows | `%LOCALAPPDATA%\Programs\<App>` | VS Code, Signal, Discord, Zoom, GitHub Desktop |
| macOS | `~/Applications/<App>.app` | anything dragged out of a `.dmg` without admin rights |
| Linux | *(nothing)* | so every project invents one, and no two agree |

XDG is not the missing answer. The Base Directory specification defines homes for
*data*, *config*, *cache*, *state* and *runtime files*. A 40 MB self-contained
application is none of those. `~/.local/bin` is the closest thing and it is a
`$PATH` directory — the right home for a symlink or a three-line wrapper, not for
the payload.

So this document adopts a convention and asks you to adopt it too:

> **Static Everywhere applications install to `~/Apps`.**

```
~/Apps/                                 the user's Program Files
~/Apps/Foo                              a single-file app is just a file
~/Apps/Bar/                             an app with modules gets a directory
~/Apps/Bar/bar                          …with the executable inside it
~/.local/bin/bar -> ~/Apps/Bar/bar      optional, and this is what goes on $PATH
```

The rules, all of them deliberately boring:

- **Not hidden.** `~/.local/share` is a fine place for a MIME database and a
  terrible place for the single most security-relevant object on the machine: an
  executable that did not come from a package manager. A user who cannot find it
  cannot inspect it, back it up, or delete it. We are asking people to trust
  binaries they downloaded; the least we can do is not hide them.
- **Not localised.** `Program Files` is `Program Files` in every locale Windows
  ships. `/Applications` is `/Applications` in Japanese. A path that moves with
  `LC_MESSAGES` breaks scripts, documentation, support threads, and the
  trampoline in §7.4. Translate your interface, not your filesystem.
- **`Apps`, not `Applications`.** Four letters, sorts to the top of `ls ~`, and
  is not a prefix of anything XDG already owns.
- **One file or one directory per application, and nothing else.** No shared
  `lib/`, no `~/Apps/bin` that half your applications write into. Two programs
  that must share a directory are one program.
- **`$PATH` stays XDG.** If the application is also a command, drop a symlink in
  `~/.local/bin`, which is already on `$PATH` on every current distribution and
  is trivial to remove. The payload still lives in `~/Apps`.
- **One escape hatch, for the people who will hate this**: `$ONEBIN_APPS_DIR`, if
  set and absolute, wins. There is no further fallback chain and no
  autodetection. A convention with three candidate locations is not a
  convention.

Nothing here is enforceable and nothing here needs to be. It costs one `mkdir`
and it gives the ecosystem something it has never had: the same answer to "where
does it go?" on every distribution, in a place a user can point a backup tool, a
file manager, or their own curiosity at.

### 7.3 Be a good citizen of the desktop

On first run, with consent, install into the user's home:

```
~/.local/share/applications/com.example.app.desktop
~/.local/share/icons/hicolor/{256x256,scalable}/apps/com.example.app.{png,svg}
~/.local/share/mime/packages/com.example.app.xml
```

Then call `update-desktop-database` and `update-mime-database` if present, and ignore failures. Mark your entries `X-StaticEverywhere-Managed=true` so uninstall is exact. Fifty lines of code. This is the entire gap between "a binary I downloaded" and "an app on my computer."

### 7.4 Be a good citizen of the distribution

**If your binary detects it was installed by a package manager — it lives under `/usr`, it isn't writable by the user, it's owned by root — the updater must switch to Override Mode.** Instead of failing or asking for root, it installs the update into `~/Apps/<App>/` (§7.2), and the system binary acts as a trampoline that launches the local copy. If the update breaks, the user deletes `~/Apps/<App>` — a visible directory, in a place they were told about, removable with a file manager — and is instantly back on the distribution's build. Distribution packaging is a legitimate delivery channel and this manifesto is not a declaration of war on it (§10).

---

## 8. Objections, honestly answered

**"Static linking means CVEs never get fixed. The distro's shared OpenSSL protects users."**

The strongest objection, and it deserves a real answer rather than a slogan.

The shared-library model has one genuine advantage: one `libssl.so` upgrade fixes every consumer at once. That is real and it should not be dismissed.

But look at what it costs, and at how often it actually delivers. Your users on Debian stable are running the version of your program you shipped 26 months ago, with all of *your* bugs, including your security bugs, because the distribution froze it. The CVE in your dependency gets patched; the CVE in *your* code does not, until the next release cycle. And half the ecosystem — Chrome, Firefox, Electron, every Go and Rust binary, every game, every container image — already vendors its dependencies, so the "shared surface" the model protects is much smaller than it appears.

What we owe users in exchange for taking on this responsibility is concrete and non-negotiable:

- **Publish an SBOM** (CycloneDX or SPDX) with every release. Machine-readable. Non-optional.
- **Automate dependency monitoring.** Subscribe to advisories for everything you vendor. Dependabot/Renovate on your vendored manifests.
- **Ship security fixes in hours, not release cycles.** You control the pipeline now — that's the whole trade.
- **Ship an auto-updater** (§7.1). Without it you have taken the distribution's responsibility and not performed it, and the objection becomes correct.
- **Use the host's CA store**, so certificate trust decisions stay with the administrator.

Static linking without an updater is negligence. Static linking *with* one gets fixes to users faster than any distribution ever has.

**"Static binaries waste disk and RAM — no page sharing."**

Measure it. `--gc-sections` + LTO typically produce a binary *smaller* than the sum of the shared libraries it replaced, because you only pay for what you call. Shared libraries are only shared if multiple processes actually map the same file, which for app-specific dependencies is approximately never. And the comparison isn't against a hypothetical perfectly-shared system — it's against a Flatpak runtime measured in gigabytes.

**"This is just vendoring, and vendoring is bad."**

Vendoring is bad when it's invisible. It's fine when it's declared, pinned, monitored and reproducible. The badness was never in the linking model; it was in the lack of an SBOM.

**"Distributions will refuse to package this."**

They can still package it (§10) — a well-behaved project offers `-DUSE_SYSTEM_LIBS=ON` and keeps the boring source build boring. But also: distribution packaging is not the only legitimate way for software to reach users, and treating it as such is precisely how we ended up with 200 MB Electron apps.

**"Not everything can be static."**

Correct, and this document says so plainly (§2.3, §3). The claim is not "no dynamic linking ever". The claim is: **the set of things you load from the host should be ten filenames long, chosen by physics, loaded at runtime, and behind a fallback.** Everything else is yours.

**"This is fine for a CLI tool. Try it on something real."**

Fair, and the reason §6.4 exists. The reference application is far2l — a file manager with a terminal backend, two graphical backends, a plugin ABI, a helper process and a GPLv2 licence — and its build is kept in CI so that "we tried it on something real" is a link rather than a claim. That exercise is also where this document gets its corrections: §5.2's warning about `--exclude-libs,ALL` is there because far2l's plugins stopped loading, and the honest answer to "one binary?" for an application with `dlopen`'d plugins is "one binary and its modules, or a packer, and here is the cost of each" (see [04-REFERENCE-far2l.md §7.5](./04-REFERENCE-far2l.md)).

The parts that *don't* work are published too. GTK cannot be bundled; the wxWidgets build of far2l is kept in the matrix as a measured failure rather than deleted from the argument.

**"musl is slower than glibc."**

Sometimes, notably in `malloc` and some string routines. If it matters for your workload, use `mimalloc`/`jemalloc` (static, one link line) or use Profile H. Most programs will never notice; measure before you decide it disqualifies you.

**"Why not just use Flatpak, it's improving."**

It is, and portals in particular are excellent work that this manifesto explicitly recommends using — *directly*, without the container. But no amount of improvement changes the layering: it will always be shipping a userland to compensate for our inability to ship an executable. We should fix the executable.

---

## 9. Licensing: read this before you ship

Static linking changes your obligations. Two specific landmines:

- **LGPL libraries (Qt, glibc, and many others).** Dynamic linking satisfies the LGPL's "user can replace the library" requirement automatically. Static linking does not — you must provide either the object files or another mechanism enabling relinking against a modified version of the library. This is a solvable problem (publish your `.o`/`.a` artifacts alongside releases; it's a CI step), but it must be solved *deliberately*.
- **This is a strong practical argument for musl (MIT) over glibc (LGPL)** in Profile S, and for permissively-licensed dependencies generally.

Automate SPDX license scanning in CI. "We didn't realise" is not a defence, and getting this wrong will discredit the whole idea faster than any technical failure.

---

## 10. A note to distribution maintainers

You are not the villain of this document. The Linux distribution is one of the great achievements of collaborative engineering, and for the OS itself — the shell, the compiler, the kernel, the libraries that genuinely benefit from being shared — the model is correct and should continue.

What we are asking is narrower: **stop being the only path by which application software reaches users**, because that path has latency measured in years and it is losing the desktop to a browser engine.

Concretely, a project conforming to this manifesto commits to:

- keeping a **plain, boring source build that uses system libraries** (`-DUSE_SYSTEM_LIBS=ON` or equivalent) so you can package it the way you always have;
- **switching the self-updater to user-local override mode** when installed system-wide by a package manager, using the system binary as a reliable trampoline;
- publishing an **SBOM** so you can audit what we vendored;
- **reproducible builds**, so you can verify our binaries match our sources;
- not shipping anything into `/usr` ourselves, ever.

Two channels, one codebase, no fighting. Users who want the distribution's release get it. Users who need today's fix today get that. Nobody has to lose.

---

## 11. What to do this week

**If you maintain a CLI tool or daemon** (an afternoon):

1. Build it with `zig cc -target x86_64-linux-musl -static-pie`.
2. Run `./tools/audit.sh`. Confirm zero `DT_NEEDED`.
3. Attach the binary to your GitHub release. Keep doing the tarball too.
4. Add the Level 1 badge.

**If you maintain a GUI app** (a week):

1. Pick a glibc baseline (2.28 is a sane default) and pin it.
2. Move every dependency to a static build; move GL/Vulkan/audio to `dlopen` (or adopt SDL, which already did it for you).
3. Audit `DT_NEEDED` against the allowlist. Fix everything that isn't on it.
4. Add the container test matrix to CI as a **hard gate**.
5. Add first-run desktop integration and `--uninstall` (Level 2).
6. Add signed self-updates (Level 3).

**If you maintain a library**:

1. Make sure `BUILD_SHARED_LIBS=OFF` works and is tested in CI.
2. Export a working static `pkg-config`/CMake config with correct transitive `Libs.private`.
3. Don't `dlopen` things behind your users' backs. If you must, document it and let it be overridden.
4. Don't assume the host filesystem layout in your build.

**If you're starting something new**: Profile S by default, SDL if you need a window, portals for everything the desktop offers, and one binary in your release page from day one.

---

## 12. Prior art, gratefully acknowledged

- **Turbo Pascal / Delphi / Free Pascal** — one `.exe` with the runtime inside, since 1985.
- **Go** — proved at scale that "one static binary" is a viable product decision, not a niche trick.
- **Cosmopolitan Libc** — one file, six operating systems. The existence proof.
- **musl** — a libc that treats static linking as a first-class mode instead of a legacy accident. MIT-licensed.
- **Zig** — `zig cc` made "target an arbitrary glibc baseline" a command-line flag instead of a container.
- **SDL** — has implemented the Layer-3 doctrine correctly for two decades. Read `SDL_dynapi` and the `SDL_LoadObject` backends.
- **Telegram Desktop, Blender, Sublime Text, Godot, Steam** — proof by shipping.
- **Rust's `x86_64-unknown-linux-musl` target** — a neighbouring ecosystem that made static the easy path.
- **XDG Desktop Portals, Wayland, D-Bus, PipeWire** — the parts of the modern desktop that got the protocol-not-ABI question right, and which make this whole approach possible.
- **[UTF-8 Everywhere](https://utf8everywhere.org/)** — for the format, the tone, and the demonstration that a document can change an ecosystem's defaults without a committee's permission.
- **Nix's `pkgsStatic`** — proof that "rebuild the dependency graph statically, from source, with pinned hashes" scales to a whole package repository. Also, honestly, proof of the cost: years of open issues over `gcc`/`bintools` target-prefix mismatches, `libc++` exception handling under static linking, and `pkgsStatic` accidentally implying musl when it shouldn't have to. Rebuilding everything is powerful and expensive; this project's bet is that most projects don't need to rebuild everything, only to link what they already build differently.
- **[stal/IX](https://github.com/stal-ix/stalix)** — the extreme, whole-OS version of this doctrine: a Linux distribution with no dynamic loader at all, where even GNOME and the browser are static. The strongest available evidence that "everything static, including big GUI applications" is not a toy claim. It answers a different question than this project does — "build an OS where static is the default" rather than "make one existing, unmodified upstream project static with the least disruption to its own build" — which is why it doesn't reduce the need for a project like far2l to be individually, incrementally converted and audited; see `FUTURE-IDEAS.md §2` for why a from-scratch recipe collection is not simply "reimplementing nixpkgs".

---

## 13. Sign it

If your project conforms, open a pull request adding it to `CONFORMING.md` with its level and a link to its CI audit. If you disagree, open an issue — this document is a draft and the objections in §8 got better every time someone argued with them.

> **Ship your code. Borrow the host's data. Talk to the host by protocol.**
> **One binary. Any Linux. No containers.**
