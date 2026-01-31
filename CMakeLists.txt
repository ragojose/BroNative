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
set(CMAKE_EXE_LINKER_FLAGS_RELEASE "-flto")

# Strip symbols in Release
if(CMAKE_BUILD_TYPE STREQUAL "Release")
  set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-dead_strip")
endif()

# CEF binary distribution path
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/cef-project/third_party/cef/cef_binary_145.0.21+gd7459b1+chromium-145.0.7632.26_macosarm64_beta_minimal")

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
)

set(BRO_HELPER_SRCS
    src/process_helper_mac.cc
)

# Resources
set(BRO_RESOURCES_SRCS
    src/mac/Info.plist.in
)

# App bundle info
set(PRODUCT_NAME "Bro")
set(EXECUTABLE_NAME "Bro")

# Configure Info.plist
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/src/mac/Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    @ONLY
)

# Helper app Info.plist
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/src/mac/helper-Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/helper-Info.plist"
    @ONLY
)

# Main executable
add_executable(${EXECUTABLE_NAME} MACOSX_BUNDLE ${BRO_SRCS})

# Include directories
target_include_directories(${EXECUTABLE_NAME} PRIVATE
    ${CEF_ROOT}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Link libraries
target_link_libraries(${EXECUTABLE_NAME}
    libcef_dll_wrapper
    ${CEF_STANDARD_LIBS}
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
    MACOSX_BUNDLE_BUNDLE_VERSION "1.0.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    OUTPUT_NAME "Bro"
)

# Helper executable
add_executable(${EXECUTABLE_NAME}_Helper MACOSX_BUNDLE ${BRO_HELPER_SRCS})

target_include_directories(${EXECUTABLE_NAME}_Helper PRIVATE
    ${CEF_ROOT}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(${EXECUTABLE_NAME}_Helper
    libcef_dll_wrapper
    ${CEF_STANDARD_LIBS}
)

target_compile_options(${EXECUTABLE_NAME}_Helper PRIVATE
    ${CEF_CXX_COMPILER_FLAGS}
)

set_target_properties(${EXECUTABLE_NAME}_Helper PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/helper-Info.plist"
    OUTPUT_NAME "Bro Helper"
)

# Copy CEF framework to app bundle
add_custom_command(TARGET ${EXECUTABLE_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}>/Contents/Frameworks"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CEF_ROOT}/Release/Chromium Embedded Framework.framework"
        "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}>/Contents/Frameworks/Chromium Embedded Framework.framework"
    COMMENT "Copying CEF framework to app bundle"
)

# Copy helper apps to app bundle
add_custom_command(TARGET ${EXECUTABLE_NAME}_Helper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}>/Contents/Frameworks"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}_Helper>"
        "$<TARGET_BUNDLE_DIR:${EXECUTABLE_NAME}>/Contents/Frameworks/Bro Helper.app"
    COMMENT "Copying helper app to main bundle"
)

# Note: Helper variants will be copied manually after build
# Run: ./copy_helpers.sh after building

add_dependencies(${EXECUTABLE_NAME} ${EXECUTABLE_NAME}_Helper)
