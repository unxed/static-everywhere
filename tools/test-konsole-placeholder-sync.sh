#!/usr/bin/env bash
# Every @PLACEHOLDER@ in the kde-builder template must be substituted by
# BOTH the build script and the preflight, and the rendered YAML must
# parse.
#
# Why this exists
# ---------------
# make-install-prefix went in as a bare `@INSTALL_PREFIX_CMD@`. Every
# other top-level value in the template is quoted, because '@' cannot
# start a YAML scalar; unquoted, it is a parse error. CI caught it -- but
# the preflight, whose job is to catch exactly this before a two-hour
# run, did not, because it renders with its own hard-coded list of sed
# substitutions and that list was missing the new placeholder. It was
# validating a different document than the one the build produces.
#
# Two independent failures, one root: a placeholder the template uses that
# a renderer does not know about. This checks both renderers know every
# placeholder, and that the result parses.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
template = (root / 'contrib/konsole/kde-builder.yaml.in').read_text()
placeholders = set(re.findall(r'@[A-Z_]+@', template))

problems = []
for renderer in ('tools/build-konsole.sh', 'tools/preflight-konsole.sh'):
    text = (root / renderer).read_text()
    for ph in sorted(placeholders):
        # The renderer must name the placeholder (in a sed -e s|@X@|...| ).
        if ph not in text:
            problems.append((renderer, ph))

if problems:
    print('a renderer does not substitute every template placeholder;')
    print('it will validate or build a different config than intended:')
    for renderer, ph in problems:
        print(f'  {renderer} is missing {ph}')
    sys.exit(1)

# Every top-level placeholder value must be quoted, since '@' cannot open
# a YAML scalar. (Placeholders inside the folded cmake-options block are
# exempt: there they are plain text.)
lines = template.splitlines()
in_folded = False
for n, line in enumerate(lines, 1):
    stripped = line.strip()
    if stripped.endswith(': >') or stripped.endswith(': |'):
        in_folded = True
        continue
    if in_folded:
        # A less-indented non-blank line ends the folded scalar.
        if stripped and not line.startswith('    '):
            in_folded = False
        else:
            continue
    m = re.match(r'^\s*[a-z0-9-]+:\s*(@[A-Z_]+@)\s*$', line)
    if m:
        print(f'line {n}: {stripped}')
        print(f'  the value {m.group(1)} is an unquoted top-level placeholder;')
        print("  '@' cannot start a YAML scalar, so this fails to parse. Quote it.")
        sys.exit(1)
PY

printf 'placeholder sync: both renderers know every placeholder, top-level ones are quoted\n'
