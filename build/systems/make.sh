#!/usr/bin/env bash
# make.sh — driver for plain-Makefile packages (stress-ng) and for packages with
# a bespoke, non-autotools `configure` script (zlib).
#
# Behaviour:
#   * if CONFIGURE_COMMAND is set, it is executed first (e.g. zlib's ./configure);
#   * `make` runs MAKE_TARGETS with MAKE_ARGS;
#   * if MAKE_INSTALL_TARGET is empty the install step is skipped — the artifact
#     is then resolved straight out of the build dir (stress-ng).
#
# Requirements: PREFIX, SRC_DIR, BUILD_DIR, JOBS, CONFIGURE_COMMAND,
#               MAKE_TARGETS[], MAKE_ARGS[], MAKE_INSTALL_TARGET, MAKE_INSTALL_VARS[]

set -euo pipefail

driver_artifact_search_dir() { printf '%s' "$BUILD_DIR"; }

driver_configure() {
  cd "$BUILD_DIR"
  if [ -n "${CONFIGURE_COMMAND:-}" ]; then
    log "configure: $CONFIGURE_COMMAND"
    bash -c "$CONFIGURE_COMMAND"
  else
    log "no configure step for make-based package"
  fi
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
    log "no install target; artifact will be resolved from the build dir"
    return 0
  fi
  log "make $MAKE_INSTALL_TARGET -> prefix=$PREFIX"
  make \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"} \
    ${MAKE_INSTALL_VARS[@]+"${MAKE_INSTALL_VARS[@]}"} \
    "$MAKE_INSTALL_TARGET"
}
