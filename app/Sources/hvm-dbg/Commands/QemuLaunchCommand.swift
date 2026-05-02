// hvm-dbg/Commands/QemuLaunchCommand.swift
// hvm-dbg qemu-launch — 独立调试命令: 直接拉起 QEMU 后端 VM, 绕过 hvm-cli start
// 的 host process / IPC server 流程. 用于验证 QEMU 模块端到端正确性.
//
// 与 hvm-cli start 的区别:
//   - hvm-cli start 走 HVMHost 子进程 + IPC, VZ 后端正式生产路径
//   - hvm-dbg qemu-launch 直接 in-process 启动 QEMU, 命令前台等待, ctrl+c 走 ACPI
//   - 不抢 BundleLock (这是调试命令; 别人若已起着, 端口冲突自见)
//
// 用法:
//   hvm-dbg qemu-launch <vm-name>           # 启动并附着
//   hvm-dbg qemu-launch <vm-name> --dry-run # 仅打印 argv

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMInstall
import HVMQemu
import Darwin

struct QemuLaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qemu-launch",
        abstract: "调试: 直接拉起 QEMU 后端 VM (绕过 hvm-cli start 的 host 进程流程)"
    )

    @Argument(help: "VM 名称或 .hvmz bundle 路径")
    var vm: String

    @Flag(name: .long, help: "仅打印 argv 然后退出, 不真启 QEMU")
    var dryRun: Bool = false

    @Option(name: .long, help: "ACPI shutdown 等待秒数 (超时强杀); 默认 10")
    var shutdownTimeout: Int = 10

    func run() async throws {
        let bundleURL = try BundleResolve.resolve(vm)
        let config = try BundleIO.load(from: bundleURL)

        guard config.engine == .qemu else {
            FileHandle.standardError.write("✗ engine=\(config.engine.rawValue), 不是 qemu. ".data(using: .utf8)!)
            FileHandle.standardError.write("VZ VM 请用 hvm-cli start <name>\n".data(using: .utf8)!)
            throw ExitCode(2)
        }

        // 路径解析
        let qemuRoot: URL
        let qemuBin: URL
        do {
            qemuRoot = try QemuPaths.resolveRoot()
            qemuBin = try QemuPaths.qemuBinary()
        } catch {
            FileHandle.standardError.write("✗ 找不到 QEMU 包: \(error)\n".data(using: .utf8)!)
            FileHandle.standardError.write("  开发期请先 make qemu (10-30 分钟首次), 或 export HVM_QEMU_ROOT=...\n".data(using: .utf8)!)
            throw ExitCode(3)
        }

        try HVMPaths.ensure(HVMPaths.runDir)
        let qmpSocket = HVMPaths.qmpSocketPath(for: config.id)
        // 清残留 socket (上次崩溃留的会让 QEMU bind 失败)
        try? FileManager.default.removeItem(at: qmpSocket)

        // virtio-win (windows guest only); 调试命令不做下载, 已缓存就挂, 否则警告
        var virtioWinPath: String? = nil
        if config.guestOS == .windows, VirtioWinCache.isReady {
            virtioWinPath = VirtioWinCache.cachedISOURL.path
        } else if config.guestOS == .windows {
            FileHandle.standardError.write("⚠ virtio-win.iso 未缓存, Win 装机看不到 virtio-blk 盘\n".data(using: .utf8)!)
        }

        // swtpm sidecar (windows + tpmEnabled). 未启或路径找不到会让 Win11 在 TPM 检查处失败.
        var swtpmRunner: SwtpmRunner? = nil
        var swtpmSockPath: String? = nil
        if config.guestOS == .windows, config.windows?.tpmEnabled == true {
            (swtpmRunner, swtpmSockPath) = try await launchSwtpmSidecar(config: config, bundleURL: bundleURL)
        }

        // socket_vmnet 现在是系统级 launchd daemon (scripts/install-vmnet-helper.sh 安装),
        // QemuArgsBuilder 直接连 /var/run/socket_vmnet*; daemon 缺会抛 configInvalid

        let inputs = QemuArgsBuilder.Inputs(
            config: config,
            bundleURL: bundleURL,
            qemuRoot: qemuRoot,
            qmpSocketPath: qmpSocket.path,
            virtioWinISOPath: virtioWinPath,
            swtpmSocketPath: swtpmSockPath
        )
        let buildResult = try QemuArgsBuilder.build(inputs)

        if dryRun {
            print(qemuBin.path)
            for a in buildResult.args { print("  \(a)") }
            return
        }

        // stderr 落全局 ~/Library/.../HVM/logs/<displayName>-<uuid8>/qemu-stderr.log;
        // 每次 truncate 避免累积老错误干扰判断
        let qemuLogsDir = HVMPaths.vmLogsDir(displayName: config.displayName, id: config.id)
        _ = try? HVMPaths.ensure(qemuLogsDir)
        let stderrLog = qemuLogsDir.appendingPathComponent("qemu-stderr.log")
        try? FileManager.default.removeItem(at: stderrLog)

        // 桥接 (vmnet) 路径已下线; 当前仅 .nat 可用, 不需要父进程 fd 透传.
        let runner = QemuProcessRunner(
            binary: qemuBin, args: buildResult.args, stderrLog: stderrLog
        )
        try runner.start()
        if case .running(let pid) = runner.state {
            print("✔ QEMU 已启动 pid=\(pid)")
            print("  bundle: \(bundleURL.path)")
            print("  qmp:    \(qmpSocket.path)")
            print("  stderr: \(stderrLog.path)")
        }

        // QMP 连接重试: QEMU bind unix socket 与 listen 之间有窗口, ECONNREFUSED 期间重试.
        // 同时若 QEMU 进程提前退出 (例如缺 ROM / 配置错误), 不再继续重试.
        var client: QmpClient?
        let connectDeadline = Date().addingTimeInterval(TimeInterval(HVMTimeout.qmpConnect))
        var lastErr: Error?
        while Date() < connectDeadline {
            // QEMU 已退出 (例如配置错误立即崩) → 不再重试
            if case .exited = runner.state { break }
            if case .crashed = runner.state { break }
            // socket 文件还没出现 → 等
            if !FileManager.default.fileExists(atPath: qmpSocket.path) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            let c = QmpClient(socketPath: qmpSocket.path)
            do {
                try await c.connect()
                client = c
                break
            } catch {
                lastErr = error
                c.close()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard let client else {
            FileHandle.standardError.write("✗ QMP 连接失败 (15s 超时): \(lastErr.map(String.init(describing:)) ?? "未知")\n".data(using: .utf8)!)
            FileHandle.standardError.write("  QEMU 状态: \(runner.state)\n".data(using: .utf8)!)
            FileHandle.standardError.write("  查看 stderr: tail \(stderrLog.path)\n".data(using: .utf8)!)
            runner.forceKill()
            runner.waitUntilExit()
            throw ExitCode(5)
        }

        let status = try await client.queryStatus()
        print("✔ QMP 已连接 — vm status: \(status.status) (running=\(status.running))")
        print()
        print("  ctrl+c → 发 system_powerdown (\(shutdownTimeout)s 超时强杀)")
        print()

        // 主循环: 同时等 (a) QEMU 进程退 (b) ctrl+c (c) SHUTDOWN event
        let waiter = ExitWaiter()
        runner.addStateObserver { state in
            switch state {
            case .exited, .crashed: waiter.signal(reason: "process \(state)")
            default: break
            }
        }

        let eventTask = Task {
            for await event in client.events {
                print("  [event] \(event.name)")
                if event.name == "SHUTDOWN" {
                    waiter.signal(reason: "QMP SHUTDOWN event")
                    return
                }
            }
        }

        // SIGINT (ctrl+c) → ACPI powerdown + 强杀 fallback
        // 注: signal(SIGINT, SIG_IGN) 后 DispatchSource 才能可靠拦截
        signal(SIGINT, SIG_IGN)
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let timeout = self.shutdownTimeout
        sigSrc.setEventHandler {
            print("\n⏎ ctrl+c → system_powerdown")
            Task {
                do {
                    try await client.systemPowerdown()
                } catch {
                    FileHandle.standardError.write("system_powerdown 失败: \(error)\n".data(using: .utf8)!)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if !waiter.isSignaled {
                    print("⚠ guest \(timeout)s 内未响应 ACPI, 强杀")
                    runner.forceKill()
                }
            }
        }
        sigSrc.resume()

        // 阻塞等
        await waiter.wait()
        eventTask.cancel()
        runner.waitUntilExit()
        client.close()

        // swtpm: --terminate 通常已让它自退; 保险再 SIGTERM
        if let s = swtpmRunner {
            s.terminate()
            s.waitUntilExit()
            if let p = swtpmSockPath {
                try? FileManager.default.removeItem(atPath: p)
            }
        }

        // socket_vmnet 是系统级 launchd daemon, 不归本命令生命周期, 不动

        // 清 socket 残留
        try? FileManager.default.removeItem(at: qmpSocket)

        switch runner.state {
        case .exited(let code):
            print("✔ QEMU 已退出 exit=\(code)")
        case .crashed(let signal):
            print("✔ QEMU 已退出 signal=\(signal)")
        default:
            print("✔ 退出 state=\(runner.state)")
        }
    }

    /// 轮询等文件出现 (QEMU 启动到 QMP listen 之间有几百 ms 窗口)
    private func waitForFile(_ path: String, timeoutSec: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// 启动 swtpm sidecar 并等 socket 就绪. 失败 throw ExitCode (调试命令直接退).
    private func launchSwtpmSidecar(config: VMConfig, bundleURL: URL) async throws -> (SwtpmRunner, String) {
        let swtpmBin: URL
        do {
            swtpmBin = try SwtpmPaths.locate()
        } catch {
            FileHandle.standardError.write("✗ swtpm 未找到: \(error)\n".data(using: .utf8)!)
            FileHandle.standardError.write("  brew install swtpm 或 make qemu (打包后含)\n".data(using: .utf8)!)
            throw ExitCode(30)
        }

        let stateDir = BundleLayout.tpmStateDir(bundleURL)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try HVMPaths.ensure(HVMPaths.runDir)
        let sockPath = HVMPaths.swtpmSocketPath(for: config.id).path
        let pidPath = HVMPaths.swtpmPidPath(for: config.id)
        let swtpmLogsDir = HVMPaths.vmLogsDir(displayName: config.displayName, id: config.id)
        try HVMPaths.ensure(swtpmLogsDir)
        let logFile = swtpmLogsDir.appendingPathComponent("swtpm.log")
        try? FileManager.default.removeItem(atPath: sockPath)
        try? FileManager.default.removeItem(at: pidPath)

        let argsList = SwtpmArgsBuilder.build(SwtpmArgsBuilder.Inputs(
            stateDir: stateDir, ctrlSocketPath: sockPath,
            logFile: logFile, pidFile: pidPath
        ))
        let stderrLog = swtpmLogsDir.appendingPathComponent("swtpm-stderr.log")
        try? FileManager.default.removeItem(at: stderrLog)
        let runner = SwtpmRunner(binary: swtpmBin, args: argsList,
                                 ctrlSocketPath: sockPath, stderrLog: stderrLog)
        do {
            try runner.start()
        } catch {
            FileHandle.standardError.write("✗ swtpm 启动失败: \(error)\n".data(using: .utf8)!)
            throw ExitCode(31)
        }
        let ready = await runner.waitForSocketReady(timeoutSec: 5)
        guard ready else {
            FileHandle.standardError.write("✗ swtpm socket 5s 未就绪 (state=\(runner.state))\n".data(using: .utf8)!)
            FileHandle.standardError.write("  详见 \(stderrLog.path) 与 \(logFile.path)\n".data(using: .utf8)!)
            runner.forceKill()
            runner.waitUntilExit()
            throw ExitCode(32)
        }
        print("✔ swtpm 已启动 sock=\(sockPath)")
        return (runner, sockPath)
    }

}

/// 简单的一次性 signal/wait, 用 CheckedContinuation 配合 NSLock
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var reason: String?

    var isSignaled: Bool {
        lock.lock(); defer { lock.unlock() }
        return signaled
    }

    func signal(reason: String) {
        lock.lock()
        if signaled { lock.unlock(); return }
        signaled = true
        self.reason = reason
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}
