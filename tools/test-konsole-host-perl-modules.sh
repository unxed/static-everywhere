#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/contrib/konsole/host-perl-modules.txt"

[[ -r "$MANIFEST" ]] || {
    printf 'FAIL: host Perl module manifest is missing: %s\n' "$MANIFEST" >&2
    exit 1
}
command -v perl >/dev/null 2>&1 || {
    printf 'FAIL: perl is missing\n' >&2
    exit 1
}

checked=0
while read -r apt_package perl_module extra; do
    [[ -z "${apt_package:-}" || "$apt_package" == \#* ]] && continue
    [[ -n "${perl_module:-}" && -z "${extra:-}" ]] || {
        printf 'FAIL: malformed Perl module manifest entry\n' >&2
        exit 1
    }
    perl -M"$perl_module" -e 1 || {
        printf 'FAIL: Perl module is unavailable: %s (%s)\n' \
            "$perl_module" "$apt_package" >&2
        exit 1
    }
    printf 'PASS: %s provides Perl module %s\n' "$apt_package" "$perl_module"
    checked=$((checked + 1))
done < "$MANIFEST"

(( checked > 0 )) || {
    printf 'FAIL: host Perl module manifest is empty\n' >&2
    exit 1
}
printf 'Konsole host Perl modules: PASS\n'
