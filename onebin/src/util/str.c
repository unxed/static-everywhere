/* util/str.c — see util/str.h. */
#include "util/str.h"

#include <stdio.h>
#include <string.h>

int ob_str_sanitize(const char *src, char *dst, size_t dstsz) {
    if (dst && dstsz > 0) {
        dst[0] = '\0';
    }
    if (!dst || dstsz == 0) {
        return 0;
    }
    if (!src) {
        return 0;
    }

    /* Bounded working buffer: sanitisation itself must never do unbounded
     * work, regardless of how long `src` is. OB_STR_MAXLEN is the final cap
     * anyway, so there is nothing to gain from scanning further than a
     * generous margin past it. */
    char work[OB_STR_MAXLEN + 32];
    size_t n = 0;
    int changed = 0;
    for (; src[n] != '\0' && n < sizeof(work) - 1; n++) {
        unsigned char c = (unsigned char)src[n];
        if (c < 0x20 || c > 0x7E) {
            work[n] = '?';
            changed = 1;
        } else {
            work[n] = (char)c;
        }
    }
    work[n] = '\0';

    char marked[sizeof(work) + 16];
    if (changed) {
        snprintf(marked, sizeof(marked), "%s [sanitised]", work);
    } else {
        snprintf(marked, sizeof(marked), "%s", work);
    }

    size_t total = strlen(marked);
    if (total <= OB_STR_MAXLEN) {
        size_t copy = (total < dstsz - 1) ? total : dstsz - 1;
        memcpy(dst, marked, copy);
        dst[copy] = '\0';
        return changed;
    }

    /* Truncate to OB_STR_MAXLEN bytes total, the last 3 replaced by "...". */
    size_t keep = OB_STR_MAXLEN - 3;
    size_t copy = (keep < dstsz - 1) ? keep : dstsz - 1;
    memcpy(dst, marked, copy);
    dst[copy] = '\0';
    if (dstsz - strlen(dst) > 3) {
        strcat(dst, "...");
    }
    return changed;
}
