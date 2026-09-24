#!/usr/bin/env bash
# Regression guard for Qt resources compiled into STATIC libraries.
#
# An AUTORCC object inside an archive is referenced by nothing, so the linker
# leaves it out and :/ is empty at runtime. Konsole lost its menus, keyboard
# layouts and colour schemes that way. The recipe must move every .qrc of
# every STATIC target, in any subdirectory, into an OBJECT library whose
# objects are a link item of the static library's consumers. This
# configure-only fixture has Konsole's shape: the .qrc lives outside the
# target's directory and is named relative to it.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/source/src" "$PROBE/source/data"
cat >"$PROBE/source/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.21)
project(konsole_static_qt_resources_probe LANGUAGES CXX)
set(CMAKE_AUTORCC ON)

include("$REPO_ROOT/contrib/konsole/link-static-qt-resources.cmake")
cmake_language(DEFER DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}"
    CALL _se_link_static_qt_resources)

add_subdirectory(src)

function(check_static_qt_resources)
    get_target_property(probe_sources konsoleprivate SOURCES)
    get_target_property(probe_interface konsoleprivate INTERFACE_LINK_LIBRARIES)
    get_target_property(probe_plain_sources plainlib SOURCES)
    set(probe_object_sources "<none>")
    if(TARGET konsoleprivate_se_qt_resources)
        get_target_property(probe_object_sources
            konsoleprivate_se_qt_resources SOURCES)
    endif()
    file(WRITE "\${CMAKE_BINARY_DIR}/probe-result.txt"
        "sources=\${probe_sources}\n"
        "interface=\${probe_interface}\n"
        "object_sources=\${probe_object_sources}\n"
        "plain_sources=\${probe_plain_sources}\n")
endfunction()
cmake_language(DEFER DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}"
    CALL check_static_qt_resources)
CMAKE

cat >"$PROBE/source/src/CMakeLists.txt" <<'CMAKE'
add_library(konsoleprivate STATIC private.cpp ../data/data.qrc)
add_library(plainlib STATIC plain.cpp)
add_executable(konsole main.cpp)
target_link_libraries(konsole PRIVATE konsoleprivate plainlib)
CMAKE
printf 'int private_symbol() { return 1; }\n' >"$PROBE/source/src/private.cpp"
printf 'int plain_symbol() { return 2; }\n' >"$PROBE/source/src/plain.cpp"
printf 'int main() { return 0; }\n' >"$PROBE/source/src/main.cpp"
cat >"$PROBE/source/data/data.qrc" <<'QRC'
<!DOCTYPE RCC>
<RCC version="1.0"><qresource prefix="/konsole"></qresource></RCC>
QRC

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    >"$PROBE/configure.log" 2>&1 || {
    sed -n '1,240p' "$PROBE/configure.log" >&2
    exit 1
}

result="$PROBE/build/probe-result.txt"
[[ -f $result ]] || {
    printf 'static Qt resource probe produced no result\n' >&2
    exit 1
}
fail() {
    printf '%s\n' "$1" >&2
    cat "$result" >&2
    exit 1
}
grep -Eq '^sources=.*[.]qrc' "$result" &&
    fail 'the STATIC target still owns a .qrc that its archive would drop'
grep -Fq 'sources=private.cpp' "$result" ||
    fail 'the non-resource sources of the STATIC target were not kept'
grep -Fq '$<TARGET_OBJECTS:konsoleprivate_se_qt_resources>' "$result" ||
    fail 'the resource objects are not a link item of the STATIC target consumers'
grep -Fxq "object_sources=$PROBE/source/data/data.qrc" "$result" ||
    fail 'the .qrc was not moved as an absolute path relative to its target'
grep -Fxq 'plain_sources=plain.cpp' "$result" ||
    fail 'a STATIC target without resources was modified'

printf 'Konsole static Qt resources: PASS (every STATIC .qrc reaches the final link)\n'
