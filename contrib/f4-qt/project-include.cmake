# static-everywhere: the single CMAKE_PROJECT_INCLUDE entry point.
#
# CMAKE_PROJECT_INCLUDE has accepted a list only since CMake 3.29. This
# build pins 3.31.6 and would be fine, but a one-file entry point costs
# nothing and removes a silent failure mode: passed a list to an older
# CMake, the extra files are simply ignored and the build fails much
# later with a link or runtime error that says nothing about hooks.
#
# Each included file guards itself with PROJECT_IS_TOP_LEVEL, because
# CMAKE_PROJECT_INCLUDE runs after *every* project() call, nested ones
# included.
# Runs in EVERY project scope, nested ones included -- unlike the two
# below, which guard themselves to the top level. It must, because the
# target it rewrites is declared inside ZoinGallery's own project().
include("${CMAKE_CURRENT_LIST_DIR}/force-static-qml-backing.cmake")

# The repository root, derived once here rather than guessed by each
# hook: this file's directory is contrib/f4-qt, two levels down.
get_filename_component(_SE_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)

include("${CMAKE_CURRENT_LIST_DIR}/link-qt6-opengl.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/import-qt-static-plugins.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/optional-gl.cmake")
