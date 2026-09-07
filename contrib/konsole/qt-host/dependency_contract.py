"""No-compile checks of public headers and pkg-config provider provenance."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def public_headers(dependencies, consumers):
    """Capture header promises from the same cpp_info used by both generators.

    consumers maps a directly consumed package to {pc module: [header, ...]}.
    Paths are read from Conan, never reconstructed from its cache layout.
    """
    result = {}
    for package, modules in consumers.items():
        if package not in dependencies.direct_host:
            raise ValueError(f"{package}: public header consumer needs a direct requirement")
        dep = dependencies[package]
        root = Path(dep.package_folder).resolve()
        includes = dep.cpp_info.aggregated_components().includedirs
        for module, headers in modules.items():
            for header in headers:
                candidates = [(Path(directory) / header).resolve() for directory in includes]
                if not any(path.is_relative_to(root) and path.is_file() for path in candidates):
                    raise ValueError(f"{package}: cpp_info does not expose {header} from {root}")
            result[module] = {"package": package, "root": str(root), "headers": headers}
    return result


def record_contract(folder, headers):
    folder = Path(folder)
    modules = sorted(path.stem for path in folder.glob("*.pc"))
    if not modules or not set(headers).issubset(modules):
        raise ValueError(f"PkgConfigDeps did not generate required modules: {set(headers) - set(modules)}")
    (folder / "dependency-contract.json").write_text(
        json.dumps({"modules": modules, "headers": headers}, indent=2) + "\n"
    )


def verify_contract(folder, env=None):
    folder = Path(folder).resolve()
    contract = json.loads((folder / "dependency-contract.json").read_text())
    env = dict(os.environ if env is None else env)
    # pkg-config normally suppresses -I/usr/include. Expose it to the audit:
    # it must not hide a host-header substitution.
    env["PKG_CONFIG_ALLOW_SYSTEM_CFLAGS"] = "1"

    def query(module, *flags):
        return subprocess.check_output(
            ["pkg-config", *flags, module], env=env, text=True,
        ).strip()

    for module in contract["modules"]:
        provider = Path(query(module, "--variable=pcfiledir")).resolve()
        if provider != folder:
            raise ValueError(f"{module}: pkg-config selected {provider}, expected {folder}")
        query(module, "--exists")  # Also resolve the Requires closure.
    for module, entry in contract["headers"].items():
        root = Path(entry["root"])
        if Path(query(module, "--variable=prefix")).resolve() != root:
            raise ValueError(f"{module}: pkg-config prefix is not the Conan package {root}")
        flags = shlex.split(query(module, "--cflags-only-I"))
        includes = [Path(flag[2:]) for flag in flags if flag.startswith("-I")]
        for header in entry["headers"]:
            candidates = [(path / header).resolve() for path in includes]
            if not any(path.is_relative_to(root) and path.is_file() for path in candidates):
                raise ValueError(f"{module}: pkg-config does not expose {header} from {root}")
    print(f"Conan metadata: {len(contract['modules'])} pkg-config providers and public headers verified")


if __name__ == "__main__":
    try:
        verify_contract(sys.argv[1])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Conan metadata contract failed: {error}")
