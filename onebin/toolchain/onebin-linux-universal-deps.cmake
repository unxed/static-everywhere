# onebin-linux-universal-deps.cmake — Profile U dependency producer.
#
# Dependencies are compiled for the same musl target as the final U image,
# but their build systems may still configure helper SHARED/MODULE targets
# even when the recipe requests static libraries.  Profile S's executable
# flags (-static -pie) are correct for final executables, while U modules
# need -static after CMake's -shared create flag so Zig selects static target
# libraries for the shared object as well.
cmake_minimum_required(VERSION 3.16)

include("${CMAKE_CURRENT_LIST_DIR}/onebin-linux-static.cmake")

set(_onebin_shared_link_flags
    # SHARED/MODULE targets still have to be self-contained in Profile U.
    # CMake expands <LINK_FLAGS> before <...CREATE_*_FLAGS>, so putting
    # -static here leaves it before -shared.  Zig 0.13 uses the last driver
    # mode flag and consequently emits a module with libc.so despite all
    # explicitly listed third-party libraries being .a.  The create-rule
    # override below puts -static after -shared for every CMake language and
    # both shared-object target kinds; this is the class-level fix.
    "-Wl,-z,relro"
    "-Wl,-z,now"
    "-Wl,-z,noexecstack"
)
string(JOIN " " _onebin_shared_link_flags_str ${_onebin_shared_link_flags})
set(CMAKE_SHARED_LINKER_FLAGS_INIT
    "${_onebin_shared_link_flags_str}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT
    "${_onebin_shared_link_flags_str}")

# CMake's default C/C++ rules place <LINK_FLAGS> before
# <CMAKE_SHARED_LIBRARY_CREATE_*_FLAGS>, whose standard value is -shared.
# Keep the shared-object form, but append -static in the final driver order.
# This applies to every U SHARED/MODULE target, including helper libraries
# created by a dependency build, instead of depending on far2l target names.
foreach(_onebin_lang C CXX)
    set(CMAKE_SHARED_LIBRARY_CREATE_${_onebin_lang}_FLAGS "-shared -static")
    set(CMAKE_SHARED_MODULE_CREATE_${_onebin_lang}_FLAGS "-shared -static")
endforeach()
unset(_onebin_lang)

set(CMAKE_SKIP_RPATH ON)
