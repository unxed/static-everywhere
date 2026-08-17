/* audit/checks_common.c — see audit/checks.h. */
#include "audit/checks.h"
#include "elf/elf_const.h"

void ob_checks_resolve_profile(ob_check_ctx *ctx) {
    if (!ctx || !ctx->img) {
        return;
    }
    if (ctx->profile_forced) {
        ctx->profile_ambiguous = 0;
        return; /* "--profile overrides all of it" */
    }

    int has_pt_interp = 0;
    for (size_t i = 0; i < ctx->img->nphdrs; i++) {
        if (ctx->img->phdrs[i].p_type == PT_INTERP) {
            has_pt_interp = 1;
            break;
        }
    }

    int df1_pie_set = 0;
    int has_soname = 0;
    int has_needed = 0;
    if (ctx->dyn) {
        df1_pie_set = (ctx->dyn->flags_1 & DF_1_PIE) != 0;
        has_soname = ctx->dyn->has_soname;
        has_needed = ctx->dyn->nneeded > 0;
    }

    int et_dyn = (ctx->img->e_type == ET_DYN);

    int ambiguous = 0;
    ctx->profile = ob_profile_detect(has_pt_interp, df1_pie_set, et_dyn,
                                      has_soname, has_needed, &ambiguous);
    ctx->profile_ambiguous = ambiguous;
}
