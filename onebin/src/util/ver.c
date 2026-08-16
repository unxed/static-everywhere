#include <string.h>
#include "util/ver.h"

static bool parse_numeric_rest(const char *rest, ob_ver *out) {
    if (!rest || *rest == '\0' || *rest == '.') {
        return false;
    }

    size_t comp_count = 0;
    uint32_t comps[OB_VER_MAX_COMPONENTS];
    size_t group_len = 0;
    uint64_t group_val = 0;

    const char *p = rest;
    while (*p != '\0') {
        if (*p == '.') {
            if (group_len == 0 || group_len > 9) {
                return false;
            }
            if (comp_count >= OB_VER_MAX_COMPONENTS) {
                return false;
            }
            comps[comp_count++] = (uint32_t)group_val;
            group_len = 0;
            group_val = 0;
            if (*(p + 1) == '\0') {
                return false;
            }
        } else if (*p >= '0' && *p <= '9') {
            group_len++;
            if (group_len > 9) {
                return false;
            }
            group_val = group_val * 10 + (uint64_t)(*p - '0');
        } else {
            return false;
        }
        p++;
    }

    if (group_len == 0 || group_len > 9) {
        return false;
    }
    if (comp_count >= OB_VER_MAX_COMPONENTS) {
        return false;
    }
    comps[comp_count++] = (uint32_t)group_val;

    out->ncomponents = comp_count;
    for (size_t i = 0; i < comp_count; i++) {
        out->components[i] = comps[i];
    }
    return true;
}

int ob_ver_parse(const char *str, ob_ver *out) {
    if (!str || !out) {
        return -1;
    }

    out->is_numeric = false;
    out->ncomponents = 0;
    out->family[0] = '\0';
    out->raw[0] = '\0';

    size_t raw_len = strlen(str);
    size_t copy_len = raw_len < sizeof(out->raw) - 1 ? raw_len : sizeof(out->raw) - 1;
    for (size_t i = 0; i < copy_len; i++) {
        out->raw[i] = str[i];
    }
    out->raw[copy_len] = '\0';

    const char *underscore = strchr(str, '_');
    if (!underscore) {
        size_t flen = raw_len < sizeof(out->family) - 1 ? raw_len : sizeof(out->family) - 1;
        for (size_t i = 0; i < flen; i++) {
            out->family[i] = str[i];
        }
        out->family[flen] = '\0';
        return 0;
    }

    size_t fam_len = (size_t)(underscore - str);
    size_t flen = fam_len < sizeof(out->family) - 1 ? fam_len : sizeof(out->family) - 1;
    for (size_t i = 0; i < flen; i++) {
        out->family[i] = str[i];
    }
    out->family[flen] = '\0';

    const char *rest = underscore + 1;
    if (parse_numeric_rest(rest, out)) {
        out->is_numeric = true;
    }

    return 0;
}

int ob_ver_parse_numeric(const char *str, ob_ver *out) {
    if (!str || !out) {
        return -1;
    }

    out->is_numeric = false;
    out->ncomponents = 0;
    out->family[0] = '\0';
    out->raw[0] = '\0';

    size_t raw_len = strlen(str);
    size_t copy_len = raw_len < sizeof(out->raw) - 1 ? raw_len : sizeof(out->raw) - 1;
    for (size_t i = 0; i < copy_len; i++) {
        out->raw[i] = str[i];
    }
    out->raw[copy_len] = '\0';

    if (parse_numeric_rest(str, out)) {
        out->is_numeric = true;
        return 0;
    }

    return -1;
}

int ob_ver_cmp(const ob_ver *a, const ob_ver *b) {
    if (!a || !b) {
        return 0;
    }

    size_t max_comp = a->ncomponents > b->ncomponents ? a->ncomponents : b->ncomponents;
    for (size_t i = 0; i < max_comp; i++) {
        uint32_t val_a = (i < a->ncomponents) ? a->components[i] : 0;
        uint32_t val_b = (i < b->ncomponents) ? b->components[i] : 0;
        if (val_a < val_b) {
            return -1;
        }
        if (val_a > val_b) {
            return 1;
        }
    }

    return 0;
}
