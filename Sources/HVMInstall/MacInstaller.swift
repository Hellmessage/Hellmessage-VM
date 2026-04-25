// HVMInstall/MacInstaller.swift
// macOS guest 全自动装机. 流程:
//   preparing  → load IPSW, 校验 CPU/RAM, 写 auxiliary 三件套, 创建主盘
//   installing → VZMacOSInstaller.install + KVO 进度
//   finalizing → config.macOS.autoInstalled=true + bootFromDiskOnly=true 落盘
//
// 调用方负责: 1) bundle 不在跑 (BundleLock.isBusy 检查) 2) 装机期间不能并发 vm.start.
// 详见 docs/GUEST_OS_INSTALL.md "流程".

import Foundation
@preconcurrency import Virtualization
import HVMBackend
import HVMBundle
import HVMCore
import HVMStorage

@MainActor
public final class MacInstaller {
    public init() {}

    /// 完整装机流程. 进度通过 onProgress 推 (调用线程 = MainActor).
    /// - Parameters:
    ///   - bundleURL: .hvmz bundle 根
    ///   - config:    bundle 当前 config (调用方已确保 guestOS=.macOS)
    ///   - ipswURL:   IPSW 绝对路径
    ///   - onProgress: 进度回调, MainActor 上下文
    public func install(
        bundleURL: URL,
        config: VMConfig,
        ipswURL: URL,
        onProgress: @MainActor @escaping (InstallProgress) -> Void
    ) async throws {
        guard config.guestOS == .macOS else {
            throw HVMError.install(.installerFailed(reason: "MacInstaller 仅用于 macOS guest"))
        }
        if BundleLock.isBusy(bundleURL: bundleURL) {
            throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
        }

        onProgress(.preparing)

        // 1. 加载 + 校验 IPSW
        let handle = try await RestoreImageHandle.load(from: ipswURL)

        // 2. CPU / RAM 与 IPSW 推荐对比
        if config.cpuCount < handle.info.minCPU {
            throw HVMError.install(.ipswUnsupported(
                reason: "IPSW 要求至少 \(handle.info.minCPU) 核, 当前配置 \(config.cpuCount) 核"
            ))
        }
        if config.memoryMiB < handle.info.minMemoryMiB {
            throw HVMError.install(.ipswUnsupported(
                reason: "IPSW 要求至少 \(handle.info.minMemoryMiB / 1024) GiB 内存, 当前配置 \(config.memoryMiB / 1024) GiB"
            ))
        }

        // 3. 卷空间预检 (主盘 + IPSW 缓冲, 估 IPSW 大小 × 2)
        let ipswSize = (try? FileManager.default.attributesOfItem(atPath: ipswURL.path)[.size] as? UInt64) ?? 0
        let mainDiskGiB = config.disks.first(where: { $0.role == .main })?.sizeGiB ?? 0
        let required = mainDiskGiB * (1 << 30) + ipswSize * 2
        try VolumeInfo.assertSpaceAvailable(at: bundleURL.path, requiredBytes: required)

        // 4. 写 auxiliary 三件套
        try MacAuxiliaryFactory.create(in: bundleURL, from: handle)

        // 5. 主盘按需创建 (装机走的是 raw sparse, VZ 写入)
        let mainDiskURL = BundleLayout.mainDiskURL(bundleURL)
        if !FileManager.default.fileExists(atPath: mainDiskURL.path) {
            guard let mainDisk = config.disks.first(where: { $0.role == .main }) else {
                throw HVMError.install(.installerFailed(reason: "config 缺主盘 spec"))
            }
            try DiskFactory.create(at: mainDiskURL, sizeGiB: mainDisk.sizeGiB)
        }

        // 6. 构建 VZ config (走 ConfigBuilder 的 macOS 分支, 读 auxiliary 已经落盘的三件套)
        // 装机阶段也会创建 ConsoleBridge (带回 built.consoleBridge), 用 _ 持有保证 fd 不被 GC.
        let built: ConfigBuilder.BuildResult
        do {
            built = try ConfigBuilder.build(from: config, bundleURL: bundleURL)
        } catch {
            throw HVMError.install(.installerFailed(reason: "build VZ config: \(error)"))
        }
        let consoleBridge = built.consoleBridge  // 持有, 否则 fd 提前释放
        defer { consoleBridge.close() }

        // 7. 创建 VM + VZMacOSInstaller, 进度走 KVO
        let vm = VZVirtualMachine(configuration: built.vzConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)

        // KVO 进度. NSKeyValueObservation 在 invalidate 前一直推送.
        // 用 @Sendable 包一下避免 Swift 6 警告.
        let progressBox = ProgressBox(onProgress: onProgress)
        let observer = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            let v = progress.fractionCompleted
            Task { @MainActor in
                progressBox.fire(.installing(fraction: v))
            }
        }

        // 8. 异步装机
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                installer.install { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
        } catch {
            observer.invalidate()
            throw HVMError.install(.installerFailed(reason: "\(error)"))
        }
        observer.invalidate()

        // 9. 写 config: autoInstalled=true, bootFromDiskOnly=true
        onProgress(.finalizing)
        var newConfig = config
        newConfig.macOS = MacOSSpec(ipsw: ipswURL.path, autoInstalled: true)
        newConfig.bootFromDiskOnly = true
        do {
            try BundleIO.save(config: newConfig, to: bundleURL)
        } catch {
            throw HVMError.install(.installerFailed(reason: "save config: \(error)"))
        }
    }
}

/// 把 onProgress 闭包包进 reference 内, 避免 Swift 6 在 Task @Sendable 闭包里捕获非 Sendable 闭包.
/// MainActor 隔离, 调用方都在 main actor 上.
@MainActor
private final class ProgressBox {
    private let onProgress: @MainActor (InstallProgress) -> Void
    init(onProgress: @MainActor @escaping (InstallProgress) -> Void) {
        self.onProgress = onProgress
    }
    func fire(_ p: InstallProgress) { onProgress(p) }
}
