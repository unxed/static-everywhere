/* tests/t_f4_qt_plan.c — unit tests for tools/build-f4-qt.sh */
#define _POSIX_C_SOURCE 200809L
#include "test.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static const char *resolve_script(void) {
    if (access("./tools/build-f4-qt.sh", F_OK) == 0) {
        return "./tools/build-f4-qt.sh";
    }
    if (access("../tools/build-f4-qt.sh", F_OK) == 0) {
        return "../tools/build-f4-qt.sh";
    }
    return "tools/build-f4-qt.sh";
}

TEST(f4_qt_plan_linux_succeeds) {
    const char *script = resolve_script();
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "sh %s --config linux --gallery public --print-plan >/dev/null 2>&1", script);
    int rc = system(cmd);
    ASSERT_TRUE(rc != -1 && WIFEXITED(rc) && WEXITSTATUS(rc) == 0);
}

TEST(f4_qt_plan_windows_succeeds) {
    const char *script = resolve_script();
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "sh %s --config windows --gallery public --print-plan >/dev/null 2>&1", script);
    int rc = system(cmd);
    ASSERT_TRUE(rc != -1 && WIFEXITED(rc) && WEXITSTATUS(rc) == 0);
}

/* The gallery contract changed: ZoinGallery turned out to be public, so
   --gallery public is the default and needs no flag, while --gallery off
   was removed outright -- it exported an environment variable nothing
   read, promised a -DF4_NO_GALLERY that f4 has no option for, and would
   have produced an image viewer with no image viewing. These two tests
   pin the new contract in both directions.

   They also record a process miss worth remembering: the commit that
   changed this contract did not run `make test`, so these tests sat
   broken until an unrelated change happened to run the suite. The
   preflight now runs it. */
TEST(f4_qt_no_gallery_flag_is_fine) {
    const char *script = resolve_script();
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "sh %s --config linux --print-plan >/dev/null 2>&1", script);
    int rc = system(cmd);
    ASSERT_TRUE(rc != -1 && WIFEXITED(rc) && WEXITSTATUS(rc) == 0);
}

TEST(f4_qt_gallery_off_is_refused) {
    const char *script = resolve_script();
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "sh %s --config linux --gallery off --print-plan >/dev/null 2>&1", script);
    int rc = system(cmd);
    ASSERT_TRUE(rc != -1 && WIFEXITED(rc) && WEXITSTATUS(rc) != 0);
}
