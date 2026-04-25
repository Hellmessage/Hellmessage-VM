// HVMInstall/RestoreImageHandle.swift
// 包 VZMacOSRestoreImage, 让上层不直接接触 VZ 类型, 同时把 image 句柄留给 MacAuxiliaryFactory /
// MacInstaller 内部复用.
//
// VZ 的 VZMacOSRestoreImage.load(from:) 是异步 + completion handler, 这里转 async/await.
// 详见 docs/GUEST_OS_INSTALL.md "macOS Guest 装机"

import Foundation
@preconcurrency import Virtualization
import HVMCore

/// IPSW 元信息 (展示用, Sendable)
public struct RestoreImageInfo: Sendable, Equatable {
    /// 例 "24A335"
    public let buildVersion: String
    /// 例 "15.0.1"
    public let osVersion: String
    /// IPSW 推荐的最低 CPU 数
    public let minCPU: Int
    /// IPSW 推荐的最低内存 (MiB)
    public let minMemoryMiB: UInt64
}

/// 持有已 load 的 VZMacOSRestoreImage. 给装机和 aux 创建复用同一份, 不重复 IO.
public final class RestoreImageHandle: @unchecked Sendable {
    public let info: RestoreImageInfo
    /// VZ 句柄. 仅 HVMInstall 内部使用 (创建 aux / 装机)
    internal let image: VZMacOSRestoreImage

    private init(info: RestoreImageInfo, image: VZMacOSRestoreImage) {
        self.info = info
        self.image = image
    }

    /// 加载并校验 IPSW. 失败抛 HVMError.install(.ipswNotFound / .ipswUnsupported)
    public static func load(from ipswURL: URL) async throws -> RestoreImageHandle {
        guard FileManager.default.fileExists(atPath: ipswURL.path) else {
            throw HVMError.install(.ipswNotFound(path: ipswURL.path))
        }

        // VZMacOSRestoreImage 不是 Sendable, 跨 continuation 传会触发 Swift 6 sending 警告.
        // 实际 VZ 这类对象都要求主线程使用, 这里 box 一下抑制警告 — 真正使用 (mostFeaturefulSupportedConfiguration)
        // 都发生在 MainActor 上.
        struct ImageBox: @unchecked Sendable { let value: VZMacOSRestoreImage }

        let box: ImageBox
        do {
            box = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ImageBox, Error>) in
                VZMacOSRestoreImage.load(from: ipswURL) { result in
                    switch result {
                    case .success(let img): cont.resume(returning: ImageBox(value: img))
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
            }
        } catch {
            throw HVMError.install(.ipswUnsupported(reason: "load IPSW failed: \(error)"))
        }
        let image = box.value

        guard let req = image.mostFeaturefulSupportedConfiguration else {
            throw HVMError.install(.ipswUnsupported(
                reason: "VZ 不支持此 IPSW (mostFeaturefulSupportedConfiguration=nil); 可能 IPSW 太老或与本机硬件不兼容"
            ))
        }
        guard req.hardwareModel.isSupported else {
            throw HVMError.install(.ipswUnsupported(
                reason: "VZ 不支持此 IPSW 的 hardware model (req.hardwareModel.isSupported=false)"
            ))
        }

        let v = image.operatingSystemVersion
        let osVer = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let info = RestoreImageInfo(
            buildVersion: image.buildVersion,
            osVersion: osVer,
            minCPU: req.minimumSupportedCPUCount,
            minMemoryMiB: req.minimumSupportedMemorySize / (1024 * 1024)
        )
        return RestoreImageHandle(info: info, image: image)
    }
}
