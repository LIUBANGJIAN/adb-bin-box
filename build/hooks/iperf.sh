#!/usr/bin/env bash
# iperf.sh — pre_configure hook for iperf3.
#
# The iperf3 GitHub release tarball already ships a generated `configure`, so
# this hook is a safety net: if a future source snapshot lacks it, bootstrap the
# autotools files here.  It runs with CWD = the unpacked source tree ($SRC_DIR).
#
# Referenced from tools.yml:  hooks.pre_configure: ["bash \"$REPO_ROOT/build/hooks/iperf.sh\""]

set -euo pipefail

if [ -x ./configure ]; then
  echo "iperf hook: ./configure present, nothing to do"
  exit 0
fi

echo "iperf hook: ./configure missing -> running autoreconf -fi"
if ! command -v autoreconf >/dev/null 2>&1; then
  echo "iperf hook: ERROR autoreconf not found on PATH" >&2
  exit 1
fi
autoreconf -fi

[ -x ./configure ] || { echo "iperf hook: autoreconf did not produce ./configure" >&2; exit 1; }
echo "iperf hook: bootstrap complete"
