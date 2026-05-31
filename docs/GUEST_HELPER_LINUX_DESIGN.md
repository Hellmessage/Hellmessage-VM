# Linux Guest Helper 自动部署设计

## 1. 目标 + 范围

**目标**: Linux VM 也像 Windows 一样, **零人工 / VM 启动后自动注入 + 配置 + 启动** HVM guest helper,
提供与 Windows 对等的 RPC 控制通道 (ping / exec / write-file / read-file), `hvm-dbg helper-exec`
在 Linux VM 上同样可用.

**做**:
- Linux 版 helper 二进制 (复用现有跨平台 RPC 核心; 新增 Linux 传输; **不做** clipboard)
- 打开 Linux VM 的 helper virtio-serial 传输端口 (当前 Windows-only)
- Linux 自动部署 (qga 推二进制 + systemd 单元 + 自启), 同 Windows `GuestHelperInstaller` 体验

**不做 (能力边界)**:
- **Linux 剪贴板** — 归 spice-vdagent (Linux guest 装 spice-vdagent 即可), HVM helper 在 Linux 不碰剪贴板.
- **用户图形会话内任务** — v1 helper 跑系统服务 (root), 不进用户 X/Wayland 会话. (touch 用户桌面推 v2, Linux 剪贴板已 vdagent 覆盖, 暂无需求.)
- **非 systemd guest 的全自动自启** — 见 §3.7 (v1 fail-soft).

## 2. 现状

| 项 | Windows | Linux 现状 |
|---|---|---|
| RPC 核心 (protocol/exec/fileio/log) | ✅ | ✅ **已跨平台** (0 Windows-API 引用) |
| 传输 (`src/virtio.rs`) | `CreateFile \\.\Global\...` | ❌ 无 (要写 `/dev/virtio-ports/...` 版) |
| clipboard (`src/clipboard.rs`) | CF_HDROP | — (不需要, vdagent 管) |
| helper virtio-serial 端口 (argv) | ✅ | ❌ `QemuHostEntry:214` Windows-only |
| qga 推送通道 | ✅ | ✅ `QemuHostEntry:210` 无条件设 (前提 guest 装 qemu-guest-agent) |
| 自动部署 | ✅ `GuestHelperInstaller` (schtasks) | ❌ 无 |

## 3. 设计

### 3.1 crate 跨平台化

`patches/guest/helper-win/` → 重命名 `patches/guest/helper/` (跨平台单 crate):
- **共享** (无改动): `protocol.rs` / `exec.rs` / `fileio.rs` / `log.rs`
- **`#[cfg(windows)]`**: `clipboard.rs` (CF_HDROP) + `transport_win.rs` (现 `virtio.rs`)
- **`#[cfg(unix)]`**: `transport_unix.rs` (新)
- `main.rs`: dispatch 里 clipboard 相关 op `#[cfg(windows)]` gate; Linux 收到 set-clipboard 返 "unsupported on linux" (vdagent 管)
- 两 target build: `aarch64-pc-windows-gnullvm` (现有) + `aarch64-unknown-linux-musl` (新)

### 3.2 Linux 传输 (`transport_unix.rs`)

guest 内 virtio-serial port 暴露为字符设备 `/dev/virtio-ports/com.hellmessage.hvm-clipboard.0`
(udev 按 port `name=` 建软链). 直接 `File::open` 读写 (比 Windows `CreateFile` 简单, 标准 `Read`/`Write`).
断线重连同 Windows 主循环 (5s retry).

### 3.3 启用 Linux helper 端口

`QemuHostEntry.swift:214`: `hvmClipboardSocketPath` 从 `guestOS == .windows ? ... : nil`
改为 **Linux + Windows 都设** (即 `guestOS != .macOS`, 但 macOS guest 已下线 → 实际恒设).
端口 `name=com.hellmessage.hvm-clipboard.0` **沿用不改** (改名牵连 Windows helper + udev, 工程量大);
语义从 "clipboard 专用" 泛化为 "HVM helper RPC 通道", 代码注释标注. host 侧 `HVMFileClipboardBridge`
(其 exec/writeFile/readFile RPC 方法) 对 Linux VM 也 connect.

### 3.4 build (musl 静态)

`aarch64-unknown-linux-musl` 静态链 → 单二进制无 glibc 依赖, 任意 Linux 发行版/版本可跑
(类比 Windows `crt-static`). `build.sh` 扩展: 缺 musl target 自动 `rustup target add` + 装 musl
linker (`brew install FiloSottile/musl-cross/musl-cross` 或 `cross`). 末尾校验 `file` 输出 "statically linked".
`make guest-helper` 同时出 Win + Linux 两产物到 `dist/{aarch64-win,aarch64-linux}/`.

### 3.5 Linux 自动部署 (`LinuxGuestHelperInstaller`)

`GuestHelperInstaller` 的 Linux 平行实现 (host 侧, HVMDisplayQemu):
```
qga-ready → marker 检测 (/var/lib/hvm/.helper-installed-vN)
  → 未装: qga guest-file-write 推 binary → /usr/local/bin/hvm-guest-helper (chmod 0755)
         → 写 systemd unit /etc/systemd/system/hvm-guest-helper.service
         → systemctl daemon-reload && systemctl enable --now hvm-guest-helper
  → 已装: 跳过 (版本号在 marker 名, 升级改名重装, 同 Win marker v3 机制)
```
systemd unit: `[Service] ExecStart=/usr/local/bin/hvm-guest-helper / Restart=always / User=root`.
`QemuHostEntry`: 把 §3.3 的 Windows-only helper 块泛化 — Windows 走 `GuestHelperInstaller`,
Linux 走 `LinuxGuestHelperInstaller`, 都 qga-ready 后台 fail-soft 跑.

### 3.6 运行身份: root 系统服务 (v1)

Linux helper 跑 systemd system service (root) — 类比 qemu-ga, RPC/provisioning 够用. 打开
`/dev/virtio-ports/...` 需 root (默认 perms). 用户图形会话 helper 推 v2 (Linux 剪贴板已 vdagent).

### 3.7 非 systemd guest (OpenWrt 等)

OpenWrt = procd, 无 systemd. v1 策略: 推完 binary 后探 `command -v systemctl`:
- 有 systemd → 写 unit + enable --now (全自动)
- 无 systemd → **fail-soft**: binary 已推 (`/usr/local/bin/`), log warn "非 systemd, 未自动配置自启, 请手动",
  **不**尝试 procd/init.d/rc.local (各发行版差异大, v1 不赌). v2 按需加 OpenWrt procd 脚本.

## 4. 选型对比

| 维度 | 选 | 备选 | 理由 |
|---|---|---|---|
| build | **musl 静态** | glibc 动态 | 单二进制跨发行版 (Ubuntu/Alpine/OpenWrt 通吃), 同 Win crt-static 哲学 |
| crate | **单 crate cfg-split** | 两 crate | RPC 核心已跨平台, cfg gate 传输/clipboard 即可, 不重复 |
| 运行身份 | **root 系统服务** | 用户会话 | RPC/provisioning 够用; Linux 剪贴板已 vdagent; 简单 |
| 自启 | **systemd v1** | 多 init 适配 | 覆盖主流; 非 systemd fail-soft 不赌 |
| 端口名 | **沿用 hvm-clipboard.0** | 改通用名 | 改名牵连 Win helper+udev, 语义泛化注释即可 |

## 5. PR 拆解 (颗粒 ≤ 2 天)

- **PR-1**: crate 跨平台化 (helper-win → helper, cfg-split transport/clipboard, Linux `transport_unix.rs`) +
  `build.sh` 出 Linux musl 静态产物. 验收: 两 target 都编出, Linux 产物 `file` 显 statically linked.
- **PR-2**: 启用 Linux helper virtio 端口 (`QemuHostEntry:214`) + host bridge connect Linux VM.
  验收: 起 Linux VM, host 侧 bridge 能连上端口 (helper 还没装时 retry).
- **PR-3**: `LinuxGuestHelperInstaller` (qga 推 + systemd unit + 自启 + 非 systemd fail-soft) +
  QemuHostEntry 泛化触发 (Win/Linux 分流). 验收: 真机 e2e — Ubuntu VM 启动后自动装 + `hvm-dbg helper-exec` 通.
- **PR-4**: 文档回写 CLAUDE.md (helper 跨平台 + Linux 自动部署小节) + 调试约束更新.

## 6. 风险 / P0 must-pass

- **P0-1 Linux 传输**: guest 内 `/dev/virtio-ports/com.hellmessage.hvm-clipboard.0` 存在且 helper 能读写
  (验: Ubuntu VM 内 `ls -l /dev/virtio-ports/`, helper 启动连上).
- **P0-2 musl 静态**: 产物无动态依赖 (验 `file` + `ldd` 显 "not a dynamic executable"), 跨发行版可跑.
- **P0-3 qga 前提**: 自动部署依赖 guest 装 qemu-guest-agent; 没装 → qga 永不 ready → 不部署 (同 Win 前提).
  文档显式告知 Linux guest 需 `apt install qemu-guest-agent` (类比 Win 的 UTM Guest Tools).
- **P0-4 systemd 自启**: Ubuntu VM 重启后 helper 自动起 (验: 重启 VM, `helper-exec` 仍通).
- **P0-5 非 systemd 不崩**: OpenWrt VM 部署走 fail-soft (binary 推成功, 不自启, 不报错阻塞 VM 启动).
- **P0-6 host bridge 复用**: `HVMFileClipboardBridge` 的 exec/writeFile/readFile 对 Linux helper 协议一致
  (同 JSON 帧), `dbg.helper.exec` handler 不分 OS.

## 7. Decisions

| # | 决策 | 选定 |
|---|---|---|
| D1 | Linux helper 职责 | RPC-only (ping/exec/write/read), **不做 clipboard** (vdagent 管) |
| D2 | 运行身份 | **root systemd 系统服务** v1 (用户会话推 v2) |
| D3 | 非 systemd guest (OpenWrt) | v1 **fail-soft** (推 binary 不自启 + 告知), 不赌 procd/init.d |
| D4 | build | **musl 静态单二进制** |
| D5 | crate 结构 | **单 crate cfg-split** (helper-win → helper) |
| D6 | 端口名 | 沿用 `com.hellmessage.hvm-clipboard.0` (语义泛化, 不改名) |
