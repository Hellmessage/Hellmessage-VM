// ProgressTracker.swift — JSON 模式下载进度步进过滤器 (跨命令共享).
// onProgress 闭包跨线程, 用 NSLock 保护 lastFraction.

import Foundation

final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction: Double = -1

    func shouldEmit(_ f: Double, threshold: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if f - lastFraction >= threshold {
            lastFraction = f
            return true
        }
        return false
    }
}
