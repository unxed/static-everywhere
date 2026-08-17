/* audit/checks/c_rpath.c — 01-SPEC-audit.md §7.4. 00-AGENT-TASK.md Task 8. */
#include "audit/checks.h"
#include "util/str.h"
#include "util/limits.h"

#include <stdio.h>
#include <string.h>

/* $ORIGIN must be followed by '/', ':', or end of string — a prefix match
 * alone would wrongly accept "$ORIGINAL/lib" (03-TESTPLAN.md §4.4 #12,
 * flagged there as "the one you will get wrong"). Colons never actually
 * reach here (the caller already split on them), but the check stays for
 * fidelity to the rule as stated. */
static int is_origin_prefixed(const char *comp) {
    static const char p1[] = "$ORIGIN";
    static const char p2[] = "${ORIGIN}";
    size_t l1 = sizeof(p1) - 1, l2 = sizeof(p2) - 1;

    if (strncmp(comp, p1, l1) == 0) {
        char c = comp[l1];
        if (c == '\0' || c == '/' || c == ':') {
            return 1;
        }
    }
    if (strncmp(comp, p2, l2) == 0) {
        char c = comp[l2];
        if (c == '\0' || c == '/' || c == ':') {
            return 1;
        }
    }
    return 0;
}

/* `value` is the whole colon-separated DT_RPATH/DT_RUNPATH string, already
 * sanitised-on-output by ob_report_add_finding — this function only splits
 * and classifies. `tag` names which tag it came from, for OB0043's
 * subject; case 8/9/10's empty-component check needs no reference to the
 * individual component, since there is nothing there to name. */
static void check_pathlist(ob_report *r, const char *value, const char *tag) {
    size_t len = strlen(value);
    size_t start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i != len && value[i] != ':') {
            continue;
        }
        size_t complen = i - start;
        if (complen == 0) {
            char subj[64];
            snprintf(subj, sizeof(subj), "%s", tag);
            ob_report_add_finding(r, "OB0043", "rpath.empty_component", OB_SEV_ERROR, subj,
                                   "empty path component means \"current directory\"");
        } else {
            char comp[ONEBIN_MAX_STRING + 1];
            size_t n = complen < sizeof(comp) - 1 ? complen : sizeof(comp) - 1;
            memcpy(comp, value + start, n);
            comp[n] = '\0';
            if (is_origin_prefixed(comp)) {
                ob_report_add_finding(r, "OB0041", "rpath.origin", OB_SEV_WARN, comp,
                                       "search path is $ORIGIN-relative");
            } else {
                ob_report_add_finding(r, "OB0040", "rpath.absolute", OB_SEV_ERROR, comp,
                                       "search path component is not $ORIGIN-relative");
            }
        }
        start = i + 1;
    }
}

void ob_check_rpath(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx || !ctx->img || !ctx->dyn || !r) {
        return;
    }
    const ob_dynamic *dyn = ctx->dyn;

    if (dyn->has_rpath) {
        ob_report_add_finding(r, "OB0042", "rpath.rpath_present", OB_SEV_WARN, "",
                               "DT_RPATH is ignored by the loader when DT_RUNPATH is also present, "
                               "and cannot be overridden by LD_LIBRARY_PATH");
        char val[ONEBIN_MAX_STRING + 1];
        if (ob_dynamic_string(ctx->img, dyn, dyn->rpath_stroff, val, sizeof(val)) == OB_STR_OK) {
            check_pathlist(r, val, "DT_RPATH");
        }
    }
    if (dyn->has_runpath) {
        char val[ONEBIN_MAX_STRING + 1];
        if (ob_dynamic_string(ctx->img, dyn, dyn->runpath_stroff, val, sizeof(val)) == OB_STR_OK) {
            check_pathlist(r, val, "DT_RUNPATH");
        }
    }
}
