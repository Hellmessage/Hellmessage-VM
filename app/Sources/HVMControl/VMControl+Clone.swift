// VMControl+Clone.swift — 整 VM 克隆 (CLI + GUI 共用门面). 底层 HVMStorage/CloneManager.
//
// 单一来源: hvm-cli CloneCommand 与新 GUI NewGUIStore.clone 都走 VMControl.clone(CloneSpec),
// 不各自拼 CloneManager.Options. 新增克隆能力先加到这里, 两端自动同步.
//
// 边界 (CloneManager 内部强制): 源必须 stopped (内部抢 .edit lock, 被 .runtime 占抛 .busy);
// 源 + 目标父目录必须同 APFS 卷 (clonefile 跨卷 EXDEV); 目标不能预存在; 加密源必须传 password;
// 失败清理目标残留 (不留 partial bundle). 加密源 routing 正确重生 (vmId/displayName 重生, salt 保留).

import Foundation
import HVMCore
import HVMStorage

public extension VMControl {
    /// 克隆参数. 加密源 VM 必须传 password (调用方 prompt); 明文源传 nil.
    struct CloneSpec: Sendable {
        public var sourceBundle: URL
        public var newDisplayName: String
        /// 目标父目录, nil = 源父目录 (同卷).
        public var targetParentDir: URL?
        /// true = 保留所有 NIC MAC (用户自负: 同 LAN 双开会冲突). 默认重生.
        public var keepMACAddresses: Bool
        /// 加密源 VM 必传; 明文源 nil.
        public var password: String?

        public init(sourceBundle: URL,
                    newDisplayName: String,
                    targetParentDir: URL? = nil,
                    keepMACAddresses: Bool = false,
                    password: String? = nil) {
            self.sourceBundle = sourceBundle
            self.newDisplayName = newDisplayName
            self.targetParentDir = targetParentDir
            self.keepMACAddresses = keepMACAddresses
            self.password = password
        }
    }

    /// 执行整 VM 克隆. 成功 = 完整可用的新 bundle; 失败 = 无 partial 残留.
    @discardableResult
    static func clone(_ spec: CloneSpec) throws -> CloneManager.Result {
        let opts = CloneManager.Options(
            newDisplayName: spec.newDisplayName,
            targetParentDir: spec.targetParentDir,
            keepMACAddresses: spec.keepMACAddresses,
            password: spec.password
        )
        return try CloneManager.clone(sourceBundle: spec.sourceBundle, options: opts)
    }
}
