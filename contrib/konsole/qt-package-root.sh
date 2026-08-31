# Source this file from the Konsole build script or its regression tests.
# The CMakeDeps data-file name contains the Conan package name and host
# architecture, so callers must discover the file by the variable it defines.

konsole_qt_package_root() {
    local qt_out="$1"
    local data_file root

    while IFS= read -r data_file; do
        root=$(sed -n 's|^[[:space:]]*set(qt_PACKAGE_FOLDER_RELEASE "\(.*\)") [[:space:]]*$|\1|p'                    "$data_file" | head -n 1)
        if [[ -n $root ]]; then
            printf '%s\n' "$root"
            return 0
        fi
    done < <(find "$qt_out" -maxdepth 1 -type f                  -name '*-release*-data.cmake' -print | sort)

    printf 'Konsole: no Conan CMakeDeps data file containing qt_PACKAGE_FOLDER_RELEASE in %s\n'         "$qt_out" >&2
    return 1
}
