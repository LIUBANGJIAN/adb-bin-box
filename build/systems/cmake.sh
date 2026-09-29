#!/usr/bin/env bash
# cmake.sh — driver for CMake packages, cross-compiled through a generated
# toolchain file (no package currently uses this in Phase 1; provided for
# completeness per system_design.md §2 / class-diagram BuildSystemDriver).
#
# Requirements: SRC_DIR, BUILD_DIR, PREFIX, ZIG_TARGET, ZIG_BIN, AR, RANLIB,
#               ABI, JOBS, CONFIGURE_FLAGS[], MAKE_TARGETS[]

set -euo pipefail

driver_artifact_search_dir() { printf '%s' "$PREFIX/bin"; }

_cmake_system_processor() {
  case "$ABI" in
    arm64-v8a)   printf '%s' "aarch64" ;;
    armeabi-v7a) printf '%s' "arm" ;;
    x86_64)      printf '%s' "x86_64" ;;
    x86)         printf '%s' "i686" ;;
    *)           printf '%s' "$ABI" ;;
  esac
}

_render_toolchain() {
  local out="$1" template="$CM_CMAKE_TOOLCHAIN_TEMPLATE"
  [ -f "$template" ] || die "cmake toolchain template missing: $template"
  sed \
    -e "s|@CMAKE_SYSTEM_PROCESSOR@|$(_cmake_system_processor)|g" \
    -e "s|@ZIG_BIN@|$ZIG_BIN|g" \
    -e "s|@ZIG_TARGET@|$ZIG_TARGET|g" \
    -e "s|@AR@|$AR|g" \
    -e "s|@RANLIB@|$RANLIB|g" \
    -e "s|@PREFIX@|$PREFIX|g" \
    "$template" >"$out"
}

driver_configure() {
  require_cmd cmake
  cmake="$(command -v cmake)"
  mkdir -p "$BUILD_DIR"
  local tc="$BUILD_DIR/toolchain.cmake"
  _render_toolchain "$tc"
  cd "$BUILD_DIR"
  log "cmake: src=$SRC_DIR prefix=$PREFIX toolchain=$tc"
  "$cmake" "$SRC_DIR" \
    -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$tc" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    ${CONFIGURE_FLAGS[@]+"${CONFIGURE_FLAGS[@]}"}
}

driver_build() {
  cd "$BUILD_DIR"
  log "cmake --build (jobs=$JOBS)"
  cmake --build . --parallel "$JOBS" \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"}
}

driver_install() {
  cd "$BUILD_DIR"
  log "cmake --install -> prefix=$PREFIX"
  cmake --install . --prefix "$PREFIX"
}

# Local var: cmake is resolved at configure time to avoid shadowing the command.
cmake=""
CM_CMAKE_TOOLCHAIN_TEMPLATE="$SYSTEMS_DIR/cmake-toolchain.cmake.in"
