import os

from conan import ConanFile
from conan.errors import ConanInvalidConfiguration
from conan.tools.cmake import CMakeDeps, CMakeToolchain
from conan.tools.files import save

from qt_cmake_components import (
    component_config,
    component_version_config,
    legacy_package_config,
)


class KonsoleQtHostConan(ConanFile):
    name = "static-everywhere-konsole-qt-host"
    version = "0.1"
    exports = "qt_cmake_components.py"
    settings = "os", "compiler", "build_type", "arch"

    # This keeps the runtime surface focused on Widgets, X11 and OpenGL.
    # QtDeclarative is nevertheless required at build time because the
    # upstream KNewStuff framework unconditionally builds its Qt Quick
    # library. The optional QML integrations in the other frameworks remain
    # disabled in kde-builder; QtTools is included only for the build-time
    # Linguist tools used by KF6 translation catalogs. qtmultimedia itself is
    # required by Konsole, and Qt's qtmultimedia package requires
    # qtshadertools; its optional audio backends are not. Qt5Compat is
    # required by qca's Qt6 build, and QtSvg is required by KIconThemes' CMakeLists.txt
    # even though Konsole's own top-level
    # CMakeLists.txt does not request it. QtDBus is built because
    # KNotifications' Linux CMakeLists.txt requires Qt6DBus even when the
    # application-level USE_DBUS option is disabled.
    default_options = {
        "qt/*:shared": False,
        "qt/*:opengl": "desktop",
        "qt/*:qtdeclarative": True,
        "qt/*:qtmultimedia": True,
        "qt/*:qtimageformats": False,
        "qt/*:qt5compat": True,
        "qt/*:qtsvg": True,
        "qt/*:qtshadertools": True,
        "qt/*:qttools": True,
        "qt/*:qttranslations": False,
        "qt/*:qtwayland": False,
        "qt/*:with_dbus": True,
        "qt/*:with_egl": True,
        "qt/*:with_x11": True,
        "qt/*:with_glib": False,
        "qt/*:with_openal": False,
        "qt/*:with_gstreamer": False,
        "qt/*:with_pulseaudio": False,
        "qt/*:with_libalsa": False,
        "qt/*:with_icu": True,
        "qt/*:with_fontconfig": True,
        "qt/*:with_freetype": True,
        "qt/*:with_harfbuzz": True,
        "qt/*:with_libpng": True,
        "qt/*:with_pq": False,
        "qt/*:with_odbc": False,
        "qt/*:with_sqlite3": False,
        "qt/*:with_vulkan": False,
        "qt/*:openssl": False,
        "qt/*:with_gssapi": False,
        "qt/*:with_zstd": False,
        "xkbcommon/*:with_x11": True,
        "xkbcommon/*:with_wayland": False,
    }

    # Konsole's and the KDE frameworks' CMakeLists.txt files consume these
    # packages directly. Keep them direct requirements rather than relying on
    # Qt's transitive graph: Conan marks transitive requirements as
    # headers=False, which can publish a usable link target without its
    # include directories. That turns a missing header into a late,
    # framework-specific failure (for example lzma.h in KArchive).
    requires = (
        "qt/6.11.1",
        "icu/78.1",
        # Sonnet's src/plugins/CMakeLists.txt makes the individual spell
        # backends optional but fails the whole framework when none is
        # available. Keep one backend in the target graph; the ConanCenter
        # recipe installs the headers and static library that Sonnet's
        # FindHUNSPELL.cmake searches for.
        "hunspell/1.7.2",
        "bzip2/1.0.8",
        "xz_utils/5.8.3",
        "zlib/1.3.2",
        # KDocTools' src/CMakeLists.txt consumes LIBXML2_INCLUDE_DIR and its
        # tools include libxml headers directly. Qt brings libxml2
        # transitively, but Conan marks that edge headers=False, so keep the
        # public header dependency visible to CMakeDeps.
        "libxml2/2.15.3",
        "libmount/2.39.2",
    )

    def _require_header_in_package(self, package: str, header: str) -> None:
        """Fail now if the header an adapter promises is not in the package.

        Cheap insurance against the whole shape of failure: we synthesize
        CMake metadata, and until this check nothing confirmed the
        metadata described reality. A wrong or stale entry surfaced only
        when some consumer's compile could not find the file, with no
        mention of which package had promised it.
        """
        root = self.dependencies[package].package_folder
        for base, _dirs, files in os.walk(os.path.join(root, "include")):
            if header in files:
                self.output.info(
                    f"Adapter check: {header} found in {base}"
                )
                return
        raise ConanInvalidConfiguration(
            f"{package} does not contain {header} anywhere under include/. "
            f"The generated adapter would report the package as found and "
            f"hand over an include directory that does not resolve it, and "
            f"the failure would appear later inside a consumer's compile."
        )

    def generate(self):
        cmake_deps = CMakeDeps(self)

        # Some KDE Frameworks use the upstream CMake target spelling while
        # Conan Center recipes expose the package-name spelling. Keep these
        # bridges in CMakeDeps metadata so both spellings resolve to the same
        # imported target instead of discovering one missing alias per
        # framework during the hosted build.
        cmake_deps.set_property(
            "libmount",
            "cmake_file_name",
            "LibMount",
        )
        cmake_deps.set_property(
            "libmount::libmount",
            "cmake_target_aliases",
            ["LibMount::LibMount"],
        )
        cmake_deps.generate()

        # Conan Center's Qt recipe intentionally removes the upstream
        # Qt6<Module>Config.cmake files and exports one component-aware
        # Qt6Config.cmake through CMakeDeps. KDE Frameworks use both forms:
        # find_package(Qt6 COMPONENTS Core) and find_package(Qt6Core). Keep
        # the latter working for every component published by the dependency,
        # instead of discovering one missing adapter at a time in CI.
        qt_components = sorted(
            component_name[2:]
            for component_name in self.dependencies["qt"].cpp_info.components
            if len(component_name) > 2
            and component_name.startswith("qt")
            and component_name != "qtPlatform"
        )
        # Conan's aggregate Qt config can define private targets without
        # publishing a standalone Qt6<Module>PrivateConfig.cmake. KDE
        # Frameworks use both forms (for example Qt6GuiPrivate), so cover the
        # complete private-component family instead of discovering one missing
        # adapter at a time in the hosted graph.
        qt_components = sorted(
            set(qt_components)
            | {
                "ConcurrentPrivate",
                "CorePrivate",
                "DBusPrivate",
                "GuiPrivate",
                "MultimediaPrivate",
                "MultimediaWidgetsPrivate",
                "NetworkPrivate",
                "OpenGLPrivate",
                "OpenGLWidgetsPrivate",
                "PrintSupportPrivate",
                "QmlPrivate",
                "QuickPrivate",
                "ShaderToolsPrivate",
                "SqlPrivate",
                "SvgPrivate",
                "SvgWidgetsPrivate",
                "TestPrivate",
                "WidgetsPrivate",
                "XmlPrivate",
            }
        )
        for module in qt_components:
            save(self, f"Qt6{module}Config.cmake", component_config(module))
            save(self, f"Qt6{module}ConfigVersion.cmake", component_version_config())

        # Conan's generated CONFIG file exposes hunspell::hunspell, while
        # Sonnet's upstream FindHUNSPELL.cmake consumes legacy variables and
        # the PKG_HUNSPELL_VERSION probe. Generate the same compatibility
        # adapter shape for this and future variable-based consumers instead
        # of relying on a global MODULE/CONFIG preference that can break KDE
        # packages such as LibMount.
        # Verify the claim before writing it down.
        #
        # An adapter asserts "this package is found, and here is where its
        # header lives". Nothing checked that until a consumer tried to
        # compile, which for sonnet meant the failure arrived two hours
        # into the run as a bare "'hunspell.hxx' file not found" that
        # never mentioned hunspell's package at all. The check is a
        # filesystem lookup and costs nothing.
        self._require_header_in_package("hunspell", "hunspell.hxx")
        save(
            self,
            "HUNSPELLConfig.cmake",
            legacy_package_config(
                package="hunspell",
                target="hunspell::hunspell",
                variable_prefix="HUNSPELL",
                version="1.7.2",
                # sonnet includes <hunspell.hxx> unqualified while the
                # package installs it under include/hunspell/, so handing
                # over the target's include directory is one level too
                # high: the plugin compiled and died on
                # "'hunspell.hxx' file not found".
                header="hunspell.hxx",
                path_suffixes="hunspell",
            ),
        )
        self.output.info("Generated legacy-variable adapter: HUNSPELLConfig.cmake")
        self.output.info(
            "Generated Qt6 component CMake compatibility adapters: "
            + ", ".join(f"Qt6{module}" for module in qt_components)
        )

        tc = CMakeToolchain(self)
        tc.variables["CMAKE_BUILD_TYPE"] = "Release"
        # zig-cc cannot complete CMake's ABI probe, although this target is
        # unambiguously x86_64. These are the same values forced in f4 qt.
        tc.variables["CMAKE_SIZEOF_VOID_P"] = "8"
        tc.variables["CMAKE_LIBRARY_ARCHITECTURE"] = "x86_64-linux-gnu"
        tc.variables["CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES"] = "/usr/include"
        tc.variables["CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES"] = "/usr/include"
        tc.variables["CMAKE_SKIP_RPATH"] = True
        # Conan's static CONFIG packages remain preferred so KDE's own
        # dependency targets and aliases are selected. Legacy variable-based
        # consumers are adapted in the generated package config above.
        tc.variables["CMAKE_FIND_PACKAGE_PREFER_CONFIG"] = True
        tc.variables["CMAKE_FIND_USE_PACKAGE_REGISTRY"] = False
        tc.variables["CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY"] = False
        tc.generate()
