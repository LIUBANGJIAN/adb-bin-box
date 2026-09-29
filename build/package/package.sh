#!/usr/bin/env bash
# package.sh — collect built binaries and produce ONE archive per tool.
#
# Input : dist/<tool>/<abi>/<bin>   (produced by build.sh or downloaded artifacts)
# Output: <out>/
#   <tool>-<version>-android.tar.gz   <- ONE archive per tool, ABIs as subdirs:
#        README.txt
#        LICENSE-NOTICE.txt
#        SHA256SUMS            (sha256 of every binary inside the archive)
#        <abi>/<bin>           (only for ABIs that were actually built)
#   SHA256SUMS                            (global: sha256 of every archive)
#   manifest.json                         (ONE entry per tool: tool,version,abis[],file,size,sha256,binaries[])
#   adb-bin-box-<VERSION>-all.tar.gz       (everything above)
#
# A partial build (selective compilation) produces only the present tools/ABIs —
# nothing is fabricated for tools or ABIs that were not built.
#
# system_design.md §8 + §4.4.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=build/package/naming.sh
. "$SCRIPT_DIR/naming.sh"

DIST="$REPO_ROOT/dist"
OUT="$REPO_ROOT/dist/_packages"
VERSION=""
TOOLS_YML="$REPO_ROOT/tools.yml"
CLEAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dist)    DIST="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --tools)   TOOLS_YML="$2"; shift 2 ;;
    --clean)   CLEAN=1; shift ;;
    -h|--help)
      cat >&2 <<'EOF'
usage: package.sh [--dist <dir>] [--out <dir>] [--version <v>] [--tools tools.yml] [--clean]
EOF
      exit 0 ;;
    *) echo "package.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$VERSION" ] && [ -f "$REPO_ROOT/VERSION" ]; then
  VERSION="$(tr -d ' \t\r\n' <"$REPO_ROOT/VERSION")"
fi
[ -n "$VERSION" ] || { echo "package.sh: cannot determine VERSION (no VERSION file, no --version)" >&2; exit 1; }

PYTHON="${PYTHON:-$(command -v python3 || command -v python)}"
require() { command -v "$1" >/dev/null 2>&1 || { echo "package.sh: missing command: $1" >&2; exit 1; }; }
require tar
require sha256sum

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # absolute: subshells below chdir into a temp dir
if [ "$CLEAN" -eq 1 ]; then
  rm -f "$OUT"/*.tar.gz "$OUT/$(name_sha256sums)" "$OUT/$(name_manifest)" 2>/dev/null || true
fi

# --------------------------------------------------------------------------- #
# helpers reading tools.yml (source of truth for version / notes / repo)       #
# --------------------------------------------------------------------------- #
tool_field() {
  # tool_field <tool-id> <field>
  "$PYTHON" - "$TOOLS_YML" "$1" "$2" <<'PY'
import sys, yaml
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
want_id, field = sys.argv[2], sys.argv[3]
for tool in data.get("tools", []):
    if tool.get("id") == want_id:
        print(tool.get(field, ""))
        break
else:
    print("")
PY
}

tool_version() { tool_field "$1" version; }
tool_notes()   { tool_field "$1" notes; }
tool_repo()    { tool_field "$1" repo; }

# --------------------------------------------------------------------------- #
# ONE archive per tool                                                         #
# --------------------------------------------------------------------------- #
ASSETS=()
if [ ! -d "$DIST" ]; then
  echo "package.sh: dist directory not found: $DIST" >&2
  exit 1
fi

shopt -s nullglob
for tool_dir in "$DIST"/*/; do
  tool="$(basename "$tool_dir")"
  if [ "$tool" = "_packages" ]; then
    continue
  fi
  version="$(tool_version "$tool")"
  [ -n "$version" ] || version="0"
  # The registered binary name for this tool (tools.yml `bin`).  When present we
  # package ONLY that file per ABI — this keeps stray files (logs, notes, ...)
  # out of the archive AND keeps the ABI list from being appended once per file.
  want_bin="$(tool_field "$tool" bin)"

  stage="$(mktemp -d -t adbbinbox-pkg.XXXXXX)"
  abis_present=()
  picked_bins_present=()      # bin actually staged, parallel to abis_present
  bin_name="$want_bin"

  for abi_dir in "$tool_dir"*/; do
    abi="$(basename "$abi_dir")"
    # --- pick exactly ONE binary for this ABI (collected once per ABI dir) ----
    picked=""
    if [ -n "$want_bin" ] && [ -f "$abi_dir$want_bin" ]; then
      picked="$want_bin"
    else
      files=()
      for f in "$abi_dir"*; do
        [ -f "$f" ] || continue
        files+=("$(basename "$f")")
      done
      if [ "${#files[@]}" -eq 1 ]; then
        picked="${files[0]}"
        echo "package.sh: WARN $tool/$abi: registered bin '$want_bin' not found; falling back to the single file '$picked'" >&2
      elif [ "${#files[@]}" -eq 0 ]; then
        continue
      else
        echo "package.sh: WARN $tool/$abi: registered bin '$want_bin' not found and directory holds ${#files[@]} files (${files[*]}); skipping this ABI" >&2
        continue
      fi
    fi
    [ -n "$bin_name" ] || bin_name="$picked"
    mkdir -p "$stage/$abi"
    cp -f "$abi_dir$picked" "$stage/$abi/$picked"
    chmod +x "$stage/$abi/$picked"
    abis_present+=("$abi")
    picked_bins_present+=("$picked")
  done

  if [ "${#abis_present[@]}" -eq 0 ]; then
    rm -rf "$stage" 2>/dev/null || true
    continue
  fi

  # checksums of the included ABI binaries only (top-level files excluded),
  # verifiable with:  tar -xzf <pkg> && cd <dir> && sha256sum -c SHA256SUMS
  ( cd "$stage" && find . -mindepth 2 -type f -printf '%P\0' | sort -z | xargs -0 sha256sum ) >"$stage/$(name_sha256sums)"

  {
    printf 'adb-bin-box artifact\n'
    printf 'tool    : %s\n' "$tool"
    printf 'version : %s\n' "$version"
    printf 'binary  : %s\n' "$bin_name"
    printf 'abis    : %s\n' "${abis_present[*]}"
    printf 'packaged: with adb-bin-box %s\n\n' "$VERSION"
    printf 'This archive contains one directory per Android ABI. Install the\n'
    printf 'binary that matches the device (adb shell getprop ro.product.cpu.abi).\n\n'
    printf 'Install on device:\n'
    ridx=0
    for abi in "${abis_present[@]}"; do
      pbin="${picked_bins_present[$ridx]}"
      printf '  # %s\n' "$abi"
      printf '  adb push %s/%s /data/local/tmp/%s\n' "$abi" "$pbin" "$pbin"
      printf '  adb shell chmod +x /data/local/tmp/%s\n' "$pbin"
      ridx=$((ridx + 1))
    done
    printf '\nOr push the whole archive and unpack on the device:\n'
    printf '  adb push %s-%s-android.tar.gz /data/local/tmp/\n' "$tool" "$version"
    printf '  adb shell tar -xzf /data/local/tmp/%s-%s-android.tar.gz -C /data/local/tmp/\n' "$tool" "$version"
    printf '  adb shell chmod +x /data/local/tmp/*/%s\n' "$bin_name"
    printf '\nNotes:\n  %s\n' "$(tool_notes "$tool")"
  } >"$stage/README.txt"

  {
    printf 'LICENSE NOTICE\n'
    printf '==============\n'
    printf 'This archive redistributes compiled builds of "%s" (%s).\n' "$tool" "$version"
    printf 'Upstream source and licence terms: https://github.com/%s\n' "$(tool_repo "$tool")"
    printf 'Corresponding source is available from the upstream release locked in\n'
    printf 'tools.yml and from this repository history.\n'
  } >"$stage/LICENSE-NOTICE.txt"

  if [ -d "$REPO_ROOT/LICENSES/$tool" ]; then
    mkdir -p "$stage/LICENSES"
    cp -R "$REPO_ROOT/LICENSES/$tool" "$stage/LICENSES/"
  fi

  asset="$(name_tool_archive "$tool" "$version")"
  ( cd "$stage" && tar -czf "$OUT/$asset" . )

  # -------------------------------------------------------------------------
  # A2 guard: the binaries INSIDE the archive must carry the executable bit,
  # otherwise `adb push` + `chmod +x` on device is the only way to run them and
  # a silent permission regression could slip through CI unnoticed.
  #   * Linux   : tar records the POSIX mode verbatim -> assert mode has owner-x.
  #   * non-Linux (Windows/Git-Bash NTFS): the source fs has no POSIX execute
  #     bit, so `tar -tvf` would show -rw-r--r-- and the check is meaningless.
  #     We print a notice and DO NOT fail, to avoid local false alarms.
  # -------------------------------------------------------------------------
  if [ "$(uname -s)" = "Linux" ]; then
    guard_fail=0
    tar_listing="$(tar -tvf "$OUT/$asset")"
    idx=0
    for abi in "${abis_present[@]}"; do
      pbin="${picked_bins_present[$idx]}"
      member="./$abi/$pbin"
      mode="$(printf '%s\n' "$tar_listing" | awk -v m="$member" '$NF==m {print $1; exit}')" || true
      if [ -z "$mode" ]; then
        echo "package.sh: ERROR archive $asset: member $member missing" >&2
        guard_fail=1
      elif [ "${mode:3:1}" != "x" ]; then
        echo "package.sh: ERROR archive $asset: member $member is not executable (mode $mode)" >&2
        guard_fail=1
      fi
      idx=$((idx + 1))
    done
    if [ "$guard_fail" -ne 0 ]; then
      echo "package.sh: verify failed: non-executable binary inside $asset (exit 2)" >&2
      exit 2
    fi
  else
    echo "package.sh: notice: skipping archive execute-bit check on $(uname -s) (no POSIX modes on this filesystem)"
  fi

  rm -rf "$stage" 2>/dev/null || true

  ASSETS+=("$OUT/$asset")
  echo "packaged: $asset  (abis: ${abis_present[*]})"
  unset abis_present
done

if [ "${#ASSETS[@]}" -eq 0 ]; then
  echo "package.sh: no binaries found under $DIST" >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# manifest.json (one entry per tool)                                          #
# --------------------------------------------------------------------------- #
"$PYTHON" - "$OUT" "$DIST" "$VERSION" "$TOOLS_YML" <<'PY'
import datetime
import hashlib
import json
import os
import sys

out_dir, dist, version, tools_yml = sys.argv[1:5]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


versions, bins, order = {}, {}, []
try:
    import yaml
    with open(tools_yml, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    for tool in data.get("tools", []):
        versions[tool["id"]] = tool.get("version", "0")
        bins[tool["id"]] = tool.get("bin", "")
        order.append(tool["id"])
except Exception:
    pass

assets = []
tool_dirs = [d for d in os.listdir(dist)
             if os.path.isdir(os.path.join(dist, d)) and d != "_packages"]
tool_dirs.sort(key=lambda t: (order.index(t) if t in order else 999, t))

for tool in tool_dirs:
    tpath = os.path.join(dist, tool)
    ver = versions.get(tool, "0")
    want_bin = bins.get(tool, "")
    binaries, abis = [], []
    for abi in sorted(os.listdir(tpath)):
        apath = os.path.join(tpath, abi)
        if not os.path.isdir(apath):
            continue
        # Mirror package.sh: package ONLY the registered bin (or, as a fallback,
        # the sole regular file).  One entry per (abi, bin) — never one per file.
        if want_bin and os.path.isfile(os.path.join(apath, want_bin)):
            chosen = want_bin
        else:
            regular = sorted(
                f for f in os.listdir(apath)
                if os.path.isfile(os.path.join(apath, f)))
            if len(regular) != 1:
                continue
            chosen = regular[0]
        bpath = os.path.join(apath, chosen)
        binaries.append({
            "abi": abi,
            "bin": chosen,
            "sha256": sha256_file(bpath),
            "size": os.path.getsize(bpath),
        })
        if abi not in abis:
            abis.append(abi)
    if not binaries:
        continue
    abis.sort()
    archive = "%s-%s-android.tar.gz" % (tool, ver)
    archive_path = os.path.join(out_dir, archive)
    assets.append({
        "tool": tool,
        "version": ver,
        "abis": abis,
        "file": archive if os.path.isfile(archive_path) else None,
        "size": os.path.getsize(archive_path) if os.path.isfile(archive_path) else None,
        "sha256": sha256_file(archive_path) if os.path.isfile(archive_path) else None,
        "binaries": binaries,
    })

manifest = {
    "version": version,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "assets": assets,
}
with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8", newline="\n") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print("manifest.json: %d tool(s)" % len(assets))
PY

# --------------------------------------------------------------------------- #
# global SHA256SUMS + full bundle                                             #
# --------------------------------------------------------------------------- #
ALL_NAME="$(name_all "$VERSION")"
( cd "$OUT" && tar -czf "$ALL_NAME" $(ls -1 | grep -v "^$ALL_NAME\$") )

: >"$OUT/$(name_sha256sums)"
( cd "$OUT" && sha256sum *.tar.gz | sort -k2 ) >>"$OUT/$(name_sha256sums)"

echo "package.sh: wrote $(basename "$ALL_NAME") and $(name_sha256sums)"
