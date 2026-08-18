/* t_far2l_plan.c — 00-AGENT-TASK.md Task 15's gate: runs
 * tools/build-far2l.sh --print-plan for each of the four configurations
 * and compares the output byte-for-byte against tests/golden/far2l-*.plan.
 */
#define _POSIX_C_SOURCE 200809L
#include "test.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef ONEBIN_BUILD_FAR2L_SH
#define ONEBIN_BUILD_FAR2L_SH "./tools/build-far2l.sh"
#endif

static char *run_plan(const char *config, size_t *out_len) {
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "%s --config %s --print-plan 2>&1",
             ONEBIN_BUILD_FAR2L_SH, config);
    FILE *p = popen(cmd, "r");
    if (!p) {
        return NULL;
    }
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) {
        pclose(p);
        return NULL;
    }
    size_t n;
    while ((n = fread(buf + len, 1, cap - len, p)) > 0) {
        len += n;
        if (len == cap) {
            cap *= 2;
            char *nb = realloc(buf, cap);
            if (!nb) {
                free(buf);
                pclose(p);
                return NULL;
            }
            buf = nb;
        }
    }
    pclose(p);
    if (out_len) {
        *out_len = len;
    }
    return buf;
}

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)sz + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    size_t rd = fread(buf, 1, (size_t)sz, f);
    buf[rd] = '\0';
    fclose(f);
    if (out_len) {
        *out_len = rd;
    }
    return buf;
}

static void check_config(const char *config) {
    char goldpath[128];
    snprintf(goldpath, sizeof(goldpath), "tests/golden/far2l-%s.plan", config);

    size_t glen = 0;
    char *golden = read_file(goldpath, &glen);
    ASSERT_NOT_NULL(golden);

    size_t alen = 0;
    char *actual = run_plan(config, &alen);
    ASSERT_NOT_NULL(actual);

    if (alen != glen || memcmp(actual, golden, glen) != 0) {
        char msg[256];
        snprintf(msg, sizeof(msg),
                 "--print-plan output for --config %s does not match %s (got %zu bytes, want %zu)",
                 config, goldpath, alen, glen);
        free(golden);
        free(actual);
        test_fail(__FILE__, __LINE__, msg);
    }

    free(golden);
    free(actual);
}

TEST(far2l_plan_tiny_matches_golden) { check_config("tiny"); }
TEST(far2l_plan_tty_matches_golden)  { check_config("tty"); }
TEST(far2l_plan_sdl_matches_golden)  { check_config("sdl"); }
TEST(far2l_plan_wx_matches_golden)   { check_config("wx"); }

TEST(far2l_plan_is_deterministic_across_runs) {
    size_t l1 = 0, l2 = 0;
    char *a = run_plan("tiny", &l1);
    char *b = run_plan("tiny", &l2);
    ASSERT_NOT_NULL(a);
    ASSERT_NOT_NULL(b);
    ASSERT_TRUE(l1 == l2 && memcmp(a, b, l1) == 0);
    free(a);
    free(b);
}

TEST(far2l_no_fetch_missing_source_is_clean_error) {
    char cwd[400];
    ASSERT_NOT_NULL(getcwd(cwd, sizeof(cwd)));

    char cmd[600];
    snprintf(cmd, sizeof(cmd),
             "rm -rf /tmp/onebin_t_far2l_nofetch && mkdir /tmp/onebin_t_far2l_nofetch && "
             "cd /tmp/onebin_t_far2l_nofetch && %s/%s --config tiny "
             ">/tmp/onebin_t_far2l_out 2>&1; echo EXIT:$?",
             cwd, ONEBIN_BUILD_FAR2L_SH);

    FILE *p = popen(cmd, "r");
    ASSERT_NOT_NULL(p);
    char line[256];
    int exit_code = -1;
    while (fgets(line, sizeof(line), p)) {
        int v;
        if (sscanf(line, "EXIT:%d", &v) == 1) {
            exit_code = v;
        }
    }
    pclose(p);
    ASSERT_TRUE(exit_code != 0);

    char *out = read_file("/tmp/onebin_t_far2l_out", NULL);
    ASSERT_NOT_NULL(out);
    ASSERT_TRUE(strstr(out, "--fetch") != NULL);
    free(out);
}
