// hvm-dbg/Support/BundleResolve.swift
// 同 hvm-cli/Support/BundleResolve.swift, 复制一份给独立 target 用

import Foundation
import HVMCore
import HVMBundle

public enum BundleResolve {
    public static var defaultRoot: URL { HVMPaths.vmsRoot }

    public static func resolve(_ ref: String) throws -> URL {
        if let url = BundleDiscovery.resolve(reference: ref, defaultRoot: defaultRoot) {
            return url
        }
        throw HVMError.bundle(.notFound(path: ref))
    }
}
