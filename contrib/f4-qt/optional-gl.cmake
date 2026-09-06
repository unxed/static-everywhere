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

# A Qt target can be consumed by an executable, a shared library, or a
# MODULE.  The optional library boundary has to hold at every one of those
# loadable link boundaries.  It is not enough to make the final executable
# safe: a shared library that embeds static Qt can acquire its own DT_NEEDED
# on libGL and the loader resolves that dependency before the executable (or
# its fallback constructor) runs.
function(_se_remove_system_gl_dependency target)
    if(NOT TARGET "${target}")
        return()
    endif()

    get_target_property(_links "${target}" INTERFACE_LINK_LIBRARIES)
    if(_links STREQUAL "_links-NOTFOUND")
        return()
    endif()

    set(_filtered "")
    foreach(_link IN LISTS _links)
        string(TOLOWER "${_link}" _lower_link)
        if(_lower_link MATCHES "(^|::)(opengl|wrapopengl)::gl([^a-z0-9_]|$)" OR
           _lower_link MATCHES "(^|/)libgl[.]so([.]([0-9]+))?([^a-z0-9_]|$)" OR
           _lower_link STREQUAL "gl" OR
           _lower_link MATCHES "(^|[;$<>])[-]lgl([^a-z0-9_]|$)")
            message(STATUS
                "static-everywhere: removed system libGL link item '${_link}' "
                "from ${target}; the generated forwarder supplies its symbols")
        else()
            list(APPEND _filtered "${_link}")
        endif()
    endforeach()
    set_property(TARGET "${target}" PROPERTY INTERFACE_LINK_LIBRARIES
                 "${_filtered}")
endfunction()

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

    # The generated definitions must be present in every loadable consumer
    # of Qt6::Gui.  Static libraries are deliberately excluded: they do not
    # create a loader boundary, and attaching the same definitions there
    # would duplicate them in every final consumer.  Executables alone were
    # insufficient for Konsole's libkonsoleapp SHARED target.
    set(_se_loadable_sources
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:${_gen}>"
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,SHARED_LIBRARY>:${_gen}>"
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,MODULE_LIBRARY>:${_gen}>"
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:${_se_fallback}>"
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,SHARED_LIBRARY>:${_se_fallback}>"
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,MODULE_LIBRARY>:${_se_fallback}>")
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_SOURCES
        ${_se_loadable_sources})

    # The forwarder and the fallback use dlopen/dlsym.  Carry the platform's
    # loader library through the same interface so shared and module targets
    # are link-complete, not merely source-complete.
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_LINK_LIBRARIES
                 "${CMAKE_DL_LIBS}")

    # Conan's static Qt targets may expose the host GL library as a transitive
    # link item.  Once the forwarder supplies every GL symbol, retaining that
    # item would recreate DT_NEEDED on shared/module consumers on linkers that
    # do not default to --as-needed.  Remove the system edge from every Qt
    # target that can carry it; Qt6::OpenGL remains a static Qt archive and is
    # intentionally not removed.
    foreach(_qt_target Qt6::Gui Qt6::Widgets Qt6::Quick)
        _se_remove_system_gl_dependency("${_qt_target}")
    endforeach()

    message(STATUS
        "static-everywhere: libGL is now optional at executable/shared/module "
        "boundaries; software rendering is selected automatically when it is absent")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_optional_gl)
