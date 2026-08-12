# 3.24 for FetchContent's DOWNLOAD_EXTRACT_TIMESTAMP, used by the Sparkle fetch
# below. On 3.21-3.23 that keyword is unknown and configuring fails outright.
cmake_minimum_required(VERSION 3.24)
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

# CEF binary distribution version. Single source of truth for the pinned
# build — CI and README both derive their copy from this line by grepping it,
# so a bump here is a bump everywhere.
set(BRO_CEF_VERSION "cef_binary_151.3.16+gbe1e15d+chromium-151.0.7922.109_macosarm64_minimal")

# CEF binary distribution path
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/cef-project/third_party/cef/${BRO_CEF_VERSION}")

# Use C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Include CEF cmake helpers
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")

# Find CEF package
find_package(CEF REQUIRED)

# Add CEF library target
add_subdirectory(${CEF_ROOT}/libcef_dll libcef_dll_wrapper)

# Sparkle, for over-the-air updates. Fetched as the upstream prebuilt binary
# rather than built from source: the tarball is ~15 MB and ships the signed
# XPC services and Autoupdate helper that Sparkle needs at runtime. The hash is
# pinned so a swapped upstream artifact fails the build instead of shipping.
include(FetchContent)
set(SPARKLE_VERSION "2.9.5")
FetchContent_Declare(sparkle
    URL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    URL_HASH SHA256=015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc
    # FALSE per CMake's own guidance: extracted files get their extraction time
    # rather than the archive's, so dependency checking can't skip work it
    # should redo. Setting it either way silences the CMP0135 warning.
    DOWNLOAD_EXTRACT_TIMESTAMP FALSE
)
FetchContent_MakeAvailable(sparkle)
set(SPARKLE_FRAMEWORK "${sparkle_SOURCE_DIR}/Sparkle.framework")

# Source files
set(BRO_SRCS
    src/bro_app.cc
    src/bro_app.h
    src/bro_closed_tabs.h
    src/bro_closed_tabs.mm
    src/bro_downloads.mm
    src/bro_favicon.mm
    src/bro_find.h
    src/bro_find.mm
    src/bro_geometry.h
    src/bro_handler.cc
    src/bro_handler.h
    src/bro_handler_mac.mm
    src/bro_history.h
    src/bro_history.mm
    src/bro_mac.mm
    src/bro_mac_internal.h
    src/bro_motion.h
    src/bro_motion.mm
    src/bro_persist.h
    src/bro_persist.mm
    src/bro_palette.mm
    src/bro_tabstrip.mm
    src/bro_text_morph.h
    src/bro_text_morph.mm
    src/bro_toolbar.mm
    src/bro_updater.h
    src/bro_updater.mm
    src/browser_registry.cc
    src/browser_registry.h
    src/radix_icons.h
    src/radix_icons.mm
    src/tab_description_fetcher.cc
    src/tab_description_fetcher.h
    src/tab_thumbnail_fetcher.cc
    src/tab_thumbnail_fetcher.h
)

set(BRO_HELPER_SRCS
    src/process_helper_mac.cc
)

# Bundle resources
set(BRO_RESOURCES
    src/mac/bro.icns
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

# Toolbar/tab-strip icons, loaded at runtime by radix_icons.mm.
set(BRO_ICON_RESOURCES
    src/mac/icons/arrow-left.pdf
    src/mac/icons/arrow-right.pdf
    src/mac/icons/arrow-up.pdf
    src/mac/icons/arrow-down.pdf
    src/mac/icons/reload.pdf
    src/mac/icons/plus.pdf
    src/mac/icons/cross-2.pdf
    src/mac/icons/desktop.pdf
    src/mac/icons/mobile.pdf
    src/mac/icons/globe.pdf
    src/mac/icons/drawing-pin.pdf
    src/mac/icons/drawing-pin-filled.pdf
    src/mac/icons/view-vertical.pdf
    src/mac/icons/download.pdf
    src/mac/icons/magnifying-glass.pdf
    src/mac/icons/chevron-down.pdf
)
set_source_files_properties(${BRO_ICON_RESOURCES} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources/Icons"
)

# App bundle info
# PRODUCT_NAME is the user-visible app/bundle name; EXECUTABLE_NAME stays
# space-free because it doubles as the CMake target name.
set(PRODUCT_NAME "Bro Computer")
set(EXECUTABLE_NAME "Bro")
# Marketing version, shown to people. Bump by hand for a real release.
set(VERSION_SHORT "1.0.0")

# Build number, shown to nobody but compared by Sparkle. This MUST increase on
# every published build or the updater will never offer an update, so it is
# derived from the commit count rather than hand-maintained. Requires full
# history: a shallow clone always counts 1, which is why CI checks out with
# fetch-depth 0.
set(VERSION_BUILD "0")
find_package(Git QUIET)
if(GIT_FOUND AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git")
  execute_process(
      COMMAND "${GIT_EXECUTABLE}" rev-list --count HEAD
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      OUTPUT_VARIABLE VERSION_BUILD
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
  )
endif()
if(NOT VERSION_BUILD MATCHES "^[0-9]+$")
  set(VERSION_BUILD "0")
endif()
if(VERSION_BUILD STREQUAL "0")
  # Building from a source archive rather than a checkout. Harmless locally, but
  # such a build reports version 0 and must never be published: Sparkle would
  # read it as older than everything already released.
  message(WARNING
      "No git history found — CFBundleVersion is 0. Fine for a local build; "
      "do not distribute it. Build from a full clone to get a real version.")
endif()
message(STATUS "Bro version ${VERSION_SHORT} (build ${VERSION_BUILD})")

# Configure Info.plist
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/src/mac/Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    @ONLY
)

# Main executable
add_executable(${EXECUTABLE_NAME} MACOSX_BUNDLE ${BRO_SRCS} ${BRO_RESOURCES}
               ${BRO_FONT_RESOURCES} ${BRO_ICON_RESOURCES})

# Include directories
target_include_directories(${EXECUTABLE_NAME} PRIVATE
    ${CEF_ROOT}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Link libraries. Sparkle is found via -F at link time and via the @executable_path
# rpath below at runtime, once it has been copied into Contents/Frameworks.
target_link_libraries(${EXECUTABLE_NAME}
    libcef_dll_wrapper
    ${CEF_STANDARD_LIBS}
    "-framework QuartzCore"
    "-framework ImageIO"
    "-F${sparkle_SOURCE_DIR}"
    "-framework Sparkle"
)

# Compile flags. The -F lets `#import <Sparkle/Sparkle.h>` resolve; linking
# needs its own copy of the same flag above.
target_compile_options(${EXECUTABLE_NAME} PRIVATE
    ${CEF_CXX_COMPILER_FLAGS}
    -fobjc-arc
    "-F${sparkle_SOURCE_DIR}"
)

# Set bundle properties
set_target_properties(${EXECUTABLE_NAME} PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.bro.browser"
    MACOSX_BUNDLE_BUNDLE_NAME "${PRODUCT_NAME}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${VERSION_BUILD}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${VERSION_SHORT}"
    OUTPUT_NAME "${PRODUCT_NAME}"
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "@executable_path/../Frameworks"
)

# Helper apps. Chromium on macOS launches subprocesses from helper bundles with
# exact names derived from the app name: "Bro Computer Helper.app",
# "Bro Computer Helper (Alerts).app", "(GPU)", "(Plugin)", "(Renderer)". CEF_HELPER_APP_SUFFIXES
# (from cef_variables.cmake) enumerates them as "<name suffix>:<target suffix>:<plist suffix>".
foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" _suffix_list ${_suffix_list})
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)

  set(_helper_target "${EXECUTABLE_NAME}_Helper${_target_suffix}")
  set(_helper_output_name "${PRODUCT_NAME} Helper${_name_suffix}")

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

# Copy Sparkle into the app bundle. Uses ditto rather than `cmake -E
# copy_directory` on purpose: Sparkle is a versioned framework (Versions/B plus
# Current/Resources/Headers symlinks) and copy_directory dereferences symlinks,
# which both bloats the bundle and produces a layout codesign rejects.
add_custom_command(TARGET ${EXECUTABLE_NAME} POST_BUILD
    COMMAND ditto
        "${SPARKLE_FRAMEWORK}"
        "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}>/Contents/Frameworks/Sparkle.framework"
    COMMENT "Copying Sparkle framework to app bundle"
    VERBATIM
)
