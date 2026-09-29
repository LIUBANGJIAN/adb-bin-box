#!/usr/bin/env bash
# naming.sh — the single implementation of the artifact naming scheme.
#
# Releases ship ONE archive per tool (all ABIs as subdirectories) plus a global
# bundle; the per-(tool,abi) single-binary name is kept for reference/labels.
#   single binary  : <tool>-<version>-android-<abi>
#   tool archive   : <tool>-<version>-android.tar.gz        (ABIs as subdirs)
#   full bundle    : adb-bin-box-<VERSION>-all.tar.gz
#
# Sourced by package.sh (and anything else that needs a stable name).

set -euo pipefail

name_single() {
  # name_single <tool> <version> <abi>
  printf '%s-%s-android-%s' "$1" "$2" "$3"
}

name_archive() {
  # name_archive <tool> <version> <abi>
  printf '%s.tar.gz' "$(name_single "$1" "$2" "$3")"
}

name_tool_archive() {
  # name_tool_archive <tool> <version>  -- ONE archive per tool, ABIs as subdirs
  printf '%s-%s-android.tar.gz' "$1" "$2"
}

name_all() {
  # name_all <VERSION>
  printf 'adb-bin-box-%s-all.tar.gz' "$1"
}

name_sha256sums() { printf 'SHA256SUMS'; }
name_manifest()   { printf 'manifest.json'; }
