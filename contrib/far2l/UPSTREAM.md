# Changes far2l would need for a better Static Everywhere result

Proposals for far2l's maintainers to consider, not demands. Everything
below is traceable to findings already written up in
[`04-REFERENCE-far2l.md`](../../04-REFERENCE-far2l.md) — this file adds
no new claim about far2l's source.

## 1. NULL-check the `dlsym(RTLD_DEFAULT, ...)` calls in `InstallPath.cpp`

`utils/src/InstallPath.cpp`'s `TranslateInstallPath` (both the
`std::wstring`/`GetPathTranslationPrefix` and the
`std::string`/`GetPathTranslationPrefixA` overload) resolves a function
pointer via `dlsym(RTLD_DEFAULT, ...)` and calls through it
unconditionally. In a statically linked build there is no dynamic symbol
table for `dlsym` to search, the lookup returns `NULL`, and the very next
statement calls through it — during startup path resolution, so the
process segfaults before any UI appears. Full detail, reproduction, and
a suggested minimal fix: `04-REFERENCE-far2l.md §2.5`.

This is the one change that would matter most: it's the sole reason a
fully static (Profile S) far2l build cannot even start, as opposed to
merely being architecturally out of scope for one.

## 2. Static registration of plugins, so Profile S can have them

far2l's plugins are `dlopen`'d shared objects
(`04-REFERENCE-far2l.md §3.3`), which is exactly what a fully static
Profile S binary cannot do — no dynamic loader, no `dlopen`. A plugin
system that could, as an alternative *build-time* configuration, link
plugins in statically and register them through a static table (each
plugin's entry points collected into an array the core iterates, instead
of a runtime `dlopen`/`dlsym` scan of a plugins directory) would let a
Profile S far2l build ship a fixed, curated plugin set — no dynamic
loading, but not zero plugins either. This is a build-system-level
alternative registration path, not a requirement to remove the existing
`dlopen`-based one; hosts that want runtime-loadable third-party plugins
keep exactly what they have today.

We haven't attempted this ourselves and aren't proposing a specific
implementation — flagging the shape of the gap, since `04-REFERENCE-far2l.md
§7.3` already establishes that Profile S has no plugins today, and this is
the concrete mechanism that would change that.

## 3. Document (or reconsider) the `sudo`/`askpass` re-exec-through-symlinks design

`far2l_sudoapp` and `far2l_askpass` are symlinks to `bin/far2l` itself —
far2l launches `sudo`, which launches far2l again in a different mode,
talking back over IPC (`04-REFERENCE-far2l.md §2.5`, `WinPort/src/sudo/
sudo_client.cpp`). This works correctly and is invoked in the portable,
`$PATH`-based way (`execlp`, not a hardcoded path) — nothing here is a bug.
It cost real time to understand from the install layout alone, though:
the two symlinks' purpose isn't obvious without reading the sudo client
code directly. A short comment in the CMake install rule that creates
them, or a line in `HACKING.md`, pointing at `sudo_client.cpp` would have
saved that time for the next person reading the install tree from the
outside.

## 4. `far2l-tiny` (Profile S) as a documented, minimal, unsupported-but-buildable target

Once item 1 is fixed, a config resembling what
`04-REFERENCE-far2l.md §6.1` describes (`-DUSEWX=no -DUSESDL=no
-DTTYX=no -DNETROCKS=no -DMULTIARC=no -DCOLORER=no -DUSEUCD=no`, built
statically against musl) produces a real, running terminal-only file
manager with an empty `DT_NEEDED`. Whether far2l's maintainers want to
carry this as an officially supported configuration is entirely their
call — but if item 1 lands, it becomes buildable, and worth a line in
`CMakeLists.txt` or the docs noting that this combination is known to
produce a working binary, for anyone who goes looking.

## 5. Exit-time segfault: a `dlclose()`'d plugin's `__cxa_atexit`-registered destructor

Confirmed via two full `gdb` sessions (breaking on every `__cxa_atexit`
call and comparing the recorded TLS pointer-guard cookie against the
crash point — see `04-REFERENCE-far2l.md` for the detailed writeup, or
`STATUS.md`'s history in this repository): `far2l` reliably segfaults on
normal exit, inside glibc's `__run_exit_handlers`, calling through a
function pointer that resolves to unmapped memory.

The evidence points specifically at `far2l/src/plug/plclass.cpp:90`'s
`dlclose(m_hModule)` call when unloading a plugin. If a plugin has any
`static` C++ object with a non-trivial destructor (a config cache, a
logger, anything), `__cxa_atexit` registers that destructor to run at
*process* exit regardless of which module constructed it — but the
plugin's code and data are unmapped the moment `dlclose()` runs. The
next `exit()` call (this one, or possibly any later one) then calls
through a dangling function pointer into memory that used to be that
plugin.

This is a well-known, well-documented class of bug for any
`dlopen`/`dlclose`-based plugin architecture, unrelated to any particular
toolchain — it would surface the same way built with GCC, Clang, or
`zig cc`. Two standard fixes, in order of simplicity:

1. **Don't `dlclose()` at all.** Leak the mapping — the address space
   cost is negligible for a file manager's lifetime, and it's the
   standard, widely-used workaround for exactly this class of bug.
2. **Call `__cxa_finalize(m_hModule)` immediately before `dlclose()`.**
   This explicitly runs (and de-registers) every `__cxa_atexit` handler
   whose home module is `m_hModule`, leaving nothing dangling for the
   later real `exit()` to trip over — the more surgical fix if leaking
   the mapping is undesirable.

We have implemented the first fix implicitly for our reference builds by
adding `-Wl,-z,nodelete` to `onebin-linux-hybrid.cmake` and our Meson
native file. This prevents the dynamic linker from ever unmapping the plugins,
keeping their destructors valid at exit. No patch to `far2l` source code
is required to achieve this, but upstream might still want to adopt one
of the fixes for downstream packagers who do not use `-z nodelete`.

## 6. `utils/include/debug.h` guards `<execinfo.h>` on a macro no libc defines

`utils/include/debug.h` decides whether to include `<execinfo.h>` and
define `HAS_BACKTRACE` with:

```c
#if !defined(__FreeBSD__) && !defined(__NetBSD__) && !defined(__DragonFly__) \
    && !defined(__MUSL__) && !defined(__UCLIBC__) && !defined(__HAIKU__) \
    && !defined(__ANDROID__)
# include <execinfo.h>
# define HAS_BACKTRACE
#endif
```

The intent is clear and correct: musl has no `backtrace()` at all, so the
header must not be included there. But **nothing defines `__MUSL__`**.
musl deliberately provides no macro identifying itself, and `__MUSL__` is
a downstream invention that only exists if a build system passes `-D`.
So on a musl build the guard does not fire, `<execinfo.h>` is included,
and what gets found is whatever the include path happens to offer — on a
typical CI host, glibc's `/usr/include/execinfo.h`, which opens with
`__BEGIN_DECLS` and does not parse outside glibc. The failure surfaces
several cascading errors later, in `cxxabi.h`, with the parser already
derailed.

The use site is already guarded properly (`#ifdef HAS_BACKTRACE` at
`debug.h:540`), so only the include condition needs to change.

A robust form tests availability rather than libc identity, and matches
the idiom `debug.h` already uses a few lines below for `<cxxabi.h>`:

```c
#if !defined(__FreeBSD__) && !defined(__NetBSD__) && !defined(__DragonFly__) \
    && !defined(__UCLIBC__) && !defined(__HAIKU__) && !defined(__ANDROID__)
# if !defined(__has_include) || __has_include(<execinfo.h>)
#  include <execinfo.h>
#  define HAS_BACKTRACE
# endif
#endif
```

This keeps every existing platform exclusion (the BSD ones are about
`-lexecinfo`, not availability, so they must stay), drops the macro that
never fires, and additionally covers any other libc without the header.

**No patch to far2l is carried for this.** Static Everywhere passes
`-D__MUSL__` for musl targets
(`onebin/toolchain/onebin-linux-static.cmake`), which makes the existing
guard mean what it says — supplying an input the source already tests
for rather than modifying the source. The suggestion above is offered
because the next person to build far2l against musl without that flag
will hit the same wall.
