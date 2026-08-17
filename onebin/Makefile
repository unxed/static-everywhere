.POSIX:

CC = cc
PREFIX = /usr/local
DESTDIR =
FUZZ_ITERS = 20000

CFLAGS = -std=c11 -O2 -g -Wall -Wextra -Werror -Wpedantic \
         -Wshadow -Wconversion -Wsign-conversion -Wstrict-prototypes \
         -Wmissing-prototypes -Wpointer-arith -Wwrite-strings \
         -Wcast-qual -Wvla -Wformat=2 -Wundef \
         -D_FILE_OFFSET_BITS=64

INCLUDES = -Iinclude -Isrc

LIB_SRC = src/util/buf.c src/util/ver.c src/util/str.c src/util/json.c src/util/vec.c \
          src/elf/image.c src/elf/dynamic.c src/elf/verneed.c src/elf/symbols.c src/elf/strings.c \
          src/audit/finding.c src/audit/baseline.c src/audit/report.c \
          src/audit/report_text.c src/audit/report_json.c src/audit/checks_common.c \
          src/audit/checks/c_needed.c src/audit/checks/c_profile.c
SRC = src/main.c $(LIB_SRC)
TEST_SRC = tests/test_main.c tests/t_skeleton.c tests/t_buf.c tests/t_ver.c \
           tests/mkelf.c tests/t_mkelf.c tests/t_image.c \
           tests/t_dynamic.c tests/t_verneed.c tests/t_symbols.c \
           tests/t_str.c tests/t_json.c tests/t_baseline.c tests/t_report.c \
           tests/report_fixtures.c tests/t_checks_needed.c tests/t_checks_profile.c $(LIB_SRC)

all: build/onebin

build/onebin: $(SRC)
	@mkdir -p build
	$(CC) $(CFLAGS) $(INCLUDES) $(SRC) -o build/onebin

build/tests: $(TEST_SRC)
	@mkdir -p build
	$(CC) $(CFLAGS) $(INCLUDES) -Itests $(TEST_SRC) -o build/tests

test: build/tests
	./build/tests

test-asan:
	@mkdir -p build/asan
	@if $(CC) -fsanitize=address,undefined -E - < /dev/null >/dev/null 2>&1; then \
		$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-omit-frame-pointer $(INCLUDES) -Itests $(TEST_SRC) -o build/asan/tests && \
		./build/asan/tests; \
	else \
		echo "SKIP: AddressSanitizer/UBSan not supported by $(CC)"; \
	fi

test-ubsan:
	@mkdir -p build/ubsan
	@if $(CC) -fsanitize=undefined -E - < /dev/null >/dev/null 2>&1; then \
		$(CC) $(CFLAGS) -fsanitize=undefined -fno-sanitize-recover=all $(INCLUDES) -Itests $(TEST_SRC) -o build/ubsan/tests && \
		./build/ubsan/tests; \
	else \
		echo "SKIP: UndefinedBehaviorSanitizer not supported by $(CC)"; \
	fi

fuzz:
	@echo "Fuzzer target: $(FUZZ_ITERS) iterations (fuzzer module in progress)"

coverage:
	@mkdir -p build/cov
	@if $(CC) --coverage -E - < /dev/null >/dev/null 2>&1; then \
		$(CC) $(CFLAGS) --coverage $(INCLUDES) -Itests $(TEST_SRC) -o build/cov/tests && \
		./build/cov/tests; \
	else \
		echo "SKIP: gcov coverage not supported by $(CC)"; \
	fi

golden:
	@echo "Regenerating golden files (none yet)"

selftest: all
	@echo "Running selftest on build/onebin..."
	./build/onebin --version

lint:
	@echo "Lint target (source lint tests in progress)"

install: build/onebin
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	cp build/onebin $(DESTDIR)$(PREFIX)/bin/onebin

clean:
	rm -rf build

.PHONY: all test test-asan test-ubsan fuzz coverage golden selftest lint install clean
