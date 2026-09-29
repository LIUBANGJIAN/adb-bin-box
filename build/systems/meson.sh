#!/usr/bin/env bash
# meson.sh — driver for Meson packages, cross-compiled via a generated Meson
# cross file that points at thin zig wrappers.
#
# No package currently uses this in Phase 1; provided for completeness
# (system_design.md §2).
#
# Requirements: SRC_DIR, BUILD_DIR, PREFIX, ZIG_TARGET, ZIG_BIN, AR, STRIP,
#               ABI, JOBS, CONFIGURE_FLAGS[]

set -euo pipefail

driver_artifact_search_dir() { printf '%s' "$PREFIX/bin"; }

_meson_cpu() {
  case "$ABI" in
    arm64-v8a)   printf 'aarch64|aarch64' ;;
    armeabi-v7a) printf 'arm|armv7' ;;
    x86_64)      printf 'x86_64|x86_64' ;;
    x86)         printf 'x86|i686' ;;
    *)           printf '%s|%s' "$ABI" "$ABI" ;;
  esac
}

_make_wrappers() {
  cat >"$BUILD_DIR/zig-cc" <<EOF
#!/bin/sh
exec "$ZIG_BIN" cc -target "$ZIG_TARGET" "\$@"
EOF
  cat >"$BUILD_DIR/zig-cxx" <<EOF
#!/bin/sh
exec "$ZIG_BIN" c++ -target "$ZIG_TARGET" "\$@"
EOF
  chmod +x "$BUILD_DIR/zig-cc" "$BUILD_DIR/zig-cxx"
}

driver_configure() {
  require_cmd meson
  require_cmd ninja
  mkdir -p "$BUILD_DIR"
  _make_wrappers
  local family cpu
  IFS='|' read -r family cpu <<<"$(_meson_cpu)"
  local cross="$BUILD_DIR/meson-cross.ini"
  cat >"$cross" <<EOF
[binaries]
c = '$BUILD_DIR/zig-cc'
cpp = '$BUILD_DIR/zig-cxx'
ar = '$AR'
strip = '$STRIP'

[host_machine]
system = 'linux'
cpu_family = '$family'
cpu = '$cpu'
endian = 'little'

[built-in options]
c_args = ['-O2', '-fPIC']
cpp_args = ['-O2', '-fPIC']
c_link_args = ['-static']
cpp_link_args = ['-static']
EOF
  cd "$BUILD_DIR"
  log "meson setup (cross=$cross prefix=$PREFIX)"
  meson setup builddir "$SRC_DIR" \
    --cross-file "$cross" \
    --prefix "$PREFIX" \
    --buildtype release \
    ${CONFIGURE_FLAGS[@]+"${CONFIGURE_FLAGS[@]}"}
}

driver_build() {
  cd "$BUILD_DIR"
  ninja -C builddir -j "$JOBS" \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"}
}

driver_install() {
  cd "$BUILD_DIR"
  meson install -C builddir
}
