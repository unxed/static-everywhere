#!/usr/bin/env bash
# Render the kde-builder config exactly as build-konsole.sh does and run
# the real kde-builder on it in --pretend mode.
#
# Why this exists
# ---------------
# Several two-hour runs died on things kde-builder rejects before building
# anything: ignore-projects given as a string where it demands a list; a
# comment inside a folded cmake-options scalar that shlex could not split;
# a pin it cannot resolve. Each was caught by CI half an hour to two hours
# in, and each is caught by kde-builder itself in about thirty seconds when
# it is simply run on the config. This runs it.
#
# --pretend parses the config, type-checks every option, fetches KDE's
# repo-metadata, resolves the dependency graph, validates the pins, and
# prints the build order -- everything the build job does up to the point
# of building. If it prints ":-)" the config is one kde-builder accepts.
set -euo pipefail

KDE_BUILDER=${1:?usage: $0 <kde-builder checkout>}
# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

# Every placeholder the template uses, with harmless local values. The
# placeholder-sync test guarantees this list and build-konsole.sh agree.
sed \
    -e "s|@KDE_SOURCE_DIR@|$R/src|g" \
    -e "s|@KDE_BUILD_DIR@|$R/build|g" \
    -e "s|@KDE_INSTALL_DIR@|$R/install|g" \
    -e "s|@KDE_LOG_DIR@|$R/log|g" \
    -e "s|@KDE_STATE_DIR@|$R/state|g" \
    -e "s|@KDE_JOBS@|2|g" \
    -e "s|@CONAN_TOOLCHAIN@|$R/conan_toolchain.cmake|g" \
    -e "s|@ZIGCC@|$REPO_ROOT/onebin/toolchain/zig-cc|g" \
    -e "s|@ZIGCXX@|$REPO_ROOT/onebin/toolchain/zig-c++|g" \
    -e "s|@CMAKE_PREFIX_PATH@|$R/qt|g" \
    -e "s|@PROJECT_INCLUDE@|$REPO_ROOT/contrib/konsole/project-include.cmake|g" \
    -e "s|@INSTALL_PREFIX_CMD@|$REPO_ROOT/tools/kde-install-and-reconcile.sh|g" \
    -e 's|@TARGET_TRIPLE@|x86_64-linux-gnu.2.27|g' \
    -e "s|@QT_PACKAGE_ROOT@|$R/qt|g" \
    -e "s|@KONSOLE_REF@|$(awk '$1 == "konsole" { print $2 }' "$REPO_ROOT/contrib/konsole/deps.lock")|g" \
    "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" >"$R/cfg.yaml"

if grep -qE '@[A-Z_]+@' "$R/cfg.yaml"; then
    printf 'unsubstituted placeholder in the rendered config:\n' >&2
    grep -oE '@[A-Z_]+@' "$R/cfg.yaml" | sort -u | sed 's/^/  /' >&2
    exit 1
fi

out=$(cd "$KDE_BUILDER" && timeout 600 python3 kde-builder \
        --rc-file "$R/cfg.yaml" --pretend konsole 2>&1) || status=$?
status=${status:-0}

if [ "$status" -ne 0 ] || ! printf '%s' "$out" | grep -q ':-)'; then
    printf 'kde-builder rejected the rendered config (exit %s):\n' "$status" >&2
    printf '%s\n' "$out" | grep -vE '^\s*$' | tail -15 | sed 's/^/  /' >&2
    exit 1
fi

# The resolved graph must still match the snapshot the forward scan uses;
# if kde-builder now resolves a different set, the scan is checking the
# wrong modules.
printf '%s\n' "$out" | grep -oE '^[a-z0-9-]+$' | sort -u >"$R/resolved.txt"
grep -vE '^\s*(#|$)' "$REPO_ROOT/contrib/konsole/kde-graph.txt" \
    | grep -vxE 'kdoctools|kirigami' | sort -u >"$R/snapshot.txt"
if ! diff -q "$R/snapshot.txt" "$R/resolved.txt" >/dev/null; then
    printf 'the resolved graph differs from contrib/konsole/kde-graph.txt:\n' >&2
    diff "$R/snapshot.txt" "$R/resolved.txt" | sed 's/^/  /' >&2
    printf 'update the snapshot so the forward scan checks the real graph\n' >&2
    exit 1
fi

count=$(wc -l <"$R/resolved.txt")
printf 'kde-builder --pretend accepted the config and resolved %s modules ending in konsole\n' "$count"
