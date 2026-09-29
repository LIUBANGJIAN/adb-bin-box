#!/usr/bin/env bash
# detect-artifact.sh — locate build products, rename, and stage into dist/.
#
# Reads a TSV rules file produced by build.sh (path, bin_name, strip, required)
# and resolves each rule against $PREFIX first, then $BUILD_DIR.  Every located
# file is copied to --staging and --dist (chmod +x) and its *dist* path is
# printed to stdout (one per line).  Logs go to stderr.
#
# A rule whose glob matches nothing aborts with exit 1 when required=1, and
# only warns when required=0.
#
# system_design.md §4.2 (ArtifactResolver).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build/engine/common.sh
. "$SCRIPT_DIR/common.sh"

shopt -s nullglob

TOOL_ID=""
ABI=""
BIN=""
PREFIX=""
BUILD_DIR=""
STAGING=""
DIST=""
RULES_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tool)       TOOL_ID="$2"; shift 2 ;;
    --abi)        ABI="$2"; shift 2 ;;
    --bin)        BIN="$2"; shift 2 ;;
    --prefix)     PREFIX="$2"; shift 2 ;;
    --build-dir)  BUILD_DIR="$2"; shift 2 ;;
    --staging)    STAGING="$2"; shift 2 ;;
    --dist)       DIST="$2"; shift 2 ;;
    --rules-file) RULES_FILE="$2"; shift 2 ;;
    *) die "detect-artifact.sh: unknown argument: $1" ;;
  esac
done

[ -n "$PREFIX" ] || die "detect-artifact.sh: --prefix is required"
[ -n "$STAGING" ] || die "detect-artifact.sh: --staging is required"
[ -n "$DIST" ] || die "detect-artifact.sh: --dist is required"
[ -n "$BIN" ] || die "detect-artifact.sh: --bin is required"
LOG_PREFIX="[$TOOL_ID/$ABI]"

mkdir -p "$STAGING" "$DIST"

# --------------------------------------------------------------------------- #
# determine the rules                                                          #
# --------------------------------------------------------------------------- #
RULES=()
if [ -n "$RULES_FILE" ] && [ -s "$RULES_FILE" ]; then
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      RULES+=("$line")
    fi
  done <"$RULES_FILE"
fi
if [ "${#RULES[@]}" -eq 0 ]; then
  # default: the installed binary in $PREFIX/bin
  RULES+=("bin/$BIN	$BIN	0	1")
fi

PRODUCED_FILE="$STAGING/.artifacts"
: >"$PRODUCED_FILE"

resolve_and_stage() {
  local rawpath="$1" bin_name="$2" strip="$3" required="$4"
  local candidates=()
  case "$rawpath" in
    /*) candidates=("$rawpath") ;;
    *)  candidates=("$PREFIX/$rawpath" "$BUILD_DIR/$rawpath") ;;
  esac

  local found="" pat f
  for pat in "${candidates[@]}"; do
    for f in $pat; do
      if [ -f "$f" ]; then found="$f"; break; fi
    done
    if [ -n "$found" ]; then
      break
    fi
  done

  if [ -z "$found" ]; then
    if [ "$required" = "1" ]; then
      die "required artifact not found: '$rawpath' (searched $PREFIX and $BUILD_DIR)"
    fi
    warn "optional artifact not found: '$rawpath' (skipped)"
    return 0
  fi

  local name="${bin_name:-$(basename "$found")}"
  local staged="$STAGING/$name"
  local disted="$DIST/$name"

  cp -f "$found" "$staged"
  chmod +x "$staged"

  if [ "$strip" = "1" ] && [ "${STRIP:-true}" != "true" ]; then
    log "stripping $name with $STRIP"
    "$STRIP" "$staged"
  fi

  cp -f "$staged" "$disted"
  chmod +x "$disted"

  printf '%s\n' "$disted" >>"$PRODUCED_FILE"
  printf '%s\n' "$disted"
}

log "staging artifacts (rules=${#RULES[@]})"
for rule in "${RULES[@]}"; do
  IFS=$'\t' read -r r_path r_bin r_strip r_required <<<"$rule"
  resolve_and_stage "${r_path:-}" "${r_bin:-}" "${r_strip:-0}" "${r_required:-1}"
done

log "staged $(wc -l <"$PRODUCED_FILE" | tr -d ' ') artifact(s)"
