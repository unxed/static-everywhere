#ifndef TEST_H
#define TEST_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include "onebin/audit.h"

typedef void (*test_fn_t)(void);

typedef struct test_case {
    const char *name;
    test_fn_t fn;
    const char *file;
    int line;
    struct test_case *next;
} test_case_t;

extern test_case_t *g_test_list_head;
extern test_case_t *g_test_list_tail;

void test_register(const char *name, test_fn_t fn, const char *file, int line);
void test_fail(const char *file, int line, const char *msg);
void test_skip(const char *file, int line, const char *msg);

#define TEST(name) \
    static void test_fn_##name(void); \
    __extension__ static void __attribute__((constructor)) register_test_##name(void) { \
        test_register(#name, test_fn_##name, __FILE__, __LINE__); \
    } \
    static void test_fn_##name(void)

#define ASSERT_TRUE(expr) do { \
    if (!(expr)) { \
        test_fail(__FILE__, __LINE__, "ASSERT_TRUE(" #expr ") failed"); \
        return; \
    } \
} while (0)

#define ASSERT_FALSE(expr) do { \
    if (expr) { \
        test_fail(__FILE__, __LINE__, "ASSERT_FALSE(" #expr ") failed"); \
        return; \
    } \
} while (0)

#define ASSERT_EQ_INT(actual, expected) do { \
    long long a_val = (long long)(actual); \
    long long e_val = (long long)(expected); \
    if (a_val != e_val) { \
        char buf[256]; \
        snprintf(buf, sizeof(buf), "ASSERT_EQ_INT(" #actual ", " #expected ") failed: %lld != %lld", a_val, e_val); \
        test_fail(__FILE__, __LINE__, buf); \
        return; \
    } \
} while (0)

#define ASSERT_EQ_U64(actual, expected) do { \
    uint64_t a_val = (uint64_t)(actual); \
    uint64_t e_val = (uint64_t)(expected); \
    if (a_val != e_val) { \
        char buf[256]; \
        snprintf(buf, sizeof(buf), "ASSERT_EQ_U64(" #actual ", " #expected ") failed: %llu != %llu", (unsigned long long)a_val, (unsigned long long)e_val); \
        test_fail(__FILE__, __LINE__, buf); \
        return; \
    } \
} while (0)

#define ASSERT_EQ_STR(actual, expected) do { \
    const char *a_str = (const char *)(actual); \
    const char *e_str = (const char *)(expected); \
    if (!a_str || !e_str || strcmp(a_str, e_str) != 0) { \
        char buf[512]; \
        snprintf(buf, sizeof(buf), "ASSERT_EQ_STR(" #actual ", " #expected ") failed: \"%s\" != \"%s\"", a_str ? a_str : "NULL", e_str ? e_str : "NULL"); \
        test_fail(__FILE__, __LINE__, buf); \
        return; \
    } \
} while (0)

#define ASSERT_EQ_MEM(actual, expected, len) do { \
    const unsigned char *a_mem = (const unsigned char *)(actual); \
    const unsigned char *e_mem = (const unsigned char *)(expected); \
    size_t n_len = (size_t)(len); \
    if (memcmp(a_mem, e_mem, n_len) != 0) { \
        test_fail(__FILE__, __LINE__, "ASSERT_EQ_MEM(" #actual ", " #expected ", " #len ") memory mismatch"); \
        return; \
    } \
} while (0)

#define ASSERT_NULL(p) do { \
    if ((p) != NULL) { \
        test_fail(__FILE__, __LINE__, "ASSERT_NULL(" #p ") failed: expected NULL"); \
        return; \
    } \
} while (0)

#define ASSERT_NOT_NULL(p) do { \
    if ((p) == NULL) { \
        test_fail(__FILE__, __LINE__, "ASSERT_NOT_NULL(" #p ") failed: expected non-NULL"); \
        return; \
    } \
} while (0)

#define ASSERT_OK(call) do { \
    int res = (call); \
    if (res != 0) { \
        char buf[256]; \
        snprintf(buf, sizeof(buf), "ASSERT_OK(" #call ") failed with code %d", res); \
        test_fail(__FILE__, __LINE__, buf); \
        return; \
    } \
} while (0)

#define ASSERT_ERR(call) do { \
    int res = (call); \
    if (res == 0) { \
        test_fail(__FILE__, __LINE__, "ASSERT_ERR(" #call ") expected error but succeeded"); \
        return; \
    } \
} while (0)

#define SKIP(reason) do { \
    test_skip(__FILE__, __LINE__, (reason)); \
    return; \
} while (0)

int test_runner_main(int argc, char **argv);

#endif /* TEST_H */
