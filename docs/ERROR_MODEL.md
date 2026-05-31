# 错误模型 / 退出码 / IPC 协议

> 现状文档 (QEMU-only 单后端)。描述当前代码实际行为, 非设计提案。
> 源文件:
> - `app/Sources/HVMCore/HVMError.swift` — 错误枚举 + UserFacing 映射
> - `app/Sources/HVMCore/ErrorCodes.swift` — 稳定字符串错误码清单
> - `app/Sources/HVMIPC/Protocol.swift` / `Frame.swift` / `SocketClient.swift` / `SocketServer.swift` — IPC 协议
> - `app/Sources/HVMCore/SignalGuard.swift` — 信号处理
> - `app/Sources/HVMCore/Logger.swift` / `LogSink.swift` / `LoggingPreferences.swift` / `Paths.swift` — 日志
> - `app/Sources/HVMUtils/CliExit.swift` + `hvm-cli`/`hvm-dbg` 各自 `Support/OutputFormat.swift` — 退出码映射

---

## 1. HVMError 错误模型

### 1.1 根类型与分类

错误根类型是 `HVMError`, 一个 `Sendable` enum, 按子系统分派成 8 类 (`HVMError.swift`):

```swift
public enum HVMError: Error, Sendable {
    case bundle(BundleError)        // VM bundle (.hvmz) 打开 / 锁 / schema
    case storage(StorageError)      // 磁盘文件 / ISO / clonefile
    case backend(BackendError)      // VM 配置校验 / 启动 / 状态机
    case install(InstallError)      // 装机 (IPSW / ISO / Rosetta)
    case net(NetError)              // 网络 (桥接 / MAC)
    case ipc(IPCError)              // 进程间通信 (Unix socket)
    case config(ConfigError)        // 手编 config.yaml 语义错
    case encryption(EncryptionError)// 整 VM 加密 (sparsebundle / LUKS / hdiutil / qemu-img)
}
```

每个子系统是独立 enum, case 各自携带强类型 payload (路径 / errno / pid 等)。

> 注: `backend.vzInternal` (code `backend.vz_internal`, message "VZ 内部错误") 是 VZ 历史残留命名, VZ 后端已移除, 但该 case 仍作为"非 HVMError 的任意 Error 兜底通道"保留在用 (见 §2.4), 没删。一批 VZ / macOS guest 专属的死 case (Rosetta / IPSW / 桥接 entitlement / sparsebundle 相关) 已随 VZ 移除整批删除, 本文已按当前代码 (`HVMError.swift` / `ErrorCodes.swift`) 更新。

### 1.2 各子系统 case

**`BundleError`** (`bundle.*`)
- `notFound(path)` / `busy(pid, holderMode)` / `invalidSchema(version, expected)` / `parseFailed(reason, path)`
- `primaryDiskMissing(path)` / `corruptAuxiliary(reason)` / `writeFailed(reason, path)`
- `outsideSandbox(requestedPath)` — 磁盘路径逃出 bundle 目录 (路径安全防线)
- `alreadyExists(path)` / `lockFailed(reason)`

**`StorageError`** (`storage.*`)
- `diskAlreadyExists(path)` / `creationFailed(errno, path)` / `ioError(errno, path)`
- `shrinkNotSupported(currentBytes, requestedBytes)` — 不支持缩容
- `isoMissing(path)` / `isoSizeSuspicious(bytes)`
- `cloneFailed(errno)` / `crossVolumeNotAllowed(source, target)` — APFS clonefile(2) 跨卷 EXDEV 提前拦
- `volumeSpaceInsufficient(requiredBytes, availableBytes)`
- `importInvalid(reason, path)` — 导入镜像防呆 (格式 / 解析 / 越界缩容 / 不可读)

**`BackendError`** (`backend.*`)
- `configInvalid(field, reason)` / `cpuOutOfRange(requested, min, max)` / `memoryOutOfRange(requestedMiB, minMiB, maxMiB)`
- `diskNotFound(path)` / `diskBusy(path)` / `unsupportedGuestOS(raw)`
- `invalidTransition(from, to)` — VM 状态机不允许当前操作
- `vzInternal(description)` — 兜底任意非 HVMError 错误 (见 §2.4)
- `qemuHostStartupTimeout(waitedSeconds, logPath)` — GUI 拉起 `--host-mode-bundle` 子进程后时限内未观测到其持有 BundleLock

**`InstallError`** (`install.*`)
- `ipswDownloadFailed(reason)` — 复用为通用镜像下载失败 (原 IPSW 专用语义, VZ 移除后泛化)
- `diskSpaceInsufficient(requiredBytes, availableBytes)` / `isoNotFound(path)`

**`NetError`** (`net.*`)
- `bridgedInterfaceNotFound(requested, available)`
- `macInvalid(String)` / `macNotLocallyAdministered(String)` — MAC 必须 locally-administered (首字节低位)

**`IPCError`** (`ipc.*`)
- `socketNotFound(path)` / `connectionRefused(path)` / `protocolMismatch(expected, got)`
- `readFailed(reason)` / `writeFailed(reason)` / `decodeFailed(reason)`
- `remoteError(code, message)` — server 端返回的业务错回灌成 client 侧 error
- `timedOut` / `serverBindFailed(path, errno)`

**`EncryptionError`** (`encryption.*`) — 整 VM 加密
- `hdiutilFailed(verb, exitCode, stderr)` / `qemuImgFailed(verb, exitCode, stderr)` — 子命令非 0 退出 (stderr 截断 400 字符入 details)
- `wrongPassword` / `mountpointInUse(path)` / `parseFailed(reason)`
- `invalidKeyLength(got, expected)` — master KEK 固定 32 字节
- `randomGenerationFailed(status)` / `kdfFailed(reason)` — PBKDF2 派生失败
- `luksRekeyHalfDone(reason)` — LUKS 改密 step1 (加新 keyslot) 成功但 step2 (删旧) 失败, 数据不丢但需重跑 rekey

**`ConfigError`** (`config.*`) — 手编 config.yaml 语义错
- `missingField(name)` / `invalidEnum(field, raw, allowed)` / `invalidRange(field, value, range)` / `duplicateRole(role)`

### 1.3 UserFacing 映射

`HVMError.userFacing` 把内部错误翻译成面向用户的 `UserFacingError` 结构, GUI ErrorDialog / CLI JSON 输出 / hvm-dbg 共用同一份:

```swift
public struct UserFacingError: Sendable, Equatable, Codable {
    public let code: String              // 稳定错误码, 如 "bundle.not_found"
    public let message: String           // 中文短句, 如 "Bundle 未找到"
    public let details: [String: String] // 结构化上下文, 如 ["path": "..."]
    public let hint: String?             // 可选修复建议
}
```

映射逐 case 写在各子 enum 的 `var userFacing` 扩展里。设计要点:

- **`code`** 优先取 `HVMErrorCode` 枚举的 `rawValue` (见 §2.1)。少数较晚加入的 case 直接写字符串字面量 (`bundle.already_exists` / `bundle.lock_failed` / `storage.volume_space_insufficient` / `backend.invalid_transition` / `ipc.server_bind_failed`), 这些**未登记进 `HVMErrorCode` 枚举**, 但 `code` 字符串仍是稳定的, 退出码映射按前缀匹配 (`backend.` / `ipc.` 等) 兜底命中。
- **`message`** 一律中文短句, 不含可变上下文 (上下文进 `details`)。
- **`details`** 携带可定位字段 (path / pid / errno / requested-min-max 等)。**未脱敏** — `userFacing` 注释明确"调用方入日志时应自行 sanitize"。
- **`hint`** 仅在有明确可执行修复时给。例:
  - `crossVolumeNotAllowed` → `APFS clonefile 不能跨卷; 把目标位置选在与源同卷的目录`
  - `macNotLocallyAdministered` → `首字节低两位第二位必须为 1, 例: 02:xx:xx:xx:xx:xx`
  - `luksRekeyHalfDone` → `重跑 rekey 即可销毁老 keyslot; 数据未损失`

---

## 2. 退出码 (exit code)

### 2.1 错误码权威清单

`HVMErrorCode` (`ErrorCodes.swift`) 是 dotted 风格 `"<domain>.<name>"` 字符串枚举, 是 GUI / CLI / IPC 共享的稳定标识。新增错误"必须在此登记"(文件头注释)。覆盖 8 个 domain: `bundle.*` / `storage.*` / `backend.*` / `install.*` / `net.*` / `ipc.*` / `config.*` / `encryption.*`。

> 注意: §1.3 提到的若干字面量 code 是例外, 没进这个 enum。

### 2.2 CLI / dbg 退出码映射

退出码由 `code` 字符串前缀匹配决定。两个 CLI 各有一份 `exitCode(for:)` (`Support/OutputFormat.swift`), 公共 `bail` / `bailJSON` 在 `HVMUtils/CliExit.swift`, 通过 `exitCodeMap` 闭包注入各自策略。

**hvm-cli** (`app/Sources/hvm-cli/Support/OutputFormat.swift`):

| 条件 (code 前缀) | exit code |
|---|---|
| `bundle.not_found` | 3 |
| `bundle.busy` 或 `backend.disk_busy` | 4 |
| `backend.invalid_transition` | 5 |
| `ipc.timed_out` | 6 |
| `backend.*` (其余) | 10 |
| `config.*` | 2 |
| 其他 (默认) | 1 |

**hvm-dbg** (`app/Sources/hvm-dbg/Support/OutputFormat.swift`) — 与 hvm-cli 对齐, 另加 `dbg.*` 系 20-23:

| 条件 (code 前缀) | exit code |
|---|---|
| `dbg.vm_not_running` | 20 |
| `ipc.socket_not_found` 或 `ipc.connection_refused` | 21 |
| `dbg.console_agent_offline` | 22 |
| `dbg.no_match` | 23 |
| `bundle.not_found` | 3 |
| `bundle.busy` | 4 |
| `ipc.timed_out` | 6 |
| `backend.*` | 10 |
| `config.*` | 2 |
| 其他 (默认) | 1 |

> `dbg.vm_not_running` / `dbg.console_agent_offline` / `dbg.no_match` 是 hvm-dbg / host 侧直接拼的 code 字面量 (例 `QemuHostEntry.swift` 返 `dbg.vm_not_running`, `FindTextCommand` 直接 `throw ExitCode(23)`), **未进 `HVMErrorCode` 枚举**, 仅由退出码表识别。两表对 `ipc.socket_not_found` 处理不同: hvm-cli 走默认 1, hvm-dbg 单列 21。

### 2.3 退出渲染

`bail(_:exitCodeMap:)` (human 模式) 把 `UserFacingError` 渲染到 stderr:

```
错误: <message>
  code: <code>
  <detailKey>: <detailValue>     (逐条)
  建议: <hint>                    (若有)
```

`bailJSON` (json 模式) 把 `{ "error": { code, message, details, hint } }` pretty-print 到 stdout。两者最后都 `exit(exitCodeMap(uf.code))`。

### 2.4 非 HVMError 兜底

`CliExit.userFacing(of:)`: 若抛出的 `Error` 不是 `HVMError`, 包成 `.backend(.vzInternal(description: "\(error)"))` 再取 userFacing。结果 code = `backend.vz_internal` → 命中 `backend.*` → exit 10。这是任意未分类 error 的统一落点。

SwiftArgumentParser 自身的参数错 (`hvm-cli`/`hvm-dbg` 的 `exit(withError:)`, 见各 `HvmCli.swift` / `HvmDbg.swift`) 走 ArgumentParser 标准退出码 (通常 64), 不经过上述映射。

---

## 3. IPC 协议

HVM 主进程 (host-mode, 跑 VM) 暴露 Unix domain socket, `hvm-cli` / `hvm-dbg` / GUI 作为 client 连入。协议是 length-prefixed JSON, 定义在 `HVMIPC/Protocol.swift`。

### 3.1 传输层 (Frame)

`Frame` (`Frame.swift`) — 4 字节大端 length prefix + JSON payload:

```
[4B big-endian u32 length][JSON payload]
```

- 单帧上限 `maxPayloadBytes = 8 MiB` (覆盖 screenshot base64 上限, 同时防异常请求撑爆 parser)。
- `read(fd:)` 返回 `nil` 表示对端正常关闭 (起始处 EOF); length 为 0 或 > 上限抛 `ipc.readFailed`; payload 截断抛 `ipc.readFailed`。
- `readExact` / `writeAll` 处理部分读写 + `EINTR` 重试。
- 不是多路复用: 一个连接上**串行**单请求 / 单响应 (但同一连接可循环多轮请求, `SocketServer.handleConnection` 是 while 循环)。

### 3.2 请求 / 响应结构

```swift
public struct IPCRequest: Codable, Sendable {
    public var id: String              // 默认 UUID, 用于请求-响应配对
    public var op: String              // 操作名 (见 IPCOp)
    public var args: [String: String]  // 字符串键值参数
    public var protoVersion: Int?      // 客户端协议版本, 默认填 IPCProtocol.version
}

public struct IPCResponse: Codable, Sendable {
    public var id: String              // echo 回请求 id
    public var ok: Bool
    public var data: [String: String]? // 成功时业务数据 (复杂 payload JSON-stringify 进 "payload" 键)
    public var error: IPCErrorPayload? // 失败时 { code, message, details }
}
```

工厂方法: `IPCResponse.success(id:data:)` / `.failure(id:code:message:details:)` / `.encoded(id:payload:kind:dateStrategy:)` (后者把任意 `Encodable` 编码进 `data["payload"]`, 编码失败返 `ipc.encode_failed`, 替代 14 处重复样板)。

复杂响应作为独立 `Codable` payload struct 通过 `data["payload"]` 传 (如 `IPCStatusPayload` / `IPCDbgScreenshotPayload` / `IPCClipboardPasteFilesPayload` 等)。

### 3.3 操作枚举 (IPCOp)

`IPCOp: String` 当前 case (字符串 rawValue):

**生命周期控制** (hvm-cli):
- `status` / `stop` / `kill` / `pause` / `resume`

**hvm-dbg 调试子集** (`dbg.*`):
- `dbg.screenshot` / `dbg.status` / `dbg.key` / `dbg.mouse` / `dbg.ocr` / `dbg.find_text`
- `dbg.boot_progress` / `dbg.console.read` / `dbg.console.write`
- `dbg.display.info` (QMP screendump 拿真实 framebuffer 尺寸) / `dbg.display.resize` (模拟 host→guest resize, 双通路 HDP + vdagent)
- `dbg.exec.guest` (qemu-guest-agent 跑 guest 内 process 拿 stdout/stderr/exit_code)
- `dbg.file.push` / `dbg.file.pull` (qga `guest-file-*`, 1 MiB chunk base64) / `dbg.dir.list` (列 guest 目录)

**GUI ↔ host 控制**:
- `display.setMonitors` (改 guest 分辨率, 走 host 持有的 vdagent socket)
- `clipboard.setEnabled` (热切剪贴板共享, 不重启 VM)
- `clipboard.paste-files` (Cmd+V host 文件经 vdagent file_xfer 流给 guest `~/Downloads`, 长事务 ≥600s)
- `clipboard.install-helper` (QGA 推 EXE + schtasks 注册 guest helper, 仅 Windows)

**未知 op**: 由 host handler default 分支兜底返 `ipc.unknown_op` (`QemuHostEntry.swift`)。dbg.* 在 QEMU 后端不支持的也走这个 code。

### 3.4 协议版本协商

`IPCProtocol.version` 当前 = **1**。约定 (`Protocol.swift` 头注释 + `SocketServer.handleConnection`):

- 改 `IPCRequest` / `IPCResponse` / 已知 op 语义 → version +1; 纯加新 op (向上扩展) **不** +1。
- client (`SocketClient`) 默认在 `IPCRequest` 填 `protoVersion = IPCProtocol.version`。
- server 在 dispatch 前校验:
  - `protoVersion == nil` (老 client 没这字段) → 视作 legacy, **接受** (向后兼容)。
  - `!= current` → 不调 handler, 直接返 `ipc.protocol_mismatch` (message 含双方版本)。
  - `== current` → 正常 dispatch。
- `JSONDecoder` 默认忽略未知字段, 所以 "新 client → 老 server" 不会因 `protoVersion` 字段失败; "老 client → 新 server" 走 nil legacy 分支也接受。**真正拦下只发生在双方都有该字段且 != current**。
- 动机: 用户可能从老 `.app` 启动 host, 又用新装的 hvm-cli 调用 (版本错位让语义模糊)。

### 3.5 socket 安全与并发

- **仅 Unix domain socket, 严禁 TCP** (CLAUDE.md QEMU 进程模型约束)。
- 默认路径 `HVMPaths.socketPath(for: id)` = `run/<uuid>.sock`; GUI 探针另走 `run/hvm-dbg-gui.sock`。
- server bind 后 `chmod 0600` (仅 owner 可访问), 预清理上次崩溃残留 socket (`unlink`)。
- 连接并发上限 `maxConcurrentConnections = 32`; 超过新连接立即 close + warn。handler 跑在 concurrent dispatch queue (非 1:1 thread-per-conn)。
- client (`SocketClient.request`) 每次新建连接, 同步收发, 默认 `timeoutSec = 10` (走 `SO_RCVTIMEO`/`SNDTIMEO`)。connect `ENOENT` 映射 `socketNotFound` (优先于 `connectionRefused`, 给更准提示)。
- 解析失败回 `ipc.decode_failed`; 编码 payload 失败回 `ipc.encode_failed`。

---

## 4. 信号处理 (SignalGuard)

`SignalGuard` (`SignalGuard.swift`) 服务两个独立目的。

### 4.1 进程级永久忽略 SIGPIPE

`SignalGuard.ignoreSIGPIPE()` — **所有 entry (HVM main / hvm-cli / hvm-dbg) 启动顶部必须调**。

- IPC server 给已退出的 client 写响应时, `write(2)` 触发 `SIGPIPE`; 默认 disposition = terminate 整个 host 进程。
- host 被 SIGPIPE 杀掉 → QEMU + swtpm 子进程 reparent 到 launchd 成 orphan, 占着 `tpm/.lock` NVRAM 锁 + qmp socket, 新 host 起不来 (实测: `hvm-dbg exec-guest` 长任务时用户 Ctrl-C → host 猝死 → GUI 报 startup timeout)。
- 装 `SIG_IGN` 后 `write` 返 -1 + `EPIPE`, `Frame.writeAll` 抛 `ipc.writeFailed`, `SocketServer.handleConnection` 的 catch 干净 close 连接, host 继续跑。
- 进程级永久装, 不走下面的 reentrant 计数。

### 4.2 加密长事务防中断 (SIGINT / SIGTERM)

`install(message:)` / `uninstall()` 给加密事务 (encrypt / decrypt / rekey) 装 SIGINT + SIGTERM handler, 实现"两次 Ctrl-C 才退":

- **第一次** Ctrl-C → 走 `write(2)` 打警告到 stderr (`⚠ 加密操作进行中, 请等待结束 ...`), **不打断**当前事务, 让 LUKS keyslot / qemu-img convert 跑完, 不留 partial。
- **5s 窗口内二次** Ctrl-C → 跑 atexit cleanup 后 `_exit(130)`, 用户自负残留风险。
- 窗口 `secondPressWindowSec = 5.0`, 用 `clock_gettime(CLOCK_MONOTONIC)` 测间隔 (`Date` 非 async-signal-safe)。

**实施约束**:
- handler 是 `@convention(c)`, 只调 async-signal-safe 函数 (`write` / atomic / `_exit`), 不调 `print` / Swift API。
- 可变状态 (`lastSignalSec` / `installCount` / cleanup 队列) 用 `nonisolated(unsafe)` 静态 + `NSLock` 给主路径同步。
- `install` / `uninstall` 走 **reentrant 计数** (嵌套安全, 计数减到 0 才真还原老 handler)。
- `registerCleanup(_:)` 注册兜底清理 (atexit 正常退出 + 二次硬退都跑, LIFO 顺序, 推荐 `try? FileManager.removeItem(tmpDir)`); `clearCleanup()` 事务正常完成后调, 防 atexit 重复跑。
- **限制**: `SIGKILL` / `abort` 拦不住 (接受, 文档说明用户自负); 不支持嵌套不同事务。

---

## 5. 日志

### 5.1 两类落盘 (硬约束)

CLAUDE.md「日志路径约束」: 落盘日志严格分两类。

**(A) HVM 软件本身的 host 侧 `.log`** → 全部落 `~/Library/Application Support/HVM/logs/`:
- 顶层 `<yyyy-MM-dd>.log` — `LogSink` mirror `os.Logger` 输出 (跨 VM 共享)。
- 子目录 `<displayName>-<uuid8>/` (`HVMPaths.vmLogsDir(displayName:id:)`) — 该 VM 的 host 侧 .log:
  - `host-<date>.log` — VMHost (HVM `--host-mode-bundle`) 进程 stdout/stderr
  - `qemu-stderr.log` — QEMU host 进程 stderr
  - `swtpm.log` / `swtpm-stderr.log` — swtpm 自身 / 进程 stderr
- 路径必须走 `HVMPaths.logsDir` / `vmLogsDir(displayName:id:)`, **禁止**业务侧自己拼 `bundle/logs/...`。
- dev / debug 临时日志同样走 `HVMPaths.logsDir`, 不散落 `/tmp` / 仓库根。

**(B) 虚拟机自己的 `.log` (guest 内部产生)** → 留在 `<bundle>.hvmz/logs/`:
- `console-<date>.log` — guest serial 输出 (内核启动 / systemd / dmesg), 由 `QemuConsoleBridge` 写 (**唯一允许写 bundle/logs/ 的来源**)。
- 不受全局日志开关影响 (那是 guest 自己的输出)。

VM 删除时**不**自动清理 host 侧 `<displayName>-<uuid8>/` 子目录 (留作排查), orphan 由用户手动清。displayName 改名时旧目录留 orphan。

### 5.2 Logger 门面

`HVMLog` (`Logger.swift`) — 薄封装 `os.Logger`, 统一挂 subsystem `com.hellmessage.vm`, 各模块以 category 区分 (`HVMLog.logger("ipc.server")` 等)。第一次调用 lazy 启动 `LogSink.shared`。

### 5.3 LogSink — 文件 mirror

`LogSink` (`LogSink.swift`) — 把 `os.Logger` 输出异步 mirror 到顶层 `<yyyy-MM-dd>.log`:
- 实现: 周期性 `OSLogStore.getEntries` 拉本进程 (`.currentProcessIdentifier`) 的 OSLogEntry, 按 `subsystem == com.hellmessage.vm` 过滤, 写当日文件。不改 `HVMLog.logger` API。
- **actor 隔离** (非 MainActor): `getEntries` 是 50-200ms 阻塞 syscall, 早期 `@MainActor` 实现每 poll 周期撞主线程让 framebuffer 周期卡顿; 改 actor 后跑 cooperative pool, 主线程零阻塞。
- poll 间隔 5s (latency ≤ 5s); 退出前 atexit flush 一次。
- 按天 rotate, 保留 `retentionDays = 14` (`gcOldLogs` 按文件名 `yyyy-MM-dd.log` parse 删旧)。文件权限: 目录 0755, 文件 0644。
- 短命 CLI (hvm-cli/hvm-dbg) 跑完即退, poll 没机会启动 → 自己 stdout 已够看, 只长命 GUI / VMHost 持续落盘 (设计如此)。
- 单行格式: `<ts> [<level>] [<category>] <message>` (level: DBG/INF/NOTE/ERR/FAULT)。

### 5.4 全局日志开关 (LoggingPreferences)

`LoggingPreferences` (`LoggingPreferences.swift`) — 跨进程日志总开关:
- 持久化到 `UserDefaults(suiteName: "com.hellmessage.vm")` 的 key `com.hellmessage.vm.logging.enabled` (默认 true)。**显式 suiteName** 而非 `.standard` — hvm-cli 无 bundle, `.standard` 会落到执行档名域看不到 GUI 写的开关。
- 读 `readEnabledFromDefaults()` 是 nonisolated 静态方法 (任何线程 / 进程可调); 写 `setEnabled(_:)` 是 `@MainActor` (GUI 状态栏 toggle), 同步刷 LogSink + UserDefaults。
- **关闭时覆盖范围**:
  - LogSink 不再写顶层 `<date>.log` (关 fileHandle; poll 仅推 `lastPosition` 不写, 防开启后回放堆积历史)。
  - GUI / hvm-cli 派生的 VMHost 子进程不再创建 `host-<date>.log` (stdout/stderr → `/dev/null`, vmLogsDir 子目录也不创建)。
  - VMHost 子进程不再创建 `qemu-stderr.log` / `swtpm.log` / `swtpm-stderr.log`。
  - `os.Logger` 调用仍走系统 unified logging (Console.app / `log show` 仍可见), 只是不落自家 `.log`。
  - guest serial `console-*.log` **不受影响** (guest 自身输出)。
- **切换时机**: LogSink 即时生效; 子进程 host log / qemu / swtpm 在 VM 启动时拍板, 运行中切换不影响已开 fd, 下次启 VM 才生效。

### 5.5 脱敏约束

- `UserFacingError.details` 未脱敏, 调用方入日志时应自行 sanitize (`HVMError.userFacing` 注释)。
- CLAUDE.md 签名约束: 签名相关代码 / 日志**不得输出** team ID / 证书 SHA / 私钥路径。
- `EncryptionError` 的 hdiutil / qemu-img stderr 入 details 前截断 400 字符。

---

## 附: 各层错误流转

```
内部错误 (HVMError 子 enum case)
   │  .userFacing
   ▼
UserFacingError { code, message, details, hint }
   ├──► GUI ErrorDialog (message + hint)
   ├──► IPC: IPCResponse.failure(code, message, details)  ──Frame──► client
   │         (client 收到后包成 IPCError.remoteError(code, message))
   └──► CLI: bail (human → stderr) / bailJSON (json → stdout)
              └──► exit(exitCodeMap(code))   (hvm-cli 表 / hvm-dbg 表)
```
