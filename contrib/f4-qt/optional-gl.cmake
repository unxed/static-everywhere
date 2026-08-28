# static-everywhere: make libGL optional, with a software fallback.
#
# Why
# ---
# A library on the link line becomes a DT_NEEDED entry, and the loader
# resolves those before main(). So `f4-qt-host` linked against libGL does
# not start at all on a host without libGL: no fallback code of ours ever
# runs, because no code of ours runs. For an artefact whose entire premise
# is "runs anywhere", a hard dependency on a GPU driver library is the
# wrong shape.
#
# Two pieces, both necessary:
#
#   1. tools/gen-optional-lib-forwarder.sh defines every symbol libGL
#      exports, each a tail-call to a pointer resolved by dlopen at
#      startup. The linker then never needs libGL and records no
#      dependency on it. Measured: DT_NEEDED goes from
#      "libGL.so.1, libc.so.6" to "libc.so.6, libdl.so.2", and libdl is
#      already on onebin's default allowlist.
#
#   2. contrib/f4-qt/compat/render-backend-fallback.c asks, before
#      main(), whether libGL can be opened, and if not selects Qt's
#      software scene graph. Qt will not do this by itself -- see that
#      file for the citations.
#
# Scope note: this covers GL only. The same technique would remove libX11
# and the libxcb family from DT_NEEDED, which would let the binary run
# headless on a machine with no X libraries installed at all. That is
# worth doing and is deliberately left for after this one has proven
# itself on a smaller surface.

if(NOT PROJECT_IS_TOP_LEVEL)
    return()
endif()

function(_static_everywhere_optional_gl)
    if(NOT TARGET Qt6::Gui)
        message(FATAL_ERROR
            "static-everywhere: Qt6::Gui does not exist at the end of the "
            "top-level directory scope, so the optional-GL forwarder has "
            "nowhere to attach. See contrib/f4-qt/optional-gl.cmake.")
    endif()

    # The symbol list is read from a real libGL on the build host. A
    # symbol Qt needs that this libGL does not export will fail at link
    # time, loudly, which is the failure worth having: the alternative is
    # a binary that starts and then jumps to a null pointer.
    find_library(_se_libgl NAMES GL
        PATHS /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib
        NO_DEFAULT_PATH)
    if(NOT _se_libgl)
        message(FATAL_ERROR
            "static-everywhere: no libGL found on the build host, so the "
            "list of symbols to forward cannot be read. Install libgl-dev. "
            "Without this the binary keeps a hard DT_NEEDED on libGL and "
            "will not start where GL is absent.")
    endif()

    set(_gen "${CMAKE_BINARY_DIR}/static_everywhere_gl_forwarder.c")
    execute_process(
        COMMAND "${_SE_REPO_ROOT}/tools/gen-optional-lib-forwarder.sh"
                "libGL.so.1" "se_gl" "${_se_libgl}" "${_gen}"
        RESULT_VARIABLE _rc
        OUTPUT_VARIABLE _out
        ERROR_VARIABLE _err)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR
            "static-everywhere: generating the libGL forwarder failed "
            "(${_rc}):\n${_err}")
    endif()
    string(STRIP "${_out}" _out)
    message(STATUS "static-everywhere: ${_out}")

    # f4's host project enables CXX, not C. These files contain C-compatible
    # code, but adding a .c source through an imported target's
    # INTERFACE_SOURCES makes newer CMake try to enable C after project()
    # already configured the language set. That leaves CMAKE_C_COMPILE_OBJECT
    # unset and fails during generation. Keep both sources in the project's
    # existing C++ language context instead. The generator emits C linkage
    # for its assembly-referenced globals, so compiling it as C++ preserves
    # the exact symbol names used by the trampolines.
    set(_se_fallback
        "${_SE_REPO_ROOT}/contrib/f4-qt/compat/render-backend-fallback.c")
    set_source_files_properties("${_gen}" "${_se_fallback}"
        PROPERTIES LANGUAGE CXX)

    # Executables only, exactly as the plugin import unit: a registration
    # or a symbol definition compiled into an intermediate static library
    # ends up duplicated in every consumer, and once produced a ninja
    # dependency cycle. See import-qt-static-plugins.cmake.
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_SOURCES
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:${_gen}>"
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:${_se_fallback}>")

    message(STATUS
        "static-everywhere: libGL is now optional; software rendering is "
        "selected automatically when it is absent")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_optional_gl)
