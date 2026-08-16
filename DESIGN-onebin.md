# `onebin` — Design Document

**A toolkit that makes the [Static Everywhere](./STATIC-EVERYWHERE.md) manifesto a `find_package` away.**

Status: design draft, no code written yet.
Target languages: C11 (library, public ABI), C++17 permitted internally, Go or Rust acceptable for the CLI.
License: **MIT or Apache-2.0 only** — a library that preaches static linking cannot itself impose relinking obligations. This is a hard constraint, not a preference.

---

## 0. Why this exists

The manifesto asks developers to do six things:

1. pin a libc baseline and prove it,
2. link everything else statically,
3. `dlopen` the host contract with graceful fallback,
4. read host data (fonts, CA certs, themes) from the right places,
5. integrate into the desktop without root,
6. update themselves, signed and atomically.

Items 1 and 2 are build flags. Items 3–6 are each 500–2000 lines of fiddly, security-sensitive, easy-to-get-subtly-wrong code that every project currently reimplements badly or skips entirely. **That reimplementation cost is the actual reason people reach for Flatpak.**

`onebin` exists to make items 3–6 a dependency instead of a project.

### Non-goals

- **Not a package manager.** No repositories, no dependency resolution, no global state.
- **Not a sandbox.** Sandboxing is the OS's job (portals, bubblewrap, seccomp). We do not confine the app.
- **Not a build system.** We ship toolchain files and a linter, and we cooperate with CMake/Meson/Autotools rather than replacing them.
- **Not a compatibility shim.** We do not ship a libc, a loader, or emulation. If a thing genuinely cannot be bundled, we say so and load it from the host.
- **Not a GUI toolkit.** We sit *under* SDL/Qt/your own, not beside it.

---

## 1. Architecture

```
onebin/
├── cli/            onebin — audit, doctor, sign, release, pack   (host-side tool)
├── lib/            libonebin — runtime library linked into the app
│   ├── host/       ob_host_*   dlopen brokers for the host contract
│   ├── paths/      ob_paths_*  host data discovery (Layer 2)
│   ├── desktop/    ob_desktop_* first-run integration & uninstall
│   └── update/     ob_update_*  signed, atomic, resumable self-update
├── toolchain/      CMake toolchain files, Meson cross files, zig-cc wrappers
├── ci/             GitHub Action + reusable test matrix
└── spec/           update manifest schema, signature format, conformance spec
```

Four independent pieces. **Every one must be usable alone.** A project that only wants the audit tool must not be forced to link a runtime; a project that only wants self-update must not inherit the desktop integration code. This is a hard modularity requirement — the failure mode of tools in this space is becoming a framework.

### Size budget

| Component | Budget (stripped, x86_64, `--gc-sections`) |
|---|---|
| `libonebin` host brokers | ≤ 40 KB |
| paths | ≤ 15 KB |
| desktop | ≤ 30 KB |
| update (incl. Ed25519 + BLAKE3 + zstd decode) | ≤ 250 KB |
| **Total, all features** | **≤ 350 KB** |

If we exceed this, we have become the thing we are replacing. Budgets are enforced by a CI test.

### Dependency policy

`libonebin` may depend on: **libc, and nothing else.**

Crypto is vendored as single-file public-domain/permissive implementations (`monocypher` or TweetNaCl-style Ed25519, reference BLAKE3). zstd decompression is optional and behind `ONEBIN_DELTA=ON`; if the app already links zstd, we use theirs. TLS for the update channel is **not** ours: the app passes in a fetch callback (§5.4), so `libonebin` never imposes an HTTP or TLS stack. This also means the update logic can be unit-tested with a stub transport and no network.

---

## 2. `onebin audit` — the conformance linter

The most important component, and the one to build first: **it delivers value on day one to projects that adopt nothing else.**

```
onebin audit ./build/myapp \
    --profile hybrid \
    --glibc-max 2.28 \
    --level 1 \
    --format json
```

### Checks (Linux / ELF)

| # | Check | Level | Failure |
|---|---|---|---|
| 1 | `DT_NEEDED` ⊆ allowlist for the profile | 0 | error |
| 2 | Highest `GLIBC_x.y` versioned symbol ≤ `--glibc-max` | 0 | error, lists offending symbols and the objects that pulled them |
| 3 | Profile S: no `PT_INTERP`, no `DT_NEEDED`, `ET_DYN` (static-pie) | 1 | error |
| 4 | Profile S: no reference to `dlopen`/`dlsym` (they are stubs in static musl) | 1 | error |
| 5 | No `DT_RPATH`/`DT_RUNPATH`, or `$ORIGIN`-relative only | 1 | error |
| 6 | `GNU_RELRO` present and `BIND_NOW` set | 1 | error |
| 7 | `GNU_STACK` is RW, not RWX | 1 | error |
| 8 | PIE (`ET_DYN` with `DT_FLAGS_1 & DF_1_PIE`) | 1 | warn |
| 9 | No build-machine absolute paths in `.rodata` (`/home/`, `/build/`, `/Users/`) | 1 | warn |
| 10 | No hardcoded distro library paths (`/usr/lib/x86_64-linux-gnu/...`) | 1 | warn |
| 11 | Report `dlopen`'d host-contract sonames found in strings; flag any outside the known contract | 1 | warn |
| 12 | Warn on `memcpy@GLIBC_2.14` (use `2.2.5` alias) and other gratuitous version bumps | 0 | warn |
| 13 | Static glibc detected (`__libc_start_main` static + NSS symbols) → hard error | 0 | error |
| 14 | Debug info stripped; separate `.debug` file present next to it | 1 | info |
| 15 | SBOM (`sbom.cdx.json`) present alongside the artifact | 3 | error at L3 |
| 16 | Binary size delta vs. previous release exceeds threshold | — | info |

### Checks (Windows / PE)

- Imports ⊆ baseline: no `VCRUNTIME140.dll`, `MSVCP140.dll`, `MSVCR*.dll`
- All imported `api-ms-win-*` and `kernel32` ordinals available in the declared `_WIN32_WINNT` baseline (against a bundled API-version database)
- `/DYNAMICBASE`, `/NXCOMPAT`, `/HIGHENTROPYVA`, CFG enabled
- Authenticode signature present at Level 3

### Checks (macOS / Mach-O)

- `LC_LOAD_DYLIB` ⊆ `/usr/lib/libSystem.B.dylib` + `/System/Library/Frameworks/*`
- `LC_BUILD_VERSION.minos` ≤ declared deployment target
- Universal binary contains all declared architectures
- Hardened runtime + notarization ticket at Level 3

### Interface

- Exit code `0` pass / `1` fail / `2` warnings-only (with `--strict`, warnings fail).
- `--format json` emits a stable schema for CI consumption.
- `--baseline baseline.json` records an accepted state so new violations fail but existing ones don't block adoption — **this is essential for incremental adoption of legacy projects.**

### Implementation notes

Parse ELF/PE/Mach-O directly. Do **not** shell out to `readelf`/`otool` — the tool must run on a machine that isn't the target platform, and must be a single static binary itself (dogfooding is non-negotiable: `onebin audit onebin` must pass at Level 1).

---

## 3. `ob_host_*` — the host contract broker

### Problem

Every project that draws a triangle writes the same 300 lines: try `libGL.so.1`, fall back to `libGL.so`, then `libEGL.so.1`, resolve 40 function pointers, handle the case where the user has no GPU, don't crash on a headless CI machine, and produce an error message better than `NULL`.

### API sketch

```c
#include <onebin/host.h>

typedef enum {
    OB_HOST_GL, OB_HOST_GLES, OB_HOST_EGL, OB_HOST_GLX,
    OB_HOST_VULKAN, OB_HOST_CUDA, OB_HOST_OPENCL,
    OB_HOST_VAAPI, OB_HOST_VDPAU,
    OB_HOST_ALSA, OB_HOST_PULSE, OB_HOST_PIPEWIRE, OB_HOST_JACK,
    OB_HOST_UDEV,
} ob_host_id;

typedef struct ob_host ob_host;

/* Try each candidate soname in order; NULL if none load.
   Thread-safe, idempotent, refcounted. Never aborts. */
ob_host *ob_host_open(ob_host_id id, ob_error *err);

void    *ob_host_sym(ob_host *h, const char *name);
int      ob_host_syms(ob_host *h, const char *const *names, void **out, size_t n);
void     ob_host_close(ob_host *h);

/* Probe without committing — for capability UIs and diagnostics. */
bool     ob_host_available(ob_host_id id);

/* Human-readable, actionable. Not "dlopen failed". */
const char *ob_host_diagnose(ob_host_id id);
```

### Behaviour

- **Candidate lists are data, not code**, in `spec/host-contract.toml`, so a new soname is a table entry and a patch release rather than a code change:

```toml
[gl]
sonames = ["libGL.so.1", "libGL.so", "libOpenGL.so.0"]
probe   = "glXGetProcAddressARB"

[vulkan]
sonames = ["libvulkan.so.1", "libvulkan.so", "libMoltenVK.dylib"]
probe   = "vkGetInstanceProcAddr"

[audio]
order = ["pipewire", "pulse", "alsa", "jack"]
```

- **Fallback chains, not single attempts.** Audio in particular: PipeWire → PulseAudio → ALSA → null sink. The app asks for "audio output", not for "PulseAudio".
- **`RTLD_LOCAL | RTLD_NOW`** by default. `RTLD_GLOBAL` is opt-in and documented as dangerous, since it lets a host library's symbols collide with your statically-linked copies of the same library — a subtle and vicious failure mode.
- **Diagnosis is a feature.** `ob_host_diagnose(OB_HOST_VULKAN)` returns something like *"libvulkan.so.1 loaded, but vkEnumeratePhysicalDevices found 0 devices. No ICD JSON in /usr/share/vulkan/icd.d. Install your GPU vendor's Vulkan driver package."* Half of "it doesn't work on Linux" bug reports are this message not existing.
- **Profile S build**: compiles to stubs that always return `NULL` plus a compile-time warning. It must be possible to write one codebase that builds in both profiles.

### Ready-made loaders

Ship optional generated headers (`onebin/gl.h`, `onebin/vk.h`) with the full function-pointer tables, so a project can replace glad/volk with one dependency. These are generated from the Khronos XML at build time — we do not hand-maintain them.

---

## 4. `ob_paths_*` — Layer 2 host data discovery

Small, boring, and the difference between "native" and "foreign".

```c
/* Returns a path, or NULL. Caller does not free (interned). */
const char *ob_paths_ca_bundle(void);        /* CA certs — probes 6 known locations */
const char *ob_paths_ca_dir(void);
int         ob_paths_font_dirs(const char **out, size_t n);
int         ob_paths_icon_dirs(const char **out, size_t n);
const char *ob_paths_xdg(ob_xdg_kind kind);  /* CONFIG_HOME, DATA_HOME, CACHE_HOME, RUNTIME_DIR, STATE_HOME */
const char *ob_paths_self_exe(void);         /* realpath(/proc/self/exe), or platform equivalent */
const char *ob_paths_self_dir(void);
bool        ob_paths_is_system_managed(void);/* under /usr, /opt, /nix/store, root-owned, not user-writable */
const char *ob_paths_desktop_env(void);      /* "GNOME", "KDE", "sway", ... best effort */
bool        ob_paths_is_wayland(void);
```

CA bundle probe order (first hit wins): `$SSL_CERT_FILE` → `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu/Alpine) → `/etc/pki/tls/certs/ca-bundle.crt` (RHEL/Fedora) → `/etc/ssl/ca-bundle.pem` (SUSE) → `/etc/ssl/cert.pem` (Alpine/BSD/macOS) → `/system/etc/security/cacerts` (Android) → embedded fallback bundle if the app opted in.

`ob_paths_is_system_managed()` is load-bearing: it gates the self-updater (§5.7) and the desktop integration (§6). Getting it wrong means fighting the user's package manager, which is the fastest way to make this whole idea unwelcome.

---

## 5. `ob_update_*` — signed self-update

The security-critical component. Design it as if it will be attacked, because it will be.

### 5.1 Threat model

Defended against:
- **Malicious CDN / MITM** → signature verification with an embedded public key, independent of TLS.
- **Rollback to a known-vulnerable version** → monotonic `sequence` + manifest `expires`.
- **Freeze attack** (withholding updates silently) → manifest expiry; the app surfaces "no successful update check in N days".
- **Partial/corrupt download** → BLAKE3 over the full artifact, verified before install.
- **Mixed-platform artifact substitution** → platform, arch and profile are inside the signed manifest.
- **Interrupted install** → atomic rename; power loss leaves either old or new, never a truncated binary.
- **Bad release** → first-run canary + automatic rollback.

Explicitly out of scope:
- Compromise of the signing key itself → mitigated organizationally (offline key, rotation via a root key set, §5.3).
- Malicious local user with write access to the install directory → they can already replace the binary.

### 5.2 Update manifest

```json
{
  "schema": 1,
  "product": "com.example.app",
  "channel": "stable",
  "sequence": 412,
  "published": "2026-08-16T09:00:00Z",
  "expires":   "2026-09-16T09:00:00Z",
  "releases": [
    {
      "version": "3.4.1",
      "platform": "linux",
      "arch": "x86_64",
      "profile": "hybrid",
      "min_glibc": "2.28",
      "min_kernel": "3.10",
      "size": 24117248,
      "blake3": "b1946ac9…",
      "url": "https://dl.example.com/app-3.4.1-linux-x86_64",
      "notes_url": "https://example.com/changelog#3.4.1",
      "patches": [
        { "from": "3.4.0", "algo": "zstd-patch-from",
          "size": 913408, "blake3": "5891b5b5…",
          "url": "https://dl.example.com/patch-3.4.0-3.4.1-x86_64.zst" }
      ]
    }
  ]
}
```

Signed with a **detached minisign-format Ed25519 signature** over the exact bytes of the manifest file. We deliberately reuse minisign's format so releases can be signed with existing tooling and audited by third parties, and so `onebin sign` is a convenience rather than a lock-in.

### 5.3 Key handling

- The binary embeds a **root key set** (2–3 Ed25519 public keys, offline, long-lived).
- The root keys sign a short-lived **signing key delegation** (a small signed document with an expiry).
- The signing key signs manifests. Rotation is a delegation change, not a client update.
- Deliberately TUF-shaped but far smaller. If a project needs full TUF, it should use TUF; we cover the 95% case in ~600 lines.

### 5.4 API

```c
typedef struct {
    const char *product_id;
    const char *current_version;
    const char *manifest_url;
    const char *channel;                 /* "stable" | "beta" | ... */
    const uint8_t (*root_keys)[32];
    size_t      root_key_count;

    /* The app supplies transport. libonebin never links an HTTP or TLS stack. */
    ob_fetch_fn fetch;
    void       *fetch_ctx;

    bool        allow_delta;
    bool        check_on_start;
    unsigned    check_interval_hours;
} ob_update_config;

ob_update *ob_update_init(const ob_update_config *cfg, ob_error *err);

/* Non-blocking; results delivered on the caller's thread via ob_update_poll(). */
void       ob_update_check_async(ob_update *u);
ob_update_state ob_update_poll(ob_update *u, ob_update_info *out);

int        ob_update_download(ob_update *u, ob_progress_fn cb, void *ctx);
int        ob_update_stage(ob_update *u);      /* verify + write next to current binary */
int        ob_update_apply(ob_update *u);      /* atomic rename; takes effect next launch */
int        ob_update_apply_and_restart(ob_update *u, int argc, char **argv);
int        ob_update_rollback(ob_update *u);

void       ob_update_mark_healthy(ob_update *u);  /* first-run canary; see 5.6 */
```

**The app owns the UX.** `libonebin` never draws a dialog, never restarts the app without being told to, and never applies an update behind the user's back unless the app explicitly configures that. Auto-updaters that seize control are the reason people distrust auto-updaters.

### 5.5 Atomic install algorithm (Linux)

```
1.  self  = realpath("/proc/self/exe")
2.  dir   = dirname(self)
3.  if ob_paths_is_system_managed() → refuse, return OB_ERR_SYSTEM_MANAGED
4.  if access(dir, W_OK) != 0       → refuse, return OB_ERR_NOT_WRITABLE
5.  fd = open(dir, O_TMPFILE|O_RDWR, 0755)    (fallback: mkstemp in dir)
6.  write bytes (full artifact, or old + zstd patch applied in-memory/streamed)
7.  verify BLAKE3 == manifest.blake3            → else abort, discard
8.  fchmod(fd, 0755); fsync(fd)
9.  linkat(fd, "", AT_FDCWD, dir/".app.new", AT_EMPTY_PATH)
10. link(self, dir/".app.prev")                 (rollback copy; replace if exists)
11. rename(dir/".app.new", self)                (atomic; running process keeps its inode)
12. fsync(dirfd)
13. write dir/".app.state" { pending_version, prev_version, healthy:false }
```

Renaming over a running executable is safe on Linux: the kernel resolves `ETXTBSY` only for opening the *inode* for writing, and `rename(2)` replaces the directory entry. The running process continues on the old inode until it exits.

macOS: same shape, but the `.app` bundle is replaced directory-wise via `renameat2`-equivalent (`exchangedata` is deprecated; use a staged sibling directory + `rename`), then re-codesign verification before swap.

Windows: the running `.exe` cannot be replaced, but it *can* be renamed. `MoveFileEx(self, self.old)` → write new `self` → schedule `self.old` deletion with `MOVEFILE_DELAY_UNTIL_REBOOT` or clean it on next launch.

### 5.6 First-run canary

After an update, the state file records `healthy:false`. On the next launch:

- if the app calls `ob_update_mark_healthy()` (which it should do once it has drawn a window / accepted a connection / completed init), the state flips to `healthy:true` and `.app.prev` is retained for one more cycle;
- if the app is launched again and the previous run never marked healthy **twice in a row**, `libonebin` restores `.app.prev` and reports the rollback to the app so it can tell the user and (optionally) report telemetry.

Two consecutive failures, not one, so that a user force-quitting during startup doesn't trigger a spurious rollback.

### 5.7 Refusal conditions

The updater **must** disable itself, visibly, when:

- the binary is under `/usr`, `/opt`, `/nix/store`, `/snap`, or another system prefix;
- the binary is not writable by the current user;
- the environment sets `ONEBIN_NO_UPDATE=1` (for distro packagers and enterprise deployment);
- a `.onebin-no-update` marker file sits next to the binary.

In all these cases `ob_update_check_async` returns `OB_UPDATE_DISABLED_SYSTEM_MANAGED` and the app should say *"Updates are managed by your system package manager."* This is the single most important piece of diplomacy in the whole project (see manifesto §10).

---

## 6. `ob_desktop_*` — integration without root

```c
typedef struct {
    const char *app_id;          /* reverse-DNS: com.example.app */
    const char *name;
    const char *generic_name;
    const char *comment;
    const char *categories;      /* freedesktop categories */
    const char *exec_args;       /* appended after the absolute self path */
    ob_icon    *icons;           /* embedded PNG/SVG blobs, sizes */
    size_t      icon_count;
    ob_mime    *mimes;
    size_t      mime_count;
    bool        single_instance;
    bool        offer_autostart;
} ob_desktop_config;

bool ob_desktop_is_installed(const ob_desktop_config *cfg);
int  ob_desktop_install(const ob_desktop_config *cfg, ob_error *err);
int  ob_desktop_uninstall(const char *app_id, ob_uninstall_flags flags, ob_error *err);
```

Writes only into `$XDG_DATA_HOME` (default `~/.local/share`) and `$XDG_CONFIG_HOME`:

```
applications/<app_id>.desktop
icons/hicolor/<size>/apps/<app_id>.png
icons/hicolor/scalable/apps/<app_id>.svg
mime/packages/<app_id>.xml
```

Rules:

- **Never without consent.** `ob_desktop_install` is called by the app in response to a user action or a first-run prompt, not on library init.
- Every generated file carries `X-Onebin-Managed=true` and `X-Onebin-AppId=<id>` so uninstall is exact and never deletes something a distro package placed.
- `Exec=` uses the absolute path of the current binary; if the user moves the binary, the next launch detects the mismatch and offers to fix the entry.
- Best-effort `update-desktop-database` / `update-mime-database` / `gtk-update-icon-cache`; failures are logged, never fatal.
- `ob_desktop_uninstall` with `OB_UNINSTALL_USER_DATA` also removes `~/.config/<id>`, `~/.local/share/<id>`, `~/.cache/<id>` — but only when that flag is passed explicitly, and the app must have asked.

macOS: no-op (the `.app` bundle is the integration). Windows: optional Start Menu shortcut + `HKCU` file associations, same consent rules.

---

## 7. `onebin pack` — optional resource appending

For projects that can't use C23 `#embed` yet: append a resource blob to the binary and read it back at runtime.

```
onebin pack ./myapp --add assets/ --out ./myapp-packed
```

- Appends a zstd-compressed archive plus an 8-byte magic trailer with an offset, rather than adding an ELF section, so the same implementation works for ELF, PE and Mach-O.
- **Signing interaction:** on macOS and Windows, appended data invalidates code signatures. `onebin pack` must therefore run *before* signing, and `onebin release` enforces the ordering.
- Runtime API: `ob_res_open(name)`, `ob_res_data(res, &len)` — memory-mapped, zero-copy for stored (uncompressed) entries.
- **This is the lowest-priority component.** `#embed` makes it obsolete over time and we should say so in its own README.

---

## 8. Toolchain files

### `toolchain/onebin-linux-static.cmake` (Profile S)

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(ONEBIN_PROFILE "static")
set(CMAKE_C_COMPILER   zig)   # wrapped: zig cc -target x86_64-linux-musl
set(CMAKE_CXX_COMPILER zig)   # wrapped: zig c++ -target x86_64-linux-musl
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-pie -Wl,--gc-sections -Wl,--exclude-libs,ALL")
```

### `toolchain/onebin-linux-hybrid.cmake` (Profile H)

Same, with `-target x86_64-linux-gnu.${ONEBIN_GLIBC_BASELINE}` (default `2.28`) and `-static-libstdc++ -static-libgcc` instead of `-static-pie`.

Plus: `onebin-macos-universal.cmake`, `onebin-windows-static.cmake`, equivalent Meson cross files, and a `zig cc` wrapper script that papers over the `-nostdinc`/argument-quoting differences that break some `configure` scripts.

A `OneBinConfig.cmake` exposes:

```cmake
find_package(OneBin REQUIRED COMPONENTS host update desktop)
target_link_libraries(myapp PRIVATE OneBin::host OneBin::update)
onebin_audit(myapp LEVEL 1 GLIBC_MAX 2.28)   # adds a post-build audit + a CI target
```

---

## 9. CI

A composite GitHub Action (and a plain shell script for everyone else):

```yaml
- uses: static-everywhere/onebin-action@v1
  with:
    binary: build/myapp
    profile: hybrid
    glibc-max: "2.28"
    level: 2
    run-matrix: true        # actually executes the binary in the distro matrix
    smoke-command: "--version"
```

The matrix (manifesto §6.2) runs the binary under `alpine:3.10`, `centos:7`, `ubuntu:16.04`, `debian:bullseye`, `fedora:latest`, `archlinux:latest`, `opensuse/leap`, `nixos/nix`, and — for Profile S — `scratch`. Failures are reported per-image with the exact loader error.

For GUI apps the smoke test runs under `weston --backend=headless` and `Xvfb`, asserting that a window is created and that `ob_host_diagnose` reports a working renderer (llvmpipe is an acceptable result — we are testing the loading path, not the GPU).

---

## 10. Milestones

**v0.1 — "Prove it"** *(the only milestone that must ship for the manifesto to be credible)*
`onebin audit` for ELF, all Level 0/1 checks, JSON output, `--baseline`, GitHub Action, the distro test matrix. No library at all. Ships as a static binary that passes its own audit.

**v0.2 — "Load it"**
`ob_host_*` with GL/EGL/Vulkan/audio brokers, `host-contract.toml`, `ob_host_diagnose`, generated GL/VK loader headers, `ob_paths_*`. CMake package.

**v0.3 — "Ship it"**
`ob_update_*` full stack: manifest spec, minisign-compatible signing, atomic install, canary rollback, `onebin sign` / `onebin release`. Deltas behind a flag. Fuzzing of the manifest parser is a release gate.

**v0.4 — "Belong"**
`ob_desktop_*`, Windows/macOS audit backends, `onebin pack`.

**v1.0**
API freeze, conformance spec as a testable document, at least five real third-party projects at Level 3.

---

## 11. Open questions and risks

| # | Risk | Current thinking |
|---|---|---|
| 1 | **Profile S + `dlopen` is impossible.** Static musl has no dynamic loader. | Accept and document. Two profiles is the honest answer. A bundled mini-ELF-loader (TLS, IFUNC, versioned symbols, `dlclose`) is a multi-year project with a bad safety story — **explicitly out of scope**, and we should say so loudly to stop people expecting it. |
| 2 | **musl's locale and `iconv` are minimal**, and it has no NSS (no mDNS/`.local`, NIS, LDAP). | Document in the profile decision table. Offer an ICU-backed collation/conversion shim as an optional component if demand appears. |
| 3 | **musl's default thread stack is 128 KiB** vs glibc's 8 MiB — deep-recursion code crashes mysteriously. | `ob_thread_default_stack()` helper + an audit warning when `-Wl,-z,stack-size` is unset in Profile S. |
| 4 | **`libgcc_s` is `dlopen`'d by glibc for `pthread_cancel`/unwinding**, even with `-static-libgcc`. | Document; audit reports it as info rather than error; recommend avoiding thread cancellation. |
| 5 | **GTK is architecturally unbundleable.** | Not our problem to solve, but it must be stated clearly in the docs rather than discovered by users at 2am. Recommend SDL/Qt. |
| 6 | **LGPL relinking obligation** for static Qt/glibc. | `onebin release --emit-relink-objects` produces the object archive alongside the binary, plus SPDX scanning in CI. A legal-review section in the docs, written with actual counsel before v1.0. |
| 7 | **The `host-contract.toml` becomes stale** as sonames change. | Data file, versioned independently, overridable at runtime by `ONEBIN_HOST_CONTRACT=/path`. Community PRs expected to be the main update path. |
| 8 | **`ob_paths_is_system_managed()` false negatives** would make us fight package managers. | Conservative by default: any ambiguity → treat as system-managed and disable updates. Extensive test fixtures per distro layout, including Nix and Guix. |
| 9 | **Signing key compromise.** | Root key set + delegation, offline root keys, documented rotation runbook. Recommend hardware tokens in the docs. |
| 10 | **We become a framework.** The real failure mode. | Hard rule: every component usable alone; size budgets enforced in CI; `libonebin` depends on libc only; any PR adding a third-party dependency needs an explicit exception. |
| 11 | **Adoption**: nobody uses a tool from an unknown org. | v0.1 is a *linter*, which costs a project nothing to try and produces an immediately shareable badge. Land it in 10–20 well-known projects before shipping any library code. |

---

## 12. Success criteria

This project has succeeded when:

1. `onebin audit` is in the CI of projects that have never heard of the manifesto, because it caught a real bug for them.
2. A new C++ GUI project can get to "one signed, self-updating binary that runs on every distro" in under a day.
3. At least one person who would have reached for Electron doesn't.
4. A distribution maintainer says, in public, that this made their life easier rather than harder.

---

*Companion to [STATIC-EVERYWHERE.md](./STATIC-EVERYWHERE.md). Comments, corrections and rewrites welcome — especially from people who think this is wrong.*
