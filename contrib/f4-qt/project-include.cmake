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
include("${CMAKE_CURRENT_LIST_DIR}/link-qt6-opengl.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/import-qt-static-plugins.cmake")
