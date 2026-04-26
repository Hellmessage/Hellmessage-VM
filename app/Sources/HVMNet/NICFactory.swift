// HVMNet/NICFactory.swift
// 从 NetworkSpec 构建 VZVirtioNetworkDeviceConfiguration.
// M1 仅 NAT 路径; bridged 分支保留, entitlement 未就绪时抛错 (见 docs/NETWORK.md)

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore

public enum NICFactory {
    /// 构建一个 virtio 网卡. NetworkMode = .bridged 时:
    ///   - 若 entitlement 未就绪或目标接口不存在, 抛 HVMError.net.*
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

        case .bridged(let wantedIface):
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            guard let iface = interfaces.first(where: { $0.identifier == wantedIface }) else {
                throw HVMError.net(.bridgedInterfaceNotFound(
                    requested: wantedIface,
                    available: interfaces.map { $0.identifier }
                ))
            }
            nic.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)

        case .shared:
            // VZ 后端不支持 socket_vmnet 风格的 shared (多 guest 互通); 退化到 NAT,
            // 用户若要真 shared 应走 QEMU 后端. 见 docs/NETWORK.md.
            // GUI/CLI 入口已在 engine=vz 时不暴露 .shared, 这里是兜底防 config 手改.
            nic.attachment = VZNATNetworkDeviceAttachment()
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
