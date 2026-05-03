// HVMUtils/FSCleanup.swift
// 文件清理 helper. 之前业务侧大量 `try? FileManager.removeItem(at:)` 静默吞错;
// 失败时残留 socket 会让 QEMU 下次 bind 报神秘 "address already in use", 用户难定位.
//
// 这里给清理接口加一层: 文件不存在视为成功(常见情况, 不打日志); 其他错误 log warning,
// 不阻塞流程 (清理本来就是尽力而为, 不应让主流程挂死).

import Foundation
import HVMCore

public enum FSCleanup {
    private static let log = HVMLog.logger("fs.cleanup")

    /// 删文件 / 目录, 不存在视为成功. 真失败 (权限 / I/O) 时 log warning 不抛.
    /// - Parameter context: 出现在日志里的诊断标签 (例如 "qmp socket" / "swtpm pid").
    public static func removeQuietly(at url: URL, context: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // 不存在 = 已干净, 不打日志
        } catch {
            log.warning("清理 \(context, privacy: .public) 失败 path=\(url.path, privacy: .public) err=\(String(describing: error), privacy: .public)")
        }
    }

    /// path 版.
    public static func removeQuietly(atPath path: String, context: String) {
        removeQuietly(at: URL(fileURLWithPath: path), context: context)
    }
}
