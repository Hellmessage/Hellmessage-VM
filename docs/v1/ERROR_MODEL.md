# 错误模型

## 目标

- 全项目共用一套错误抽象, `HVMCore` 定义根类型 + UserFacing 映射
- 错误带**code** (稳定 dotted 字符串) + **面向用户中文文案** + **结构化 details** + 可选 **hint** (下一步建议)
- GUI / CLI / hvm-dbg 三端统一入口, 不临时造新 error 类型
- 不在日志 / GUI / json 输出中泄露敏感信息 (team ID / 证书 SHA / 私钥路径 / token)
- GUI 错误对话框走统一 `ErrorDialog`, **禁止用 `NSAlert`** (CLAUDE.md GUI 约束)

## 根类型

权威定义: `app/Sources/HVMCore/HVMError.swift`。

```swift
public enum HVMError: Error, Sendable {
    case bundle(BundleError)
    case storage(StorageError)
    case backend(BackendError)
    case install(InstallError)
    case net(NetError)
    case ipc(IPCError)
    case config(ConfigError)
}

public extension HVMError {
    var userFacing: UserFacingError { ... }   // dispatch 到子枚举
}
```

> 注: 当前实现**没有** `dbg.*` / `qemu.*` / `vmnet.*` 这种独立 domain — `hvm-dbg` 的错误统一以 `BackendError` / `IPCError` 抛出; QEMU 后端启动相关错误用 `BackendError.qemuHostStartupTimeout` 等; vmnet 走 `NetError`。

### 四要素 (UserFacingError)

每个 `HVMError` 都能输出四个字段, 由 `var userFacing: UserFacingError` 翻译:

| 字段 | 类型 | 说明 |
|---|---|---|
| `code` | String | 稳定 dotted key, 例 `bundle.busy`; 维护在 `HVMCore/ErrorCodes.swift` enum |
| `message` | String | 一句话中文, 给用户看 |
| `details` | `[String: String]` | 结构化上下文 (路径、pid、errno 等); 统一 `String → String` 便于 LLM / json 解析 |
| `hint` | `String?` | 下一步建议 (可选) |

```swift
public struct UserFacingError: Sendable, Equatable, Codable {
    public let code: String
    public let message: String
    public let details: [String: String]
    public let hint: String?
}
```

## 子错误枚举

### BundleError → `bundle.*`

| case | code | message |
|---|---|---|
| `.notFound(path:)` | `bundle.not_found` | Bundle 未找到 |
| `.busy(pid:holderMode:)` | `bundle.busy` | Bundle 被另一个进程占用 |
| `.invalidSchema(version:expected:)` | `bundle.invalid_schema` | Bundle schema 版本不兼容 |
| `.parseFailed(reason:path:)` | `bundle.parse_failed` | Bundle 配置解析失败 |
| `.primaryDiskMissing(path:)` | `bundle.primary_disk_missing` | Bundle 主盘文件缺失 |
| `.corruptAuxiliary(reason:)` | `bundle.corrupt_auxiliary` | Bundle auxiliary 数据损坏, VM 已无法恢复 |
| `.writeFailed(reason:path:)` | `bundle.write_failed` | 写入 bundle 文件失败 |
| `.outsideSandbox(requestedPath:)` | `bundle.outside_sandbox` | 磁盘路径逃出 bundle 目录 |
| `.alreadyExists(path:)` | `bundle.already_exists` | Bundle 目录已存在 |
| `.lockFailed(reason:)` | `bundle.lock_failed` | Bundle 加锁失败 |

### StorageError → `storage.*`

| case | code | message |
|---|---|---|
| `.diskAlreadyExists(path:)` | `storage.disk_exists` | 磁盘文件已存在 |
| `.creationFailed(errno:path:)` | `storage.creation_failed` | 创建磁盘文件失败 |
| `.ioError(errno:path:)` | `storage.io_error` | 磁盘 I/O 失败 |
| `.shrinkNotSupported(currentBytes:requestedBytes:)` | `storage.shrink_unsupported` | 不支持缩容磁盘 |
| `.isoMissing(path:)` | `storage.iso_missing` | ISO 文件不在原位置 |
| `.isoSizeSuspicious(bytes:)` | `storage.iso_size_suspicious` | ISO 文件大小异常 |
| `.cloneFailed(errno:)` | `storage.clone_failed` | APFS clonefile 失败 |
| `.volumeSpaceInsufficient(required:available:)` | `storage.volume_space_insufficient` | 磁盘卷空间不足 |
| `.importInvalid(reason:path:)` | `storage.import_invalid` | 导入磁盘镜像不可用 |

### BackendError → `backend.*`

| case | code | message |
|---|---|---|
| `.configInvalid(field:reason:)` | `backend.config_invalid` | VM 配置无效 |
| `.cpuOutOfRange(requested:min:max:)` | `backend.cpu_out_of_range` | CPU 核心数超出范围 |
| `.memoryOutOfRange(requestedMiB:minMiB:maxMiB:)` | `backend.memory_out_of_range` | 内存大小超出范围 |
| `.diskNotFound(path:)` | `backend.disk_not_found` | 磁盘文件未找到 |
| `.diskBusy(path:)` | `backend.disk_busy` | 磁盘被另一个进程占用 |
| `.unsupportedGuestOS(raw:)` | `backend.unsupported_guest_os` | 不支持的 guest OS |
| `.rosettaUnavailable` | `backend.rosetta_unavailable` | Rosetta 2 不可用 |
| `.bridgedNotEntitled` | `backend.bridged_not_entitled` | 桥接网络 entitlement 未启用 |
| `.ipswInvalid(reason:)` | `backend.ipsw_invalid` | IPSW 文件无效或不被支持 |
| `.invalidTransition(from:to:)` | `backend.invalid_transition` | VM 状态不允许当前操作 |
| `.vzInternal(description:)` | `backend.vz_internal` | VZ 内部错误 |
| `.qemuHostStartupTimeout(waitedSeconds:logPath:)` | `backend.qemu_host_startup_timeout` | QEMU 宿主进程未在规定时间内就绪 |

### InstallError → `install.*`

| case | code | message |
|---|---|---|
| `.ipswNotFound(path:)` | `install.ipsw_not_found` | IPSW 文件未找到 |
| `.ipswUnsupported(reason:)` | `install.ipsw_unsupported` | IPSW 版本不受 VZ 支持 |
| `.ipswDownloadFailed(reason:)` | `install.ipsw_download_failed` | IPSW 下载失败 |
| `.auxiliaryCreationFailed(reason:)` | `install.aux_creation_failed` | 创建 auxiliary 数据失败 |
| `.diskSpaceInsufficient(required:available:)` | `install.disk_space_insufficient` | 磁盘空间不足以安装 |
| `.installerFailed(reason:)` | `install.installer_failed` | 装机流程失败 |
| `.rosettaNotInstalled` | `install.rosetta_not_installed` | 系统未安装 Rosetta 2 |
| `.isoNotFound(path:)` | `install.iso_not_found` | ISO 文件未找到 |

### NetError → `net.*`

| case | code | message |
|---|---|---|
| `.bridgedNotEntitled` | `net.bridged_not_entitled` | 桥接网络 entitlement 未启用 |
| `.bridgedInterfaceNotFound(requested:available:)` | `net.bridged_interface_not_found` | 指定的桥接接口不存在 |
| `.macInvalid(_:)` | `net.mac_invalid` | MAC 地址格式非法 |
| `.macNotLocallyAdministered(_:)` | `net.mac_not_locally_administered` | MAC 必须是 locally-administered |

### IPCError → `ipc.*`

| case | code | message |
|---|---|---|
| `.socketNotFound(path:)` | `ipc.socket_not_found` | IPC socket 不存在 |
| `.connectionRefused(path:)` | `ipc.connection_refused` | IPC 连接被拒绝 |
| `.protocolMismatch(expected:got:)` | `ipc.protocol_mismatch` | IPC 协议版本不匹配 |
| `.readFailed(reason:)` | `ipc.read_failed` | IPC 读取失败 |
| `.writeFailed(reason:)` | `ipc.write_failed` | IPC 写入失败 |
| `.decodeFailed(reason:)` | `ipc.decode_failed` | IPC 消息解码失败 |
| `.remoteError(code:message:)` | `ipc.remote_error` | (透传 remote 端 message) |
| `.timedOut` | `ipc.timed_out` | IPC 调用超时 |
| `.serverBindFailed(path:errno:)` | `ipc.server_bind_failed` | 无法绑定 IPC socket |

### ConfigError → `config.*`

手动编辑 `config.yaml` 产生的语义错。

| case | code | message |
|---|---|---|
| `.missingField(name:)` | `config.missing_field` | 配置缺少必填字段 |
| `.invalidEnum(field:raw:allowed:)` | `config.invalid_enum` | 配置字段取值非法 |
| `.invalidRange(field:value:range:)` | `config.invalid_range` | 配置字段值超出允许范围 |
| `.duplicateRole(role:)` | `config.duplicate_role` | 配置中出现重复的角色 |

## 错误码权威清单

`app/Sources/HVMCore/ErrorCodes.swift` 是 enum 形式的全列, 编译期检查。新增错误**必须三处同步**:

1. `HVMError.swift` 加 enum case
2. `ErrorCodes.swift` 加 enum case
3. 本文档表格补一行

`userFacing` 内大部分 case 走 `HVMErrorCode.<key>.rawValue` 渲染 code; 少数后加的 case (`bundle.already_exists` / `bundle.lock_failed` / `storage.volume_space_insufficient` / `backend.invalid_transition` / `ipc.server_bind_failed`) 当前直接写字面量, **应在下一次重构补回 `ErrorCodes`** (TODO: errorcode-coverage)。

## 用户面文案规范

统一原则:

1. 一句话, 中文, ≤ 40 字符
2. 先说**发生了什么**, 不说代码细节
3. 不说"未知错误 (-42)", 要说具体场景
4. 不使用感叹号
5. 术语保留英文 (CPU / IPSW / VZ / QEMU / SecureBoot / TPM)
6. **不暴露内部路径**: `third_party/qemu-stage/` / `~/Library/Caches/` 等仓库内部路径不应给用户看; 必要时用相对项 (例: "QEMU 后端二进制") 描述

示例对照:

| 不推荐 | 推荐 |
|---|---|
| `Error: errno 16 EBUSY` | `磁盘被另一个进程占用` |
| `VZVirtualMachineError.invalidConfiguration` | `VM 配置无效, 请检查 CPU/内存数量` |
| `Operation failed (code 4)` | `bundle 未找到, 路径: /Users/me/foo.hvmz` |
| `未知错误, 请重试` | `启动超时, guest 可能未正确引导; 查看日志: ...` |
| `qemu-system-aarch64 exec failed at /Users/.../third_party/qemu-stage/bin/...` | `QEMU 后端二进制启动失败, 请检查日志` |

## hint 字段

可选, 给用户"下一步怎么办":

| code | hint |
|---|---|
| `bundle.busy` | 请先关闭占用该 bundle 的进程 |
| `bundle.not_found` | 确认路径是否正确, 或用 hvm-cli list 查看可用 bundle |
| `bundle.invalid_schema` | 请升级 HVM 或换用匹配的 bundle |
| `bundle.already_exists` | 换个名称, 或先删除已有 bundle |
| `backend.cpu_out_of_range` | 当前系统支持 N~M 核心, 请调整后重试 |
| `backend.rosetta_unavailable` | 执行: softwareupdate --install-rosetta --agree-to-license |
| `backend.bridged_not_entitled` | 详见 docs/ENTITLEMENT.md |
| `backend.qemu_host_startup_timeout` | 请查看 log 中 host-*.log; Bridged/Shared 时确认 socket_vmnet 与 sudoers 已正确配置, 并排除 bundle 正被其他进程占用 |
| `install.rosetta_not_installed` | 执行: softwareupdate --install-rosetta --agree-to-license |
| `storage.iso_missing` | 重新在配置里选择 ISO 文件位置 |
| `storage.shrink_unsupported` | 如需回收空间, 建议在 guest 内清零后 rebuild bundle |
| `storage.import_invalid` | 仅支持 qcow2 / raw 镜像; 校验镜像可读、大小在合理范围 |
| `net.bridged_not_entitled` | 详见 docs/ENTITLEMENT.md |
| `net.mac_not_locally_administered` | 首字节低两位第二位必须为 1, 例: 02:xx:xx:xx:xx:xx |
| `ipc.socket_not_found` | VM 可能未运行, 或 socket 被清理 |

## GUI 渲染: ErrorDialog (强制)

CLAUDE.md GUI 约束: 所有错误对话框走统一 `ErrorDialog`, **禁止用 `NSAlert`**; 弹窗只能通过点击右上角 X 按钮关闭, 禁止点击遮罩层关闭。详见 [GUI.md](GUI.md)。

```swift
@Environment(\.errorPresenter) var error

do {
    try await vm.start()
} catch let e as HVMError {
    let uf = e.userFacing
    error.present(.init(
        title: titleFor(code: uf.code),
        message: uf.message,
        details: uf.sanitizedDetails.map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
        primaryAction: ("好", {}),
        secondaryAction: uf.hint.map { hint in ("查看建议", { showHintSheet(hint) }) }
    ))
}
```

标题按 code 前缀选:

| code 前缀 | 标题 |
|---|---|
| `bundle.*` | Bundle 错误 |
| `storage.*` | 磁盘错误 |
| `backend.*` | VM 运行错误 |
| `install.*` | 安装错误 |
| `net.*` | 网络错误 |
| `ipc.*` | 通信错误 |
| `config.*` | 配置错误 |

## CLI 渲染

### human 模式

```
错误: 磁盘被另一个进程占用
  code:    bundle.busy
  pid:     47820
  bundle:  /Users/me/VMs/foo.hvmz
  建议:    请先关闭占用该 bundle 的进程
```

退出码: 见 [CLI.md](CLI.md)。

### json 模式

```json
{
  "error": {
    "code": "bundle.busy",
    "message": "Bundle 被另一个进程占用",
    "details": {
      "pid": "47820",
      "bundle": "/Users/me/VMs/foo.hvmz"
    },
    "hint": "请先关闭占用该 bundle 的进程"
  }
}
```

`details` 统一 `String → String` (避免混合类型, 便于 LLM 解析)。

## hvm-dbg 渲染

同 CLI json 模式, 默认 json 输出。`hvm-dbg` 自身的错误 (例如 OCR 不可用 / screenshot 失败) 当前以 `IPCError.remoteError` 或 `BackendError.vzInternal` 抛出, 暂无独立 `dbg.*` domain。

## 日志约束

- 错误入日志格式固定: `ERROR [code=xxx] message | key1=value1 key2=value2`
- 日志统一走 `HVMCore/LogSink.swift` mirror 到 `os.Logger`, 落 `~/Library/Application Support/HVM/logs/<yyyy-MM-dd>.log` (跨 VM 共享) + `<displayName>-<uuid8>/host-<date>.log` (per-VM host); 详见 CLAUDE.md "日志路径约束"
- **details 里的值必须先脱敏** (`UserFacingError.sanitizedDetails`):

```swift
extension UserFacingError {
    public var sanitizedDetails: [String: String] {
        details.mapValues { value in looksSensitive(value) ? "***" : value }
    }
}

private func looksSensitive(_ s: String) -> Bool {
    let lower = s.lowercased()
    return lower.contains("token") ||
           lower.contains("password") ||
           lower.contains("secret") ||
           lower.hasPrefix("aps_") ||
           lower.contains("key=") ||
           (s.count > 64 && s.allSatisfy { $0.isHexDigit })  // 像 SHA
}
```

CLAUDE.md 明确**永远不得输出**的:

- team ID
- 证书 SHA
- 私钥路径

这三项 **永远** 替换为 `***`, 不走 `looksSensitive`, 直接硬编码黑名单兜底:

```swift
private let alwaysRedact: [String] = ["Q7L455FS97", "/Library/Keychains/", ".p12"]
```

`scripts/bundle.sh` 的输出也对应限制 — 签名相关代码 / 日志不打印 Team ID / 证书 SHA / 私钥路径, 详见 [BUILD_SIGN.md](BUILD_SIGN.md)。

## 从系统 Error 转换

VZ 抛出的 `NSError` 兜底转换:

```swift
extension BackendError {
    public init(wrapping error: Error) {
        if let ns = error as NSError?, ns.domain == "VZErrorDomain" {
            self = .vzInternal(description: ns.localizedDescription)
        } else {
            self = .vzInternal(description: "\(error)")
        }
    }
}
```

errno 走 `StorageError.ioError(errno:path:)` / `StorageError.creationFailed(errno:path:)` / `StorageError.cloneFailed(errno:)`, 渲染时取 `String(cString: strerror(e))`。

## 不做什么

1. **不做 error wrapping 链** (Swift 6 还没正式 underlying error 特性)。要链式信息, `details` 里放
2. **不做 i18n 多语言**: MVP 中文一版
3. **不做 error 上报 / 遥测**: 不联网
4. **不做 try? 吞错**: 所有非 UI 可恢复错误必须 propagate 到顶层
5. **不用 `fatalError` 处理可恢复错误**: 只用在"绝不可能发生"的不变量破坏上
6. **不暴露内部路径** (`third_party/qemu-stage/`、Keychain 路径、cache 子目录) 给最终用户

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| L1 | structured logging (os_log key-value) | Logger + metadata, MVP 足够 | 已决 |
| L2 | GUI ErrorDialog 是否按 code 加截图预览 | 不做, details 文本够 | 已决 |
| L3 | 错误文档页 (website) | 不做, 本文件表格即权威 | 已决 |
| L4 | 后加的 5 个直接字面量 code 回填进 `HVMErrorCode` enum | 计划修 (errorcode-coverage) | 待办 |

## 相关文档

- [GUI.md](GUI.md) — ErrorDialog 统一弹窗 (禁用 NSAlert)
- [CLI.md](CLI.md) — 退出码与 json 错误格式
- [DEBUG_PROBE.md](DEBUG_PROBE.md) — hvm-dbg 错误风格
- [BUILD_SIGN.md](BUILD_SIGN.md) — 签名日志脱敏要求
- [VM_BUNDLE.md](VM_BUNDLE.md) / [STORAGE.md](STORAGE.md) / [VZ_BACKEND.md](VZ_BACKEND.md) / [NETWORK.md](NETWORK.md) / [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 各子系统错误定义

---

**最后更新**: 2026-05-04
