#ifndef UTIL_BUF_H
#define UTIL_BUF_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    const uint8_t *p;      /* start of the whole file image */
    size_t         len;    /* bytes actually read */
    int            be;     /* 1 = big endian, 0 = little endian */
    int            c64;    /* 1 = ELFCLASS64, 0 = ELFCLASS32 */
} ob_buf;

int     ob_rd8   (const ob_buf *b, size_t off, uint8_t  *out);
int     ob_rd16  (const ob_buf *b, size_t off, uint16_t *out);
int     ob_rd32  (const ob_buf *b, size_t off, uint32_t *out);
int     ob_rd64  (const ob_buf *b, size_t off, uint64_t *out);
int     ob_rdaddr(const ob_buf *b, size_t off, uint64_t *out);
int     ob_range (const ob_buf *b, size_t off, size_t n);
ssize_t ob_rdstr (const ob_buf *b, size_t off, char *dst, size_t dstsz, size_t max);

#endif /* UTIL_BUF_H */
