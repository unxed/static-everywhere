#!/usr/bin/env bash
# No diagnostics collector may copy a build tree wholesale.
#
# Why this exists
# ---------------
# Twice now an artifact has grown past the point of being downloadable,
# each time for the same reason and each time in a different workflow.
# gnome-terminal reached 178 MB by copying every non-binary file under
# its output directory -- which meant the full source checkouts of glib,
# gtk, cairo, pango and the rest. konsole reached 429 MB by copying every
# text file under kde-build: translation catalogues, DocBook, generated
# sources, ninja dependency files.
#
# Both filters looked reasonable. "Not a binary, under 2 MB, newer than
# the job start" sounds selective until you notice the job creates
# everything it touches, so the age test excludes nothing and the size
# test only excludes the largest single files, never the total.
#
# The rule that holds in both cases: name the files you want. A collector
# that subtracts from everything will keep finding new things to include
# by accident; one that adds from nothing cannot.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
workflows = sorted((root / '.github/workflows').glob('*.yml'))
if not workflows:
    sys.exit('no workflows found; has the directory moved?')

# A find that only builds a listing is harmless -- it costs one text file.
# What has twice made an artifact undownloadable is a find whose results
# get copied. So look only at those.
FIND = re.compile(r'^[ \t]*find[ \t](?:[^\n]*\\\n)*[^\n]*', re.M)

problems, unbounded = [], []
for workflow in workflows:
    text = workflow.read_text()
    copies_anything = False
    for match in FIND.finditer(text):
        block = match.group(0)
        if 'job-start-marker' not in block:
            continue
        # "Feeds a copy" must mean this find's own output, not merely a
        # cp somewhere below it: far2l builds a listing here and copies
        # CMake logs a few lines later from a different search entirely.
        feeds_a_copy = '-exec cp' in block
        if not feeds_a_copy:
            # The redirect target may or may not be quoted, and a control
            # showed the quoted-only form silently matched nothing for
            # konsole -- so the whole workflow escaped both checks.
            redirect = re.search(r'>\s*"?([^"\s]+)"?\s*$', block.strip())
            if redirect:
                target = redirect.group(1)
                feeds_a_copy = (f'done < "{target}"' in text
                                or f'done < {target}' in text)
        if not feeds_a_copy:
            continue
        copies_anything = True
        # An allowlist names what it wants: -name terms that are not
        # spelled as exclusions.
        names = re.findall(r"-name\s+'([^']+)'", block)
        # '*' and '*.*' are not selections; they are the exclusion
        # rule wearing an allowlist's clothes.
        positives = [n for n in names if f"! -name '{n}'" not in block]
        # A universal pattern voids the list rather than joining it: with
        # -name '*' among them the other entries select nothing extra,
        # and the collector is back to copying everything.
        if any(n in ('*', '*.*', '?*') for n in positives):
            positives = []
        if not positives:
            problems.append((workflow.name, block.split('\n')[0].strip()))
    # Look for the arithmetic that enforces the ceiling, not for the
    # message that announces it: the message can be reworded, and a
    # control proved the check passed once it was.
    if copies_anything and '-gt 32768' not in text:
        unbounded.append(workflow.name)

if problems:
    print('a diagnostics collector copies files selected by exclusion only:')
    for name, first_line in problems:
        print(f'  {name}: {first_line}')
    print()
    print('Subtracting from "everything under the build tree" produced a')
    print('178 MB artifact once and a 429 MB one after that. Name the files')
    print('that answer a question instead.')
    sys.exit(1)

if unbounded:
    print('a copying collector has no size ceiling:', ', '.join(unbounded))
    print('The allowlist is a judgement and can be wrong again; arithmetic')
    print('cannot. Stop at a fixed size and say so in the artifact.')
    sys.exit(1)
PY

printf 'diagnostics collectors: allowlisted and bounded\n'
