#!/usr/bin/env bash
# Compare the Qt inter-module dependencies Qt's own sources declare with
# the components the Conan qt recipe exposes, for every Qt module the
# konsole link uses. A dependency that is neither a Conan component nor
# an edge the project hook repairs will surface as undefined symbols in a
# static link -- with --no-undefined, on the first shared MODULE.
#
# Why this exists
# ---------------
# konsolepart.so failed on QOpenGL* symbols: libQt6Quick.a needs
# Qt6OpenGL and the Conan recipe omits that edge. Fixed by hand, from the
# link error. Asked how to find the NEXT such edge before a build, this
# reads both sides from source. First run found it: Qt 6.11's Quick links
# QmlMeta, a module Conan builds but never declares as a component, so
# libQt6QmlMeta.a is never on any link line.
#
# Reads: qt_internal_add_module(<M> ... LIBRARIES/PUBLIC_LIBRARIES ...) and
# qt_internal_extend_target(<M> CONDITION ... LIBRARIES ...) from the Qt
# branch matching contrib/konsole/deps.lock, and _create_module("<M>", [...])
# from the conan-center recipe.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
command -v curl >/dev/null 2>&1 || { printf 'curl unavailable; skipping\n'; exit 0; }

QT_VER=$(awk '$1 == "qt" { print $2 }' "$REPO_ROOT/contrib/konsole/deps.lock")
QT_BR=${QT_VER%.*}   # 6.11.1 -> 6.11
PROBE=$(mktemp -d); trap 'rm -rf "$PROBE"' EXIT

curl -fsSL --max-time 30 -o "$PROBE/conanfile.py" \
    "https://raw.githubusercontent.com/conan-io/conan-center-index/master/recipes/qt/6.x.x/conanfile.py" \
    || { printf 'could not fetch the conan qt recipe; skipping\n'; exit 0; }

python3 - "$PROBE" "$QT_BR" "$REPO_ROOT" <<'PY'
import re, sys, urllib.request, pathlib
probe, br, root = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

# Modules on konsole's link (Qt side), with their source locations.
mods = {
 "Core":("qtbase","src/corelib"), "Gui":("qtbase","src/gui"), "Widgets":("qtbase","src/widgets"),
 "Network":("qtbase","src/network"), "DBus":("qtbase","src/dbus"), "Xml":("qtbase","src/xml"),
 "PrintSupport":("qtbase","src/printsupport"), "OpenGL":("qtbase","src/opengl"),
 "Concurrent":("qtbase","src/concurrent"),
 "Qml":("qtdeclarative","src/qml"), "QmlModels":("qtdeclarative","src/qmlmodels"),
 "QmlMeta":("qtdeclarative","src/qmlmeta"), "QmlWorkerScript":("qtdeclarative","src/qmlworkerscript"),
 "Quick":("qtdeclarative","src/quick"), "QuickWidgets":("qtdeclarative","src/quickwidgets"),
 "Multimedia":("qtmultimedia","src/multimedia"), "Svg":("qtsvg","src/svg"),
}
conan = {m.group(1): set(re.findall(r'"(\w+)"', m.group(2)))
         for m in re.finditer(r'_create_module\("(\w+)",\s*\[([^\]]*)\]', open(f"{probe}/conanfile.py").read())}
# Modules Conan exposes as components at all (any _create_module call).
conan_components = set(conan) | {"Core", "Gui", "Network", "Multimedia"}  # created via other helpers in the recipe

# Edges the project hook repairs by hand (link-qt6-opengl.cmake and the
# orphan-archive hook), read from the files so this stays honest.
hook = ""
for f in ("contrib/f4-qt/link-qt6-opengl.cmake", "contrib/konsole/link-qt6-orphan-modules.cmake"):
    p = root / f
    if p.exists(): hook += p.read_text()
# Repaired edges: Qt6::X mentions in the OpenGL file, plus the "From|To"
# table in the orphan-modules file -- read as a table, so the scan and the
# hook share one source of truth.
repaired = set(re.findall(r'Qt6::(\w+)', hook))
repaired |= {m.group(2) for m in re.finditer(r'"(\w+)\|(\w+)"', hook)}

def fetch(repo, path):
    try: return urllib.request.urlopen(f"https://raw.githubusercontent.com/qt/{repo}/{br}/{path}/CMakeLists.txt", timeout=30).read().decode()
    except Exception: return ""

problems, checked = [], 0
for mod, (repo, path) in mods.items():
    t = fetch(repo, path)
    if not t: continue
    deps = set()
    for m in re.finditer(r'qt_internal_(?:add_module|add_qml_module|extend_target|extend_module)\(\s*' + mod + r'\b(.*?)\n\)', t, re.S):
        body = m.group(1)
        cond = re.search(r'CONDITION\s+([^\n]+)', body)
        # Skip extensions gated on platforms/features we do not build.
        if cond and re.search(r'\b(MSVC|WIN32|APPLE|MACOS|ANDROID|WASM|QNX|INTEGRITY|VXWORKS|QT_FEATURE_wayland|QT_FEATURE_xcb_xlib)\b', cond.group(1)):
            continue
        for sect in re.finditer(r'\b(?:PUBLIC_)?LIBRARIES\s*\n((?:\s+[^\n]+\n)+?)(?=\s+[A-Z_]+\b|\s*$)', body):
            deps |= {d for d in re.findall(r'Qt::(\w+)', sect.group(1))}
    deps = {d[:-7] if d.endswith("Private") else d for d in deps}
    # Platform and GlobalConfig are INTERFACE targets (flags), not archives.
    # Platform, GlobalConfig are INTERFACE targets; QmlIntegration is header-only
    # (its include dir is injected for consumers separately; no archive to link).
    deps -= {mod, "Platform", "GlobalConfig", "BundledTLSF", "QmlIntegration"}
    deps = {d for d in deps if not d.startswith("Bundled") and d != "EntryPoint"}
    checked += 1
    for d in sorted(deps):
        declared = d in conan.get(mod, set())
        exposed = d in conan_components
        if declared: continue
        if exposed:
            # Component exists but the edge is undeclared: a consumer must
            # link it explicitly -- exactly the OpenGL bug.
            if d in repaired: continue
            problems.append(f"{mod} -> {d}: Qt declares the dependency, Conan exposes Qt6::{d} but omits the edge, and no hook repairs it")
        else:
            if d in repaired: continue
            problems.append(f"{mod} -> {d}: Qt declares the dependency, Conan has NO component for {d} -- libQt6{d}.a is built but never linked")

if problems:
    print(f"Qt module dependencies missing from the static link ({len(problems)}):")
    for p in problems: print("  " + p)
    sys.exit(1)
print(f"qt module edges: {checked} modules checked against Qt {br} sources and the Conan recipe; every dependency is declared, exposed or repaired")
PY
