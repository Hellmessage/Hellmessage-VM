// HVMCore/ErrorCodes.swift
// 错误码权威清单. 新增错误必须同时在此登记 + docs/ERROR_MODEL.md 更新表格
// M0 先列框架, 具体 case 随模块实现补齐

/// 稳定字符串错误码, dotted 风格 "<domain>.<name>"
public enum HVMErrorCode: String, Sendable {
    // bundle.*
    case bundleNotFound         = "bundle.not_found"
    case bundleBusy             = "bundle.busy"
    case bundleInvalidSchema    = "bundle.invalid_schema"
    case bundleParseFailed      = "bundle.parse_failed"
    case bundlePrimaryDiskMissing = "bundle.primary_disk_missing"
    case bundleCorruptAuxiliary = "bundle.corrupt_auxiliary"
    case bundleWriteFailed      = "bundle.write_failed"
    case bundleOutsideSandbox   = "bundle.outside_sandbox"

    // storage.*
    case storageDiskExists      = "storage.disk_exists"
    case storageCreationFailed  = "storage.creation_failed"
    case storageIOError         = "storage.io_error"
    case storageShrinkUnsupported = "storage.shrink_unsupported"
    case storageISOMissing      = "storage.iso_missing"
    case storageISOSizeSuspicious = "storage.iso_size_suspicious"
    case storageCloneFailed     = "storage.clone_failed"

    // backend.*
    case backendConfigInvalid   = "backend.config_invalid"
    case backendCPUOutOfRange   = "backend.cpu_out_of_range"
    case backendMemoryOutOfRange = "backend.memory_out_of_range"
    case backendDiskNotFound    = "backend.disk_not_found"
    case backendDiskBusy        = "backend.disk_busy"
    case backendUnsupportedGuestOS = "backend.unsupported_guest_os"
    case backendRosettaUnavailable = "backend.rosetta_unavailable"
    case backendBridgedNotEntitled = "backend.bridged_not_entitled"
    case backendIPSWInvalid     = "backend.ipsw_invalid"
    case backendVZInternal      = "backend.vz_internal"

    // install.*
    case installIPSWNotFound    = "install.ipsw_not_found"
    case installIPSWUnsupported = "install.ipsw_unsupported"
    case installIPSWDownloadFailed = "install.ipsw_download_failed"
    case installAuxCreationFailed = "install.aux_creation_failed"
    case installDiskSpaceInsufficient = "install.disk_space_insufficient"
    case installInstallerFailed = "install.installer_failed"
    case installRosettaNotInstalled = "install.rosetta_not_installed"
    case installISONotFound     = "install.iso_not_found"

    // net.*
    case netBridgedNotEntitled  = "net.bridged_not_entitled"
    case netBridgedInterfaceNotFound = "net.bridged_interface_not_found"
    case netMACInvalid          = "net.mac_invalid"
    case netMACNotLocallyAdministered = "net.mac_not_locally_administered"

    // ipc.*
    case ipcSocketNotFound      = "ipc.socket_not_found"
    case ipcConnectionRefused   = "ipc.connection_refused"
    case ipcProtocolMismatch    = "ipc.protocol_mismatch"
    case ipcReadFailed          = "ipc.read_failed"
    case ipcWriteFailed         = "ipc.write_failed"
    case ipcDecodeFailed        = "ipc.decode_failed"
    case ipcRemoteError         = "ipc.remote_error"
    case ipcTimedOut            = "ipc.timed_out"

    // config.*
    case configMissingField     = "config.missing_field"
    case configInvalidEnum      = "config.invalid_enum"
    case configInvalidRange     = "config.invalid_range"
    case configDuplicateRole    = "config.duplicate_role"
}
