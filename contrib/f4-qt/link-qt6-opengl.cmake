# static-everywhere: link Qt6::OpenGL into f4-qt-host.
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
# f4's script. CMake's own CMAKE_PROJECT_INCLUDE hook runs this file
# immediately after f4's top-level project() call, and cmake_language(DEFER)
# postpones the actual work to the end of that directory scope, by which
# point both find_package(Qt6) and the f4-qt-host target exist.
#
# Both preconditions are checked and fail loudly. A silent no-op here
# would resurface as the same confusing link error much later, so if the
# target names ever change upstream this stops immediately and says so.
#
# The mechanism itself was verified locally before being committed, with
# a negative control: a miniature project whose executable deliberately
# omits a needed static library fails to link on its own, and links and
# runs once this exact DEFER injection adds the dependency.

function(_static_everywhere_link_qt6_opengl)
    if(NOT TARGET f4-qt-host)
        message(FATAL_ERROR
            "static-everywhere: target 'f4-qt-host' does not exist at the end of "
            "the top-level directory scope. This injection (see "
            "contrib/f4-qt/link-qt6-opengl.cmake) assumes f4 defines that target "
            "in qt/host/CMakeLists.txt. If upstream renamed or moved it, update "
            "this file rather than dropping it -- the static link needs "
            "Qt6::OpenGL either way.")
    endif()

    if(NOT TARGET Qt6::OpenGL)
        message(FATAL_ERROR
            "static-everywhere: Qt6::OpenGL target not found. libQt6Quick.a "
            "references QOpenGLFramebufferObject, which lives in libQt6OpenGL.a, "
            "so a static link cannot succeed without it. Check that the Qt Conan "
            "package still ships the OpenGL component.")
    endif()

    target_link_libraries(f4-qt-host PRIVATE Qt6::OpenGL)
    message(STATUS
        "static-everywhere: linked Qt6::OpenGL into f4-qt-host "
        "(Conan's qt recipe omits it from Qt6::Quick's dependencies; "
        "only static links notice)")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_link_qt6_opengl)
