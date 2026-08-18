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
