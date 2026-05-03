// HVMCore/HVMError.swift
// 错误根类型 + 各子错误具体 case + UserFacing 映射
// 完整设计见 docs/ERROR_MODEL.md

import Foundation

/// 全项目错误根类型, 按子系统分派
public enum HVMError: Error, Sendable {
    case bundle(BundleError)
    case storage(StorageError)
    case backend(BackendError)
    case install(InstallError)
    case net(NetError)
    case ipc(IPCError)
    case config(ConfigError)
    case encryption(EncryptionError)
}

// MARK: - Bundle

public enum BundleError: Error, Sendable {
    case notFound(path: String)
    case busy(pid: Int32, holderMode: String)
    case invalidSchema(version: Int, expected: Int)
    case parseFailed(reason: String, path: String)
    case primaryDiskMissing(path: String)
    case corruptAuxiliary(reason: String)
    case writeFailed(reason: String, path: String)
    case outsideSandbox(requestedPath: String)
    case alreadyExists(path: String)
    case lockFailed(reason: String)
}

// MARK: - Storage

public enum StorageError: Error, Sendable {
    case diskAlreadyExists(path: String)
    case creationFailed(errno: Int32, path: String)
    case ioError(errno: Int32, path: String)
    case shrinkNotSupported(currentBytes: Int64, requestedBytes: Int64)
    case isoMissing(path: String)
    case isoSizeSuspicious(bytes: Int64)
    case cloneFailed(errno: Int32)
    case volumeSpaceInsufficient(requiredBytes: UInt64, availableBytes: UInt64)
    /// 导入磁盘镜像时的所有防呆错误 (格式不支持 / qemu-img 解析失败 / 越界缩容 / 文件不可读)
    case importInvalid(reason: String, path: String)
    /// CloneManager: 源 bundle 与目标父目录分别在不同 APFS 卷, clonefile(2) 跨卷会被
    /// 内核拒 (EXDEV); 提前 statfs 探测到差异时直接抛, 而非让底层报模糊错
    case crossVolumeNotAllowed(source: String, target: String)
}

// MARK: - Backend

public enum BackendError: Error, Sendable {
    case configInvalid(field: String, reason: String)
    case cpuOutOfRange(requested: Int, min: Int, max: Int)
    case memoryOutOfRange(requestedMiB: UInt64, minMiB: UInt64, maxMiB: UInt64)
    case diskNotFound(path: String)
    case diskBusy(path: String)
    case unsupportedGuestOS(raw: String)
    case rosettaUnavailable
    case bridgedNotEntitled
    case ipswInvalid(reason: String)
    case invalidTransition(from: String, to: String)
    case vzInternal(description: String)
    /// GUI 已拉起 `--host-mode-bundle` 子进程, 在时限内未观测到其持有 BundleLock (通常表示子进程已退出或极慢)
    case qemuHostStartupTimeout(waitedSeconds: Int, logPath: String)
}

// MARK: - Install

public enum InstallError: Error, Sendable {
    case ipswNotFound(path: String)
    case ipswUnsupported(reason: String)
    case ipswDownloadFailed(reason: String)
    case auxiliaryCreationFailed(reason: String)
    case diskSpaceInsufficient(requiredBytes: UInt64, availableBytes: UInt64)
    case installerFailed(reason: String)
    case rosettaNotInstalled
    case isoNotFound(path: String)
}

// MARK: - Net

public enum NetError: Error, Sendable {
    case bridgedNotEntitled
    case bridgedInterfaceNotFound(requested: String, available: [String])
    case macInvalid(String)
    case macNotLocallyAdministered(String)
}

// MARK: - IPC

public enum IPCError: Error, Sendable {
    case socketNotFound(path: String)
    case connectionRefused(path: String)
    case protocolMismatch(expected: Int, got: Int)
    case readFailed(reason: String)
    case writeFailed(reason: String)
    case decodeFailed(reason: String)
    case remoteError(code: String, message: String)
    case timedOut
    case serverBindFailed(path: String, errno: Int32)
}

// MARK: - Encryption (整 VM 加密, sparsebundle + Keychain, docs/v3/ENCRYPTION.md)

public enum EncryptionError: Error, Sendable {
    /// hdiutil 子命令以非 0 退出. verb 指 create/attach/detach/chpass/info 等
    case hdiutilFailed(verb: String, exitCode: Int32, stderr: String)
    /// sparsebundle 已存在, create 拒绝覆盖
    case sparsebundleAlreadyExists(path: String)
    /// 密码错 (attach / chpass 时 hdiutil 报 "Authentication error" 等)
    case wrongPassword
    /// 挂载点已有挂载或不可用
    case mountpointInUse(path: String)
    /// hdiutil 输出 plist 解析失败 (理论上 hdiutil 有变动才会触发)
    case parseFailed(reason: String)
    /// master KEK 长度不对 (固定 32 字节 = 256 bit)
    case invalidKeyLength(got: Int, expected: Int)
    /// SecRandomCopyBytes 等系统 crypto 调用失败 (用户级几乎不会触发)
    case randomGenerationFailed(status: Int32)
    /// PBKDF2 派生失败 (CommonCrypto / CryptoKit 报错)
    case kdfFailed(reason: String)
}

// MARK: - Config (手动编辑 config.json 产生的语义错)

public enum ConfigError: Error, Sendable {
    case missingField(name: String)
    case invalidEnum(field: String, raw: String, allowed: [String])
    case invalidRange(field: String, value: String, range: String)
    case duplicateRole(role: String)
}

// MARK: - UserFacing 映射

/// 面向用户的错误呈现, GUI ErrorDialog / CLI json / hvm-dbg 共用
public struct UserFacingError: Sendable, Equatable, Codable {
    public let code: String
    public let message: String
    public let details: [String: String]
    public let hint: String?

    public init(code: String, message: String, details: [String: String] = [:], hint: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.hint = hint
    }
}

public extension HVMError {
    /// 翻译为面向用户的错误; details 里的值未做脱敏, 调用方入日志时应用 sanitize
    var userFacing: UserFacingError {
        switch self {
        case .bundle(let e):     return e.userFacing
        case .storage(let e):    return e.userFacing
        case .backend(let e):    return e.userFacing
        case .install(let e):    return e.userFacing
        case .net(let e):        return e.userFacing
        case .ipc(let e):        return e.userFacing
        case .config(let e):     return e.userFacing
        case .encryption(let e): return e.userFacing
        }
    }
}

public extension BundleError {
    var userFacing: UserFacingError {
        switch self {
        case .notFound(let p):
            return .init(code: HVMErrorCode.bundleNotFound.rawValue,
                         message: "Bundle 未找到",
                         details: ["path": p],
                         hint: "确认路径是否正确, 或用 hvm-cli list 查看可用 bundle")
        case .busy(let pid, let mode):
            return .init(code: HVMErrorCode.bundleBusy.rawValue,
                         message: "Bundle 被另一个进程占用",
                         details: ["pid": "\(pid)", "mode": mode],
                         hint: "请先关闭占用该 bundle 的进程")
        case .invalidSchema(let got, let expected):
            return .init(code: HVMErrorCode.bundleInvalidSchema.rawValue,
                         message: "Bundle schema 版本不兼容",
                         details: ["got": "\(got)", "expected": "\(expected)"],
                         hint: "请升级 HVM 或换用匹配的 bundle")
        case .parseFailed(let reason, let path):
            return .init(code: HVMErrorCode.bundleParseFailed.rawValue,
                         message: "Bundle 配置解析失败",
                         details: ["path": path, "reason": reason])
        case .primaryDiskMissing(let path):
            return .init(code: HVMErrorCode.bundlePrimaryDiskMissing.rawValue,
                         message: "Bundle 主盘文件缺失",
                         details: ["path": path])
        case .corruptAuxiliary(let reason):
            return .init(code: HVMErrorCode.bundleCorruptAuxiliary.rawValue,
                         message: "Bundle auxiliary 数据损坏, VM 已无法恢复",
                         details: ["reason": reason])
        case .writeFailed(let reason, let path):
            return .init(code: HVMErrorCode.bundleWriteFailed.rawValue,
                         message: "写入 bundle 文件失败",
                         details: ["path": path, "reason": reason])
        case .outsideSandbox(let requested):
            return .init(code: HVMErrorCode.bundleOutsideSandbox.rawValue,
                         message: "磁盘路径逃出 bundle 目录",
                         details: ["requested": requested])
        case .alreadyExists(let path):
            return .init(code: "bundle.already_exists",
                         message: "Bundle 目录已存在",
                         details: ["path": path],
                         hint: "换个名称, 或先删除已有 bundle")
        case .lockFailed(let reason):
            return .init(code: "bundle.lock_failed",
                         message: "Bundle 加锁失败",
                         details: ["reason": reason])
        }
    }
}

public extension StorageError {
    var userFacing: UserFacingError {
        switch self {
        case .diskAlreadyExists(let p):
            return .init(code: HVMErrorCode.storageDiskExists.rawValue,
                         message: "磁盘文件已存在",
                         details: ["path": p])
        case .creationFailed(let e, let p):
            return .init(code: HVMErrorCode.storageCreationFailed.rawValue,
                         message: "创建磁盘文件失败",
                         details: ["errno": "\(e)", "path": p])
        case .ioError(let e, let p):
            return .init(code: HVMErrorCode.storageIOError.rawValue,
                         message: "磁盘 I/O 失败",
                         details: ["errno": "\(e)", "path": p])
        case .shrinkNotSupported(let cur, let req):
            return .init(code: HVMErrorCode.storageShrinkUnsupported.rawValue,
                         message: "不支持缩容磁盘",
                         details: ["current": "\(cur)", "requested": "\(req)"],
                         hint: "如需回收空间, 建议在 guest 内清零后 rebuild bundle")
        case .isoMissing(let p):
            return .init(code: HVMErrorCode.storageISOMissing.rawValue,
                         message: "ISO 文件不在原位置",
                         details: ["path": p],
                         hint: "重新在配置里选择 ISO 文件位置")
        case .isoSizeSuspicious(let b):
            return .init(code: HVMErrorCode.storageISOSizeSuspicious.rawValue,
                         message: "ISO 文件大小异常",
                         details: ["bytes": "\(b)"])
        case .cloneFailed(let e):
            return .init(code: HVMErrorCode.storageCloneFailed.rawValue,
                         message: "APFS clonefile 失败",
                         details: ["errno": "\(e)"])
        case .volumeSpaceInsufficient(let req, let avail):
            return .init(code: "storage.volume_space_insufficient",
                         message: "磁盘卷空间不足",
                         details: ["required": "\(req)", "available": "\(avail)"])
        case .importInvalid(let reason, let p):
            return .init(code: HVMErrorCode.storageImportInvalid.rawValue,
                         message: "导入磁盘镜像不可用",
                         details: ["reason": reason, "path": p],
                         hint: "仅支持 qcow2 / raw 镜像; 校验镜像可读、大小在合理范围")
        case .crossVolumeNotAllowed(let src, let tgt):
            return .init(code: HVMErrorCode.storageCrossVolumeNotAllowed.rawValue,
                         message: "克隆要求源与目标在同一卷",
                         details: ["source": src, "target": tgt],
                         hint: "APFS clonefile 不能跨卷; 把目标位置选在与源同卷的目录")
        }
    }
}

public extension BackendError {
    var userFacing: UserFacingError {
        switch self {
        case .configInvalid(let field, let reason):
            return .init(code: HVMErrorCode.backendConfigInvalid.rawValue,
                         message: "VM 配置无效",
                         details: ["field": field, "reason": reason])
        case .cpuOutOfRange(let r, let lo, let hi):
            return .init(code: HVMErrorCode.backendCPUOutOfRange.rawValue,
                         message: "CPU 核心数超出范围",
                         details: ["requested": "\(r)", "min": "\(lo)", "max": "\(hi)"],
                         hint: "当前系统支持 \(lo)~\(hi) 核心, 请调整后重试")
        case .memoryOutOfRange(let r, let lo, let hi):
            return .init(code: HVMErrorCode.backendMemoryOutOfRange.rawValue,
                         message: "内存大小超出范围",
                         details: ["requestedMiB": "\(r)", "minMiB": "\(lo)", "maxMiB": "\(hi)"])
        case .diskNotFound(let p):
            return .init(code: HVMErrorCode.backendDiskNotFound.rawValue,
                         message: "磁盘文件未找到",
                         details: ["path": p])
        case .diskBusy(let p):
            return .init(code: HVMErrorCode.backendDiskBusy.rawValue,
                         message: "磁盘被另一个进程占用",
                         details: ["path": p])
        case .unsupportedGuestOS(let raw):
            return .init(code: HVMErrorCode.backendUnsupportedGuestOS.rawValue,
                         message: "不支持的 guest OS",
                         details: ["raw": raw])
        case .rosettaUnavailable:
            return .init(code: HVMErrorCode.backendRosettaUnavailable.rawValue,
                         message: "Rosetta 2 不可用",
                         hint: "执行: softwareupdate --install-rosetta --agree-to-license")
        case .bridgedNotEntitled:
            return .init(code: HVMErrorCode.backendBridgedNotEntitled.rawValue,
                         message: "桥接网络 entitlement 未启用",
                         hint: "详见 docs/ENTITLEMENT.md")
        case .ipswInvalid(let r):
            return .init(code: HVMErrorCode.backendIPSWInvalid.rawValue,
                         message: "IPSW 文件无效或不被支持",
                         details: ["reason": r])
        case .invalidTransition(let from, let to):
            return .init(code: "backend.invalid_transition",
                         message: "VM 状态不允许当前操作",
                         details: ["from": from, "to": to])
        case .vzInternal(let d):
            return .init(code: HVMErrorCode.backendVZInternal.rawValue,
                         message: "VZ 内部错误",
                         details: ["description": d])
        case .qemuHostStartupTimeout(let sec, let logPath):
            return .init(code: HVMErrorCode.backendQemuHostStartupTimeout.rawValue,
                         message: "QEMU 宿主进程未在规定时间内就绪",
                         details: ["waitedSeconds": "\(sec)", "log": logPath],
                         hint: "请查看 log 中 host-*.log; Bridged/Shared 时确认 socket_vmnet 与 sudoers 已正确配置, 并排除 bundle 正被其他进程占用。")
        }
    }
}

public extension InstallError {
    var userFacing: UserFacingError {
        switch self {
        case .ipswNotFound(let p):
            return .init(code: HVMErrorCode.installIPSWNotFound.rawValue,
                         message: "IPSW 文件未找到",
                         details: ["path": p])
        case .ipswUnsupported(let r):
            return .init(code: HVMErrorCode.installIPSWUnsupported.rawValue,
                         message: "IPSW 版本不受 VZ 支持",
                         details: ["reason": r])
        case .ipswDownloadFailed(let r):
            return .init(code: HVMErrorCode.installIPSWDownloadFailed.rawValue,
                         message: "IPSW 下载失败",
                         details: ["reason": r])
        case .auxiliaryCreationFailed(let r):
            return .init(code: HVMErrorCode.installAuxCreationFailed.rawValue,
                         message: "创建 auxiliary 数据失败",
                         details: ["reason": r])
        case .diskSpaceInsufficient(let req, let avail):
            return .init(code: HVMErrorCode.installDiskSpaceInsufficient.rawValue,
                         message: "磁盘空间不足以安装",
                         details: ["required": "\(req)", "available": "\(avail)"])
        case .installerFailed(let r):
            return .init(code: HVMErrorCode.installInstallerFailed.rawValue,
                         message: "装机流程失败",
                         details: ["reason": r])
        case .rosettaNotInstalled:
            return .init(code: HVMErrorCode.installRosettaNotInstalled.rawValue,
                         message: "系统未安装 Rosetta 2",
                         hint: "执行: softwareupdate --install-rosetta --agree-to-license")
        case .isoNotFound(let p):
            return .init(code: HVMErrorCode.installISONotFound.rawValue,
                         message: "ISO 文件未找到",
                         details: ["path": p])
        }
    }
}

public extension NetError {
    var userFacing: UserFacingError {
        switch self {
        case .bridgedNotEntitled:
            return .init(code: HVMErrorCode.netBridgedNotEntitled.rawValue,
                         message: "桥接网络 entitlement 未启用",
                         hint: "详见 docs/ENTITLEMENT.md")
        case .bridgedInterfaceNotFound(let req, let avail):
            return .init(code: HVMErrorCode.netBridgedInterfaceNotFound.rawValue,
                         message: "指定的桥接接口不存在",
                         details: ["requested": req, "available": avail.joined(separator: ",")])
        case .macInvalid(let m):
            return .init(code: HVMErrorCode.netMACInvalid.rawValue,
                         message: "MAC 地址格式非法",
                         details: ["mac": m])
        case .macNotLocallyAdministered(let m):
            return .init(code: HVMErrorCode.netMACNotLocallyAdministered.rawValue,
                         message: "MAC 必须是 locally-administered",
                         details: ["mac": m],
                         hint: "首字节低两位第二位必须为 1, 例: 02:xx:xx:xx:xx:xx")
        }
    }
}

public extension IPCError {
    var userFacing: UserFacingError {
        switch self {
        case .socketNotFound(let p):
            return .init(code: HVMErrorCode.ipcSocketNotFound.rawValue,
                         message: "IPC socket 不存在",
                         details: ["path": p],
                         hint: "VM 可能未运行, 或 socket 被清理")
        case .connectionRefused(let p):
            return .init(code: HVMErrorCode.ipcConnectionRefused.rawValue,
                         message: "IPC 连接被拒绝",
                         details: ["path": p])
        case .protocolMismatch(let exp, let got):
            return .init(code: HVMErrorCode.ipcProtocolMismatch.rawValue,
                         message: "IPC 协议版本不匹配",
                         details: ["expected": "\(exp)", "got": "\(got)"])
        case .readFailed(let r):
            return .init(code: HVMErrorCode.ipcReadFailed.rawValue,
                         message: "IPC 读取失败",
                         details: ["reason": r])
        case .writeFailed(let r):
            return .init(code: HVMErrorCode.ipcWriteFailed.rawValue,
                         message: "IPC 写入失败",
                         details: ["reason": r])
        case .decodeFailed(let r):
            return .init(code: HVMErrorCode.ipcDecodeFailed.rawValue,
                         message: "IPC 消息解码失败",
                         details: ["reason": r])
        case .remoteError(let code, let msg):
            return .init(code: HVMErrorCode.ipcRemoteError.rawValue,
                         message: msg,
                         details: ["remoteCode": code])
        case .timedOut:
            return .init(code: HVMErrorCode.ipcTimedOut.rawValue,
                         message: "IPC 调用超时")
        case .serverBindFailed(let p, let e):
            return .init(code: "ipc.server_bind_failed",
                         message: "无法绑定 IPC socket",
                         details: ["path": p, "errno": "\(e)"])
        }
    }
}

public extension EncryptionError {
    var userFacing: UserFacingError {
        switch self {
        case .hdiutilFailed(let verb, let code, let stderr):
            return .init(code: HVMErrorCode.encryptionHdiutilFailed.rawValue,
                         message: "磁盘镜像操作失败 (hdiutil \(verb))",
                         details: ["verb": verb, "exitCode": "\(code)", "stderr": stderr.prefix(400).trimmingCharacters(in: .whitespacesAndNewlines)])
        case .sparsebundleAlreadyExists(let p):
            return .init(code: HVMErrorCode.encryptionSparsebundleAlreadyExists.rawValue,
                         message: "加密容器已存在",
                         details: ["path": p],
                         hint: "换个名称或先删除已有 sparsebundle")
        case .wrongPassword:
            return .init(code: HVMErrorCode.encryptionWrongPassword.rawValue,
                         message: "密码错误",
                         hint: "重新输入密码; 多次失败请确认密码")
        case .mountpointInUse(let p):
            return .init(code: HVMErrorCode.encryptionMountpointInUse.rawValue,
                         message: "挂载点已被占用",
                         details: ["path": p])
        case .parseFailed(let reason):
            return .init(code: HVMErrorCode.encryptionParseFailed.rawValue,
                         message: "hdiutil 输出解析失败",
                         details: ["reason": reason])
        case .invalidKeyLength(let got, let expected):
            return .init(code: HVMErrorCode.encryptionInvalidKeyLength.rawValue,
                         message: "密钥长度不正确",
                         details: ["got": "\(got)", "expected": "\(expected)"])
        case .randomGenerationFailed(let status):
            return .init(code: HVMErrorCode.encryptionRandomGenerationFailed.rawValue,
                         message: "系统随机数生成失败",
                         details: ["status": "\(status)"])
        case .kdfFailed(let reason):
            return .init(code: HVMErrorCode.encryptionKdfFailed.rawValue,
                         message: "密钥派生 (PBKDF2) 失败",
                         details: ["reason": reason])
        }
    }
}

public extension ConfigError {
    var userFacing: UserFacingError {
        switch self {
        case .missingField(let name):
            return .init(code: HVMErrorCode.configMissingField.rawValue,
                         message: "配置缺少必填字段",
                         details: ["field": name])
        case .invalidEnum(let field, let raw, let allowed):
            return .init(code: HVMErrorCode.configInvalidEnum.rawValue,
                         message: "配置字段取值非法",
                         details: ["field": field, "got": raw, "allowed": allowed.joined(separator: ",")])
        case .invalidRange(let field, let value, let range):
            return .init(code: HVMErrorCode.configInvalidRange.rawValue,
                         message: "配置字段值超出允许范围",
                         details: ["field": field, "value": value, "range": range])
        case .duplicateRole(let role):
            return .init(code: HVMErrorCode.configDuplicateRole.rawValue,
                         message: "配置中出现重复的角色",
                         details: ["role": role])
        }
    }
}
