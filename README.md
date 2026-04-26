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

- **跑 Linux arm64 guest** — 通过 ISO 半自动安装 (Ubuntu / Debian / Fedora arm64 等), 装完切 `bootFromDiskOnly` 走硬盘启动
- **跑 macOS guest** — 通过 IPSW 全自动装机,内建从 Apple CDN 拉最新 IPSW(支持断点续传)
- **GUI 全鼠标操作** — 黑色主题主窗口、创建向导、独立/嵌入运行窗口、菜单栏 popover、缩略图列表
- **CLI 自动化** — `hvm-cli` 子命令覆盖 list / create / start / stop / pause / resume / config / disk / snapshot / iso / boot-from-disk / install / logs / ipsw
- **AI agent 友好** — `hvm-dbg` 提供 screenshot / status / key / mouse / console / exec 等子命令, 不依赖 osascript 也能操控 guest
- **零三方依赖 (Swift 侧)** — 仅 Apple framework + `swift-argument-parser`, 一条 `make build` 出带签名的 .app

## QEMU 集成 (规划中)

在 **不替代现有 VZ 主路径** 的前提下, 规划增加 **QEMU 子进程后端**, 由 `HVM.app` **随包携带** `qemu-system-aarch64` 与必要资源, **用户无需** Homebrew、亦无需在 PATH 中安装 QEMU, 所有运行时依赖在应用包内解决。

- **仅支持 guest 为 ARM64 的 Windows 与 Linux**; 不实现 x86_64、riscv 等其他架构, 不扩展多 `qemu-system-*` 目标矩阵
- 工程与法律 (GPL 合规、包内布局、`bundle.sh` 签名顺序等) 见 **[docs/QEMU_INTEGRATION.md](docs/QEMU_INTEGRATION.md)**
- 实现落地前, **GUI/CLI 仍以 VZ 能力为准**; 上表「不做什么」描述的是 **Virtualization.framework 路径**

## 不做什么(能力边界)

**Virtualization.framework (VZ) 的硬限制**, 在 **仅走 VZ** 时即使有需求也不会实现:

- ❌ **Windows guest (VZ)** — VZ 无 TPM, Win11 装不了; Win10 ARM 已停供 ISO
- ❌ **x86_64 / riscv64 guest (VZ)** — VZ 只支持原生 arm64, 无 TCG 翻译
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

```bash
git clone <repo-url>
cd HVM
make build              # release 模式, 出 build/HVM.app + build/hvm-cli + build/hvm-dbg
```

其他命令:

```bash
make dev                # debug 模式
make verify             # smoke test, 验证 .app 可启动
make clean              # 清掉 build/ 与 .build/
make help               # 看全部目标
```

Xcode 用户:

```bash
xed Package.swift       # 仅作开发期调试用, 出裸二进制无 entitlement; 真实运行必须走 make build
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

完整子命令清单见 [docs/CLI.md](docs/CLI.md)。

### `hvm-dbg` (调试探针 / AI agent 入口)

```bash
./build/hvm-dbg screenshot u1 --out /tmp/u1.png
./build/hvm-dbg key u1 --text "hello" --press "Return"
./build/hvm-dbg exec u1 -- /bin/bash -c "uname -a"
```

详见 [docs/DEBUG_PROBE.md](docs/DEBUG_PROBE.md)。

---

## 目录结构

### 用户数据

```
~/Library/Application Support/HVM/
├── VMs/              # VM bundle 存放目录, 每台一个 *.hvmz
│   └── u1.hvmz/
│       ├── config.json        # bundle 元数据 (CPU/mem/磁盘/网络...)
│       ├── disks/main.img     # 主盘 (raw sparse)
│       ├── nvram/efi-vars.fd  # EFI 变量
│       └── .lock              # fcntl flock + 当前 host pid + IPC socket 路径
├── cache/            # 装机临时缓存
├── logs/             # 按日切分的日志
└── run/              # 运行期 socket
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
3. [docs/VM_BUNDLE.md](docs/VM_BUNDLE.md) — `.hvmz` 目录布局与 `config.json` schema
4. [docs/QEMU_INTEGRATION.md](docs/QEMU_INTEGRATION.md) — QEMU 随包分发、**仅 Win/Linux arm64**、零用户侧安装依赖 (规划)
5. 其他专题 (CLI / GUI / NETWORK / STORAGE / GUEST_OS_INSTALL / ...) 按需读

项目硬约束在仓库根 [CLAUDE.md](CLAUDE.md), 与 docs/ 冲突时以 CLAUDE.md 为准。

---

## License

TBD — 1.0 之前先不定。

