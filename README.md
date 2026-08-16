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
| **[tools/audit.sh](./tools/audit.sh)** | A 30-line shell audit you can drop into CI today, before any of the above exists. |

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

> `zig cc` is a Clang distribution that bundles headers and stubs for musl *and every glibc version*. You don't have to write a line of Zig — it replaces the "keep a CentOS 7 container as a build environment" ritual with a command-line flag.

---

## Conformance levels

| Level | Name | Requirement |
|---|---|---|
| **0** | Baseline Pinned | Declared and verified libc baseline; no accidental `DT_NEEDED` |
| **1** | Self-Contained | One file; all non-host libraries static; passes the distro matrix; PIE + RELRO + BIND_NOW |
| **2** | Self-Installing | First-run integration into `~/.local`; clean `--uninstall`; **never requires root** |
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
├── tools/
│   └── audit.sh             shell audit — works today, no build required
└── onebin/                  (planned) the toolkit itself
    ├── cli/                 onebin audit | sign | release | pack
    ├── lib/                 libonebin — host brokers, paths, desktop, update
    ├── toolchain/           CMake toolchain files, Meson cross files
    └── ci/                  GitHub Action + distro test matrix
```

---

## Status

**Draft 0.1 — in development.** Implementation of `onebin audit` is underway; `tools/audit.sh` is a stopgap that already does the most valuable check.

Roadmap (see [DESIGN-onebin.md §10](./DESIGN-onebin.md)):

- [ ] **v0.1 "Prove it"** — `onebin audit` for ELF, Level 0/1 checks, JSON output, GitHub Action, distro test matrix
- [ ] **v0.2 "Load it"** — `ob_host_*` GL/Vulkan/audio brokers with real diagnostics, `ob_paths_*`
- [ ] **v0.3 "Ship it"** — `ob_update_*`: signed manifests, atomic install, canary rollback, deltas
- [ ] **v0.4 "Belong"** — desktop integration, Windows/macOS audit backends
- [ ] **v1.0** — API freeze, testable conformance spec, five real projects at Level 3

The linter comes first deliberately: it costs a project nothing to try, and it finds real bugs in projects that never adopt anything else here.

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
