#!/usr/bin/env bash
# release_notes.sh — render the GitHub Release body (Markdown).
#
# Every release is documented from the packaged artifacts themselves, so the
# notes can never drift from what was actually uploaded.  It lists, per library
# (one archive per library), both the *direct* GitHub URL and the *accelerated*
# URL obtained by prefixing the well-known proxy https://gh-proxy.com/ in front
# of the full GitHub URL.
#
# Usage:
#   release_notes.sh --packages <dir> --repo <owner/repo> --tag <tag> \
#                    --version <VERSION> --out <file> [--proxy https://gh-proxy.com/]
#
# The <dir> should contain manifest.json (produced by package.sh); if it is
# missing we degrade to scanning *.tar.gz.

set -euo pipefail

PACKAGES=""
REPO=""
TAG=""
VERSION=""
OUT=""
PROXY="https://gh-proxy.com/"

while [ $# -gt 0 ]; do
  case "$1" in
    --packages) PACKAGES="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --tag)      TAG="$2"; shift 2 ;;
    --version)  VERSION="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --proxy)    PROXY="$2"; shift 2 ;;
    -h|--help)
      cat >&2 <<'EOF'
usage: release_notes.sh --packages <dir> --repo <owner/repo> --tag <tag> \
                        --version <VERSION> --out <file> [--proxy https://gh-proxy.com/]
EOF
      exit 0 ;;
    *) echo "release_notes.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$PACKAGES" ] || { echo "release_notes.sh: --packages is required" >&2; exit 1; }
[ -n "$REPO" ]     || { echo "release_notes.sh: --repo is required" >&2; exit 1; }
[ -n "$TAG" ]      || { echo "release_notes.sh: --tag is required" >&2; exit 1; }
[ -n "$OUT" ]      || { echo "release_notes.sh: --out is required" >&2; exit 1; }
[ -d "$PACKAGES" ] || { echo "release_notes.sh: packages dir not found: $PACKAGES" >&2; exit 1; }
[ -n "$VERSION" ] || VERSION="$(printf '%s' "$TAG" | sed 's/^v//')"

case "$PROXY" in
  */) ;;
  *) PROXY="$PROXY/" ;;
esac

PYTHON="${PYTHON:-$(command -v python3 || command -v python)}"

export RN_PACKAGES="$PACKAGES"
export RN_REPO="$REPO"
export RN_TAG="$TAG"
export RN_VERSION="$VERSION"
export RN_PROXY="$PROXY"
export RN_OUT="$OUT"

"$PYTHON" - <<'PY'
import json
import os

packages = os.environ["RN_PACKAGES"]
repo = os.environ["RN_REPO"]
tag = os.environ["RN_TAG"]
version = os.environ["RN_VERSION"]
proxy = os.environ["RN_PROXY"]
out = os.environ["RN_OUT"]

manifest_path = os.path.join(packages, "manifest.json")


def human(n):
    if n is None:
        return "-"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return ("%d B" % int(n)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0
    return "-"


assets = []
if os.path.isfile(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    for a in data.get("assets", []):
        if a.get("file"):
            assets.append({
                "tool": a.get("tool", "?"),
                "version": a.get("version", version),
                "abis": a.get("abis", []),
                "binaries": a.get("binaries", []),
                "file": a["file"],
                "size": a.get("size"),
            })
else:
    # degrade: scan *.tar.gz (skip the all-bundle)
    for name in sorted(os.listdir(packages)):
        if not name.endswith(".tar.gz") or name.startswith("adb-bin-box-"):
            continue
        stem = name[: -len(".tar.gz")]
        parts = stem.split("-")
        if "android" in parts:
            idx = parts.index("android")
            tool = "-".join(parts[: idx - 1]) or parts[0]
            ver = parts[idx - 1]
        else:
            tool, ver = stem, version
        assets.append({
            "tool": tool,
            "version": ver,
            "abis": ["(in archive)"],
            "file": name,
            "size": os.path.getsize(os.path.join(packages, name)),
        })

first_file = assets[0]["file"] if assets else "curl-<version>-android.tar.gz"
first_tool = assets[0]["tool"] if assets else "curl"

# Derive the ABI set actually shipped from the manifest itself, so selective
# builds (e.g. only curl on 2 ABIs) never over-promise a fixed count.  The
# degrade path uses the sentinel "(in archive)" which is not a real ABI -> skip.
abi_seen = []
for a in assets:
    for x in a.get("abis", []):
        if x and not x.startswith("(") and x not in abi_seen:
            abi_seen.append(x)
abi_seen.sort()
abi_count = len(abi_seen)
abi_inline = "、".join("`%s`" % x for x in abi_seen) if abi_seen else "-"

# Example ABI / binary used in the install snippet: taken from the first asset
# so a selective build never prints a path that was not actually shipped.
example_abi = abi_seen[0] if abi_seen else "arm64-v8a"
example_bin = first_tool
if assets:
    _bins = assets[0].get("binaries") or []
    if _bins:
        example_bin = _bins[0].get("bin") or first_tool
    elif assets[0].get("abis"):
        example_abi = assets[0]["abis"][0]


def direct_url(fname):
    return "https://github.com/%s/releases/download/%s/%s" % (repo, tag, fname)


def accel_url(fname):
    return proxy + direct_url(fname)


lines = []
lines.append("# adb-bin-box %s" % tag)
lines.append("")
if abi_count:
    lines.append("Android 命令行工具的**静态二进制**合集，本次共 **%d 个库**、"
                 "覆盖 **%d 个 ABI**（%s），用 `adb push` 到设备即可直接运行"
                 "（无需 root、无动态依赖）。" % (len(assets), abi_count, abi_inline))
    lines.append("")
    lines.append("> 每个压缩包 = **一个库**，包内按 ABI 分成子目录"
                 "（%s — 仅包含本次实际编译的 ABI）。" % abi_inline)
else:
    lines.append("Android 命令行工具的**静态二进制**合集，本次共 **%d 个库**，"
                 "用 `adb push` 到设备即可直接运行（无需 root、无动态依赖）。"
                 % len(assets))
    lines.append("")
    lines.append("> 每个压缩包 = **一个库**，包内按 ABI 分成子目录（见下表）。")
lines.append("")
lines.append("## 资产一览")
lines.append("")
lines.append("| 库 | 版本 | 包含的 ABI | 大小 | 直连地址 | 加速地址 |")
lines.append("|---|---|---|---|---|---|")
for a in assets:
    abis = ", ".join("`%s`" % x for x in a["abis"]) if a["abis"] else "-"
    lines.append("| `%s` | %s | %s | %s | [直连](%s) | [加速](%s) |" % (
        a["tool"], a["version"], abis, human(a["size"]),
        direct_url(a["file"]), accel_url(a["file"])))
all_name = "adb-bin-box-%s-all.tar.gz" % version
all_path = os.path.join(packages, all_name)
if os.path.isfile(all_path):
    lines.append("| `all` | %s | 全部库 | %s | [直连](%s) | [加速](%s) |" % (
        version, human(os.path.getsize(all_path)),
        direct_url(all_name), accel_url(all_name)))
lines.append("")

lines.append("## 加速下载（gh-proxy）")
lines.append("")
lines.append("国内直连 GitHub Release 常常很慢。给**完整 GitHub URL 前面加上** "
             "`https://gh-proxy.com/` 前缀即可走加速"
             "（规则就是简单拼接，不改路径、不改文件名）：")
lines.append("")
lines.append("```text")
lines.append("# 原始直连")
lines.append(direct_url(first_file))
lines.append("")
lines.append("# 加速（在完整 GitHub URL 前加 https://gh-proxy.com/）")
lines.append(accel_url(first_file))
lines.append("```")
lines.append("")
lines.append("也可直接在命令行套用（把下面 URL 换成你要的文件即可）：")
lines.append("")
lines.append("```sh")
lines.append("# 例：下载 %s 包" % first_tool)
lines.append("curl -fL -o %s %s" % (first_file, accel_url(first_file)))
lines.append("```")
lines.append("")

lines.append("## 安装到设备")
lines.append("")
lines.append("```sh")
lines.append("# 1. 选与设备匹配的 ABI")
lines.append("adb shell getprop ro.product.cpu.abi")
lines.append("")
lines.append("# 2. 解包（本机；%s 为例）" % first_tool)
lines.append("tar -xzf %s" % first_file)
lines.append("")
lines.append("# 3. 推送并赋可执行权限（按实际 ABI 目录推送）")
lines.append("adb push %s/%s /data/local/tmp/%s" % (example_abi, example_bin, example_bin))
lines.append("adb shell chmod +x /data/local/tmp/%s" % example_bin)
lines.append("adb shell /data/local/tmp/%s --version" % example_bin)
lines.append("")
lines.append("# 或整体推到设备上解包")
lines.append("adb push %s /data/local/tmp/" % first_file)
lines.append("adb shell tar -xzf /data/local/tmp/%s -C /data/local/tmp/" % first_file)
lines.append("adb shell chmod +x /data/local/tmp/*/%s" % example_bin)
lines.append("```")
lines.append("")

lines.append("## ⚠️ 运行时限制（诚实说明）")
lines.append("")
lines.append("这些是**静态 musl** 二进制，在 Android 上有几处与桌面环境不同，属已知行为：")
lines.append("")
lines.append("- **DNS**：musl 通过读 `/etc/resolv.conf` 解析域名，而标准 Android 没有该文件，"
             "默认**域名解析可能失败**。规避：用 `--resolve`/显式 IP，"
             "或 `curl --dns-servers 8.8.8.8`，或（需 root）写入 `/etc/resolv.conf`。")
lines.append("- **strace**：需要 `ptrace` 权限，**通常要 root**；`--version` 无需 root。")
lines.append("- **htop**：非 root 下读不到其它进程的部分 `/proc/<pid>` 字段（进程列表与自身正常）。")
lines.append("- **stress-ng**：部分 stressor 需 root 或被 **Android 10+ seccomp** 拦截，失败会明确报错。")
lines.append("- **curl**：Phase 1 用 `--without-ssl`，**暂不支持 https://**（HTTP/FTP 等可用）。")
lines.append("")
lines.append("> `--version` 类验证一定可用；真正干活取决于功能是否需要 root / DNS / TLS。")
lines.append("")

lines.append("## 许可证合规")
lines.append("")
lines.append("本 Release 分发的是第三方程序的**二进制**：")
lines.append("")
lines.append("- `htop` / `strace` / `stress-ng`：**GPL**（分发二进制须提供对应源码）")
lines.append("- `curl`：MIT 类（保留版权与许可声明）")
lines.append("- `iperf3`：BSD-3-Clause（保留版权声明）")
lines.append("")
lines.append("每个压缩包内含 `LICENSE-NOTICE.txt`；对应源码即 `tools.yml` 中锁定的上游版本，"
             "可从各库上游仓库获取。")
lines.append("")

with open(out, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(lines) + "\n")
print("release notes written: %s (%d asset row(s))" % (out, len(assets)))
PY
