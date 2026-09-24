# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
# 3.13: target_link_options (16 KB page alignment below).
cmake_minimum_required(VERSION 3.13)

project(lame_mp3_library VERSION 0.1.0 LANGUAGES C)

# Keep LAME's assert() checks. Off by default (NDEBUG is defined for LAME in
# every build type, as for the iOS pod); the host test build turns it on.
option(LAME_MP3_ENABLE_ASSERTS "Compile the vendored LAME sources with assert() enabled" OFF)

set(LAME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lame")

# Vendored LAME 4.0 encoder (see lame/PATCHES.md). Listed explicitly so that
# the file list stays in sync with the iOS forwarders in ios/Classes.
set(LAME_SOURCES
  "${LAME_DIR}/libmp3lame/VbrTag.c"
  "${LAME_DIR}/libmp3lame/bitstream.c"
  "${LAME_DIR}/libmp3lame/encoder.c"
  "${LAME_DIR}/libmp3lame/fft.c"
  "${LAME_DIR}/libmp3lame/gain_analysis.c"
  "${LAME_DIR}/libmp3lame/id3tag.c"
  "${LAME_DIR}/libmp3lame/lame.c"
  "${LAME_DIR}/libmp3lame/newmdct.c"
  "${LAME_DIR}/libmp3lame/presets.c"
  "${LAME_DIR}/libmp3lame/psymodel.c"
  "${LAME_DIR}/libmp3lame/quantize.c"
  "${LAME_DIR}/libmp3lame/quantize_pvt.c"
  "${LAME_DIR}/libmp3lame/reservoir.c"
  "${LAME_DIR}/libmp3lame/set_get.c"
  "${LAME_DIR}/libmp3lame/tables.c"
  "${LAME_DIR}/libmp3lame/takehiro.c"
  "${LAME_DIR}/libmp3lame/util.c"
  "${LAME_DIR}/libmp3lame/vbrquantize.c"
  "${LAME_DIR}/libmp3lame/version.c"
)

add_library(lame_mp3 SHARED
  "lame_mp3.c"
  ${LAME_SOURCES}
)

set_target_properties(lame_mp3 PROPERTIES
  PUBLIC_HEADER lame_mp3.h
  OUTPUT_NAME "lame_mp3"
  # Export only the FFI_PLUGIN_EXPORT functions of the wrapper.
  C_VISIBILITY_PRESET hidden
)

target_include_directories(lame_mp3 PRIVATE
  "${LAME_DIR}"               # config.h
  "${LAME_DIR}/include"       # lame.h
  "${LAME_DIR}/libmp3lame"
)

target_compile_definitions(lame_mp3 PUBLIC DART_SHARED_LIB)
target_compile_definitions(lame_mp3 PRIVATE HAVE_CONFIG_H)

# Always optimise: LAME at -O0 (Debug builds) is several times slower. This
# comes after the build-type flags on the command line, so it wins.
target_compile_options(lame_mp3 PRIVATE -O2)

if (LAME_MP3_ENABLE_ASSERTS)
  target_compile_options(lame_mp3 PRIVATE -UNDEBUG)
else()
  target_compile_definitions(lame_mp3 PRIVATE NDEBUG)
endif()

# LAME is third-party code written for much older compilers; silence its
# warnings but keep them for the wrapper.
set_source_files_properties(${LAME_SOURCES} PROPERTIES COMPILE_FLAGS "-w")

if (NOT APPLE)
  # libm; LAME uses pow/log/exp/... (the NDK links it implicitly as well).
  target_link_libraries(lame_mp3 PRIVATE m)
  # Fail the link on unresolved symbols, and let the linker drop LAME code
  # that the wrapper can never reach (decoder stubs, ID3 API, ...).
  target_compile_options(lame_mp3 PRIVATE -ffunction-sections -fdata-sections)
  target_link_libraries(lame_mp3 PRIVATE "-Wl,--no-undefined" "-Wl,--gc-sections")
endif()

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(lame_mp3 PRIVATE "-Wl,-z,max-page-size=16384")
endif()
