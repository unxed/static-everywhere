# onebin/toolchain/tests/ — 00-AGENT-TASK.md Task 14's gate: a minimal C
# and C++ project built via each toolchain file, exercising every wrapper
# (zig-cc, zig-c++, zig-ar via the static archive, zig-ranlib transitively).
cmake_minimum_required(VERSION 3.16)
project(onebin_toolchain_smoketest C CXX)

add_library(hello_lib STATIC hello_lib.c)

add_executable(hello_c hello.c)
target_link_libraries(hello_c PRIVATE hello_lib)

add_executable(hello_cxx hello.cpp)
target_link_libraries(hello_cxx PRIVATE hello_lib)
