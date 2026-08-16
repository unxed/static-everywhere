#include "test.h"
#include "util/ver.h"

TEST(ver_spec_table_cases) {
    ob_ver v;

    /* GLIBC_2.2.5 */
    ASSERT_OK(ob_ver_parse("GLIBC_2.2.5", &v));
    ASSERT_EQ_STR(v.family, "GLIBC");
    ASSERT_TRUE(v.is_numeric);
    ASSERT_EQ_U64(v.ncomponents, 3);
    ASSERT_EQ_U64(v.components[0], 2);
    ASSERT_EQ_U64(v.components[1], 2);
    ASSERT_EQ_U64(v.components[2], 5);

    /* GLIBC_2.9 vs GLIBC_2.10 */
    ob_ver v29, v210;
    ASSERT_OK(ob_ver_parse("GLIBC_2.9", &v29));
    ASSERT_OK(ob_ver_parse("GLIBC_2.10", &v210));
    ASSERT_TRUE(v29.is_numeric);
    ASSERT_TRUE(v210.is_numeric);
    ASSERT_EQ_INT(ob_ver_cmp(&v29, &v210), -1);
    ASSERT_EQ_INT(ob_ver_cmp(&v210, &v29), 1);

    /* GLIBC_2.28 & GLIBC_2.34 */
    ASSERT_OK(ob_ver_parse("GLIBC_2.28", &v));
    ASSERT_TRUE(v.is_numeric);
    ASSERT_EQ_U64(v.components[1], 28);
    ASSERT_OK(ob_ver_parse("GLIBC_2.34", &v));
    ASSERT_TRUE(v.is_numeric);
    ASSERT_EQ_U64(v.components[1], 34);

    /* Non-numeric GLIBC requirements */
    ASSERT_OK(ob_ver_parse("GLIBC_PRIVATE", &v));
    ASSERT_EQ_STR(v.family, "GLIBC");
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GLIBC_ABI_DT_RELR", &v));
    ASSERT_EQ_STR(v.family, "GLIBC");
    ASSERT_FALSE(v.is_numeric);

    /* Other libraries */
    ASSERT_OK(ob_ver_parse("GLIBCXX_3.4.29", &v));
    ASSERT_EQ_STR(v.family, "GLIBCXX");
    ASSERT_TRUE(v.is_numeric);
    ASSERT_EQ_U64(v.ncomponents, 3);

    ASSERT_OK(ob_ver_parse("CXXABI_1.3.9", &v));
    ASSERT_EQ_STR(v.family, "CXXABI");
    ASSERT_TRUE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GCC_3.0", &v));
    ASSERT_EQ_STR(v.family, "GCC");
    ASSERT_TRUE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GCC_4.2.0", &v));
    ASSERT_EQ_STR(v.family, "GCC");
    ASSERT_TRUE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("LIBXML2_2.6.0", &v));
    ASSERT_EQ_STR(v.family, "LIBXML2");
    ASSERT_TRUE(v.is_numeric);

    /* Degenerate but valid: empty family */
    ASSERT_OK(ob_ver_parse("_2.0", &v));
    ASSERT_EQ_STR(v.family, "");
    ASSERT_TRUE(v.is_numeric);
    ASSERT_EQ_U64(v.components[0], 2);
    ASSERT_EQ_U64(v.components[1], 0);

    /* Non-numeric / malformed cases */
    ASSERT_OK(ob_ver_parse("GLIBC_", &v));
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GLIBC_2.", &v));
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GLIBC_.2", &v));
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GLIBC_2..3", &v));
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GLIBC_2.1a", &v));
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("GLIBC_9999999999.1", &v));
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("", &v));
    ASSERT_EQ_STR(v.family, "");
    ASSERT_FALSE(v.is_numeric);

    ASSERT_OK(ob_ver_parse("NOUNDERSCORE", &v));
    ASSERT_EQ_STR(v.family, "NOUNDERSCORE");
    ASSERT_FALSE(v.is_numeric);
}

TEST(ver_comparator_direct) {
    ob_ver a, b;

    /* (2.2.5, 2.3) -> -1 */
    ASSERT_OK(ob_ver_parse_numeric("2.2.5", &a));
    ASSERT_OK(ob_ver_parse_numeric("2.3", &b));
    ASSERT_EQ_INT(ob_ver_cmp(&a, &b), -1);

    /* (2.9, 2.10) -> -1 */
    ASSERT_OK(ob_ver_parse_numeric("2.9", &a));
    ASSERT_OK(ob_ver_parse_numeric("2.10", &b));
    ASSERT_EQ_INT(ob_ver_cmp(&a, &b), -1);

    /* (2.28, 2.28) -> 0 */
    ASSERT_OK(ob_ver_parse_numeric("2.28", &a));
    ASSERT_OK(ob_ver_parse_numeric("2.28", &b));
    ASSERT_EQ_INT(ob_ver_cmp(&a, &b), 0);

    /* (2.28.1, 2.28) -> +1 */
    ASSERT_OK(ob_ver_parse_numeric("2.28.1", &a));
    ASSERT_OK(ob_ver_parse_numeric("2.28", &b));
    ASSERT_EQ_INT(ob_ver_cmp(&a, &b), 1);

    /* (2, 2.0) -> 0 */
    ASSERT_OK(ob_ver_parse_numeric("2", &a));
    ASSERT_OK(ob_ver_parse_numeric("2.0", &b));
    ASSERT_EQ_INT(ob_ver_cmp(&a, &b), 0);

    /* (3, 2.99) -> +1 */
    ASSERT_OK(ob_ver_parse_numeric("3", &a));
    ASSERT_OK(ob_ver_parse_numeric("2.99", &b));
    ASSERT_EQ_INT(ob_ver_cmp(&a, &b), 1);
}

TEST(ver_null_and_boundary_checks) {
    ob_ver v;
    ASSERT_EQ_INT(ob_ver_parse(NULL, &v), -1);
    ASSERT_EQ_INT(ob_ver_parse("2.0", NULL), -1);
    ASSERT_EQ_INT(ob_ver_parse_numeric(NULL, &v), -1);
    ASSERT_EQ_INT(ob_ver_parse_numeric("2.0", NULL), -1);
    ASSERT_EQ_INT(ob_ver_parse_numeric("invalid", &v), -1);
    ASSERT_EQ_INT(ob_ver_cmp(NULL, &v), 0);
    ASSERT_EQ_INT(ob_ver_cmp(&v, NULL), 0);

    /* Exceeding max components */
    ASSERT_OK(ob_ver_parse("GLIBC_1.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16.17", &v));
    ASSERT_FALSE(v.is_numeric);

    /* Long 4096-byte input */
    char long_str[4096];
    memset(long_str, 'A', sizeof(long_str) - 1);
    long_str[sizeof(long_str) - 1] = '\0';
    ASSERT_OK(ob_ver_parse(long_str, &v));
    ASSERT_FALSE(v.is_numeric);
}

TEST(ver_total_order_property) {
    const char *raw_list[7] = {
        "2.2.5", "2.3", "2.9", "2.10", "2.28", "2.28.1", "2.34"
    };
    ob_ver parsed[7];
    for (int i = 0; i < 7; i++) {
        ASSERT_OK(ob_ver_parse_numeric(raw_list[i], &parsed[i]));
    }

    for (int i = 0; i < 7; i++) {
        for (int j = 0; j < 7; j++) {
            int cmp_ij = ob_ver_cmp(&parsed[i], &parsed[j]);
            int cmp_ji = ob_ver_cmp(&parsed[j], &parsed[i]);
            ASSERT_EQ_INT(cmp_ij, -cmp_ji);
            if (i < j) {
                ASSERT_EQ_INT(cmp_ij, -1);
            } else if (i > j) {
                ASSERT_EQ_INT(cmp_ij, 1);
            } else {
                ASSERT_EQ_INT(cmp_ij, 0);
            }
        }
    }
}
