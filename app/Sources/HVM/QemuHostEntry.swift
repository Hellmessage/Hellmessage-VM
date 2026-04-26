// HVM/QemuHostEntry.swift
// VMHost 进程的 QEMU 后端分支. HVMHostEntry.run() 看到 config.engine == .qemu 时分派到此.
//
// 与 VZ runVZ 的差异:
//   - 不开离屏 NSWindow, 不挂 HVMView (QEMU -display cocoa 自开窗口)
//   - 不接 DbgOps (QEMU dbg.* 一期不支持)
//   - 用 QemuProcessRunner + QmpClient 替代 VMHandle
//
// 共用部分:
//   - NSApp accessory 策略 + menu bar 状态栏图标 (复用 HostStatusMenuController 风格)
//   - IPC SocketServer (复用 HVMIPC), CLI 端 hvm-cli status / stop / kill 兼容
//   - BundleLock (调用方已抢)
//   - 退出码语义与 VZ 路径一致 (3=load, 4=lock; 20+ 是 QEMU 特有)

import AppKit
import Foundation
import HVMBackend
import HVMBundle
import HVMCore
import HVMInstall
import HVMIPC
import HVMQemu

public enum QemuHostEntry {
    @MainActor
    public static func run(
        config: VMConfig,
        bundleURL: URL,
        lock: BundleLock,
        socketURL: URL,
        startedAt: Date
    ) -> Never {
        // 1. 路径解析
        let qemuRoot: URL
        let qemuBin: URL
        do {
            qemuRoot = try QemuPaths.resolveRoot()
            qemuBin = try QemuPaths.qemuBinary()
        } catch {
            fputs("HVMHost(qemu): QEMU 包未找到: \(error)\n", stderr)
            fputs("  开发期请先 make qemu, 或 export HVM_QEMU_ROOT=...\n", stderr)
            lock.release()
            exit(20)
        }

        let qmpSocketURL = HVMPaths.runDir
            .appendingPathComponent("\(config.id.uuidString.lowercased()).qmp")
        // 清残留 socket (上次崩溃留的会让 QEMU bind 失败)
        try? FileManager.default.removeItem(at: qmpSocketURL)

        // 2. virtio-win 路径解析 (windows guest 才用; 缓存就绪才挂第二 cdrom).
        //    创建 Win VM 时 GUI 会前台触发 ensureCached; 这里不做下载, 缺则降级.
        var virtioWinPath: String? = nil
        if config.guestOS == .windows {
            if VirtioWinCache.isReady {
                virtioWinPath = VirtioWinCache.cachedISOURL.path
            } else {
                fputs("HVMHost(qemu): ⚠ virtio-win.iso 未缓存, Win 装机将看不到 virtio-blk 盘\n", stderr)
                fputs("  GUI 创建向导会自动下载; CLI 创建后请用 GUI Cache → Download virtio-win\n", stderr)
            }
        }

        // 3. 构造 argv
        let args: [String]
        do {
            let inputs = QemuArgsBuilder.Inputs(
                config: config, bundleURL: bundleURL,
                qemuRoot: qemuRoot, qmpSocketPath: qmpSocketURL.path,
                virtioWinISOPath: virtioWinPath
            )
            args = try QemuArgsBuilder.build(inputs)
        } catch {
            fputs("HVMHost(qemu): argv 构造失败: \(error)\n", stderr)
            lock.release()
            exit(21)
        }

        // 3. stderr 落 bundle/logs/qemu-stderr.log (truncate, 不累积老错误)
        let stderrLog = BundleLayout.logsDir(bundleURL)
            .appendingPathComponent("qemu-stderr.log")
        try? FileManager.default.removeItem(at: stderrLog)

        // 4. 启动 QEMU 子进程
        let runner = QemuProcessRunner(binary: qemuBin, args: args, stderrLog: stderrLog)
        do {
            try runner.start()
        } catch {
            fputs("HVMHost(qemu): QEMU 启动失败: \(error)\n", stderr)
            lock.release()
            exit(22)
        }
        fputs("HVMHost(qemu): QEMU 已启动 (state=\(runner.state)) bundle=\(bundleURL.lastPathComponent)\n", stderr)

        // 5. NSApp accessory 策略 + 状态栏图标
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        QemuHostState.shared.config = config
        QemuHostState.shared.bundleURL = bundleURL
        QemuHostState.shared.runner = runner
        QemuHostState.shared.qmpSocketURL = qmpSocketURL
        QemuHostState.shared.lock = lock
        QemuHostState.shared.startedAt = startedAt
        QemuHostState.shared.installStatusItem(displayName: config.displayName)

        // 6. QMP 连接 (重试; 同时监控进程 state, 若 QEMU 早退不再重试)
        Task { @MainActor in
            let client = await tryConnectQmp(
                socketPath: qmpSocketURL.path,
                runner: runner,
                deadlineSec: 15
            )
            guard let client else {
                fputs("HVMHost(qemu): QMP 连接失败 (15s 超时); 查看 \(stderrLog.path)\n", stderr)
                runner.forceKill()
                runner.waitUntilExit()
                try? FileManager.default.removeItem(at: qmpSocketURL)
                lock.release()
                exit(23)
            }
            QemuHostState.shared.qmpClient = client
            fputs("HVMHost(qemu): QMP 已连接\n", stderr)

            // 6a. 监听 QMP 异步事件: SHUTDOWN / POWERDOWN → 等进程 exit
            Task { @MainActor in
                for await event in client.events {
                    fputs("HVMHost(qemu): [event] \(event.name)\n", stderr)
                    if event.name == "SHUTDOWN" {
                        // SHUTDOWN 之后 QEMU 通常自动 exit (-no-reboot 加持下), 由 process observer 收尾
                        return
                    }
                }
            }

            // 6b. 进程退出观察: clean exit / crash → tear down + exit 主进程
            runner.addStateObserver { state in
                switch state {
                case .exited(let code):
                    DispatchQueue.main.async {
                        fputs("HVMHost(qemu): QEMU 进程已退出 exit=\(code)\n", stderr)
                        QemuHostState.shared.tearDown(exitCode: 0)
                    }
                case .crashed(let signal):
                    DispatchQueue.main.async {
                        fputs("HVMHost(qemu): QEMU 进程被信号杀 signal=\(signal)\n", stderr)
                        QemuHostState.shared.tearDown(exitCode: 11)
                    }
                default: break
                }
            }
        }

        // 7. IPC server (与 VZ 路径同 socketPath; CLI 客户端无需感知 backend 类型)
        let server = SocketServer(socketPath: socketURL)
        QemuHostState.shared.ipcServer = server
        do {
            try server.start { req in
                let box = ResponseBox(.failure(id: req.id, code: "ipc.internal", message: "未初始化"))
                let sem = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    box.value = await QemuHostState.shared.handle(req)
                    sem.signal()
                }
                sem.wait()
                return box.value
            }
        } catch let e as HVMError {
            fputs("HVMHost(qemu): IPC server 启动失败: \(e.userFacing.message)\n", stderr)
            runner.forceKill()
            runner.waitUntilExit()
            lock.release()
            exit(12)
        } catch {
            fputs("HVMHost(qemu): IPC server 启动失败: \(error)\n", stderr)
            runner.forceKill()
            runner.waitUntilExit()
            lock.release()
            exit(12)
        }

        fputs("HVMHost(qemu): 就绪 (pid=\(getpid()), qmp=\(qmpSocketURL.lastPathComponent))\n", stderr)

        // 8. NSApp.run() 驻留主循环 (status item + Cocoa 显示渲染依赖 main event loop)
        app.run()
        exit(0)
    }

    /// QMP 连接重试: bind 与 listen 之间有窗口, 200ms 间隔 backoff;
    /// 若 QEMU 进程提前 exit/crashed (如配置错误立即崩) 不再重试.
    @MainActor
    private static func tryConnectQmp(
        socketPath: String,
        runner: QemuProcessRunner,
        deadlineSec: Int
    ) async -> QmpClient? {
        let deadline = Date().addingTimeInterval(TimeInterval(deadlineSec))
        while Date() < deadline {
            switch runner.state {
            case .exited, .crashed: return nil
            default: break
            }
            if !FileManager.default.fileExists(atPath: socketPath) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            let c = QmpClient(socketPath: socketPath)
            do {
                try await c.connect()
                return c
            } catch {
                c.close()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return nil
    }
}

// MARK: - QemuHostState

/// QEMU host 进程的全局状态. 仅在 @MainActor 访问.
@MainActor
final class QemuHostState {
    static let shared = QemuHostState()

    var config: VMConfig?
    var bundleURL: URL?
    var runner: QemuProcessRunner?
    var qmpClient: QmpClient?
    var qmpSocketURL: URL?
    var lock: BundleLock?
    var ipcServer: SocketServer?
    var startedAt: Date?

    var statusItem: NSStatusItem?
    var statusMenu: QemuStatusMenuController?

    /// 安装 menu bar 图标 + Stop/Kill/Quit 菜单 (与 VZ HostState 形态一致)
    func installStatusItem(displayName: String) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "shippingbox.fill",
                                 accessibilityDescription: "HVM QEMU VM running") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "HVM"
            }
        }
        let controller = QemuStatusMenuController()
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "HVM · \(displayName) (qemu)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let stopItem = NSMenuItem(title: "Stop (ACPI)",
                                  action: #selector(QemuStatusMenuController.stopAction),
                                  keyEquivalent: "")
        stopItem.target = controller
        menu.addItem(stopItem)

        let killItem = NSMenuItem(title: "Kill (Force)",
                                  action: #selector(QemuStatusMenuController.killAction),
                                  keyEquivalent: "")
        killItem.target = controller
        menu.addItem(killItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit HVM Host",
                                  action: #selector(QemuStatusMenuController.quitAction),
                                  keyEquivalent: "q")
        quitItem.target = controller
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
        self.statusMenu = controller
    }

    /// IPC 请求分派. status / stop / kill / pause / resume 走 QMP / runner;
    /// dbg.* QEMU 后端一期不支持, 返回 ipc.unknown_op.
    func handle(_ req: IPCRequest) async -> IPCResponse {
        guard let runner else {
            return .failure(id: req.id, code: "backend.no_vm", message: "QEMU runner 未初始化")
        }

        switch req.op {
        case IPCOp.status.rawValue:
            return await handleStatus(req: req, runner: runner)

        case IPCOp.stop.rawValue:
            // ACPI shutdown via QMP system_powerdown
            guard let client = qmpClient else {
                return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
            }
            do {
                try await client.systemPowerdown()
                return .success(id: req.id)
            } catch {
                return .failure(id: req.id, code: "backend.qmp_error", message: "\(error)")
            }

        case IPCOp.kill.rawValue:
            runner.forceKill()
            return .success(id: req.id)

        case IPCOp.pause.rawValue:
            guard let client = qmpClient else {
                return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
            }
            do {
                try await client.stop()
                return .success(id: req.id)
            } catch {
                return .failure(id: req.id, code: "backend.qmp_error", message: "\(error)")
            }

        case IPCOp.resume.rawValue:
            guard let client = qmpClient else {
                return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
            }
            do {
                try await client.cont()
                return .success(id: req.id)
            } catch {
                return .failure(id: req.id, code: "backend.qmp_error", message: "\(error)")
            }

        default:
            // dbg.* 一期不支持: VZ 的 DbgOps 依赖 VZ frame buffer / VZ key injection,
            // QEMU 端等价物 (screendump / human-monitor-command) 留给后续 commit
            if req.op.hasPrefix("dbg.") {
                return .failure(id: req.id, code: "backend.qemu_dbg_unsupported",
                                message: "QEMU 后端暂未实现 dbg.* 命令; 用 hvm-dbg qemu-launch 直跑可看 cocoa 窗口")
            }
            return .failure(id: req.id, code: "ipc.unknown_op", message: "未知 op: \(req.op)")
        }
    }

    private func handleStatus(req: IPCRequest, runner: QemuProcessRunner) async -> IPCResponse {
        guard let config else {
            return .failure(id: req.id, code: "backend.no_vm", message: "config 未注入")
        }
        // 优先用 QMP query-status; QMP 未就绪或失败时回退到进程 state
        var stateString = "starting"
        if let client = qmpClient {
            if let qstat = try? await client.queryStatus() {
                stateString = qstat.status   // running / paused / shutdown / ...
            } else {
                stateString = qemuRunnerStateString(runner.state)
            }
        } else {
            stateString = qemuRunnerStateString(runner.state)
        }

        let payload = IPCStatusPayload(
            state: stateString,
            id: config.id.uuidString,
            bundlePath: bundleURL?.path ?? "",
            displayName: config.displayName,
            guestOS: config.guestOS.rawValue,
            cpuCount: config.cpuCount,
            memoryMiB: config.memoryMiB,
            pid: getpid(),
            startedAt: startedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(id: req.id, code: "ipc.encode_failed", message: "响应编码失败")
        }
        return .success(id: req.id, data: ["payload": json])
    }

    private func qemuRunnerStateString(_ s: QemuProcessRunner.State) -> String {
        switch s {
        case .idle:    return "starting"
        case .running: return "running"
        case .exited:  return "stopped"
        case .crashed(let signal): return "error:signal-\(signal)"
        }
    }

    /// 关闭 IPC server / QMP / 进程; 释放 lock; 清 socket; 退主进程
    func tearDown(exitCode: Int32) {
        ipcServer?.stop()
        qmpClient?.close()
        runner?.waitUntilExit()
        if let qmpSocketURL {
            try? FileManager.default.removeItem(at: qmpSocketURL)
        }
        lock?.release()
        exit(exitCode)
    }
}

/// menu bar 菜单 action 接收方 (QEMU 后端版).
@MainActor
final class QemuStatusMenuController: NSObject {
    @objc func stopAction() {
        Task { @MainActor in
            do {
                try await QemuHostState.shared.qmpClient?.systemPowerdown()
            } catch {
                NSLog("HVMHost(qemu): system_powerdown 失败 \(error)")
            }
        }
    }

    @objc func killAction() {
        QemuHostState.shared.runner?.forceKill()
    }

    @objc func quitAction() {
        QemuHostState.shared.runner?.forceKill()
        QemuHostState.shared.tearDown(exitCode: 0)
    }
}
