/* audit/checks/c_needed.c — 01-SPEC-audit.md §7.1. 00-AGENT-TASK.md Task 8. */
#include "audit/checks.h"
#include "util/str.h"
#include "util/limits.h"

#include <stdio.h>
#include <string.h>

static const char *const DEFAULT_ALLOWLIST[] = {
    "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1", "ld-linux-armhf.so.3",
    "ld-linux.so.2", "ld-linux-riscv64-lp64d.so.1",
    "libc.so.6", "libm.so.6",
    "libdl.so.2", "libpthread.so.0", "librt.so.1",
};
#define N_DEFAULT_ALLOWLIST (sizeof(DEFAULT_ALLOWLIST) / sizeof(DEFAULT_ALLOWLIST[0]))

static int on_allowlist(const ob_check_ctx *ctx, const char *soname) {
    for (size_t i = 0; i < N_DEFAULT_ALLOWLIST; i++) {
        if (strcmp(soname, DEFAULT_ALLOWLIST[i]) == 0) { /* case-sensitive: §4.1 #12 */
            return 1;
        }
    }
    for (size_t i = 0; i < ctx->nallow; i++) {
        if (strcmp(soname, ctx->allow[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

void ob_check_needed(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx || !ctx->dyn || !r) {
        return;
    }
    const ob_dynamic *dyn = ctx->dyn;

    if (dyn->nneeded == 0) {
        ob_report_add_finding(r, "OB0011", "needed.none", OB_SEV_INFO, "", "fully static");
        return;
    }

    /* One finding per DISTINCT offending soname even if it appears more
     * than once in DT_NEEDED (§4.1 #7): the first occurrence reports, and
     * names the total count in its message; later occurrences are skipped
     * here (the report's own fingerprint-based dedup would collapse them
     * anyway, but skipping avoids doing the O(n) duplicate-count scan more
     * than once per distinct name). */
    for (size_t i = 0; i < dyn->nneeded; i++) {
        char soname[OB_STR_MAXLEN + 1];
        ob_str_err e = ob_dynamic_string(ctx->img, dyn, dyn->needed[i], soname, sizeof(soname));
        if (e != OB_STR_OK) {
            continue; /* elf/dynamic.c already accounts for this: OB0003 is
                       * emitted elsewhere (01-SPEC-audit.md §12) */
        }

        int already_seen = 0;
        for (size_t j = 0; j < i && !already_seen; j++) {
            char other[OB_STR_MAXLEN + 1];
            if (ob_dynamic_string(ctx->img, dyn, dyn->needed[j], other, sizeof(other)) == OB_STR_OK &&
                strcmp(other, soname) == 0) {
                already_seen = 1;
            }
        }
        if (already_seen) {
            continue;
        }

        size_t total_occurrences = 1;
        for (size_t j = i + 1; j < dyn->nneeded; j++) {
            char other[OB_STR_MAXLEN + 1];
            if (ob_dynamic_string(ctx->img, dyn, dyn->needed[j], other, sizeof(other)) == OB_STR_OK &&
                strcmp(other, soname) == 0) {
                total_occurrences++;
            }
        }

        char msg[OB_STR_MAXLEN + 64];
        if (strcmp(soname, "libgcc_s.so.1") == 0) {
            snprintf(msg, sizeof(msg),
                     "glibc dlopens libgcc_s.so.1 for unwinding and pthread_cancel "
                     "even under -static-libgcc; this is common and usually harmless");
            ob_report_add_finding(r, "OB0012", "needed.libgcc", OB_SEV_WARN, soname, msg);
        } else if (strcmp(soname, "libstdc++.so.6") == 0) {
            snprintf(msg, sizeof(msg), "dynamic libstdc++; link with -static-libstdc++");
            ob_report_add_finding(r, "OB0013", "needed.libstdcxx", OB_SEV_ERROR, soname, msg);
        } else if (!on_allowlist(ctx, soname)) {
            if (total_occurrences > 1) {
                snprintf(msg, sizeof(msg), "not on the allowlist (appears %zu times)", total_occurrences);
            } else {
                snprintf(msg, sizeof(msg), "not on the allowlist");
            }
            ob_report_add_finding(r, "OB0010", "needed.allowlist", OB_SEV_ERROR, soname, msg);
        }
    }
}
