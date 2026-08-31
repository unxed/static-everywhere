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
