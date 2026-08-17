/* elf/strings.c — see elf/strings.h. */
#include "elf/strings.h"
#include "util/limits.h"

static int is_strchar(uint8_t c) {
    return c >= 0x20 && c <= 0x7E;
}

void ob_strings_scan(const ob_buf *buf, ob_strings_cb cb, void *user) {
    if (!buf || !buf->p || !cb) {
        return;
    }
    size_t i = 0;
    while (i < buf->len) {
        if (!is_strchar(buf->p[i])) {
            i++;
            continue;
        }
        size_t start = i;
        while (i < buf->len && is_strchar(buf->p[i]) &&
               (i - start) < ONEBIN_MAX_STRING) {
            i++;
        }
        size_t runlen = i - start;
        if (runlen >= 4) {
            cb((const char *)&buf->p[start], runlen, start, user);
        }
        /* If the run was cut short only by the ONEBIN_MAX_STRING cap (not
         * by an out-of-range byte or EOF), the outer loop resumes scanning
         * printable bytes right where we stopped, naturally splitting the
         * remainder into further callbacks -- no special-casing needed. */
    }
}
