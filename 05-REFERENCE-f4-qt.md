# REFERENCE — f4-qt, the Qt reference application

**Offline reference. No internet required to read it.** Everything below was read
out of the source tree at the pin in §2 and is reproduced here so that an agent
without network access can work from it.

far2l ([04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md)) is the reference for a
C++ application with a plugin ABI and three UI backends. **f4-qt is the reference
for Qt** — the toolkit everyone is told to reach for once GTK has been ruled out
(manifesto §5.4, `DESIGN-onebin.md §11` row 5), and the one whose static build
nobody wants to be the first to attempt.

It is also the first project this repository has looked at that **arrived at the
doctrine independently, wrote it down, and enforces it in CI.** That makes it
evidence rather than a demonstration, and §7 is where the evidence disagrees with
us.

---

## 1. Why f4-qt

1. **Qt is the hard case that is not GTK.** The manifesto tells people to prefer
   SDL or Qt and then says almost nothing about what a static Qt actually costs.
   This closes that gap with numbers instead of encouragement.
2. **It is QML, not just widgets.** A static Qt Quick application must carry its
   QML modules, its shaders, its `qtquickcontrols2` style and its platform
   plugins *inside the executable*. This is the part where "just link it
   statically" stops working and nobody says so out loud.
3. **It already ships a written portable-build policy**
   (`docs/PORTABLE_BUILD_POLICY.md`) that reads like an independent derivation of
   Static Everywhere, including a glibc baseline, an audit script, and a rule
   against inferring portability from a successful link.
4. **It disagrees with us in useful places.** Two processes on purpose, a
   baseline of 2.27 rather than 2.28, and a cache-extraction step we had filed
   under "v0.4, not yet specified". See §7.
5. **It is a Go program wearing a Qt front end**, which puts a second toolchain
   inside the same artifact and tests whether our profiles describe anything
   beyond C and C++.

---

## 2. Facts

| | |
|---|---|
| Upstream core | `https://github.com/unxed/f4` — Go, BSD-3-Clause, module path `github.com/unxed/f4` |
| Qt fork | `https://github.com/Zoinen/f4`, branch **`zoin`** |
| Pin used for this document | `1a03511a5ad97bbd4ec1400078272373b32e9d2c` (2026-08-17) |
| Where the Qt code lives | `qt/host/` in the fork; upstream has `sdk/extui` and `extui_host.go` but no `qt/` |
| Qt | **6.11.1**, via Conan; `Core Gui Qml Quick QuickControls2 Network Svg` (+ `Test`) |
| C++ standard | `gnu20` |
| Linux baseline | **glibc 2.27** (Ubuntu 18.04), gcc-11 from `ppa:ubuntu-toolchain-r/test` |
| macOS deployment target | 13.0, enforced by the Conan recipe's `validate()` |
| Build tooling | Conan 2.29.1, CMake 3.31.6, Ninja 1.13.0, Go 1.26.x |
| Go binary size | ~50 MB (upstream README), before the embedded Qt host |
| Licences in play | f4 BSD-3-Clause; Qt LGPLv3-or-commercial; Lucide icons bundled with their licence |

**Pin the commit, not the branch.** `zoin` is a moving development branch with no
tags; a reference build that says "branch `zoin`" is not reproducible and will
not stay honest for a week.

---

## 3. Architecture you must know

### 3.1 Two processes, deliberately

```
f4  (Go, CGO_ENABLED=0)  ──ExtUI──►  f4-qt-host  (C++/Qt/QML)
        parent                            child
```

The Go core owns the file manager. The Qt host owns the window. They speak
**ExtUI**: a 4-byte big-endian length prefix followed by a MessagePack map, over
a socket. The host is started with `--f4-ext-connect=`, `--f4-ext-nonce=`,
`--f4-ext-cols=`, `--f4-ext-rows=` (the older `--f4-qt-*` spellings are still
accepted).

`docs/PORTABLE_BUILD_POLICY.md` states the boundary as a rule: *do not merge the
Go runtime and the Qt event loop into one process merely to call the result a
single binary.* We agree, and §7.1 explains why that does not cost them the
claim.

The Go core also runs with no Qt at all — in a terminal, or with its own
`--gui=gogpu|x11|wayland` backends. The Qt host is one renderer among several,
which is why it can be a child process without the design feeling contorted.

### 3.2 The embedded host and the content-addressed cache

The Linux and Windows download is **one Go executable**. The Qt host is gzipped
(`ci/package-embedded-qt-host.py`, level 9, `mtime=0` for determinism) into
`embedded/f4-qt-host.gz` at release time — never committed — and linked in under
the `f4_embedded_qt_host` build tag.

On the first `--gui=qt` launch the Go process materialises it into a
**content-addressed cache** keyed by the SHA-256 of the payload: private
directory, temporary file, gzip integrity check, executable bits, atomic rename.
Concurrent first launches are safe; a new payload hash produces a new path, so an
upgrade can never execute a stale helper; old generations are collectable only
when not running. `F4_QT_HOST_CACHE_DIR` overrides the root, otherwise the OS
user cache directory is used.

Runtime lookup order: `F4_EXT_UI_PATH` → a packaged sibling host (for
distribution maintainers) → the embedded cache. On macOS the `.app` bundle next
to `f4` wins and **nothing is extracted**, because extracting an executable
helper would break the signature.

### 3.3 Layer 2 — host data it reads

Fonts and the font configuration, the icon theme (Qt's platform file-icon
provider delegates to the XDG icon theme on Linux, Finder/NSWorkspace on macOS,
the Shell image lists on Windows), the MIME database, and the user's display
server. The bundled Lucide icon set is the *fallback* when a theme icon is
missing — a good model, and the opposite of shipping a theme and ignoring the
host's.

### 3.4 Layer 3 — what it talks to

The display server, the GPU (Qt RHI: Vulkan/OpenGL/software), and, in the Go
core, whatever the selected `--gui` backend needs. Note §7.7: the Go side reaches
these **without cgo and without X11 or Wayland client libraries**, which is a
stronger result than the doctrine currently claims is possible.

---

## 4. Build system reference

### 4.1 The baseline container

`ci/build-portable-qt-linux.sh` refuses to run unless it is root inside **Ubuntu
18.04** (`grep -q 'Ubuntu 18.04' /etc/os-release`). That is the glibc 2.27
contract, expressed as a guard rather than as a comment. CI runs it via
`docker run` from `ubuntu-24.04`, with the host's `GOROOT` bind-mounted read-only
at `/opt/go`.

We recommend `zig cc -target x86_64-linux-gnu.2.28` instead of an old container
precisely to avoid this ritual (manifesto §4.1). f4 shows the honest cost of the
container route for a dependency graph this size: it is not just the final link
that must respect the baseline, it is **every one of the 38 native packages**.

### 4.2 The Conan graph, and the rule that matters

```
qt/6.11.1  msgpack-cxx/7.0.0
libtiff/4.7.0  libraw/0.21.3  libpng/1.6.45  libwebp/1.6.0
libheif/1.20.1  libjpeg-turbo/3.0.2  jasper/4.2.0 (override)
```

Portable options:

```
-o:h qt/*:shared=False        -o:h qt/*:qtwayland=True
-o:h qt/*:with_egl=True       -o:h xkbcommon/*:with_wayland=True
-o:h libraw/*:shared=False    -s:h compiler.cppstd=gnu20
```

and then the load-bearing line, quoted from the script's own comment:

> Conan package IDs do not encode the glibc build baseline.

So every target-side package is rebuilt from source even when Conan Center offers
a matching GCC-11 binary — 38 `--build=<pkg>/*` entries plus `m4`, whose remote
binary needs a newer glibc than the container has. **A binary package cache is
baseline-blind.** See §7.3; this is the finding we most want in our own docs.

`third_party/ZoinGallery` (the panel renderer) and QWindowKit are built in the
same CMake graph, from source, statically. QWindowKit comes from its `main`
branch via `ci/build-qwindowkit.sh`; ZoinGallery is a pinned submodule (§7.8).

### 4.3 Compiler and linker flags

```
compile: -ffunction-sections -fdata-sections -fstack-protector-strong
link:    -static-libstdc++ -static-libgcc
         -Wl,--gc-sections -Wl,--exclude-libs,ALL -Wl,--as-needed
         -Wl,-z,relro,-z,now,-z,noexecstack
MSVC:    MSVC_RUNTIME_LIBRARY = MultiThreaded   (static CRT)
Go:      CGO_ENABLED=0 go build -trimpath -tags f4_embedded_qt_host -ldflags='-s -w'
```

That link line is Profile H from our Quick Start, flag for flag, arrived at
independently. `--exclude-libs,ALL` is safe here because the Qt host exports no
ABI to plugins of its own — the far2l exception (§7.1 there) does not apply.

`F4_PORTABLE_STATIC=ON` also *asserts* the shape of the Qt package at configure
time: `Qt6::Core` must be a `STATIC_LIBRARY` or an `INTERFACE_LIBRARY` facade, or
the build fails before compiling anything. A cheap, copyable trick.

### 4.4 QML modules and plugins

The requirement is stated as a contract, not a hope: *embed every required QML
module, Qt plugin, shader, image and application resource; the host must not
require a sibling Qt library, QML tree or plugin directory.* Icons and QML go in
through `qt6_add_resources` / `qt_add_qml_module`, and `QT_QML_IMPORT_PATH` has
to be set explicitly on the application target for both the Conan-staged Qt tree
and ZoinGallery, because `qmlimportscanner` reads that property from the
application target only and does not traverse it through linked imported
targets. That sentence is worth copying verbatim into anyone's notes: it is the
single most likely reason a static Qt Quick build links and then dies at
startup.

---

## 5. Dependency verdicts

| Dependency | Layer | Verdict |
|---|---|---|
| Qt Core/Gui/Qml/Quick/QuickControls2/Network/Svg | 1 | static — **but see the LGPL note in §7.6** |
| QWindowKit, ZoinGallery | 1 | static, built in-tree |
| libpng, libjpeg-turbo, libtiff, libwebp, libheif, libraw, jasper | 1 | static |
| msgpack-cxx | 1 | static, header-only-ish |
| libstdc++, libgcc | 1 | static (`-static-*`) |
| freetype, harfbuzz, icu, pcre2, zlib, zstd, brotli, xz | 1 | static, via Qt's graph |
| fontconfig | 1 | static — but it reads the **host's** font configuration at run time, which is the entire point (Layer 2) |
| glibc, libm, libdl, libpthread, librt | host | dynamic, ≤ 2.27 |
| libwayland, libxkbcommon, libX11/xcb, EGL/GL/Vulkan | 3 | `dlopen`ed or linked by Qt against the host — the irreducible graphics ABI |
| Fonts, icon theme, MIME db, CA store | 2 | host's, always |

---

## 6. Target configurations

| Name | Platform | Profile | Level | What it demonstrates |
|---|---|---|---|---|
| `f4-qt-linux` | Linux/amd64 | H (2.27) | 1 | **The headline.** One Go file; a static Qt Quick application inside it; no Qt, QML or plugin directory anywhere on the target. |
| `f4-qt-windows` | Windows/amd64 | H | 1 | One `.exe`; static CRT; only system DLLs imported. |
| `f4-qt-macos` | macOS/arm64+amd64 | — | 2 | Signed, notarised `.app` with bundled dynamic Qt frameworks. **Deliberately a different contract** (§7.10). |
| `f4-tty` | any | S | 1 | The Go core alone, `CGO_ENABLED=0`, no Qt. Already ships. |

---

## 7. Collisions with the doctrine, and what we decided

### 7.1 "One binary" survives two processes

f4 ships one file and runs two processes. Our documents have been sloppy about
the difference, and far2l already forced us to admit that a plugin host is "one
binary and its modules" (`04-REFERENCE-far2l.md §7.5`).

**Decision: the unit of the claim is the artifact the user downloads, not the
process table.** A second process that came out of the first one's own bytes, is
verified by hash before execution, and cannot be substituted by the host is not a
dependency. Level 1 language should say *downloaded artifact* everywhere it
currently implies *executable*.

### 7.2 They shipped `onebin pack` before we specified it

`DESIGN-onebin.md §7` describes appending a resource blob and extracting it to a
cache on first run as a low-priority v0.4 component. f4 has it in production,
with the parts we hand-waved actually solved: hash-addressed paths, atomic
rename, concurrency safety, upgrade separation, GC only when not running, and an
environment override for tests.

**Decision: `onebin pack`'s runtime half should be specified against this design,
not invented.** Add "a new payload hash must produce a new path" as a hard
requirement — it is the rule that prevents an upgraded application from silently
running yesterday's helper, and we did not have it.

### 7.3 Binary package caches are baseline-blind

The finding of the whole exercise. Conan's package ID captures os, arch,
compiler, version and build type — **not the glibc the package was built
against**. A cache hit therefore silently raises your baseline, and nothing in
the build fails; you find out from a user on Debian 10.

This generalises well beyond Conan: vcpkg binary caching, prebuilt CI toolchain
tarballs, and "just `apt install` the -dev package in the newer container" all
have the same hole.

**Decision: `01-SPEC-audit.md` gets an informational check** — when the audited
binary's highest `GLIBC_*` version comes from a *dependency* rather than from the
application's own objects, say so by name. And the manifesto's build-environment
section should state the rule directly: *the baseline applies to every object in
the artifact, not to the final link.*

### 7.4 A passing `readelf` audit does not prove a static Qt app runs

Our audit — and `tools/audit.sh` — check `DT_NEEDED`, symbol versions, RPATH,
PIE, RELRO. f4's Linux audit checks the same things (plus: no exported
`Qt*`/`QWindowKit*`/`ZoinGallery*` dynamic symbols). And then it **runs the
binary**:

```
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software f4-qt-host --f4-ext-connect=127.0.0.1:1 …
```

expects exit status 2 (disconnected), and greps the log for
`QQmlApplicationEngine failed to load component` and
`Could not find the Qt platform plugin`. A static Qt build that forgot a QML
module or a platform plugin passes every static check and then fails at startup.

**Decision: this is a gap in `03-TESTPLAN.md`, not a nicety.** Level 1 needs a
"the artifact starts and reaches a checkpoint" gate for GUI applications, and the
offscreen + software-rasteriser pair is the portable way to run it in CI. Their
policy says it in one sentence we should adopt: *never infer portability from a
successful link.*

### 7.5 Their baseline is 2.27; ours is 2.28

Ubuntu 18.04 versus RHEL 8. Both are defensible and the difference is one
distribution generation.

**Decision: nothing changes.** But the manifesto should stop presenting 2.28 as
*the* number and present it as *a* number with a table of what each baseline
buys, since a project's choice is driven by its oldest supported enterprise
target, not by our preference.

### 7.6 Static Qt and the LGPL

Their release gate 7 requires that *licence notices, corresponding sources, and
LGPL relinking material* be published when the Qt licence in use demands it —
which is exactly the obligation `DESIGN-onebin.md §11` row 6 flags and
`onebin release --emit-relink-objects` is meant to automate.

**Decision: f4-qt is the first concrete customer for that flag.** It should be
specified against a real Qt link line rather than in the abstract, and the doc
should say plainly: static Qt under LGPLv3 is legal and routine, and it is a CI
job you must actually run.

### 7.7 `CGO_ENABLED=0` can still `dlopen` — which contradicts our risk table

> **Consequence, confirmed by an actual far2l build attempt (see
> `STATUS.md`'s top note and `04-REFERENCE-far2l.md §6.1`): f4 is a
> dlopen *user*, which means f4/f4-qt must target Profile H, not Profile
> S.** Do not attempt a Profile S build of f4 or f4-qt expecting zero
> dlopen evidence from `onebin audit` — it will FAIL on OB0033 for the
> same structural reason far2l-tiny did, and re-discovering that is a
> waste of a session. Target Profile H from the start.

`DESIGN-onebin.md §11` row 1 says Profile S plus `dlopen` is impossible, because
a static musl binary has no dynamic loader. True for C. **Not a law of nature.**

f4's Go core is built `CGO_ENABLED=0` and audited to have *no* `PT_INTERP` and
*no* `DT_NEEDED` — and it still performs FFI, through `purego`/`pureffi` on top
of `goffi`, which supplies the runtime hooks the Go runtime needs (`fakecgo`
injecting `_cgo_init` and friends so `runtime.cgocall` works) and calls `dlopen`
itself. On macOS it drives AppKit through `objc_msgSend` with no Objective-C
compiler anywhere in the build.

And on Linux it opens windows **without libX11 and without libwayland-client**,
using pure-Go clients that speak the X11 and Wayland wire protocols over a
socket.

**Decision: amend row 1.** The correct statement is that *the C toolchain* gives
you no loader in a static binary, and that a runtime which carries its own FFI
machinery is a live counterexample. It is also the strongest evidence yet for the
manifesto's Layer 3 rule — the two display servers everyone links a client
library for turn out not to need one — and for
[FUTURE-IDEAS.md §1.3](./FUTURE-IDEAS.md), which argues exactly that and can now
cite a shipping program instead of a specification.

### 7.8 A private submodule breaks reproducibility for everyone else

`third_party/ZoinGallery` is pinned as a submodule at
`git@github.com:Zoinen/ZoinGallery.git`, branch `zoin/f4-integration`. It returns
404 to an anonymous clone, and CI supplies `secrets.SUBMODULE_SSH_KEY`.
`qt/host/CMakeLists.txt` hard-fails without it.

So: **today, nobody outside the project can reproduce the reference build.** That
is not a criticism of a work in progress, it is a blocker for using it as a
showcase, and it is a Level-0 problem in our own terms — an artifact whose
sources cannot be obtained cannot have a verifiable SBOM.

**Decision: the showcase needs one of** (a) ZoinGallery public, or (b) a
`-DF4_NO_GALLERY=ON` build path that produces a complete Qt host without it. Ask
upstream for (b) even if (a) is coming; a reference build that can lose a
dependency and still stand up is a better reference.

### 7.9 Source mirrors are a provenance question

The script rewrites fontconfig 2.15.0's download URL to a MacPorts mirror because
`www.freedesktop.org` answers GitHub-hosted runners with HTTP 418, and notes that
the Conan Center SHA-256 remains authoritative.

Correct handling, and worth generalising: **a mirror is fine when the hash is
pinned elsewhere; a mirror without a pinned hash is a supply-chain incident
waiting to be written up.** `contrib/*/deps.lock` should carry hashes for exactly
this reason, and `--no-fetch` should remain a hard error rather than a fallback.

### 7.10 macOS is a different contract on purpose

No extraction to a cache; bundled dynamic Qt frameworks preferred over static;
nested code signed in order, then the bundle, then notarisation, then Gatekeeper
verification. Their policy says static Qt is permitted on macOS only when it
*demonstrably simplifies the signed bundle*, and is explicitly **not** a
portability requirement, because Apple's own frameworks are dynamic anyway.

**Decision: adopt this framing.** Our documents treat "one file" as the goal on
every platform. On macOS the right unit is the signed bundle, and pretending
otherwise produces advice that fails notarisation.

---

## 8. What `onebin audit` must say

For `f4` (the Go launcher, Linux):

- no `PT_INTERP`, no `DT_NEEDED` → Profile S, Level 1;
- Go binaries are not PIE by default with these flags — report it, do not fail
  the profile on it, and say what enabling it would cost;
- `.note.go.buildid` present → identify the toolchain in the report.

For `f4-qt-host` (Linux, before it is embedded):

- `DT_NEEDED` ⊆ the Profile H set; **specifically** no `libQt6*`, no
  `libstdc++`, no `libgcc_s`, no codec libraries;
- highest `GLIBC_*` ≤ 2.27, and if it comes from a dependency, name it (§7.3);
- no `RPATH`/`RUNPATH`;
- no exported `Qt*` / `QWindowKit*` / `ZoinGallery*` dynamic symbols;
- RELRO + BIND_NOW + noexecstack present.

For the release artifact: the directory contains exactly one file.

---

## 9. `tools/build-f4-qt.sh` — required interface

Same shape as `tools/build-far2l.sh` (`04-REFERENCE-far2l.md §10`):

```
tools/build-f4-qt.sh --config linux|windows --src DIR --out DIR
                     [--print-plan] [--no-fetch] [--pin COMMIT]
```

- reads pinned versions from `contrib/f4-qt/deps.lock` (Qt, codecs, QWindowKit,
  Go, Conan, CMake, Ninja — with hashes, §7.9);
- refuses to run without the ZoinGallery pin resolved, and says which of the two
  fixes in §7.8 the user needs;
- `--print-plan` prints every command without running one;
- `--no-fetch` makes network access a hard error;
- audits every artifact it produced, then runs the offscreen smoke test from
  §7.4 and fails on its greps;
- never invents build flags: it drives the project's own `ci/` scripts where they
  exist, so that our build cannot drift from theirs silently.

---

## 10. Provenance, and how to re-verify

Everything in this document came from these files at the pin in §2:

```
docs/PORTABLE_BUILD_POLICY.md     the product contract, per-OS contracts, CI gates
qt/host/README.md                 build steps, icon sets, ExtUI lookup order
qt/host/CMakeLists.txt            Qt components, static assertions, flags, QML paths
qt/host/conanfile.py              dependency graph, options, macOS validate()
ci/build-portable-qt-linux.sh     the 18.04 guard, rebuild list, fontconfig mirror
ci/audit-portable-qt-linux.sh     the Linux audit
ci/audit-static-go-linux.sh       the Go launcher audit
ci/audit-portable-qt-windows.ps1  the Windows import audit
ci/package-embedded-qt-host.py    the deterministic payload
embedded_qt_host.go               the content-addressed cache
.github/workflows/build.yml       the portable-qt matrix and the submodule secret
go.mod                            purego → pureffi, and the pure-Go X11/Wayland clients
```

Re-verify with `git -C <fork> show <pin>:<path>`. If a fact here disagrees with
the tree, the tree is right and this document is stale — say so in your report,
as with far2l.
