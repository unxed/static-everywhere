#!/usr/bin/env bash
# Regression test for contrib/f4-qt/f4-diag.sh.
#
# The wrapper exists so a failed graphical launch explains itself. That
# only works if the wrapper itself is sound, and the first real run
# proved it was not: a section header written as
#
#     printf '----- host -----\n'
#
# is a format string starting with '-', so bash's printf parsed it as
# options, errored, and the run lost the "f4 output" section entirely --
# the diagnostic tool silently dropped the diagnosis.
#
# So this checks the two properties that matter:
#   1. no printf (or other) errors anywhere in the produced log;
#   2. the log actually contains the child's stdout+stderr, the exit
#      code, and the environment sections.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
DIAG="${REPO_ROOT}/contrib/f4-qt/f4-diag.sh"

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

# A stand-in f4 that writes to both streams and exits non-zero, since a
# failing launch is the case the wrapper is for.
cat >"$PROBE/f4" <<'EOF'
#!/usr/bin/env bash
printf 'STDOUT-MARKER\n'
printf 'STDERR-MARKER\n' >&2
exit 3
EOF
chmod +x "$PROBE/f4"
cp "$DIAG" "$PROBE/f4-diag"
chmod +x "$PROBE/f4-diag"

( cd "$PROBE" && ./f4-diag >/dev/null 2>&1 ) || true

# shellcheck disable=SC2012  # our own timestamped names, no odd chars
LOG=$(ls -t "$PROBE"/f4-diag-*.log 2>/dev/null | head -1)
[ -n "$LOG" ] || { printf 'f4-diag produced no log at all\n' >&2; exit 1; }

# 1. The wrapper must not have errored on its own output. A format string
# beginning with '-' is the specific bug that shipped; catch the class.
if grep -qiE 'printf: |invalid option|недопустимый параметр|usage: printf' "$LOG"; then
    printf 'f4-diag emitted printf errors into its own log:\n' >&2
    grep -iE 'printf: |invalid option|недопустимый параметр|usage: printf' "$LOG" \
        | sed 's/^/  /' >&2
    exit 1
fi

# 2. The child's output must be captured -- both streams. This is the
# whole point; the shipped version lost it.
grep -q 'STDOUT-MARKER' "$LOG" \
    || { printf 'the log does not contain the child stdout\n' >&2; exit 1; }
grep -q 'STDERR-MARKER' "$LOG" \
    || { printf 'the log does not contain the child stderr\n' >&2; exit 1; }

# 3. The exit code must be recorded, since "it did nothing" and "it exited
# 3" are different bug reports.
grep -q 'exited with code 3' "$LOG" \
    || { printf 'the log does not record the exit code\n' >&2; exit 1; }

# 4. The environment sections that shape a graphical failure must be
# present and non-empty.
for section in 'host' 'libGL' 'fonts' 'launch configuration' 'f4 output'; do
    grep -qi -- "$section" "$LOG" \
        || { printf 'the log is missing the %s section\n' "$section" >&2; exit 1; }
done

# 5. The child must get a real terminal. Capturing output by redirecting
# both streams into a file leaves it with no tty, and a terminal UI
# started that way exits immediately and silently -- which is exactly what
# the first desktop run produced: an empty section and exit 0. The
# capture must not change what it captures.
cat >"$PROBE/f4" <<'EOF'
#!/usr/bin/env bash
if [ -t 1 ]; then printf 'TTY-PRESENT\n'; else printf 'NO-TTY\n'; fi
EOF
chmod +x "$PROBE/f4"
rm -f "$PROBE"/f4-diag-*.log
( cd "$PROBE" && ./f4-diag >/dev/null 2>&1 ) || true
# shellcheck disable=SC2012
TTYLOG=$(ls -t "$PROBE"/f4-diag-*.log 2>/dev/null | head -1)
if command -v script >/dev/null 2>&1; then
    grep -q 'TTY-PRESENT' "$TTYLOG" \
        || { printf 'the child was run without a tty; a terminal UI would exit silently\n' >&2
             exit 1; }
fi

# 6. An empty capture must be called out, since a blank section plus exit
# 0 is otherwise indistinguishable from a broken wrapper.
cat >"$PROBE/f4" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PROBE/f4"
rm -f "$PROBE"/f4-diag-*.log
( cd "$PROBE" && ./f4-diag >/dev/null 2>&1 ) || true
# shellcheck disable=SC2012
EMPTYLOG=$(ls -t "$PROBE"/f4-diag-*.log 2>/dev/null | head -1)
grep -q 'produced no output' "$EMPTYLOG" \
    || { printf 'an empty run was not called out in the log\n' >&2; exit 1; }

# 7. f4 detaches on a desktop: it re-execs itself with Setsid, points the
# child's stdio at /dev/null and exits 0 in the parent. Run plainly, the
# wrapper captured an empty section and exit 0 -- a correct launch that
# looked like a silent failure. The wrapper must set F4_DETACHED=1 so the
# real work stays in our process and its output reaches the log.
cat >"$PROBE/f4" <<'EOF'
#!/usr/bin/env bash
if [ "${F4_DETACHED:-}" != "1" ]; then
    F4_DETACHED=1 setsid "$0" "$@" >/dev/null 2>&1 &
    exit 0
fi
printf 'POST-DETACH-OUTPUT\n'
EOF
chmod +x "$PROBE/f4"
rm -f "$PROBE"/f4-diag-*.log
( cd "$PROBE" && ./f4-diag >/dev/null 2>&1 ) || true
# shellcheck disable=SC2012
DETACHLOG=$(ls -t "$PROBE"/f4-diag-*.log 2>/dev/null | head -1)
grep -q 'POST-DETACH-OUTPUT' "$DETACHLOG" \
    || { printf 'f4 detached and its output was lost; F4_DETACHED not honoured\n' >&2
         exit 1; }

printf 'f4-diag: no printf errors, child output and exit code captured\n'
