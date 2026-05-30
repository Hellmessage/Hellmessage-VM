// ProgressTracker.swift — JSON 模式下载进度步进过滤器 (CLI 自用, 跨命令共享).
//
// 原在 IpswCommand.swift, 随 macOS/IPSW 命令下线抽到此处 (osimage 等 Linux/Windows
// ISO 下载命令仍需). onProgress 闭包跨线程, 用 NSLock 保护 lastFraction.

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
