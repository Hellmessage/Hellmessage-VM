// HVMNet/NICFactory.swift
// 从 NetworkSpec 构建 VZVirtioNetworkDeviceConfiguration.
//
// VZ 后端不支持 socket_vmnet 风格的 shared/host 多 guest 互通; mode 映射:
//   .user / .vmnetShared / .vmnetHost / .none → VZNAT (退化)
//   .vmnetBridged                              → VZBridgedNetworkDeviceAttachment
//
// .vmnetShared / .vmnetHost 在 VZ 上的退化 NAT 行为是兜底 — 用户若要真 vmnet 多 guest
// 互通, 应当走 QEMU 后端. 见 docs/NETWORK.md (待更新).

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore

public enum NICFactory {
    /// 构建一个 virtio 网卡. 调用方负责跳过 enabled=false / mode=.none 的 spec.
    public static func make(spec: NetworkSpec) throws -> VZVirtioNetworkDeviceConfiguration {
        try MACAddressGenerator.validate(spec.macAddress)
        guard let mac = VZMACAddress(string: spec.macAddress) else {
            throw HVMError.net(.macInvalid(spec.macAddress))
        }

        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.macAddress = mac

        switch spec.mode {
        case .user, .vmnetShared, .vmnetHost, .none:
            // VZ 没有 socket_vmnet 等价, 退化到 NAT (与 hell-vm 注释一致)
            nic.attachment = VZNATNetworkDeviceAttachment()

        case .vmnetBridged:
            let wantedIface = spec.effectiveBridgedInterface ?? "en0"
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            guard let iface = interfaces.first(where: { $0.identifier == wantedIface }) else {
                throw HVMError.net(.bridgedInterfaceNotFound(
                    requested: wantedIface,
                    available: interfaces.map { $0.identifier }
                ))
            }
            nic.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
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
