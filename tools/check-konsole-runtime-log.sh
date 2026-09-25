#!/usr/bin/env bash
# Fail a Konsole smoke run whose window appeared but whose runtime is hollow.
#
# A static Qt/KF6 Konsole can draw a terminal while missing everything it
# looks up at runtime: its window-system backend (a MODULE static Qt cannot
# load), and the :/ resources a STATIC library dropped at link time (XMLGUI
# menus, the default keyboard translator, colour schemes). The pixel check in
# run-konsole-smoke.sh passes for all of them, so the log is the contract.
# The smoke harness enables the kf.* and qt.core.plugin* categories that
# carry these messages.
set -euo pipefail

if [[ $# -ne 1 || ! -f $1 ]]; then
    printf 'usage: %s KONSOLE_LOG\n' "$0" >&2
    exit 2
fi
log=$1
status=0

forbidden=(
    'Could not find any platform plugin'
    'into a statically linked Qt library'
    'cannot find .rc file'
    'Unable to load translator'
    'Icon theme "breeze" not found'
    'KIconTheme created with empty theme name'
)
for message in "${forbidden[@]}"; do
    if grep -Fq "$message" "$log"; then
        printf 'error: Konsole runtime log reports: %s\n' "$message" >&2
        grep -F "$message" "$log" | head -n 5 >&2 || true
        status=1
    fi
done

grep -Fq 'Loaded a static plugin for platform' "$log" || {
    printf 'error: KWindowSystem did not report loading its static platform plugin\n' >&2
    status=1
}

if [[ $status == 0 ]]; then
    printf 'Konsole runtime log: PASS (%s)\n' "$log"
fi
exit "$status"
