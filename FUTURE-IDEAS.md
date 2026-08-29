# FUTURE IDEAS

**Status: none of this is scheduled, specified, or agreed. No code exists. No
milestone depends on any of it.**

This file is where speculative ideas live so that they are argued in public
rather than rediscovered in private every eighteen months. Everything here is an
invitation to disagree. If an idea graduates, it leaves this file and becomes a
proposal in `DESIGN-onebin.md` with an owner and an experiment; if it dies, it
stays here with the reason it died, which is more useful than deleting it.

Nothing in this file should influence v0.1 beyond §1.11, which lists the few
decisions worth *not foreclosing* — all of them free.

---

## 1. One binary per architecture, not per operating system

### 1.1 The observation

Look at what a modern cross-platform application actually is.

The application logic is the same on every operating system. The toolkit is the
same. The compression, parsing, crypto, layout, and text shaping are the same.
This is not an accident and it is not new: everyone stopped writing per-OS
applications decades ago and started writing against a framework that abstracts
the platform. Qt, SDL, wxWidgets, Skia, Electron, Flutter, Go's runtime — the
whole industry converged on "one codebase, a thin platform port underneath".

And then we ship it three times.

The Linux build, the Windows build and the macOS build of the same program are,
by volume, overwhelmingly the same machine code doing the same thing, produced
from the same source, differing only in a port layer that is a rounding error in
the binary. We accept a 3× duplication of the artifact in order to vary a few
per cent of it.

Worse, we accept it *for no structural reason*. The port layer is already an
abstraction with a defined interface. The only thing that forces the choice to
happen at link time is that this is what C toolchains have always done.

The manifesto's central claim is that Linux's packaging misery is a habit rather
than a property. This is the same claim, one level up: **shipping one artifact
per operating system is a habit, not a property.**

### 1.2 Three questions

A universal binary — one file, one architecture, any of the three desktop
operating systems — has to answer exactly three questions:

1. **How does the code reach the operating system?** Syscalls, windows, GPU,
   audio, files.
2. **What container format is the code in?**
3. **Who loads that format on an OS that does not natively load it?**

Question 1 is the one everybody assumes is hardest. It is the one this project
has already answered.

### 1.3 Question 1 is already answered, and that is the interesting part

Apply the doctrine's three layers to a program and count what is left that is
genuinely OS-specific:

**Layer 1 — code.** Your dependencies are static, which means they are already
in your image as ordinary machine code with no opinion about the OS. zlib does
not know what kernel it is on. Neither does FreeType, HarfBuzz, SQLite, or 90% of
Qt. This layer is *already* OS-neutral; it is only the toolchain that stamps an
OS on it.

**Layer 2 — data.** Fonts, CA certificates, icon themes, locales, MIME database.
The *paths* differ per OS; the *content* and the parsing do not. `ob_paths_*`
already exists to paper over exactly this difference, and it is a hundred lines
of string handling.

**Layer 3 — services and devices.** This is where the doctrine pays off in a way
we did not design for:

| Service | What it actually is | OS-specific? |
|---|---|---|
| Wayland | a wire protocol over a Unix socket | no — `libwayland-client` is a convenience, not a requirement |
| X11 | a wire protocol over a socket, fully specified since 1987 | no |
| D-Bus, portals | a wire protocol over a socket | no |
| PulseAudio, PipeWire | wire protocols over sockets | no |
| Win32 | a plain C ABI, stable for thirty years, callable by anything that can call C | it *is* the OS, but it is not exotic |
| Cocoa | Objective-C — whose runtime is a C ABI: `objc_getClass`, `sel_registerName`, `objc_msgSend` | reachable from C, no ObjC compiler needed |
| Vulkan, OpenGL | C ABI behind a loader, with a machine-readable registry (`vk.xml`, `gl.xml`) | the one genuinely per-OS binding |

**This is not a thought experiment.** The Qt reference application
([05-REFERENCE-f4-qt.md §7.7](./05-REFERENCE-f4-qt.md)) ships a Go binary with no
interpreter and no `DT_NEEDED` that opens X11 *and* Wayland windows with no
client library on either — pure wire protocol over a socket — and drives AppKit
on macOS through `objc_msgSend` with no Objective-C compiler in the build. Two of
the rows above are already crossed off by a program you can download today.

Take the doctrine seriously — talk to the host by protocol, not by ABI — and the
irreducible OS surface of a graphical application collapses to roughly:

- file, memory, thread, time, and socket syscalls: on the order of forty calls;
- one way to get a window and an input stream;
- one way to get a GPU handle.

That is the whole port layer. Everything else is your own code, in your own
image, already OS-neutral.

**And the dispatch mechanism is boring.** A struct of function pointers,
populated at startup by whichever backend detected that it is the one running.
Qt's QPA is exactly this, and it already selects `xcb`, `wayland`, `cocoa`,
`windows` or `offscreen` *at runtime* from a plugin directory. SDL's video and
audio drivers are exactly this. Go's runtime is exactly this, with the
per-OS half chosen at compile time for no reason except that Go links statically.

**The platform abstraction we would need already exists in every one of these
frameworks. It is simply resolved at the wrong time.** Nobody has to invent it;
somebody has to move it from link time to run time and then ship the backends
together.

That is the part that has been sitting in plain sight.

### 1.4 Questions 2 and 3: pick a format, carry a loader

`DESIGN-onebin.md §13` already contains the shape of the answer for a different
axis. Profile D says: a dynamic executable is only dynamic relative to a loader,
so *ship the loader* and stop depending on the host's glibc. Profile U would be
the same trick pointed one level up: **ship the loader and stop depending on the
host's operating system.**

Which format? The answer is counter-intuitive: **PE**.

| | ELF | Mach-O | PE/COFF |
|---|---|---|---|
| Relocations | multiple types, IFUNC resolvers run arbitrary code | chained fixups, opcode stream | one base-delta table, four relocation types in practice |
| Symbol binding | versioned symbols, `GNU_HASH`, `dlsym` scope rules, `LD_PRELOAD` interposition | two-level namespace, dyld caches | by name or ordinal, per imported module, no versioning, no interposition |
| TLS | `__tls_get_addr`, four TLS models, IE/LE relaxations | `tlv_get_addr` | a TLS directory with slots and callbacks |
| Loader complexity for a *cooperating* image | high | high, and moving | **low** |
| Natively loaded by | Linux, BSD | macOS | Windows |

PE is the simplest of the three to load, by a wide margin, for the specific case
of an image you compiled yourself. It has no symbol versioning, no IFUNC, no
interposition semantics, and its relocations are a list of "add the base delta
here". A competent PE loader for a cooperating image is on the order of a
thousand lines — the sort of thing demo groups and packers have written for
thirty years — where an equivalently capable ELF loader is a multi-year project
we have already declared out of scope (`DESIGN-onebin.md §11`, row 1).

It also has the right asymmetry. The one operating system that will never learn a
new executable format is Windows; it is the one whose format we would adopt, so
it needs no loader at all. Linux and macOS both let a userspace process map and
execute memory, which is all a loader needs.

### 1.5 The insight that makes the loader small: the guest cooperates

The obvious objection is "you have just proposed writing Wine, which took
thirty years and is still not finished."

No. Wine is hard for a reason that does not apply here.

**Wine's job is to run binaries it did not build, whose authors it cannot talk
to, which use any part of Win32 they like, including the undocumented parts,
including the parts that were bugs.** The API surface is unbounded because the
guest is uncooperative. That is the entire source of the difficulty.

We would be running a binary *we compiled*, from source *we control*, against a
platform contract *we wrote*. In that world:

- The API surface is whatever we say it is. Call it two hundred functions.
- No COM, no registry, no GDI, no undocumented `Nt*` calls, no SEH abuse, no
  DirectX, no installer, no 16-bit anything.
- The exception model, the calling convention details, the TLS model and the
  entry-point protocol are all things we *choose at compile time*, so we choose
  the ones the loader can implement.

And here is the part that ties it back to the tool this repository is actually
building:

> **`onebin audit` is what makes the loader small.**

The audit's whole job today is "this ELF may import these six sonames and nothing
else". Point it at a PE image and the same check becomes "this image may import
these two hundred functions and nothing else" — a strictly *finer* contract than
the one we already enforce, on a table that is right there in the file, and the
build fails the moment somebody links something that reaches outside it.

Nobody built the small version of Wine because nobody could bound the API
surface. **A linter bounds it.** That inversion — the loader is small because the
binary is provably minimal, rather than the loader being complete because the
binary might do anything — is the idea in this section that seems genuinely
unexploited.

There is even a documented dispatch hook sitting unused: PE's *delay-loaded
imports* route every first call to a user-replaceable helper
(`__delayLoadHelper2`). A universal image can be built so that every platform
call is delay-loaded, and the helper is the platform vtable — the same mechanism
on Windows, where it binds to the real `kernel32`, and everywhere else, where it
binds to the carried backend. It has been in MSVC since 1998 and is used almost
exclusively for shaving milliseconds off startup.

**What to take from Wine, and what to leave.** Wine has already done the hard,
unglamorous half of this work and published it: since the Wine 6 era its own
DLLs are built as PE and call into the Unix world through a narrow, explicit
"unixlib" boundary (`__wine_unix_call`), precisely because the project needed a
clean split between PE-side code and host-side libraries. That boundary, the
Microsoft-x64-to-SysV thunking, and `winevulkan`'s *generated* thunks (generated
from `vk.xml`, not hand-written) are the reusable parts. The unbounded
compatibility surface is the part to leave behind.

One accident of history helps and one hurts. On x86-64, Windows reaches the TEB
through `%gs` while System V uses `%fs` for TLS — they do not collide, which is
part of why Wine on Linux works as well as it does. On macOS, `%gs` *is* the
thread-local base, and on arm64 Apple reserves `x18`, which is exactly the
register Windows-on-ARM uses for the TEB. The two platforms that collide are the
two that are hardest for other reasons as well; see §1.7.

### 1.6 The file: one payload, N heads

"One binary" must not mean "three binaries in a trenchcoat". The point is that
the *payload* — the 30 MB of application and toolkit — exists once.

Two ways to get there, and they are not equally exotic:

**(a) The polyglot.** One file with several valid headers, one shared payload.
Cosmopolitan's APE has done this since 2020: a single file that Linux, macOS,
Windows and the BSDs each recognise as their own. It works, it is proven at
scale, and the trickery is confined to the first few hundred bytes. The heads are
kilobytes; the payload is megabytes; the duplication is the heads.

**(b) The boring version, which is probably where to start.** Publish three
downloads whose payload is byte-identical and whose per-OS head is a few tens of
kilobytes. Not one file — but:

- one build, one payload hash, one SBOM, one signature over the payload;
- **`zstd --patch-from` deltas that are OS-neutral**: the same 200 KB patch
  updates the Linux, Windows and macOS users, because the bytes it patches are
  the same bytes;
- audits that no longer have to be repeated per platform for the parts that are
  not platform-specific;
- and a completely uneventful migration path to (a) later, since (a) is (b) with
  the heads concatenated.

(b) captures most of the operational value with none of the polyglot's
weirdness, and it can be evaluated on its own merits even if the rest of this
section is wrong.

### 1.7 Where this breaks

Honestly, and in the order that matters:

**macOS is the wall.** Every other problem here is engineering; this one is
policy. Executable pages on modern macOS are entangled with code signing, the
hardened runtime, and — on Apple Silicon — the JIT entitlement and `MAP_JIT`
W^X rules. Notarisation assumes a Mach-O the notary can inspect. A process
that maps a foreign code image and jumps into it is, from Apple's point of view,
a JIT at best. `%gs` and `x18` are taken. And Rosetta translates Mach-O, not PE,
so the "amd64 image everywhere" bonus in §1.9 does not extend to Apple Silicon.
Assume, until proven otherwise, that macOS needs a real Mach-O and therefore a
second copy of the code — which is exactly the outcome the idea is trying to
avoid, on the platform where users are least likely to accept a workaround.

**C++ exceptions.** x86-64 Windows unwinding is table-driven (`.pdata`/`.xdata`)
and a foreign loader must implement `RtlUnwindEx` semantics for anything that
throws. Qt throws. This is the single largest line item in a from-scratch
loader, and it is where "a thousand lines" stops being true. Levers exist —
we choose the compiler, so we can choose the exception model, or build the
toolkit with exceptions disabled — but they are constraints on the application,
and constraints on the application are how ideas like this die.

**GPU drivers are native shared objects.** `libvulkan.so.1` is an ELF; a PE image
cannot load it directly. The bridge is a thunk in the host-side head, converting
calling conventions, and Wine's answer — generate it from the Khronos registry —
is the right one. Note that `onebin` already plans to generate `onebin/vk.h` and
`onebin/gl.h` from the same XML for a completely different reason
(`DESIGN-onebin.md §3`), so the generator is not new work so much as new output
from work already scoped.

**Debuggers, profilers and crash reporters.** `gdb`, `perf`, `lldb` and every
crash-reporting service understand the host's format. A carried loader breaks
symbolication unless it registers with the JIT interfaces the debuggers expose —
which exist, and which nobody enjoys.

**Antivirus.** A binary that maps a code image out of its own data section and
executes it is, behaviourally, a packer. On Windows this is a false-positive
generator; on corporate endpoints it can be a hard block. This alone has killed
otherwise good distribution ideas.

**Startup cost and `/proc/self/exe`.** Same caveats as Profile D: a re-exec or an
in-process load changes what "where am I?" means, and anything that locates its
resources by looking at its own path breaks. `ob_paths_self_exe()` and `ob_res_*`
exist for this; a universal image would make them mandatory rather than
advisable.

**The real failure mode: you have written a second Wine.** Every "just a small
loader" grows. The discipline that keeps it small is the audited contract in
§1.5, and if that discipline slips even slightly, this becomes a compatibility
project — and compatibility projects are how decades disappear.

### 1.8 Prior art, and where each stopped

| Prior art | What it proved | Why it is not this |
|---|---|---|
| **Cosmopolitan / APE** | One file, many OSes, one copy of the code, runtime syscall dispatch. The idea is *not* impossible; it is shipping. | Its own libc, no dynamic linking to host libraries, no GUI toolkit story, and a deliberately spartan world. Cosmopolitan solved this for programs it can rebuild from source against its own libc — which is exactly the population that needed it least. |
| **Wine** | PE code can call the Unix world through a narrow boundary; the PE/unix split is real, documented and maintained. | Aimed at uncooperative guests, so it must be complete. Enormous. Ships as a host dependency rather than as part of the application. |
| **Hangover** | amd64 PE running on arm64 Linux, in production, today. | Same. Plus emulation cost. |
| **FatELF** | Multi-architecture ELF was technically straightforward. | Rejected by the ecosystem in 2009, for good reasons that also apply to naive fat binaries: it duplicates the payload, which is the thing we are trying not to do. |
| **JVM, .NET, wasm/WASI** | Portable bytecode obviously works. | You pay with a runtime on the host, a JIT, or both, and you lose direct access to native toolkits — which is the entire reason a desktop application is native in the first place. WASI still has no answer for "give me a window and a GPU". |
| **Qt QPA, SDL drivers** | Runtime-selected platform backends are normal, boring, and already in every application you ship. | Selected at runtime *within* one OS, compiled per OS. The missing piece is the smallest one. |
| **Go** | One codebase, per-OS syscall layer, no host runtime, brilliant cross-compilation. | Chooses the OS at compile time out of convention. `GOOS` is a build tag, not a runtime switch — but nothing about the design forbids it being one. |
| **WSL 1** | An OS kernel can implement another OS's syscall interface well enough to run real userlands. | The wrong direction — it puts the shim in the kernel, where you cannot ship it. |
| **UPX, installers, self-extracting archives** | Everyone already ships programs that unpack and execute code at runtime, and nobody finds this strange. | Crude, single-format, and only ever used to save space. |

The pattern is that every piece of this has been built, several of them
repeatedly, and nobody has assembled them for *distribution* — because the people
who could (Wine, emulator authors) were solving compatibility with binaries they
did not control, and the people with the motive (application authors) were told
that per-OS builds are how it works.

### 1.9 The architecture bonus

If the universal image is amd64, then on arm64 hosts it already has translators:
Rosetta 2 (Mach-O only), FEX-Emu and box64 on Linux, Windows-on-ARM's own x64
emulation, and Hangover for PE-on-arm64-Linux. An amd64 universal image would
therefore run *approximately everywhere*, natively on amd64 and translated on
arm64 — which is the practical portability wasm promises, without giving up
native code paths on the majority platform.

The honest version: translation costs 20–60% depending on workload, arm64 is
where new laptops are, and a two-architecture fat file (APE already does this) is
the sane answer. The bonus is a fallback, not a plan.

### 1.10 What Profile U would look like, if it existed
### 1.10.1 The True Universal Linux Engine: Static Binary + Micro-ELF Relocator + ABI Bridge

The fundamental barrier separating Profile S (fully static, zero host dependencies, works on Alpine/musl/scratch) from Profile H (glibc-dependent, loads host GPU/audio drivers via `dlopen`) is userspace ABI incompatibility:
1. A static binary has no `PT_INTERP` and cannot use host glibc's dynamic linker directly.
2. Host GPU drivers (`libGL.so.1`, Mesa `radeonsi_dri.so`, `libGLX_nvidia.so.0`, Vulkan ICDs) are linked against `libc.so.6` with versioned symbols (`GLIBC_2.2.5`..`GLIBC_2.34`) and expect glibc struct layouts and TLS (`%fs` allocation).
3. If an application links musl statically, musl's `dlopen` is a no-op stub and refuses to load glibc-linked shared objects.

We can achieve a **single, 100% universal profile** (Profile U) running on Alpine, Ubuntu, CentOS 7, NixOS, and bare container roots while accessing host GPU drivers by combining four demoscene-inspired architectural techniques:

#### A. In-Process Micro-ELF Relocator (`micro-ld`)
Instead of relying on the host's `/lib64/ld-linux-x86-64.so.2` or musl's dynamic linker:
- The application is built as a static-PIE executable (no `PT_INTERP`, no `DT_NEEDED`, starts via kernel direct ELF loading).
- It embeds a ~1,500-line minimal ELF relocator (supporting `R_X86_64_GLOB_DAT`, `R_X86_64_JUMP_SLOT`, `R_X86_64_RELATIVE`, `R_X86_64_64`, `R_X86_64_TPOFF64`, and `TLSDESC`).
- When `ob_host_open(OB_HOST_GL)` or `ob_host_open(OB_HOST_VULKAN)` is called, `micro-ld` reads the host's `.so` (or ICD) from `/usr/lib/` or `/usr/lib64/`, maps its `PT_LOAD` segments, and performs relocations in memory.

#### B. Synthetic Glibc ABI Translation Bridge (`glibc-bridge`)
Host GPU/audio libraries don't call arbitrary glibc internals; Mesa and NVIDIA drivers touch a very narrow subset (~60–80 functions):
- Memory management: `malloc`, `calloc`, `realloc`, `free`, `posix_memalign`, `mmap`, `munmap`, `mprotect`.
- Concurrency & synchronization: `pthread_mutex_*`, `pthread_rwlock_*`, `pthread_key_*`, `pthread_once`, `sched_yield`, `futex`/`sys_futex`.
- System calls: `ioctl`, `openat`, `close`, `read`, `write`, `poll`, `epoll_*`, `clock_gettime`.
- Environment & strings: `getenv`, `strcmp`, `strncmp`, `strlen`, `memcpy`, `memset`, `strchr`.

Because the **Linux kernel syscall ABI is identical** across all distributions, the bridge exports synthetic `libc.so.6` symbol entries directly from our static runtime. For functions where glibc and musl data structures differ (e.g. `struct stat`, `fstatat`, `ioctl` request encodings, `pthread_t` handles), the bridge translates the struct on the stack before and after dispatch.

#### C. Isolated Dual-TLS Allocator
Glibc `.so` modules often use Thread-Local Storage (Initial Exec `IE` or Local Dynamic `LD` models) and call `__tls_get_addr`.
- In musl static binaries, `%fs:0` points to musl's `pthread` control block.
- Overwriting `%fs:0` crashes musl; leaving it unhandled crashes the host driver.
- **Solution:** `micro-ld` allocates a private TLS slab for each loaded host module and provides a custom `__tls_get_addr` resolver that maps module-specific `(ti->ti_module, ti->ti_offset)` pairs to our private slab without perturbing `%fs:0`.

#### D. Direct ICD Driver Bypass for Vulkan
Instead of loading distro `libvulkan.so.1` (which might be missing on minimal distros like Alpine or Arch minimal), the engine reads `/usr/share/vulkan/icd.d/*.json` directly, locates the vendor driver (`libGLX_nvidia.so`, `radv_icd.so`, `iris_icd.so`), relocates it via `micro-ld`, and resolves `vkGetInstanceProcAddr` directly.

This removes the dichotomy between "Static" and "Hybrid": every binary is static, self-contained, and universal, while retaining full hardware acceleration on every desktop.

Purely to make the shape concrete. **This is not a specification.**

```
Profile U — one image, N heads

  image      one PE/COFF payload per architecture, containing the application,
             the toolkit, and every backend
  contract   ~200 named imports, versioned, machine-readable, enforced by
             `onebin audit --contract u1`
  heads      per-OS launcher stubs, tens of kilobytes each: on Windows the OS
             loads the image; elsewhere the head maps it, relocates it, binds
             the contract to its backend, and calls the entry point
  backends   selected at run time, not link time: win32 | wayland | x11 | cocoa
  layer 3    protocols over sockets wherever a protocol exists; generated
             thunks for Vulkan and GL; nothing else crosses the boundary
  audit      the contract check is the same tool, the same finding model, and
             the same badge as Level 1
```

Note what does *not* appear: an emulator, a bytecode VM, a host-installed
runtime, or a container.

### 1.11 What is worth reserving today, for free

None of the following costs v0.1 anything, and all of them are annoying to
retrofit:

1. **Reserve the profile letter `U`.** S, H, M, D are taken; do not spend U.
2. **Keep `ob_host_*` capability-oriented in its public API.** It already is —
   `ob_host_open(OB_HOST_VULKAN)` rather than `dlopen("libvulkan.so.1")`. The
   only thing that leaks is the `RTLD_*` flag language in the docs, which should
   be described as the Linux implementation's behaviour rather than as the API's
   contract.
3. **Never let anything use `/proc/self/exe` directly.** `ob_paths_self_exe()`
   exists; make it the only way, in our code and in the reference builds.
4. **Resources through `ob_res_*`, not through sibling files.** Already the plan
   for `onebin pack` (v0.4); a universal image makes it the only thing that
   works, which is an argument for not letting `$ORIGIN`-relative modules become
   load-bearing in the meantime.
5. **Record imports as (module, symbol) pairs in the audit's finding model**, not
   just as module names. The ELF backend does not need the symbol half today;
   the PE backend and any future contract check are much harder to add if the
   model cannot express it.
6. **Key `host-contract.toml` on capability first, soname second.** A Windows or
   macOS row should be a table entry, not a schema change.
7. **Do not describe the audit's core as "the ELF linter"** in the code layout.
   Format backends are already planned for v0.4; keep `elf/` a backend directory
   rather than the architecture.

That is the whole ask. Everything else in this section can wait for evidence.

### 1.12 The experiment that would settle it

This is a weekend, not a roadmap, and it is the only honest way to move any of
this out of this file:

1. **Measure the premise.** Take one real cross-platform application and
   determine what fraction of its binary is genuinely OS-specific. If the answer
   is 30% rather than 3%, the idea is much less interesting and we should say so
   here and stop. *Nobody appears to have published this number, which is
   suspicious in both directions.*
2. **Write the smallest possible PE loader** for a cooperating image on Linux:
   map, relocate, bind imports against a fifty-function table, set up TLS, call
   the entry point. Target: a `--version` that prints. Measure the line count
   honestly, including the parts that were skipped.
3. **Add one socket.** Have the PE image speak the Wayland or X11 wire protocol
   directly and open a window with no toolkit and no `libX11`. If this is easy —
   and the doctrine says it should be — then Layer 3 really is OS-neutral and
   §1.3 is more than rhetoric.
4. **Then try C++ exceptions**, because that is where the estimate breaks, and
   report the number before anyone gets attached to the idea.
5. **Try macOS early, not last.** If macOS cannot be made to work, the honest
   framing changes from "one binary everywhere" to "one binary for Windows and
   Linux, plus a Mac build" — still useful, much less exciting, and better known
   before than after.

### 1.13 Why we might be wrong

- The premise in §1.1 may be wrong. Toolkits may be far more OS-entangled at the
  object-code level than they look from the source. §1.12 step 1 exists to find
  out.
- The saving may not matter. Disk is cheap; CI time is cheap; three builds are
  already automated. "We ship 3× the bytes" is aesthetically offensive and may be
  economically irrelevant — although OS-neutral delta updates (§1.6) are a real
  operational win independent of the aesthetics.
- The failure mode in §1.7 is not hypothetical. If this becomes a compatibility
  project it will consume everything and deliver nothing, and this repository's
  actual deliverable is a linter that works.
- Somebody may have done this already and hit a wall we cannot see from here. If
  you are that person, the issue tracker is the right place, and we would rather
  hear it now.

---

## 2. A shared recipe database — the Homebrew-formula idea

**Status: idea only. Not scheduled. No format decided.**

`contrib/far2l/` and `contrib/f4-qt/` are already planned as pinned,
per-project build recipes (`deps.lock`, patches, toolchain notes) — see
`04-REFERENCE-far2l.md §10`, `05-REFERENCE-f4-qt.md §9`, and
`00-AGENT-TASK.md` Tasks 15+. Right now each is bespoke to its own project
and lives inside *this* repository.

The question worth asking once both exist: is `contrib/` actually the
seed of something more general — a shared, versioned collection of "how to
build X as Profile H/S" recipes, in the shape Homebrew formulae or nixpkgs
derivations are, but scoped narrowly to *this project's one job*
(reproducing a static/hybrid build, with pinned versions, a lockfile of
hashes, and an `onebin audit`-clean result as the acceptance test)?

Sketch, nothing more:

- One recipe per upstream project: pinned commit/tag, dependency lockfile
  (versions + hashes, per manifesto §5.1 and `04-REFERENCE-far2l.md`'s
  `deps.lock`), any patches needed, the exact `onebin`/CMake/Meson
  invocation, and the expected audit result (profile, level) as a
  regression check for the recipe itself.
- Discoverable and browsable independently of this repository's own
  history — closer to `homebrew-core`'s one-formula-per-file model than to
  a monorepo's `contrib/` folder, so a third project (not far2l, not f4-qt)
  can add its own recipe without touching anything else.
- The two recipes this project is already committed to building
  (`04-REFERENCE-far2l.md`, `05-REFERENCE-f4-qt.md`) become the first two
  entries and the proof the format is real, not the only two entries
  forever.

Open questions, deliberately unanswered here: does this live in this
repository under a promoted `recipes/` (or `formulae/`) top-level directory,
or as a separate repository this project points at, the way Homebrew
separates `brew` (the tool) from `homebrew-core` (the formulae)? Does
`onebin` ever gain a `onebin build <recipe>` verb, or does a recipe stay a
plain shell script `tools/build-*.sh` already produces, just catalogued
somewhere browsable? Does a recipe format need its own schema/lint, or is
"a `deps.lock` plus a build script plus a golden audit result" enough
structure on its own?

**Do not build this now.** `contrib/far2l/` and `contrib/f4-qt/` should
exist and prove themselves as bespoke, per-project directories first (Tasks
15+); generalising the format before there are at least three real recipes
to compare would be designing in a vacuum. Revisit once far2l's and f4-qt's
own `contrib/` entries exist and a third candidate shows up.

### Why not just use Nix?

A fair question, asked directly: nixpkgs is already a shared, versioned
recipe database at enormous scale, and `pkgsStatic` already automates
"rebuild this dependency graph statically, from pinned sources." Doesn't
that make a from-scratch recipe collection redundant?

Two honest reasons it doesn't, plus one thing worth taking:

1. **Adopting Nix is the cost this whole project is designed to avoid
   asking for.** The manifesto's Quick Start is "keep your existing
   CMake/Meson/Autotools build, add a toolchain file and a few flags."
   Nix asks a maintainer to accept the Nix language, the daemon, the
   `/nix/store` layout, and a different mental model for their build —
   real value, but a materially larger ask than "point
   `CMAKE_TOOLCHAIN_FILE` somewhere." far2l is the reference application
   specifically because it is an existing, unmodified, unconverted GPLv2
   CMake project; a recipe collection scoped to "the smallest patch that
   makes an existing build static-and-audited" is answering a different
   question than "port this package into nixpkgs."
2. **`pkgsStatic` rebuilding cleanly does not mean the result passes an
   audit — the same lesson `f4-qt` and far2l's own build already taught
   this project twice.** `pkgsStatic` has years of open issues (musl being
   forced when it shouldn't be, `libc++` exceptions under static linking,
   `gcc`/`bintools` target-prefix mismatches) that are evidence rebuilding
   the world statically is hard even with Nix's substantial automation —
   not a criticism of Nix, a confirmation that "it built" and "it's
   actually clean" are different claims, which is this project's entire
   reason to exist. Nothing here competes with that: **`onebin audit`
   doesn't care how a binary was built.** A `pkgsStatic` output is exactly
   as auditable as a CMake one; the tool is agnostic on purpose.
3. **What's actually worth taking from Nix, if this is ever built:**
   content-addressed storage of build inputs by hash, and treating a
   pinned commit + a lockfile of hashes as the unit of reproducibility —
   both already partially present in `contrib/far2l/deps.lock`'s design,
   worth deliberately keeping if a shared format is ever built.

The two are complementary, not competing: a `pkgsStatic`-built far2l and a
`zig cc`-built one are both legitimate inputs to the same `onebin audit`.
Recorded because it's worth being explicit about, not because there's a
decision to make yet.

---

## 3. `libwinescape` — the same doctrine, worked from the other side of Wine

**Status: idea recorded, one fact confirmed by a live experiment, no library
written yet. Full task spec lives in the other repository (§3.5) so it does
not have to be duplicated or kept in sync by hand.**

§1 asks what happens if *we* carry a small, audited loader instead of asking
Wine to run arbitrary Windows binaries. This section is the mirror image:
what happens if a binary that is genuinely, honestly Windows-shaped —
compiled with a normal Windows toolchain, runs on real Windows with no
caveats — *also* notices when the thing underneath it happens to be Wine, and
in that one case reaches past Win32 for the parts of the doctrine's Layer 3
that Wine already exposes a path to, instead of paying the Win32-to-POSIX
translation tax on every syscall. Same doctrine — *talk to the host by
protocol, not by ABI* — applied by a guest that already knows it is a guest,
rather than by a loader we wrote ourselves.

### 3.1 What's already true, independently of this idea

This project ([unxed/f4](https://github.com/unxed/f4), also the upstream
behind [05-REFERENCE-f4-qt.md](./05-REFERENCE-f4-qt.md)) already does the
Layer-3-is-a-protocol thing §1.3 describes, and does it a second way that
§1.3 doesn't mention yet: its terminal UI library (`vtui`) speaks the X11
wire protocol directly over a socket, via a pure-Go client
([`jezek/xgb`](https://github.com/jezek/xgb), no `libX11`), and that code
already cross-compiles under `GOOS=windows` and is already reachable from a
Windows build via `--gui=x11` — untested under Wine as of this writing, but
zero new code away from being tested. That's the same claim §1.3 makes about
f4-qt's Go binary opening X11/Wayland windows with no client library, from a
sibling codebase, arrived at independently.

### 3.2 The experiment that's already been run

§1.12 step 2 proposes measuring, empirically, whether "the guest cooperates"
(§1.5) is really enough to keep a Windows-shaped loader small on Linux. A
version of that same question — does a cooperating, unprepared guest get a
real syscall through, with nothing registered, nothing negotiated, no
`unixlib`-style boundary declared on either side — has an answer now, from
the opposite direction:

A `GOOS=windows GOARCH=amd64` binary containing one hand-written function —
a bare `SYSCALL` instruction, `AX=39` (Linux's `getpid`) — run under real Wine
(tested independently on Wine 9.0 and by the project's own maintainer on
their machine), returned a value that exactly matched the host's actual PID
for the `wine64` process, as cross-checked against `ps` on the host. Not a
crash, not an emulated/ignored instruction, not a value that merely looked
plausible — the literal PID, confirmed twice, on two different machines.

That is one data point, for one syscall, with no pointer arguments, on one
architecture, under one Wine version — nowhere near "the API surface is
bounded and small like §1.5 wants." But it is real, it cost about ten lines
of assembly and no negotiation with Wine at all, and it is independent
evidence for exactly the premise §1.5 argues from analogy: **a cooperating
guest doesn't need Wine's unbounded compatibility surface, because it never
asked Wine to interpret anything — it went straight to the kernel's own
protocol**, which is arguably the *most* boring, stable, wire-format-shaped
interface either project touches. Full writeup, exact bytes, and the caveats
about what one `getpid()` call does and doesn't prove:
[unxed/f4, `WINE.md` §5/§11–§12](https://github.com/unxed/f4/blob/main/WINE.md).

### 3.3 Where it agrees with §1, and where the two projects would collide productively

- **Same wall, different reason.** §1.7 calls macOS "the wall" for the
  from-scratch-loader direction, because of code signing, the hardened
  runtime, and `%gs`/`x18` already being spoken for. The Wine-side direction
  hits a *different* wall on the same two platforms: Wine on OpenBSD refuses
  a raw `SYSCALL` whose entry point isn't inside `libc.so` (`pledge`/
  `msyscall`), and Wine on Darwin needs the call routed through
  `libSystem.dylib` for the same reason Go's own runtime stopped doing raw
  syscalls there. Neither wall is the other's wall, but both projects
  converge on "Linux and the BSD-family-that-isn't-OpenBSD are fine, macOS
  is where the trick stops working" from two unrelated codebases and two
  unrelated mechanisms. That convergence is itself worth something.
- **Complementary, not competing.** §1 wants to stop needing three builds by
  carrying a loader. This idea keeps the three builds — the Windows build is
  a completely ordinary Windows build — and only spends effort on the case
  where Wine happens to already be present, which is strictly less ambitious
  and strictly cheaper to abandon if it doesn't pan out: worst case, the
  Windows binary runs on Windows exactly as it always did, and under Wine it
  falls back to normal Win32 (this is already how `WINE.md` requires every
  part of the f4 work to degrade — see its rule "деградация обязательна и
  молчалива").
- **`onebin audit`'s bounded-contract idea applies here too**, in miniature.
  §1.5's insight — a linter that bounds the imported surface is what keeps a
  loader small — has a direct analogue for a syscall trampoline library:
  the whole safety argument for `libwinescape` (§3.5) resting on a *small,
  explicitly enumerated table* of syscalls with numbers taken from ABI
  documentation, never invented, is the same discipline in a different
  format (a spec table instead of an ELF/PE import list).

### 3.4 Where it's weaker evidence than §1 wants

Worth being honest about, in the spirit of §1.13: this is not proof that a
from-scratch PE loader (§1) would have an equally easy time. Wine has spent
decades making its *existing*, sanctioned code paths (the ones that go
through `ntdll`/`kernel32`) work; a bare `SYSCALL` from ordinary `.text` that
Wine's own JIT/exception machinery never expected to see executing a trap
instruction is arguably an *easier* case for a hypervisor-like layer to get
right than the full unwinding/exception/TLS story §1.7 worries about for a
ground-up loader — `getpid()` doesn't touch any of that. Do not read §3.2 as
"therefore exceptions and TLS are also fine"; it settles nothing about §1.7's
actual hard parts.

### 3.5 What would settle more of it, and where that work is happening

Not in this repository — the project is a general-purpose syscall trampoline
library, useful to any Windows-shaped codebase under Wine, not specific to
static-everywhere's own scope. Recorded here only as a cross-reference, in
the spirit of this file's own stated purpose — argued in public rather than
rediscovered in private — with a pointer to where the actual work lives:

- **Design and full task spec:** `WINE.md` §5 (Stage B1b) and §12 (Part D) in
  [unxed/f4](https://github.com/unxed/f4/blob/main/WINE.md) — calling
  conventions actually verified (Linux amd64/arm64, FreeBSD amd64's carry-flag
  error signalling, explicitly *not* assumed for NetBSD/DragonFly/BSD-arm64
  until probed), the generic-trampoline-per-(OS,arch) architecture, and a
  two-tier test plan: a portable tier that runs without Wine, and a
  Wine-required tier that — like everything in this file marked "idea only"
  — is not meant to run in normal CI, only ahead of a release.
- **The library itself:** `github.com/unxed/libwinescape`, not yet published.
  When it exists, add it to this bullet and, if it reaches Level 1-shaped
  discipline on its own terms (small enumerated syscall surface, audited, no
  invented ABI facts), it's a candidate for its own row in `CONFORMING.md` —
  though note it's the wrong *kind* of project for that file (a syscall
  trampoline library isn't a Profile S/H binary), so that would need its own
  conversation, not an assumption.
  UPD: implemented, published

---

## 3.5 The synthesis: APE-style polyglot + `libwinescape` = one binary, one architecture, every OS

**Status: idea only, prompted by reading `libwinescape`'s own README next to
Cosmopolitan's. Not scheduled. macOS explicitly unresolved — see the end of
this section.**

§1 and §3 above are two answers to two different halves of the same
question, and reading them side by side is what this section is: §1 asks
"how does *our own code* reach the host on an OS it wasn't compiled for",
and answers it with a carried loader. §3 asks "how does a *genuinely native*
Windows binary reach past Win32, when the thing underneath it happens to be
Wine", and answers it by having the guest notice and cooperate. Cosmopolitan
already ships the third piece neither of those sections needed on its own:
**one file, valid as more than one native format at once**, dispatched by
magic bytes the kernel (or `binfmt_misc`) recognises directly, no loader
process involved before the OS's own loader takes over.

Put together:

1. **The file is a polyglot**, the way APE already is: bytes 0–1 are a valid
   PE/MZ header (`MZqFpD` is the literal four-byte APE magic Cosmopolitan's
   own `binfmt_misc` registration matches on), and the same bytes are
   *also* a valid ELF header, and *also* a valid Mach-O header, each format
   pointing its own loader at a different, non-overlapping region of the
   same file. This is solved, shipping, and does not need reinventing —
   it's Cosmopolitan's actual mechanism, not a proposal.
2. **The ELF payload is an ordinary Static Everywhere binary** — Profile S
   or H, built and audited exactly as this project already does, with none
   of Cosmopolitan's own libc or its `--strace`/`--ftrace` machinery. On
   Linux, the kernel's own ELF loader runs it directly. Zero Wine, zero
   translation, zero involvement of anything this section is about — this
   is the fast path, and it is just this project's existing reference
   build.
3. **The PE payload is a genuinely, honestly Windows binary** — built with
   a normal Windows toolchain, linking normal Win32 DLLs, running on real
   Windows with zero caveats, the same as any other `.exe`. This is what
   makes it a `libwinescape`-shaped binary rather than a Cosmopolitan-shaped
   one: it is not compiled against a universal libc that reimplements every
   OS's syscalls from scratch. It is a real PE binary that happens to also
   be readable as an ELF from a different offset.
4. **`libwinescape`'s trick is what makes the PE payload interesting when
   it *is* run through Wine specifically** — rather than paying Win32's
   full translation tax on every call, the guest notices Wine underneath it
   (§3.2's `getpid()` experiment) and reaches past Win32 for the parts of
   Layer 3 Wine already exposes a stable path to. This matters only for the
   case Cosmopolitan's own README flags as a real hazard: "some Linux
   systems are configured to launch MZ executables under WINE" via
   `binfmt_misc` — meaning a `chmod +x` polyglot file, double-clicked or
   `exec`'d without an explicit interpreter, could in principle be picked
   up by Wine's own `binfmt_misc` entry *instead of* the kernel's native
   ELF path, depending on registration order and which entry matches first.
   `libwinescape` is what keeps that accidental path from being the slow
   one — if Wine ends up running the PE side regardless of intent, the
   binary still notices and still reaches past Win32.

**What this is not:** a claim that the two projects' loaders need to merge,
or that this project should adopt Cosmopolitan's libc, or that
`libwinescape`'s syscall table needs to grow to cover general Layer 3 work.
It is an observation that the three pieces — a shipping polyglot-dispatch
mechanism, an audited Static Everywhere ELF payload, and a
cooperating-guest PE payload — are independently real and slot together
without new engineering, which is the same kind of "the pieces already
exist, nobody assembled them for this" observation §1.8's prior-art table
makes about the loader idea generally.

**Genuinely unresolved, not glossed over: macOS.** §1.7's "macOS is the
wall" paragraph applies here without modification — Rosetta translates
Mach-O, not PE, so there is no Wine-shaped compatibility layer to notice
and cooperate with the way `libwinescape` does on Linux, and code signing
still assumes a single, honest Mach-O the notary can inspect. A three-way
polyglot (ELF/PE/Mach-O in one file) is exactly what Cosmopolitan already
does, so the *file format* problem is solved; what's missing is a macOS
equivalent of "the guest notices it's running under a translator and
reaches past the slow path" — Rosetta 2 does not expose anything
comparable to what Wine exposes, as far as this section's author has
found. Left open rather than assumed away.

---

---

## 4. What else belongs in this file

Ideas that are not ready to be proposals, but should not be lost. Open a PR that
adds one, in the same shape: what it is, why nobody did it, where it breaks, and
what experiment would settle it.

- **The universal `~/Apps` catalogue.** If enough applications adopt §7.2 of the
  manifesto, `~/Apps` becomes machine-readable by accident: a directory listing
  is an inventory, and a `.onebin-app.json` beside each binary would make
  "update everything I installed myself" a fifteen-line shell script rather than
  a package manager. Deliberately not proposed yet — the convention should earn
  adoption before it grows features.
- **Reproducible-build attestation as the SBOM's other half.** We ask projects to
  publish an SBOM; a rebuilder attestation would let a third party prove the
  binary matches the sources without trusting the publisher's CI.
- **Tier 3 desktop integration:** consider trying system GTK (and perhaps Qt)
  to improve integration with the desktop.

---

*Companion to [STATIC-EVERYWHERE.md](./STATIC-EVERYWHERE.md) and
[DESIGN-onebin.md](./DESIGN-onebin.md). Nothing here is a commitment. Arguments
against are worth more than agreement — especially from people who have written a
loader, shipped a Qt application on three platforms, or worked on Wine.*
