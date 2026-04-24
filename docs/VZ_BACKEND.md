# VZ Backend 设计 (`HVMBackend`)

## 目标

`HVMBackend` 是唯一封装 `Virtualization.framework` 的模块。对上提供:

1. **配置构建**: 把 `VMConfig` 翻译成 `VZVirtualMachineConfiguration`
2. **生命周期**: 启动 / 停止 / 暂停 / 恢复, 统一状态枚举
3. **事件订阅**: 状态变化、guest 崩溃、I/O 错误
4. **校验**: 上层传入参数在构建前就拒绝, 避免 VZ 运行时报错难理解

其他模块(GUI/CLI/dbg)一律不 `import Virtualization`, 所有 VZ 调用走 Backend。例外:
- `HVMDisplay` 需要暴露 `VZVirtualMachineView`, 该 view 必须在同一进程内
- `HVMInstall` 需要 `VZMacOSInstaller`, 归类为 "安装流程相关的 VZ 封装"

## 职责边界

| 做 | 不做 |
|---|---|
| 读 `VMConfig`, 产出 `VZVirtualMachineConfiguration` | 直接读写 `config.json`(归 `HVMBundle`) |
| 管理 `VZVirtualMachine` 实例生命周期 | 创建 / 扩容磁盘(归 `HVMStorage`) |
| KVO `.state`, 发布到外部 | 提供 UI 展示 |
| 构建 NAT / bridged attachment | 决定 bridged 是否可用(由上层根据 entitlement 传入) |
| 处理 VZ 的 delegate callback | 处理 guest 内业务(无法, guest 是黑盒) |

## 数据类型

### RunState

```swift
public enum RunState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case error(BackendError)
}
```

映射自 `VZVirtualMachine.State`:

| VZ State | RunState |
|---|---|
| `.stopped` | `.stopped` |
| `.starting` | `.starting` |
| `.running` | `.running` |
| `.paused` | `.paused` |
| `.resuming` | `.starting`(合并) |
| `.pausing` | `.running`(瞬态合并) |
| `.stopping` | `.stopping` |
| `.saving` / `.restoring` | N/A (我们不做 snapshot save state, 见下) |
| `.error` | `.error(.vzInternal(desc))` |

### BackendError

```swift
public enum BackendError: Error, Sendable {
    case configInvalid(field: String, reason: String)
    case cpuOutOfRange(requested: Int, min: Int, max: Int)
    case memoryOutOfRange(requestedMiB: UInt64, minMiB: UInt64, maxMiB: UInt64)
    case diskNotFound(path: String)
    case diskBusy(path: String)
    case unsupportedGuestOS(raw: String)
    case rosettaUnavailable             // rosetta 未安装
    case bridgedNotEntitled             // entitlement 没批下来
    case ipswInvalid(reason: String)
    case vzInternal(description: String)
}
```

### VMHandle

```swift
public actor VMHandle {
    public nonisolated let id: UUID               // 来自 VMConfig.id
    public nonisolated let bundleURL: URL

    public private(set) var state: RunState
    public var stateStream: AsyncStream<RunState> { get }

    public init(config: VMConfig, bundleURL: URL) async throws
    public func start() async throws
    public func requestStop() async throws        // 软关机, 发 ACPI shutdown
    public func forceStop() async throws          // 直接 VZ.stop()
    public func pause() async throws
    public func resume() async throws
    public func takeThumbnail() async -> Data?    // 截当前 frame buffer
}
```

- 所有方法在 actor 内串行, 避免 VZ 状态机并发问题
- `stateStream` 给 GUI 订阅, 内部由 KVO 驱动

## 配置构建

核心函数:

```swift
enum ConfigBuilder {
    static func build(from config: VMConfig, bundle: URL) throws -> VZVirtualMachineConfiguration
}
```

### 构建步骤

```
 1. 创建 VZVirtualMachineConfiguration()
 2. 设置 cpuCount / memorySize
 3. 根据 guestOS 创建 platform:
      .macOS  → VZMacPlatformConfiguration
      .linux  → VZGenericPlatformConfiguration
 4. 创建 bootLoader:
      .macOS  → VZMacOSBootLoader
      .linux  → VZEFIBootLoader (带 nvram 文件)
 5. 遍历 disks[], 创建 VZVirtioBlockDeviceConfiguration + VZDiskImageStorageDeviceAttachment
 6. 可选: ISO 挂载成 VZUSBMassStorageDevice(仅 bootFromDiskOnly=false)
 7. 遍历 networks[], 创建 VZVirtioNetworkDeviceConfiguration + NAT/Bridged attachment
 8. 显示设备:
      .macOS  → VZMacGraphicsDeviceConfiguration
      .linux  → VZVirtioGraphicsDeviceConfiguration
 9. 输入设备:
      VZUSBScreenCoordinatePointingDeviceConfiguration
      VZUSBKeyboardConfiguration
      .macOS 另加 VZMacTrackpadConfiguration (macOS 13+)
10. Entropy: VZVirtioEntropyDeviceConfiguration
11. 音频: VZVirtioSoundDeviceConfiguration (默认关, 配置打开才加)
12. Console: VZVirtioConsoleDeviceConfiguration + 默认 serial port (供 hvm-dbg)
13. 共享目录: 可选 VZVirtioFileSystemDeviceConfiguration
14. Rosetta (仅 linux, rosettaShare=true): 注册为 VirtioFS share
15. config.validate() — 让 VZ 自校验
```

### 参数校验

在调用 VZ 之前就拒绝明显错误:

```swift
let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
guard (minCPU...maxCPU).contains(config.cpuCount) else {
    throw BackendError.cpuOutOfRange(requested: config.cpuCount, min: minCPU, max: maxCPU)
}

let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize / 1024 / 1024
let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize / 1024 / 1024
guard (minMem...maxMem).contains(config.memoryMiB) else {
    throw BackendError.memoryOutOfRange(...)
}
```

### macOS guest 专属

macOS guest 构建时需要:

```swift
let platform = VZMacPlatformConfiguration()
platform.hardwareModel = try loadHardwareModel(from: bundle)      // auxiliary/hardware-model
platform.machineIdentifier = try loadMachineIdentifier(from: bundle)
platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxStorageURL)
```

这三个文件必须在**创建 bundle 时**由 `HVMInstall` 写入, 一旦 VM 创建就不可变。详见 [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md)。

### Linux guest 专属

```swift
let bootLoader = VZEFIBootLoader()
bootLoader.variableStore = VZEFIVariableStore(url: nvramURL)       // bundle/nvram/efi-vars.fd
let platform = VZGenericPlatformConfiguration()
```

若 `config.linux.rosettaShare == true`, 添加:

```swift
let rosetta = try VZLinuxRosettaDirectoryShare()
let tag = VZVirtioFileSystemDeviceConfiguration(tag: "RosettaShare")
tag.share = rosetta
```

Rosetta 不可用(系统未安装)时抛 `BackendError.rosettaUnavailable`, 由 GUI 引导用户运行 `softwareupdate --install-rosetta`。

## 生命周期

### 状态机

```
  ┌───────┐   start()   ┌──────────┐           ┌─────────┐
  │stopped│─────────────▶│ starting │──────────▶│ running │
  └───▲───┘              └──────┬───┘           └────┬────┘
      │                         │ fail                │
      │                         ▼                     │
      │                    ┌────────┐                 │
      │                    │ error  │                 │
      │                    └────────┘                 │
      │                                               │
      │         forceStop()                           │
      │◀──────────────────────────────────────────────┤
      │         requestStop() → stopping              │
      │                                               │
      │                      pause()                  │
      │                   ┌───────────┐               │
      │                   │           ▼               │
      │                   │      ┌────────┐           │
      │                   │      │ paused │           │
      │                   │      └────┬───┘           │
      │                   │           │ resume()      │
      │                   └───────────┘               │
```

### `start()` 实现

```swift
func start() async throws {
    guard state == .stopped else { throw BackendError.invalidTransition(from: state, to: .starting) }
    state = .starting

    let vzConfig = try ConfigBuilder.build(from: config, bundle: bundleURL)
    try vzConfig.validate()

    let vm = VZVirtualMachine(configuration: vzConfig)
    self.vm = vm
    setupKVO(vm)

    try await withCheckedThrowingContinuation { cont in
        vm.start { result in
            switch result {
            case .success: cont.resume()
            case .failure(let e): cont.resume(throwing: BackendError.vzInternal(description: "\(e)"))
            }
        }
    }
    // state 由 KVO 自动切 running
}
```

### `requestStop()` vs `forceStop()`

- `requestStop()`: `vm.requestStop()`, 触发 guest ACPI shutdown, 等待其自然关机; 超时(默认 60s)后自动升级为 `forceStop`
- `forceStop()`: `vm.stop()`, guest 直接被杀, 等同拔电源

### `pause()` / `resume()`

- 使用 `vm.pause { }` / `vm.resume { }`
- **不实现 save state 到磁盘**: `VZVirtualMachine.saveMachineStateTo` 需要额外设计(快照文件在哪、恢复时 config 必须完全匹配), 超 MVP 范畴。MVP pause 仅保持内存中暂停, 退出进程即丢失

## 事件订阅

### 状态流

```swift
extension VMHandle {
    public var stateStream: AsyncStream<RunState> {
        AsyncStream { cont in
            let token = self.addStateListener { newState in
                cont.yield(newState)
            }
            cont.onTermination = { _ in self.removeStateListener(token) }
        }
    }
}
```

多个订阅者各自拿一个 stream, 内部保留 listener 数组。

### KVO

```swift
vm.observe(\.state, options: [.initial, .new]) { [weak self] _, _ in
    Task { await self?.onVZStateChanged() }
}
```

`onVZStateChanged` 把 VZ state 翻成 `RunState` 并广播。

### delegate

`VZVirtualMachineDelegate` 几个关键回调:

```swift
func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
    // 异常停止, state 切 .error
}

func guestDidStop(_ vm: VZVirtualMachine) {
    // 正常关机, state 切 .stopped
}
```

## 共享目录 (VirtioFS)

用户可在 config 里声明 host 目录共享给 guest:

```json
"shares": [
  { "tag": "Shared", "hostPath": "/Users/me/Projects/shared", "readOnly": false }
]
```

构建时:

```swift
let share = VZSharedDirectory(url: hostURL, readOnly: spec.readOnly)
let device = VZVirtioFileSystemDeviceConfiguration(tag: spec.tag)
device.share = VZSingleDirectoryShare(directory: share)
```

Guest 内挂载:

```
# Linux
mount -t virtiofs Shared /mnt/shared

# macOS 13+
# Finder → Go → Connect to Server → 自动出现在 "Other" tag
```

## 并发 / 线程

- **actor 内**: 所有 VZ API 调用
- **主线程**: VZ 要求 `VZVirtualMachine.start/stop/pause/resume` 的 completion handler 在主线程。实现里在 handler 里 `Task { await self.actorFunc() }` 桥接
- **delegate 回调**: 默认主线程, 里面也用 `Task` 切入 actor

## 测试策略

- `HVMBackendTests/ConfigBuilderTests.swift` — 输入 VMConfig, 断言产出的 VZ 配置各字段
- `HVMBackendTests/ValidationTests.swift` — 边界值: CPU 0 / 过大、内存 64 MiB(低于最小) 等
- 集成测试**不在 CI 里跑 VZ**(需要 entitlement + 真实硬件), 本地 `make test-integration` 手动触发

## 不做什么

1. **不做 save state 快照**: 复杂且容易出错, 走"关机 + 重启"即可
2. **不做 live migration**: VZ 无此能力
3. **不做 CPU pinning / NUMA**: VZ 不暴露
4. **不自动回收内存**: memory ballooning 不开, guest 要多少给多少直到 OS 报 OOM
5. **不跨进程复用 VZVirtualMachine**: 一个 VMHost 进程一个实例

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| C1 | `requestStop` 超时时间是否做成配置 | 固定 60s | 有用户反馈再说 |
| C2 | 是否支持多 NIC | 支持(NetworkSpec 是数组), 但 GUI 只暴露一张 | M2 |
| C3 | audio 设备默认关还是开 | 默认关, config 里 `audio: true` 打开 | 已决 |
| C4 | serial console 的 FIFO 路径 | `bundle/run/console.sock`(运行时创建, 停机删) | M1 |

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 模块全景
- [VM_BUNDLE.md](VM_BUNDLE.md) — config 字段
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 装机特有 VZ 调用
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — 显示/输入设备
- [NETWORK.md](NETWORK.md) — 网络 attachment

---

**最后更新**: 2026-04-25
