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
    snprintf(cmd, sizeof(cmd), "sh %s --config linux --gallery off --print-plan >/dev/null 2>&1", script);
    int rc = system(cmd);
    ASSERT_TRUE(rc != -1 && WIFEXITED(rc) && WEXITSTATUS(rc) == 0);
}

TEST(f4_qt_plan_windows_succeeds) {
    const char *script = resolve_script();
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "sh %s --config windows --gallery off --print-plan >/dev/null 2>&1", script);
    int rc = system(cmd);
    ASSERT_TRUE(rc != -1 && WIFEXITED(rc) && WEXITSTATUS(rc) == 0);
}

TEST(f4_qt_gallery_guard_fails_without_flag) {
    const char *script = resolve_script();
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "sh %s --config linux --print-plan >/dev/null 2>&1", script);
    int rc = system(cmd);
    ASSERT_TRUE(WEXITSTATUS(rc) != 0);
}
