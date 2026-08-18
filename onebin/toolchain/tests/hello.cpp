#include <iostream>

extern "C" const char *onebin_toolchain_greeting(void);

int main() {
    std::cout << onebin_toolchain_greeting() << " (C++)" << std::endl;
    return 0;
}
