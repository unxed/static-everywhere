# Conforming projects

Projects that ship according to [Static Everywhere](./STATIC-EVERYWHERE.md), and at what [level](./README.md#conformance-levels).

| Project | Level | Profile | Baseline | Audit | Notes |
|---|---|---|---|---|---|
| *(be the first)* | | | | | |

---

## The reference application

Not a conforming project — a *target*. This repository owes the argument at least
one real program that it did not write, cannot simplify, and does not control.
That program is [far2l](https://github.com/elfmz/far2l): a fork of FAR Manager v2
with a terminal backend, two graphical backends, a `dlopen`'d plugin ABI, a helper
process and a GPLv2 licence.

| Build | Target level | Profile | Baseline | Status |
|---|---|---|---|---|
| `far2l-tiny` — terminal only, no plugins | 1 | S | musl | not built yet |
| `far2l-tty` — terminal + plugins + X11 helper | 1 | H | 2.28 | not built yet |
| `far2l-sdl` — SDL graphical backend | 1 | H | 2.28 | not built yet |
| `far2l-wx` — wxWidgets graphical backend | 0 | H | 2.28 | **expected to fail Level 1**; kept to measure how badly |

Upstream far2l has made no commitment to any of this and has not been asked to.
The work is ours; the row above moves into the table only when there is a CI link
to point at. Details, build instructions and the running list of things far2l has
already forced us to change are in
[04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md).

## The Qt reference application

[f4-qt](https://github.com/Zoinen/f4/tree/zoin) — a Go file manager with a static
Qt Quick front end, pinned for our purposes at commit `1a03511`. Unlike far2l,
this project reached the same conclusions independently and enforces them in its
own CI; we are measuring against it, not converting it.

| Build | Target level | Profile | Baseline | Status |
|---|---|---|---|---|
| `f4-qt-linux` — one Go executable with a static Qt host inside | 1 | H | 2.27 | ships upstream; **not yet reproducible by us** |
| `f4-qt-windows` — one `.exe`, static CRT | 1 | H | — | ships upstream |
| `f4-qt-macos` — signed, notarised `.app` | 2 | — | 13.0 | different contract by design |
| `f4-tty` — the Go core alone, `CGO_ENABLED=0` | 1 | S | — | ships upstream |

The blocker on the first row is a private submodule (`third_party/ZoinGallery`),
not a technical one. Details and the two acceptable fixes are in
[05-REFERENCE-f4-qt.md §7.8](./05-REFERENCE-f4-qt.md).

## The GNOME reference application

[GNOME Terminal](https://gitlab.gnome.org/GNOME/gnome-terminal) is the GNOME
reference target. Its GTK3, libhandy, VTE and text/rendering dependencies are
intended to be linked statically from the pinned dependency prefix described in
[06-REFERENCE-gnome-terminal.md](./06-REFERENCE-gnome-terminal.md).

| Build | Target level | Profile | Baseline | Status |
|---|---|---|---|---|
| `gnome-terminal-hybrid-static-gtk` — hybrid profile with static GTK3 `gnome-terminal-server` | 1 | H | 2.28 | build recipe in progress |

## Prior art that does not conform, and is worth studying anyway

[far2l-portable](https://github.com/spvkgn/far2l-portable) ships far2l as one
runnable artifact for five architectures by taking the **opposite** bet to this
doctrine: instead of removing dependencies, it carries every one of them,
including the loader, and rewrites RPATH and `PT_INTERP` with `patchelf`.

Under our own audit it scores **Level 0** — dozens of unlisted `DT_NEEDED`
(`OB0010`), an unrecognised interpreter (`OB0037`). It also works, has users,
and reaches more architectures than our own reference build currently targets.

Both facts are true at once, and keeping them both visible is the point: **these
levels measure conformance to this doctrine, not whether something works for
people.** A bring-everything bundle and a static binary are two different bets
about where fragility lives. The write-up, including the `PT_INTERP`/`$ORIGIN`
constraint it uncovered for our own Profile D proposal and its measured
musl-vs-glibc size delta, is
[04-REFERENCE-far2l.md §12](./04-REFERENCE-far2l.md).

**If you maintain a project shaped like far2l** — plugins, multiple UI backends, a
toolkit dependency you can't drop — the interesting rows are the ones that fail.
Send those too.

---

## Adding your project

Open a pull request adding a row. Requirements:

- **Level 0–1** — link to a CI job that runs an audit (`tools/audit.sh` or `onebin audit`) on the released artifact and to a release page where the single binary is downloadable.
- **Level 2** — additionally, a link to the code or docs for first-run desktop integration and `--uninstall`.
- **Level 3** — additionally, a link to your published SBOM and a one-line description of your update signing scheme.

Fill in:

- **Profile** — `S` (fully static, musl) or `H` (hybrid, pinned glibc)
- **Baseline** — `musl` for Profile S, or the glibc version for Profile H (e.g. `2.28`)
- **Audit** — link to the passing CI run

No project is too small, and *especially* no project is too unglamorous. A conforming `grep` clone is worth more to this argument than an aspirational GUI framework.

## Notable non-conforming prior art

Projects that arrived at most of this independently, before the document existed. Listed for evidence, not endorsement, and with no claim that they'd sign anything:

| Project | What they got right |
|---|---|
| Telegram Desktop | Single binary, user-writable install location, self-updating, native-feeling |
| Blender | Pinned old glibc baseline, everything else bundled, one archive |
| Sublime Text | Ancient baseline, one directory, self-updating |
| Godot | Single-file editor binary, runs on effectively any distro |
| Steam & most games on it | Hybrid profile, `dlopen` for GPU, ships its own everything |
| SDL | The reference implementation of the Layer-3 doctrine |
| Most Go and Rust CLI tools | Profile S by default, without ever calling it that |

If you maintain one of these and want a real row in the table above, we'd be glad to have you.
