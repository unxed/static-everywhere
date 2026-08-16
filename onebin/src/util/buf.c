#include "util/buf.h"

int ob_range(const ob_buf *b, size_t off, size_t n) {
    if (!b) {
        return -1;
    }
    if (off > b->len || n > b->len - off) {
        return -1;
    }
    return 0;
}

int ob_rd8(const ob_buf *b, size_t off, uint8_t *out) {
    if (!out || ob_range(b, off, 1) != 0) {
        return -1;
    }
    *out = b->p[off];
    return 0;
}

int ob_rd16(const ob_buf *b, size_t off, uint16_t *out) {
    if (!out || ob_range(b, off, 2) != 0) {
        return -1;
    }
    uint16_t b0 = (uint16_t)b->p[off];
    uint16_t b1 = (uint16_t)b->p[off + 1];
    if (b->be) {
        *out = (uint16_t)((b0 << 8) | b1);
    } else {
        *out = (uint16_t)((b1 << 8) | b0);
    }
    return 0;
}

int ob_rd32(const ob_buf *b, size_t off, uint32_t *out) {
    if (!out || ob_range(b, off, 4) != 0) {
        return -1;
    }
    uint32_t b0 = (uint32_t)b->p[off];
    uint32_t b1 = (uint32_t)b->p[off + 1];
    uint32_t b2 = (uint32_t)b->p[off + 2];
    uint32_t b3 = (uint32_t)b->p[off + 3];
    if (b->be) {
        *out = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    } else {
        *out = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
    }
    return 0;
}

int ob_rd64(const ob_buf *b, size_t off, uint64_t *out) {
    if (!out || ob_range(b, off, 8) != 0) {
        return -1;
    }
    uint64_t b0 = (uint64_t)b->p[off];
    uint64_t b1 = (uint64_t)b->p[off + 1];
    uint64_t b2 = (uint64_t)b->p[off + 2];
    uint64_t b3 = (uint64_t)b->p[off + 3];
    uint64_t b4 = (uint64_t)b->p[off + 4];
    uint64_t b5 = (uint64_t)b->p[off + 5];
    uint64_t b6 = (uint64_t)b->p[off + 6];
    uint64_t b7 = (uint64_t)b->p[off + 7];
    if (b->be) {
        *out = (b0 << 56) | (b1 << 48) | (b2 << 40) | (b3 << 32) |
               (b4 << 24) | (b5 << 16) | (b6 << 8)  | b7;
    } else {
        *out = (b7 << 56) | (b6 << 48) | (b5 << 40) | (b4 << 32) |
               (b3 << 24) | (b2 << 16) | (b1 << 8)  | b0;
    }
    return 0;
}

int ob_rdaddr(const ob_buf *b, size_t off, uint64_t *out) {
    if (!b || !out) {
        return -1;
    }
    if (b->c64) {
        return ob_rd64(b, off, out);
    }
    uint32_t val32 = 0;
    if (ob_rd32(b, off, &val32) != 0) {
        return -1;
    }
    *out = (uint64_t)val32;
    return 0;
}

ssize_t ob_rdstr(const ob_buf *b, size_t off, char *dst, size_t dstsz, size_t max) {
    if (dst && dstsz > 0) {
        dst[0] = '\0';
    }
    if (!b || !dst || dstsz == 0) {
        return -1;
    }
    if (off >= b->len) {
        return -1;
    }

    size_t limit = b->len - off;
    if (max < limit) {
        limit = max;
    }

    size_t slen = 0;
    int found_nul = 0;
    for (size_t i = 0; i < limit; i++) {
        if (b->p[off + i] == 0) {
            slen = i;
            found_nul = 1;
            break;
        }
    }

    if (!found_nul) {
        return -1;
    }

    if (slen + 1 > dstsz) {
        return -1;
    }

    for (size_t i = 0; i < slen; i++) {
        dst[i] = (char)b->p[off + i];
    }
    dst[slen] = '\0';

    return (ssize_t)slen;
}
