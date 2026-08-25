# static-everywhere: repair the missing Qt6::Quick -> Qt6::OpenGL edge.
#
# Why this file exists
# --------------------
# With a *static* Qt, the final link of f4-qt-host fails:
#
#   ld.lld: error: undefined symbol: QOpenGLFramebufferObject::texture() const
#   >>> referenced by qsgdefaultpainternode.cpp:299
#   >>>               qsgdefaultpainternode.cpp.o:(QSGDefaultPainterNode::
#   >>>               updateRenderTarget()) in archive .../lib/libQt6Quick.a
#
# libQt6Quick.a genuinely references symbols that live in libQt6OpenGL.a,
# but the Conan qt recipe does not declare that edge. Straight from the
# generated dependency data in a real failing build:
#
#   set(qt_Qt6_Quick_DEPENDENCIES_RELEASE Qt6::Gui Qt6::Qml Qt6::QmlModels Qt6::Core)
#
# No Qt6::OpenGL -- even though the component exists in the same package.
# Shared builds never notice: libQt6Quick.so carries a DT_NEEDED on
# libQt6OpenGL.so and the dynamic linker resolves it. A static build has
# no such mechanism; the archive has to be on the link line, and f4's own
# qt/host/CMakeLists.txt asks only for
# `Core Gui Qml Quick QuickControls2 Network Svg`.
#
# Why it is injected rather than patched in
# -----------------------------------------
# f4 is the reference application this build exists to reproduce
# faithfully, so its sources are left alone -- the same reasoning that
# made qwindowkit's pin an environment wrapper rather than a patch to
# f4's script. CMake's CMAKE_PROJECT_INCLUDE hook runs this file after
# every project() call, including nested projects such as ZoinGallery.
# Restrict the hook to the top-level project, then cmake_language(DEFER)
# postpones the actual work to the end of that directory scope, by which
# point both find_package(Qt6) and the f4-qt-host target exist.
#
# Repairing the EDGE, not one consumer
# -----------------------------------
# The first version of this file did `target_link_libraries(f4-qt-host
# PRIVATE Qt6::OpenGL)`, which fixed the app and nothing else. The next
# run failed on F4PanelSplitterTests, F4OperationsQueueTests and
# F4DocumentSurfaceTests -- f4's own test executables, which link
# Qt6::Quick just as the app does and needed exactly the same archive.
# Naming one consumer treats the symptom; every future consumer (a test,
# a plugin, a QML module) would have to be listed here as it appeared.
#
# The defect is a missing edge in the dependency graph, so fix the edge:
# append Qt6::OpenGL to Qt6::Quick's own INTERFACE_LINK_LIBRARIES, and
# every consumer inherits it. Link interfaces are resolved at generate
# time, so this reaches targets already created in nested subdirectories
# too. Verified with a miniature project reproducing the real shape -- a
# static library referencing a symbol from another, an imported target
# that fails to declare the edge, and TWO consumers: naming one consumer
# leaves one link error, repairing the edge leaves none.
#
# Both preconditions are checked and fail loudly. A silent no-op here
# would resurface as the same confusing link error much later, so if the
# target names ever change upstream this stops immediately and says so.
#
# The mechanism itself was verified locally before being committed, with
# a negative control: a miniature project whose executable deliberately
# omits a needed static library fails to link on its own, and links and
# runs once this exact DEFER injection adds the dependency. The regression
# test also includes a nested project, because that is how the real failure
# escaped the original local miniature-project check.

if(NOT PROJECT_IS_TOP_LEVEL)
    return()
endif()

function(_static_everywhere_link_qt6_opengl)
    if(NOT TARGET Qt6::Quick)
        message(FATAL_ERROR
            "static-everywhere: Qt6::Quick target does not exist at the end of "
            "the top-level directory scope. This injection (see "
            "contrib/f4-qt/link-qt6-opengl.cmake) repairs Qt6::Quick's missing "
            "dependency on Qt6::OpenGL. If the Conan qt recipe ever declares "
            "that edge itself, delete this file; if it renamed the component, "
            "update it -- a static link needs the archive either way.")
    endif()

    if(NOT TARGET Qt6::OpenGL)
        message(FATAL_ERROR
            "static-everywhere: Qt6::OpenGL target not found. libQt6Quick.a "
            "references QOpenGLFramebufferObject, which lives in libQt6OpenGL.a, "
            "so a static link cannot succeed without it. Check that the Qt Conan "
            "package still ships the OpenGL component.")
    endif()

    set_property(TARGET Qt6::Quick APPEND PROPERTY
                 INTERFACE_LINK_LIBRARIES Qt6::OpenGL)
    message(STATUS
        "static-everywhere: added Qt6::OpenGL to Qt6::Quick's link interface "
        "(Conan's qt recipe omits that edge; only static links notice)")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_link_qt6_opengl)
