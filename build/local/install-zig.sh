#!/usr/bin/env bash
# install-zig.sh — install the pinned Zig toolchain and export its cache dirs.
#
# Zig is the *only* cross toolchain required (system_design.md F3): a single
# archive ships musl libc, compiler-rt and lld, so no third-party toolchain is
# ever downloaded (musl.cc is banned in CI — F2).
#
# Crucial: Zig must be able to write its caches, otherwise it dies with
# "unable to load 'std.zig': AccessDenied".  We therefore always export
# ZIG_GLOBAL_CACHE_DIR / ZIG_LOCAL_CACHE_DIR to writable locations (F3/§3.6).
#
# Usage:
#   install-zig.sh [--version 0.16.0] [--dir <install-dir>] [--host <zig-host>]
#                  [--force] [--print-url] [--no-export]
#
# In CI this writes $GITHUB_PATH / $GITHUB_ENV when those are set, so subsequent
# steps get zig and the cache dirs automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
INSTALL_DIR="${ZIG_INSTALL_DIR:-${RUNNER_TEMP:-$HOME/.local}/zig}"
HOST=""
FORCE=0
PRINT_URL=0
NO_EXPORT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)    ZIG_VERSION="$2"; shift 2 ;;
    --dir)        INSTALL_DIR="$2"; shift 2 ;;
    --host)       HOST="$2"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    --print-url)  PRINT_URL=1; shift ;;
    --no-export)  NO_EXPORT=1; shift ;;
    -h|--help)
      cat >&2 <<'EOF'
usage: install-zig.sh [--version 0.16.0] [--dir DIR] [--host OS-ARCH] [--force]
       [--print-url] [--no-export]
EOF
      exit 0 ;;
    *) echo "install-zig.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# host detection -> zig "os-arch" tokens                                       #
# --------------------------------------------------------------------------- #
detect_host() {
  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="macos" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) os="windows" ;;
    *)      os="linux" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l|armv7)  arch="arm" ;;
    i686|i386|x86) arch="x86" ;;
    *)             arch="x86_64" ;;
  esac
  printf '%s %s' "$os" "$arch"
}

read -r OS_NAME ARCH_NAME <<<"$(detect_host)"
if [ -n "$HOST" ]; then
  OS_NAME="${HOST%%-*}"
  ARCH_NAME="${HOST##*-}"
fi

case "$OS_NAME" in
  windows) EXT="zip"; ZIG_BIN_NAME="zig.exe" ;;
  *)       EXT="tar.xz"; ZIG_BIN_NAME="zig" ;;
esac

candidate_urls() {
  # new scheme (0.15+): zig-<arch>-<os>-<ver>
  printf '%s\n' "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH_NAME}-${OS_NAME}-${ZIG_VERSION}.${EXT}"
  # older scheme (<=0.14): zig-<os>-<arch>-<ver>
  printf '%s\n' "https://ziglang.org/download/${ZIG_VERSION}/zig-${OS_NAME}-${ARCH_NAME}-${ZIG_VERSION}.${EXT}"
  # very old: .tar.gz
  printf '%s\n' "https://ziglang.org/download/${ZIG_VERSION}/zig-${OS_NAME}-${ARCH_NAME}-${ZIG_VERSION}.tar.gz"
}

pick_url() {
  local url code
  while IFS= read -r url; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 30 "$url" || echo 000)"
    if [ "$code" = "200" ]; then
      printf '%s' "$url"
      return 0
    fi
  done < <(candidate_urls)
  return 1
}

# --------------------------------------------------------------------------- #
# reuse an already-installed matching zig                                      #
# --------------------------------------------------------------------------- #
BIN="$INSTALL_DIR/$ZIG_BIN_NAME"
if [ "$FORCE" -eq 0 ] && [ -x "$BIN" ]; then
  existing="$("$BIN" version 2>/dev/null || echo '?')"
  if [ "$existing" = "$ZIG_VERSION" ]; then
    echo "zig $ZIG_VERSION already installed at $BIN"
    URL=""
  else
    URL="$(pick_url)" || { echo "install-zig.sh: no downloadable zig $ZIG_VERSION for ${OS_NAME}-${ARCH_NAME}" >&2; exit 1; }
  fi
else
  URL="$(pick_url)" || { echo "install-zig.sh: no downloadable zig $ZIG_VERSION for ${OS_NAME}-${ARCH_NAME}" >&2; exit 1; }
fi

if [ "$PRINT_URL" -eq 1 ]; then
  if [ -n "$URL" ]; then
    echo "$URL"
  fi
  exit 0
fi

if [ -n "$URL" ]; then
  echo "downloading zig $ZIG_VERSION: $URL"
  mkdir -p "$INSTALL_DIR"
  TMP="$(mktemp -t zig.XXXXXX)"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 -o "$TMP" "$URL"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/_unpack"
  if [ "$EXT" = "zip" ]; then
    command -v unzip >/dev/null 2>&1 || { echo "install-zig.sh: unzip required for windows host" >&2; exit 1; }
    unzip -q "$TMP" -d "$INSTALL_DIR/_unpack"
  else
    tar -xf "$TMP" -C "$INSTALL_DIR/_unpack"
  fi
  # flatten the single top-level directory
  top="$(find "$INSTALL_DIR/_unpack" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [ -n "$top" ]; then
    mv "$top"/* "$INSTALL_DIR/" 2>/dev/null || true
  fi
  rm -rf "$INSTALL_DIR/_unpack" "$TMP"
  chmod +x "$INSTALL_DIR/$ZIG_BIN_NAME" 2>/dev/null || true
fi

[ -x "$INSTALL_DIR/$ZIG_BIN_NAME" ] || { echo "install-zig.sh: zig binary not found at $INSTALL_DIR/$ZIG_BIN_NAME" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# cache dirs (F3) + PATH export                                                #
# --------------------------------------------------------------------------- #
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${RUNNER_TEMP:-$INSTALL_DIR}/zig-cache-global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-${RUNNER_TEMP:-$INSTALL_DIR}/zig-cache-local}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

if [ "$NO_EXPORT" -eq 0 ]; then
  export PATH="$INSTALL_DIR:$PATH"
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$INSTALL_DIR" >>"$GITHUB_PATH"
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "ZIG_GLOBAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR"
      echo "ZIG_LOCAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR"
      echo "ZIG_VERSION=$ZIG_VERSION"
      echo "ZIG_BIN=$INSTALL_DIR/zig"
    } >>"$GITHUB_ENV"
  else
    # local usage: print values the caller can eval
    echo "export PATH=\"$INSTALL_DIR:\$PATH\""
    echo "export ZIG_GLOBAL_CACHE_DIR=\"$ZIG_GLOBAL_CACHE_DIR\""
    echo "export ZIG_LOCAL_CACHE_DIR=\"$ZIG_LOCAL_CACHE_DIR\""
    echo "export ZIG_VERSION=\"$ZIG_VERSION\""
  fi
fi

echo "zig $("$BIN" version) ready at $BIN"
echo "ZIG_GLOBAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR"
echo "ZIG_LOCAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR"
