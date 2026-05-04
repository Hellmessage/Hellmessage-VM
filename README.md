# HVM

> macOS 上基于 **Apple Virtualization.framework** 的轻量 VM 管理工具 — GUI + CLI 双入口, 给 AI agent 留了独立调试探针。VZ + QEMU 双后端, 整 VM 加密落盘。

![status](https://img.shields.io/badge/status-WIP%20%2F%20Pre--1.0-orange)
![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![arch](https://img.shields.io/badge/arch-Apple%20Silicon-green)
![deps](https://img.shields.io/badge/runtime%20deps-zero%20%28brew%20socket__vmnet%20opt%29-lightgrey)

```
┌─ macOS guest      → VZ + IPSW 全自动装机
├─ Linux arm64      → VZ (默认) / QEMU (可选), 7 发行版自动下载
└─ Windows 11 arm64 → QEMU + HVF + swtpm + EDK2 (实验性, 含 unattend.iso 跳过硬件检查)

加密                → QEMU per-file LUKS qcow2 + AES-GCM config + KDF 跨机器 portable
克隆                → APFS clonefile + 身份字段重生 + 加密 VM 同密码字节级 COW
GUI 自动化           → hvm-dbg gui * (HDP-GUI 协议), 业务侧 .hvmProbe(id:) 修饰
```

---

## 目录

- [当前状态](#-当前状态-开发中)
- [能做什么](#能做什么)
- [系统要求](#系统要求)
- [构建](#构建)
- [快速上手 — GUI](#gui)
- [快速上手 — CLI](#cli)
- [整 VM 加密 (encrypt / decrypt / rekey)](#整-vm-加密)
- [整 VM 克隆](#整-vm-克隆)
- [桥接 / 共享网络](#桥接--共享网络-实验性-qemu-后端)
- [调试探针 hvm-dbg](#hvm-dbg-调试探针--ai-agent-入口)
- [目录结构](#目录结构)
- [文档](#文档)
- [License](#license)

---

## ⚠️ 当前状态: 开发中

HVM 还在 1.0 之前, **API、CLI 子命令、`.hvmz` bundle schema (v3)、IPC 协议在 1.0 发布前都可能破坏性变更**。请勿在生产环境依赖, 也不要把重要数据只放在 HVM guest 内的磁盘里。

| 里程碑 | 目标 | 状态 |
|---|---|---|
| **M0** | 项目骨架 + 空 .app 跑通 | ✅ |
| **M1** | CLI 起 Linux guest (create/start/stop/...) | ✅ |
| **M2** | GUI 基础(列表 + 向导 + 独立/嵌入运行窗口) | ✅ |
| **M3** | macOS guest(IPSW + `VZMacOSInstaller`,含内建下载 / 断点续传) | ✅ |
| **M4** | 桥接网络 — QEMU 后端 socket_vmnet ✅ / VZ 后端 ⬜ 等 Apple entitlement | 🚧 |
| **M5** | `hvm-dbg` 完整化(screenshot / key / mouse / console / exec / gui) | ✅ |
| **M6** | 打磨 + 文档查漏补缺 | ✅ |
| **加密 / 克隆** | HVMEncryption + CloneManager (QEMU 全闭环, VZ-sparsebundle 推后) | ✅ |

详见 [docs/v1/ROADMAP.md](docs/v1/ROADMAP.md)。

---

## 能做什么

### Guest OS

- **跑 Linux arm64 guest** — 默认 VZ 后端,高级模式可选 QEMU。**内建 7 发行版自动下载**:Ubuntu 24.04 / 22.04 LTS · Debian 13 · Fedora 44 · Alpine 3.20 · Rocky 9 · openSUSE Tumbleweed(catalog 走主流 mirror,SHA256 校验,断点续传)
- **跑 macOS guest** — 通过 IPSW 全自动装机,内建从 Apple CDN 拉最新 IPSW(支持断点续传)。仅 VZ 后端
- **跑 Windows arm64 guest**(实验性)— Win11 走 **QEMU + HVF** + 包内 swtpm(TPM 2.0)+ 包内 EDK2(SecureBoot,自家 patch 修 0x10000000 RAM 孔让 bootmgfw ConvertPages 通过)。装机流程含 unattend.iso 自动跳过 Win11 硬件检查 + UTM Guest Tools(vdagent + qemu-ga + viogpudo)自动静默装

### 安全

- **整 VM 落盘加密** (QEMU 后端) — 每文件独立加密: qcow2 LUKS-aes-256-xts (主盘 + 数据盘 + Win OVMF VARS) + swtpm encrypt + AES-256-GCM 包裹的 `config.yaml.enc`. PBKDF2-SHA256 600k iter 派生 master KEK, HKDF 派生 4 个子 key (qcow2-disk / qcow2-nvram / swtpm / config). routing JSON 落明文是 KDF 入口, 跨机器 portable
- **encrypt / decrypt / rekey 全 lifecycle** — 创建即加密 (`--encrypt`), 或对现有 VM 冷迁移加 / 解 / 改密. rekey 走 LUKS keyslot 重写, 毫秒级 (Win VM 重置 TPM)
- **长事务 SIGINT 防中断** — `SignalGuard` 把 SIGINT/SIGTERM 改成 "标记中止", critical section 完成才 exit, 不留 partial bundle
- **整 VM 克隆** — APFS clonefile(2) COW + 身份字段重生 (id / MAC / machine-identifier / 数据盘 uuid8). 加密 VM 走 D9 等价复制 + 同密码 (字节级 LUKS qcow2 复制不解密 + 用源 sub.config 重新加密 config)

### 用户体验

- **host ↔ guest 剪贴板共享** — UTF-8 文本双向同步,走 vdagent virtio-serial chardev。自家实现 spice-vdagent 协议(ANNOUNCE_CAPABILITIES 协商 + GRAB / REQUEST / CLIPBOARD 状态机 + multi-chunk reassembly),不依赖 spice-gtk。per-VM 配置,运行中可即时切换
- **macOS 风快捷键** — host `cmd+c/v/x/a/...` 自动映射成 guest `ctrl+c/v/x/a/...`,用户保留 macOS 肌肉记忆。修了 macOS 已知 "按住 cmd 字符键 keyUp 不送 view" 卡键问题。per-VM 配置可关
- **GUI 全鼠标操作** — 黑色主题主窗口、4 步创建向导(Linux / macOS / Windows + 加密 toggle)、嵌入运行窗口、独立窗口(borderless 自家 toolbar + 自家红绿灯 + 单层 chrome)、菜单栏 popover、缩略图列表; 加密 VM sidebar `lock.fill` 标识 + 解锁前详情页改 UnlockPanel
- **CLI 自动化** — `hvm-cli` 23 个子命令: list / status / create / delete / clone / start / stop / kill / pause / resume / boot-from-disk / iso / disk / snapshot / config / logs / install / ipsw / osimage / **encrypt / decrypt / rekey / encrypt-status**; `--engine vz|qemu` 走 ArgumentParser 自动校验
- **AI agent 友好** — `hvm-dbg` 提供 screenshot / status / key / mouse / console / exec / exec-guest / display-info / display-resize / find-text / boot-progress / ocr / wait / qemu-launch / **gui** 等子命令,不依赖 osascript 也能操控 guest (VZ + QEMU 双后端)。`exec-guest` 走 qemu-guest-agent 在 guest 内跑 PowerShell / cmd 命令拿 stdout, 绕开 IME / OCR / mouse 抖动. `hvm-dbg gui *` 走 HDP-GUI 协议自动化测 HVM 主进程 GUI (创建向导 / 加密 dialog / 详情页等), 替代脆弱的 osascript

### 工程

- **零三方依赖(运行时)** — 最终用户机器**不需要** Homebrew,仅 Xcode CLT 即可。QEMU + swtpm + 全部依赖 dylib 随 `.app` 分发,由 `make build-all` 一次打包。`socket_vmnet` 例外(用户 `brew install socket_vmnet` 后由 launchd daemon 接管)
- **签名闭环** — `Resources/QEMU/{bin,lib,libexec}/*` 严格逐文件 codesign;QEMU 子进程独立 entitlement(含 `com.apple.security.hypervisor`,HVF 必需)
- **GPL 合规** — QEMU + EDK2 + swtpm/libtpms 上游 commit SHA + tag + license 全文写入 `Resources/QEMU/MANIFEST.json` 与 `Resources/QEMU/LICENSE`
- **bundle schema v3** — `config.yaml` (Yams), 顶层加 `encryption` 字段; v2 → v3 走 `ConfigMigrator` 自动升级 (顶层加 `encryption: { enabled: false }` 兜底, 幂等)

## 后端选择

| Guest | 默认 | 备选 | 加密 | 备注 |
|-------|----------|------|------|------|
| macOS | VZ | — | ❌ (推后) | `VZMacOSInstaller`, QEMU 跑不了 macOS |
| Linux | VZ | QEMU | ✅ (QEMU only) | VZ 性能更好;QEMU 用于特殊设备 / 老内核 / 加密 |
| Windows | **QEMU only** | — | ✅ | VZ 无 TPM, Win11 装不了 |

工程与法律细节(GPL 合规、包内布局、`bundle.sh` 签名顺序、virtio-win / swtpm 处理)见 [docs/v1/QEMU_INTEGRATION.md](docs/v1/QEMU_INTEGRATION.md)。

## 不做什么(能力边界)

**Virtualization.framework(VZ)的硬限制**(Windows 已通过 QEMU 后端绕过):

- ❌ **x86_64 / riscv64 guest** — VZ 只支持原生 arm64,QEMU 后端我们也不接 TCG 跨架构(体积/性能不划算)
- ❌ **host USB 设备直通** — VZ API 不支持,仅虚拟 USB mass storage(建议 `dd` 成 image 再挂)
- ❌ **多 VM 共享同一 bundle** — 一个 `.hvmz` 同时只能被一个进程打开(fcntl flock 互斥)
- ❌ **热插拔 CPU / 内存** — 改配置必须停机
- ❌ **VZ-sparsebundle 加密 VM 启动解锁** — 路径推后, 加密 VM 当前只走 QEMU per-file scheme

完整不做清单见 [docs/v1/ROADMAP.md](docs/v1/ROADMAP.md)。

---

## 系统要求

- macOS 14(Sonoma)或更高
- Apple Silicon(M1 / M2 / M3 / M4 ...)
- Xcode Command Line Tools — `xcode-select --install`
- *(可选)* Apple Developer 个人证书 — 自动签出带 `com.apple.security.virtualization` entitlement 的 .app;没有也能 ad-hoc 签名跑

## 构建

### VZ-only(macOS + Linux guest,最小快速路径)

```bash
git clone <repo-url>
cd HVM
make build              # release 模式, 出 build/HVM.app + build/hvm-cli + build/hvm-dbg
```

`make build` 不嵌入 QEMU;.app 较小,仅 VZ 后端,适合只跑 macOS / Linux guest 且不需要加密的场景。

> **加密 VM 也需要 QEMU 后端** (依赖 qemu-img + LUKS), 想用加密必须 `make build-all`。

> **增量构建**:连跑两次 `make build`,第二次 ~1s 跳过 bundle.sh(stamp 文件机制,见 [Makefile](Makefile))。

### 含 QEMU 后端(Linux 可选 + Windows 装机 + 整 VM 加密)

```bash
make edk2               # 首次 ~5 分钟: 拉 edk2-stable202408 + apply Win11 patch + cross compile
make qemu               # 首次 10-30 分钟: 装 brew 依赖 + 拉 v10.2.0 源码 + 编译 + 嵌 swtpm
                        # 源码落 third_party/qemu-src/ + edk2-src/ (gitignored)
                        # 产物落 third_party/qemu-stage/  (~180M)
                        #         third_party/edk2-stage/ (Win11 patched firmware)
make build-all          # = make edk2 + make qemu + make build (.app 自带 QEMU + swtpm + EDK2)
```

跑 `make qemu` / `make edk2` 需要联网 + 几 GB 临时编译空间。一次跑完后 `third_party/{qemu,edk2}-{src,stage}/` 缓存在仓库内(gitignored),后续只需 `make build` 重新打包(不重编译)。

### 其他常用命令

```bash
make dev                # debug 模式
make verify             # smoke test, 验证 .app 可启动 + 签名 + entitlement + patches 孤儿检测 + GUI 约束 (无 NSAlert)
make install            # 把 build/HVM.app 装到 /Applications/
make run-app            # build + install + 重启 GUI 主进程 (保留运行中的 host 子进程)
make qemu-clean         # 清除 third_party/qemu-{src,stage}/ (重编 QEMU 前用)
make edk2-clean         # 清除 third_party/edk2-{src,stage}/
make clean              # 清除 build/ 与 app/.build/
make help               # 看全部目标
```

### Xcode

```bash
xed app/Package.swift   # 仅作开发期调试用, 出裸二进制无 entitlement; 真实运行必须走 make build
```

---

## 快速上手

### GUI

```bash
make install
open /Applications/HVM.app
```

界面里点 `+` → 4 步向导填 Linux VM 参数 (名字 → OS 类型 + ISO → CPU/内存/磁盘 + 网络 → 加密) → 创建 → 列表点 `Start` → 进 guest 装 OS → 装完关机, 在详情面板切到 "从硬盘启动"。

> 创建向导支持 **Download…** 按钮一键拉 7 发行版 ISO 到本地缓存,不用自己找 mirror。
> 加密 toggle 仅在 QEMU engine 下可见, 创建后整 VM 落盘加密, 启动时弹密码。

### CLI

#### Linux

```bash
# 看可下载的 OS 镜像
./build/hvm-cli osimage list

# 拉 Ubuntu 24.04 arm64 (走 catalog mirror, 断点续传, SHA256 校验)
./build/hvm-cli osimage fetch ubuntu-24.04

# 创建 + 启动
./build/hvm-cli create --name u1 --os linux \
    --cpu 4 --memory 8 --disk 64 \
    --iso ~/Library/Application\ Support/HVM/cache/os-images/ubuntu/ubuntu-24.04-live-server-arm64.iso

./build/hvm-cli start u1            # 后台 headless
./build/hvm-cli status u1
./build/hvm-cli boot-from-disk u1   # 装完切硬盘启动
./build/hvm-cli stop u1             # 软关机
```

#### macOS

```bash
# 拉 Apple 推荐的最新 IPSW (断点续传; 中途断网 / kill 都能从断点继续)
./build/hvm-cli ipsw fetch
./build/hvm-cli ipsw latest         # 看最新版本信息

# 创建 + 装机
./build/hvm-cli create --name mac1 --os macOS \
    --cpu 4 --memory 8 --disk 80 \
    --ipsw ~/Library/Application\ Support/HVM/cache/ipsw/<build>.ipsw

./build/hvm-cli install mac1         # 装机进度全自动
./build/hvm-cli start mac1           # 进首次启动向导
```

#### Windows 11 arm64(实验性,需先 `make build-all`)

```bash
# 先把 Win11 arm64 ISO 备好 (Microsoft 官网 / Insider 渠道, 不在本仓库分发)
# https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewARM64

./build/hvm-cli create --name win11 --os windows \
    --cpu 4 --memory 8 --disk 64 \
    --iso ~/Downloads/Win11_ARM64.iso       # engine 自动按 guestOS=windows 锁 qemu

./build/hvm-cli start win11
# 自动启 swtpm sidecar (TPM 2.0) + 挂 virtio-win.iso (首次自动下载 ~700MB)
# QEMU 起 iosurface display, Win11 安装界面在 HVM GUI 嵌入窗口里出现; 装机时驱动自动加载
# 装完关机后:
./build/hvm-cli boot-from-disk win11
./build/hvm-cli start win11
```

或直接走 GUI:`open /Applications/HVM.app` → `+` → 选 **Windows(实验性)** → 填 ISO 路径 → Create 时自动下 virtio-win → Start 自动起 swtpm。

#### 调试不走 host 进程的独立路径

```bash
./build/hvm-dbg qemu-launch win11 --dry-run     # 仅打印 argv
./build/hvm-dbg qemu-launch win11               # 直接拉 QEMU + 连 QMP, ctrl+c 走 ACPI
```

完整子命令清单见 [docs/v1/CLI.md](docs/v1/CLI.md)。

### 整 VM 加密

```bash
# 创建即加密 (强制 engine=qemu)
./build/hvm-cli create --name secure-linux --os linux --engine qemu \
    --cpu 4 --memory 4 --disk 32 --encrypt \
    --iso ~/Library/Application\ Support/HVM/cache/os-images/ubuntu/ubuntu-24.04-live-server-arm64.iso
# prompt 密码 + 二次确认 → 创建加密 bundle (config.yaml.enc + LUKS qcow2)

# 启动加密 VM (tty prompt 密码; 自动化场景 --password-stdin)
./build/hvm-cli start secure-linux
echo "my-password" | ./build/hvm-cli start secure-linux --password-stdin

# 把现有明文 VM 改成加密
./build/hvm-cli encrypt u1                        # 冷迁移, VM 必 stopped

# 加密 → 明文 (拆 LUKS)
./build/hvm-cli decrypt secure-linux

# 改密 (LUKS keyslot 重写, 毫秒级; Win VM 重置 TPM)
./build/hvm-cli rekey secure-linux

# 看加密形态 (走 routing JSON, 不需密码)
./build/hvm-cli encrypt-status secure-linux
# scheme=qemu-perfile  kdf=pbkdf2-sha256  iter=600000  salt=<base64>  ...
```

GUI 等价: 详情页 stopped 视图 → "Encrypt" / "Decrypt" / "Rekey" 按钮 → 三态 dialog (form / running / done)。详见 [docs/v1/ENCRYPTION.md](docs/v1/ENCRYPTION.md)。

### 整 VM 克隆

```bash
# 明文 VM clone (APFS clonefile + 身份字段重生)
./build/hvm-cli clone u1 --name u1-copy
# 输出: 源 / 目标 / 新 UUID / 数据盘 uuid8 重生映射

# 保留 MAC (用户自负不双开)
./build/hvm-cli clone u1 --name u1-twin --keep-mac

# 落到外部目录 (必须与源同 APFS 卷)
./build/hvm-cli clone u1 --name u1-side --target-dir ~/Documents/HVM-VMs

# 加密 VM clone (D9 等价复制 + 同密码)
./build/hvm-cli clone secure-linux --name secure-linux-copy
# prompt 源密码 + 二次确认 → 字节级 LUKS qcow2 复制 + 用源 sub.config 重新加密 config
# 新 VM 跟源同密码; 想换密码: hvm-cli rekey secure-linux-copy
```

详见 [docs/v1/CLONE.md](docs/v1/CLONE.md)。

### 桥接 / 共享网络(实验性,QEMU 后端)

默认 NAT 网络下 guest 拿不到物理 LAN 段地址,跨机访问受限。QEMU 后端走 `socket_vmnet` 系统级 launchd daemon 实现真桥接 / 内网共享,让 guest IP 落在物理 LAN 段或 host 与 guest 互通的 NAT 段。

**前提**:用户机器 `brew install socket_vmnet`(HVM 不打包 socket_vmnet 二进制,走 brew 路径)。

**安装 daemon**:GUI **编辑配置 → 网络 → 安装 daemon** 按钮,走 `osascript "do shell script ... with administrator privileges"` 弹**原生 Touch ID / 密码框**,一次到位装 shared + host + N 个 bridged.iface。**不写 `/etc/sudoers.d/*`,不拉 Terminal sudo bash**,daemon 由 launchd KeepAlive 常驻。

CLI 自动化或 CI 场景,也可直接调脚本:

```bash
sudo bash scripts/install-vmnet-daemons.sh                # 装 shared + host
sudo bash scripts/install-vmnet-daemons.sh en0            # + bridged.en0
sudo bash scripts/install-vmnet-daemons.sh en0 en1        # 多桥接
sudo bash scripts/install-vmnet-daemons.sh --uninstall    # 卸载
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

socket_vmnet daemon 由 launchd 以 root 常驻,监听固定 unix socket(跟 socket_vmnet 上游 / lima / hell-vm 一致):

| 模式 | socket 路径 |
|---|---|
| shared  | `/var/run/socket_vmnet` |
| host    | `/var/run/socket_vmnet.host` |
| bridged | `/var/run/socket_vmnet.bridged.<iface>` |

QEMU 通过 `-netdev stream,addr.type=unix,addr.path=<sock>` 直接连 daemon(4-byte length-prefix framing 跟 QEMU `-netdev stream` 协议兼容,不需要 `socket_vmnet_client` wrapper,不需要父进程 fd 透传)。GUI 创建向导若检测到对应 daemon 未跑会提示一键安装。

launchd plist label namespace `com.hellmessage.hvm.vmnet.*`,跟 lima / hell-vm / colima 区分互不干扰。

> VZ 后端的桥接(`com.apple.vm.networking` entitlement)仍在 Apple 审批中,审批通过前 VZ 路径只能用 NAT。
> 详见 [docs/v1/NETWORK.md](docs/v1/NETWORK.md)。

### `hvm-dbg`(调试探针 / AI agent 入口)

```bash
# 截屏 / 输入 / 控件
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

# OCR / 等待状态 / 启动阶段判定
./build/hvm-dbg ocr win11
./build/hvm-dbg find-text win11 "Sign In"
./build/hvm-dbg wait u1 --for state --eq running --timeout 30
./build/hvm-dbg boot-progress u1

# HVM 主进程 GUI 自动化 (HDP-GUI 协议; 需 HVM_GUI_PROBE=1 启 HVM)
HVM_GUI_PROBE=1 open /Applications/HVM.app
./build/hvm-dbg gui ping
./build/hvm-dbg gui list --prefix dialog.encryptVM
./build/hvm-dbg gui click --identifier dialog.encryptVM.button.encrypt
./build/hvm-dbg gui type --identifier dialog.encryptionPassword.input.password --text "secret"
./build/hvm-dbg gui screenshot --output /tmp/gui.png
```

详见 [docs/v1/DEBUG_PROBE.md](docs/v1/DEBUG_PROBE.md) 与 [docs/v3/HVM_DBG_GUI_PROTOCOL.md](docs/v3/HVM_DBG_GUI_PROTOCOL.md)。

---

## 目录结构

### 用户数据

```
~/Library/Application Support/HVM/
├── VMs/              # VM bundle 存放目录, 每台一个 *.hvmz
│   └── u1.hvmz/
│       ├── config.yaml         # bundle 元数据 (YAML 1.1, schema v3)
│       │   或 config.yaml.enc  # AES-GCM 加密 (qemu-perfile scheme)
│       ├── meta/encryption.json # 加密 VM routing JSON (明文, KDF 入口)
│       ├── disks/os.{img,qcow2} # VZ raw / QEMU qcow2 / QEMU 加密 LUKS qcow2
│       ├── nvram/efi-vars.{fd,qcow2} # EFI 变量 (Win SecureBoot; 加密 VM 走 qcow2 LUKS)
│       ├── tpm/                # swtpm state (Win11 TPM 2.0; 加密 VM swtpm encrypt)
│       ├── snapshots/<name>/   # APFS clonefile snapshot
│       ├── logs/console-*.log  # guest serial console 输出
│       └── .lock               # fcntl flock + 当前 host pid + IPC socket 路径
├── cache/            # 装机临时缓存 (IPSW / Linux ISO / virtio-win.iso / utm-guest-tools.iso)
├── logs/             # 全局日志: 顶层按日 + 子目录 <displayName>-<uuid8>/ (host/qemu/swtpm/console)
└── run/              # 运行期 socket (qmp / qmp-input / iosurface / vdagent / qga / console / hvm-dbg-gui)
```

### 三个二进制各管一摊

| 产物 | 角色 |
|---|---|
| `HVM.app` | GUI 主入口,同时也是 VM host 进程(`--host-mode-bundle` 起 `HVMHost`) + GUI Probe Server (`HVM_GUI_PROBE=1`) |
| `hvm-cli` | 短命 CLI,操作 bundle 或对已有 host 发 IPC,不常驻 |
| `hvm-dbg` | 调试探针,给 AI agent / 自动化测试用;零新协议,只复用公开 VZ API + QMP + qga + HDP-GUI |

源码模块拓扑(17 target)见 [docs/v1/ARCHITECTURE.md](docs/v1/ARCHITECTURE.md)。

---

## 文档

- **[docs/v1/](docs/v1/)** — 现状描述(按当前代码逻辑重构,2026-05-05 全量更新)
- **[docs/v3/](docs/v3/)** — 新能力设计提案 (单提案单文档, 大多已合入, 留底作决策溯源)
- **[docs/CHANGELOG.md](docs/CHANGELOG.md)** — 历史 v2 TODO 清单归档 (45 项已完成)

推荐阅读顺序:

1. [docs/v1/ARCHITECTURE.md](docs/v1/ARCHITECTURE.md) — 项目全貌、17 模块、双后端进程模型
2. [docs/v1/ROADMAP.md](docs/v1/ROADMAP.md) — 里程碑与不做清单
3. [docs/v1/VM_BUNDLE.md](docs/v1/VM_BUNDLE.md) — `.hvmz` 目录布局与 `config.yaml` schema (YAML 1.1, v3)
4. [docs/v1/QEMU_INTEGRATION.md](docs/v1/QEMU_INTEGRATION.md) — QEMU 随包分发、签名、补丁串行管理
5. [docs/v1/ENCRYPTION.md](docs/v1/ENCRYPTION.md) — 整 VM 加密
6. [docs/v1/CLONE.md](docs/v1/CLONE.md) — 整 VM 克隆
7. 其他专题(CLI / GUI / NETWORK / STORAGE / GUEST_OS_INSTALL / DEBUG_PROBE / ...)按需读

项目硬约束在仓库根 [CLAUDE.md](CLAUDE.md),与 docs/ 冲突时以 CLAUDE.md 为准。

---

## License

TBD — 1.0 之前先不定。
