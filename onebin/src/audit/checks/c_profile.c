/* audit/checks/c_profile.c — 01-SPEC-audit.md §7.3. 00-AGENT-TASK.md Task 8. */
#include "audit/checks.h"
#include "util/str.h"
#include "util/limits.h"
#include "elf/strings.h"
#include "elf/elf_const.h"

#include <string.h>

/* Known interpreters, 02-REFERENCE-elf.md §4 — used only to decide whether
 * OB0037 fires, so an unrecognised-but-plausible one is not itself wrong;
 * it just can't be confirmed. */
static const char *const KNOWN_INTERP[] = {
    "/lib64/ld-linux-x86-64.so.2",
    "/lib/ld-linux.so.2",
    "/lib/ld-linux-aarch64.so.1",
    "/lib/ld-linux-armhf.so.3",
    "/lib/ld-linux-riscv64-lp64d.so.1",
};
#define N_KNOWN_INTERP (sizeof(KNOWN_INTERP) / sizeof(KNOWN_INTERP[0]))

static int is_known_interp(const char *path) {
    for (size_t i = 0; i < N_KNOWN_INTERP; i++) {
        if (strcmp(path, KNOWN_INTERP[i]) == 0) {
            return 1;
        }
    }
    /* musl's ld-musl-<arch>.so.1 family, 02-REFERENCE-elf.md §4. */
    size_t n = strlen(path);
    return strncmp(path, "/lib/ld-musl-", 13) == 0 && n >= 5 &&
           strcmp(path + n - 5, ".so.1") == 0;
}

/* ---- PT_INTERP: find the first one, per §12's "multiple PT_INTERP" rule */

static const ob_phdr *first_interp(const ob_image *img, int *count_out) {
    const ob_phdr *first = NULL;
    int count = 0;
    for (size_t i = 0; i < img->nphdrs; i++) {
        if (img->phdrs[i].p_type == PT_INTERP) {
            if (!first) {
                first = &img->phdrs[i];
            }
            count++;
        }
    }
    if (count_out) {
        *count_out = count;
    }
    return first;
}

/* ---- dlopen / static-glibc string evidence, §7.3's Profile S checks ---- */

typedef struct {
    int has_dlopen_symbol;      /* from a .symtab — v0.1 doesn't parse the
                                  * full static symbol table, so this stays
                                  * 0 for now; see NOTES.md */
    int has_musl_dlopen_stub;   /* "Dynamic loading not supported" */
    int has_dlopen_string;      /* "dlopen" as a standalone string */
    int has_nsswitch_string;
    int has_libnss_string;
    int has_nss_module_string;
} string_evidence;

static void evidence_cb(const char *s, size_t len, size_t off, void *user) {
    (void)off;
    string_evidence *e = (string_evidence *)user;
    /* Bounded, explicit comparisons rather than building a NUL-terminated
     * copy: the run is not NUL-terminated by the scanner, and these needles
     * are short and fixed, so a manual substring/equality check is both
     * simpler and avoids a copy per candidate string. */
    static const char needle1[] = "Dynamic loading not supported";
    static const char needle2[] = "dlopen";
    static const char needle3[] = "/etc/nsswitch.conf";
    static const char needle4[] = "libnss_";
    static const char needle5[] = "__nss_module";

    if (len == sizeof(needle1) - 1 && memcmp(s, needle1, len) == 0) {
        e->has_musl_dlopen_stub = 1;
    }
    if (len == sizeof(needle2) - 1 && memcmp(s, needle2, len) == 0) {
        e->has_dlopen_string = 1;
    }
    if (len >= sizeof(needle3) - 1) {
        for (size_t i = 0; i + (sizeof(needle3) - 1) <= len; i++) {
            if (memcmp(s + i, needle3, sizeof(needle3) - 1) == 0) {
                e->has_nsswitch_string = 1;
                break;
            }
        }
    }
    if (len >= sizeof(needle4) - 1) {
        for (size_t i = 0; i + (sizeof(needle4) - 1) <= len; i++) {
            if (memcmp(s + i, needle4, sizeof(needle4) - 1) == 0) {
                e->has_libnss_string = 1;
                break;
            }
        }
    }
    if (len >= sizeof(needle5) - 1) {
        for (size_t i = 0; i + (sizeof(needle5) - 1) <= len; i++) {
            if (memcmp(s + i, needle5, sizeof(needle5) - 1) == 0) {
                e->has_nss_module_string = 1;
                break;
            }
        }
    }
}

static void check_profile_s(const ob_check_ctx *ctx, ob_report *r) {
    const ob_image *img = ctx->img;

    int interp_count = 0;
    if (first_interp(img, &interp_count)) {
        ob_report_add_finding(r, "OB0030", "profile.interp", OB_SEV_ERROR, "",
                               "PT_INTERP present in a file audited as Profile S");
    }
    if (ctx->dyn && ctx->dyn->nneeded > 0) {
        ob_report_add_finding(r, "OB0031", "profile.needed", OB_SEV_ERROR, "",
                               "DT_NEEDED present in a file audited as Profile S");
    }
    if (img->e_type == ET_EXEC) {
        ob_report_add_finding(r, "OB0032", "profile.nopie", OB_SEV_WARN, "",
                               "static but not PIE, so no ASLR; consider -static-pie");
    }

    string_evidence ev;
    memset(&ev, 0, sizeof(ev));
    ob_strings_scan(&img->buf, evidence_cb, &ev);

    if (ev.has_musl_dlopen_stub || ev.has_dlopen_symbol) {
        ob_report_add_finding(r, "OB0033", "profile.dlopen", OB_SEV_ERROR, "",
                               "evidence of dlopen in a statically linked binary");
    } else if (ev.has_dlopen_string) {
        ob_report_add_finding(r, "OB0033", "profile.dlopen", OB_SEV_WARN, "",
                               "the string \"dlopen\" appears; evidence is a string match, not confirmed");
    }
    /* No positive AND no negative evidence: 01-SPEC-audit.md §7.3's tier 4
     * ("Otherwise: OB0035 info, binary is stripped") is deliberately NOT
     * implemented as an unconditional fallback here. Tier 1 of that same
     * list needs a parsed SHT_SYMTAB (the STATIC symbol table — a
     * completely different thing from DT_SYMTAB, which elf/symbols.c
     * parses, and which Profile S binaries don't have by definition) to
     * tell "confirmed absent" apart from "stripped, can't tell". v0.1 does
     * not parse SHT_SYMTAB (02-REFERENCE-elf.md §1: section headers are an
     * optional bonus view), so this module cannot honestly distinguish
     * those two cases yet — and 03-TESTPLAN.md §4.3 #1 is explicit that a
     * clean static binary must produce NO findings at all, calling it "the
     * false-positive test that matters most". Emitting OB0035
     * unconditionally would violate that on every clean fixture this
     * project's own generator can produce. Documented in NOTES.md as a
     * deferred piece of #10 in that same section, pending SHT_SYMTAB
     * support. */

    if (!(ctx->dyn && ctx->dyn->nneeded > 0) &&
        (ev.has_nsswitch_string || ev.has_libnss_string || ev.has_nss_module_string)) {
        ob_report_add_finding(r, "OB0034", "profile.staticglibc", OB_SEV_ERROR, "",
                               "evidence of statically linked glibc NSS (breaks name/host lookups beyond the plain files backend)");
    }
}

static void check_profile_h(const ob_check_ctx *ctx, ob_report *r) {
    const ob_image *img = ctx->img;
    int interp_count = 0;
    const ob_phdr *interp = first_interp(img, &interp_count);

    if (!interp) {
        ob_report_add_finding(r, "OB0036", "profile.nointerp", OB_SEV_ERROR, "",
                               "no PT_INTERP in a file audited as Profile H");
        return;
    }
    if (interp_count > 1) {
        ob_report_add_finding(r, "OB0003", "elf.truncated", OB_SEV_INFO, "PT_INTERP",
                               "multiple PT_INTERP segments; using the first");
    }

    char path[ONEBIN_MAX_STRING + 1];
    if (ob_rdstr(&img->buf, (size_t)interp->p_offset, path, sizeof(path),
                 (size_t)interp->p_filesz) >= 0) {
        if (!is_known_interp(path)) {
            ob_report_add_finding(r, "OB0037", "profile.interp_unknown", OB_SEV_WARN,
                                   path, "not a recognised interpreter path for this machine");
        }
    }
}

/* Profile U is the static-PIE universal-host contract. It deliberately does
 * not reuse Profile S's dlopen finding: U binaries carry an explicit loader
 * and ABI bridge (SoLo in the first implementation), so loading a host
 * graphics closure is the feature being verified rather than a violation.
 * The audit can prove the ELF boundary here; the workflow's runtime smoke
 * test proves the carried loader reaches the host X11 stack. */
static void check_profile_u(const ob_check_ctx *ctx, ob_report *r) {
    const ob_image *img = ctx->img;
    int interp_count = 0;
    if (first_interp(img, &interp_count)) {
        ob_report_add_finding(r, "OB0030", "profile.interp", OB_SEV_ERROR, "",
                               "PT_INTERP present in a file audited as Profile U");
    }
    if (ctx->dyn && ctx->dyn->nneeded > 0) {
        ob_report_add_finding(r, "OB0031", "profile.needed", OB_SEV_ERROR, "",
                               "DT_NEEDED present in a file audited as Profile U");
    }
    if (img->e_type != ET_DYN) {
        ob_report_add_finding(r, "OB0032", "profile.nopie", OB_SEV_ERROR, "",
                               "Profile U requires an ET_DYN static-PIE image");
    }

    string_evidence ev;
    memset(&ev, 0, sizeof(ev));
    ob_strings_scan(&img->buf, evidence_cb, &ev);
    if (!(ctx->dyn && ctx->dyn->nneeded > 0) &&
        (ev.has_nsswitch_string || ev.has_libnss_string || ev.has_nss_module_string)) {
        ob_report_add_finding(r, "OB0034", "profile.staticglibc", OB_SEV_ERROR, "",
                               "evidence of statically linked glibc NSS in a Profile U image");
    }
}

static void check_profile_m(const ob_check_ctx *ctx, ob_report *r) {
    const ob_image *img = ctx->img;
    int interp_count = 0;
    if (first_interp(img, &interp_count)) {
        ob_report_add_finding(r, "OB0030", "profile.interp", OB_SEV_ERROR, "",
                               "PT_INTERP present in a file audited as a module — it is not a module");
        return;
    }

    char subject[ONEBIN_MAX_STRING + 1];
    subject[0] = '\0';
    if (ctx->dyn && ctx->dyn->has_soname) {
        ob_dynamic_string(img, ctx->dyn, ctx->dyn->soname_stroff, subject, sizeof(subject));
    }
    ob_report_add_finding(r, "OB0038", "profile.module", OB_SEV_INFO, subject,
                           "audited as a shared module; executable-only checks skipped");
}

void ob_check_profile(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx || !ctx->img || !r) {
        return;
    }
    if (ctx->profile_ambiguous && !ctx->profile_forced) {
        ob_report_add_finding(r, "OB0039", "profile.ambiguous", OB_SEV_INFO, "",
                               "indistinguishable from a static-PIE executable; pass --profile explicitly to be sure");
    }
    switch (ctx->profile) {
    case OB_PROFILE_S: check_profile_s(ctx, r); break;
    case OB_PROFILE_H: check_profile_h(ctx, r); break;
    case OB_PROFILE_M: check_profile_m(ctx, r); break;
    case OB_PROFILE_U: check_profile_u(ctx, r); break;
    }
}
