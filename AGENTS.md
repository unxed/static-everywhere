# Repository agent instructions

## Build and dependency recipes

Before writing or modifying a build or dependency recipe, first study the
build files of the project being built. Inspect the relevant `CMakeLists.txt`,
`meson.build`, `configure.ac`, project files, and referenced subdirectories at
the pinned source revision. Record the required and optional dependencies,
feature switches, generated build-time tools, target structure, and
platform/runtime assumptions needed for a correct recipe. Do not wait for a
CI failure to discover information that is available in the project's build
files; CI is validation of the recipe, not the primary way to discover its
requirements.

## Пиновка источника без пиновки тулчейна — это половина пиновки

Каждая сторонняя сборка фиксирует не только *что* собирается, но и *чем*.
Коммит в lock-файле задаёт исходник; компилятор, которым его собирают, задаётся
там же и передаётся сборке явно.

Правило появилось из конкретного отказа. `contrib/far2l/solo.lock` фиксировал
коммит SoLo, а `./build` запускался без `CC`/`CXX`. `build.py` в SoLo при
незаданных переменных берёт `cc`/`c++`, то есть на раннере — g++. Его CI при
этом собирает всё с clang. Под g++ библиотека `dlfcn` не компилируется:
build.py кладёт публичные заголовки musl перед системными путями, а host
libstdc++ через `<string_view>` → `bits/os_defines.h` требует `__GLIBC_PREREQ`
из glibc'шного `features.h`, который musl заслоняет. В логе это выглядит как
четыре `missing binary operator before token "("` и падение внутри чужого
проекта — то есть как его баг, хотя причина у нас.

Практически:

- компилятор пишется в тот же lock-файл, что и коммит, и рядом с ним —
  причина, почему именно этот;
- workflow читает его оттуда и передаёт сборке явно, а не полагается на
  дефолты чужого скрипта;
- перед сборкой проверяется, что этот компилятор установлен, и его версия
  печатается в лог. Отсутствие компилятора обязано падать на этом шаге с
  внятным сообщением, а не всплывать ошибкой компиляции внутри зависимости;
- пакет с ним добавляется в список устанавливаемых, а не предполагается
  присутствующим на раннере.

Тот же принцип уже соблюдён в `onebin/tools/build-far2l-deps.sh`, который
задаёт `CC`/`CXX` из `onebin/toolchain`. Новая сторонняя сборка без явно
заданного тулчейна — дефект того же класса, независимо от того, проходит она
сегодня или нет: она проходит по совпадению с тем, что оказалось на раннере.
