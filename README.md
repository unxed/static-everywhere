# Static Everywhere

**One binary. Any Linux. No containers.**

[![Manifesto](https://img.shields.io/badge/read-the%20manifesto-1f6feb)](./STATIC-EVERYWHERE.md)
[![Status](https://img.shields.io/badge/status-draft%200.1-orange)](#status)
[![License: CC0](https://img.shields.io/badge/docs-CC0-lightgrey)](#license)

> C was invented to make Unix portable.
> Today the C ecosystem produces portable binaries everywhere **except** Unix.

Windows lets you ship one `.exe` and has for thirty years. macOS gives you one versioned system library and a deployment target. Go gives you one static binary — and Turbo Pascal did the same in 1985.

Linux gives you `GLIBC_2.38 not found`, six package formats, a 300 MB Flatpak to ship a text editor, and — eventually — Electron.

**None of that is a property of Linux. It's a habit.** This repository is an argument that we can stop, plus the tooling to make stopping cheap.

---

## The doctrine

> **Ship your code. Borrow the host's data. Talk to the host by protocol, not by ABI.**

Every dependency you have is exactly one of three things. Sort them correctly and the problem dissolves:

| Layer | What | Where it lives |
|---|---|---|
| **1. Code** | zlib, OpenSSL, FreeType, your toolkit, your runtime | **Static, inside your binary.** You chose the version; you own it. |
| **2. Data** | fonts, CA certificates, icon themes, locales, MIME db | **The host's.** Read at runtime from XDG/FHS paths. This is what makes your app look native. |
| **3. Services & devices** | display, audio, IPC, file dialogs, GPU | **Protocol first** (Wayland, D-Bus, portals). `dlopen` only where physics demands it — about ten sonames, all GPU/audio. |

Flatpak, Snap and Docker apply Layer-1 thinking to Layers 2 and 3: they ship a userland to compensate for our inability to ship an executable, then spend years punching holes back through the wall. **The bundle isn't the problem. Bundling the wrong layer is.**

---

## Start here

| Document | What it is |
|---|---|
| **[STATIC-EVERYWHERE.md](./STATIC-EVERYWHERE.md)** | The manifesto. The argument, the two build profiles, recipes for CMake/Meson/Autotools, a cheat sheet for ~30 popular libraries, Windows/macOS, verification, self-updating, and honest answers to the objections. **Start here.** |
| **[DESIGN-onebin.md](./DESIGN-onebin.md)** | Design doc for `onebin` — the toolkit that turns the manifesto into a `find_package`: a conformance linter, a host-contract `dlopen` broker, desktop integration, and signed self-updates. |
| **[CONFORMING.md](./CONFORMING.md)** | Projects that conform, and at what level. Add yours. |
| **[05-REFERENCE-f4-qt.md](./05-REFERENCE-f4-qt.md)** | The Qt reference application. Everything about [f4-qt](https://github.com/Zoinen/f4/tree/zoin) — a static Qt Quick front end inside a single Go executable — and the five places it corrected us. |
| **[04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md)** | The reference application. Everything about building [far2l](https://github.com/elfmz/far2l) — a real file manager with three UI backends, a plugin ABI and a copyleft licence — under this doctrine, and every place it made the doctrine more specific. |
| **[tools/audit.sh](./tools/audit.sh)** | A 30-line shell audit you can drop into CI today, before any of the above exists. |
| **[FUTURE-IDEAS.md](./FUTURE-IDEAS.md)** | Speculation, clearly labelled as such. Currently: could one binary per *architecture* replace one binary per *operating system*? Nothing here is scheduled; arguments against are the point. |

---

## Quick start

Two profiles. Pick by whether you need `dlopen`.

**Profile S — fully static.** CLI tools, daemons, servers. Zero host dependencies, runs on `FROM scratch`.

```bash
zig cc -target x86_64-linux-musl -O2 -static-pie \
       -ffunction-sections -fdata-sections -Wl,--gc-sections \
       -o myapp *.c

ldd myapp            # → "not a dynamic executable"
```

**Profile H — hybrid.** GUI apps, games, anything touching a GPU. Pinned libc baseline, everything else static, host contract via `dlopen`.

```bash
zig cc -target x86_64-linux-gnu.2.28 -O2 \
       -static-libstdc++ -static-libgcc \
       -Wl,--as-needed -Wl,--exclude-libs,ALL \
       -Wl,-z,relro,-z,now -Wl,-z,noexecstack \
       -o myapp ...
```

Allowed `DT_NEEDED` in Profile H, and nothing else:

```
ld-linux-x86-64.so.2   libc.so.6   libm.so.6
libdl.so.2   libpthread.so.0   librt.so.1
```

**Then prove it:**

```bash
./tools/audit.sh ./myapp 2.28
```

Both profiles produce one file. The user never learns which one you picked.

**And it goes in `~/Apps`.** Windows has `%LOCALAPPDATA%\Programs`, macOS has
`~/Applications`, Linux has nothing — so every project invents something, usually
hidden. Static Everywhere applications install to `~/Apps/<App>`: visible, not
localised, one directory per application, with an optional symlink in
`~/.local/bin` for `$PATH`. The rules are in
[STATIC-EVERYWHERE.md §7.2](./STATIC-EVERYWHERE.md#72-where-it-lives-apps).

> `zig cc` is a Clang distribution that bundles headers and stubs for musl *and every glibc version*. You don't have to write a line of Zig — it replaces the "keep a CentOS 7 container as a build environment" ritual with a command-line flag.

---

## The reference application: far2l

A manifesto that has only ever been tested on its own linter is a blog post. So this project has a standing obligation: **[far2l](https://github.com/elfmz/far2l) must build with our tooling, in every one of its UI modes.**

far2l is a Linux fork of FAR Manager v2 — a two-panel file manager that runs in a bare terminal, in a terminal with X11 clipboard integration, and as a desktop application through either wxWidgets or SDL. It has a plugin ABI, a helper process, ~15 optional third-party libraries, host data it must read to look native, external programs it shells out to, and a GPLv2 licence. It is, in other words, everything the "just static-link it" advice usually gets waved at and then quietly dropped.

Full detail — architecture, the complete option table, the dependency verdicts, the licence traps, and the list of things far2l has already forced us to change — is in **[04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md)**.

### The four configurations

| Name | Profile | Target level | What it demonstrates |
|---|---|---|---|
| `far2l-tiny` | S | 1 | Terminal-only, no plugins. One musl static-PIE file, runs on `FROM scratch`. The thing you scp onto a 2014 server. |
| `far2l-tty` | H | 1 | Full plugin set as `$ORIGIN`-relative modules, X11 clipboard through a helper process. |
| `far2l-sdl` | H | 1 | **The headline.** A graphical file manager with no toolkit on the target: SDL `dlopen`s X11/Wayland/GL itself, FreeType and HarfBuzz are static, and fontconfig reads the *host's* fonts so the text looks native. |
| `far2l-wx` | H | 0 only | Built to fail, on purpose. GTK arrives through wxWidgets and cannot be bundled. We publish its `DT_NEEDED` list instead of asserting that GTK is a problem. |

### Building it

```bash
# 1. the latest stable far2l — releases are tagged v_X.Y.Z, master is unstable
TAG=$(git ls-remote --tags --refs https://github.com/elfmz/far2l 'refs/tags/v_*' \
      | awk -F/ '{print $NF}' | sort -V | tail -1)
echo "$TAG"                    # v_2.8.0 at the time of writing

git clone --depth 1 --branch "$TAG" https://github.com/elfmz/far2l far2l-src

# 2. build it with our toolchain
./tools/build-far2l.sh --config sdl --src ./far2l-src --out ./out/far2l-sdl

# 3. prove it
./tools/audit.sh ./out/far2l-sdl/far2l 2.28
```

Clone the **tag**, not a commit and not a tarball: far2l's CMake runs `git describe --tag` and appends a date and hash to its version string when it doesn't land exactly on a release, which makes the build non-reproducible.

`build-far2l.sh` is a thin wrapper: it reads pinned dependency versions from `contrib/far2l/deps.lock`, builds the static third-party libraries, configures far2l with `onebin`'s CMake toolchain file, and audits every artifact it produced. `--print-plan` prints every command it would run without running any of them; `--no-fetch` makes network access a hard error.

> **Status.** `tools/audit.sh` works today. `tools/build-far2l.sh`, the toolchain files and `contrib/far2l/` are specified in [04-REFERENCE-far2l.md §10](./04-REFERENCE-far2l.md#10-toolsbuild-far2lsh--required-interface) and [00-AGENT-TASK.md](./00-AGENT-TASK.md), and are not written yet. Until they are, the manual `cmake` invocations in [04-REFERENCE-far2l.md §6](./04-REFERENCE-far2l.md#6-target-configurations) are what a person would type by hand.

## The Qt reference application: f4-qt

far2l answers "can a C++ application with plugins and three UI backends ship this
way?". It does not answer "what does a **static Qt** cost?" — the question every
project asks the moment GTK is ruled out.

**[f4-qt](https://github.com/Zoinen/f4/tree/zoin)** answers that one. It is a Go
file manager with a Qt Quick front end, and its Linux and Windows downloads are
**one executable** with a fully static Qt — QML modules, shaders, platform
plugins and codecs inside the binary — gzipped into the Go launcher and unpacked
to a hash-addressed cache on first use.

It also arrived at this doctrine on its own, wrote it down in
`docs/PORTABLE_BUILD_POLICY.md`, and enforces it in CI with an audit script and a
glibc 2.27 baseline. Its link line is our Profile H, flag for flag, derived
independently. So it is evidence, and the interesting part is where it corrects
us — five things, all in
[05-REFERENCE-f4-qt.md §7](./05-REFERENCE-f4-qt.md#7-collisions-with-the-doctrine-and-what-we-decided):

- **A binary package cache is baseline-blind.** Conan package IDs do not encode
  the glibc a package was built against, so a cache hit silently raises your
  baseline and nothing fails. The baseline applies to every object in the
  artifact, not to the final link.
- **A passing `readelf` audit does not prove a static Qt application runs.** It
  can link cleanly and then die because a QML module or platform plugin was never
  embedded. Their CI runs the binary offscreen with a software rasteriser and
  greps for exactly that. Our test plan did not.
- **`CGO_ENABLED=0` still does FFI.** Their Go launcher has no interpreter and no
  `DT_NEEDED`, and still `dlopen`s — and opens X11 and Wayland windows with no
  client library at all, by speaking the wire protocols. Our "Profile S cannot
  `dlopen`" risk is a fact about the C toolchain, not about static binaries.
- **On macOS the unit is the signed bundle, not one file.** Chasing "one file"
  there produces advice that fails notarisation.
- **Two processes, one artifact.** The claim is about what the user downloads.

### Why we let a build target dictate the design

Because it already has. Before a single far2l object file was compiled, the exercise had found a linker flag in our own Quick Start that breaks any application with a plugin ABI, and a rule in our own audit spec that would report every one of far2l's plugins as a broken executable. Both are fixed. A reference application that never embarrasses the manifesto isn't doing its job.

---

## Conformance levels

| Level | Name | Requirement |
|---|---|---|
| **0** | Baseline Pinned | Declared and verified libc baseline; no accidental `DT_NEEDED` |
| **1** | Self-Contained | One file; all non-host libraries static; passes the distro matrix; PIE + RELRO + BIND_NOW |
| **2** | Self-Installing | Installs into `~/Apps`; first-run integration into `~/.local`; clean `--uninstall`; **never requires root** |
| **3** | Self-Updating | Signed, atomic, rollback-capable updates; published SBOM; updater disables itself under a package manager |

```markdown
![Static Everywhere Level 1](https://img.shields.io/badge/Static%20Everywhere-Level%201-1f6feb)
```

---

## Repository layout

```
.
├── STATIC-EVERYWHERE.md     the manifesto
├── DESIGN-onebin.md         design doc for the toolkit
├── CONFORMING.md            projects that conform
├── 00-AGENT-TASK.md         the implementation brief
├── 01-SPEC-audit.md         `onebin audit` v0.1 specification
├── 02-REFERENCE-elf.md      ELF reference — no internet required
├── 03-TESTPLAN.md           the test plan
├── 04-REFERENCE-far2l.md    the reference application — no internet required
├── 05-REFERENCE-f4-qt.md    the Qt reference application — no internet required
├── FUTURE-IDEAS.md          speculative, unscheduled, argue with it
├── tools/
│   ├── audit.sh             shell audit — works today, no build required
│   └── build-far2l.sh       (planned) the reference build
├── contrib/
│   ├── far2l/               (planned) deps.lock, patches, upstream proposals
│   └── f4-qt/               (planned) deps.lock and the ZoinGallery question
└── onebin/                  the toolkit itself
    ├── cli/                 onebin audit | sign | release | pack
    ├── lib/                 libonebin — host brokers, paths, desktop, update
    ├── toolchain/           CMake toolchain files, Meson cross files
    └── ci/                  GitHub Action + distro test matrix
```

---

## Status

**Draft 0.1 — in development.** Implementation of `onebin audit` is underway; `tools/audit.sh` is a stopgap that already does the most valuable check.

Roadmap (see [DESIGN-onebin.md §10](./DESIGN-onebin.md)):

- [ ] **v0.1 "Prove it"** — `onebin audit` for ELF, Level 0/1 checks, JSON output, GitHub Action, distro test matrix, and the CMake toolchain files plus `tools/build-far2l.sh` that build the reference application
- [ ] **v0.2 "Load it"** — `ob_host_*` GL/Vulkan/audio brokers with real diagnostics, `ob_paths_*`
- [ ] **v0.3 "Ship it"** — `ob_update_*`: signed manifests, atomic install, canary rollback, deltas
- [ ] **v0.4 "Belong"** — desktop integration, Windows/macOS audit backends
- [ ] **v1.0** — API freeze, testable conformance spec, five real projects at Level 3

The linter comes first deliberately: it costs a project nothing to try, and it finds real bugs in projects that never adopt anything else here. The far2l build comes second, in the same milestone, because a linter with nothing real to lint is a toy.

---

## This is not a war on distributions

It isn't, and the manifesto has [a whole section](./STATIC-EVERYWHERE.md#10-a-note-to-distribution-maintainers) saying so. A conforming project commits to keeping a plain source build against system libraries, publishing an SBOM, building reproducibly, and **automatically disabling its self-updater when installed system-wide by a package manager**.

Two channels, one codebase. Users who want their distribution's release get it. Users who need today's fix today get that.

---

## Contributing

- **Disagree?** Open an issue. Every objection in [§8](./STATIC-EVERYWHERE.md#8-objections-honestly-answered) got better because someone argued with it. The CVE/security objection in particular deserves more scrutiny, not less.
- **Conform?** Open a PR adding your project to [CONFORMING.md](./CONFORMING.md) with its level and a link to its CI audit.
- **Know a soname we missed?** The host contract is a data file, not code. PRs welcome.
- **Want to build it?** v0.1 is a self-contained ELF linter in C with no dependencies — a good first contribution.

---

## Prior art

[Turbo Pascal / Free Pascal](https://www.freepascal.org/) · [Go](https://go.dev/) · [Cosmopolitan Libc](https://justine.lol/cosmopolitan/) · [musl](https://musl.libc.org/) · [Zig](https://ziglang.org/) · [SDL](https://libsdl.org/) · [XDG Desktop Portals](https://flatpak.github.io/xdg-desktop-portal/) · and [UTF-8 Everywhere](https://utf8everywhere.org/), for showing that a document can change an ecosystem's defaults without anyone's permission.

---

## License

Documents: **CC0** — copy, fork, translate, quote in your README without asking.
Code (when it exists): **MIT or Apache-2.0**. A project that preaches static linking cannot itself impose relinking obligations.
