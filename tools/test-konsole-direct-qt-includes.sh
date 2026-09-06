#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/src/kioworkers/file"
printf '%s\n' \
    '#include "file.h"' \
    'QUrl copy_source;' \
    >"$TMP/src/kioworkers/file/file_unix_copy.cpp"
printf '%s\n' \
    'cmake_minimum_required(VERSION 3.28)' \
    'project(KIO LANGUAGES NONE)' \
    >"$TMP/CMakeLists.txt"

cmake -S "$TMP" -B "$TMP/build" \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
    >"$TMP/configure.log"

source_file="$TMP/src/kioworkers/file/file_unix_copy.cpp"
grep -Fqx '#include <QUrl>' "$source_file" \
    || { printf 'FAIL: direct QUrl include was not inserted\n' >&2; exit 1; }
[ "$(grep -Fxc '#include <QUrl>' "$source_file")" -eq 1 ] \
    || { printf 'FAIL: direct QUrl include was inserted more than once\n' >&2; exit 1; }

# Reconfigure to prove the contract is idempotent rather than accumulating
# headers on every kde-builder configure pass.
cmake -S "$TMP" -B "$TMP/build" \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
    >"$TMP/reconfigure.log"
[ "$(grep -Fxc '#include <QUrl>' "$source_file")" -eq 1 ] \
    || { printf 'FAIL: direct Qt include contract is not idempotent\n' >&2; exit 1; }

printf 'PASS: split-source direct Qt include contract\n'
