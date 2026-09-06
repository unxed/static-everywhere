#!/usr/bin/env python3
"""Exercise metadata discovery, without compiling any source code."""

import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "contrib/konsole/qt-host"))
from dependency_contract import public_headers, record_contract, verify_contract


class Dependencies(dict):
    @property
    def direct_host(self):
        return self


class MetadataContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="konsole-metadata-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.generated = self.base / "generated"
        self.host = self.base / "host"
        self.generated.mkdir()
        self.host.mkdir()
        self.dependencies = Dependencies()
        self.consumers = {}
        # Arbitrary names: the rule must cover new dependencies and both
        # source-built and downloaded cache packages, not a Zstd whitelist.
        for name, location in (("codec", "p/b/build/p"), ("crypto", "p/download/p"),
                               ("future", "relocated store/package")):
            root = self.base / location
            include = root / "include"
            include.mkdir(parents=True)
            (include / f"{name}.h").touch()
            cpp = SimpleNamespace(includedirs=[str(include)])
            self.dependencies[name] = SimpleNamespace(
                package_folder=str(root),
                cpp_info=SimpleNamespace(aggregated_components=lambda cpp=cpp: cpp),
            )
            self.consumers[name] = {f"lib{name}": [f"{name}.h"]}
            self.pc(self.generated, name, root, include)
            self.pc(self.host, name, self.host, self.host)
        headers = public_headers(self.dependencies, self.consumers)
        record_contract(self.generated, headers)
        self.env = dict(os.environ, PKG_CONFIG_PATH=f"{self.generated}:{self.host}",
                        PKG_CONFIG_LIBDIR=str(self.host), PKG_CONFIG_SYSROOT_DIR="")

    @staticmethod
    def pc(folder, name, root, include):
        (folder / f"lib{name}.pc").write_text(
            f"prefix={root}\nName: {name}\nDescription: fixture\nVersion: 1.0\n"
            f"Cflags: -I\"{include}\"\nLibs: -L\"{root}/lib\" -l{name}\n"
        )

    def test_all_cache_layouts_and_space_in_path(self):
        verify_contract(self.generated, self.env)

    def test_host_priority_is_rejected(self):
        self.env["PKG_CONFIG_PATH"] = f"{self.host}:{self.generated}"
        with self.assertRaisesRegex(ValueError, "pkg-config selected"):
            verify_contract(self.generated, self.env)

    def test_missing_generated_file_cannot_fall_back_to_host(self):
        (self.generated / "libfuture.pc").unlink()
        with self.assertRaisesRegex(ValueError, "pkg-config selected"):
            verify_contract(self.generated, self.env)

    def test_transitive_only_header_consumer_is_rejected(self):
        class Transitive(Dependencies):
            direct_host = {}
        with self.assertRaisesRegex(ValueError, "direct requirement"):
            public_headers(Transitive(self.dependencies), self.consumers)

    def test_cpp_info_header_loss_is_rejected(self):
        self.dependencies["future"].cpp_info.aggregated_components().includedirs = []
        with self.assertRaisesRegex(ValueError, "cpp_info does not expose"):
            public_headers(self.dependencies, self.consumers)

    def test_pc_header_loss_is_rejected(self):
        root = Path(self.dependencies["future"].package_folder)
        self.pc(self.generated, "future", root, self.host)
        (self.host / "future.h").touch()
        with self.assertRaisesRegex(ValueError, "does not expose future.h"):
            verify_contract(self.generated, self.env)

    def test_wrong_library_provider_is_rejected(self):
        self.pc(self.generated, "future", self.host, self.host)
        with self.assertRaisesRegex(ValueError, "prefix is not"):
            verify_contract(self.generated, self.env)

    def test_missing_module_at_generation_is_rejected(self):
        (self.generated / "libfuture.pc").unlink()
        with self.assertRaisesRegex(ValueError, "did not generate required modules"):
            record_contract(self.generated, public_headers(self.dependencies, self.consumers))


if __name__ == "__main__":
    unittest.main()
