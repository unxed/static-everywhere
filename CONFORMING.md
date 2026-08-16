# Conforming projects

Projects that ship according to [Static Everywhere](./STATIC-EVERYWHERE.md), and at what [level](./README.md#conformance-levels).

| Project | Level | Profile | Baseline | Audit | Notes |
|---|---|---|---|---|---|
| *(be the first)* | | | | | |

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
