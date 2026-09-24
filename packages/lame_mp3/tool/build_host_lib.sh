#!/usr/bin/env bash
# Builds the native library for the host (Linux, or macOS) from
# src/CMakeLists.txt into build/host/ and prints the absolute path of the
# resulting shared library on stdout (build logs go to stderr), so that it can
# be used as
#
#   LAME_MP3_LIBRARY="$(tool/build_host_lib.sh)" flutter test
#
# The test suite also finds build/host/ on its own, so after running this
# script once a plain `flutter test` works as well.
#
# Environment: CMAKE_BUILD_TYPE (default Debug; LAME is built with -O2 in all
# build types), CMAKE_GENERATOR (default: Ninja if installed).
# LAME's internal assert()s are enabled in this build (they are compiled out
# in the Android/iOS app builds).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${package_dir}/build/host"

generator_args=()
if [[ -z "${CMAKE_GENERATOR:-}" ]] && command -v ninja >/dev/null 2>&1; then
  generator_args=(-G Ninja)
fi

cmake -S "${package_dir}/src" -B "${build_dir}" "${generator_args[@]}" \
  -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Debug}" \
  -DLAME_MP3_ENABLE_ASSERTS=ON >&2
cmake --build "${build_dir}" >&2

case "$(uname -s)" in
  Darwin) lib_name="liblame_mp3.dylib" ;;
  *) lib_name="liblame_mp3.so" ;;
esac
lib_path="${build_dir}/${lib_name}"
if [[ ! -f "${lib_path}" ]]; then
  echo "error: expected ${lib_path} after the build" >&2
  exit 1
fi
echo "${lib_path}"
