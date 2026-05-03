# VZ Backend 设计 (`HVMBackend`)

`HVMBackend` 是封装 Apple `Virtualization.framework` 的模块, 服务 macOS / Linux arm64 guest. Windows arm64 走 QEMU 后端 (见 [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md)), 不进 VZ 路径.

## 目标

1. **配置构建**: 把 `VMConfig` 翻译成 `VZVirtualMachineConfiguration`
2. **生命周期**: 启动 / 停止 / 暂停 / 恢复, 统一 `RunState` 枚举
3. **事件订阅**: 状态变化 / guest 崩溃 (delegate) 透传
4. **校验**: 上层非法参数在构建前就拒绝

非 VZ-aware 模块一律不 `import Virtualization`. 例外:

- `HVMDisplay` 暴露 `VZVirtualMachineView` 给 SwiftUI 嵌入
- `HVMInstall` 调用 `VZMacOSInstaller` 做 IPSW 装机
- `HVMNet/NICFactory` 构造 `VZ*NetworkDeviceAttachment` (单一职责, 不持有 VM)

## 模块矩阵

| 模块 | 职责 |
|---|---|
| `HVMBackend` | `ConfigBuilder` / `VMHandle` / `RunState` / `MacPlatform` / `ConsoleBridge` / `VZErrorMapping` |
| `HVMNet` | `NICFactory` (VZ NIC 构造) / `MACAddress` / `IPResolver` |
| `HVMStorage` | `DiskFactory` / `ISOValidator` / `SnapshotManager` / `VolumeInfo` |
| `HVMInstall` | `MacInstaller` (IPSW 装机) / `IPSWFetcher` / `OSImageCatalog` (Linux ISO 自动下载) / `MacAuxiliaryFactory` |

## 数据类型

### RunState

```swift
public enum RunState: Equatable, Sendable, Codable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case error(String)        // 携带 VZ 报告的 localizedDescription
}
```

VZ → RunState 映射 (`RunState.from(_:)`):

| `VZVirtualMachine.State` | `RunState` |
|---|---|
| `.stopped` | `.stopped` |
| `.starting` / `.resuming` / `.restoring` | `.starting` |
| `.running` / `.pausing` / `.saving` | `.running` |
| `.paused` | `.paused` |
| `.stopping` | `.stopping` |
| `.error` | `.error("...")` |

### VMHandle

```swift
@MainActor
public final class VMHandle {
    public nonisolated let id: UUID
    public nonisolated let bundleURL: URL
    public nonisolated let config: VMConfig
    public private(set) var state: RunState

    public var virtualMachine: VZVirtualMachine? { vm }   // 给 HVMView 挂渲染
    public private(set) var consoleBridge: ConsoleBridge? // virtio-console 桥

    public init(config: VMConfig, bundleURL: URL)

    public func start() async throws
    public func requestStop() throws       // ACPI 软关机
    public func forceStop() async throws   // VZ.stop, 等同拔电源
    public func pause() async throws
    public func resume() async throws

    @discardableResult
    public func addStateObserver(_ handler: @escaping (RunState) -> Void) -> UUID
    public func removeStateObserver(_ token: UUID)
}
```

实现注记: 最初设计是 `actor`, 但 VZ 类多数非 `Sendable`, 跨 actor 传递触发 Swift 6 并发错误. VZ API 本身要求主线程调用, 因此改为 `@MainActor final class`, 既满足 VZ 约束又天然串行.

观察者注册时 **不立即投递当前 state**: 注册时若 state=.stopped, 后续 .stopped → cleanup 会 removeStateObserver, 导致真正的 .running 丢失. 调用方需要时主动读 `self.state`.

## 配置构建 (`ConfigBuilder.build`)

```swift
public enum ConfigBuilder {
    public struct BuildResult {
        public let vzConfig: VZVirtualMachineConfiguration
        public let consoleBridge: ConsoleBridge   // 必须由 VMHandle 持有
    }
    public static func build(from config: VMConfig, bundleURL: URL) throws -> BuildResult
}
```

`consoleBridge` 必须由 caller (VMHandle) 持有, 否则 fd 被 ARC 回收会令 VZ 拿到失效 attachment.

### 步骤

1. CPU 数校验 (`VZVirtualMachineConfiguration.minimumAllowedCPUCount...maximumAllowedCPUCount`)
2. 内存校验 (`minimumAllowedMemorySize...maximumAllowedMemorySize`, MiB 单位)
3. 按 `guestOS` 分流:
   - `.macOS` → `MacPlatform.load(from:)` 读 `bundle/auxiliary/` 三件套 + `VZMacOSBootLoader`
   - `.linux` → `VZGenericPlatformConfiguration` + `VZEFIBootLoader` + `VZEFIVariableStore` (复用 / 创建 `bundle/nvram/efi-vars.fd`)
   - `.windows` → 直接 throw `unsupportedGuestOS`, 由 `VMConfig.validate` + 这里双重拦截
4. 图形设备:
   - macOS → `VZMacGraphicsDeviceConfiguration`, 单 display 1920×1080 @ 220ppi
   - Linux → `VZVirtioGraphicsDeviceConfiguration`, 单 scanout 1024×768
5. 输入设备:
   - macOS → `VZMacKeyboardConfiguration` + `VZMacTrackpadConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration`
   - Linux → `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration`
6. 磁盘: 遍历 `config.disks` → `VZDiskImageStorageDeviceAttachment` → `VZVirtioBlockDeviceConfiguration`
   - **Linux guest 强制** `cachingMode: .cached, synchronizationMode: .fsync`. 默认 `.automatic` 在 Linux 上触发 I/O error / 数据损坏 (UTM #4840), curtin extract 卡死的根因
7. ISO (仅 Linux + `bootFromDiskOnly==false`): `ISOValidator.validate` → `VZUSBMassStorageDeviceConfiguration`
8. 网卡: `config.networks.map(NICFactory.make)` (见 [NETWORK.md](NETWORK.md))
9. 熵源: `VZVirtioEntropyDeviceConfiguration`
10. Virtio console serial: `ConsoleBridge` 提供双向 pipe, 向 `bundle/logs/console-<date>.log` tee
11. `vz.validate()` 终审, 失败封装成 `BackendError.configInvalid`

### macOS guest 平台 (MacPlatform)

读 `bundle/auxiliary/`:

```
auxiliary/hardware-model      → VZMacHardwareModel
auxiliary/machine-identifier  → VZMacMachineIdentifier
auxiliary/aux-storage         → VZMacAuxiliaryStorage
```

三件套**仅在装机时**由 `HVMInstall.MacAuxiliaryFactory` 写入, 之后随 bundle 不可变. 详见 [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md).

### Linux guest 平台

EFI 变量存储 `bundle/nvram/efi-vars.fd`:

- 已存在 → `VZEFIVariableStore(url:)` 加载
- 不存在 → `VZEFIVariableStore(creatingVariableStoreAt:)` 创建并落盘

Rosetta 共享当前**未在 ConfigBuilder 中实现** (`LinuxSpec.rosettaShare` 字段已声明, 等独立通路落地).

## 生命周期

```
   ┌───────┐  start()   ┌──────────┐  KVO  ┌─────────┐
   │stopped│───────────▶│ starting │──────▶│ running │
   └───▲───┘            └──────────┘       └────┬────┘
       │                                        │
       │  guestDidStop / didStopWithError       │ requestStop
       │◀────────── (delegate) ─────────────────┤ pause / resume
       │                                        │
       │             forceStop()                │
       └────────────────────────────────────────┘
```

### `start()`

1. 校验 state == .stopped, 否则 `BackendError.invalidTransition`
2. `ConfigBuilder.build` → 失败 → `state = .error(...)` 抛出
3. `VZVirtualMachine(configuration:)` + 装 delegate
4. `await vm.start { ... }` (continuation 桥)
5. `state = .running`

### `requestStop()` / `forceStop()`

- `requestStop()`: 同步调用 `vm.requestStop()`, 触发 guest ACPI shutdown, 由 delegate `guestDidStop` 翻成 `.stopped`. 不内置超时升级 — 上层 GUI 给用户"超时改强停"按钮
- `forceStop()`: `vm.stop { }` async, 立即终止

两者在 `vm == nil` 时统一抛 `invalidTransition`, 不做幂等吞掉; GUI/CLI 自己先看 `state`.

### `pause()` / `resume()`

直接 `vm.pause/resume { }`. **不做 save state 到磁盘**: VZ `saveMachineStateTo` 需要快照设计, 超出当前范围. 进程退出即丢失暂停状态.

## 事件订阅

`VMHandle.addStateObserver` 注册回调; `delegate` 与 KVO 共同驱动:

- `Delegate.guestDidStop(_:)` → `.stopped`
- `Delegate.virtualMachine(_:didStopWithError:)` → `.error(error.localizedDescription)`, 把 VZ 真实错误透传 (磁盘 IO / 配置不支持 / firmware 验证失败 等)
- `onVZStateChanged` 把 VZ 瞬态 (`.starting/.stopping`) 过滤, 只在稳定态下广播, 避免覆盖 `requestStop` 自己设的 `.stopping`

`consoleBridge` 在 `.stopped` / `.error` 时被 `close()` 释放, 防止 fd 泄漏.

## ConsoleBridge

`HVMBackend/ConsoleBridge.swift`. 双向 pipe + 日志 tee + ring buffer:

- guest → host pipe → tee 到 `bundle/logs/console-<date>.log` (按天 rotate, 唯一允许写 bundle/logs 的来源)
- host → guest pipe → 写入由 `hvm-dbg console` / VMHost IPC 转发

VZ 端走 `VZFileHandleSerialPortAttachment(fileHandleForReading:fileHandleForWriting:)` 挂在 `VZVirtioConsoleDeviceSerialPortConfiguration` 上. fd 生命周期由 `ConsoleBridge` 控制.

## VZ 能力边界 (硬约束)

CLAUDE.md "VZ 能力边界约束" 同款, 下列能力即使用户要求也不实现:

- **x86_64 / riscv64 guest**: VZ 只支持原生 arm64, 无 TCG
- **Windows guest**: VZ 无 TPM, Win11 装不了; Win10 ARM ISO 已断源. Windows 走 QEMU 后端
- **host USB 设备直通**: VZ 无 `usb-host` 等价, 仅 `VZUSBMassStorageDevice`. U 盘需要先 `dd` 成 image 再挂
- **多 VM 共享 bundle**: 一个 `.hvmz` 同时只能被一个进程打开, fcntl flock 互斥 (`HVMBundle/BundleLock`)
- **热插拔 CPU/内存**: VZ 不支持运行时改, 必须停机重配
- **save state 快照**: 不做; APFS clonefile 整 bundle 走 `SnapshotManager` (见 [STORAGE.md](STORAGE.md))

## VZ Bridged 现状

`VZBridgedNetworkDeviceAttachment` 依赖 `com.apple.vm.networking` entitlement. **当前 `app/Resources/HVM.entitlements` 未启用** (申请审批中, 详见 [ENTITLEMENT.md](ENTITLEMENT.md)).

未启用时 `VZBridgedNetworkInterface.networkInterfaces` 数组为空, `NICFactory.make(spec: .vmnetBridged)` 会抛 `HVMError.net(.bridgedInterfaceNotFound(requested:available:))`. 在此期间:

- VZ 后端用户应当走 `.user` (NAT) 模式
- 真正需要 bridged → 切 QEMU 后端 + socket_vmnet bridged daemon

entitlement 通过后只需在 `HVM.entitlements` 解开 `com.apple.vm.networking` 即可启用, 代码无需改动.

## 错误映射 (`VZErrorMapping`)

`BackendError.fromVZ(_:op:)` 把 `VZError` / `NSError` 翻成结构化 `BackendError`. VZ 报错文本通常携带 errno + 内部代号, 直接展示对用户不友好. 当前最重要的是把 `didStopWithError` 的 `error.localizedDescription` 完整透传到 `RunState.error(...)`, 让 GUI 能告诉用户具体死因 (磁盘满 / 损坏 firmware / 配置不支持 等).

## 不做什么

1. 不做 save state / live migration (VZ 不支持或代价过大)
2. 不做 CPU pinning / NUMA (VZ 不暴露)
3. 不开 memory ballooning, guest 要多少给多少
4. 不跨进程复用 `VZVirtualMachine` 实例 (一个 VMHost 进程一个)
5. 不做 USB 设备直通 (VZ API 缺)
6. 不做共享目录 / VirtioFS (字段已声明但 ConfigBuilder 暂未挂载, 等独立 PR)

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| C1 | `requestStop` 超时升级是否做成 | 当前 GUI 自带"超时改强停"按钮, backend 不内置 | 已决 |
| C2 | 多 NIC GUI 暴露 | NetworkSpec 是数组, GUI 已支持折叠多卡 | 已决 |
| C3 | Rosetta share 何时落 ConfigBuilder | 等 Linux M3 优化阶段 | TBD |
| C4 | 共享目录 (VirtioFS) | 后续独立 PR, 字段保留 | TBD |

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 模块全景
- [VM_BUNDLE.md](VM_BUNDLE.md) — `config.yaml` schema
- [STORAGE.md](STORAGE.md) — 磁盘 attachment 数据
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — VZView 嵌入
- [NETWORK.md](NETWORK.md) — NICFactory + 网络模式
- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — Windows / 可选 Linux QEMU 路径
- [ENTITLEMENT.md](ENTITLEMENT.md) — `com.apple.vm.networking` 申请追踪
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — IPSW / ISO 装机

---

**最后更新**: 2026-05-04
