/* audit/checks/c_glibc.c — 01-SPEC-audit.md §7.2. 00-AGENT-TASK.md Task 8.
 *
 * Two independent computations share this file:
 *   - the highest required GLIBC_x.y, from the verneed walk alone (OB0020,
 *     OB0022, OB0023, OB0024) — never needs the symbol table at all;
 *   - which specific symbols pulled in that requirement (OB0021), which
 *     does need DT_VERSYM cross-referenced against dynsym (§6.4), and is
 *     the only reason OB0025 ("symbol count unknown") exists.
 */
#include "audit/checks.h"
#include "util/str.h"
#include "util/ver.h"
#include "elf/elf_const.h"

#include <stdio.h>
#include <string.h>

#define OB0021_CAP 20

typedef struct {
    ob_ver highest;
    int    have_highest;
    int    saw_abi_dt_relr;
} verneed_summary;

static void summarize_verneed(const ob_check_ctx *ctx, ob_report *r, verneed_summary *sum) {
    memset(sum, 0, sizeof(*sum));
    if (!ctx->verneed) {
        return;
    }
    for (size_t i = 0; i < ctx->verneed->nreqs; i++) {
        const ob_verneed_req *req = &ctx->verneed->reqs[i];
        char version[OB_STR_MAXLEN + 1];
        if (ob_dynamic_string(ctx->img, ctx->dyn, req->vna_name_stroff, version, sizeof(version)) != OB_STR_OK) {
            continue;
        }

        ob_ver v;
        ob_ver_parse(version, &v);

        if (strcmp(v.family, "GLIBC") != 0) {
            char file[OB_STR_MAXLEN + 1] = { 0 };
            ob_dynamic_string(ctx->img, ctx->dyn, req->vn_file_stroff, file, sizeof(file));
            char msg[OB_STR_MAXLEN + 96];
            snprintf(msg, sizeof(msg),
                     "non-glibc versioned symbol from %s; the library providing it should usually be static too",
                     file[0] ? file : "an unknown library");
            ob_report_add_finding(r, "OB0023", "glibc.foreign_version", OB_SEV_WARN, version, msg);
            continue;
        }

        if (strcmp(version, "GLIBC_PRIVATE") == 0) {
            ob_report_add_finding(r, "OB0024", "glibc.private", OB_SEV_ERROR, version,
                                   "GLIBC_PRIVATE is never legitimate in a redistributable binary; it pins the exact glibc build");
            continue;
        }
        if (strcmp(version, "GLIBC_ABI_DT_RELR") == 0) {
            sum->saw_abi_dt_relr = 1;
            continue;
        }
        if (!v.is_numeric) {
            continue; /* an unrecognised non-numeric GLIBC_* tag: not one of
                       * the cases §7.2 names, so no finding — nothing to
                       * safely say about it */
        }

        if (!sum->have_highest || ob_ver_cmp(&v, &sum->highest) > 0) {
            sum->highest = v;
            sum->have_highest = 1;
        }
    }

    if (sum->saw_abi_dt_relr) {
        ob_report_add_finding(r, "OB0022", "glibc.abi_dt_relr", OB_SEV_WARN, "GLIBC_ABI_DT_RELR",
                               "requires GLIBC_ABI_DT_RELR (RELR relocations); needs a glibc new enough to support it");
    }
}

/* DT_VERSYM: one Elf*_Half per dynsym entry, at ob_image_vaddr_to_offset(
 * dyn->versym_vaddr) + index * 2. Not owned by elf/symbols.c (which only
 * knows about .dynsym itself) or elf/verneed.c (which never needs to know
 * which symbol asked for which version) — this cross-reference is specific
 * to this one check, so it lives here rather than in the elf/ layer. */
static int read_versym(const ob_image *img, const ob_dynamic *dyn, size_t index, uint16_t *out) {
    if (!dyn->has_versym) {
        return -1;
    }
    uint64_t base = ob_image_vaddr_to_offset(img, dyn->versym_vaddr);
    if (base == OB_NOT_MAPPED || base > (uint64_t)SIZE_MAX) {
        return -1;
    }
    uint64_t off64 = base + (uint64_t)index * 2u;
    if (off64 < base || off64 > (uint64_t)SIZE_MAX) {
        return -1;
    }
    return ob_rd16(&img->buf, (size_t)off64, out);
}

static void attribute_symbols(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx->syms || !ctx->syms->count_known) {
        ob_report_add_finding(r, "OB0025", "glibc.symcount_unknown", OB_SEV_INFO, "",
                               "dynamic symbol count could not be determined; per-symbol glibc version attribution skipped");
        return;
    }
    if (!ctx->verneed || ctx->verneed->nreqs == 0 || !ctx->dyn->has_versym) {
        return; /* nothing to attribute to */
    }

    ob_ver max_ver;
    if (ctx->glibc_max) {
        if (ob_ver_parse_numeric(ctx->glibc_max, &max_ver) != 0) {
            return;
        }
    } else {
        ob_ver_parse_numeric(OB_DEFAULT_GLIBC_MAX, &max_ver);
    }

    size_t reported = 0, total_offending = 0;
    for (size_t i = 0; i < ctx->syms->count; i++) {
        uint16_t versym = 0;
        if (read_versym(ctx->img, ctx->dyn, i, &versym) != 0) {
            continue;
        }
        uint16_t ndx = versym & 0x7FFFu; /* mask off VER_NDX_HIDDEN */
        if (ndx == VER_NDX_LOCAL || ndx == VER_NDX_GLOBAL) {
            continue;
        }

        const char *version_str = NULL;
        char version_buf[OB_STR_MAXLEN + 1];
        for (size_t j = 0; j < ctx->verneed->nreqs; j++) {
            if (ctx->verneed->reqs[j].vna_other == ndx) {
                if (ob_dynamic_string(ctx->img, ctx->dyn, ctx->verneed->reqs[j].vna_name_stroff,
                                       version_buf, sizeof(version_buf)) == OB_STR_OK) {
                    version_str = version_buf;
                }
                break;
            }
        }
        if (!version_str) {
            continue;
        }
        ob_ver v;
        ob_ver_parse(version_str, &v);
        if (strcmp(v.family, "GLIBC") != 0 || !v.is_numeric) {
            continue;
        }
        if (ob_ver_cmp(&v, &max_ver) <= 0) {
            continue;
        }

        total_offending++;
        if (reported >= OB0021_CAP) {
            continue;
        }

        ob_sym_entry se;
        if (ob_symbols_at(ctx->img, ctx->dyn, ctx->syms, i, &se) != 0) {
            continue;
        }
        char symname[OB_STR_MAXLEN + 1];
        if (ob_dynamic_string(ctx->img, ctx->dyn, se.st_name, symname, sizeof(symname)) != OB_STR_OK) {
            continue;
        }

        char subject[2 * (OB_STR_MAXLEN + 1) + 1];
        snprintf(subject, sizeof(subject), "%s@%s", symname, version_str);
        ob_report_add_finding(r, "OB0021", "glibc.offending_symbol", OB_SEV_INFO, subject, "");
        reported++;
    }

    if (total_offending > OB0021_CAP) {
        char msg[96];
        snprintf(msg, sizeof(msg), "%zu offending symbols total; showing the first %d",
                 total_offending, OB0021_CAP);
        ob_report_add_finding(r, "OB0021", "glibc.offending_symbol", OB_SEV_INFO, "", msg);
    }
}

void ob_check_glibc(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx || !ctx->img || !ctx->dyn || !r) {
        return;
    }

    verneed_summary sum;
    summarize_verneed(ctx, r, &sum);

    if (sum.have_highest) {
        ob_ver max_ver;
        int have_max = (ctx->glibc_max ? ob_ver_parse_numeric(ctx->glibc_max, &max_ver)
                                        : ob_ver_parse_numeric(OB_DEFAULT_GLIBC_MAX, &max_ver)) == 0;
        if (have_max && ob_ver_cmp(&sum.highest, &max_ver) > 0) {
            char msg[320];
            snprintf(msg, sizeof(msg), "requires %s, which is newer than the configured maximum %s",
                     sum.highest.raw, max_ver.raw);
            ob_report_add_finding(r, "OB0020", "glibc.max_exceeded", OB_SEV_ERROR, "", msg);
        }
    }

    attribute_symbols(ctx, r);
}
