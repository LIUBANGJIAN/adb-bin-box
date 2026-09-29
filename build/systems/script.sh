#!/usr/bin/env bash
# script.sh — driver for packages with a bespoke build flow that is expressed as
# a raw command in the manifest (e.g. OpenSSL's ./Configure in Phase 2).
#
# CONFIGURE_COMMAND is evaluated verbatim; MAKE_TARGETS/MAKE_ARGS drive `make`,
# and MAKE_INSTALL_TARGET (when non-empty) runs the install step.
#
# Requirements: SRC_DIR, BUILD_DIR, PREFIX, JOBS, CONFIGURE_COMMAND,
#               MAKE_TARGETS[], MAKE_ARGS[], MAKE_INSTALL_TARGET, MAKE_INSTALL_VARS[]

set -euo pipefail

driver_artifact_search_dir() { printf '%s' "$PREFIX/bin"; }

driver_configure() {
  cd "$BUILD_DIR"
  if [ -z "${CONFIGURE_COMMAND:-}" ]; then
    warn "script driver: empty CONFIGURE_COMMAND (nothing to do)"
    return 0
  fi
  log "script configure: $CONFIGURE_COMMAND"
  bash -c "$CONFIGURE_COMMAND"
}

driver_build() {
  cd "$BUILD_DIR"
  if [ "${#MAKE_TARGETS[@]}" -eq 0 ]; then
    warn "script driver: no make targets; skipping build"
    return 0
  fi
  log "make targets=[${MAKE_TARGETS[*]}] jobs=$JOBS"
  make -j"$JOBS" \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"} \
    ${MAKE_TARGETS[@]+"${MAKE_TARGETS[@]}"}
}

driver_install() {
  cd "$BUILD_DIR"
  if [ -z "${MAKE_INSTALL_TARGET:-}" ]; then
    log "script driver: no install target; artifact resolved from build dir"
    return 0
  fi
  log "make $MAKE_INSTALL_TARGET -> prefix=$PREFIX"
  make \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"} \
    ${MAKE_INSTALL_VARS[@]+"${MAKE_INSTALL_VARS[@]}"} \
    "$MAKE_INSTALL_TARGET"
}
