# adb-bin-box

[![build](https://github.com/LIUBANGJIAN/adb-bin-box/actions/workflows/build.yml/badge.svg)](https://github.com/LIUBANGJIAN/adb-bin-box/actions/workflows/build.yml)
[![lint](https://github.com/LIUBANGJIAN/adb-bin-box/actions/workflows/lint.yml/badge.svg)](https://github.com/LIUBANGJIAN/adb-bin-box/actions/workflows/lint.yml)
[![release](https://github.com/LIUBANGJIAN/adb-bin-box/actions/workflows/release.yml/badge.svg)](https://github.com/LIUBANGJIAN/adb-bin-box/actions/workflows/release.yml)

> 把命令行工具编译成 **Android 上可直接 `adb push` 运行的静态二进制**的构建工厂。
>
> **GitHub Actions** + **Zig 内置 musl 交叉编译**，一次产出 **25 个工具 × 4 个 ABI**（`arm64-v8a` / `armeabi-v7a` / `x86_64` / `x86`，`stunnel` 只出前三个）的**单文件、无动态依赖**产物，共 **99 个并行 job**。
>
> 当前状态：主分支全绿（99/99），每周日自动编译发布一版。

---

## 产物清单

版本锁定在 `tools.yml`，改版本 = 改一行 YAML（见「如何添加新工具」）。

### 网络与传输

| 工具 | 版本 | 二进制 | 用途 | 需 root |
|---|---|---|---|---|
| `curl` | 8.22.0 | `curl` | HTTP/FTP 客户端（**仅明文**，无 TLS） | 否 |
| `iperf` | 3.21 | `iperf3` | 带宽/吞吐测速（客户端+服务端） | 否 |
| `tcping` | 2.5.0 | `tcping` | TCP 端口连通性与延迟，比 ping 更贴近实际服务 | 否 |
| `rsync` | 3.3.0 | `rsync` | 增量同步（走本地路径或 `rsync://`） | 否 |
| `dropbear` | 2024.86 | `dropbear` `dbclient` | 轻量 SSH 服务端 + 客户端 | 是（监听 22） |
| `socat` | 1.8.0.0 | `socat` | 端口转发、PTY 桥接、协议转换 | 否（高位端口） |
| `stunnel` | 5.82 | `stunnel` | 给明文服务套 TLS（自备证书与配置） | 否（高位端口） |

> `stunnel` 不出 `x86`（32 位）包，原因见「已知问题与取舍」。

### 抓包与网络诊断

| 工具 | 版本 | 二进制 | 用途 | 需 root |
|---|---|---|---|---|
| `tcpdump` | 4.99.5 | `tcpdump` | 抓包；`-r file.pcap` 离线解析不需要 root | 是（抓活包） |
| `ngrep` | 1.47.0 | `ngrep` | 按正则匹配报文内容；`-I file` 可离线分析 | 是 |
| `mtr` | 0.96 | `mtr` `mtr-packet` | 逐跳路由 + 丢包率；手机上看 `--report` 最实用 | 是（CAP_NET_RAW） |
| `nload` | 0.7.4 | `nload` | 实时上下行带宽（只读 `/proc/net/dev`） | 否 |
| `nethogs` | 0.8.7 | `nethogs` | 按进程统计流量，定位「谁在偷偷跑流量」 | 是 |
| `horst` | 5.0 | `horst` | WiFi 信道/客户端扫描（需网卡进 monitor 模式） | 是 |
| `arp-scan` | 1.10.0 | `arp-scan` | 局域网设备发现（原始套接字） | 是 |
| `drill` | 1.8.3 | `drill` | DNS 查询，**`drill -T` 自己发查询、不读 `/etc/resolv.conf`** | 否 |

### 系统与性能

| 工具 | 版本 | 二进制 | 用途 | 需 root |
|---|---|---|---|---|
| `htop` | 3.5.3 | `htop` | 交互式进程/CPU/内存监视 | 否（部分 `/proc` 字段受限） |
| `strace` | 7.2 | `strace` | 系统调用跟踪/排障 | 是（跟踪他人进程） |
| `stress-ng` | 0.22.01 | `stress-ng` | CPU/内存/IO 压力测试 | 部分 stressor |
| `fio` | 3.36 | `fio` | 存储 IO 基准测试 | 否 |
| `memtester` | 4.5.1 | `memtester` | 内存稳定性测试（找坏内存） | 否 |
| `pv` | 1.6.20 | `pv` | 管道进度/限速 | 否 |

### 数据与文本

| 工具 | 版本 | 二进制 | 用途 | 需 root |
|---|---|---|---|---|
| `sqlite` | 3.46.1 | `sqlite3` | 直接读写 app 数据库（需对应 uid） | 见限制 |
| `jq` | 1.7.1 | `jq` | JSON 解析/过滤 | 否 |
| `nano` | 8.1 | `nano` | 终端编辑器 | 否 |
| `ncdu` | 1.20 | `ncdu` | 交互式磁盘占用分析 | 否 |

---

## 为什么是静态 + musl + Zig

| 决策 | 原因 |
|---|---|
| **静态链接** | 单文件、拷过去就能跑；不依赖设备上有没有对应 `.so` |
| **musl libc（而非 Android bionic）** | bionic 把网络/DNS 委托给设备 `netd`，破坏静态链接；musl 直接走 syscall，天然跨 Android 版本 |
| **Zig 内置交叉工具链** | `zig cc -target <triple>` 一条命令自带 musl + compiler-rt + lld，**无需下载任何第三方工具链**（musl.cc 已封、NDK 路线已排除） |

> 只要设备内核 syscall 兼容，同一个静态二进制即可覆盖 Android 4.4 ~ 15，无需按 API level 分别构建。
>
> **关于两端越界（实测，2026-10）**：Android 15+ 引入的 16 KB page size 已核查 —— `arm64-v8a` / `armeabi-v7a` 产物的 `PT_LOAD p_align` 为 `0x10000`（64 KB），满足 16 KB 页要求，因此 16/17 **技术上无障碍但尚未真机验证**（CI 只做 QEMU user-mode 冒烟）。Android 2.x **不在支持范围**：当时内核 2.6.32/2.6.35 低于 musl 基线 2.6.39，且产物为 `armeabi-v7a` hard-float，ARMv6 设备会 `SIGILL`。

---

## 发布节奏

### 每周日自动发布（默认通道）

`.github/workflows/release.yml` 带一条 cron：

```yaml
schedule:
  - cron: "0 12 * * 0"   # UTC 周日 12:00 == 北京时间周日 20:00
```

* 到点自动跑**全量** 99 个 job → 打包 → 建 Release，**无需任何人工操作**。
* tag 自动取发布当天的北京日期，例如 `v2026.11.01`；同一天重复跑会退化成 `v2026.11.01-r2`、`-r3`（不会撞车）。
* 发布完成后 GitHub Releases 页面上**只剩这一版**（每条发布都会清掉更旧的，见「发布行为」）。

> ⚠️ 两个必须知道的前提：
> 1. GitHub 的 `schedule` **只在默认分支上生效**，且每轮都必须有人提交过代码/手动跑过一次，否则会被判定为不活跃；
> 2. **仓库连续 60 天没有任何提交，GitHub 会自动停用定时任务**。长期不动仓库时，记得去 Actions → Release → 右上角 `Enable workflow` 手动恢复，或者随便提交一次。

### 手动发布（要指定版本时）

* 打 tag：`git tag v2026.12.25 && git push origin v2026.12.25`；
* 或 Actions → **release** → Run workflow，填 `tag` / `tools` / `abis`（都留空 = 全量 + `v$(cat VERSION)`）。

### 只编译不发布（验证用）

* 推送到 `main` / 提 PR → 自动跑 `build.yml`；
* 或 Actions → **build** → Run workflow，用 `tools` / `abis` 只编指定的库：

| 输入 | 含义 | 示例 |
|---|---|---|
| `tools` | 只编这些库（逗号分隔） | `curl,htop` |
| `abis` | 只编这些 ABI（逗号分隔） | `arm64-v8a` |

两者可组合（`tools=curl` + `abis=arm64-v8a` → 1 个 job）。命令行等价写法：

```sh
python build/gen/generate_matrix.py tools.yml --deps deps.yml --count-only          # 99
python build/gen/generate_matrix.py tools.yml --deps deps.yml --only curl,htop --count-only
python build/gen/generate_matrix.py tools.yml --deps deps.yml --only curl,htop --abis x86_64 --count-only
python build/gen/generate_matrix.py tools.yml --deps deps.yml --exclude strace --count-only
```

> 填了**不存在的库名**会直接报错并以**退出码 1** 结束（错误信息里列出未知 id 与可用 id），避免拼错后静默编了个空集。

### 发布行为（release.yml）

* 触发方式：周日定时 / 推送 `v*` tag / 手动 Run workflow。
* tag 解析优先级：① push tag → `github.ref_name`；② 手动填了 `tag` → 用它；③ 定时触发 → `v<北京日期>`（冲突自动加 `-rN`）；④ 否则兜底 `v$(cat VERSION)`。
* **每次发布都会先删除所有旧 release（含旧 tag），只保留本次要发布的那个** —— 这是刻意行为，不是 bug。
* Release 说明由 `build/package/release_notes.sh` 依据实际产物生成，内含每个文件的**直连 + gh-proxy 加速**两种地址、安装命令、运行时限制与许可证提示。

---

## 拿到产物并安装

CI 里有两个 artifact：

* `dist__<tool>__<abi>`：每个 (工具 × ABI) 一份原始二进制；
* `packages`：打包好的**每库一个** `<tool>-<version>-android.tar.gz`（包内按 ABI 分子目录 `arm64-v8a/`…）+ 全局 `SHA256SUMS` + `manifest.json` + 全量包 `adb-bin-box-<VERSION>-all.tar.gz`。

推荐放到 **`/data/local/tmp`**（可执行、无需 root、不受系统分区只读限制）：

```sh
# 先确认设备 ABI
adb shell getprop ro.product.cpu.abi

# 解包并推送（以 curl 为例）
tar -xzf curl-8.22.0-android.tar.gz -C /tmp/curl-dist
adb push /tmp/curl-dist/arm64-v8a/curl /data/local/tmp/curl
adb shell chmod +x /data/local/tmp/curl
adb shell /data/local/tmp/curl --version
```

### 从 Release 下载（含国内加速）

```sh
# 直连
curl -fLO https://github.com/LIUBANGJIAN/adb-bin-box/releases/download/<tag>/curl-8.22.0-android.tar.gz

# 国内加速：给「完整 GitHub URL」前面直接拼 https://gh-proxy.com/
curl -fLO https://gh-proxy.com/https://github.com/LIUBANGJIAN/adb-bin-box/releases/download/<tag>/curl-8.22.0-android.tar.gz
```

|  | URL 形态 |
|---|---|
| 直连 | `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>` |
| 加速 | `https://gh-proxy.com/` + 上面的**完整** URL |

> 规则就是**简单拼接**：`加速地址 = https://gh-proxy.com/ + 直连地址`（不改路径、不改文件名）。每个 Release 说明页里，每个文件都同时给出两种链接。

---

## ⚠️ 运行时限制（务必阅读）

这些二进制是**静态 musl**，在 Android 上有几处与 glibc/桌面环境不同，属于**已知且诚实披露**的行为，不是打包错误：

| 工具 | 限制 | 说明 / 规避 |
|---|---|---|
| **全部** | **DNS 解析** | musl 通过读 `/etc/resolv.conf` 做 DNS，而标准 Android **没有这个文件**，因此默认**域名解析可能失败**。规避：① 用 `--resolve`/显式 IP（curl）、`-c` client IP（iperf3）等；② 有 root 时可写 `/etc/resolv.conf` 指向内网 DNS；③ **首选 `drill -T`**：它自己发查询，可判定"是解析坏了还是网络坏了" |
| **全部** | Android 10+ seccomp | 新系统对部分 syscall 有过滤，个别工具特性可能不可用（下表逐项披露） |
| **curl** | **无 HTTPS** | 当前用 `--without-ssl`，仅支持 HTTP/FTP 等明文协议。需要 HTTPS 时用 `stunnel` 本地起 TLS 端，或等 `curl` 打开 `features:[tls]`（`openssl` 依赖已在仓库里，具备条件） |
| **strace** | **需要 root** | `ptrace` 在 Android 上默认只允许同 uid/父进程跟踪；非 root 只能对自身子进程操作。`--version` 无需 root |
| **htop** | **/proc 字段受限** | 非 root 读不到其它进程的部分 `/proc/<pid>`（如 `cmdline`、`environ`），进程列表与自身信息正常 |
| **stress-ng** | **部分 stressor 需 root/被 seccomp 拦截** | 内存/CPU stressor 通常可用；`io_uring`、`mount`、网络命名空间类在 Android 10+ 会被拒。失败会明确报错，属预期 |
| **tcpdump / mtr / nethogs / ngrep / arp-scan / horst** | **需要 root** | 走 `AF_PACKET` 原始套接字；`tcpdump -r`、`ngrep -I` 离线解析不需要 root。`mtr-packet` 需要 `CAP_NET_RAW`，无 cap 辅助程序时等同 root |
| **nload / tcping / socat / stunnel / jq / pv / fio / memtester** | 无需 root | `nload` 只读 `/proc/net/dev`；`tcping` 是普通 TCP connect；`stunnel`/`socat` 监听高位端口即可 |
| **rsync** | **无 ssh 传输** | 只带 zlib，`--disable-openssl`，因此不能用 `-e ssh`；走本地路径或 `rsync://`（需对端跑 rsyncd） |
| **dropbear** | **需要 root** | 监听 22 端口需特权；host key 目录须可写（如 `/data/local/tmp/dropbear`），用 `-R` 走公钥认证 |
| **sqlite3** | 读 app 数据库需权限 | `/data/data/<pkg>/databases/*` 只有该 app uid 或 root 可读；可用 `adb shell run-as <pkg>` 或 root |
| **nano / ncdu** | 终端依赖 | 需要能用 `TERM` 的 shell（adb shell 默认可用）；`ncdu` 扫描 `/data` 同样受文件权限限制 |
| **horst** | 除 root 外还需 monitor 模式 | 多数原厂 ROM 的 WiFi 驱动不支持，开了也抓不到 |

> 结论：**`--version` 类验证一定可用；真正干活取决于目标功能是否需要 root / 域名解析 / TLS。**

---

## 已知问题与取舍

| 项 | 现状 | 原因 / 后续 |
|---|---|---|
| **`stunnel` 不出 `x86`（32 位）** | 只出 `arm64-v8a` / `armeabi-v7a` / `x86_64` | 编译、链接、ELF 门禁全过，但 `-version` 一跑就 SIGSEGV 且无任何输出；`-version` 只打印编译期默认值，不碰 TLS/crypto 初始化。已排除：openssl 原子操作 workaround（宏取 0/1 都同样崩）、libcrypto 本身（`drill`/`x86` 链接同一份正常）、configure 探测差异（两个 ABI 完全一致）。本机无 32 位 Linux 可复现，**宁可不出包也不出会崩的包**。32 位 Android x86 镜像早已绝迹（能跑现代 Android 的 x86 设备都是 x86_64）。要恢复需一个 32 位复现环境 |
| **`mtr-packet` 不做冒烟** | 产物照常打包、照常过 ELF 门禁，只是跳过运行时自检 | 它在 `getopt` 之前就开 raw socket，无特权下连 `--version` 都 `exit 1`。引擎的「一工具一条断言」无法表达，因此用 `smoke.skip_artifacts` 显式豁免 |
| **`curl` 无 TLS** | 仅 HTTP/FTP | 见上表；`openssl` 依赖已就绪，需要时可开 |
| **视频类工具未纳入** | 无 `ffmpeg` | 体积与依赖面太大，暂不引入（需要时可加，走 `meson` 驱动） |

---

## 如何添加一个新工具（三步）

声明式清单驱动，**加库 = 改一段 YAML**，通常**不需要改任何脚本**。

**第 1 步**：在 `tools.yml` 的 `tools:` 下加一条（示例：`jq`）：

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
python build/gen/generate_matrix.py tools.yml --deps deps.yml --count-only   # 加一个库 +4
```

**第 3 步**：提交并推送 —— CI 的 `generate` job 会**自动**把新库加入矩阵并并行构建，无需修改任何 workflow。

> 需要第三方库 → 在 `deps.yml` 加一条 `dep`，并在工具条目写 `deps: [<dep-id>]`；
> 需要打补丁 → 放 `patches/<tool>-<reason>.patch` 并在工具条目写 `patches: [...]`；
> 需要自定义步骤 → 用 `build/hooks/<tool>.sh` + `hooks:` 字段（见 `build/hooks/example.sh`）；
> 需要某 ABI 特殊处理 → `abi_overrides.<abi>`（深度合并，**列表整体替换**）；
> 上游源站不稳 → `source.mirror`（主源失败/返回坏包后自动切镜像）。

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
build/package/                  产物命名 / 打包 / 校验和 / release notes
build/hooks/                    按工具的钩子（pre_configure / pre_build / post_*）
build/local/                    本地复现 + zig 安装
patches/                        上游补丁
.github/workflows/              build / _build-tool / release / lint
dist/                           产物（gitignore；CI 上传为 artifact）
```

**约定**：全局 zig 版本真源 = `ZIG_VERSION`（默认 `0.16.0`）；全局 ABI 真源 = `build/verify/abi_matrix.json`（**任何脚本不得硬编码 zig triple**）。

**退出码**：`0` 成功 · `1` 构建失败 · `2` 校验（ELF 门禁）失败 · `3` 冒烟失败。

**产物命名**：**每库一个**压缩包 `<tool>-<version>-android.tar.gz`（包内按 ABI 分子目录 `<abi>/<bin>`）；全量包 `adb-bin-box-<VERSION>-all.tar.gz`；每包内含 `SHA256SUMS`/`README.txt`/`LICENSE-NOTICE.txt`。

---

## 许可证与合规提醒

本仓库**构建并分发第三方程序的二进制**，请遵守各自许可证。下方为归类，**准确条款以上游仓库 / 包内 `LICENSE-NOTICE.txt` 为准**。

**公共领域**

| 工具 | 许可证 |
|---|---|
| `sqlite3` | Public Domain |

**宽松许可（MIT / BSD / Apache-2.0 / curl 许可）** — 保留版权与许可声明即可

| 工具 | 许可证 |
|---|---|
| `curl` | curl license（MIT-like） |
| `iperf3` | BSD-3-Clause |
| `jq` | MIT |
| `ncdu` | MIT |
| `tcpdump` | BSD-3-Clause |
| `tcping` | MIT |
| `drill`（ldns） | BSD-3-Clause |
| `dropbear` | MIT 系 |
| `ngrep` | BSD 系 |

**GPL / LGPL 家族** — **分发二进制须能让接收方获取完全相同版本的源码**

| 工具 | 许可证 |
|---|---|
| `htop` / `strace` / `stress-ng` / `fio` / `memtester` / `nano` / `pv` / `mtr` / `nload` / `nethogs` / `rsync` / `socat` / `horst` / `stunnel` / `arp-scan` | GPL 系（多为 GPL-2.0-or-later，`rsync`/`nano`/`pv` 为 GPL-3.0-or-later） |

* 打包时每个 tar.gz 内含 `LICENSE-NOTICE.txt`；若你把某工具的完整许可证文本放入 `LICENSES/<tool>/`，会被一并打进包里。
* **GPL 工具**：对外分发其二进制时，你必须能让接收方获取**完全相同版本**的源码 —— 可直接引用上游 release tarball + 本仓库锁定的版本/清单/构建脚本。
* 本项目**仅提供构建脚本**，不对第三方程序的合规性/可用性作担保；上线前请按你所在组织的法务要求复核。
