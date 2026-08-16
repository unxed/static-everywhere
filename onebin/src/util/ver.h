#ifndef UTIL_VER_H
#define UTIL_VER_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#define OB_VER_MAX_COMPONENTS 16
#define OB_VER_MAX_FAMILY 64

typedef struct {
    char     family[OB_VER_MAX_FAMILY];
    bool     is_numeric;
    size_t   ncomponents;
    uint32_t components[OB_VER_MAX_COMPONENTS];
    char     raw[128];
} ob_ver;

int ob_ver_parse(const char *str, ob_ver *out);
int ob_ver_parse_numeric(const char *str, ob_ver *out);
int ob_ver_cmp(const ob_ver *a, const ob_ver *b);

#endif /* UTIL_VER_H */
