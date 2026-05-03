# HVM

> macOS 上基于 **Apple Virtualization.framework** 的轻量 VM 管理工具 — GUI + CLI 双入口, 给 AI agent 留了独立调试探针。

![status](https://img.shields.io/badge/status-WIP%20%2F%20Pre--1.0-orange)
![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![arch](https://img.shields.io/badge/arch-Apple%20Silicon-green)
![deps](https://img.shields.io/badge/deps-Apple%20framework%20%2B%20swift--argument--parser-lightgrey)

---

## ⚠️ 当前状态: 开发中

HVM 还在 1.0 之前, **API、CLI 子命令、`.hvmz` bundle schema、IPC 协议在 1.0 发布前都可能破坏性变更**。请勿在生产环境依赖, 也不要把重要数据只放在 HVM guest 内的磁盘里。

| 里程碑 | 目标 | 状态 |
|---|---|---|
| **M0** | 项目骨架 + 空 .app 跑通 | ✅ |
| **M1** | CLI 起 Linux guest (create/start/stop/...) | ✅ |
| **M2** | GUI 基础 (列表 + 向导 + 独立/嵌入运行窗口) | ✅ |
| **M3** | macOS guest (IPSW + `VZMacOSInstaller`, 含内建下载 / 断点续传) | ✅ |
| **M4** | 桥接网络 (依赖 Apple entitlement 审批) | ⬜ 等审批 |
| **M5** | `hvm-dbg` 完整化 (screenshot/key/mouse/console/exec) | ✅ |
| **M6** | 打磨 + 文档查漏补缺 | 🚧 |

详见 [docs/ROADMAP.md](docs/ROADMAP.md)。

---

## 能做什么

- **跑 Linux arm64 guest** — 通过 ISO 半自动安装 (Ubuntu / Debian / Fedora arm64 等), 装完切 `bootFromDiskOnly` 走硬盘启动. 默认 VZ 后端, 高级模式可选 QEMU. 内建从主流发行版 mirror 自动下载 7 种 ISO
- **跑 macOS guest** — 通过 IPSW 全自动装机, 内建从 Apple CDN 拉最新 IPSW (支持断点续传). 仅 VZ 后端
- **跑 Windows arm64 guest** (实验性) — Win11 走 **QEMU + HVF** + 包内 swtpm (TPM 2.0) + 包内 EDK2 (SecureBoot, 自家 patch 修 0x10000000 RAM 孔让 bootmgfw ConvertPages 通过). 装机流程含 unattend.iso 自动跳过 Win11 硬件检查 + UTM Guest Tools (vdagent + qemu-ga + viogpudo) 自动静默装
- **host ↔ guest 剪贴板共享** — UTF-8 文本双向同步, 走 vdagent virtio-serial chardev. 自家实现 spice-vdagent 协议 (ANNOUNCE_CAPABILITIES 协商 + GRAB/REQUEST/CLIPBOARD 状态机 + multi-chunk reassembly), 不依赖 spice-gtk. per-VM 配置, 运行中可即时切换
- **macOS 风快捷键** — host `cmd+c/v/x/a/...` 自动映射成 guest `ctrl+c/v/x/a/...`, 用户保留 macOS 肌肉记忆. 修了 macOS 已知 "按住 cmd 字符键 keyUp 不送 view" 卡键问题. per-VM 配置可关
- **GUI 全鼠标操作** — 黑色主题主窗口、创建向导 (Linux/macOS/Windows 三选一)、嵌入运行窗口、独立窗口 (borderless 自家 toolbar + 自家红绿灯 + 单层 chrome)、菜单栏 popover、缩略图列表
- **CLI 自动化** — `hvm-cli` 子命令覆盖 list / create / start / stop / pause / resume / config / disk / snapshot / iso / boot-from-disk / install / logs / ipsw; 创建支持 `--engine vz|qemu`
- **AI agent 友好** — `hvm-dbg` 提供 screenshot / status / key / mouse / console / exec / exec-guest / display-info / display-resize / find-text / boot-progress 等子命令, 不依赖 osascript 也能操控 guest (VZ + QEMU 双后端). `exec-guest` 走 qemu-guest-agent 在 guest 内跑 PowerShell / cmd 命令拿 stdout, 绕开 IME / OCR / mouse 抖动
- **零三方依赖 (运行时)** — 最终用户机器**不需要** Homebrew, 仅 Xcode CLT 即可. QEMU + swtpm + 全部依赖 dylib 随 `.app` 分发, 由 `make build-all` 一次打包. socket_vmnet 例外 (用户 `brew install socket_vmnet` 后由 launchd daemon 接管)

## 后端选择

| Guest | 默认后端 | 备选 | 备注 |
|-------|----------|------|------|
| macOS | VZ | — | `VZMacOSInstaller`, QEMU 跑不了 macOS |
| Linux | VZ | QEMU | VZ 性能更好; QEMU 用于特殊设备 / 老内核 |
| Windows | **QEMU only** | — | VZ 无 TPM, Win11 装不了 |

工程与法律细节 (GPL 合规、包内布局、`bundle.sh` 签名顺序、virtio-win / swtpm 处理) 见 **[docs/QEMU_INTEGRATION.md](docs/QEMU_INTEGRATION.md)**。

## 不做什么(能力边界)

**Virtualization.framework (VZ) 的硬限制** (Windows 已通过 QEMU 后端绕过):

- ❌ **x86_64 / riscv64 guest** — VZ 只支持原生 arm64, QEMU 后端我们也不接 TCG 跨架构 (体积/性能不划算)
- ❌ **host USB 设备直通** — VZ API 不支持, 仅虚拟 USB mass storage (建议 `dd` 成 image 再挂)
- ❌ **多 VM 共享同一 bundle** — 一个 `.hvmz` 同时只能被一个进程打开 (fcntl flock 互斥)
- ❌ **热插拔 CPU / 内存** — 改配置必须停机

完整不做清单见 [docs/ROADMAP.md](docs/ROADMAP.md#不做的事-远期也不做)。

---

## 系统要求

- macOS 14 (Sonoma) 或更高
- Apple Silicon (M1 / M2 / M3 / M4 ...)
- Xcode Command Line Tools (`xcode-select --install`)
- (可选) Apple Developer 个人证书 — 用于自动签名出带 `com.apple.security.virtualization` entitlement 的 .app; 没有也能 ad-hoc 签名跑

## 构建

### VZ-only (macOS + Linux guest, 最小快速路径)

```bash
git clone <repo-url>
cd HVM
make build              # release 模式, 出 build/HVM.app + build/hvm-cli + build/hvm-dbg
```

`make build` 不嵌入 QEMU; .app ~14MB, 仅 VZ 后端, 适合只跑 macOS / Linux guest 的场景。

### 含 QEMU 后端 (Linux 可选 + Windows 装机)

```bash
make qemu               # 首次 10-30 分钟: 自动装 brew 依赖 + 拉 v10.2.0 源码 + 编译 + 裁剪 + 嵌 swtpm
                        # 源码落 third_party/qemu-src/ (~900M)
                        # 产物落 third_party/qemu-stage/{bin,lib,share} (~180M, 含 swtpm + dylib 重定向; socket_vmnet 不入包, 由用户 `brew install socket_vmnet` 提供)
make build-all          # = make qemu + make build (.app 自带 QEMU + swtpm + EDK2, 共 ~66MB)
```

跑 `make qemu` 需要联网 + 几 GB 临时编译空间. 一次跑完后 `third_party/qemu-{src,stage}/` 缓存在仓库内 (gitignored), 后续只需 `make build` 重新打包 (不重编译 QEMU)。

### 其他常用命令

```bash
make dev                # debug 模式
make verify             # smoke test, 验证 .app 可启动
make qemu-clean         # 清除 third_party/qemu/ 与 build/qemu-* (重编 QEMU 前用)
make clean              # 清除 build/ 与 app/.build/
make help               # 看全部目标
```

Xcode 用户:

```bash
xed app/Package.swift   # 仅作开发期调试用, 出裸二进制无 entitlement; 真实运行必须走 make build
```

## 快速上手

### GUI

```bash
open build/HVM.app
```

界面里点 `+` → 向导填 Linux VM 参数 (CPU / 内存 / 磁盘 / ISO 路径) → 创建 → 列表点 `Start` → 进 guest 装 OS → 装完关机, 在详情面板切到"从硬盘启动"。

### CLI

```bash
# 创建一台 Ubuntu 24.04 arm64 guest
./build/hvm-cli create \
  --name u1 \
  --os linux \
  --cpu 4 \
  --memory 8 \
  --disk 64 \
  --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso

# 启动 (后台, headless)
./build/hvm-cli start u1

# 看状态
./build/hvm-cli status u1

# 装完后切硬盘启动
./build/hvm-cli boot-from-disk u1

# 软关机
./build/hvm-cli stop u1
```

macOS guest 走 IPSW 装机:

```bash
# 拉 Apple 推荐的最新 IPSW 到 cache (支持断点续传, 中途断网 / kill 都能从断点继续)
./build/hvm-cli ipsw fetch

# 或先看一眼最新版本信息
./build/hvm-cli ipsw latest

# 创建 + 装机
./build/hvm-cli create --name mac1 --os macOS --cpu 4 --memory 8 --disk 80 \
                      --ipsw ~/Library/Application\ Support/HVM/cache/ipsw/<build>.ipsw
./build/hvm-cli install mac1     # 进度条全自动
./build/hvm-cli start mac1       # 进首次启动向导
```

Windows 11 arm64 走 QEMU 后端 (实验性, 需先 `make build-all`):

```bash
# 先把 Win11 arm64 ISO 备好 (Microsoft 官网 / Insider 渠道, 不在本仓库分发)
# https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewARM64

# 创建 (engine 自动按 guestOS=windows 锁 qemu)
./build/hvm-cli create --name win11 --os windows \
    --cpu 4 --memory 8 --disk 64 \
    --iso ~/Downloads/Win11_ARM64.iso

# 启动: 自动启 swtpm sidecar (TPM 2.0) + 挂 virtio-win.iso (首次自动下载 ~700MB)
./build/hvm-cli start win11
# QEMU 自开 cocoa 窗口, Win11 安装界面出现; 装机时 Browse 驱动 → E:\amd64\w11 → viostor.sys

# 装完, 关机后切硬盘
./build/hvm-cli boot-from-disk win11
./build/hvm-cli start win11
```

或直接走 GUI: `open build/HVM.app` → `+` → 选 **Windows (实验性)** → 填 ISO 路径 → Create 时自动下 virtio-win → Start 自动起 swtpm。

调试不走 host 进程的独立路径:
```bash
./build/hvm-dbg qemu-launch win11 --dry-run     # 仅打印 argv
./build/hvm-dbg qemu-launch win11               # 直接拉 QEMU + 连 QMP, ctrl+c 走 ACPI
```

完整子命令清单见 [docs/CLI.md](docs/CLI.md)。

### 桥接 / 共享网络 (实验性, QEMU 后端)

默认 NAT 网络下 guest 拿不到物理 LAN 段地址, 跨机访问受限。QEMU 后端走 `socket_vmnet` 系统级 launchd daemon
实现真桥接 / 内网共享, 让 guest IP 落在物理 LAN 段或 host 与 guest 互通的 NAT 段。

**前提**: 用户机器 `brew install socket_vmnet` (HVM 不打包 socket_vmnet 二进制, 走 brew 路径).

**安装 daemon**: GUI **编辑配置 → 网络 → 安装 daemon** 按钮, 走 `osascript "do shell script ... with administrator privileges"` 弹**原生 Touch ID / 密码框**, 一次到位装 shared + host + N 个 bridged.iface. **不写 `/etc/sudoers.d/*`, 不拉 Terminal sudo bash**, daemon 由 launchd KeepAlive 常驻.

CLI 自动化或 CI 场景, 也可直接调脚本 (sudo + 显式 iface 列表):

```bash
# 装 shared + host (默认; 不带桥接)
sudo bash scripts/install-vmnet-daemons.sh

# 加桥接接口 (en0): 同时装 shared / host / bridged.en0
sudo bash scripts/install-vmnet-daemons.sh en0

# 多桥接 (en0, en1)
sudo bash scripts/install-vmnet-daemons.sh en0 en1

# 卸载
sudo bash scripts/install-vmnet-daemons.sh --uninstall
```

之后创建 VM:

```bash
./build/hvm-cli create --name foo --os linux --engine qemu \
    --cpu 4 --memory 4 --disk 32 \
    --network bridged:en0 \
    --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso

./build/hvm-cli start foo
# guest 内 IP 在 en0 同段, 跨机 ssh / ping 通
```

socket_vmnet daemon 由 launchd 以 root 常驻, 监听固定 unix socket (跟 socket_vmnet 上游 / lima / hell-vm 一致):

| 模式 | socket 路径 |
|---|---|
| shared  | `/var/run/socket_vmnet` |
| host    | `/var/run/socket_vmnet.host` |
| bridged | `/var/run/socket_vmnet.bridged.<iface>` |

QEMU 通过 `-netdev stream,addr.type=unix,addr.path=<sock>` 直接连 daemon (4-byte length-prefix framing 跟 QEMU `-netdev stream` 协议兼容, 不需要 `socket_vmnet_client` wrapper, 不需要父进程 fd 透传). GUI 创建向导若检测到对应 daemon 未跑会提示一键安装.

launchd plist label namespace `com.hellmessage.hvm.vmnet.*`, 跟 lima / hell-vm / colima 区分互不干扰.

> VZ 后端的桥接 (`com.apple.vm.networking` entitlement) 仍在 Apple 审批中, 审批通过前 VZ 路径只能用 NAT。
> 详见 [docs/NETWORK.md](docs/NETWORK.md)。

### `hvm-dbg` (调试探针 / AI agent 入口)

```bash
./build/hvm-dbg screenshot u1 --output /tmp/u1.png
./build/hvm-dbg key u1 --text "hello"
./build/hvm-dbg key u1 --press "Return"
./build/hvm-dbg mouse u1 --op click --x 100 --y 200

# Linux guest (VZ): 走 console (hvc0 getty)
./build/hvm-dbg exec u1 -- /bin/bash -c "uname -a"

# Win/Linux guest (QEMU + qemu-guest-agent): 绕开 IME / OCR / mouse, 拿干净 stdout
./build/hvm-dbg exec-guest win11 --ps "Get-Process | Select-Object -First 5"
./build/hvm-dbg exec-guest linux1 --path /usr/bin/uname --args "-a"

# 验证 dynamic resize 是否真生效
./build/hvm-dbg display-info win11        # guest 当前 framebuffer 真实分辨率
./build/hvm-dbg display-resize win11 --width 2560 --height 1440
```

详见 [docs/DEBUG_PROBE.md](docs/DEBUG_PROBE.md)。

---

## 目录结构

### 用户数据

```
~/Library/Application Support/HVM/
├── VMs/              # VM bundle 存放目录, 每台一个 *.hvmz
│   └── u1.hvmz/
│       ├── config.yaml        # bundle 元数据 (YAML 1.1, schema v2: CPU/mem/磁盘/网络/clipboard/macStyle...)
│       ├── disks/os.img       # VZ 后端: raw sparse;  os.qcow2 = QEMU 后端
│       ├── nvram/efi-vars.fd  # EFI 变量 (Win SecureBoot 状态持久)
│       ├── tpm/               # swtpm state (Win11 TPM 2.0)
│       ├── logs/console-*.log # guest serial console 输出
│       └── .lock              # fcntl flock + 当前 host pid + IPC socket 路径
├── cache/            # 装机临时缓存 (IPSW / Linux ISO / virtio-win.iso / utm-guest-tools.iso)
├── logs/             # 全局日志: 顶层按日 + 子目录 <displayName>-<uuid8>/ (host/qemu/swtpm/console)
└── run/              # 运行期 socket (qmp / qmp-input / iosurface / vdagent / qga / console)
```

### 三个二进制各管一摊

| 产物 | 角色 |
|---|---|
| `HVM.app` | GUI 主入口, 同时也是 VM host 进程 (`--host-mode` 起 `HVMHost`) |
| `hvm-cli` | 短命 CLI, 操作 bundle 或对已有 host 发 IPC, 不常驻 |
| `hvm-dbg` | 调试探针, 给 AI agent / 自动化测试用; 零新协议, 只复用公开 VZ API |

源码模块拓扑见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 文档

设计文档与决策沉淀全在 [docs/](docs/), 推荐顺序:

1. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 项目全貌、模块划分、进程模型
2. [docs/ROADMAP.md](docs/ROADMAP.md) — 里程碑与不做清单
3. [docs/VM_BUNDLE.md](docs/VM_BUNDLE.md) — `.hvmz` 目录布局与 `config.yaml` schema (YAML 1.1, v2)
4. [docs/QEMU_INTEGRATION.md](docs/QEMU_INTEGRATION.md) — QEMU 随包分发、**仅 Win/Linux arm64**、零用户侧安装依赖 (规划)
5. 其他专题 (CLI / GUI / NETWORK / STORAGE / GUEST_OS_INSTALL / ...) 按需读

项目硬约束在仓库根 [CLAUDE.md](CLAUDE.md), 与 docs/ 冲突时以 CLAUDE.md 为准。

---

## License

TBD — 1.0 之前先不定。

