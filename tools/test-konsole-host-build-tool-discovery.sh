#!/usr/bin/env bash
# Regression test for host tools omitted by CONFIG-mode package replacements.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-host-tools.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT

expected_xmllint=$(command -v xmllint) || {
    printf 'error: xmllint is required for this host-tool regression\n' >&2
    exit 1
}

mkdir -p "$PROBE/prefix/lib/cmake/LibXml2" "$PROBE/source"
cat >"$PROBE/prefix/lib/cmake/LibXml2/LibXml2Config.cmake" <<'CMAKE'
set(LibXml2_FOUND TRUE)
CMAKE
cat >"$PROBE/source/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.21)
project(konsole_host_build_tool_probe NONE)
find_package(LibXml2 REQUIRED)
if(NOT LIBXML2_XMLLINT_EXECUTABLE STREQUAL "$expected_xmllint")
    message(FATAL_ERROR
            "the host xmllint was not preserved across CONFIG-mode lookup: "
            "'\${LIBXML2_XMLLINT_EXECUTABLE}'")
endif()
if(NOT XMLLINT_EXECUTABLE STREQUAL "$expected_xmllint")
    message(FATAL_ERROR
            "the legacy xmllint variable was not preserved: "
            "'\${XMLLINT_EXECUTABLE}'")
endif()
CMAKE

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
    -DCMAKE_PREFIX_PATH="$PROBE/prefix" \
    -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON
printf 'Konsole host build-tool discovery regression: PASS\n'
