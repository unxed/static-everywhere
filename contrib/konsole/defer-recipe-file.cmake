# Helpers for files owned by this recipe but executed by a deferred CMake call.
#
# cmake_language(DEFER) evaluates its arguments in the later directory/list
# context. CMAKE_CURRENT_LIST_DIR therefore points at the dependency's source
# tree by the time the callback runs, not at this recipe's directory. Capture
# the absolute path in the caller's directory scope and resolve it there.
function(_se_konsole_defer_recipe_file path)
    set(_SE_KONSOLE_DEFERRED_RECIPE_FILE "${path}" PARENT_SCOPE)
    cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}"
        CALL _se_konsole_include_deferred_recipe_file)
endfunction()

function(_se_konsole_include_deferred_recipe_file)
    if(NOT DEFINED _SE_KONSOLE_DEFERRED_RECIPE_FILE OR
       NOT EXISTS "${_SE_KONSOLE_DEFERRED_RECIPE_FILE}")
        message(FATAL_ERROR
            "static-everywhere: deferred recipe file is missing: "
            "'${_SE_KONSOLE_DEFERRED_RECIPE_FILE}'")
    endif()
    include("${_SE_KONSOLE_DEFERRED_RECIPE_FILE}")
endfunction()
