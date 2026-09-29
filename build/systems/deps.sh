#!/usr/bin/env bash
# deps.sh — statically cross-compile a single dependency into $PREFIX.
#
# This is a mini build engine: it reuses common.sh + the same build-system
# drivers as the main tools, but reads its spec from deps.yml via
# `manifest.py dep-shell`.  Dependencies are always built *in-source* (BUILD_DIR
# == SRC_DIR) because that is the only mode ncurses/zlib reliably support.
#
# A per-(dep, abi) marker under $PREFIX/.deps makes repeat calls a no-op, which
# is what the CI prefix cache relies on (system_design.md §1.4 / §4.2).
#
# Exit codes: 0 ok, 1 build failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build/engine/common.sh
. "$SCRIPT_DIR/../engine/common.sh"

DEP_ID=""
ABI=""
MANIFEST="${MANIFEST:-$REPO_ROOT_DEFAULT/tools.yml}"
DEPS_MANIFEST="${DEPS_MANIFEST:-$REPO_ROOT_DEFAULT/deps.yml}"
PREFIX=""
WORK_ROOT="${WORK_ROOT:-${RUNNER_TEMP:-$REPO_ROOT_DEFAULT}/work}"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dep)    DEP_ID="$2"; shift 2 ;;
    --abi)    ABI="$2"; shift 2 ;;
    --tools)  MANIFEST="$2"; shift 2 ;;
    --deps)   DEPS_MANIFEST="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --work)   WORK_ROOT="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help)
      echo "usage: deps.sh --dep <id> --abi <abi> --prefix <dir> [--work <dir>] [--force]" >&2
      exit 0 ;;
    *) die "deps.sh: unknown argument: $1" ;;
  esac
done

[ -n "$DEP_ID" ] || die "deps.sh: --dep is required"
[ -n "$ABI" ]    || die "deps.sh: --abi is required"
[ -n "$PREFIX" ] || die "deps.sh: --prefix is required"
[ -f "$DEPS_MANIFEST" ] || die "deps.sh: deps manifest not found: $DEPS_MANIFEST"

LOG_PREFIX="[dep:$DEP_ID/$ABI]"
PYTHON="$(resolve_python)"

SRC_DIR="$WORK_ROOT/src/dep-$DEP_ID/$ABI"
BUILD_DIR="$SRC_DIR"
MARKER_DIR="$PREFIX/.deps"
MARKER="$MARKER_DIR/$DEP_ID.done"

mkdir -p "$PREFIX" "$MARKER_DIR"
if [ -f "$MARKER" ] && [ "$FORCE" -eq 0 ]; then
  log "dependency already built (marker: $MARKER) — cache hit"
  exit 0
fi

# --------------------------------------------------------------------------- #
# Load the dep spec from deps.yml                                              #
# --------------------------------------------------------------------------- #
DEP_CTX="$("$PYTHON" "$MANIFEST_PY" dep-shell \
  --tools "$MANIFEST" --deps "$DEPS_MANIFEST" \
  --dep "$DEP_ID" --abi "$ABI" \
  --prefix "$PREFIX" --src-dir "$SRC_DIR" --build-dir "$BUILD_DIR")"
# shellcheck disable=SC1090
eval "$DEP_CTX"

# map DEP_* -> the generic names the drivers consume
BUILD_SYSTEM="$DEP_BUILD_SYSTEM"
CONFIGURE_FLAGS=(${DEP_CONFIGURE_FLAGS[@]+"${DEP_CONFIGURE_FLAGS[@]}"})
CONFIGURE_COMMAND="${DEP_CONFIGURE_COMMAND:-}"
BOOTSTRAP_CMDS=(${DEP_BOOTSTRAP_CMDS[@]+"${DEP_BOOTSTRAP_CMDS[@]}"})
MAKE_TARGETS=(${DEP_MAKE_TARGETS[@]+"${DEP_MAKE_TARGETS[@]}"})
MAKE_INSTALL_TARGET="${DEP_MAKE_INSTALL_TARGET:-install}"
MAKE_INSTALL_VARS=(${DEP_MAKE_INSTALL_VARS[@]+"${DEP_MAKE_INSTALL_VARS[@]}"})
MAKE_ARGS=(${DEP_MAKE_ARGS[@]+"${DEP_MAKE_ARGS[@]}"})

log "building dep: system=$BUILD_SYSTEM version=$DEP_VERSION url=$DEP_SOURCE_URL"

mkdir -p "$SRC_DIR"
fetch_source "$DEP_SOURCE_TYPE" "$DEP_SOURCE_URL" "$DEP_SOURCE_TAG" \
  "$DEP_STRIP_COMPONENTS" "$SRC_DIR" "dep:$DEP_ID"

apply_kv DEP_ENV_KV
setup_zig_env

DRIVER_FILE="$SYSTEMS_DIR/$BUILD_SYSTEM.sh"
[ -f "$DRIVER_FILE" ] || die "no driver for dep build_system='$BUILD_SYSTEM'"
# shellcheck source=/dev/null
. "$DRIVER_FILE"

driver_configure
driver_build
driver_install

touch "$MARKER"
log "dependency installed into $PREFIX (provides: ${DEP_PROVIDES[*]:-n/a})"
