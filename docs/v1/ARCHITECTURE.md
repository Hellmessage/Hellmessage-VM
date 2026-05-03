# HVM 架构总览

## 目标

HVM 是一个 macOS 虚拟机管理工具, 双后端: **VZ (Apple `Virtualization.framework`)** 主, **QEMU** 用于 VZ 不承接的场景。面向**个人开发者在自己 Apple Silicon Mac 上运行 macOS / Linux / Windows arm64 guest**。

核心目标:

1. **零外部依赖 (用户机器)**: 仅依赖 Apple 官方 framework + `swift-argument-parser` + `Yams`(YAML 解析); QEMU + EDK2 + swtpm 等运行时产物随 `.app` 包内分发, `socket_vmnet` 由用户 brew 装(系统级 launchd daemon)
2. **三端一体**: GUI (`HVM.app`) + CLI (`hvm-cli`) + 调试探针 (`hvm-dbg`) 共享同一套核心逻辑
3. **Bundle 自包含**: `.hvmz` 目录封装一台 VM 的全部状态, 可整目录拷贝迁移
4. **与 hell-vm 共存**: `.hvmz` 与 `.hellvm` 严格隔离, 同目录可共存不冲突

## 硬约束

- **平台**: macOS 14+, Apple Silicon only
- **Guest 架构**: arm64 only(VZ + QEMU 都不做 TCG 翻译, x86/riscv guest 拒绝)
- **Guest OS**:
  - macOS — Apple Silicon only, **仅 VZ** (IPSW + `VZMacOSInstaller`)
  - Linux  — **默认 VZ, 可选 QEMU** (双后端)
  - Windows — arm64 only, **仅 QEMU** (VZ 无 TPM, Win11 装不上)
- **USB host 直通**: 不支持, 仅 `VZUSBMassStorageDevice` 挂 image
- **三方 Swift 依赖白名单**: `swift-argument-parser` + `Yams`, 不引其他
- **构建系统**: SwiftPM 唯一来源, Xcode 仅作开发期 IDE

## 模块划分

全部模块前缀 `HVM`(Hell Message VM), 主 App target 名 `HVM`。SwiftPM 包根在 `app/` 子目录, 当前 16 个 target:

```
app/Package.swift
├── HVMCore         — 基础类型 / HVMError / HVMLog / HVMPaths, 无下游依赖
├── HVMUtils        — 跨模块 helper: Format(bytes/rate/eta) / Hashing(sha256) / ResumableDownloader
├── HVMBundle       — .hvmz 布局 (BundleLayout) / config.yaml (VMConfig + Yams) / BundleLock / ConfigMigrator
├── HVMStorage      — 磁盘镜像创建 / 扩容 (raw ftruncate + qemu-img) / ISO 路径校验
├── HVMNet          — 网络 attachment 构建 (NAT / socket_vmnet shared/host/bridged 路径协调)
├── HVMDisplay      — VZ graphics / keyboard / pointer / OCR / 截屏 / boot 阶段分类
├── HVMBackend      — VZ 封装: VMHandle 生命周期 / VZ 配置构建 / 事件发布
├── HVMQemu        — QEMU 后端: argv 构造 / QmpClient / QemuProcessRunner / SwtpmRunner / WindowsUnattend
├── HVMScmRecv      — POSIX recvmsg + SCM_RIGHTS C wrapper (Swift 不能调 cmsg 宏), 仅给 HVMDisplayQemu 用
├── HVMDisplayQemu  — QEMU 显示嵌入: HDP v1.0.0 protocol / Metal 零拷贝 / vdagent 剪贴板 / 输入转发
├── HVMInstall      — IPSW 下载/校验 (IPSWFetcher 包 ResumableDownloader) / macOS 装机驱动 / OSImageCatalog 7 发行版
├── HVMIPC          — hvm-cli / hvm-dbg ↔ host 子进程 unix domain socket 协议
├── HVM   (App)     — SwiftUI GUI, 深色主题, 主窗口 + 创建向导 + ErrorDialog + 双后端 host 子进程 entry
├── hvm-cli (exe)   — 命令行工具
└── hvm-dbg (exe)   — 调试探针, 替代 osascript 做 guest 内操作
```

### 依赖拓扑

```
                           ┌──────────────┐
                           │   HVMCore    │  ← 任何模块都可依赖
                           └──────┬───────┘
                                  │
                            ┌─────┴─────┐
                            ▼           ▼
                       HVMUtils     HVMIPC
                            │
              ┌─────────────┼──────────┬──────────┬──────────┐
              ▼             ▼          ▼          ▼          ▼
         HVMBundle*    HVMStorage  HVMNet    HVMDisplay   HVMQemu*
              │             │          │          │          │
              └─────────────┴──────┬───┴──────────┘          │
                                   ▼                         │
                              HVMBackend                HVMScmRecv
                                   │                         │
                                   │          ┌──────────────┘
                                   │          ▼
                                   │   HVMDisplayQemu
                                   │          │
                                   ▼          ▼
                              HVMInstall  ┌─ HVM (App)
                                   │      ├─ hvm-cli
                                   └──────┴─ hvm-dbg

* HVMBundle 依赖 Yams; HVMQemu 不依赖 VZ
```

规则:

- `HVMCore` 不依赖任何下游模块
- `HVMBackend` 是 VZ 相关逻辑的唯一落点; `HVMQemu` 是 QEMU 后端的唯一落点, 二者并行不交叉(各自完成自己的 process / config / event)
- 仅 `HVMDisplay` / `HVMBackend` / 主 App 进程 import `Virtualization`
- `HVMDisplayQemu` 仅依赖 `HVMQemu` + `HVMScmRecv`, 不知道 VZ 的存在
- GUI / CLI / dbg 三端共享 HVM* 库, 不互相依赖

## 进程模型

HVM 采取 **"一 VM 一 host 子进程"** 策略, 避免一个 VM 崩溃带崩全部。

### 进程角色

| 进程 | 由谁拉起 | 职责 |
|---|---|---|
| `HVM.app` (主 GUI, mode=ui) | 用户/Finder | 列表/向导/详情, **不直接持有 VZVirtualMachine 也不 spawn QEMU** |
| `HVM.app --host-mode-bundle` (VZ host) | GUI 或 `hvm-cli start` | 持有 `VZVirtualMachine`, 渲染 framebuffer; argv 区分 mode 复用主二进制 |
| `HVM.app --qemu-host` (QEMU host) | GUI 或 `hvm-cli start` | 启动 `qemu-system-aarch64` 子进程 + swtpm sidecar(Win), 起 QMP / HDP socket |
| `qemu-system-aarch64` | QEMU host 进程 fork | guest 实际运行体. 来自 `Resources/QEMU/bin/`, 走独立 entitlement |
| `swtpm` | QEMU host 进程 fork | Win11 TPM 2.0, 仅 Windows guest 启 |
| `socket_vmnet` daemon | brew 装 + launchd | 系统级 daemon, 监听 `/var/run/socket_vmnet*`, **不在 .app 内** |
| `hvm-cli` | 用户 shell | 短命, 对已有 host 子进程下命令, 或拉起新 host |
| `hvm-dbg` | 用户/AI agent | 短命, 走 IPC 截屏 / 注入键鼠 / OCR / find-text / qga exec |

> VZ host 与 QEMU host 都不是独立 target, 而是 `HVM.app` 二进制以不同 launch argument 复制启动自身: `HVMHostEntry.swift` (VZ) / `QemuHostEntry.swift` (QEMU)。这样避免多一个 Mach-O binary, 简化签名。

### 典型启动路径

**GUI 启动 Linux VM (VZ 后端)**:

```
用户双击 HVM.app → 主进程 (mode=ui)
点 Start "u1"
  → 主进程 spawn HVM.app --host-mode-bundle <bundle> (VZ host)
  → VZ host 抢 BundleLock, 起 VZ, 监听 IPC socket (HVMPaths.run/<uuid>.sock)
  → 主进程订阅 state / frame / log 事件
```

**GUI 启动 Windows VM (QEMU 后端)**:

```
点 Start "win1"
  → 主进程 spawn HVM.app --qemu-host <bundle>
  → QEMU host 起 swtpm + qemu-system-aarch64 子进程
  → QEMU 监听 QMP socket (run/<uuid>.qmp) + HDP iosurface socket
  → HVMDisplayQemu 接 HDP, Metal 零拷贝渲染
```

**CLI 启动 VM**:

```
hvm-cli start foo
  → 若 foo 未运行, locate /Applications/HVM.app 或 ~/Applications/HVM.app
    (不再 fallback build/HVM.app, dev 期需先 make install)
  → spawn host 子进程, hvm-cli 立即返回, 或 --wait 等 ready
```

## 数据流

### VM 配置流

```
用户向导填参数 (GUI) 或 hvm-cli create
  → BundleIO.save(VMConfig)  [Yams 序列化]
  → <bundle>/config.yaml 写入 (atomic rename)
  → 启动时 BundleIO.load → VMConfig
  → engine 分流:
    .vz   → HVMBackend.ConfigBuilder → VZVirtualMachineConfiguration
    .qemu → HVMQemu.QemuArgsBuilder → argv [String]
```

### 运行时事件流

```
[VZ]  VZVirtualMachine.state KVO → HVMBackend.RunState 枚举 → IPC 广播
[QEMU] QmpClient 订阅 'STOP'/'RESUME'/'SHUTDOWN' 事件 → 同款 RunState
   → HVMIPC.SocketServer 推给所有订阅端 (GUI / hvm-cli / hvm-dbg)
```

### 显示流

```
[VZ]
VZMacGraphicsDevice / VZVirtioGraphicsDevice
  → VZVirtualMachineView (AppKit NSView)
  → HVMDisplay.VZViewRepresentable
  → SwiftUI 嵌入主窗口 / detached borderless 窗口 (PasteboardBridge 走 VZ 自带剪贴板)

[QEMU]
qemu-system-aarch64 -display iosurface,socket=...   (HVM patch 0002)
  → HDP v1.0.0 over AF_UNIX (SCM_RIGHTS 携带 shm fd)
  → HVMDisplayQemu.DisplayChannel + FramebufferRenderer (Metal 零拷贝)
  → FramebufferHostView (NSView)
  → 输入: NSEvent → InputForwarder → QMP input-send-event
  → 剪贴板: PasteboardBridge ↔ vdagent (virtio-serial chardev)
```

`HVMDisplayQemu` 协议规范见 [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md)。剪贴板共享 (`clipboardSharingEnabled`) + macOS 风快捷键 (`macStyleShortcuts`, host cmd→guest ctrl) 为 QEMU 后端独有, 持久化到 config.yaml。

## 核心抽象

### VMConfig (HVMBundle)

```swift
public struct VMConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2     // YAML
    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var displayName: String
    public var guestOS: GuestOSType                // .macOS / .linux / .windows
    public var engine: Engine                      // .vz / .qemu
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var disks: [DiskSpec]                   // DiskSpec.format ∈ {.raw, .qcow2}
    public var networks: [NetworkSpec]             // NetworkMode 五值
    public var installerISO: String?
    public var bootFromDiskOnly: Bool
    public var windowsDriversInstalled: Bool       // 仅 Windows
    public var clipboardSharingEnabled: Bool       // 仅 QEMU
    public var macStyleShortcuts: Bool             // 仅 QEMU
    public var macOS: MacOSSpec?
    public var linux: LinuxSpec?
    public var windows: WindowsSpec?
    public func validate() throws                  // 校验 engine ↔ guestOS 合法组合
}
```

完整 schema 见 [VM_BUNDLE.md](VM_BUNDLE.md)。

### VMHandle (HVMBackend, VZ 后端)

```swift
public actor VMHandle {
    public nonisolated let id: UUID
    public private(set) var state: RunState
    public func start() async throws
    public func stop(force: Bool) async throws
    public func pause() async throws
    public func resume() async throws
}

public enum RunState: Equatable {
    case stopped, starting, running, paused, stopping
    case error(String)
}
```

### QEMU 进程编排 (HVMQemu)

```swift
public final class QemuProcessRunner          // qemu-system-aarch64 子进程生命周期
public final class QmpClient                  // QMP unix socket JSON-RPC
public final class SwtpmRunner                // Win11 TPM sidecar
public enum QemuArgsBuilder                   // VMConfig → [String] argv
public enum WindowsUnattend                   // AutoUnattend.xml + hdiutil makehybrid
```

### BundleLock (HVMBundle)

```swift
public final class BundleLock {
    public init(bundleURL: URL, mode: Mode, socketPath: String) throws  // fcntl LOCK_EX|LOCK_NB
    public func release()
    public static func isBusy(bundleURL: URL) -> Bool
    public static func inspect(bundleURL: URL) -> HolderInfo?
}
```

flock 跨主机不可靠, NFS/SMB 卷会 warn 但不强禁(详见 [VM_BUNDLE.md](VM_BUNDLE.md))。

## 错误模型

错误统一以 `HVMError` 为根(在 `HVMCore`):

```swift
public enum HVMError: Error, CustomStringConvertible {
    case bundle(BundleError)
    case storage(StorageError)
    case backend(BackendError)
    case install(InstallError)
    case net(NetError)
    case ipc(IPCError)
    case config(ConfigError)
    case qemu(QemuError)
}
```

详见 [ERROR_MODEL.md](ERROR_MODEL.md)。

## 日志

落盘日志严格分两类(详见根 CLAUDE.md "日志路径约束"):

- **HVM host 侧 .log** → `~/Library/Application Support/HVM/logs/`
  - 顶层 `<yyyy-MM-dd>.log`: `LogSink` mirror `os.Logger`(跨 VM 共享)
  - 子目录 `<displayName>-<uuid8>/`: 该 VM 的 host 侧 .log
    - `host-<date>.log` — VMHost 进程 stdout/stderr
    - `qemu-stderr.log` — QEMU host 进程 stderr
    - `swtpm.log` / `swtpm-stderr.log` — swtpm 输出
- **guest 自己产的 .log** → `<bundle>.hvmz/logs/`
  - `console-<date>.log` — guest serial(由 ConsoleBridge / QemuConsoleBridge 写, **唯一允许写 bundle/logs/ 的来源**)

绝对禁止打印: team ID / 证书 SHA / 私钥路径 / guest 内密码 token。VM 删除时**不**清理 host 侧子目录, 留作排查。

## 线程 / 并发模型

- `HVMBackend.VMHandle` 用 Swift actor, 所有 VZ API 调用串行化在 actor 内
- VZ delegate callback 必须主线程: 用 `@MainActor` 标注
- GUI 用 SwiftUI + `@MainActor` ViewModel
- CLI/dbg 用 structured concurrency (async/await)
- QEMU 端 QmpClient 用单后台 actor 串行化 send/recv

## 不做什么

1. **不做插件系统**(无动态 dylib 加载, 全部静态链接)
2. **不做远程管理**(IPC 仅 Unix domain socket, 严禁 TCP listen)
3. **不做快照链 / COW 磁盘**(VZ 走 raw, QEMU 走 qcow2 但当前未上 chain)
4. **不做多租户 / 权限**(单用户工具)
5. **不做统计 / 上报**
6. **不做自更新**(`make build` 即升级)
7. **不做 x86_64 / riscv guest**(无 TCG 翻译)
8. **不做 host USB 直通 / 热插拔 CPU/mem / 多 VM 共享单 bundle**

## 相关文档

- [VM_BUNDLE.md](VM_BUNDLE.md) — bundle 格式细节
- [VZ_BACKEND.md](VZ_BACKEND.md) — VZ 封装与生命周期
- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — QEMU 后端集成
- [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) — HDP v1.0.0 协议
- [STORAGE.md](STORAGE.md) — 磁盘与 ISO
- [NETWORK.md](NETWORK.md) — 网络 (NAT + socket_vmnet)
- [GUI.md](GUI.md) — 主 App 界面
- [CLI.md](CLI.md) — hvm-cli
- [DEBUG_PROBE.md](DEBUG_PROBE.md) — hvm-dbg
- [BUILD_SIGN.md](BUILD_SIGN.md) — 构建签名
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 装机流程
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — 显示与输入
- [ERROR_MODEL.md](ERROR_MODEL.md) — 错误体系
- [ROADMAP.md](ROADMAP.md) — 里程碑
- [ENTITLEMENT.md](ENTITLEMENT.md) — entitlement 申请追踪

---

**最后更新**: 2026-05-04
