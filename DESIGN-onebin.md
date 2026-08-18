# `onebin` — Design Document

**A toolkit that makes the [Static Everywhere](./STATIC-EVERYWHERE.md) manifesto a `find_package` away.**

Status: design draft, no code written yet.
Target languages: C11 (library, public ABI), C++17 permitted internally, Go or Rust acceptable for the CLI.
License: **MIT or Apache-2.0 only** — a library that preaches static linking cannot itself impose relinking obligations. This is a hard constraint, nota preference.

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

### The reference application

Every milestone below is judged against one program we did not write and cannot
simplify: **[far2l](https://github.com/elfmz/far2l) must build with these tools, in
every UI mode it has.** It is a file manager with a terminal backend, two
graphical backends, a `dlopen`'d plugin ABI, a helper process, ~15 optional
dependencies and a GPLv2 licence — which makes it a fair test of every component
here rather than a friendly one.

Everything an implementer needs is in
[04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md), which is written to be usable
with no network access. Two of its findings already changed this document: see
§8 (toolchain files) and §11 rows 12–14.

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
| 17 | Shared **modules** (plugins, `dlopen`'d backends) audited as Profile M: same soname, glibc, rpath and hardening rules, no executable-only checks | 1 | — |

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

- Exit code `0` pass / `1` fail / `2` usage error or fatal error (with `--strict`, warnings fail).
- `--format json` emits a stable schema for CI consumption.
- `--baseline baseline.json` records an accepted state so new violations fail but existing ones don't block adoption — **this is essential for incremental adoption of legacy projects.**
- Multiple operands, because a real application is an executable *plus* its modules. `onebin audit build/install/far2l build/install/*.so build/install/Plugins/*/plug/*.far-plug-*` is the normal case, not the exotic one; the exit code is the maximum over all files.

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
const char *ob_paths_apps_dir(void);         /* $ONEBIN_APPS_DIR, else ~/Apps  */
const char *ob_paths_app_dir(const char *install_name, bool create);
const char *ob_paths_self_exe(void);         /* realpath(/proc/self/exe), or platform equivalent */
const char *ob_paths_self_dir(void);
bool        ob_paths_is_system_managed(void);/* under /usr, /opt, /nix/store, root-owned, not user-writable */
const char *ob_paths_desktop_env(void);      /* "GNOME", "KDE", "sway", ... best effort */
bool        ob_paths_is_wayland(void);
```

`ob_paths_apps_dir()` is the user's application directory — the manifesto's
`~/Apps` (§7.2). It is one environment variable and one fallback, never a probe
chain, and it is the same call on every platform because every platform already
has one:

| Platform | `ob_paths_apps_dir()` returns |
|---|---|
| Linux, BSD | `$ONEBIN_APPS_DIR`, else `$HOME/Apps` |
| Windows | `%ONEBIN_APPS_DIR%`, else `%LOCALAPPDATA%\Programs` |
| macOS | `$ONEBIN_APPS_DIR`, else `$HOME/Applications` |

`ob_paths_app_dir("Bar", true)` returns `~/Apps/Bar`, creating it `0755` if
asked. It never creates it world- or group-writable, and it fails rather than
following a symlink it does not own — the override trampoline in §5.7 relies on
both.

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

### 5.7 System-managed binaries and Override Mode

If the binary detects it is managed by a package manager (installed under `/usr`,
`/opt` or `/nix/store`, root-owned, or simply not writable by the current user),
it **must not** refuse to update, nor try to overwrite the system file via root.
Instead it enters **Override Mode**:

1. The update is verified and installed into the user's application directory:
   `ob_paths_app_dir(cfg->install_name, true)` — `~/Apps/<InstallName>/` by
   default (manifesto §7.2). **Not `~/.local/share`.** The override payload is a
   program the user must be able to find, inspect and delete with a file
   manager, not application data.
2. Beside the executable, `libonebin` writes `.onebin-override.json`:

```json
{ "app_id":   "com.example.bar",
  "version":  "3.2.1",
  "build_id": "b4c1…",
  "exec":     "bar",
  "healthy":  true,
  "installed": "2026-08-17T10:00:00Z" }
```

3. The system-wide binary becomes a **trampoline**. Before anything else,
   `libonebin` reads that file and `execv`s the override — but only when every
   one of these holds. Any failure is silent, is logged at debug level, and
   means "run the system build".

| Condition | Why |
|---|---|
| the process is not setuid/setgid and `AT_SECURE` is clear | a user-writable path must never win inside a privileged process |
| `~/Apps` and the app directory are owned by the real uid | ditto, one directory down |
| neither is group- or world-writable | otherwise any group member ships you code |
| the marker's `app_id` equals the compiled-in `app_id` | a directory-name collision must not exec a different program |
| the override version is strictly newer | an override is an upgrade mechanism, not a downgrade one — and rollback protection (§5.1) applies to it |
| `healthy` is true, or this is the canary launch (§5.6) | two failed launches and the trampoline stops preferring it |
| no `.onebin-no-override` marker beside the system binary or in the app directory | packagers and administrators get a hard off switch |
| `ONEBIN_NO_UPDATE` and `ONEBIN_NO_OVERRIDE` are both unset | the user gets one too, per launch |

4. `execv`, not `fork`: no extra process, `argv` preserved verbatim, and
   `ONEBIN_TRAMPOLINE=<absolute path of the system binary>` exported so the
   override knows how it was started and can never bounce a second time. A
   trampoline that finds `ONEBIN_TRAMPOLINE` already set runs itself and reports
   the loop.
5. If the override is broken, the user deletes `~/Apps/<InstallName>` and is back
   on the distribution's build, with no tooling and no instructions. **That
   recovery path is the entire reason the payload goes somewhere visible instead
   of somewhere tidy.**

The updater **must** disable itself completely only when:
- the environment sets `ONEBIN_NO_UPDATE=1` (for distro packagers and enterprise deployment);
- a `.onebin-no-update` marker file sits next to the binary.

When fully disabled, `ob_update_check_async` returns `OB_UPDATE_DISABLED_SYSTEM_MANAGED` and the app should say *"Updates are managed by your system package manager."* This is an important piece of diplomacy in the whole project (see manifesto §10).

---

## 6. `ob_desktop_*` — integration without root

```c
typedef struct {
    const char *app_id;          /* reverse-DNS: com.example.app */
    const char *install_name;    /* directory under ~/Apps: "Bar". No spaces, not localised. */
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
- `Exec=` uses the absolute path of the current binary — for a normally installed application that is `~/Apps/<install_name>/<exec>`; if the user moves the binary, the next launch detects the mismatch and offers to fix the entry. Never write a `~/Apps` path into a *system* desktop entry: the trampoline (§5.7) exists precisely so the system entry keeps pointing at the system binary.
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

**`--exclude-libs,ALL` is opt-out, and the toolchain files must let you opt out.**
An application that exports an ABI to its own `dlopen`'d plugins needs those
symbols in `.dynsym`; stripping them produces a binary that starts and then fails
on the first plugin. So:

```cmake
option(ONEBIN_EXPORT_DYNAMIC "app exports an ABI to its own plugins" OFF)
# ON  -> -Wl,--export-dynamic (or -Wl,--version-script=…), no --exclude-libs
# OFF -> -Wl,--exclude-libs,ALL, as before
```

Prefer a version script over `--export-dynamic` when the project has one: export
what was promised, not everything that survived `--gc-sections`. far2l needs this
(`04-REFERENCE-far2l.md §7.1`) and it is not unusual — every application with a
plugin API has the same requirement.

Two smaller notes the reference build turned up, both belonging in the hybrid and
static toolchain files rather than in each project's build:

- `zig cc` identifies as Clang, so build systems that add flags "unless the
  compiler is Clang" will silently skip them. Set `--gc-sections` from the
  toolchain file rather than assuming the project adds it.
- Always pass `-ffile-prefix-map=${CMAKE_SOURCE_DIR}=.` and
  `-ffile-prefix-map=${CMAKE_BINARY_DIR}=.`; otherwise the audit's own hygiene
  check fires on binaries we produced ourselves, which is a bad look for a
  linter.

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

### The reference build job

Separate workflow, runs on a schedule and on every change to the toolchain files
or to `tools/build-far2l.sh`:

1. Resolve the pinned far2l tag from `contrib/far2l/deps.lock` (never "latest" —
   a floating upstream turns a red build into a mystery).
2. Build all four configurations: `tiny`, `tty`, `sdl`, `wx`.
3. Audit every produced artifact per `04-REFERENCE-far2l.md §9`.
4. Run the distro matrix on the `tiny` and `tty` binaries, and the headless GUI
   smoke test on `sdl`.
5. **Publish the `wx` audit output as an artifact even though it fails.** It is
   the evidence for the GTK row in the cheat sheet, and evidence that we do not
   quietly drop the configurations that embarrass us.

The job is allowed to be slow. It is not allowed to be skipped when it goes red.

---

## 10. Milestones

**v0.1 — "Prove it"** *(the only milestone that must ship for the manifesto to be credible)*
`onebin audit` for ELF, all Level 0/1 checks including Profile M for modules, JSON output, `--baseline`, GitHub Action, the distro test matrix. No library at all. Ships as a static binary that passes its own audit.

Plus the reference build, because a linter with nothing real to lint is a toy:
the two CMake toolchain files, the `zig cc` wrapper, `contrib/far2l/deps.lock`,
and `tools/build-far2l.sh` producing `far2l-tiny`, `far2l-tty` and `far2l-sdl`
at Level 1, with `far2l-wx` measured and published as the documented failure.

**v0.2 — "Load it"**
`ob_host_*` with GL/EGL/Vulkan/audio brokers, `host-contract.toml`, `ob_host_diagnose`, generated GL/VK loader headers, `ob_paths_*`. CMake package.

Acceptance is the reference application, not a sample: `far2l-sdl` starts on a
host with no toolkit installed, finds fonts through the host's fontconfig, and
`ob_host_diagnose` explains itself when there is no GPU.

**v0.3 — "Ship it"**
`ob_update_*` full stack: manifest spec, minisign-compatible signing, atomic install, canary rollback, `onebin sign` / `onebin release`. Deltas behind a flag. Fuzzing of the manifest parser is a release gate.

**v0.4 — "Belong"**
`ob_desktop_*`, Windows/macOS audit backends, `onebin pack`.

`onebin pack` finally has a real user: it is what turns "far2l plus its modules"
into one file (`04-REFERENCE-far2l.md §7.5`). Until then we ship a directory and
say so.

**v1.0**
API freeze, conformance spec as a testable document, at least five real third-party projects at Level 3.

---

## 11. Open questions and risks

| # | Risk | Current thinking |
|---|---|---|
| 1 | **Profile S + `dlopen` is impossible.** Static musl has no dynamic loader. | Accept and document — but stop pretending this is a small problem. Almost every real program needs `dlopen` for something, so Profile S in practice means CLI tools and nothing else. **Amended by f4-qt** (`05-REFERENCE-f4-qt.md §7.7`): this is a fact about the C toolchain, not about static binaries. A language runtime that carries its own FFI machinery — Go with `purego`/`goffi` — produces a binary with no `PT_INTERP` and no `DT_NEEDED` that still `dlopen`s, and reaches X11 and Wayland by wire protocol with no client library at all. **A second, stronger counterexample**: [`pg83/solo`](https://github.com/pg83/solo) is a shipping, ~2,100-line x86-64 ELF loader plus a hand-written glibc-ABI-over-musl shim that lets a fully static musl binary `dlopen()` an unmodified, glibc-linked host `.so` (a real Mesa/Vulkan ICD) with no re-exec and no second libc — see `§13.5` below for what it costs. Writing our *own* mini-ELF-loader remains **out of scope for this project right now**, at this project's current priorities (TLS, IFUNC, versioned symbols, `dlclose` — multi-year, bad safety story). Carrying somebody else's, which is a different proposal entirely, is §13. |
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
| 12 | **Applications with their own plugin ABI** need an exported dynamic symbol table, which our recommended flags delete. | Fixed in §8: `--exclude-libs,ALL` becomes opt-out, version scripts preferred. The audit must never treat a populated `.dynsym` in an executable as a defect. Found by far2l before it was found by a user. |
| 13 | **"One binary" is a lie for any app with `dlopen`'d modules.** | Say so. v0.1 ships an executable plus `$ORIGIN`-relative modules and calls it that; `onebin pack` (v0.4) makes it one file by extracting to a cache directory on first run. Do not claim the single-file property in marketing before the packer exists. |
| 14 | **`memfd_create` + `dlopen("/proc/self/fd/N")`** would give a true single file with no extraction — and breaks under hardened kernels, seccomp policies, SELinux `execmem` rules, and anywhere `/proc` is absent. | **Open question, not a plan.** If it is ever built it must be a fallback path behind the cache-directory approach, never the only one, and the failure must be diagnosable. Prototype and measure across the distro matrix before any commitment. |
| 15 | **One artifact per OS may itself be a habit.** Three builds of the same program are overwhelmingly the same machine code, differing only in a port layer that is a rounding error in the binary. | Out of scope for v0.1 and possibly forever, but recorded rather than rediscovered: [FUTURE-IDEAS.md §1](./FUTURE-IDEAS.md) argues for one image per *architecture* with runtime-selected platform backends, and lists the seven things worth not foreclosing (§1.11). Those seven are free, and are the only part of it this milestone should care about. |

---

## 12. Success criteria

This project has succeeded when:

1. `onebin audit` is in the CI of projects that have never heard of the manifesto, because it caught a real bug for them.
2. A new C++ GUI project can get to "one signed, self-updating binary that runs on every distro" in under a day.
3. At least one person who would have reached for Electron doesn't.
4. A distribution maintainer says, in public, that this made their life easier rather than harder.
5. `far2l-sdl` runs, from one downloaded artifact, on a distribution released the year this was written and on one released a decade earlier — with no toolkit, no container, and no instructions beyond `chmod +x`.

---

## 13. Proposal: Profile D — carry your own loader

**Status: decided in principle (§13.6), not yet scheduled, no code.**
Recorded here so the argument is written down rather than rediscovered.

### The problem with two profiles

Profile S forbids `dlopen`. Almost every program that is interesting to ship
needs it — for its own plugins, for the GPU, for audio. So Profile S in practice
covers CLI tools, and the "one file, any Linux" claim quietly stops being about
the software people actually care about. Profile H answers this by depending on
the host's glibc, which works well and has a floor: you cannot go below the
oldest baseline you are willing to pin.

### The trick

A dynamic executable is only "dynamic" relative to a loader. **Ship the loader.**

> **Constraint, established empirically before we build anything**
> (`04-REFERENCE-far2l.md §12`): **`PT_INTERP` does not expand `$ORIGIN`.**
> `DT_RPATH`/`DT_RUNPATH` do, because the dynamic linker expands them;
> `PT_INTERP` is opened by the *kernel* with a plain `open_exec()` on the
> literal bytes. A carried loader can therefore only be named by an absolute
> path (useless for something relocatable) or by a path relative to the
> **current working directory** (not to the binary).
>
> `far2l-portable` ships exactly this design today and takes the CWD-relative
> route, which is why its deliverable is a self-extracting `.run` that
> `chdir`s before executing rather than a directory you can drop anywhere.
>
> The three-step plan below **never sets `PT_INTERP`** — the stub `execve`s the
> loader explicitly with the real program as an argument — so it does not
> inherit this problem. That was not a deliberate response to it at the time
> the proposal was written, but it is the strongest single argument for
> paying the stub's extra `execve` and the `memfd`/cache machinery rather
> than reaching for `patchelf --set-interpreter`.

1. `onebin pack` appends `ld.so`, libc, and the application's own modules to the
   executable as a blob.
2. A small static stub finds its own blob, publishes the loader through
   `memfd_create` — falling back to `$XDG_CACHE_HOME/<app>/<build-id>/` when the
   kernel or policy forbids that — and `execve`s it with the real program.
3. From that point the process is an ordinary dynamic one. `dlopen` works,
   plugins work, `gdb` works, `LD_PRELOAD` tools work.

One file on disk, zero libc dependency on the host.

### Two flavours, and the difference is not cosmetic

| | **D-musl** | **D-glibc** |
|---|---|---|
| Added size | ~600 KB | ~12 MB |
| `dlopen` your own modules | yes | yes |
| `dlopen` the **host's** `libGL`, `libX11`, `libasound` | **no** | yes, provided the bundled glibc is newer than the host's |
| Host libc requirement | none | none |
| Good for | plugin systems with no host contract | graphics and audio on hosts older than any baseline worth pinning |

The `no` in that table is the whole story. Host libraries are built against
glibc; a musl loader cannot satisfy their versioned symbols. **Anything touching
the GPU therefore needs D-glibc, not D-musl** — which is the same conclusion
Steam's runtime and Nix reached, by the same route: a newer glibc hosting older
drivers is the direction that works.

> **That `no` is refuted by shipping code, found after this document was
> written: [`pg83/solo`](https://github.com/pg83/solo) ("SoLo — a `.so`
> loader for static Linux binaries").** It is not D-musl with a bundled
> loader; it is a fourth approach this table did not have a column for, and
> it is worth its own subsection because it changes the "no" above from a
> structural limit into a solved (if narrow) engineering problem. See
> §13.5 below.

### 13.5 What SoLo actually does, and what it costs

SoLo ships a fully static musl x86-64 executable — no `PT_INTERP`, no
`DT_NEEDED`, `readelf -d` reports "There is no dynamic section" — that can
still `dlopen()` an **unmodified, distro-installed, glibc-linked** shared
object (their proof is a real Mesa/Vulkan ICD) and call into it correctly.
No re-exec, no `memfd`, no second libc, no bundled `ld.so`. One process,
one libc, the whole time.

The trick is not "carry a loader that runs the host's `.so` under its own
glibc" (D-glibc's approach, and Detour's, and Cosmopolitan's
`cosmo_dlopen()`, and the `graphics.gd` musl+dlopen experiment — all of
which bootstrap the host's real `ld-linux`/glibc alongside the static
binary's own libc, meaning **two coexisting libc runtimes**, with the
TLS-switching-at-every-call-boundary cost and callback-safety hazards that
implies). SoLo instead:

1. **Writes its own ELF loader** (`lib/elf_loader.cpp`, ~2,100 lines):
   maps segments, walks `DT_NEEDED` recursively, resolves versioned
   symbols, applies x86-64 relocations, supports ELF TLS *and* TLSDESC,
   materializes IFUNCs, applies RELRO, runs initializers. This is close to
   the scope `DESIGN-onebin.md §11` row 1 called "multi-year" and ruled
   out — real, shipping, and roughly 2,000 lines for the x86-64 case, not
   multiple years. The honest caveat: this is one architecture, one OS,
   and has not been through the years of hostile-input hardening a real
   `ld.so` has. "A thousand lines" (this document's own §1.12 estimate,
   elsewhere) was optimistic; **~2,000 for a single architecture** is the
   corrected number, now that one exists to count.
2. **Never loads glibc.** Instead, `lib/glibc_shim.cpp` (~4,300 lines — the
   actual bulk of the effort, not the ELF loader) implements ABI-correct
   adapters for glibc imports like `malloc@GLIBC_2.2.5` *on top of the
   process's own musl runtime*. One versioned symbol at a time, by hand.
   Anything not yet implemented gets a **generated stub that names itself
   and aborts loudly** rather than silently corrupting the process — the
   same "fail loud, never guess" discipline this project tries to apply to
   audit findings, independently arrived at for a much harder problem.
3. **Lets the static binary satisfy some of the host `.so`'s own imports**
   via a "static provider registry" — e.g. give the host's `libwayland`
   dependency the Wayland symbols already linked into your executable,
   instead of requiring the host to have a compatible `libwayland.so` at
   all.

### Why this matters for D-musl specifically

If SoLo's approach generalizes past "Mesa/Vulkan ICD closures on x86-64"
(their own stated scope — see their README's "Scope" section, which is
appropriately modest about this), **D-musl's "no" becomes "yes, for the
specific host-library closures someone has bothered to shim."** That is a
narrower, harder-won "yes" than D-glibc's — every unimplemented glibc call
is a potential hard stop, not a graceful degrade — but it is a real one,
and it keeps D-musl's entire value proposition (~600 KB, no bundled glibc,
no re-exec, no `/proc/self/exe` disruption, single libc, single TLS world)
instead of trading it away for D-glibc's ~12 MB and re-exec cost.

**Not a reason to build this ourselves right now.** The glibc ABI surface
Mesa/Vulkan actually touch is a small, well-trodden path; the glibc ABI
surface a *general* application touches is not, and `glibc_shim.cpp`'s
4,300 lines for "the Vulkan/Mesa closure alone" is the honest measure of
how much work a broader net would cost. But it is a concrete, running
existence proof against this document's own pessimism, worth revisiting
if D-musl's narrower "yes" ever becomes load-bearing for a reference
application here — `far2l-sdl`'s SDL2, which already `dlopen`s
`libGL`/`libX11`/`libasound` itself, is exactly the kind of target this
would apply to.

### What must be answered before this is more than a proposal

- `MFD_NOEXEC_SEAL` and `vm.memfd_noexec` on recent kernels; `noexec` mounts for
  the cache fallback; SELinux `execmem`; containers with no `/proc`.
- Re-exec doubles process startup and changes `/proc/self/exe`, which breaks
  anything that uses it to find its own resources — including, note,
  applications that locate their modules that way.
- Bundling glibc is an LGPL obligation we satisfy by linking it dynamically,
  which is exactly what we are doing — but it needs saying in the SBOM.
- Prototype and measure across the full distro matrix before committing.

### Order of preference — this is the part to remember

**Profile H first.** A 2.28 baseline is smaller, simpler, has no re-exec, and
already covers RHEL 8, Debian 10, Ubuntu 18.04 and everything newer. Profile D is
for reaching below that floor, or for the rare case that must not touch the host
libc at all. Profile S is a deliberate niche — `FROM scratch`, initramfs,
embedded — and the documents should stop implying it is the ideal that the other
profiles compromise on.

### 13.6 Decision: support both routes, graceful degradation, don't write a loader from scratch

Two ways have been on the table for letting a Profile S binary reach a host
library it cannot statically link: carry a real loader (§13 above), or trick
the host's *own* loader into working on a payload that was never a file —
`memfd_create()` an anonymous in-memory file, write the target `.so` into it,
then `dlopen("/proc/self/fd/N")`, which is a real path the host's real `ld.so`
will happily open. **Decision: do both, and pick automatically at runtime —
never one at the cost of the other.**

Why not choose one: they fail in opposite cases. The `memfd` trick depends on
the *host* having a working, ABI-compatible dynamic loader in the first place
— which is exactly the thing a stripped `FROM scratch` container or a musl
host without glibc might not have. A carried loader has no such dependency,
but costs real engineering (§13.6.1). Neither one is strictly better; they
cover each other's gap.

**Order of attempt, at runtime, per library needed:**

1. Try `memfd_create` + `dlopen("/proc/self/fd/N")`. Cheap, uses the host's
   own loader (so it inherits the host's own security patches, ABI quirks,
   and NSS behaviour for free), no code of ours runs untested paths.
2. If that fails (no working host loader, or the specific library the host
   loader can't satisfy — e.g. the host genuinely doesn't have a compatible
   libc to run *its own* `ld.so` against), fall back to the carried loader.
3. If both fail, that is a normal, reportable "this optional feature isn't
   available on this host" outcome — not a crash. A GPU-accelerated codepath
   degrading to software rendering, or a plugin silently not loading, is the
   expected shape of failure here, matching the "protocol first, `dlopen`
   only where physics demands it" principle already in place for Profile H.

This is graceful degradation in the ordinary sense: try the cheap thing,
fall back to the expensive-but-more-self-contained thing, fail soft if
neither works, and never require a caller to know in advance which path a
given host will take.

**13.6.1 — don't write the carried loader from scratch: adapt SoLo's.**
`§13.5` already documents [`pg83/solo`](https://github.com/pg83/solo) as a
real, shipping ELF loader (`lib/elf_loader.cpp`, ~2,100 lines) plus a
glibc-ABI-over-musl compatibility shim (`lib/glibc_shim.cpp`, ~4,300 lines) —
exactly the two pieces Profile D's carried-loader route needs, already
written, already handling the hard parts (versioned symbols, TLS/TLSDESC,
IFUNCs, RELRO) that made this project's own earlier "a thousand lines"
estimate optimistic. **Building a second one from nothing would be pure
duplicated risk with no corresponding benefit — fewer wheels, more
delegation.** The concrete plan, if and when this gets scheduled: fork or
vendor SoLo's loader, trim `glibc_shim.cpp` to the symbol surface this
project's own reference applications (far2l, f4-qt) actually touch rather
than SoLo's own broader Mesa/Vulkan-focused coverage, and keep it behind
`onebin audit`'s existing static/dynamic distinction so a Profile D binary
using it is still auditable the normal way. Not started; recorded so the
next person doesn't rediscover SoLo as "maybe we could look at this" and
instead starts from "here is the adaptation plan."

---

Profile D is about escaping the host's *libc version*. The same trick pointed at
the host's *operating system* is [FUTURE-IDEAS.md §1](./FUTURE-IDEAS.md) — much
more speculative, unscheduled, and deliberately kept out of this document until
it has an experiment behind it.

---

*Companion to [STATIC-EVERYWHERE.md](./STATIC-EVERYWHERE.md). Comments, corrections and rewrites welcome — especially from people who think this is wrong.*
