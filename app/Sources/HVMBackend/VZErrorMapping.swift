// HVMBackend/VZErrorMapping.swift
// 把 VZ framework 抛出的 NSError 翻译成更具体的 HVMCore.BackendError case.
//
// 之前各处调用都直接 .vzInternal(description: "\(error)"), 用户最终看到的 user-facing
// 永远是泛泛的 "VZ 内部错误". 实际 VZError 有很丰富的分类:
//   - invalidVirtualMachineConfiguration → 配置无效, 应映射到 .configInvalid (有 hint)
//   - invalidVirtualMachineState / invalidVirtualMachineStateTransition → .invalidTransition
//   - outOfDiskSpace / networkError / operationCancelled → 保留具体码名让用户能搜
//
// 此文件在 HVMBackend (已 import Virtualization), 给 BackendError 加扩展静态方法
// fromVZ(_:op:) 让 VMHandle 等模块统一通过它构造错误.

import Foundation
@preconcurrency import Virtualization
import HVMCore

public extension BackendError {
    /// 翻译 VZ framework 给的 Error 到具体的 BackendError case.
    /// 非 VZ error 退化到 .vzInternal 但保留 op 上下文.
    /// - Parameter op: 调用方在做的高层操作 (例 "vm.start" / "vm.requestStop"), 进错误消息便于排查
    static func fromVZ(_ error: Error, op: String) -> BackendError {
        let ns = error as NSError
        guard ns.domain == VZErrorDomain else {
            return .vzInternal(description: "\(op): \(error)")
        }
        guard let code = VZError.Code(rawValue: ns.code) else {
            return .vzInternal(description: "\(op): VZ code=\(ns.code) (\(ns.localizedDescription))")
        }
        switch code {
        case .invalidVirtualMachineConfiguration:
            return .configInvalid(field: "(vz config)", reason: ns.localizedDescription)
        case .invalidVirtualMachineState, .invalidVirtualMachineStateTransition:
            return .invalidTransition(from: "(vz)", to: op)
        default:
            // 其他 case 保留 case 名 + localizedDescription, 方便用户/我们 grep
            return .vzInternal(description: "\(op): VZ.\(String(describing: code)) (\(ns.localizedDescription))")
        }
    }
}
