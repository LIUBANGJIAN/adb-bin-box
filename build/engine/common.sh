#!/usr/bin/env bash
# common.sh — shared helpers for the adb-bin-box build engine.
#
# Sourced by build.sh, deps.sh and every build-system driver.  It defines
# logging, source fetching, the *Zig environment contract* (system_design.md
# §3.6) and patch application.  No zig triple is ever hardcoded here: targets
# always arrive from build/verify/abi_matrix.json through manifest.py.
#
# NOTE: this file sets `set -euo pipefail` because it is always sourced by an
# executable entry point (never by an interactive shell).

set -euo pipefail

# --------------------------------------------------------------------------- #
# Paths                                                                        #
# --------------------------------------------------------------------------- #
# shellcheck disable=SC2128
COMMON_SH_PATH="${BASH_SOURCE[0]}"
COMMON_SH_DIR="$(cd "$(dirname "$COMMON_SH_PATH")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$COMMON_SH_DIR/../.." && pwd)"

ENGINE_DIR="$REPO_ROOT_DEFAULT/build/engine"
SYSTEMS_DIR="$REPO_ROOT_DEFAULT/build/systems"
VERIFY_DIR="$REPO_ROOT_DEFAULT/build/verify"
PACKAGE_DIR="$REPO_ROOT_DEFAULT/build/package"
GEN_DIR="$REPO_ROOT_DEFAULT/build/gen"
PATCHES_DIR="$REPO_ROOT_DEFAULT/patches"
HOOKS_DIR="$REPO_ROOT_DEFAULT/build/hooks"

MANIFEST_PY="$GEN_DIR/manifest.py"
GENERATE_MATRIX_PY="$GEN_DIR/generate_matrix.py"
ELF_CHECK_PY="$VERIFY_DIR/elf_check.py"
SMOKE_TEST_SH="$VERIFY_DIR/smoke_test.sh"
DETECT_ARTIFACT_SH="$ENGINE_DIR/detect-artifact.sh"
ABI_MATRIX_FILE="$VERIFY_DIR/abi_matrix.json"

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
DEFAULT_CFLAGS_DEFAULT="-O2 -fPIC"
DEFAULT_LDFLAGS_DEFAULT="-static"

# --------------------------------------------------------------------------- #
# Logging (all logs go to stderr so stdout stays machine-readable)             #
# --------------------------------------------------------------------------- #
LOG_PREFIX="${LOG_PREFIX:-[adb-bin-box]}"

log()  { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
warn() { printf '%s WARN: %s\n' "$LOG_PREFIX" "$*" >&2; }
die()  { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit "${DIE_CODE:-1}"; }

fail_build()  { DIE_CODE=1 die "$@"; }
fail_verify() { DIE_CODE=2 die "$@"; }
fail_smoke()  { DIE_CODE=3 die "$@"; }

# --------------------------------------------------------------------------- #
# Small utilities                                                             #
# --------------------------------------------------------------------------- #
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_python() {
  if [ -n "${PYTHON:-}" ]; then
    printf '%s' "$PYTHON"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    printf '%s' "$(command -v python)"
  else
    die "python3 not found on PATH (set PYTHON=...)"
  fi
}

cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 2
  else
    echo 2
  fi
}

# apply_kv <array-name> : export every 'KEY=VALUE' element of a nameref array.
apply_kv() {
  local name="$1"
  local -n arr="$name"
  local kv
  for kv in "${arr[@]+"${arr[@]}"}"; do
    [ -n "$kv" ] || continue
    export "$kv"
  done
}

# --------------------------------------------------------------------------- #
# Source acquisition                                                          #
# --------------------------------------------------------------------------- #
untar() {
  # untar <archive> <dest> <strip_components>
  local archive="$1" dest="$2" strip="${3:-1}"
  local flag=""
  case "$archive" in
    *.tar.gz | *.tgz)  flag="-z" ;;
    *.tar.xz | *.txz)  flag="-J" ;;
    *.tar.bz2 | *.tbz) flag="-j" ;;
    *.tar)             flag="" ;;
    *)                 flag="--auto-compress" ;;
  esac
  mkdir -p "$dest"
  # shellcheck disable=SC2086
  tar -xf "$archive" -C "$dest" --strip-components="$strip" $flag
}

clone_source() {
  # clone_source <url> <ref> <dest>
  local url="$1" ref="$2" dest="$3"
  require_cmd git
  if [ -n "$ref" ]; then
    git clone --depth 1 --branch "$ref" "$url" "$dest"
  else
    git clone --depth 1 "$url" "$dest"
  fi
}

fetch_source() {
  # fetch_source <type> <url> <tag> <strip> <dest> [<label>]
  local stype="$1" url="$2" tag="$3" strip="$4" dest="$5" label="${6:-source}"
  if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null || true)" ]; then
    log "$label: source already present at $dest (skip fetch)"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  case "$stype" in
    git)
      log "$label: git clone $url @ ${tag:-HEAD}"
      clone_source "$url" "$tag" "$dest"
      ;;
    local)
      [ -e "$url" ] || die "$label: local source '$url' does not exist"
      log "$label: copying local source $url"
      mkdir -p "$dest"
      cp -R "$url"/. "$dest"/
      ;;
    tarball | "")
      require_cmd curl
      local tmp
      tmp="$(mktemp -t adbbinbox.XXXXXX)"
      log "$label: downloading $url"
      curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 -o "$tmp" "$url"
      log "$label: extracting -> $dest (strip=$strip)"
      rm -rf "$dest"
      untar "$tmp" "$dest" "$strip"
      rm -f "$tmp"
      ;;
    *)
      die "$label: unsupported source.type '$stype'"
      ;;
  esac
}

# --------------------------------------------------------------------------- #
# Patches                                                                     #
# --------------------------------------------------------------------------- #
apply_patches() {
  # apply_patches <src_dir> <patch> [<patch> ...]
  local src_dir="$1"; shift
  local patch
  for patch in "$@"; do
    [ -n "$patch" ] || continue
    local path="$PATCHES_DIR/$patch"
    [ -f "$path" ] || die "patch not found: $path"
    log "applying patch $patch"
    ( cd "$src_dir" && patch -p1 --forward <"$path" )
  done
}

run_commands() {
  # run_commands <workdir> <cmd> [<cmd> ...]
  local workdir="$1"; shift
  local cmd
  for cmd in "$@"; do
    [ -n "$cmd" ] || continue
    log "run: $cmd"
    ( cd "$workdir" && bash -c "$cmd" )
  done
}

# --------------------------------------------------------------------------- #
# Zig environment contract (system_design.md §3.6)                            #
# --------------------------------------------------------------------------- #
write_config_site() {
  local site="$1"
  mkdir -p "$(dirname "$site")"
  cat >"$site" <<'EOF'
# adb-bin-box: preloaded autoconf cross results.
# Prevents the well-known "malloc(0) returns non-null" failures when
# cross-compiling with musl and skips several slow runtime checks.
ac_cv_func_malloc_0_nonnull=yes
ac_cv_func_realloc_0_nonnull=yes
ac_cv_func_mmap_fixed_mapped=yes
EOF
}

setup_zig_env() {
  # Requires: ZIG_TARGET, PREFIX, BUILD_DIR, (WORK_ROOT optional)
  local zig_bin
  zig_bin="${ZIG_BIN:-$(command -v zig || true)}"
  [ -n "$zig_bin" ] || die "zig not found on PATH (run build/local/install-zig.sh first)"
  export ZIG_BIN="$zig_bin"

  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${WORK_ROOT:-$PWD}/.zig-global}"
  export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-${WORK_ROOT:-$PWD}/.zig-local}"
  mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

  local ar ranlib strip
  ar="$(command -v llvm-ar || command -v ar || true)"
  ranlib="$(command -v llvm-ranlib || command -v ranlib || true)"
  strip="$(command -v llvm-strip || true)"
  [ -n "$ar" ] || die "no 'ar' found (needed to create static archives)"
  [ -n "$ranlib" ] || die "no 'ranlib' found"

  export CC="$zig_bin cc -target $ZIG_TARGET"
  export CXX="$zig_bin c++ -target $ZIG_TARGET"
  export AR="$ar"
  export RANLIB="$ranlib"
  export STRIP="${strip:-true}"
  export NM="$(command -v llvm-nm || command -v nm || echo true)"

  export CFLAGS="${CFLAGS:-${DEFAULT_CFLAGS:-$DEFAULT_CFLAGS_DEFAULT}}"
  export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"
  export LDFLAGS="${LDFLAGS:+$LDFLAGS }-static -L$PREFIX/lib"
  export CPPFLAGS="-I$PREFIX/include ${CPPFLAGS:-}"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export PKG_CONFIG="pkg-config --static"
  export CONFIG_SITE="$BUILD_DIR/config.site"
  write_config_site "$CONFIG_SITE"

  export AC_BUILD="${AC_BUILD:-$(uname -m)-pc-linux-gnu}"
  export JOBS="${JOBS:-$(cpu_count)}"

  log "zig: $zig_bin ($($zig_bin version 2>/dev/null || echo '?')) target=$ZIG_TARGET"
  log "zig cache: global=$ZIG_GLOBAL_CACHE_DIR local=$ZIG_LOCAL_CACHE_DIR"
}

# --------------------------------------------------------------------------- #
# Linux UAPI de-shadowing (system_design.md §3.6 addendum)                     #
# --------------------------------------------------------------------------- #
# mirror_fresh_uapi <fresh_root> [<fresh_root> ...]
#
# Some tools ship a *newer* snapshot of the Linux UAPI headers than the one zig
# 0.16.0 bundles.  strace is the canonical case: its build needs CLONE_AUTOREAP
# (defined in its bundled linux/sched.h, kernel 7.x) but zig's own copy of
# linux/sched.h predates it.  `configure` already puts the bundled roots on the
# compiler search path, but only as `-isystem`, and with that ordering zig's own
# libc copy still won the lookup (measured: "use of undeclared identifier
# 'CLONE_AUTOREAP'" survived those flags).  Rather than depend on include-path
# ordering, MIRROR the fresh files straight over zig's copies — order-independent
# and therefore the only reliable fix.
#
# Each <fresh_root> is relative to $SRC_DIR.  A root that does not exist (e.g.
# strace bundles no arch/x86 UAPI tree) is skipped with a warning; if NOTHING
# is mirrored at all we die, so a broken path can never silently no-op.
mirror_fresh_uapi() {
  [ "$#" -gt 0 ] || return 0
  local zig_bin="${ZIG_BIN:-$(command -v zig || true)}"
  [ -n "$zig_bin" ] || die "mirror_fresh_uapi: zig not found (ZIG_BIN unset)"
  local py
  py="$(resolve_python)"

  # `zig env` prints zig-object syntax (`.lib_dir = "..."`), not JSON — match
  # either form with a tolerant regex so this survives a future format change.
  local lib_dir
  lib_dir="$("$zig_bin" env 2>/dev/null | "$py" -c '
import re, sys
m = re.search(r"lib_dir\"?\s*[:=]\s*\"([^\"]+)\"", sys.stdin.read())
sys.stdout.write(m.group(1) if m else "")
' || true)"
  [ -n "$lib_dir" ] || die "mirror_fresh_uapi: could not read lib_dir from 'zig env'"
  local inc="$lib_dir/libc/include"
  [ -d "$inc" ] || die "mirror_fresh_uapi: zig libc include dir not found: $inc"

  local total_over=0 total_add=0
  local root fresh rel dest_dir parent
  for root in "$@"; do
    [ -n "$root" ] || continue
    fresh="$SRC_DIR/$root"
    if [ ! -d "$fresh" ]; then
      warn "mirror_fresh_uapi: root absent, skipping: $root"
      continue
    fi
    local n_over=0 n_add=0
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      for dest_dir in "$inc"/*/; do
        [ -d "$dest_dir" ] || continue
        if [ -e "${dest_dir}${rel}" ]; then
          cp -f "$fresh/$rel" "${dest_dir}${rel}"
          n_over=$((n_over + 1))
        else
          parent="$(dirname "${dest_dir}${rel}")"
          # Only add into a directory that already carries this header family;
          # an empty dir (e.g. an unused asm/ stub) is never populated, so the
          # generic "any" tree is not polluted with arch-specific headers.
          if [ -d "$parent" ] && [ -n "$(ls -A "$parent" 2>/dev/null || true)" ]; then
            cp -f "$fresh/$rel" "${dest_dir}${rel}"
            n_add=$((n_add + 1))
          fi
        fi
      done
    done < <(cd "$fresh" && find . -type f | sed 's|^\./||' | sort)
    if [ "$((n_over + n_add))" -eq 0 ]; then
      warn "mirror_fresh_uapi: root matched nothing in zig's include tree: $root"
    fi
    total_over=$((total_over + n_over))
    total_add=$((total_add + n_add))
    log "mirror_fresh_uapi: $root -> overridden=$n_over added=$n_add"
  done

  [ "$((total_over + total_add))" -gt 0 ] \
    || die "mirror_fresh_uapi: nothing mirrored (no fresh UAPI matched zig's include tree)"
  log "mirror_fresh_uapi: done overridden=$total_over added=$total_add"

  # Evidence line: prove the exact header the strace build tripped over is fresh.
  local probe="$inc/any-linux-any/linux/sched.h"
  if [ -f "$probe" ]; then
    log "mirror_fresh_uapi: CLONE_AUTOREAP in zig linux/sched.h = $(grep -c CLONE_AUTOREAP "$probe" 2>/dev/null || true)"
  fi
}
