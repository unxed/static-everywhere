/* util/vec.h — growable array of fixed-size elements.
 *
 * Backs audit/finding.c's finding list and audit/baseline.c's fingerprint
 * list — two consumers as of Task 7, which is why this exists as a shared
 * module rather than two copies (rule 3: two copies drift).
 *
 * Stores elements BY VALUE (memcpy in/out), not pointers — every consumer
 * so far wants a flat array of small fixed-size structs, and that avoids a
 * second allocation per element.
 */
#ifndef UTIL_VEC_H
#define UTIL_VEC_H

#include <stddef.h>

typedef struct {
    void  *data;
    size_t count;
    size_t cap;
    size_t elemsz;
} ob_vec;

void ob_vec_init(ob_vec *v, size_t elemsz);
void ob_vec_free(ob_vec *v);

/* Appends one zeroed element and returns a pointer to it for the caller to
 * fill in, or NULL on allocation failure (the vector is left unchanged). */
void *ob_vec_push(ob_vec *v);

/* Returns a pointer to element `i`, or NULL if i >= v->count. */
void       *ob_vec_at(ob_vec *v, size_t i);
const void *ob_vec_at_const(const ob_vec *v, size_t i);

size_t ob_vec_count(const ob_vec *v);

/* In-place sort, same contract as qsort. */
void ob_vec_sort(ob_vec *v, int (*cmp)(const void *, const void *));

/* Removes element `i`, shifting everything after it down by one. */
void ob_vec_remove_at(ob_vec *v, size_t i);

#endif /* UTIL_VEC_H */
