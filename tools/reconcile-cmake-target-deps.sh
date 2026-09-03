#!/usr/bin/env bash
# Make every installed *Config.cmake declare the packages its own
# *Targets.cmake references.
#
# Why this exists
# ---------------
# konsole's KF6 build reached kio and stopped:
#
#   CMake Error at .../KF6JobWidgets/KF6JobWidgetsTargets.cmake:62
#     The link interface of target "KF6::JobWidgets" contains:
#       KF6::Notifications
#     but the target was not found.
#
# Both modules built fine, in the right order. The inconsistency is in
# what kjobwidgets installed: its Targets file records a link interface on
# KF6::Notifications, while its Config file declares only Qt6Widgets and
# KF6CoreAddons. A consumer that calls find_package(KF6JobWidgets) gets
# the targets file, which names a target nobody has defined.
#
# That is an upstream packaging inconsistency -- an optional dependency
# found at build time and recorded in the export, without the matching
# find_dependency in the config template. It is filed in
# contrib/konsole/UPSTREAM.md. Here it is repaired mechanically, because
# the alternative is discovering it one consumer at a time, each two
# hours apart.
#
# The repair is conservative: a find_dependency is added only when the
# referenced package has a config of its own in the same prefix. If it is
# genuinely absent, appending the call would turn a confusing error into
# a different confusing error, so the script reports and fails instead.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'usage: %s <install-prefix>\n' "$0" >&2
    exit 2
fi
PREFIX="$1"

if [ ! -d "$PREFIX" ]; then
    printf 'reconcile-cmake-target-deps: %s does not exist\n' "$PREFIX" >&2
    exit 1
fi

python3 - "$PREFIX" <<'PY'
import pathlib, re, sys

prefix = pathlib.Path(sys.argv[1])
targets_files = sorted(prefix.rglob('*Targets.cmake'))
if not targets_files:
    print(f'no *Targets.cmake under {prefix}; nothing to reconcile')
    raise SystemExit(0)

# Every package that has a config somewhere in this prefix, by the name a
# find_dependency call would use.
available = {}
for config in prefix.rglob('*Config.cmake'):
    name = config.name[: -len('Config.cmake')]
    available.setdefault(name, config)

repaired, unresolved = [], []

for targets in targets_files:
    package = targets.name[: -len('Targets.cmake')]
    config = targets.with_name(f'{package}Config.cmake')
    if not config.exists():
        continue

    text = targets.read_text(errors='replace')
    declared = config.read_text(errors='replace')

    # Namespaced targets the export refers to, minus the ones this very
    # package defines.
    referenced = set(re.findall(r'\b((?:KF6|Qt6)::[A-Za-z0-9_]+)', text))
    own = set(re.findall(r'add_library\((\S+)\s', text))
    referenced -= own

    for target in sorted(referenced):
        namespace, _, component = target.partition('::')
        candidate = f'{namespace}{component}'
        if candidate == package:
            continue
        if re.search(rf'find_dependency\(\s*{re.escape(candidate)}\b', declared):
            continue
        if re.search(rf'find_package\(\s*{re.escape(candidate)}\b', declared):
            continue
        if candidate not in available:
            unresolved.append((package, target, candidate))
            continue

        # Insert after the last existing find_dependency so the call order
        # stays sane, or after the include of CMakeFindDependencyMacro.
        lines = declared.splitlines()
        insert_at = None
        for index, line in enumerate(lines):
            if 'find_dependency(' in line or 'CMakeFindDependencyMacro' in line:
                insert_at = index + 1
        if insert_at is None:
            unresolved.append((package, target, candidate))
            continue
        lines.insert(insert_at, f'find_dependency({candidate})')
        declared = '\n'.join(lines) + '\n'
        config.write_text(declared)
        repaired.append((package, target, candidate))

for package, target, candidate in repaired:
    print(f'{package}: exported {target} without declaring it; '
          f'added find_dependency({candidate})')

if unresolved:
    print()
    print('exported targets referencing packages that are not installed here:')
    for package, target, candidate in unresolved:
        print(f'  {package} references {target}, and no {candidate}Config.cmake '
              'exists in this prefix')
    print()
    print('Adding a find_dependency for a package that is absent would only')
    print('move the error, so this is reported rather than patched. Either the')
    print('module list is missing something or the export is wrong.')
    raise SystemExit(1)

if not repaired:
    print('exported targets and declared dependencies already agree')
PY
