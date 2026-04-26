// BundleResolve.swift
// 统一把 CLI 参数里的 <vm> 解析为 bundle URL

import Foundation
import HVMCore
import HVMBundle

public enum BundleResolve {
    public static var defaultRoot: URL { HVMPaths.vmsRoot }

    /// 解析失败抛 HVMError.bundle(.notFound)
    public static func resolve(_ ref: String) throws -> URL {
        if let url = BundleDiscovery.resolve(reference: ref, defaultRoot: defaultRoot) {
            return url
        }
        throw HVMError.bundle(.notFound(path: ref))
    }
}
