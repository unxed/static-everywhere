/* t_cli.c — spawns build/onebin and checks exit codes and behaviour.
 * 00-AGENT-TASK.md Task 9 gate: "Every flag has a test. Every exit code has
 * a test. Unknown flags, missing operands, and -- handling all have
 * tests." 01-SPEC-audit.md §5.
 */
#define _POSIX_C_SOURCE 200809L
#include "test.h"
#include "mkelf.h"
#include "elf/elf_const.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef ONEBIN_PATH
#define ONEBIN_PATH "./build/onebin"
#endif

typedef struct {
    int  exit_code;
    char out[16384];
} run_result;

static run_result run(const char *args) {
    run_result r;
    memset(&r, 0, sizeof(r));
    char cmd[16512];
    snprintf(cmd, sizeof(cmd), "%s %s 2>&1", ONEBIN_PATH, args);
    FILE *p = popen(cmd, "r");
    if (!p) {
        r.exit_code = -1;
        return r;
    }
    size_t n = fread(r.out, 1, sizeof(r.out) - 1, p);
    r.out[n] = '\0';
    int status = pclose(p);
    r.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return r;
}

static char *tmp_elf(const char *name, eg *o) {
    static char path[128];
    snprintf(path, sizeof(path), "/tmp/onebin_t_cli_%s_%d.elf", name, (int)getpid());
    if (eg_write(o, path) != 0) {
        path[0] = '\0';
    }
    return path;
}

/* ------------------------------------------------------------- basics */

TEST(cli_version) {
    run_result r = run("--version");
    ASSERT_EQ_INT(r.exit_code, 0);
    ASSERT_TRUE(strstr(r.out, "onebin") != NULL);
}

TEST(cli_help) {
    run_result r = run("--help");
    ASSERT_EQ_INT(r.exit_code, 0);
    ASSERT_TRUE(strstr(r.out, "audit") != NULL);
}

TEST(cli_audit_help) {
    run_result r = run("audit --help");
    ASSERT_EQ_INT(r.exit_code, 0);
    ASSERT_TRUE(strstr(r.out, "--profile") != NULL);
}

TEST(cli_no_args_is_usage_error) {
    run_result r = run("");
    ASSERT_EQ_INT(r.exit_code, 2);
}

TEST(cli_unknown_command) {
    run_result r = run("bogus-command");
    ASSERT_EQ_INT(r.exit_code, 2);
}

TEST(cli_audit_no_files_is_usage_error) {
    run_result r = run("audit");
    ASSERT_EQ_INT(r.exit_code, 2);
}

/* ------------------------------------------------------------- exit codes */

TEST(cli_exit_0_on_pass) {
    eg *o = eg_preset_static_ok();
    char *path = tmp_elf("pass", o);
    char args[256];
    snprintf(args, sizeof(args), "audit %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 0);
    eg_free(o); unlink(path);
}

TEST(cli_exit_1_on_fail) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libnotallowed.so.9");
    char *path = tmp_elf("fail", o);
    char args[256];
    snprintf(args, sizeof(args), "audit %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 1);
    eg_free(o); unlink(path);
}

TEST(cli_exit_2_on_missing_file) {
    run_result r = run("audit /tmp/onebin_cli_test_does_not_exist_xyz");
    ASSERT_EQ_INT(r.exit_code, 2);
}

TEST(cli_exit_2_on_not_elf) {
    char path[128];
    snprintf(path, sizeof(path), "/tmp/onebin_t_cli_notelf_%d", (int)getpid());
    FILE *f = fopen(path, "w");
    ASSERT_NOT_NULL(f);
    fputs("hello", f);
    fclose(f);
    char args[256];
    snprintf(args, sizeof(args), "audit %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 2);
    unlink(path);
}

/* ------------------------------------------------------------- per-flag */

TEST(cli_format_json) {
    eg *o = eg_preset_static_ok();
    char *path = tmp_elf("json", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --format json %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 0);
    ASSERT_TRUE(strstr(r.out, "\"schema\"") != NULL);
    eg_free(o); unlink(path);
}

TEST(cli_format_bad_value_is_usage_error) {
    run_result r = run("audit --format xml /nonexistent");
    ASSERT_EQ_INT(r.exit_code, 2);
}

TEST(cli_profile_forced) {
    eg *o = eg_preset_static_ok();
    char *path = tmp_elf("profforce", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --profile hybrid %s", path);
    run_result r = run(args);
    ASSERT_TRUE(strstr(r.out, "profile: hybrid") != NULL);
    eg_free(o); unlink(path);
}

TEST(cli_universal_profile_forced) {
    eg *o = eg_preset_static_ok();
    char *path = tmp_elf("universal", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --profile universal %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 0);
    ASSERT_TRUE(strstr(r.out, "profile: universal") != NULL);
    eg_free(o); unlink(path);
}

TEST(cli_profile_bad_value_is_usage_error) {
    run_result r = run("audit --profile bogus /nonexistent");
    ASSERT_EQ_INT(r.exit_code, 2);
}

TEST(cli_glibc_max) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_2.28" };
    eg_add_verneed(o, "libc.so.6", v, 1);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    char *path = tmp_elf("glibcmax", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --glibc-max 2.17 %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 1);
    ASSERT_TRUE(strstr(r.out, "OB0020") != NULL);
    eg_free(o); unlink(path);
}

TEST(cli_level_flag_accepted) {
    eg *o = eg_preset_static_ok();
    char *path = tmp_elf("level", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --level 2 %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 0);
    ASSERT_TRUE(strstr(r.out, "Level 2") != NULL);
    eg_free(o); unlink(path);
}

TEST(cli_level_out_of_range_is_usage_error) {
    run_result r = run("audit --level 9 /nonexistent");
    ASSERT_EQ_INT(r.exit_code, 2);
}

TEST(cli_allow_suppresses_needed_finding) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libweird.so.3");
    char *path = tmp_elf("allow", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --allow libweird.so.3 %s", path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 0);
    /* "libweird.so.3" itself still appears in the descriptive "needed:"
     * line regardless of allowlist status; what --allow suppresses is the
     * OB0010 finding about it. */
    ASSERT_TRUE(strstr(r.out, "OB0010") == NULL);
    eg_free(o); unlink(path);
}

TEST(cli_write_baseline_then_baseline_suppresses) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libweird.so.3");
    char *path = tmp_elf("wbaseline", o);
    char blpath[160];
    snprintf(blpath, sizeof(blpath), "%s.baseline", path);

    char wargs[300];
    snprintf(wargs, sizeof(wargs), "audit --write-baseline %s %s", blpath, path);
    run_result rw = run(wargs);
    ASSERT_EQ_INT(rw.exit_code, 0);

    char args[300];
    snprintf(args, sizeof(args), "audit --baseline %s %s", blpath, path);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 0);
    ASSERT_TRUE(strstr(r.out, "suppressed") != NULL);

    eg_free(o); unlink(path); unlink(blpath);
}

TEST(cli_baseline_missing_file_is_usage_error) {
    run_result r = run("audit --baseline /tmp/onebin_cli_no_such_baseline_xyz /nonexistent");
    ASSERT_EQ_INT(r.exit_code, 2);
}

TEST(cli_strict_flag) {
    eg *o = eg_preset_static_ok(); /* clean under c_harden.c */
    eg_set_rpath(o, "$ORIGIN/lib"); /* DT_RPATH present alone -> OB0042 warn */
    char *path = tmp_elf("strict", o);

    char args1[256];
    snprintf(args1, sizeof(args1), "audit %s", path);
    run_result r1 = run(args1);
    ASSERT_EQ_INT(r1.exit_code, 0); /* warn only, not strict */

    char args2[256];
    snprintf(args2, sizeof(args2), "audit --strict %s", path);
    run_result r2 = run(args2);
    ASSERT_EQ_INT(r2.exit_code, 1); /* warn counts under --strict */

    eg_free(o); unlink(path);
}

TEST(cli_quiet_suppresses_header) {
    eg *o = eg_preset_static_ok();
    char *path = tmp_elf("quiet", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --quiet %s", path);
    run_result r = run(args);
    ASSERT_TRUE(strstr(r.out, "==") == NULL);
    eg_free(o); unlink(path);
}

TEST(cli_verbose_shows_info) {
    eg *o = eg_preset_static_ok();
    char *path = tmp_elf("verbose", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --verbose %s", path);
    run_result r = run(args);
    ASSERT_TRUE(strstr(r.out, "OB0011") != NULL);
    eg_free(o); unlink(path);
}

TEST(cli_no_color_has_no_ansi) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libbad.so.1");
    char *path = tmp_elf("nocolor", o);
    char args[256];
    snprintf(args, sizeof(args), "audit --no-color %s", path);
    run_result r = run(args);
    ASSERT_TRUE(strchr(r.out, '\x1b') == NULL);
    eg_free(o); unlink(path);
}

/* ------------------------------------------------------------- -- and multi-file */

TEST(cli_double_dash_treats_rest_as_paths) {
    run_result r = run("audit -- --this-looks-like-a-flag-but-isnt");
    ASSERT_EQ_INT(r.exit_code, 2); /* file doesn't exist, but no "unknown option" error */
    ASSERT_TRUE(strstr(r.out, "unknown option") == NULL);
}

TEST(cli_multiple_files_worst_exit_code) {
    eg *ok = eg_preset_static_ok();
    char *p1 = tmp_elf("multi1", ok);
    eg *bad = eg_preset_hybrid_ok();
    eg_add_needed(bad, "libbad2.so.1");
    char pathbuf[128];
    snprintf(pathbuf, sizeof(pathbuf), "/tmp/onebin_t_cli_multi2_%d.elf", (int)getpid());
    ASSERT_EQ_INT(eg_write(bad, pathbuf), 0);

    char args[300];
    snprintf(args, sizeof(args), "audit %s %s", p1, pathbuf);
    run_result r = run(args);
    ASSERT_EQ_INT(r.exit_code, 1);

    eg_free(ok); eg_free(bad); unlink(p1); unlink(pathbuf);
}
