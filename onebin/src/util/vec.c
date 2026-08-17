/* util/vec.c — see util/vec.h. */
#include "util/vec.h"

#include <stdlib.h>
#include <string.h>

void ob_vec_init(ob_vec *v, size_t elemsz) {
    v->data = NULL;
    v->count = 0;
    v->cap = 0;
    v->elemsz = elemsz;
}

void ob_vec_free(ob_vec *v) {
    free(v->data);
    v->data = NULL;
    v->count = 0;
    v->cap = 0;
}

void *ob_vec_push(ob_vec *v) {
    if (v->count == v->cap) {
        size_t newcap = v->cap ? v->cap * 2 : 16;
        void *p = realloc(v->data, newcap * v->elemsz);
        if (!p) {
            return NULL;
        }
        v->data = p;
        v->cap = newcap;
    }
    unsigned char *slot = (unsigned char *)v->data + v->count * v->elemsz;
    memset(slot, 0, v->elemsz);
    v->count++;
    return slot;
}

void *ob_vec_at(ob_vec *v, size_t i) {
    if (!v || i >= v->count) {
        return NULL;
    }
    return (unsigned char *)v->data + i * v->elemsz;
}

const void *ob_vec_at_const(const ob_vec *v, size_t i) {
    if (!v || i >= v->count) {
        return NULL;
    }
    return (const unsigned char *)v->data + i * v->elemsz;
}

size_t ob_vec_count(const ob_vec *v) {
    return v ? v->count : 0;
}

void ob_vec_sort(ob_vec *v, int (*cmp)(const void *, const void *)) {
    if (v && v->data && v->count > 1) {
        qsort(v->data, v->count, v->elemsz, cmp);
    }
}

void ob_vec_remove_at(ob_vec *v, size_t i) {
    if (!v || i >= v->count) {
        return;
    }
    unsigned char *base = (unsigned char *)v->data;
    if (i + 1 < v->count) {
        memmove(base + i * v->elemsz, base + (i + 1) * v->elemsz,
                (v->count - i - 1) * v->elemsz);
    }
    v->count--;
}
