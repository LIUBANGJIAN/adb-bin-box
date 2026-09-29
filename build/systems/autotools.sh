#!/usr/bin/env bash
# autotools.sh — driver for packages using the GNU autotools (./configure && make).
#
# Interface (consumed by build.sh / deps.sh):
#   driver_configure / driver_build / driver_install
#
# Requirements: ZIG_TARGET, PREFIX, SRC_DIR, BUILD_DIR, AC_BUILD, JOBS,
#               CONFIGURE_FLAGS[], BOOTSTRAP_CMDS[], MAKE_TARGETS[],
#               MAKE_ARGS[], MAKE_INSTALL_TARGET, MAKE_INSTALL_VARS[]
#
# Out-of-tree (VPATH) builds are used so $SRC_DIR stays pristine.

set -euo pipefail

driver_artifact_search_dir() { printf '%s' "$PREFIX/bin"; }

run_autotools_bootstrap() {
  if [ -x "$SRC_DIR/configure" ]; then
    return 0
  fi
  if [ "${#BOOTSTRAP_CMDS[@]}" -gt 0 ]; then
    log "bootstrap: running manifest-defined bootstrap commands"
    run_commands "$SRC_DIR" "${BOOTSTRAP_CMDS[@]}"
  elif [ -f "$SRC_DIR/configure.ac" ] || [ -f "$SRC_DIR/configure.in" ]; then
    log "bootstrap: no configure, running 'autoreconf -fi'"
    require_cmd autoreconf
    ( cd "$SRC_DIR" && autoreconf -fi )
  else
    die "no ./configure in $SRC_DIR and no configure.bootstrap defined"
  fi
}

driver_configure() {
  run_autotools_bootstrap
  local cfg="$SRC_DIR/configure"
  [ -x "$cfg" ] || die "configure not executable after bootstrap: $cfg"

  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  log "configure: host=$ZIG_TARGET build=$AC_BUILD prefix=$PREFIX"
  "$cfg" \
    --host="$ZIG_TARGET" \
    --build="$AC_BUILD" \
    --prefix="$PREFIX" \
    ${CONFIGURE_FLAGS[@]+"${CONFIGURE_FLAGS[@]}"}
}

driver_build() {
  cd "$BUILD_DIR"
  log "make targets=[${MAKE_TARGETS[*]:-all}] jobs=$JOBS"
  make -j"$JOBS" \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"} \
    ${MAKE_TARGETS[@]+"${MAKE_TARGETS[@]}"}
}

driver_install() {
  cd "$BUILD_DIR"
  if [ -z "${MAKE_INSTALL_TARGET:-}" ]; then
    log "no install target; skipping install"
    return 0
  fi
  log "make $MAKE_INSTALL_TARGET -> prefix=$PREFIX"
  make \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"} \
    ${MAKE_INSTALL_VARS[@]+"${MAKE_INSTALL_VARS[@]}"} \
    "$MAKE_INSTALL_TARGET"
}
