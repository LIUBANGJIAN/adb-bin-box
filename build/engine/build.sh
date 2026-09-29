#!/usr/bin/env bash
# build.sh — the generic adb-bin-box build engine entry point.
#
# One invocation == one (tool, abi) build unit.  It is deliberately dumb about
# *what* it builds: every tool-specific decision lives in tools.yml and is
# pulled in through manifest.py.  See system_design.md §1.3 and §4.2.
#
# Exit codes (system_design.md §8):
#   0  success
#   1  build failure
#   2  verification (ELF gate) failure
#   3  smoke-test failure
#
# Usage:
#   build.sh --tool <id> --abi <abi> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build/engine/common.sh
. "$SCRIPT_DIR/common.sh"

# --------------------------------------------------------------------------- #
# Defaults / argument parsing                                                 #
# --------------------------------------------------------------------------- #
TOOL_ID=""
ABI=""
MANIFEST="${MANIFEST:-$REPO_ROOT_DEFAULT/tools.yml}"
DEPS_MANIFEST="${DEPS_MANIFEST:-$REPO_ROOT_DEFAULT/deps.yml}"
REPO_ROOT="$REPO_ROOT_DEFAULT"
WORK_ROOT="${WORK_ROOT:-${RUNNER_TEMP:-$REPO_ROOT}/work}"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
SKIP_SMOKE=0
SKIP_VERIFY=0

usage() {
  cat >&2 <<'EOF'
Usage: build.sh --tool <id> --abi <abi> [options]

Options:
  --tool <id>            tool id from tools.yml (required)
  --abi <abi>            Android ABI, e.g. arm64-v8a (required)
  --manifest <path>      path to tools.yml          (default: <root>/tools.yml)
  --deps <path>          path to deps.yml           (default: <root>/deps.yml)
  --root <path>          repository root            (default: script root)
  --work <path>          scratch work root          (default: $RUNNER_TEMP/work)
  --dist <path>          dist output root           (default: <root>/dist)
  --skip-verify          skip the ELF hard gate     (debug only)
  --skip-smoke           skip the QEMU smoke test   (debug only)
  -h, --help             show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tool)        TOOL_ID="$2"; shift 2 ;;
    --abi)         ABI="$2"; shift 2 ;;
    --manifest)    MANIFEST="$2"; shift 2 ;;
    --deps)        DEPS_MANIFEST="$2"; shift 2 ;;
    --root)        REPO_ROOT="$2"; shift 2 ;;
    --work)        WORK_ROOT="$2"; shift 2 ;;
    --dist)        DIST_DIR="$2"; shift 2 ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --skip-smoke)  SKIP_SMOKE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage; die "unknown argument: $1" ;;
  esac
done

[ -n "$TOOL_ID" ] || { usage; die "--tool is required"; }
[ -n "$ABI" ]     || { usage; die "--abi is required"; }
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

LOG_PREFIX="[$TOOL_ID/$ABI]"
PYTHON="$(resolve_python)"

# --------------------------------------------------------------------------- #
# Directory layout                                                            #
# --------------------------------------------------------------------------- #
SRC_DIR="$WORK_ROOT/src/$TOOL_ID/$ABI"
PREFIX="$WORK_ROOT/prefix/$ABI"
BUILD_DIR="$WORK_ROOT/build/$TOOL_ID/$ABI"
STAGING="$WORK_ROOT/out/$TOOL_ID/$ABI"
DIST_TOOL_DIR="$DIST_DIR/$TOOL_ID/$ABI"
RULES_FILE="$WORK_ROOT/out/$TOOL_ID/$ABI.rules"

emit_context() {
  "$PYTHON" "$MANIFEST_PY" shell \
    --tools "$MANIFEST" \
    --deps "$DEPS_MANIFEST" \
    --tool "$TOOL_ID" \
    --abi "$ABI" \
    --prefix "$PREFIX" \
    --src-dir "$SRC_DIR" \
    --build-dir "$BUILD_DIR"
}

log "work=$WORK_ROOT"
log "src=$SRC_DIR"
log "build=$BUILD_DIR"
log "prefix=$PREFIX"
log "dist=$DIST_TOOL_DIR"

mkdir -p "$WORK_ROOT" "$SRC_DIR" "$PREFIX" "$BUILD_DIR" "$STAGING" "$DIST_TOOL_DIR"
mkdir -p "$(dirname "$RULES_FILE")"

# --------------------------------------------------------------------------- #
# Load build context from the manifest (system_design.md §3.6)                 #
# --------------------------------------------------------------------------- #
# First pass: discover the build system so we can decide in-tree vs out-of-tree.
CTX="$(emit_context)"
# shellcheck disable=SC1090
eval "$CTX"

case "$BUILD_SYSTEM" in
  autotools | cmake | meson) OUT_OF_TREE=1 ;;
  *)                         OUT_OF_TREE=0 ;;
esac
if [ "$OUT_OF_TREE" -eq 0 ]; then
  # make/go/script build in-tree; the source dir doubles as the build dir.
  BUILD_DIR="$SRC_DIR"
  CTX="$(emit_context)"
  # shellcheck disable=SC1090
  eval "$CTX"
fi

log "system=$BUILD_SYSTEM out_of_tree=$OUT_OF_TREE bin=$TOOL_BIN deps=[${DEP_IDS[*]:-}]"

# Export the context so driver sub-shells and hooks can rely on it.
export REPO_ROOT SRC_DIR BUILD_DIR PREFIX ZIG_TARGET ABI TOOL_ID TOOL_BIN TOOL_VERSION

# --------------------------------------------------------------------------- #
# 1. Build static dependencies into $PREFIX (Tier 2)                           #
# --------------------------------------------------------------------------- #
for dep in "${DEP_IDS[@]+"${DEP_IDS[@]}"}"; do
  [ -n "$dep" ] || continue
  log "building dependency: $dep"
  bash "$SCRIPT_DIR/../systems/deps.sh" \
    --dep "$dep" \
    --abi "$ABI" \
    --tools "$MANIFEST" \
    --deps "$DEPS_MANIFEST" \
    --prefix "$PREFIX" \
    --work "$WORK_ROOT"
done

# --------------------------------------------------------------------------- #
# 2. Fetch the tool source                                                    #
# --------------------------------------------------------------------------- #
fetch_source "$TOOL_SOURCE_TYPE" "$TOOL_SOURCE_URL" "$TOOL_SOURCE_TAG" \
  "$TOOL_STRIP_COMPONENTS" "$SRC_DIR" "$TOOL_ID"

# --------------------------------------------------------------------------- #
# 3. Patches                                                                  #
# --------------------------------------------------------------------------- #
apply_patches "$SRC_DIR" "${PATCHES[@]+"${PATCHES[@]}"}"

# --------------------------------------------------------------------------- #
# 4. Environment (Zig contract) + per-tool env                                #
# --------------------------------------------------------------------------- #
# setup_zig_env() also prepends the manifest's `uapi_include` roots (strace's
# bundled Linux UAPI tree) to CPPFLAGS as `-I`, which is what actually wins the
# <linux/*.h> lookup against zig's own older, builtin copies.
apply_kv TOOL_ENV_KV
setup_zig_env

# --------------------------------------------------------------------------- #
# 5. Build via the build-system driver                                        #
# --------------------------------------------------------------------------- #
DRIVER_FILE="$SYSTEMS_DIR/$BUILD_SYSTEM.sh"
[ -f "$DRIVER_FILE" ] || die "no driver for build_system='$BUILD_SYSTEM'"
# shellcheck source=/dev/null
. "$DRIVER_FILE"

run_commands "$SRC_DIR" "${HOOK_PRE_CONFIGURE[@]+"${HOOK_PRE_CONFIGURE[@]}"}"
driver_configure
run_commands "$BUILD_DIR" "${HOOK_POST_CONFIGURE[@]+"${HOOK_POST_CONFIGURE[@]}"}"

# --------------------------------------------------------------------------- #
# 5b. UAPI -I landing gate                                                    #
# --------------------------------------------------------------------------- #
# Exporting CPPFLAGS is an intent, not evidence: configure is free to rewrite or
# drop it.  Since the missing flag only shows up much later as a confusing
# "use of undeclared identifier", assert it reached the generated Makefile —
# and assert the `-I` SPELLING, because the `-isystem` flags strace's configure
# adds by itself carry the very same path (see require_uapi_include_landed).
# No-op for every tool that does not declare `uapi_include`.
require_uapi_include_landed "$BUILD_DIR" ${UAPI_INCLUDE[@]+"${UAPI_INCLUDE[@]}"}
run_commands "$BUILD_DIR" "${HOOK_PRE_BUILD[@]+"${HOOK_PRE_BUILD[@]}"}"
driver_build
run_commands "$BUILD_DIR" "${HOOK_POST_BUILD[@]+"${HOOK_POST_BUILD[@]}"}"
driver_install
run_commands "$BUILD_DIR" "${HOOK_POST_INSTALL[@]+"${HOOK_POST_INSTALL[@]}"}"

# --------------------------------------------------------------------------- #
# 6. Locate + stage artifacts                                                 #
# --------------------------------------------------------------------------- #
{
  local_index=0
  for path in "${ARTIFACT_PATHS[@]+"${ARTIFACT_PATHS[@]}"}"; do
    bin_name="${ARTIFACT_BINS[$local_index]:-}"
    strip="${ARTIFACT_STRIP[$local_index]:-0}"
    required="${ARTIFACT_REQUIRED[$local_index]:-1}"
    printf '%s\t%s\t%s\t%s\n' "$path" "$bin_name" "$strip" "$required"
    local_index=$((local_index + 1))
  done
} >"$RULES_FILE"

log "resolving artifacts..."
ARTIFACT_LIST=""
if ! ARTIFACT_LIST="$(bash "$DETECT_ARTIFACT_SH" \
      --tool "$TOOL_ID" --abi "$ABI" --bin "$TOOL_BIN" \
      --prefix "$PREFIX" --build-dir "$BUILD_DIR" \
      --staging "$STAGING" --dist "$DIST_TOOL_DIR" \
      --rules-file "$RULES_FILE")"; then
  fail_build "artifact resolution failed"
fi

if [ -z "$ARTIFACT_LIST" ]; then
  fail_build "no artifacts were produced"
fi

log "artifacts:"
while IFS= read -r line; do
  if [ -n "$line" ]; then
    log "  $line"
  fi
done <<<"$ARTIFACT_LIST"

# --------------------------------------------------------------------------- #
# 7. ELF hard gate (exit 2)                                                    #
# --------------------------------------------------------------------------- #
if [ "$SKIP_VERIFY" -eq 0 ]; then
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    log "elf_check: $artifact (abi=$ABI)"
    if ! "$PYTHON" "$ELF_CHECK_PY" --abi "$ABI" "$artifact"; then
      fail_verify "ELF gate rejected $artifact"
    fi
  done <<<"$ARTIFACT_LIST"
else
  warn "ELF verification skipped (--skip-verify)"
fi

# --------------------------------------------------------------------------- #
# 8. Smoke test (exit 3)                                                       #
# --------------------------------------------------------------------------- #
if [ "$SKIP_SMOKE" -eq 0 ]; then
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    smoke_cmd=(bash "$SMOKE_TEST_SH" --bin "$artifact" --abi "$ABI"
               --expect-exit "$SMOKE_EXPECT_EXIT")
    for arg in "${SMOKE_ARGS[@]+"${SMOKE_ARGS[@]}"}"; do
      smoke_cmd+=(--arg "$arg")
    done
    if [ -n "$SMOKE_CONTAINS" ]; then
      smoke_cmd+=(--contains "$SMOKE_CONTAINS")
    fi
    log "smoke: ${smoke_cmd[*]}"
    if ! "${smoke_cmd[@]}"; then
      fail_smoke "smoke test failed for $artifact"
    fi
  done <<<"$ARTIFACT_LIST"
else
  warn "smoke test skipped (--skip-smoke)"
fi

log "BUILD OK  tool=$TOOL_ID abi=$ABI version=$TOOL_VERSION"
