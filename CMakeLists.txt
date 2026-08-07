cmake_minimum_required(VERSION 3.21)
project(Bro)

# Default to Release build if not specified
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Release" "RelWithDebInfo")
endif()

# Release build optimizations
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG -flto")
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG -flto")
# Applied per-config so dead stripping also happens under multi-config generators
set(CMAKE_EXE_LINKER_FLAGS_RELEASE "-flto -Wl,-dead_strip")

# CEF binary distribution path
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/cef-project/third_party/cef/cef_binary_151.3.14+g5d67476+chromium-151.0.7922.72_macosarm64_minimal")

# Use C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Include CEF cmake helpers
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")

# Find CEF package
find_package(CEF REQUIRED)

# Add CEF library target
add_subdirectory(${CEF_ROOT}/libcef_dll libcef_dll_wrapper)

# Source files
set(BRO_SRCS
    src/bro_app.cc
    src/bro_app.h
    src/bro_handler.cc
    src/bro_handler.h
    src/bro_handler_mac.mm
    src/bro_mac.mm
    src/radix_icons.h
    src/radix_icons.mm
)

set(BRO_HELPER_SRCS
    src/process_helper_mac.cc
)

# Bundle resources
set(BRO_RESOURCES
    src/mac/cefsimple.icns
    src/mac/wasm-bench.html
    src/mac/gpu-bench.html
)
set_source_files_properties(${BRO_RESOURCES} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources"
)

# UI fonts, auto-registered via ATSApplicationFontsPath in Info.plist
set(BRO_FONT_RESOURCES
    src/mac/fonts/Geist-Regular.otf
    src/mac/fonts/Geist-SemiBold.otf
)
set_source_files_properties(${BRO_FONT_RESOURCES} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources/Fonts"
)

# App bundle info
set(PRODUCT_NAME "Bro")
set(EXECUTABLE_NAME "Bro")
set(VERSION_SHORT "1.0.0")

# Configure Info.plist
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/src/mac/Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    @ONLY
)

# Main executable
add_executable(${EXECUTABLE_NAME} MACOSX_BUNDLE ${BRO_SRCS} ${BRO_RESOURCES}
               ${BRO_FONT_RESOURCES})

# Include directories
target_include_directories(${EXECUTABLE_NAME} PRIVATE
    ${CEF_ROOT}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Link libraries
target_link_libraries(${EXECUTABLE_NAME}
    libcef_dll_wrapper
    ${CEF_STANDARD_LIBS}
    "-framework QuartzCore"
)

# Compile flags
target_compile_options(${EXECUTABLE_NAME} PRIVATE
    ${CEF_CXX_COMPILER_FLAGS}
    -fobjc-arc
)

# Set bundle properties
set_target_properties(${EXECUTABLE_NAME} PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.bro.browser"
    MACOSX_BUNDLE_BUNDLE_NAME "Bro"
    MACOSX_BUNDLE_BUNDLE_VERSION "${VERSION_SHORT}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    OUTPUT_NAME "Bro"
)

# Helper apps. Chromium on macOS launches subprocesses from helper bundles with
# exact names: "Bro Helper.app", "Bro Helper (Alerts).app", "Bro Helper (GPU).app",
# "Bro Helper (Plugin).app", "Bro Helper (Renderer).app". CEF_HELPER_APP_SUFFIXES
# (from cef_variables.cmake) enumerates them as "<name suffix>:<target suffix>:<plist suffix>".
foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" _suffix_list ${_suffix_list})
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)

  set(_helper_target "${EXECUTABLE_NAME}_Helper${_target_suffix}")
  set(_helper_output_name "${EXECUTABLE_NAME} Helper${_name_suffix}")

  set(HELPER_EXECUTABLE_NAME "${_helper_output_name}")
  set(HELPER_BUNDLE_ID_SUFFIX "${_plist_suffix}")
  configure_file(
      "${CMAKE_CURRENT_SOURCE_DIR}/src/mac/helper-Info.plist.in"
      "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist"
      @ONLY
  )

  add_executable(${_helper_target} MACOSX_BUNDLE ${BRO_HELPER_SRCS})

  target_include_directories(${_helper_target} PRIVATE
      ${CEF_ROOT}
      ${CMAKE_CURRENT_SOURCE_DIR}/src
  )

  target_link_libraries(${_helper_target}
      libcef_dll_wrapper
      ${CEF_STANDARD_LIBS}
  )

  target_compile_options(${_helper_target} PRIVATE
      ${CEF_CXX_COMPILER_FLAGS}
  )

  set_target_properties(${_helper_target} PROPERTIES
      MACOSX_BUNDLE TRUE
      MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist"
      OUTPUT_NAME "${_helper_output_name}"
  )

  add_dependencies(${EXECUTABLE_NAME} ${_helper_target})

  # Copy the helper bundle into the main app bundle after the main app links,
  # so the destination bundle already exists.
  add_custom_command(TARGET ${EXECUTABLE_NAME} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_directory
          "$<TARGET_BUNDLE_DIR:${_helper_target}>"
          "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}>/Contents/Frameworks/${_helper_output_name}.app"
      COMMENT "Copying ${_helper_output_name}.app into app bundle"
      VERBATIM
  )
endforeach()

# Copy CEF framework to app bundle
add_custom_command(TARGET ${EXECUTABLE_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CEF_ROOT}/Release/Chromium Embedded Framework.framework"
        "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}>/Contents/Frameworks/Chromium Embedded Framework.framework"
    COMMENT "Copying CEF framework to app bundle"
    VERBATIM
)
