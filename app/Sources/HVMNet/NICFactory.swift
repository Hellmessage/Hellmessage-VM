// HVMNet/NICFactory.swift
// 从 NetworkSpec 构建 VZVirtioNetworkDeviceConfiguration.
//
// 当前仅支持 .nat. 桥接 (.bridged / .shared) 路径已临时下线 — 等待 hell-vm 风格新方案
// 接上, 那时 VZ 后端的 .bridged 仍走 VZBridgedNetworkDeviceAttachment (Apple framework).
// 现在收到 .bridged/.shared 直接抛 configInvalid, 跟 QEMU 后端口径一致.

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore

public enum NICFactory {
    /// 构建一个 virtio 网卡. 当前仅支持 .nat; .bridged/.shared 抛 configInvalid.
    public static func make(spec: NetworkSpec) throws -> VZVirtioNetworkDeviceConfiguration {
        try MACAddressGenerator.validate(spec.macAddress)
        guard let mac = VZMACAddress(string: spec.macAddress) else {
            throw HVMError.net(.macInvalid(spec.macAddress))
        }

        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.macAddress = mac

        switch spec.mode {
        case .nat:
            nic.attachment = VZNATNetworkDeviceAttachment()

        case .bridged, .shared:
            throw HVMError.backend(.configInvalid(
                field: "network.mode",
                reason: "桥接 / shared 网络当前临时禁用 (重写中, 切换 hell-vm 风格新方案); 请改用 NAT"
            ))
        }

        return nic
    }
}

public struct BridgedInterfaceInfo: Sendable, Equatable {
    public let identifier: String
    public let localizedDisplayName: String
}

public enum NetworkInterfaceList {
    /// 枚举可用桥接接口 (需 com.apple.vm.networking entitlement).
    /// entitlement 未启用时该数组通常为空, 不抛错.
    public static var bridged: [BridgedInterfaceInfo] {
        VZBridgedNetworkInterface.networkInterfaces.map {
            BridgedInterfaceInfo(
                identifier: $0.identifier,
                localizedDisplayName: $0.localizedDisplayName ?? $0.identifier
            )
        }
    }
}
