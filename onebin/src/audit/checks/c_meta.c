/* audit/checks/c_meta.c — 01-SPEC-audit.md §7.8. 00-AGENT-TASK.md Task 8.
 *
 * The only check that touches the filesystem beyond the audited file
 * itself, and the only one that takes the file's path directly rather than
 * through ob_check_ctx — level-3-only, and there is nothing in an ob_image
 * that could answer "does a sibling file exist".
 */
#include "audit/checks.h"

#include <stdio.h>
#include <string.h>

static int sibling_exists(const char *file_path, const char *name) {
    const char *slash = strrchr(file_path, '/');
    char path[4096];
    if (slash) {
        size_t dirlen = (size_t)(slash - file_path) + 1; /* include the '/' */
        if (dirlen >= sizeof(path)) {
            return 0;
        }
        memcpy(path, file_path, dirlen);
        size_t namelen = strlen(name);
        if (dirlen + namelen >= sizeof(path)) {
            return 0;
        }
        memcpy(path + dirlen, name, namelen + 1);
    } else {
        if (strlen(name) >= sizeof(path)) {
            return 0;
        }
        memcpy(path, name, strlen(name) + 1);
    }

    FILE *f = fopen(path, "rb");
    if (!f) {
        return 0;
    }
    fclose(f);
    return 1;
}

void ob_check_meta(const ob_check_ctx *ctx, ob_report *r, const char *file_path) {
    if (!ctx || !r || !file_path) {
        return;
    }
    if (ctx->level != OB_LEVEL_3) {
        return;
    }
    if (sibling_exists(file_path, "sbom.cdx.json") || sibling_exists(file_path, "sbom.spdx.json")) {
        return;
    }
    ob_report_add_finding(r, "OB0080", "meta.sbom", OB_SEV_ERROR, "",
                           "--level 3 requires sbom.cdx.json or sbom.spdx.json next to the audited file");
}
