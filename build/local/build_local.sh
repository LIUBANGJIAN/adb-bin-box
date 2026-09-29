#!/usr/bin/env bash
# build_local.sh — reproduce the CI build on a workstation (system_design.md T05).
#
# Usage:
#   build_local.sh --tool curl --abi arm64-v8a [--dist <dir>] [--work <dir>]
#   build_local.sh --all [--abi <abi>]                  # every enabled tool
#
# It ensures a pinned Zig is available (installing it if needed), then delegates
# to the same build/engine/build.sh the CI uses — no forked logic.
#
# NOTE: cross-compiling needs only Zig (no gcc/make on the *host* is not
# required for the toolchain itself, but a Makefile-based package obviously
# still needs `make`).  For the autotools packages you also need the host
# autotools (make/autoconf/automake).  On a bare Windows/Git-Bash box only the
# Python/shell pieces are exercisable — that is expected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=build/engine/common.sh
. "$SCRIPT_DIR/../engine/common.sh"

TOOL=""
ABI=""
ALL=0
DIST="${DIST_DIR:-$REPO_ROOT/dist}"
WORK="${WORK_ROOT:-$REPO_ROOT/work}"
SKIP_SMOKE="${SKIP_SMOKE:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tool) TOOL="$2"; shift 2 ;;
    --abi)  ABI="$2"; shift 2 ;;
    --all)  ALL=1; shift ;;
    --dist) DIST="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --skip-smoke) SKIP_SMOKE=1; shift ;;
    -h|--help)
      cat >&2 <<'EOF'
usage: build_local.sh --tool <id> --abi <abi> [--dist DIR] [--work DIR] [--skip-smoke]
       build_local.sh --all [--abi <abi>]
EOF
      exit 0 ;;
    *) die "build_local.sh: unknown argument: $1" ;;
  esac
done

PYTHON="$(resolve_python)"
export MANIFEST="$REPO_ROOT/tools.yml"
export DEPS_MANIFEST="$REPO_ROOT/deps.yml"
export DIST_DIR="$DIST"
export WORK_ROOT="$WORK"

# --------------------------------------------------------------------------- #
# ensure zig (install if missing / mismatched version)                        #
# --------------------------------------------------------------------------- #
export ZIG_INSTALL_DIR="${ZIG_INSTALL_DIR:-$WORK/toolchains/zig}"
if ! command -v zig >/dev/null 2>&1; then
  log "zig not on PATH; installing $ZIG_VERSION into $ZIG_INSTALL_DIR"
  "$SCRIPT_DIR/install-zig.sh" --version "$ZIG_VERSION" --dir "$ZIG_INSTALL_DIR" --no-export
  export PATH="$ZIG_INSTALL_DIR:$PATH"
  export ZIG_BIN="$ZIG_INSTALL_DIR/zig"
fi

run_one() {
  local tool="$1" abi="$2"
  log "=== building $tool / $abi ==="
  local extra=()
  if [ "$SKIP_SMOKE" -eq 1 ]; then
    extra+=(--skip-smoke)
  fi
  "$REPO_ROOT/build/engine/build.sh" \
    --tool "$tool" --abi "$abi" \
    --manifest "$MANIFEST" --deps "$DEPS_MANIFEST" \
    --root "$REPO_ROOT" --work "$WORK" --dist "$DIST" \
    ${extra[@]+"${extra[@]}"}
}

if [ "$ALL" -eq 1 ]; then
  # expand the matrix and iterate over every enabled tool x abi
  MATRIX_JSON="$("$PYTHON" "$GENERATE_MATRIX_PY" "$MANIFEST" --deps "$DEPS_MANIFEST" \
    ${ABI:+--abis "$ABI"})"
  while IFS=$'\t' read -r tool abi; do
    [ -n "$tool" ] || continue
    run_one "$tool" "$abi"
  done < <(printf '%s' "$MATRIX_JSON" | "$PYTHON" -c '
import json, sys
data = json.load(sys.stdin)
for entry in data["include"]:
    print("%s\t%s" % (entry["tool_id"], entry["abi"]))
')
else
  [ -n "$TOOL" ] || die "build_local.sh: --tool is required (or use --all)"
  [ -n "$ABI" ]  || die "build_local.sh: --abi is required (or use --all)"
  run_one "$TOOL" "$ABI"
fi

log "build_local.sh: done"
