#!/usr/bin/env bash
# Regression guard for the hybrid Konsole host-runtime contract.
#
# The artifact verifier and the onebin audit must consume one authoritative
# SONAME list. Duplicating that list made run 34057485004 reject the valid
# libxcb-cursor dependency after the build itself had succeeded.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CONTRACT="$REPO_ROOT/contrib/konsole/host-runtime-sonames.txt"
VERIFIER="$REPO_ROOT/tools/verify-konsole-artifact.sh"
BUILDER="$REPO_ROOT/tools/build-konsole.sh"

[[ -s $CONTRACT ]] || {
    printf 'host runtime contract is missing or empty: %s\n' "$CONTRACT" >&2
    exit 1
}

grep -Fq 'host-runtime-sonames.txt' "$VERIFIER" || {
    printf 'artifact verifier does not consume the host runtime contract\n' >&2
    exit 1
}
grep -Fq 'host-runtime-sonames.txt' "$BUILDER" || {
    printf 'Konsole builder does not consume the host runtime contract\n' >&2
    exit 1
}

declare -A seen=()
count=0
while IFS= read -r soname || [[ -n $soname ]]; do
    [[ -z $soname || $soname == \#* ]] && continue
    [[ $soname =~ ^[A-Za-z0-9._+-]+$ ]] || {
        printf 'invalid host runtime SONAME: %s\n' "$soname" >&2
        exit 1
    }
    case $soname in
        libGL.so*|libGLX.so*|libOpenGL.so*)
            printf 'forbidden OpenGL SONAME in host runtime contract: %s\n' "$soname" >&2
            exit 1
            ;;
    esac
    [[ -z ${seen[$soname]:-} ]] || {
        printf 'duplicate host runtime SONAME: %s\n' "$soname" >&2
        exit 1
    }
    seen[$soname]=1
    count=$((count + 1))
done < "$CONTRACT"

(( count > 0 )) || {
    printf 'host runtime contract contains no SONAMEs\n' >&2
    exit 1
}

for required in libX11.so.6 libxcb.so.1 libxcb-cursor.so.0 libEGL.so.1 libcanberra.so.0; do
    [[ -n ${seen[$required]:-} ]] || {
        printf 'required host runtime SONAME is missing: %s\n' "$required" >&2
        exit 1
    }
done

printf 'Konsole host runtime contract: PASS (%s explicit SONAMEs, no libGL)\n' "$count"
