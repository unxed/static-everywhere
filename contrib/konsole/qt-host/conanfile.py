from conan import ConanFile
from conan.tools.cmake import CMakeDeps, CMakeToolchain


class KonsoleQtHostConan(ConanFile):
    name = "static-everywhere-konsole-qt-host"
    version = "0.1"
    settings = "os", "compiler", "build_type", "arch"

    # This is intentionally a small Qt surface. Konsole is a Widgets
    # application; QML, Qt Quick, Wayland, DBus and the multimedia backends
    # are not part of the showcase. qtmultimedia itself is required by
    # Konsole, and Qt's qtmultimedia package requires qtshadertools; its
    # optional audio backends are not.
    default_options = {
        "qt/*:shared": False,
        "qt/*:opengl": "desktop",
        "qt/*:qtmultimedia": True,
        "qt/*:qtdeclarative": False,
        "qt/*:qtimageformats": False,
        "qt/*:qtshadertools": True,
        "qt/*:qttools": False,
        "qt/*:qttranslations": False,
        "qt/*:qtwayland": False,
        "qt/*:with_dbus": False,
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

    # Konsole's CMakeLists.txt asks for ICU directly, not only through Qt.
    # Keeping it a direct requirement makes CMakeDeps publish ICU::uc and
    # ICU::i18n and prevents a host ICU installation from satisfying it.
    requires = ("qt/6.11.1", "icu/78.1")

    def generate(self):
        CMakeDeps(self).generate()

        tc = CMakeToolchain(self)
        tc.variables["CMAKE_BUILD_TYPE"] = "Release"
        # zig-cc cannot complete CMake's ABI probe, although this target is
        # unambiguously x86_64. These are the same values forced in f4 qt.
        tc.variables["CMAKE_SIZEOF_VOID_P"] = "8"
        tc.variables["CMAKE_LIBRARY_ARCHITECTURE"] = "x86_64-linux-gnu"
        tc.variables["CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES"] = "/usr/include"
        tc.variables["CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES"] = "/usr/include"
        tc.variables["CMAKE_SKIP_RPATH"] = True
        tc.variables["CMAKE_FIND_PACKAGE_PREFER_CONFIG"] = True
        tc.variables["CMAKE_FIND_USE_PACKAGE_REGISTRY"] = False
        tc.variables["CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY"] = False
        tc.generate()
