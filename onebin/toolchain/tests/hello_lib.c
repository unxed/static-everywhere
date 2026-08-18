/* hello_lib.c — a trivial static library, so the smoketest exercises
 * zig-ar/zig-ranlib (CMAKE_AR/CMAKE_RANLIB) as well as the compilers. */
const char *onebin_toolchain_greeting(void) {
    return "hello from onebin toolchain smoketest";
}
