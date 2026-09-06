#!/usr/bin/env python3
"""CI-only integration of real Conan generators; no source compilation.

Package empty archive/header fixtures, then consume their CMake and pkg-config
metadata. This checks component aggregation as used by OpenSSL and Zstd.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "contrib/konsole/qt-host/dependency_contract.py"

with tempfile.TemporaryDirectory(prefix="konsole-conan-generators-") as temporary:
    base = Path(temporary)
    env = dict(os.environ, CONAN_HOME=str(base / "cache"))
    profile = base / "profile"
    profile.write_text("""[settings]
os=Linux
arch=x86_64
compiler=gcc
compiler.version=13
compiler.libcxx=libstdc++11
compiler.cppstd=gnu20
build_type=Release
""")

    def conan(*args):
        subprocess.run(["conan", *args, "-pr:h", str(profile), "-pr:b", str(profile)],
                       env=env, check=True)

    names = ("metacodec", "metacrypto")
    for name in names:
        source = base / name
        source.mkdir()
        (source / "conanfile.py").write_text(f'''
from conan import ConanFile
from conan.tools.files import save
import os
class Fixture(ConanFile):
    name = "{name}"
    version = "1.0"
    package_type = "static-library"
    settings = "os", "arch", "compiler", "build_type"
    def package(self):
        save(self, os.path.join(self.package_folder, "include/{name}.h"), "/* fixture */")
        save(self, os.path.join(self.package_folder, "lib/lib{name}.a"), "!<arch>\\n")
    def package_info(self):
        self.cpp_info.set_property("cmake_file_name", "{name}")
        self.cpp_info.set_property("cmake_target_name", "fixture::{name}")
        self.cpp_info.set_property("pkg_config_name", "lib{name}")
        self.cpp_info.components["core"].libs = ["{name}"]
        self.cpp_info.components["core"].set_property("pkg_config_name", "lib{name}")
''')
        conan("export-pkg", str(source))

    consumer = base / "consumer"
    consumer.mkdir()
    shutil.copy2(HELPER, consumer)
    (consumer / "conanfile.py").write_text('''
from conan import ConanFile
from conan.tools.cmake import CMakeDeps
from conan.tools.gnu import PkgConfigDeps
from dependency_contract import public_headers, record_contract
class Consumer(ConanFile):
    settings = "os", "arch", "compiler", "build_type"
    requires = "metacodec/1.0", "metacrypto/1.0"
    def generate(self):
        headers = public_headers(self.dependencies, {
            name: {"lib" + name: [name + ".h"]}
            for name in ("metacodec", "metacrypto")
        })
        CMakeDeps(self).generate()
        PkgConfigDeps(self).generate()
        record_contract(self.generators_folder, headers)
''')
    generated = base / "generated"
    conan("install", str(consumer), "--output-folder", str(generated), "--no-remote")
    pc_env = dict(env, PKG_CONFIG_PATH=str(generated), PKG_CONFIG_LIBDIR=str(generated),
                  PKG_CONFIG_SYSROOT_DIR="")
    subprocess.run(["python3", str(HELPER), str(generated)], env=pc_env, check=True)

    (consumer / "CMakeLists.txt").write_text('''
cmake_minimum_required(VERSION 3.16)
project(MetadataConsumer NONE)
find_package(metacodec REQUIRED CONFIG)
find_package(metacrypto REQUIRED CONFIG)
add_library(consumer INTERFACE)
target_link_libraries(consumer INTERFACE fixture::metacodec fixture::metacrypto)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/includes.txt"
    CONTENT "$<TARGET_PROPERTY:consumer,INTERFACE_INCLUDE_DIRECTORIES>")
''')
    build = base / "cmake"
    subprocess.run(["cmake", "-S", str(consumer), "-B", str(build),
                    "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_PREFIX_PATH={generated}"],
                   env=env, check=True)
    includes = (build / "includes.txt").read_text().split(";")
    contract = json.loads((generated / "dependency-contract.json").read_text())
    for entry in contract["headers"].values():
        for header in entry["headers"]:
            assert any((Path(path) / header).is_file()
                       and (Path(path) / header).resolve().is_relative_to(Path(entry["root"]))
                       for path in includes), (header, includes)
    print("PASS: actual CMakeDeps and PkgConfigDeps expose the same component headers")
