#!/usr/bin/env bash
# The ICU consistency probe must use FindICU's concrete values, not a
# Conan-style imported target whose generator-expression properties cannot be
# transferred to CMake's try_compile project.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-icu.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/source" "$PROBE/target-include"
cat >"$PROBE/source/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.16)
project(konsole_icu_consistency_probe CXX)

find_path(SE_ICU_INCLUDE NAMES unicode/uvernum.h)
find_library(SE_ICU_UC NAMES icuuc)
if(NOT SE_ICU_INCLUDE OR NOT SE_ICU_UC)
    message(FATAL_ERROR "the host ICU development files are required")
endif()
file(WRITE "\${CMAKE_BINARY_DIR}/probe-values.txt"
     "\${SE_ICU_INCLUDE}\n\${SE_ICU_UC}\n")

# This is the shape that triggered the hosted failure: the target exists, but
# its include path is configuration-gated and it publishes no direct
# IMPORTED_LOCATION for CheckCXXSourceCompiles to carry into try_compile.
add_library(ICU::uc INTERFACE IMPORTED)
set_target_properties(ICU::uc PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES
        "\$<\$<CONFIG:Release>:${PROBE}/target-include>")

# These are the stable values published by FindICU. The checker must prefer
# them over the incomplete Conan target metadata.
set(ICU_FOUND TRUE)
set(ICU_VERSION "probe")
set(ICU_INCLUDE_DIRS "\${SE_ICU_INCLUDE}")
set(ICU_UC_LIBRARY_RELEASE "\${SE_ICU_UC}")
include("${REPO_ROOT}/contrib/konsole/check-icu-consistency.cmake")
CMAKE

# If the probe accidentally falls back to the target's include directory, it
# has no ICU headers and fails before it can link. With no required include
# path the compiler would instead see the host header, but the target has no
# link location and the undefined ubidi_* symbols catch that variant too.
cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja >/dev/null
mapfile -t icu_probe_paths <"$PROBE/build/probe-values.txt"
configure_log="$PROBE/build/CMakeFiles/CMakeConfigureLog.yaml"
grep -Fq -- "${icu_probe_paths[0]}" "$configure_log" || {
    printf 'the try_compile command did not receive FindICU include path %s\n' \
        "${icu_probe_paths[0]}" >&2
    exit 1
}
grep -Fq -- "${icu_probe_paths[1]}" "$configure_log" || {
    printf 'the try_compile command did not receive FindICU uc library %s\n' \
        "${icu_probe_paths[1]}" >&2
    exit 1
}
printf 'Konsole ICU consistency regression: PASS\n'
