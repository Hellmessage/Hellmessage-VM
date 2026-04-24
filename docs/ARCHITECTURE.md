# HVM 架构总览

## 目标

HVM 是一个基于 Apple Virtualization.framework (下称 VZ) 的 macOS 虚拟机管理工具, 面向**个人开发者在自己 Apple Silicon Mac 上运行 macOS / Linux guest** 的场景。

核心目标:

1. **零外部依赖**: 只依赖 Apple 官方 framework + `swift-argument-parser`, 空白 Mac 上 `make build` 一条命令跑通
2. **三端一体**: GUI (`HVM.app`) + CLI (`hvm-cli`) + 调试探针 (`hvm-dbg`) 共享同一套核心逻辑
3. **Bundle 自包含**: `.hvmz` 目录封装一台 VM 的全部状态, 可整目录拷贝迁移
4. **与 hell-vm 共存**: 选用 `.hvmz` 扩展名与 hell-vm 的 `.hellvm` 区分, 同一目录下可共存不冲突

## 硬约束

- **平台**: macOS 14+, Apple Silicon only
- **Guest 架构**: arm64 only (VZ 不支持 x86/riscv guest, 也不做 TCG)
- **Windows**: 不支持, 向导里不出现
- **USB host 直通**: 不支持, 仅支持 `VZUSBMassStorageDevice` 挂载 image
- **三方依赖**: 仅 `swift-argument-parser`
- **构建系统**: SwiftPM 唯一来源, Xcode 仅作为开发期 IDE

## 模块划分

全部模块前缀 `HVM`(Hell Message VM), 主 App target 名 `HVM`。

```
Package.swift
├── HVMCore         — 基础类型、错误、日志、utility (无 VZ 依赖)
├── HVMBundle       — .hvmz 目录布局、config.json 读写、flock 互斥
├── HVMStorage      — 磁盘镜像创建/扩容、ISO 路径校验
├── HVMBackend      — VZ 封装: 配置构建、VM 生命周期、事件订阅
├── HVMDisplay      — VZ graphics/keyboard/pointer 设备封装, guest 屏幕渲染源
├── HVMInstall      — IPSW 下载/校验、macOS 安装机驱动、Linux ISO 引导流程
├── HVMNet          — NAT attachment 构建; 桥接审批通过后扩展 bridged
├── HVMIPC          — hvm-cli / hvm-dbg 与运行中的 HVM.app 通信 (Unix domain socket)
├── HVM   (App)     — SwiftUI GUI, 深色主题, 主窗口 + 创建向导 + ErrorDialog
├── hvm-cli (exe)   — 命令行工具, 外部脚本入口
└── hvm-dbg (exe)   — 调试探针, 替代 osascript 做 guest 内操作
```

### 依赖拓扑

```
             ┌──────────────┐
             │   HVMCore    │  ← 任何模块都可依赖
             └──────┬───────┘
         ┌──────────┼──────────┬──────────┐
         ▼          ▼          ▼          ▼
    HVMBundle   HVMStorage  HVMNet    HVMDisplay
         │          │          │          │
         └──────────┴─────┬────┴──────────┘
                          ▼
                     HVMBackend
                          │
              ┌───────────┼───────────┐
              ▼           ▼           ▼
          HVMInstall   HVMIPC     HVM (App)
                          │
                 ┌────────┴────────┐
                 ▼                 ▼
              hvm-cli           hvm-dbg
```

规则:

- `HVMCore` 不依赖任何下游模块
- `HVMBackend` 是 VZ 相关逻辑的唯一落点, 其他模块不直接 import `Virtualization`(除 `HVMDisplay` 必须处理 VZ 的 view)
- GUI / CLI / dbg 三端只依赖 `HVM*` 模块, 不互相依赖
- `HVMIPC` 是 CLI/dbg 与 GUI 通信的唯一通道

## 进程模型

HVM 采取 **"一 VM 一进程"** 策略。每台运行中的 VM 都有独立承载进程, 避免一个 VM 崩溃带崩全部。

### 进程角色

| 进程 | 由谁拉起 | 职责 |
|---|---|---|
| `HVM.app` | 用户/Finder/Dock | 主 GUI, 列表/向导/设置, **不直接持有 VZVirtualMachine** |
| `HVMHost` (隐藏 helper) | `HVM.app` 或 `hvm-cli` | 每 VM 一个, 持有 VZVirtualMachine, 渲染 frame buffer 到 XPC 共享表面 |
| `hvm-cli` | 用户 shell | 短命, 对已有 VMHost 下命令, 或拉起新 VMHost |
| `hvm-dbg` | 用户/脚本 | 短命, 走 IPC 对指定 VM 做截屏/键盘/鼠标注入 |

> VMHost 不是独立 target, 是 `HVM.app` 内以 `NSRunningApplication` + launch argument 方式复制启动自身, 通过 argv 区分主进程/VMHost 模式。这样避免多一个 Mach-O binary、简化签名, 同时进程级隔离。

### 典型启动路径

**GUI 启动 VM**:

```
用户双击 HVM.app → 主进程 (mode=ui)
用户列表里点 Start VM "foo" 
  → 主进程 fork 自己 (mode=vmhost, --bundle /path/to/foo.hvmz)
  → VMHost 读 bundle, 构建 VZ 配置, 启动
  → VMHost 向主进程注册 socket path
  → 主进程用该 socket 订阅 state/frame/log
```

**CLI 启动 VM**:

```
hvm-cli start foo
  → 若 foo 未运行, fork HVM.app (mode=vmhost --headless)
  → VMHost 写 PID/socket 到 bundle/.lock 相关元文件
  → hvm-cli 立即返回, 或 --wait 等 guest ready
```

## 数据流

### VM 配置流

```
用户向导填参数 
  → HVMBundle.save(config) 
  → config.json 写入 bundle 
  → 启动时 HVMBackend.buildConfiguration(config) 
  → VZVirtualMachineConfiguration 
  → VZVirtualMachine.start()
```

### 运行时事件流

```
VZVirtualMachine.state KVO 
  → HVMBackend 发布 RunState 枚举
  → HVMIPC 广播到订阅者 (GUI 主进程 / hvm-cli / hvm-dbg)
  → 各端自行渲染
```

### 显示流

```
VZMacGraphicsDevice / VZVirtioGraphicsDevice
  → VZVirtualMachineView (AppKit NSView)
  → VMHost 进程内绘制
  → 通过 IOSurface / XPC 共享到主 GUI 进程
  → SwiftUI NSViewRepresentable 显示
```

> 显示共享方案细节见 [DISPLAY_INPUT.md](DISPLAY_INPUT.md)。MVP 阶段可简化: 直接在 VMHost 进程内开窗口, 主 GUI 只负责列表和控制。

## 核心抽象

### VMIdentity (HVMBundle)

```swift
/// 代表磁盘上一个 .hvmz bundle, 尚未加载 config
public struct VMIdentity: Hashable {
    public let bundleURL: URL
    public var displayName: String { bundleURL.deletingPathExtension().lastPathComponent }
}
```

### VMConfig (HVMBundle)

```swift
/// config.json 的 Swift 映射, Codable
public struct VMConfig: Codable {
    public var schemaVersion: Int            // 当前 1
    public var id: UUID                      // bundle 内唯一 ID, 创建时生成
    public var guestOS: GuestOSType          // .macOS / .linux
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var disks: [DiskSpec]
    public var networks: [NetworkSpec]
    public var bootFromDiskOnly: Bool        // 安装完切 true
    public var installerISO: URL?            // 仅 bootFromDiskOnly=false 时有意义
    public var macOS: MacOSSpec?             // 仅 guestOS=.macOS
}
```

### VMHandle (HVMBackend)

```swift
/// 一次 VM 运行会话的句柄, 持有 VZVirtualMachine
public actor VMHandle {
    public nonisolated let id: UUID
    public private(set) var state: RunState
    public func start() async throws
    public func stop(force: Bool) async throws
    public func pause() async throws
    public func resume() async throws
}

public enum RunState: Equatable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case error(String)
}
```

### BundleLock (HVMBundle)

```swift
/// 对 bundle 目录加 fcntl flock, 保证同一时间只有一个进程打开
public final class BundleLock {
    public init(bundleURL: URL) throws          // 尝试抢锁, 失败抛 BundleBusyError
    public func release()
    deinit { release() }
}
```

## 错误模型

错误统一以 `HVMError` 为根(在 `HVMCore`), 各模块定义 associated value case:

```swift
public enum HVMError: Error, CustomStringConvertible {
    case bundle(BundleError)
    case storage(StorageError)
    case backend(BackendError)
    case install(InstallError)
    case net(NetError)
    case ipc(IPCError)
}
```

详见 [ERROR_MODEL.md](ERROR_MODEL.md)。

## 日志

- 用 `os.Logger`, subsystem `com.hellmessage.vm`, category 对应模块名
- 用户级日志落 `~/Library/Application Support/HVM/logs/<yyyy-mm-dd>.log`(按天轮转, 保留 14 天)
- **绝对禁止**在日志里打印: team ID、证书 SHA、私钥路径、guest 内密码 / token
- 日志级别默认 `info`, 环境变量 `HVM_LOG=debug` 开 debug

## 线程 / 并发模型

- `HVMBackend.VMHandle` 用 Swift actor, 所有 VZ API 调用串行化在 actor 内
- VZ 部分 delegate callback 需要在主线程: 用 `@MainActor` 明确标注
- GUI 用 SwiftUI + @Observable/@MainActor 标注的 ViewModel
- CLI/dbg 用 structured concurrency (async/await), 不用 DispatchQueue 手写

## 不做什么

1. **不做插件系统**: 不引入 dylib 动态加载, 所有功能静态链接
2. **不做远程管理**: 不监听 TCP 端口, IPC 只走 Unix domain socket, 绑在用户 home 目录下
3. **不做快照链 / copy-on-write 磁盘**: 磁盘只是 raw sparse, 快照靠 APFS clonefile(见 [STORAGE.md](STORAGE.md))
4. **不做多租户 / 权限**: 工具是单用户工具, 不鉴权
5. **不做统计 / 上报**: 不收集任何用户数据
6. **不做自更新**: 构建即安装, 升级靠重新 `make build`

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| A1 | 多进程共享 frame buffer 的具体机制 (IOSurface vs. XPC shmem) | 先 VMHost 单进程自渲染, 延后拆分 | M2 阶段 GUI 做完后评估 |
| A2 | 是否引入 `VZVirtioConsoleDevice` 作为 guest agent 通道 | 是, 供 `hvm-dbg` 注入文本命令 | M2 |
| A3 | macOS guest IPSW 缓存位置 | `~/Library/Application Support/HVM/cache/ipsw/<buildVersion>.ipsw` | M3 启动前定 |
| A4 | CLI 的 daemon 化 | 不做 daemon, 每次 CLI 直接找 VMHost 的 socket | 已决 |

## 相关文档

- [VM_BUNDLE.md](VM_BUNDLE.md) — bundle 格式细节
- [VZ_BACKEND.md](VZ_BACKEND.md) — VZ 封装与生命周期
- [STORAGE.md](STORAGE.md) — 磁盘与 ISO
- [NETWORK.md](NETWORK.md) — 网络
- [GUI.md](GUI.md) — 主 App 界面
- [CLI.md](CLI.md) — hvm-cli
- [DEBUG_PROBE.md](DEBUG_PROBE.md) — hvm-dbg
- [BUILD_SIGN.md](BUILD_SIGN.md) — 构建签名
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 装机流程
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — 显示与输入
- [ERROR_MODEL.md](ERROR_MODEL.md) — 错误体系
- [ROADMAP.md](ROADMAP.md) — 里程碑

---

**最后更新**: 2026-04-25
