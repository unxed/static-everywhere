#!/usr/bin/env bash
# A large producer piped into `grep -q` under `set -o pipefail` must be
# grouped, or a MATCH is reported as a failure.
#
# Why this exists
# ---------------
# test-optional-gl-cxx-only.sh ran
#   nm -D --defined-only "$loadable" | grep -Eq '...glColor4f$'
# grep -q exits at the first match and closes the pipe; nm dies of SIGPIPE
# with 141; pipefail makes the pipeline fail; the test reported "lacks the
# generated forwarder" for a module that defines it. Measured: the symbol
# is present (count 1) and the pipeline status is 141.
#
# It is timing-dependent -- it bites when the producer is still writing,
# which is exactly the big ones (nm, readelf, strings, objdump, find) --
# so it fails intermittently and reads like a real defect. Grouping the
# producer as `{ producer || true; }` makes that element's status 0 and
# leaves grep's verdict untouched.
set -euo pipefail
# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

bad=$(python3 - "$SCRIPT_DIR" <<'PY'
import pathlib, re, sys
d = pathlib.Path(sys.argv[1])
BIG = r'(?:nm|readelf|strings|objdump|find|runpath_of)\b'
out = []
for p in sorted(d.glob('*.sh')):
    if not p.is_file():
        continue
    t = p.read_text(errors='replace')
    if 'pipefail' not in t:
        continue
    for n, line in enumerate(t.split('\n'), 1):
        if line.lstrip().startswith("#"):
            continue
        if re.search(r'\|\s*grep\s+-[A-Za-z]*q', line) and re.search(BIG, line):
            if not re.search(r'\|\|\s*true;\s*\}', line):
                out.append(f"{p.name}:{n}: {line.strip()[:70]}")
print('\n'.join(out))
PY
)
if [ -n "$bad" ]; then
    printf 'a large producer feeds grep -q under pipefail without grouping;\n' >&2
    printf 'a match will be reported as a failure when the producer is still writing:\n' >&2
    printf '%s\n' "$bad" | sed 's/^/  /' >&2
    printf 'wrap the producer: { producer || true; } | grep -q ...\n' >&2
    exit 1
fi
printf 'sigpipe/grep -q: every large producer feeding grep -q is grouped\n'
