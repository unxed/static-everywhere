/* report_fixtures.c — see report_fixtures.h. */
#include "report_fixtures.h"

#include <stdio.h>

void fixture_hybrid_ok(ob_report *r) {
    ob_report_set_file(r, "build/fixtures/hybrid-ok.elf");
    ob_report_set_format(r, "elf");
    ob_report_set_class(r, 64);
    ob_report_set_endian(r, "little");
    ob_report_set_machine(r, "x86_64");
    ob_report_set_type(r, "ET_DYN");
    ob_report_set_profile(r, "hybrid", "auto");
    ob_report_set_interp(r, "/lib64/ld-linux-x86-64.so.2");
    ob_report_add_needed(r, "libc.so.6");
    ob_report_add_needed(r, "libm.so.6");
    ob_report_add_runpath(r, "$ORIGIN/../lib");
    ob_report_set_glibc(r, "2.28", "2.28");
    static const char *const vers[] = { "GLIBC_2.2.5", "GLIBC_2.28" };
    ob_report_add_verreq(r, "libc.so.6", vers, 2);
    ob_report_set_level(r, OB_LEVEL_1);
    ob_report_add_finding(r, "OB0011", "needed.none", OB_SEV_OK, "",
                           "all DT_NEEDED entries are on the allowlist");
    ob_report_add_finding(r, "OB0041", "rpath.origin", OB_SEV_WARN,
                           "$ORIGIN/../lib", "RUNPATH is $ORIGIN-relative");
    ob_report_add_finding(r, "OB0051", "harden.bindnow", OB_SEV_ERROR, "",
                           "no BIND_NOW (add -Wl,-z,now)");
}

void fixture_static_clean(ob_report *r) {
    ob_report_set_file(r, "build/fixtures/static-clean.elf");
    ob_report_set_format(r, "elf");
    ob_report_set_class(r, 64);
    ob_report_set_endian(r, "little");
    ob_report_set_machine(r, "x86_64");
    ob_report_set_type(r, "ET_DYN"); /* static-PIE: ET_DYN, no PT_INTERP, no DT_NEEDED */
    ob_report_set_profile(r, "static", "auto");
    /* interp, soname: left NULL (absent). needed/runpath/rpath: left empty.
     * glibc: nothing dynamic to check, so both stay NULL — the "unknown,
     * not zero" case 01-SPEC-audit.md §6.3 describes, one step further:
     * not even attempted. */
    ob_report_set_level(r, OB_LEVEL_1);
    ob_report_add_finding(r, "OB0011", "needed.none", OB_SEV_INFO, "", "fully static");
    ob_report_add_finding(r, "OB0050", "harden.relro", OB_SEV_OK, "", "full RELRO");
}

void fixture_module(ob_report *r) {
    ob_report_set_file(r, "build/fixtures/plugin.so");
    ob_report_set_format(r, "elf");
    ob_report_set_class(r, 64);
    ob_report_set_endian(r, "little");
    ob_report_set_machine(r, "x86_64");
    ob_report_set_type(r, "ET_DYN");
    ob_report_set_profile(r, "module", "auto");
    ob_report_add_needed(r, "libc.so.6");
    ob_report_set_level(r, OB_LEVEL_1);
    ob_report_add_finding(r, "OB0038", "profile.module", OB_SEV_INFO, "", "no DT_SONAME: a loadable module, not a shared library");
    ob_report_add_finding(r, "OB0050", "harden.relro", OB_SEV_OK, "", "full RELRO");
}

void fixture_baseline_suppressed(ob_report *r, const char *baseline_path, ob_baseline *bl) {
    ob_report_set_file(r, "build/fixtures/hybrid-warn.elf");
    ob_report_set_format(r, "elf");
    ob_report_set_class(r, 64);
    ob_report_set_endian(r, "little");
    ob_report_set_machine(r, "x86_64");
    ob_report_set_type(r, "ET_DYN");
    ob_report_set_profile(r, "hybrid", "auto");
    ob_report_set_interp(r, "/lib64/ld-linux-x86-64.so.2");
    ob_report_add_needed(r, "libc.so.6");
    ob_report_set_glibc(r, "2.28", "2.28");
    ob_report_set_level(r, OB_LEVEL_1);
    ob_report_add_finding(r, "OB0041", "rpath.origin", OB_SEV_WARN,
                           "$ORIGIN/../lib", "RUNPATH is $ORIGIN-relative");
    ob_report_add_finding(r, "OB0060", "hygiene.buildpath", OB_SEV_WARN,
                           "/home/builder/src/main.c", "embedded build path");

    FILE *f = fopen(baseline_path, "w");
    if (f) {
        fprintf(f, "# onebin baseline v1\n");
        fprintf(f, "OB0041:$ORIGIN/../lib\n");
        fclose(f);
    }
    ob_baseline_load(baseline_path, bl);
}

void fixture_many_needed(ob_report *r) {
    ob_report_set_file(r, "build/fixtures/many-needed.elf");
    ob_report_set_format(r, "elf");
    ob_report_set_class(r, 64);
    ob_report_set_endian(r, "little");
    ob_report_set_machine(r, "x86_64");
    ob_report_set_type(r, "ET_DYN");
    ob_report_set_profile(r, "hybrid", "auto");
    ob_report_set_interp(r, "/lib64/ld-linux-x86-64.so.2");
    ob_report_add_needed(r, "libc.so.6");
    ob_report_add_needed(r, "libm.so.6");
    ob_report_add_needed(r, "libdl.so.2");
    ob_report_add_needed(r, "libpthread.so.0");
    ob_report_add_needed(r, "librt.so.1");
    ob_report_set_glibc(r, "2.28", "2.28");
    ob_report_set_level(r, OB_LEVEL_1);
    ob_report_add_finding(r, "OB0011", "needed.none", OB_SEV_OK, "", "all DT_NEEDED entries are on the allowlist");
}

void fixture_sanitized(ob_report *r) {
    ob_report_set_file(r, "build/fixtures/hostile.elf");
    ob_report_set_format(r, "elf");
    ob_report_set_class(r, 64);
    ob_report_set_endian(r, "little");
    ob_report_set_machine(r, "x86_64");
    ob_report_set_type(r, "ET_DYN");
    ob_report_set_profile(r, "hybrid", "auto");
    ob_report_set_interp(r, "/lib64/ld-linux-x86-64.so.2");
    {
        char dirty[16];
        dirty[0] = 'l'; dirty[1] = 'i'; dirty[2] = 'b';
        dirty[3] = (char)0x01; dirty[4] = (char)0xFF;
        dirty[5] = '.'; dirty[6] = 's'; dirty[7] = 'o';
        dirty[8] = '\0';
        ob_report_add_needed(r, dirty);
    }
    ob_report_set_level(r, OB_LEVEL_1);
    {
        char dirty_subject[8] = { (char)0x1B, '[', '3', '1', 'm', 0 };
        ob_report_add_finding(r, "OB0010", "needed.allowlist", OB_SEV_ERROR,
                               dirty_subject, "not on the allowlist");
    }
}
