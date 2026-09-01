#!/usr/bin/env bash
# Verify host tools and data required by kdoctools' DocBook processing.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/contrib/konsole/host-docbook-tools.txt"

[[ -r "$MANIFEST" ]] || {
    printf 'error: DocBook host-tool manifest is missing: %s\n' "$MANIFEST" >&2
    exit 1
}

checked=0
while read -r apt_package probe_type probe extra; do
    [[ -z "${apt_package:-}" || "$apt_package" == \#* ]] && continue
    [[ -n "${probe_type:-}" && -n "${probe:-}" && -z "${extra:-}" ]] || {
        printf 'error: malformed DocBook host-tool manifest entry\n' >&2
        exit 1
    }
    case "$probe_type" in
        pkg-config)
            pkg-config --exists "$probe" || {
                printf 'error: %s does not provide pkg-config module %s\n' \
                    "$apt_package" "$probe" >&2
                exit 1
            }
            ;;
        command)
            command -v "$probe" >/dev/null 2>&1 || {
                printf 'error: %s does not provide command %s\n' \
                    "$apt_package" "$probe" >&2
                exit 1
            }
            ;;
        file)
            [[ -e "$probe" ]] || {
                printf 'error: %s does not provide %s\n' "$apt_package" "$probe" >&2
                exit 1
            }
            ;;
        *)
            printf 'error: unknown DocBook host-tool probe type: %s\n' "$probe_type" >&2
            exit 1
            ;;
    esac
    printf 'PASS: %s provides %s %s\n' "$apt_package" "$probe_type" "$probe"
    checked=$((checked + 1))
done < "$MANIFEST"

(( checked > 0 )) || {
    printf 'error: DocBook host-tool manifest is empty\n' >&2
    exit 1
}
