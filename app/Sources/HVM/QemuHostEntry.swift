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
import HVMDisplay
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

        // 3. swtpm sidecar (windows + tpmEnabled). 必须在 QEMU 启动前 listen, 否则 QEMU 连不上.
        // helper 失败路径直接 exit() (内部已 release lock); 成功返非 nil tuple.
        var swtpmSockPath: String? = nil
        var swtpmRunner: SwtpmRunner? = nil
        if config.guestOS == .windows, config.windows?.tpmEnabled == true {
            let (path, runner) = startSwtpmSidecar(config: config, bundleURL: bundleURL, lock: lock)
            swtpmSockPath = path
            swtpmRunner = runner
        }

        // 3.5 socket_vmnet sidecar (任一 networks[i].mode == .bridged 时).
        // 一期: 仅起一个 socket_vmnet, 第一个 bridged 接入它; 多 bridged 网络后续支持.
        // sudoers NOPASSWD 未配则 helper 内 fputs + exit.
        var socketVmnetPath: String? = nil
        var socketVmnetRunner: SocketVmnetRunner? = nil
        if let firstBridged = config.networks.first(where: {
            if case .bridged = $0.mode { return true } else { return false }
        }) {
            if case .bridged(let iface) = firstBridged.mode {
                let (path, runner) = startSocketVmnetSidecar(
                    config: config, bundleURL: bundleURL,
                    lock: lock, swtpmRunner: swtpmRunner,
                    bridgedInterface: iface
                )
                socketVmnetPath = path
                socketVmnetRunner = runner
            }
        }

        // 3.6 console socket 路径 (与 QMP / vmnet socket 同 runDir).
        // QemuConsoleBridge 在 QEMU 启动后 connect (见 6c).
        let consoleSocketURL = HVMPaths.runDir
            .appendingPathComponent("\(config.id.uuidString.lowercased()).console.sock")
        try? FileManager.default.removeItem(at: consoleSocketURL)

        // 4. 构造 argv
        let args: [String]
        do {
            let inputs = QemuArgsBuilder.Inputs(
                config: config, bundleURL: bundleURL,
                qemuRoot: qemuRoot, qmpSocketPath: qmpSocketURL.path,
                virtioWinISOPath: virtioWinPath,
                swtpmSocketPath: swtpmSockPath,
                socketVmnetPath: socketVmnetPath,
                consoleSocketPath: consoleSocketURL.path
            )
            args = try QemuArgsBuilder.build(inputs)
        } catch {
            fputs("HVMHost(qemu): argv 构造失败: \(error)\n", stderr)
            swtpmRunner?.terminate()
            socketVmnetRunner?.forceKill()
            lock.release()
            exit(21)
        }
        QemuHostState.shared.swtpmRunner = swtpmRunner
        QemuHostState.shared.swtpmSocketPath = swtpmSockPath
        QemuHostState.shared.socketVmnetRunner = socketVmnetRunner
        QemuHostState.shared.socketVmnetSocketPath = socketVmnetPath
        QemuHostState.shared.consoleSocketURL = consoleSocketURL

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

            // 6.5 console bridge: poll-wait socket 文件 + connect; 失败仅警告, 不阻塞 VM 启动
            let bridge = QemuConsoleBridge(
                socketPath: consoleSocketURL.path,
                logsDir: BundleLayout.logsDir(bundleURL)
            )
            // QEMU 监听 console socket 几乎跟 QMP 同时就绪; 仍 poll 5s 防 race
            let consDeadline = Date().addingTimeInterval(5)
            var connected = false
            while Date() < consDeadline {
                if FileManager.default.fileExists(atPath: consoleSocketURL.path) {
                    do {
                        try bridge.connect()
                        connected = true
                        break
                    } catch {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            if connected {
                QemuHostState.shared.consoleBridge = bridge
                fputs("HVMHost(qemu): console bridge 已连接\n", stderr)
            } else {
                fputs("HVMHost(qemu): ⚠ console bridge 5s 未连上, dbg.console.* 不可用\n", stderr)
            }

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

    /// 启动 swtpm sidecar (Win11 TPM 2.0 必需). 失败路径自身 cleanup + exit (Never).
    /// 成功返 (socket path, runner) 供 QemuArgsBuilder + tearDown 使用.
    @MainActor
    private static func startSwtpmSidecar(
        config: VMConfig,
        bundleURL: URL,
        lock: BundleLock
    ) -> (String, SwtpmRunner) {
        // 1. 定位 swtpm 二进制
        let swtpmBin: URL
        do {
            swtpmBin = try SwtpmPaths.locate()
        } catch {
            fputs("HVMHost(qemu): ✗ swtpm 未找到: \(error)\n", stderr)
            fputs("  Win11 装机需要 TPM 2.0 模拟. 解决方案:\n", stderr)
            fputs("    a) 重新 make qemu (会从 Homebrew 复制 swtpm 入包)\n", stderr)
            fputs("    b) brew install swtpm (临时降级方案)\n", stderr)
            lock.release()
            exit(30)
        }

        // 2. 路径准备: state dir 持久 / socket+log+pid 运行时
        let stateDir = BundleLayout.tpmStateDir(bundleURL)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let sockPath = HVMPaths.runDir
            .appendingPathComponent("\(config.id.uuidString.lowercased()).swtpm.sock").path
        let pidPath = HVMPaths.runDir
            .appendingPathComponent("\(config.id.uuidString.lowercased()).swtpm.pid")
        let logFile = BundleLayout.logsDir(bundleURL).appendingPathComponent("swtpm.log")
        // 清残留 socket / pid (上次崩溃留的会让 swtpm bind 失败 / 误以为已在跑)
        try? FileManager.default.removeItem(atPath: sockPath)
        try? FileManager.default.removeItem(at: pidPath)

        // 3. 构造 argv + 启动
        let swtpmArgs = SwtpmArgsBuilder.build(SwtpmArgsBuilder.Inputs(
            stateDir: stateDir,
            ctrlSocketPath: sockPath,
            logFile: logFile,
            pidFile: pidPath
        ))
        let stderrLog = BundleLayout.logsDir(bundleURL).appendingPathComponent("swtpm-stderr.log")
        try? FileManager.default.removeItem(at: stderrLog)
        let runner = SwtpmRunner(binary: swtpmBin, args: swtpmArgs,
                                 ctrlSocketPath: sockPath, stderrLog: stderrLog)
        do {
            try runner.start()
        } catch {
            fputs("HVMHost(qemu): ✗ swtpm 启动失败: \(error)\n", stderr)
            lock.release()
            exit(31)
        }

        // 4. 阻塞等 socket 文件就绪 (swtpm 通常 <500ms; QEMU 比 swtpm 早连会 ECONNREFUSED).
        //    主动 poll, 最多 5s; 若 swtpm 早退也立即报错.
        let deadline = Date().addingTimeInterval(5)
        var ready = false
        while Date() < deadline {
            switch runner.state {
            case .exited, .crashed:
                fputs("HVMHost(qemu): ✗ swtpm 启动后立即退出 state=\(runner.state)\n", stderr)
                fputs("  详见 \(stderrLog.path) 与 \(logFile.path)\n", stderr)
                lock.release()
                exit(32)
            default: break
            }
            if FileManager.default.fileExists(atPath: sockPath) {
                ready = true
                break
            }
            usleep(100_000)
        }
        if !ready {
            fputs("HVMHost(qemu): ✗ swtpm socket 5s 未就绪\n", stderr)
            runner.forceKill()
            runner.waitUntilExit()
            lock.release()
            exit(33)
        }
        fputs("HVMHost(qemu): swtpm 已就绪 sock=\(sockPath)\n", stderr)
        return (sockPath, runner)
    }

    /// 启动 socket_vmnet sidecar (vmnet bridged/shared/host 走非 root 桥接).
    /// sudo -n 拉起; sudoers NOPASSWD 未配则 sudo 立即非 0 退, helper 内打详细诊断 + exit.
    /// 失败路径自身 cleanup (含先启的 swtpm) + exit (Never).
    @MainActor
    private static func startSocketVmnetSidecar(
        config: VMConfig,
        bundleURL: URL,
        lock: BundleLock,
        swtpmRunner: SwtpmRunner?,
        bridgedInterface: String
    ) -> (String, SocketVmnetRunner) {
        // 1. 定位
        let bin: URL
        do {
            bin = try SocketVmnetPaths.locate()
        } catch {
            fputs("HVMHost(qemu): ✗ socket_vmnet 未找到: \(error)\n", stderr)
            fputs("  bridged 网络需要 socket_vmnet. 解决:\n", stderr)
            fputs("    a) make qemu (会从 Homebrew 复制 socket_vmnet 入包)\n", stderr)
            fputs("    b) brew install socket_vmnet (临时降级)\n", stderr)
            swtpmRunner?.terminate()
            lock.release()
            exit(40)
        }

        // 2. 路径准备
        let sockPath = HVMPaths.runDir
            .appendingPathComponent("\(config.id.uuidString.lowercased()).vmnet.sock").path
        let pidPath = HVMPaths.runDir
            .appendingPathComponent("\(config.id.uuidString.lowercased()).vmnet.pid")
        try? FileManager.default.removeItem(atPath: sockPath)
        try? FileManager.default.removeItem(at: pidPath)

        // 3. argv 构造
        let argsList: [String]
        do {
            argsList = try SocketVmnetArgsBuilder.build(SocketVmnetArgsBuilder.Inputs(
                mode: .bridged,
                socketPath: sockPath,
                pidFile: pidPath,
                bridgedInterface: bridgedInterface
            ))
        } catch {
            fputs("HVMHost(qemu): ✗ socket_vmnet argv 构造失败: \(error)\n", stderr)
            swtpmRunner?.terminate()
            lock.release()
            exit(41)
        }

        // 4. 启动
        let stderrLog = BundleLayout.logsDir(bundleURL).appendingPathComponent("socket_vmnet-stderr.log")
        try? FileManager.default.removeItem(at: stderrLog)
        let runner = SocketVmnetRunner(binary: bin, args: argsList,
                                       socketPath: sockPath, stderrLog: stderrLog)
        do {
            try runner.start()
        } catch {
            fputs("HVMHost(qemu): ✗ socket_vmnet 启动失败: \(error)\n", stderr)
            swtpmRunner?.terminate()
            lock.release()
            exit(42)
        }

        // 5. 阻塞等 socket 就绪 (5s; sudo 失败会让 runner 立即 exited 非 0)
        let deadline = Date().addingTimeInterval(5)
        var ready = false
        while Date() < deadline {
            switch runner.state {
            case .exited(let code):
                fputs("HVMHost(qemu): ✗ socket_vmnet 启动后立即退出 exit=\(code)\n", stderr)
                if code == 1 {
                    fputs("  常见原因: sudoers NOPASSWD 未配置. 跑一次 scripts/install-vmnet-helper.sh\n", stderr)
                }
                fputs("  详见 \(stderrLog.path)\n", stderr)
                swtpmRunner?.terminate()
                lock.release()
                exit(43)
            case .crashed(let signal):
                fputs("HVMHost(qemu): ✗ socket_vmnet 被信号杀 signal=\(signal)\n", stderr)
                swtpmRunner?.terminate()
                lock.release()
                exit(44)
            default: break
            }
            if FileManager.default.fileExists(atPath: sockPath) {
                ready = true
                break
            }
            usleep(100_000)
        }
        if !ready {
            fputs("HVMHost(qemu): ✗ socket_vmnet socket 5s 未就绪\n", stderr)
            runner.forceKill()
            swtpmRunner?.terminate()
            lock.release()
            exit(45)
        }
        fputs("HVMHost(qemu): socket_vmnet 已就绪 sock=\(sockPath) iface=\(bridgedInterface)\n", stderr)
        return (sockPath, runner)
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
    /// swtpm sidecar (仅 windows + tpmEnabled). nil 表示无 TPM
    var swtpmRunner: SwtpmRunner?
    var swtpmSocketPath: String?
    /// socket_vmnet sidecar (任一 networks[i].mode == .bridged 时). nil 表示纯 NAT
    var socketVmnetRunner: SocketVmnetRunner?
    var socketVmnetSocketPath: String?
    /// dbg.status 用: 最近一次截图的 sha256 (用于客户端做"画面变没变"轮询)
    var lastFrameSha256: String?
    /// guest serial console 桥接 (-chardev socket); console.read/write 走它
    var consoleBridge: QemuConsoleBridge?
    var consoleSocketURL: URL?

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

        case IPCOp.dbgScreenshot.rawValue: return await handleDbgScreenshot(req: req)
        case IPCOp.dbgStatus.rawValue:     return handleDbgStatus(req: req)
        case IPCOp.dbgOcr.rawValue:        return await handleDbgOcr(req: req)
        case IPCOp.dbgFindText.rawValue:   return await handleDbgFindText(req: req)
        case IPCOp.dbgKey.rawValue:           return await handleDbgKey(req: req)
        case IPCOp.dbgMouse.rawValue:         return await handleDbgMouse(req: req)
        case IPCOp.dbgBootProgress.rawValue:  return await handleDbgBootProgress(req: req)
        case IPCOp.dbgConsoleRead.rawValue:   return handleDbgConsoleRead(req: req)
        case IPCOp.dbgConsoleWrite.rawValue:  return handleDbgConsoleWrite(req: req)

        default:
            if req.op.hasPrefix("dbg.") {
                return .failure(id: req.id, code: "backend.qemu_dbg_unsupported",
                                message: "QEMU 后端尚未实现 \(req.op)")
            }
            return .failure(id: req.id, code: "ipc.unknown_op", message: "未知 op: \(req.op)")
        }
    }

    // MARK: - dbg.* 处理 (E4a)

    private func handleDbgScreenshot(req: IPCRequest) async -> IPCResponse {
        guard let client = qmpClient else {
            return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
        }
        do {
            // maxEdge=1568 与 VZ 路径一致 (Anthropic many-image 上限)
            let shot = try await QemuScreenshot.capture(
                via: client,
                tempDir: HVMPaths.runDir,
                maxEdge: 1568
            )
            lastFrameSha256 = shot.sha256
            let payload = IPCDbgScreenshotPayload(
                pngBase64: shot.pngData.base64EncodedString(),
                widthPx: shot.widthPx,
                heightPx: shot.heightPx,
                sha256: shot.sha256
            )
            guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "screenshot payload 编码失败")
            }
            return .success(id: req.id, data: ["payload": json])
        } catch {
            return .failure(id: req.id, code: "dbg.frame_unavailable", message: "\(error)")
        }
    }

    private func handleDbgStatus(req: IPCRequest) -> IPCResponse {
        // QEMU 端 framebuffer 尺寸: 当前 cocoa 自带窗口, 没有简单 API 取实时尺寸;
        // 用 guestOS 估算 (走 GuestOSType.defaultFramebufferSize, 与 VZ DbgOps 一致)
        let (gw, gh): (Int, Int)
        if let os = config?.guestOS {
            let s = os.defaultFramebufferSize; (gw, gh) = (s.width, s.height)
        } else { (gw, gh) = (0, 0) }
        let stateString: String
        if case .running = runner?.state { stateString = "running" } else { stateString = "starting" }
        let payload = IPCDbgStatusPayload(
            state: stateString,
            guestWidthPx: gw,
            guestHeightPx: gh,
            lastFrameSha256: lastFrameSha256,
            consoleAgentOnline: false  // QEMU console 通道一期未接入
        )
        guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
            return .failure(id: req.id, code: "ipc.encode_failed", message: "dbg status payload 编码失败")
        }
        return .success(id: req.id, data: ["payload": json])
    }

    private func handleDbgOcr(req: IPCRequest) async -> IPCResponse {
        guard let client = qmpClient else {
            return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
        }
        // OCR 不缩放, 保留原分辨率以维持识别精度 (与 VZ DbgOps.handleOcr 一致)
        let shot: QemuScreenshot.Result
        do {
            shot = try await QemuScreenshot.capture(via: client, tempDir: HVMPaths.runDir, maxEdge: nil)
        } catch {
            return .failure(id: req.id, code: "dbg.frame_unavailable", message: "\(error)")
        }
        lastFrameSha256 = shot.sha256

        var region: CGRect? = nil
        if let xs = req.args["x"], let ys = req.args["y"],
           let ws = req.args["w"], let hs = req.args["h"],
           let x = Double(xs), let y = Double(ys),
           let w = Double(ws), let h = Double(hs) {
            region = CGRect(x: x, y: y, width: w, height: h)
        }
        do {
            let items = try OCREngine.recognize(pngData: shot.pngData, region: region)
            let payload = IPCDbgOcrPayload(
                widthPx: shot.widthPx,
                heightPx: shot.heightPx,
                texts: items.map { IPCDbgOcrPayload.Item(
                    x: $0.x, y: $0.y, width: $0.width, height: $0.height,
                    text: $0.text, confidence: $0.confidence
                ) }
            )
            guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "ocr payload 编码失败")
            }
            return .success(id: req.id, data: ["payload": json])
        } catch let e as HVMError {
            let uf = e.userFacing
            return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
        } catch {
            return .failure(id: req.id, code: "backend.qmp_error", message: "\(error)")
        }
    }

    private func handleDbgKey(req: IPCRequest) async -> IPCResponse {
        guard let client = qmpClient else {
            return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
        }
        // 只接受 running (paused 时 send-key 也行但 guest 不消化, 行为不可预测)
        if case .running = runner?.state {} else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "QEMU 进程未运行")
        }
        do {
            if let text = req.args["text"] {
                try await QemuInput.typeText(text, via: client)
            } else if let press = req.args["press"] {
                try await QemuInput.pressCombo(press, via: client)
            } else {
                return .failure(id: req.id, code: "config.missing_field",
                                message: "需要 args.text 或 args.press")
            }
            return .success(id: req.id)
        } catch let QemuInput.InputError.unknownKey(k) {
            return .failure(id: req.id, code: "config.invalid_enum",
                            message: "未识别按键 / 字符: \(k)")
        } catch {
            return .failure(id: req.id, code: "backend.qmp_error", message: "\(error)")
        }
    }

    private func handleDbgMouse(req: IPCRequest) async -> IPCResponse {
        guard let client = qmpClient else {
            return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
        }
        if case .running = runner?.state {} else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "QEMU 进程未运行")
        }
        // guest framebuffer 尺寸 (与 dbgStatus 同, 估算)
        let (gw, gh): (Int, Int)
        if let os = config?.guestOS {
            let s = os.defaultFramebufferSize; (gw, gh) = (s.width, s.height)
        } else { (gw, gh) = (1, 1) }
        let guestSize = CGSize(width: gw, height: gh)
        let button = req.args["button"] ?? "left"
        do {
            switch req.args["op"] ?? "" {
            case "move":
                let (x, y) = try parseXY(req)
                try await QemuInput.mouseMove(x: x, y: y, guestSize: guestSize, via: client)
            case "click":
                let (x, y) = try parseXY(req)
                try await QemuInput.mouseClick(x: x, y: y, button: button, guestSize: guestSize, via: client)
            case "double-click":
                let (x, y) = try parseXY(req)
                try await QemuInput.mouseDoubleClick(x: x, y: y, button: button, guestSize: guestSize, via: client)
            default:
                return .failure(id: req.id, code: "config.invalid_enum",
                                message: "args.op 应为 move / click / double-click")
            }
            return .success(id: req.id)
        } catch let QemuInput.InputError.invalidPoint(reason) {
            return .failure(id: req.id, code: "config.invalid_range", message: reason)
        } catch let QemuInput.InputError.unsupportedButton(b) {
            return .failure(id: req.id, code: "config.invalid_enum",
                            message: "button 必须是 left/right/middle, 实际 \(b)")
        } catch {
            return .failure(id: req.id, code: "backend.qmp_error", message: "\(error)")
        }
    }

    /// args.x / args.y 解析 (字符串 → Int). 缺/格式错抛 invalidPoint.
    private func parseXY(_ req: IPCRequest) throws -> (Int, Int) {
        guard let xs = req.args["x"], let ys = req.args["y"],
              let x = Int(xs), let y = Int(ys) else {
            throw QemuInput.InputError.invalidPoint(reason: "args.x / args.y 必须是整数")
        }
        return (x, y)
    }

    // MARK: - dbg.boot_progress / console.* (F 系列)

    /// boot_progress: state + 截屏 + OCR 启发式. 与 VZ DbgOps.handleBootProgress 同算法.
    private func handleDbgBootProgress(req: IPCRequest) async -> IPCResponse {
        let elapsed: Int? = startedAt.map { Int(Date().timeIntervalSince($0)) }
        func reply(_ phase: String, _ confidence: Float) -> IPCResponse {
            let payload = IPCDbgBootProgressPayload(phase: phase, confidence: confidence, elapsedSec: elapsed)
            guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "boot_progress 编码失败")
            }
            return .success(id: req.id, data: ["payload": json])
        }

        // 进程未 running → bios
        if case .running = runner?.state {} else { return reply("bios", 1.0) }

        // 截屏不到 → BIOS / EFI 阶段
        guard let client = qmpClient else { return reply("bios", 0.7) }
        let shot: QemuScreenshot.Result
        do {
            shot = try await QemuScreenshot.capture(via: client, tempDir: HVMPaths.runDir, maxEdge: nil)
        } catch {
            return reply("bios", 0.7)
        }
        lastFrameSha256 = shot.sha256

        let items: [OCREngine.TextItem]
        do { items = try OCREngine.recognize(pngData: shot.pngData, region: nil) }
        catch { return reply("boot-logo", 0.5) }
        guard let os = config?.guestOS else { return reply("unknown", 0.0) }
        let cls = BootPhaseClassifier.classify(items: items, guestOS: os)
        return reply(cls.phase, cls.confidence)
    }

    private func handleDbgConsoleRead(req: IPCRequest) -> IPCResponse {
        guard let bridge = consoleBridge else {
            return .failure(id: req.id, code: "dbg.console_unavailable",
                            message: "console bridge 未就绪 (QEMU console socket 连接失败?)")
        }
        let since = Int(req.args["sinceBytes"] ?? "0") ?? 0
        let r = bridge.read(sinceBytes: since)
        let payload = IPCDbgConsoleReadPayload(
            dataBase64: r.data.base64EncodedString(),
            totalBytes: r.totalBytes,
            returnedSinceBytes: r.returnedSinceBytes
        )
        guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
            return .failure(id: req.id, code: "ipc.encode_failed", message: "console.read payload 编码失败")
        }
        return .success(id: req.id, data: ["payload": json])
    }

    private func handleDbgConsoleWrite(req: IPCRequest) -> IPCResponse {
        guard let bridge = consoleBridge else {
            return .failure(id: req.id, code: "dbg.console_unavailable",
                            message: "console bridge 未就绪")
        }
        let bytes: Data
        if let b64 = req.args["dataBase64"], let d = Data(base64Encoded: b64) {
            bytes = d
        } else if let text = req.args["text"] {
            bytes = Data(text.utf8)
        } else {
            return .failure(id: req.id, code: "config.missing_field",
                            message: "需要 args.dataBase64 或 args.text")
        }
        do {
            try bridge.write(bytes)
            return .success(id: req.id)
        } catch {
            return .failure(id: req.id, code: "dbg.console_write_failed", message: "\(error)")
        }
    }

    private func handleDbgFindText(req: IPCRequest) async -> IPCResponse {
        guard let query = req.args["query"], !query.isEmpty else {
            return .failure(id: req.id, code: "config.missing_field", message: "需要 args.query")
        }
        guard let client = qmpClient else {
            return .failure(id: req.id, code: "backend.qmp_unavailable", message: "QMP 未就绪")
        }
        let shot: QemuScreenshot.Result
        do {
            shot = try await QemuScreenshot.capture(via: client, tempDir: HVMPaths.runDir, maxEdge: nil)
        } catch {
            return .failure(id: req.id, code: "dbg.frame_unavailable", message: "\(error)")
        }
        lastFrameSha256 = shot.sha256
        do {
            let items = try OCREngine.recognize(pngData: shot.pngData, region: nil)
            let payload: IPCDbgFindTextPayload
            if let hit = OCRTextSearch.find(in: items, query: query) {
                let it = hit.item
                payload = IPCDbgFindTextPayload(
                    match: true,
                    x: it.x, y: it.y, width: it.width, height: it.height,
                    centerX: it.x + it.width / 2, centerY: it.y + it.height / 2,
                    text: it.text, confidence: it.confidence
                )
            } else {
                payload = IPCDbgFindTextPayload(match: false)
            }
            guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "find_text payload 编码失败")
            }
            return .success(id: req.id, data: ["payload": json])
        } catch let e as HVMError {
            let uf = e.userFacing
            return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
        } catch {
            return .failure(id: req.id, code: "backend.qmp_error", message: "\(error)")
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
        // swtpm 因 --terminate 通常已自动退; 保险再终止 + 等
        if let s = swtpmRunner {
            s.terminate()
            s.waitUntilExit()
        }
        // socket_vmnet 不会自动退 (没 --terminate equivalent), 主动 SIGTERM + 等
        if let v = socketVmnetRunner {
            v.terminate()
            v.waitUntilExit()
        }
        if let qmpSocketURL {
            try? FileManager.default.removeItem(at: qmpSocketURL)
        }
        if let p = swtpmSocketPath {
            try? FileManager.default.removeItem(atPath: p)
        }
        if let p = socketVmnetSocketPath {
            try? FileManager.default.removeItem(atPath: p)
        }
        consoleBridge?.close()
        if let u = consoleSocketURL {
            try? FileManager.default.removeItem(at: u)
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
