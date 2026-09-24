# Apply only to the checkout audited in deps.lock, including on reconfigure.
function(se_patch_kwindowsystem source)
    file(STRINGS "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/deps.lock" _pin
        REGEX "^kwindowsystem ")
    separate_arguments(_fields UNIX_COMMAND "${_pin}")
    list(GET _fields 2 _expected)
    execute_process(COMMAND git -C "${source}" rev-parse HEAD
        OUTPUT_VARIABLE _actual OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _status)
    if(NOT _status EQUAL 0 OR NOT _actual STREQUAL _expected)
        message(FATAL_ERROR "KWindowSystem source ${_actual} != pinned ${_expected}")
    endif()
    set(_patch "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/kwindowsystem-patches/0001-static-x11-backend.patch")
    execute_process(COMMAND git -C "${source}" apply --check --whitespace=error "${_patch}"
        RESULT_VARIABLE _forward OUTPUT_QUIET ERROR_QUIET)
    if(_forward EQUAL 0)
        execute_process(COMMAND git -C "${source}" apply --whitespace=error "${_patch}"
            RESULT_VARIABLE _applied)
        if(NOT _applied EQUAL 0)
            message(FATAL_ERROR "Cannot apply pinned KWindowSystem overlay")
        endif()
    else()
        execute_process(COMMAND git -C "${source}" apply --reverse --check --whitespace=error "${_patch}"
            RESULT_VARIABLE _reverse OUTPUT_QUIET ERROR_QUIET)
        if(NOT _reverse EQUAL 0)
            message(FATAL_ERROR "Pinned KWindowSystem overlay applies neither forward nor reverse")
        endif()
    endif()
endfunction()
