# 错误模型

## 目标

- 全项目共用一套错误抽象, `HVMCore` 定义根类型
- 错误带**code**(稳定字符串) + **面向用户文案** + **技术 details**
- GUI / CLI / hvm-dbg 三端统一入口, 不临时造新 error 类型
- 不在日志中泄露敏感信息(token / team ID / 私钥路径)

## 根类型

```swift
// HVMCore/HVMError.swift
public enum HVMError: Error, Sendable, CustomStringConvertible {
    case bundle(BundleError)
    case storage(StorageError)
    case backend(BackendError)
    case install(InstallError)
    case net(NetError)
    case ipc(IPCError)
    case config(ConfigError)

    public var description: String { userFacing.message }
}
```

### 四要素

每个 `HVMError` 都能输出四个字段:

| 字段 | 类型 | 说明 |
|---|---|---|
| `code` | String | 稳定 dotted key, 例 `bundle.busy` |
| `message` | String | 一句话中文, 给用户看 |
| `details` | [String: String]? | 结构化上下文(路径、pid、errno 等) |
| `hint` | String? | 下一步建议 |

```swift
public struct UserFacingError: Sendable {
    public let code: String
    public let message: String
    public let details: [String: String]
    public let hint: String?
}

extension HVMError {
    public var userFacing: UserFacingError { ... }
}
```

## 子错误枚举

### BundleError

```swift
public enum BundleError: Error, Sendable {
    case notFound(path: String)
    case busy(pid: Int32, holderMode: String)
    case invalidSchema(version: Int, expected: Int)
    case parseFailed(reason: String, path: String)
    case primaryDiskMissing(path: String)
    case corruptAuxiliary(reason: String)
    case writeFailed(reason: String, path: String)
    case outsideSandbox(requestedPath: String)   // DiskSpec.path 逃出 bundle
}
```

code 映射:

| case | code |
|---|---|
| `.notFound` | `bundle.not_found` |
| `.busy` | `bundle.busy` |
| `.invalidSchema` | `bundle.invalid_schema` |
| `.parseFailed` | `bundle.parse_failed` |
| `.primaryDiskMissing` | `bundle.primary_disk_missing` |
| `.corruptAuxiliary` | `bundle.corrupt_auxiliary` |
| `.writeFailed` | `bundle.write_failed` |
| `.outsideSandbox` | `bundle.outside_sandbox` |

### StorageError

见 [STORAGE.md](STORAGE.md), 增补 code:

| case | code |
|---|---|
| `.diskAlreadyExists` | `storage.disk_exists` |
| `.creationFailed` | `storage.creation_failed` |
| `.ioError` | `storage.io_error` |
| `.shrinkNotSupported` | `storage.shrink_unsupported` |
| `.isoMissing` | `storage.iso_missing` |
| `.isoSizeSuspicious` | `storage.iso_size_suspicious` |
| `.cloneFailed` | `storage.clone_failed` |

### BackendError

见 [VZ_BACKEND.md](VZ_BACKEND.md), code 前缀 `backend.*`:

| case | code |
|---|---|
| `.configInvalid` | `backend.config_invalid` |
| `.cpuOutOfRange` | `backend.cpu_out_of_range` |
| `.memoryOutOfRange` | `backend.memory_out_of_range` |
| `.diskNotFound` | `backend.disk_not_found` |
| `.diskBusy` | `backend.disk_busy` |
| `.unsupportedGuestOS` | `backend.unsupported_guest_os` |
| `.rosettaUnavailable` | `backend.rosetta_unavailable` |
| `.bridgedNotEntitled` | `backend.bridged_not_entitled` |
| `.ipswInvalid` | `backend.ipsw_invalid` |
| `.vzInternal` | `backend.vz_internal` |

### InstallError

`install.*`, 见 [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md)。

### NetError

`net.*`, 见 [NETWORK.md](NETWORK.md)。

### IPCError

```swift
public enum IPCError: Error, Sendable {
    case socketNotFound(path: String)
    case connectionRefused
    case protocolMismatch(expected: Int, got: Int)
    case readFailed(reason: String)
    case writeFailed(reason: String)
    case decodeFailed(reason: String)
    case remoteError(code: String, message: String)
    case timedOut
}
```

`ipc.*`

### ConfigError

手动编辑 config.json 产生的语义错:

```swift
public enum ConfigError: Error, Sendable {
    case missingField(name: String)
    case invalidEnum(field: String, raw: String, allowed: [String])
    case invalidRange(field: String, value: String, range: String)
    case duplicateRole(role: String)
}
```

`config.*`

## 用户面文案规范

统一原则:

1. 一句话, 中文, ≤ 40 字符
2. 先说**发生了什么**, 不说代码细节
3. 不说"未知错误 (-42)", 要说具体
4. 不使用感叹号
5. 术语保留英文(CPU, IPSW, VZ)

示例对照:

| ❌ 差 | ✅ 好 |
|---|---|
| `Error: errno 16 EBUSY` | `磁盘被另一个进程占用` |
| `VZVirtualMachineError.invalidConfiguration` | `VM 配置无效, 请检查 CPU/内存数量` |
| `Operation failed (code 4)` | `bundle 未找到, 路径: /Users/me/foo.hvmz` |
| `未知错误, 请重试` | `启动超时, guest 可能未正确引导; 查看日志: ...` |

## hint 字段

可选, 给用户"下一步怎么办":

| error | hint |
|---|---|
| `bundle.busy` | `请先关闭占用该 bundle 的进程, pid: 47820` |
| `backend.cpu_out_of_range` | `当前系统支持 1~10 核心, 请调整后重试` |
| `net.bridged_not_entitled` | `桥接网络需 Apple 审批 entitlement, 详见 docs/ENTITLEMENT.md` |
| `install.rosettaNotInstalled` | `执行: softwareupdate --install-rosetta --agree-to-license` |
| `storage.iso_missing` | `重新在配置里选择 ISO 文件位置` |

## GUI 渲染: ErrorDialog

见 [GUI.md](GUI.md) "ErrorDialog: 统一错误入口":

```swift
@Environment(\.errorPresenter) var error

do {
    try await vm.start()
} catch let e as HVMError {
    let uf = e.userFacing
    error.present(.init(
        title: titleFor(code: uf.code),
        message: uf.message,
        details: uf.details.map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
        primaryAction: ("好", {}),
        secondaryAction: uf.hint.map { hint in
            ("查看建议", { showHintSheet(hint) })
        }
    ))
}
```

标题按 code 前缀选:

| code 前缀 | 标题 |
|---|---|
| `bundle.*` | `Bundle 错误` |
| `storage.*` | `磁盘错误` |
| `backend.*` | `VM 运行错误` |
| `install.*` | `安装错误` |
| `net.*` | `网络错误` |
| `ipc.*` | `通信错误` |
| `config.*` | `配置错误` |

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
    "message": "磁盘被另一个进程占用",
    "details": {
      "pid": "47820",
      "bundle": "/Users/me/VMs/foo.hvmz"
    },
    "hint": "请先关闭占用该 bundle 的进程"
  }
}
```

`details` 字段统一 `String` → `String`(避免混合类型, 便于 LLM 解析)。

## hvm-dbg 渲染

同 CLI json 模式, 默认 json 输出。

## 日志约束

- 错误入日志时格式固定: `ERROR [code=xxx] message | key1=value1 key2=value2`
- **details 里的值必须先脱敏**:

```swift
extension UserFacingError {
    public var sanitizedDetails: [String: String] {
        details.mapValues { value in
            if looksSensitive(value) { return "***" }
            return value
        }
    }
}

private func looksSensitive(_ s: String) -> Bool {
    let lower = s.lowercased()
    return lower.contains("token") ||
           lower.contains("password") ||
           lower.contains("secret") ||
           lower.hasPrefix("aps_") ||
           lower.contains("key=") ||
           s.count > 64 && s.allSatisfy { $0.isHexDigit }  // 像 SHA
}
```

CLAUDE.md 明确禁止输出的:

- team ID
- 证书 SHA
- 私钥路径

这三项**永远**替换为 `***`, 不走 `looksSensitive`, 直接硬编码过滤:

```swift
private let alwaysRedact: [String] = ["Q7L455FS97", "/Library/Keychains/", ".p12"]
```

## 从系统 Error 转换

VZ 抛出的 `NSError` 要兜底转换:

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

errno 统一转:

```swift
extension StorageError {
    public init(errno: Int32) {
        self = .ioError(errno: errno)
    }
    public var userMessage: String {
        switch self {
        case .ioError(let e):
            return "磁盘 I/O 失败: \(String(cString: strerror(e)))"
        // ...
        }
    }
}
```

## 错误码列表(权威)

维护在 `HVMCore/ErrorCodes.swift` 作为 enum, 编译期全列:

```swift
public enum HVMErrorCode: String {
    case bundleNotFound           = "bundle.not_found"
    case bundleBusy               = "bundle.busy"
    case bundleInvalidSchema      = "bundle.invalid_schema"
    // ...
}
```

这样新增错误必须同时:
1. 加 enum case
2. 在 `userFacing.code` switch 里补
3. 本文档表格里补一行

编译器保证 switch 穷尽, 不会漏。

## 不做什么

1. **不做 error wrapping 链**(Swift 6 还没正式特性). Error.underlyingError 字段不引入, 要链式信息, details 里放
2. **不做 i18n 多语言错误**: MVP 中文一版
3. **不做 error 上报 / 遥测**: 不联网
4. **不做 try? 吞错**: 所有非 UI 可恢复错误必须 propagate 到顶层
5. **不用 `fatalError` 处理可恢复错误**: 只用在"绝不可能发生"的不变量破坏上

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| L1 | 是否引入 structured logging (os_log 的 key-value) | 用 Logger + metadata, MVP 足够 | 已决 |
| L2 | GUI ErrorDialog 是否按 code 加截图预览 | 不做, details 文本够 | 已决 |
| L3 | 错误文档页 (website) | 不做, 本文件表格即是权威 | 已决 |

## 相关文档

- [GUI.md](GUI.md) — ErrorDialog 统一弹窗
- [CLI.md](CLI.md) — 退出码与 json 错误格式
- [DEBUG_PROBE.md](DEBUG_PROBE.md) — hvm-dbg 错误风格
- [VM_BUNDLE.md](VM_BUNDLE.md) / [STORAGE.md](STORAGE.md) / [VZ_BACKEND.md](VZ_BACKEND.md) / [NETWORK.md](NETWORK.md) / [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 各子系统错误定义

---

**最后更新**: 2026-04-25
