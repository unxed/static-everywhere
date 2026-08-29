# REFERENCE — GNOME Terminal, the GNOME reference application

**Status: probe works and passes; the build is a plan.**

This document is the GNOME counterpart to
[04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md) and
[05-REFERENCE-f4-qt.md](./05-REFERENCE-f4-qt.md). Same obligation, same rule:
everything here that is stated as fact was measured on a real machine, and
everything that was not measured says so.

---

## 1. Why GNOME Terminal

The manifesto currently treats GTK as the thing that cannot be bundled —
`far2l-wx` is target level 0 *by design*, and the README says GTK "arrives
through wxWidgets and cannot be bundled". That is an assertion the project has
never tested. GNOME Terminal is the cheapest way to test it honestly:

- it is a **real** GNOME application, not a demo, with a shipped Debian package
  whose dependency list we can read instead of infer;
- it exercises every part of the stack this project has been worried about —
  loadable modules, GSettings including a relocatable schema, a font stack that
  has to look native, a PTY, and a D-Bus-activated single-instance app-id;
- it is small. VTE plus GTK3 is a much smaller graph than Nautilus, and it has
  no plugin ABI at all — which, per §4.1 below, removes the single most
  dangerous failure mode before we start.

## 2. Facts

Measured against the shipped Ubuntu 24.04 package, by reading
`gnome-terminal-server`'s own `DT_NEEDED`, not upstream's `meson.build`:

| | |
|---|---|
| Version | 3.52.0 |
| Toolkit | **GTK 3.24**, not GTK4 |
| Adwaita layer | **libhandy-1**, not libadwaita |
| Terminal widget | libvte-2.91 (VTE 0.76) |
| `DT_NEEDED` count | 14 |
| Structure | client + `gnome-terminal-server`, D-Bus activated |
| App-id | `org.gnome.Terminal` |
| Schemas | 2 fixed, 2 **relocatable** (`Legacy.Profile`, `Legacy.Keybindings`) |
| Settings backend | dconf, via a GIO module |

**The GTK3 finding matters and was nearly assumed away.** "GNOME 46 application"
reads as GTK4 + libadwaita, and it is neither. This has a direct consequence:
[probe report II](#) established that the settings-portal appearance
integration lives in libadwaita and *not* in GTK itself. GNOME Terminal
therefore does not get host dark-mode integration for free, and a bundled build
must either reimplement the `org.freedesktop.portal.Settings` client or accept
that it will not follow the host's appearance.

## 3. What `gt-probe` is, and why it exists

`contrib/gnome-terminal/probe/gt-probe.c` links exactly GNOME Terminal's
dependency set and then *uses* each piece hard enough that a lazily-resolved or
`dlopen`'d component cannot stay unloaded and still pass. It answers in about
thirty seconds the questions a multi-hour build would otherwise answer at
minute ninety.

It is deliberately not a hello-world. Each exercise is chosen because a
weaker version of it would produce a false pass:

| Exercise | Why the obvious weaker version does not work |
|---|---|
| Spawn `/bin/sh -c 'exit 42'` on a real PTY and check the status | Constructing a `VteTerminal` proves only that the symbol resolved. Reading the screen back instead was rejected because `vte_terminal_get_text_range` has churned across releases and a probe that stops compiling teaches nobody anything. |
| Compile a `VteRegex` | pcre2 is reachable from nothing else in the program, and in GNOME Terminal itself only from search. |
| Encode a PNG through gdk-pixbuf | Listing formats does **not** load a loader module: the list comes from the module cache file, which can advertise formats the build cannot actually use. |
| Shape mixed-script text, require non-zero ink | A `PangoLayout` with no usable font resolves silently and reports zero extents. That is precisely the symptom of a bundled fontconfig not pointed at the host's fonts. |
| Instantiate the **relocatable** profile schema at a generated UUID path | A build that ships only the fixed schemas fails when the user opens preferences, not at startup. |
| Register `org.gnome.Terminal` and report remoteness | See §4.2. |

Then it reads `/proc/self/maps` and checks the result against
`contrib/gnome-terminal/probe/host-contract.txt`. That comparison is the actual
deliverable: *everything loaded* becomes a measurement rather than a hope.

### 3.1 Why a runtime contract and not `DT_NEEDED`

`tools/audit.sh` reads `DT_NEEDED`, which cannot see anything arriving by
`dlopen`. For a GTK application the `dlopen`'d set is much larger than the
linked set — a probe build has **4** `DT_NEEDED` entries and ends with **92**
mapped objects. Both checks are needed and neither subsumes the other.

## 4. Collisions with the doctrine

### 4.1 No plugin ABI, therefore no `-rdynamic`, therefore no collision

Probe report I (§A) established that the two-glib collision is a property of
**exporting**, not of bundling: a plain executable's statically linked symbols
never reach `.dynsym`, and a host module `dlopen`'d into it binds to the host's
own copy. Only `-rdynamic` — which an application with a plugin ABI needs —
reverses that, and then the host module binds to *our* copy and shares its
mutable state.

GNOME Terminal has no plugin ABI. `tools/build-gt-probe.sh` therefore does not
pass `-rdynamic`, and `tools/test-gt-probe.sh` fails if it ever reappears.
This is the single largest reason GNOME Terminal is an easier target than
far2l, and it was not obvious before it was measured.

### 4.2 The app-id hands the window to somebody else

`org.gnome.Terminal` is a D-Bus-activated single-instance application. A
bundled build carrying the same app-id is answered by the host's already-running
`gnome-terminal-server`: the user launches our binary and gets theirs, with no
error anywhere. Reproduced in probe report I §E, and reproducible with
`gt-probe` on any machine with GNOME Terminal running.

There is no ELF-level signature for this, so `onebin audit` cannot catch it
statically. It has to be a rule: **a bundled build must not claim the upstream
app-id.** `gt-probe` reports remoteness by default and treats it as an error
under `--strict`, because in CI there is no host server and being remote there
means something is genuinely wrong.

### 4.3 Neutering GIO modules has a price, and the price is enumerable

Probe report I §D measured it: `GIO_MODULE_DIR=/nonexistent` takes the host's
GIO module mappings to **zero**, and costs the proxy resolver (falls back to
`GDummyProxyResolver`), the TLS backend, and dconf. `gt-probe` confirms the
live path — a normal run maps `libdconfsettings.so` and reports
`DConfSettingsBackend` as the answering backend.

So neutering is the safety floor, not a shippable answer. Each lost capability
must be bought back by linking its client statically and registering it through
`g_io_extension_point_implement`. Four modules, four known tasks.

### 4.4 The GLX and EGL paths have different host contracts

Probe report II measured the GTK4/EGL path. `gt-probe` on GTK3 takes the GLX
path, and the two `dlopen` deltas differ: `libXxf86vm` and `libpciaccess`
appear only on the GLX side. Both sets are in the contract file, marked as
found by running rather than by reasoning. **The host contract is per-backend,
not per-application** — a distinction the manifesto's single "about ten
sonames" figure does not currently make.

### 4.5 Mesa's closure is the real collision surface

Also from probe report II, and unchanged here: mesa drags **libxml2, ICU, LLVM,
libelf, libedit, ncurses** into the process. Those are ordinary libraries an
application might also bundle. Combined with §4.1 the rule is simple and
mechanical, and it is why the contract file lists them individually instead of
lumping them under "driver stuff".

## 5. Target configurations

| Name | Profile | Target level | What it demonstrates | Status |
|---|---|---|---|---|
| `gt-probe` | H | 1 | The dependency graph loads, and what it loads | **works, passes `--strict`** |
| `gnome-terminal-static` | H | 1 | The headline: a GNOME application as one file | plan only |
| `gnome-terminal-portal` | H | 2 | Appearance and file chooser through portals, no host `.so` | not started |

## 6. `tools/build-gnome-terminal.sh` — required interface

Renders the full plan with `--print-plan` and refuses to execute it, following
the precedent of `tools/build-far2l.sh`. The plan is the specification: build
order, the Meson options that matter and why, the schema-embedding decision,
and the two link-level rules from §4.1 and §4.2. Read it with
`./tools/build-gnome-terminal.sh --print-plan`.

## 7. Provenance

Everything in §2 comes from `dpkg -s`, `readelf -d` and `pkg-config` on Ubuntu
24.04. Everything in §3 and §4 comes from running `gt-probe`, whose report the
CI workflow uploads as an artifact on every run, passing or failing, together
with an `environment.txt` recording the toolkit and mesa versions the
measurement was taken against. A contract file without the machine that
produced it is not evidence.
