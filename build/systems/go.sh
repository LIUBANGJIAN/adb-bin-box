#!/usr/bin/env bash
# go.sh — driver for Go packages, cross-compiled with the host Go toolchain.
#
# No package currently uses this; it exists so that a Go-based CLI can be added
# to tools.yml without touching the engine (system_design.md §1.3).
#
# Requirements: SRC_DIR, BUILD_DIR, TOOL_BIN, ABI, MAKE_TARGETS[]

set -euo pipefail

driver_artifact_search_dir() { printf '%s' "$BUILD_DIR"; }

_go_arch() {
  case "$ABI" in
    arm64-v8a)   printf 'arm64' ;;
    armeabi-v7a) printf 'arm' ;;
    x86_64)      printf 'amd64' ;;
    x86)         printf '386' ;;
    *)           printf 'amd64' ;;
  esac
}

driver_configure() { :; }

driver_build() {
  require_cmd go
  cd "$SRC_DIR"
  export GOOS="${GOOS:-linux}"
  export GOARCH="$(_go_arch)"
  if [ "$GOARCH" = "arm" ]; then
    export GOARM="${GOARM:-7}"
  fi
  export CGO_ENABLED="${CGO_ENABLED:-0}"
  local out="$BUILD_DIR/$TOOL_BIN"
  log "go build: GOOS=$GOOS GOARCH=$GOARCH -> $out"
  go build -trimpath -o "$out" ./
}

driver_install() {
  # Go produces a single self-contained binary; "install" is a copy to PREFIX/bin
  # so that the default artifact rule (bin/<bin>) also works.
  mkdir -p "$PREFIX/bin"
  cp -f "$BUILD_DIR/$TOOL_BIN" "$PREFIX/bin/$TOOL_BIN"
  chmod +x "$PREFIX/bin/$TOOL_BIN"
}
