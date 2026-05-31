// HVMStorage/ISOValidator.swift
// ISO 路径合法性校验. ISO 不进 bundle, 只存绝对路径.

import Foundation
import HVMCore

public enum ISOValidator {
    /// 校验 ISO 存在且尺寸在 [1 MiB, 20 GiB) 范围. 超范围多半是选错文件, 早失败好过挂载后启动不了.
    public static func validate(at path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw HVMError.storage(.isoMissing(path: path))
        }
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        let minBytes: Int64 = 1 << 20
        let maxBytes: Int64 = 20 << 30
        guard (minBytes..<maxBytes).contains(size) else {
            throw HVMError.storage(.isoSizeSuspicious(bytes: size))
        }
    }
}
