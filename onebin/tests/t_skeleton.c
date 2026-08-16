#include "test.h"

TEST(skeleton_assertions_pass) {
    ASSERT_TRUE(1);
    ASSERT_FALSE(0);
    ASSERT_EQ_INT(42, 42);
    ASSERT_EQ_U64(100ULL, 100ULL);
    ASSERT_EQ_STR("onebin", "onebin");
    ASSERT_NULL(NULL);
    int x = 5;
    ASSERT_NOT_NULL(&x);
}

TEST(skeleton_skip_demonstration) {
    SKIP("demonstrating skip functionality");
}
