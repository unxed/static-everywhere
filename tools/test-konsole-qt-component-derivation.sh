#!/usr/bin/env bash
# Every Qt6 component adapter must be derived from the package, not
# listed by hand.
#
# Why this exists
# ---------------
# The private family used to be a hand written set of twenty names,
# grown one CI round at a time: a KDE framework asked for Qt6GuiPrivate,
# the build failed two hours in, the name was appended, and the next
# framework asked for the next one. Reading the commit history, that
# pattern accounts for several separate two-hour rounds -- each fixing a
# real bug, none of them fixing the shape that produced it.
#
# A list maintained that way is only ever correct about the past. The
# derivation is correct about the package: every public component gets a
# private counterpart, and `component_config` emits
# `if(TARGET Qt6::X) FOUND TRUE else FALSE`, so an adapter for something
# this Qt does not have reports NOT FOUND -- which is what a real Qt
# installation reports. Generating the whole family costs nothing and
# cannot be incomplete.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

python3 - "$REPO_ROOT" <<'PY'
import ast, pathlib, sys

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'contrib/konsole/qt-host'))
from qt_cmake_components import component_shim_names, component_config

# 1. Every public component gets a private counterpart -- including one
#    invented here, which stands for the component Qt adds next year.
public = ['Core', 'Gui', 'Widgets', 'SomethingNobodyHasNeededYet']
names = component_shim_names(public)
for component in public:
    if component not in names:
        sys.exit(f'{component} lost its adapter')
    if f'{component}Private' not in names:
        sys.exit(f'{component} has no private counterpart; a framework asking '
                 f'for Qt6{component}Private would fail the build instead')

# 2. The twenty names the old hand written list carried must all still be
#    produced, or this "generalisation" quietly dropped coverage.
was_listed = {
    'ConcurrentPrivate', 'CorePrivate', 'DBusPrivate', 'GuiPrivate',
    'MultimediaPrivate', 'MultimediaWidgetsPrivate', 'NetworkPrivate',
    'OpenGLPrivate', 'OpenGLWidgetsPrivate', 'PrintSupportPrivate',
    'QmlPrivate', 'QuickPrivate', 'ShaderToolsPrivate', 'SqlPrivate',
    'SvgPrivate', 'SvgWidgetsPrivate', 'TestPrivate', 'WidgetsPrivate',
    'XmlPrivate',
}
implied_public = sorted({n[: -len('Private')] for n in was_listed})
derived = set(component_shim_names(implied_public))
lost = was_listed - derived
if lost:
    sys.exit(f'the derivation drops names the old list carried: {sorted(lost)}')

# 3. Feeding a private name back in must not produce XPrivatePrivate.
if any(n.endswith('PrivatePrivate') for n in component_shim_names(['GuiPrivate'])):
    sys.exit('the derivation doubles the Private suffix')

# 4. And the adapter must stay conditional, since that is what makes
#    generating the whole family safe. If it ever reports FOUND
#    unconditionally, an adapter for an absent component becomes a lie.
generated = component_config('SomethingNobodyHasNeededYet')
if 'if(TARGET Qt6::SomethingNobodyHasNeededYet)' not in generated:
    sys.exit('component_config no longer checks whether the target exists; '
             'generating adapters for the whole family is only safe because '
             'an absent component reports NOT FOUND')

# 5. No hand written private list may come back.
recipe = (root / 'contrib/konsole/qt-host/conanfile.py').read_text()
literals = [
    node.value
    for node in ast.walk(ast.parse(recipe))
    if isinstance(node, ast.Constant) and isinstance(node.value, str)
    and node.value.endswith('Private') and node.value != 'Private'
]
if len(literals) > 2:
    sys.exit('conanfile.py names private Qt components literally again '
             f'({literals[:4]}...); derive them instead')
PY

# 6. No other check may demand the literal list back.
#
# The preflight used to require the string "GuiPrivate" in the recipe --
# pinning in place the very habit this derivation removed. Two guards
# then disagreed, and CI failed on the contradiction rather than on any
# real defect. A guard that asserts the old shape is as much a
# regression as code that reintroduces it.
python3 - "$REPO_ROOT" <<'CONTRADICTION'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
lines = (root / 'tools/preflight-konsole.sh').read_text().splitlines()

# Only the needles applied to the recipe matter. A private component
# named elsewhere is usually legitimate -- the shim test calls
# find_package(Qt6GuiPrivate) to prove a private adapter works, which is
# behaviour, not a list.
offenders, in_needles = [], False
for line in lines:
    stripped = line.strip()
    if stripped.startswith('for needle in'):
        in_needles = True
        continue
    if in_needles:
        if stripped.startswith('done') or 'grep -Fq "$needle"' in stripped:
            in_needles = False
            continue
        if stripped.startswith('#'):
            continue
        if re.search(r'\w+Private', stripped):
            offenders.append(stripped)

if offenders:
    print('the konsole preflight requires the recipe to name private Qt')
    print('components literally, which is the habit the derivation removed:')
    for line in offenders[:3]:
        print('  ' + line)
    sys.exit(1)
CONTRADICTION

printf 'qt component shims: derived from the package, private family complete\n'
