# adb-bin-box

> 把命令行工具编译成 **Android 上可直接 `adb push` 运行的静态二进制** 的构建工厂。
>
> 用 **GitHub Actions** + **Zig 内置 musl 交叉编译**，一次为 **4 个 ABI**（`arm64-v8a` / `armeabi-v7a` / `x86_64` / `x86`）产出**单文件、无动态依赖**的产物。

目标工具（Phase 1）：`curl` · `htop` · `iperf3` · `strace` · `stress-ng`

---

## 为什么是静态 + musl + Zig

| 决策 | 原因 |
|---|---|
| **静态链接** | 单文件、拷过去就能跑；不依赖设备上有没有对应 `.so` |
| **musl libc（而非 Android bionic）** | bionic 把网络/DNS 委托给设备 `netd`，破坏静态链接；musl 直接走 syscall，天然跨 Android 版本 |
| **Zig 内置交叉工具链** | `zig cc -target <triple>` 一条命令自带 musl + compiler-rt + lld，**无需下载任何第三方工具链**（CI 里 musl.cc 已被封，NDK 路线已排除） |

> 只要设备内核 syscall 兼容，同一个静态二进制即可覆盖 Android 4.4 ~ 15，无需按 API level 分别构建。

---

## 快速开始

### 1. 触发构建

* **CI（推荐）**：推送到 `main` / 提 PR / 手动 `workflow_dispatch` 即自动跑 `.github/workflows/build.yml`，矩阵由 `tools.yml` 动态生成（5 库 × 4 ABI = 20 个并行 job，`fail-fast: false`）。
* **选择性编译**：手动 `workflow_dispatch` 时只编指定的库 / ABI（见「选择性编译」）。
* **发布**：打 `v*` tag（如 `v2026.09.29`）触发 `release.yml`，生成 GitHub Release 资产。⚠️ **每次发布会自动删除旧 release，只保留最新一个**（见「发布行为」）。

### 选择性编译（只编指定的库 / ABI）

在 GitHub Actions 页面 **Run workflow** 时可填两个输入（**都留空 = 全编**）：

| 输入 | 含义 | 示例 |
|---|---|---|
| `tools` | 只编这些库（逗号分隔） | `curl,htop` |
| `abis` | 只编这些 ABI（逗号分隔） | `arm64-v8a` |

两者可组合（例：`tools=curl` + `abis=arm64-v8a` → 1 个 job）。命令行的等价写法：

```sh
python build/gen/generate_matrix.py tools.yml --only curl,htop --count-only          # 8
python build/gen/generate_matrix.py tools.yml --only curl,htop --abis x86_64 --count-only
python build/gen/generate_matrix.py tools.yml --exclude strace --count-only           # 排除
```

> 填了**不存在的库名**会直接报错并以**退出码 1** 结束（错误信息里列出未知 id 与可用 id），避免拼错后静默编了个空集。

### 发布行为（release.yml）

* 触发方式：推送 `v*` tag，或在 Actions 页面 **Run workflow** 手动触发（可填 `tag` / `tools` / `abis`）。
* tag 解析优先级：① push tag → `github.ref_name`；② 手动触发填了 `tag` → 用它；③ 否则兜底 `v$(cat VERSION)`。
* **每次发布都会先删除所有旧 release（含旧 tag），只保留本次要发布的那个** —— 这是刻意行为，不是 bug。
* Release 说明（body）由 `build/package/release_notes.sh` 依据实际产物生成，内含每个文件的**直连 + gh-proxy 加速**两种地址、安装命令、运行时限制与许可证提示。

### 2. 拿到产物

CI 里有两个 artifact：
* `dist__<tool>__<abi>`：每个 (工具×ABI) 一份原始二进制；
* `packages`：打包好的 **每库一个** `<tool>-<version>-android.tar.gz`（包内按 ABI 分子目录 `arm64-v8a/`…）+ 全局 `SHA256SUMS` + `manifest.json` + 全量包 `adb-bin-box-<VERSION>-all.tar.gz`。

### 3. 装到 Android 设备

推荐放到 **`/data/local/tmp`**（可执行、无需 root、不受系统分区只读限制）：

```sh
# 以 curl 为例：先解包，取设备对应 ABI 目录下的二进制
tar -xzf curl-8.22.0-android.tar.gz
adb push arm64-v8a/curl /data/local/tmp/curl
adb shell chmod +x /data/local/tmp/curl
adb shell /data/local/tmp/curl --version
```

用 tar 包安装（含 `README.txt`）：

```sh
tar -xzf curl-8.22.0-android.tar.gz -C /tmp/curl-dist
adb push /tmp/curl-dist/arm64-v8a/curl /data/local/tmp/curl
adb shell chmod +x /data/local/tmp/curl
adb shell /data/local/tmp/curl -sSL http://example.com/
```

> 设备 ABI 用 `adb shell getprop ro.product.cpu.abi` 确认，选对应的 `-android-<abi>` 目录里的二进制即可。

### 4. 从 Release 下载 + 加速（gh-proxy）

Release 资产是**每库一个**压缩包，直接下载：

```sh
# 直连（以 curl 为例）
curl -fLO https://github.com/LIUBANGJIAN/adb-bin-box/releases/download/v2026.09.29/curl-8.22.0-android.tar.gz

# 国内建议走加速：给「完整 GitHub URL」前面直接拼 https://gh-proxy.com/
curl -fLO https://gh-proxy.com/https://github.com/LIUBANGJIAN/adb-bin-box/releases/download/v2026.09.29/curl-8.22.0-android.tar.gz
```

|  | URL 形态 |
|---|---|
| 直连 | `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>` |
| 加速 | `https://gh-proxy.com/` + 上面的**完整** URL |

> 规则就是**简单拼接**：`加速地址 = https://gh-proxy.com/ + 直连地址`（不改路径、不改文件名）。每个 Release 的说明页里，每个文件都同时给出了直连与加速两种链接。

---

## ⚠️ 运行时限制（务必阅读）

这些二进制是**静态 musl**，在 Android 上有几处与 glibc/桌面环境不同，属于**已知且诚实披露**的行为，不是打包错误：

| 工具 | 限制 | 说明 / 规避 |
|---|---|---|
| **全部** | **DNS 解析** | musl 通过读 `/etc/resolv.conf` 做 DNS，而标准 Android **没有这个文件**。因此默认**域名解析可能失败**。规避：① 用 `--resolve`/显式 IP（curl）、`-c` client IP（iperf3）等；② `curl` 可加 `--dns-servers 8.8.8.8`（Phase 2 有 c-ares 时更佳）；③ 有 root 时可写 `/etc/resolv.conf`（`setprop` 或挂载）指向内网 DNS |
| **curl** | **无 HTTPS（Phase 1）** | Phase 1 用 `--without-ssl`，仅支持 HTTP/FTP 等明文协议；Phase 2 打开 `features:[tls]` 静态编 OpenSSL 后支持 `https://` |
| **strace** | **需要 root** | `ptrace` 在 Android 上默认只允许同 uid/父进程跟踪；非 root 只能对自身子进程或被 SELinux 放行的目标生效。`--version` 无需 root |
| **htop** | **/proc 字段受限** | 非 root 下读不到其它进程的部分 `/proc/<pid>`（如 `cmdline`、`environ`），进程列表与自身信息正常 |
| **stress-ng** | **部分 stressor 需 root / 被 seccomp 拦截** | 内存/CPU stressor 通常可用；涉及 `io_uring`、`mount`、网络命名空间等的 stressor 在 Android 10+ 的 **seccomp** 或权限下会被拒绝。失败会明确报错，属预期 |
| **全部** | Android 10+ seccomp | 新系统对部分 syscall 有过滤，个别工具特性可能不可用（已按 §限制 逐项披露） |

> 结论：**`--version` 类验证一定可用；真正干活取决于目标功能是否需要 root / 域名解析 / TLS。**

---

## 如何添加一个新工具（三步）

声明式清单驱动，**加库 = 改一段 YAML**，通常**不需要改任何脚本**。

**第 1 步**：在 `tools.yml` 的 `tools:` 下加一条（示例：加一个 `jq`）：

```yaml
  - id: jq
    version: "1.7.1"
    repo: jqlang/jq
    source:
      type: tarball
      url: "https://github.com/jqlang/jq/releases/download/jq-{version}/jq-{version}.tar.gz"
      strip_components: 1
    build_system: autotools        # autotools / cmake / make / meson / go / script
    bin: jq
    configure:
      flags: ["--disable-shared", "--enable-static", "--disable-maintainer-mode"]
    smoke:
      args: ["--version"]
      contains: "jq-1.7.1"
```

**第 2 步**：本地验证清单与矩阵：

```sh
python build/gen/manifest.py validate --tools tools.yml --deps deps.yml
python build/gen/generate_matrix.py tools.yml --deps deps.yml --count-only   # 应变为 24
```

**第 3 步**：提交并推送 —— CI 的 `generate` job 会**自动**把新库加入矩阵并并行构建，无需修改任何 workflow。

> 需要第三方库 → 在 `deps.yml` 加一条 `dep`，并在工具条目写 `deps: [<dep-id>]`；
> 需要打补丁 → 放 `patches/<tool>-<reason>.patch` 并在工具条目写 `patches: [...]`；
> 需要自定义步骤 → 用 `build/hooks/<tool>.sh` + `hooks:` 字段（见 `build/hooks/example.sh`）。

---

## 本地复现构建

```sh
# 安装固定版本 zig（脚本会自动下载正确 host 的包并设置可写缓存目录）
bash build/local/install-zig.sh --version 0.16.0 --dir ./work/toolchains/zig

# 构建单个 (工具 × ABI)
bash build/local/build_local.sh --tool curl --abi arm64-v8a

# 全部构建
bash build/local/build_local.sh --all
```

前置要求：`python3(+pyyaml)`、`curl`、`tar`，以及（仅 autotools 包需要）宿主的 `make/autoconf/automake/libtool/pkg-config`。**Zig 自身不需要宿主 gcc/clang。**

---

## 目录结构

```
tools.yml / deps.yml            声明式清单（唯一真源，用户改这里）
build/gen/                      manifest 解析 / 校验 / 矩阵生成（只读清单，不编译）
build/engine/                   通用构建引擎（build.sh / common.sh / detect-artifact.sh）
build/systems/                  各构建系统驱动 + 依赖库交叉编译（deps.sh）
build/verify/                   ELF 硬门禁 + QEMU 冒烟（只判定，无副作用）
build/package/                  产物命名 / 打包 / 校验和
build/local/                    本地复现 + zig 安装
patches/  build/hooks/          补丁与钩子（按需）
.github/workflows/              build / _build-tool / release / lint
dist/                           产物（gitignore；CI 上传为 artifact）
```

**约定**：全局 zig 版本真源 = `ZIG_VERSION`（默认 `0.16.0`）；全局 ABI 真源 = `build/verify/abi_matrix.json`（**任何脚本不得硬编码 zig triple**）。

**退出码**：`0` 成功 · `1` 构建失败 · `2` 校验（ELF 门禁）失败 · `3` 冒烟失败。

**产物命名**：**每库一个**压缩包 `<tool>-<version>-android.tar.gz`（包内按 ABI 分子目录 `<abi>/<bin>`）；全量包 `adb-bin-box-<VERSION>-all.tar.gz`；每包内含 `SHA256SUMS`/`README.txt`/`LICENSE-NOTICE.txt`。

---

## 许可证与合规提醒

本仓库**构建并分发第三方程序的二进制**，请遵守各自许可证：

| 工具 | 许可证 | 关键义务 |
|---|---|---|
| curl | MIT-like（curl license） | 保留版权与许可声明 |
| htop | **GPL-2.0-or-later** | 分发二进制**须提供对应源码**（本仓库记录 `tools.yml` 里锁定的上游版本与下载 URL；发布时请同时提供对应源码包） |
| strace | **GPL-2.0-or-later** | 同上 |
| stress-ng | **GPL-2.0-or-later** | 同上 |
| iperf3 | BSD-3-Clause | 保留版权声明 |

* 打包时每个 tar.gz 内含 `LICENSE-NOTICE.txt`；若你把某工具的完整许可证文本放入 `LICENSES/<tool>/`，会被一并打进包里。
* **GPL 工具**：对外分发其二进制时，你必须能让接收方获取**完全相同版本**的源码（可直接引用上游 release tarball + 本仓库构建脚本/清单）。
* 本项目**仅提供构建脚本**，不对第三方程序的合规性/可用性作担保；上线前请按你所在组织的法务要求复核。
