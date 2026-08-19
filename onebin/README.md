# onebin

A conformance linter for the [Static Everywhere](../STATIC-EVERYWHERE.md)
doctrine. Point it at an ELF executable or shared object; it tells you
whether the binary is genuinely self-contained the way the manifesto
describes, and exactly what's wrong if it isn't.

No `elf.h`, no `libelf`, no `mmap`. It reads the file into memory once and
parses it by hand, bounds-checked at every step — see
[`../02-REFERENCE-elf.md`](../02-REFERENCE-elf.md) for why, and
[`../01-SPEC-audit.md`](../01-SPEC-audit.md) for the full specification
this implements.

## Prerequisites (Ubuntu / Debian)

```sh
# Basic toolchain and test suite requirements:
sudo apt update && sudo apt install -y \
    build-essential shellcheck musl-tools cmake ninja-build git pkg-config m4 gawk

# Required for far2l X11 broker (far2l_ttyx.broker):
sudo apt install -y libx11-dev libxi-dev libxext-dev libice-dev libsm-dev

# Optional host dev packages for testing Profile H builds dynamically:
sudo apt install -y libsdl2-dev libfreetype-dev libharfbuzz-dev libfontconfig1-dev \
                    libuchardet-dev libssl-dev libexpat1-dev zlib1g-dev
## Prerequisites (Ubuntu / Debian)

```sh
# Basic toolchain and test suite requirements:
sudo apt update && sudo apt install -y \
    build-essential shellcheck musl-tools cmake ninja-build git pkg-config m4 gawk

# Required for far2l X11 broker (far2l_ttyx.broker):
sudo apt install -y libx11-dev libxi-dev libxext-dev libice-dev libsm-dev

# Optional host dev packages for testing Profile H builds dynamically:
sudo apt install -y libsdl2-dev libfreetype-dev libharfbuzz-dev libfontconfig1-dev \
                    libuchardet-dev libssl-dev libexpat1-dev zlib1g-dev

# Required for f4-qt build (Go and isolated Conan via pipx):
sudo apt install -y pipx golang-go
pipx install conan
## Prerequisites (Ubuntu / Debian)

```sh
# Basic toolchain and test suite requirements:
sudo apt update && sudo apt install -y \
    build-essential shellcheck musl-tools cmake ninja-build git pkg-config m4 gawk

# Required for far2l X11 broker (far2l_ttyx.broker):
sudo apt install -y libx11-dev libxi-dev libxext-dev libice-dev libsm-dev

# Optional host dev packages for testing Profile H builds dynamically:
sudo apt install -y libsdl2-dev libfreetype-dev libharfbuzz-dev libfontconfig1-dev \
                    libuchardet-dev libssl-dev libexpat1-dev zlib1g-dev

# Required for f4-qt build (Go and isolated Conan via pipx):
sudo apt install -y pipx golang-go
pipx install conan
```

## Building Reference Applications

```sh
# 1. Build far2l-sdl (Terminal + SDL GUI)
./tools/build-far2l.sh --config sdl --fetch --src /tmp/far2l-src --out /tmp/out-far2l-sdl

# 2. Build f4-qt (Go core + static embedded Qt Quick host)
./tools/build-f4-qt.sh --config linux --gallery off --fetch --src /tmp/f4-src --out /tmp/out-f4-qt
```
## Build

```sh
make            # build/onebin
make test       # the test suite (259 tests as of this writing)
make test-asan  # the same, under ASan+UBSan
make coverage   # line/branch coverage gate (>=90%/85%, 100% on buf.c/ver.c)
make fuzz       # in-process mutation fuzzer, FUZZ_ITERS=N (default 20000)
make selftest   # builds onebin statically and audits itself — see below
```

Requires a C11 compiler and nothing else. No dependencies, no vendored
libraries, no build-system generator — one `Makefile`.

## Use

```sh
onebin audit /usr/bin/ls
onebin audit --format json --level 2 ./mybinary
onebin audit --profile static --glibc-max 2.17 ./mybinary
onebin audit --write-baseline known-issues.txt ./mybinary
onebin audit --baseline known-issues.txt ./mybinary   # suppresses those findings next time
```

Exit codes: `0` clean (warnings/infos allowed), `1` at least one error (or
a warning under `--strict`), `2` usage error or a file that couldn't be
read or identified as ELF. Full grammar in
[`../01-SPEC-audit.md §5`](../01-SPEC-audit.md).

`onebin audit --help` prints every flag.

## What it checks

Seven check families, matching
[`../01-SPEC-audit.md §7`](../01-SPEC-audit.md):

| Family | What |
|---|---|
| `needed` | `DT_NEEDED` against the host-contract allowlist |
| `glibc` | highest required `GLIBC_x.y` against `--glibc-max` |
| `profile` | Static / Hybrid / Module classification and profile-specific checks |
| `rpath` | `DT_RPATH`/`DT_RUNPATH`, `$ORIGIN`-relativity |
| `harden` | RELRO, `BIND_NOW`, exec-stack, `TEXTREL`, PIE |
| `hygiene` | embedded build paths, host-toolchain paths, leftover debug info |
| `host` | dlopen'd libraries against the host contract |

Every finding has a stable ID (`OB00NN`), a severity, and a one-line
message. `--format json` gives you the same data machine-readably —
schema in [`../01-SPEC-audit.md §9.2`](../01-SPEC-audit.md).

## Self-audit, and the one finding it can never clear

`make selftest` builds `onebin` itself with Profile S flags (`musl-gcc
-static-pie` if `musl-tools` is installed, `cc -static-pie` against glibc
otherwise, or a clearly-worded `SKIP` if neither link succeeds — never a
silent pass) and runs `onebin audit` against the result.

The report is **not** a clean PASS, on purpose and unavoidably: `onebin`'s
own source code contains, as literal detection strings, several of the
exact substrings its own checks look for — `"dlopen"`, `"/etc/nsswitch.conf"`,
`"libnss_"`, `"libgcc_s.so.1"`, `"libstdc++.so.6"`. Compiled into its own
`.rodata`, these are indistinguishable from genuine evidence of the things
they detect, because the audited binary *is* the tool that contains them.
This is a structural property of any string-matching self-scanner, not a
static-linking defect — `tools/selftest.sh` prints the full explanation
inline rather than hiding it or special-casing its own build. See
`NOTES.md` for the longer version.

## Layout

```
src/
├── main.c                 argv parsing, subcommand dispatch, exit codes
├── util/                  buf (bounds-checked reads), ver, str, json, vec
├── elf/                   image, dynamic, verneed, symbols, strings — the parser
└── audit/
    ├── audit.c            orchestration: the only layer that touches disk
    ├── finding.c, baseline.c, report*.c
    ├── checks.h            shared context for every check family
    └── checks/             one file per family, c_needed.c .. c_meta.c
tests/
├── mkelf.c/.h              hand-rolled ELF fixture generator (no host compiler)
├── t_*.c                   one file per module/check family
├── t_lint.c                architecture rules enforced as tests
├── t_cli.c                 spawns the built binary, checks exit codes
├── fuzz.c                  in-process deterministic mutation fuzzer
└── golden/                 byte-exact JSON/text report fixtures
tools/
├── coverage-gate.sh
└── selftest.sh
```

`NOTES.md` is the running log of ambiguity resolutions and decisions this
implementation made where the spec left something open — read it before
assuming a behaviour is unspecified; it's probably already been decided
and written down.

## Status

Everything above is implemented and tested. See
[`../STATUS.md`](../STATUS.md) for exactly which
[`00-AGENT-TASK.md`](../00-AGENT-TASK.md) tasks are done and what's left —
building the reference applications (far2l, f4-qt) against this tool is
the next major milestone, not yet started.
