// HVMBackend/RunState.swift
// VM 运行状态枚举, 对应 VZVirtualMachine.State 做简化合并
// 详见 docs/VZ_BACKEND.md

import Foundation
@preconcurrency import Virtualization

public enum RunState: Equatable, Sendable, Codable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case error(String)
}

extension RunState {
    /// 从 VZVirtualMachine.State 映射. 瞬态合并为稳定态.
    static func from(_ vzState: VZVirtualMachine.State) -> RunState {
        switch vzState {
        case .stopped:                    return .stopped
        case .starting, .resuming, .restoring: return .starting
        case .running, .pausing, .saving: return .running
        case .paused:                     return .paused
        case .stopping:                   return .stopping
        case .error:                      return .error("VZ reported .error state")
        @unknown default:                 return .error("unknown VZ state: \(vzState.rawValue)")
        }
    }
}
