#!/usr/bin/env bash
# example.sh — template for a per-tool build hook.
#
# Hooks run via the shell engine (`build/engine/build.sh`) with the manifest
# field:
#
#   hooks:
#     pre_configure:  ["bash \"$REPO_ROOT/build/hooks/my-tool.sh\""]
#     post_configure: [...]
#     pre_build:      [...]
#     post_build:     [...]
#     post_install:   [...]
#
# Contract:
#   * pre_configure runs with CWD = $SRC_DIR
#   * post_configure / pre_build / post_build / post_install run with CWD = $BUILD_DIR
#   * exported vars available: REPO_ROOT, SRC_DIR, BUILD_DIR, PREFIX,
#     ZIG_TARGET, ABI, CC, CXX, AR, RANLIB, CFLAGS, LDFLAGS, JOBS, TOOL_ID, ...
#
# This file is NOT referenced by tools.yml — it documents the mechanism.

set -euo pipefail

echo "example hook: cwd=$(pwd) tool=${TOOL_ID:-?} abi=${ABI:-?} prefix=${PREFIX:-?}"
