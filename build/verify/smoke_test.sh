#!/usr/bin/env bash
# smoke_test.sh — actually *run* a built binary and assert its behaviour.
#
# This turns "it compiled" into "it runs" (system_design.md §1.1 / §4.2):
#   * native ABIs (x86_64 / x86 on an x86_64 runner) execute directly;
#   * foreign ABIs execute through qemu-<arch>-static when it is installed, or
#     directly when binfmt_misc is registered (docker/setup-qemu-action does this
#     in CI, so the plain path works there too).
#
# Exit codes (engine semantics): 0 = ok/asserted, 3 = smoke failure, 2 = usage.
#
# Usage:
#   smoke_test.sh --bin <path> --abi <abi> [--arg ...] [--expect-exit N]
#                 [--contains SUBSTR] [--timeout SEC] [--allow-skip]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABI_MATRIX_FILE="$SCRIPT_DIR/abi_matrix.json"

BIN=""
ABI=""
EXPECT_EXIT=0
CONTAINS=""
TIMEOUT="${SMOKE_TIMEOUT:-60}"
ALLOW_SKIP=0
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --bin)         BIN="$2"; shift 2 ;;
    --abi)         ABI="$2"; shift 2 ;;
    --arg)         ARGS+=("$2"); shift 2 ;;
    --expect-exit) EXPECT_EXIT="$2"; shift 2 ;;
    --contains)    CONTAINS="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --allow-skip)  ALLOW_SKIP=1; shift ;;
    -h|--help)
      echo "usage: smoke_test.sh --bin <path> --abi <abi> [--arg ..] [--expect-exit N] [--contains S]" >&2
      exit 0 ;;
    *) echo "smoke_test.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$BIN" ] || { echo "smoke_test.sh: --bin is required" >&2; exit 2; }
[ -n "$ABI" ] || { echo "smoke_test.sh: --abi is required" >&2; exit 2; }
[ -f "$BIN" ] || { echo "smoke_test.sh: binary not found: $BIN" >&2; exit 3; }

PYTHON="${PYTHON:-$(command -v python3 || command -v python)}"
LOG_PREFIX="[smoke:$(basename "$BIN")/$ABI]"
log() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

# --------------------------------------------------------------------------- #
# ABI metadata (qemu binary + bits) — single source of truth                   #
# --------------------------------------------------------------------------- #
read_abi_field() {
  "$PYTHON" - "$ABI_MATRIX_FILE" "$ABI" "$1" <<'PY'
import json, sys
path, abi, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
entry = data.get(abi)
if entry is None:
    sys.stderr.write("unknown abi %r\n" % abi)
    sys.exit(2)
value = entry.get(field)
print("" if value is None else value)
PY
}

QEMU_BIN="$(read_abi_field qemu)"
[ -n "$QEMU_BIN" ] || QEMU_BIN=""

HOST_ARCH="$(uname -m)"

is_native() {
  case "$ABI" in
    x86_64) case "$HOST_ARCH" in x86_64|amd64) return 0 ;; esac ;;
    x86)    case "$HOST_ARCH" in x86_64|amd64|i686|x86) return 0 ;; esac ;;
  esac
  return 1
}

# --------------------------------------------------------------------------- #
# run + assert                                                                 #
# --------------------------------------------------------------------------- #
OUTPUT=""
RC=0

run_capture() {
  local -a cmd=("$@")
  if command -v timeout >/dev/null 2>&1; then
    cmd=(timeout "$TIMEOUT" "${cmd[@]}")
  fi
  log "exec: ${cmd[*]}"
  set +e
  OUTPUT="$("${cmd[@]}" 2>&1)"
  RC=$?
  set -e
}

if is_native; then
  log "native execution (host=$HOST_ARCH)"
  run_capture "$BIN" ${ARGS[@]+"${ARGS[@]}"}
else
  if command -v "$QEMU_BIN" >/dev/null 2>&1; then
    log "qemu execution via $QEMU_BIN"
    run_capture "$(command -v "$QEMU_BIN")" "$BIN" ${ARGS[@]+"${ARGS[@]}"}
  else
    log "qemu '$QEMU_BIN' not on PATH — trying binfmt direct execution"
    run_capture "$BIN" ${ARGS[@]+"${ARGS[@]}"}
    if [ "$RC" -eq 126 ] || [ "$RC" -eq 127 ]; then
      if [ "$ALLOW_SKIP" -eq 1 ]; then
        log "cannot execute foreign binary and --allow-skip set — SKIP"
        exit 0
      fi
      log "cannot execute foreign binary: no qemu/binfmt (install qemu-user-static)"
      exit 3
    fi
  fi
fi

head_out="$(printf '%s' "$OUTPUT" | head -n 3 | tr '\n' '|')"
log "exit=$RC output_head=$head_out"

if [ "$RC" -ne "$EXPECT_EXIT" ]; then
  log "FAIL: exit code $RC != expected $EXPECT_EXIT"
  printf '%s\n' "$OUTPUT" >&2
  exit 3
fi

if [ -n "$CONTAINS" ]; then
  if ! printf '%s' "$OUTPUT" | grep -Fq -- "$CONTAINS"; then
    log "FAIL: output does not contain '$CONTAINS'"
    printf '%s\n' "$OUTPUT" >&2
    exit 3
  fi
fi

log "SMOKE OK"
exit 0
