/* t_checks_meta.c — audit/checks/c_meta.c. 01-SPEC-audit.md §7.8. */
#define _POSIX_C_SOURCE 200809L
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/elf_const.h"
#include "audit/checks.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int has_id(const ob_report *r, const char *id) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ob_finding_list_at(&r->findings, i)->id, id) == 0) return 1;
    }
    return 0;
}

TEST(meta_level3_no_sbom_errors) {
    char dir[] = "/tmp/onebin_t_meta_XXXXXX";
    ASSERT_NOT_NULL(mkdtemp(dir));
    char path[256];
    snprintf(path, sizeof(path), "%s/bin.elf", dir);

    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.level = OB_LEVEL_3;
    ob_report r;
    ob_report_init(&r);
    ob_check_meta(&ctx, &r, path);

    ASSERT_TRUE(has_id(&r, "OB0080"));

    ob_report_free(&r);
    rmdir(dir);
}

TEST(meta_level3_with_cdx_sbom_passes) {
    char dir[] = "/tmp/onebin_t_meta_XXXXXX";
    ASSERT_NOT_NULL(mkdtemp(dir));
    char path[256], sbom[256];
    snprintf(path, sizeof(path), "%s/bin.elf", dir);
    snprintf(sbom, sizeof(sbom), "%s/sbom.cdx.json", dir);
    FILE *f = fopen(sbom, "w");
    ASSERT_NOT_NULL(f);
    fputs("{}", f);
    fclose(f);

    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.level = OB_LEVEL_3;
    ob_report r;
    ob_report_init(&r);
    ob_check_meta(&ctx, &r, path);

    ASSERT_FALSE(has_id(&r, "OB0080"));

    ob_report_free(&r);
    unlink(sbom); rmdir(dir);
}

TEST(meta_level3_with_spdx_sbom_passes) {
    char dir[] = "/tmp/onebin_t_meta_XXXXXX";
    ASSERT_NOT_NULL(mkdtemp(dir));
    char path[256], sbom[256];
    snprintf(path, sizeof(path), "%s/bin.elf", dir);
    snprintf(sbom, sizeof(sbom), "%s/sbom.spdx.json", dir);
    FILE *f = fopen(sbom, "w");
    ASSERT_NOT_NULL(f);
    fputs("{}", f);
    fclose(f);

    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.level = OB_LEVEL_3;
    ob_report r;
    ob_report_init(&r);
    ob_check_meta(&ctx, &r, path);

    ASSERT_FALSE(has_id(&r, "OB0080"));

    ob_report_free(&r);
    unlink(sbom); rmdir(dir);
}

TEST(meta_level1_never_checks_sbom) {
    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.level = OB_LEVEL_1;
    ob_report r;
    ob_report_init(&r);
    ob_check_meta(&ctx, &r, "/tmp/onebin_t_meta_nonexistent_dir_xyz/bin.elf");

    ASSERT_EQ_INT(ob_finding_list_count(&r.findings), 0);

    ob_report_free(&r);
}
