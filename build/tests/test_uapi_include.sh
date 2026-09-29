#!/usr/bin/env bash
# test_uapi_include.sh — unit test for the bundled-UAPI `-I` mechanism.
#
# This is the mechanism that replaced mirroring strace's fresh UAPI headers over
# zig's installation: the manifest declares `uapi_include` roots, setup_zig_env()
# prepends them to CPPFLAGS as plain `-I`, and build.sh asserts the flag really
# reached the generated Makefile.  Four properties are load-bearing, and none of
# them is observable from "the build succeeded":
#
#   1. manifest.py expands `${karch}` and refuses to emit a `uapi_include` entry
#      that still carries a literal '$' — an unexpanded `$SRC_DIR` would silently
#      become a bogus relative path in the compiler command line;
#   2. a non-anchor root that is absent is skipped WITHOUT failing the build
#      (strace 7.2 ships arch/arm64 only, so arm/x86 legitimately have no tree);
#   3. an absent ANCHOR root (entry #0) IS a hard error, so a typo cannot degrade
#      into a confusing undeclared-identifier failure much later;
#   4. the landing gate matches the `-I` spelling but NOT the `-isystem` one —
#      configure injects the very same path as `-isystem` by itself, so a bare
#      path-substring match would make the gate pass unconditionally.
#
# Usage: bash build/tests/test_uapi_include.sh   (exit 0 = all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
PYTHON="${PYTHON:-$(command -v python3 || command -v python || true)}"
if [ -z "$PYTHON" ]; then
  printf 'FATAL: neither python3 nor python is on PATH\n' >&2
  exit 1
fi

# shellcheck source=build/engine/common.sh
if ! . "$REPO_ROOT/build/engine/common.sh" >/dev/null 2>&1; then
  printf 'FATAL: cannot source %s\n' "$REPO_ROOT/build/engine/common.sh" >&2
  exit 1
fi
set +e  # common.sh enables -e; this harness inspects exit codes itself

FAILED=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1" >&2; FAILED=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

# run_flags <src_dir> <root>... -> prints one `-I...` flag per line.
# Runs in a subshell so uapi_include_flags()'s die cannot kill the harness.
run_flags() {
  (
    uapi_include_flags "$@" >/dev/null 2>&1 || exit $?
    if [ "${#UAPI_INCLUDE_FLAGS[@]}" -gt 0 ]; then
      printf '%s\n' "${UAPI_INCLUDE_FLAGS[@]}"
    fi
  )
}

# --------------------------------------------------------------------------- #
# 1. uapi_include is token-expanded and asserted '$'-free                      #
# --------------------------------------------------------------------------- #
for abi in arm64-v8a armeabi-v7a x86_64 x86; do
  case "$abi" in
    arm64-v8a)   karch=arm64 ;;
    armeabi-v7a) karch=arm ;;
    *)           karch=x86 ;;
  esac
  snippet="$("$PYTHON" "$REPO_ROOT/build/gen/manifest.py" shell \
      --tools "$REPO_ROOT/tools.yml" --deps "$REPO_ROOT/deps.yml" \
      --tool strace --abi "$abi" \
      --prefix /abs/prefix --src-dir /abs/src --build-dir /abs/build 2>/dev/null)"
  if [ -z "$snippet" ]; then
    bad "1: manifest.py shell produced nothing for strace/$abi"
    continue
  fi
  line="$(printf '%s\n' "$snippet" | grep '^UAPI_INCLUDE=' | head -1)"
  expected="UAPI_INCLUDE=('bundled/linux/include/uapi' 'bundled/linux/arch/$karch/include/uapi')"
  if [ "$line" != "$expected" ]; then
    bad "1: strace/$abi emitted '$line', expected '$expected'"
  elif printf '%s' "$line" | grep -q '\$'; then
    bad "1: literal '\$' survived expand_tokens() for strace/$abi: $line"
  else
    ok "1: UAPI_INCLUDE expanded (\${karch}=$karch), no '\$', for strace/$abi"
  fi
done

# Negative control: a deliberately unresolvable token must FAIL, not emit junk.
cat >"$TMP/deps.yml" <<'EOF'
version: 1
deps: []
EOF
cat >"$TMP/tools.yml" <<'EOF'
version: 1
tools:
  - id: probe
    version: "1"
    build_system: autotools
    source:
      type: tarball
      url: "https://example.invalid/probe-{version}.tar.gz"
    uapi_include: ["bundled/${unknown_token}/uapi"]
EOF
err="$("$PYTHON" "$REPO_ROOT/build/gen/manifest.py" shell \
    --tools "$TMP/tools.yml" --deps "$TMP/deps.yml" \
    --tool probe --abi arm64-v8a \
    --prefix /abs/prefix --src-dir /abs/src --build-dir /abs/build 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then
  bad "1: an unresolved \${unknown_token} was emitted instead of rejected"
elif ! printf '%s' "$err" | grep -q 'unresolved \$ token'; then
  bad "1: rejection happened but without the expected message: $err"
else
  ok "1: unresolved token in uapi_include is rejected"
fi

# --------------------------------------------------------------------------- #
# 2. absent non-anchor root => skipped, rc 0                                    #
# --------------------------------------------------------------------------- #
ANCHOR="$TMP/src-anchor"
mkdir -p "$ANCHOR/bundled/linux/include/uapi"
flags="$(run_flags "$ANCHOR" \
    "bundled/linux/include/uapi" "bundled/linux/arch/arm/include/uapi")"
rc=$?
n="$(printf '%s\n' "$flags" | grep -c '^-I')"
if [ "$rc" -ne 0 ]; then
  bad "2: absent non-anchor root made uapi_include_flags fail (rc=$rc)"
elif [ "$n" -ne 1 ]; then
  bad "2: expected exactly the anchor -I, got $n flag(s): $flags"
else
  ok "2: absent non-anchor root skipped without failing"
fi

# --------------------------------------------------------------------------- #
# 3. absent ANCHOR root => die                                                  #
# --------------------------------------------------------------------------- #
flags="$(run_flags "$ANCHOR" "bundled/linux/nonexistent/uapi" 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then
  bad "3: absent anchor root did not fail (flags=$flags)"
else
  ok "3: absent anchor root is a hard error (rc=$rc)"
fi

# --------------------------------------------------------------------------- #
# 4. landing gate matches `-I<...>bundled/...` but not `-isystem <...>bundled/...` #
# --------------------------------------------------------------------------- #
mkdir -p "$TMP/mk-positive" "$TMP/mk-negative"
printf 'CPPFLAGS = -I/abs/path/bundled/linux/include/uapi -isystem /abs/path/bundled/linux/include/uapi\n' \
  >"$TMP/mk-positive/Makefile"
printf 'CPPFLAGS = -isystem /abs/path/bundled/linux/include/uapi\n' \
  >"$TMP/mk-negative/Makefile"

uapi_include_landed "$TMP/mk-positive" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "4: gate rejects the -I spelling it is supposed to accept (rc=$rc)"
else
  ok "4: gate matches -I/abs/path/bundled/linux/include/uapi"
fi

uapi_include_landed "$TMP/mk-negative" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  bad "4: gate is satisfied by -isystem alone (it must not be)"
elif [ "$rc" -ne 1 ]; then
  bad "4: gate errored (rc=$rc) instead of reporting a clean no-match"
else
  ok "4: gate is NOT satisfied by -isystem <same path> (clean no-match)"
fi

# The same three outcomes through the wrapper build.sh actually calls, so the
# "declare no roots => no gate" shortcut is covered too.
(
  require_uapi_include_landed "$TMP/mk-positive" "bundled/linux/include/uapi"
) >/dev/null 2>&1
if [ $? -ne 0 ]; then
  bad "4: require_uapi_include_landed rejects a landed -I"
else
  ok "4: require_uapi_include_landed passes when the -I landed"
fi

(
  require_uapi_include_landed "$TMP/mk-negative" "bundled/linux/include/uapi"
) >/dev/null 2>&1
if [ $? -eq 0 ]; then
  bad "4: require_uapi_include_landed passed an -isystem-only Makefile"
else
  ok "4: require_uapi_include_landed dies on an -isystem-only Makefile"
fi

(
  require_uapi_include_landed "$TMP/mk-negative"
) >/dev/null 2>&1
if [ $? -ne 0 ]; then
  bad "4: require_uapi_include_landed gated a tool with no uapi_include roots"
else
  ok "4: no uapi_include roots => the gate is a no-op"
fi

# --------------------------------------------------------------------------- #
if [ "$FAILED" -eq 0 ]; then
  printf 'PASS test_uapi_include.sh\n'
else
  printf 'FAILED test_uapi_include.sh\n' >&2
fi
exit "$FAILED"
