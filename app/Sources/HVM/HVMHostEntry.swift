// HVMHostEntry.swift
// VMHost 进程的启动入口 (--host-mode-bundle 分支). 在 main.swift 通过 argv 分派后调用.
//
// 真无头方案:
//   - NSApplication.shared + activationPolicy=.accessory
//     → 不进 Dock / Cmd+Tab, 但允许 NSStatusItem 在右上角 menu bar 显示图标
//       让 user 知道有 VM 在跑, 右键菜单可 Stop / Kill / Quit
//   - 创建一个离屏 NSWindow (位置 -20000, -20000), 把 HVMView 挂上去
//     → VZ 要求 view 必须 attach 到 window 才能创建 Metal drawable; 离屏仍被 Window
//       Server 合成, CGWindowListCreateImage 能抓到画面
//   - HVMView.inject 路径接受所有 hvm-dbg 注入的 NSEvent, 不依赖 first responder
//     和 GUI 焦点
//   - 复用 DbgOps 处理 dbg.screenshot / key / mouse / ocr / find-text / status
//
// 职责:
//   1. 解析 bundle 路径, 抢 BundleLock (runtime 模式)
//   2. 加载 VMConfig, 起 VM
//   3. 起 IPC SocketServer, 监听 status / stop / kill / dbg.*
//   4. NSApp.run() 驻留, 直到 VM 结束并退出

import AppKit
import Foundation
@preconcurrency import Virtualization
import HVMBackend
import HVMBundle
import HVMCore
import HVMDisplay
import HVMEncryption
import HVMIPC

public enum HVMHostEntry {
    @MainActor
    public static func run(bundlePath: String,
                           password: String? = nil,
                           embeddedInGUI: Bool = false) -> Never {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        // 0. 加密形态检测 (不解密, 仅看 routing JSON / sparsebundle 后缀)
        let encryptionScheme = EncryptedBundleIO.detectScheme(at: bundleURL)

        // 1. 载入 config + 解锁 (按加密形态分流)
        let config: VMConfig
        let unlocked: EncryptedBundleIO.UnlockedHandle?

        switch encryptionScheme {
        case .none:
            // 明文 VM
            unlocked = nil
            do {
                config = try BundleIO.load(from: bundleURL)
            } catch {
                fputs("HVMHost: 加载 bundle 失败: \(error)\n", stderr)
                exit(3)
            }

        case .qemuPerfile:
            // 加密 QEMU VM: 必须有 password
            guard let pw = password, !pw.isEmpty else {
                fputs("HVMHost: 加密 VM 需要密码 (stdin 读到空); hvm-cli / GUI 应已 prompt\n", stderr)
                exit(40)
            }
            do {
                let handle = try EncryptedBundleIO.unlock(bundlePath: bundleURL, password: pw)
                unlocked = handle
                config = handle.config
            } catch let e as HVMError {
                fputs("HVMHost: 加密 VM 解锁失败: \(e.userFacing.message) (\(e.userFacing.code))\n", stderr)
                if case .encryption(.wrongPassword) = e {
                    exit(41)   // 密码错
                }
                exit(42)
            } catch {
                fputs("HVMHost: 加密 VM 解锁失败: \(error)\n", stderr)
                exit(42)
            }

        case .vzSparsebundle:
            // VZ 加密接入推后 (v2.4 用户决策); 即使 sparsebundle 存在也不允许直接启动
            fputs("HVMHost: VZ 加密 VM 启动接入暂未实现 (docs/v3/ENCRYPTION.md v2.4 决定 QEMU 优先);\n", stderr)
            fputs("  请等 VZ 接入 PR; 或用明文 VM 跑 macOS guest\n", stderr)
            exit(43)
        }

        // 2. 抢锁 (共用前置)
        let socketURL = HVMPaths.socketPath(for: config.id)
        do {
            try HVMPaths.ensure(HVMPaths.runDir)
        } catch {
            fputs("HVMHost: 创建 run 目录失败: \(error)\n", stderr)
            try? unlocked?.close()
            exit(1)
        }

        let lock: BundleLock
        do {
            lock = try BundleLock(bundleURL: bundleURL, mode: .runtime, socketPath: socketURL.path)
        } catch let e as HVMError {
            fputs("HVMHost: \(e.userFacing.message) (\(e.userFacing.code))\n", stderr)
            try? unlocked?.close()
            exit(4)
        } catch {
            fputs("HVMHost: 抢锁失败: \(error)\n", stderr)
            try? unlocked?.close()
            exit(4)
        }

        let startedAt = Date()

        // 3. 按 engine 分派
        switch config.engine {
        case .qemu:
            QemuHostEntry.run(
                config: config, bundleURL: bundleURL,
                lock: lock, socketURL: socketURL, startedAt: startedAt,
                embeddedInGUI: embeddedInGUI,
                encryptedHandle: unlocked
            )
        case .vz:
            // VZ 路径明文 VM (加密 VZ 已上面拦下)
            runVZ(
                config: config, bundleURL: bundleURL,
                lock: lock, socketURL: socketURL, startedAt: startedAt,
                embeddedInGUI: embeddedInGUI
            )
        }
    }

    /// VZ 后端流程. 调用方已完成 load/lock/dirs 共用前置.
    /// `embeddedInGUI=true`: GUI 主进程派生场景, 跳过 menu bar status item (GUI 主进程
    /// 已有, 避免重复图标). hvm-cli 起 host 时为 false, 装 status item 给用户控制入口.
    @MainActor
    private static func runVZ(
        config: VMConfig,
        bundleURL: URL,
        lock: BundleLock,
        socketURL: URL,
        startedAt: Date,
        embeddedInGUI: Bool
    ) -> Never {
        // 3. NSApplication 启动: accessory 策略 (menu bar 图标 + 离屏 window 给 VZ view)
        let app = NSApplication.shared
        // .accessory: 不进 Dock / Cmd+Tab, 但 NSStatusItem 可显示在右上角 menu bar.
        app.setActivationPolicy(.accessory)

        // 4. 在 MainActor 准备 view + window + VM + IPC
        Task { @MainActor in
            // 4a. 离屏 window + HVMView
            // 走 GuestOSType.defaultFramebufferSize (Linux=1024x768, macOS/Windows=1920x1080)
            let _fbSize = config.guestOS.defaultFramebufferSize
            let (w, h): (CGFloat, CGFloat) = (CGFloat(_fbSize.width), CGFloat(_fbSize.height))
            // 位置 -20000, -20000: 远离任何真实显示器, 但 isVisible=true 仍纳入 Window Server
            // 合成树, CGWindowListCreateImage 能抓到帧.
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: w, height: h),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.alphaValue = 1.0   // 必须 > 0 否则 Window Server 跳过合成
            window.level = .normal
            window.collectionBehavior = [.stationary, .ignoresCycle]

            let view = HVMView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            window.contentView = view
            // orderFront 但不 makeKeyAndOrderFront, 不抢键盘焦点 (也没 user 来抢, .prohibited 模式)
            window.orderFrontRegardless()

            HostState.shared.window = window
            HostState.shared.view = view

            // 4a-extra. menu bar 状态栏图标. accessory 模式核心入口, 让 user 知道有 VM 在跑.
            // GUI 派生场景跳过 — GUI 主进程自己有 status item, 避免重复图标.
            if !embeddedInGUI {
                HostState.shared.installStatusItem(displayName: config.displayName)
            }

            // 4b. 起 VM
            let handle = VMHandle(config: config, bundleURL: bundleURL)
            HostState.shared.vm = handle
            HostState.shared.startedAt = startedAt
            HostState.shared.dbgOps = DbgOps(
                view: view,
                guestOS: config.guestOS,
                displaySpec: config.effectiveDisplaySpec,
                stateProvider: { handle.state },
                startedAtProvider: { HostState.shared.startedAt },
                consoleBridgeProvider: { handle.consoleBridge }
            )

            do {
                try await handle.start()
            } catch let e as HVMError {
                fputs("HVMHost: 启动 VM 失败: \(e.userFacing.message) (\(e.userFacing.code))\n", stderr)
                lock.release()
                exit(10)
            } catch {
                fputs("HVMHost: 启动 VM 失败: \(error)\n", stderr)
                lock.release()
                exit(10)
            }

            // 4c. VM 起来后绑 view (VZ Metal drawable 要 view in window + virtualMachine 都齐)
            if let vm = handle.virtualMachine {
                view.virtualMachine = vm
            }

            // VM 结束 → 退进程
            handle.addStateObserver { newState in
                if case .stopped = newState {
                    DispatchQueue.main.async {
                        HostState.shared.ipcServer?.stop()
                        lock.release()
                        exit(0)
                    }
                }
                if case .error = newState {
                    DispatchQueue.main.async {
                        HostState.shared.ipcServer?.stop()
                        lock.release()
                        exit(11)
                    }
                }
            }

            // 4d. 起 IPC server
            let server = SocketServer(socketPath: socketURL)
            HostState.shared.ipcServer = server
            do {
                try server.start { req in
                    let box = ResponseBox(
                        .failure(id: req.id, code: "ipc.internal", message: "未初始化")
                    )
                    let sem = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        box.value = HostState.shared.handle(req)
                        sem.signal()
                    }
                    sem.wait()
                    return box.value
                }
            } catch let e as HVMError {
                fputs("HVMHost: IPC server 启动失败: \(e.userFacing.message)\n", stderr)
                lock.release()
                exit(12)
            } catch {
                fputs("HVMHost: IPC server 启动失败: \(error)\n", stderr)
                lock.release()
                exit(12)
            }

            fputs("HVMHost: VM \(config.displayName) 已启动 (pid=\(getpid()), 离屏 window \(Int(w))x\(Int(h)))\n", stderr)
        }

        // 5. NSApp.run() 驻留: 跑 main event loop, 不只是 RunLoop. 否则 NSWindow / Metal layer
        //    更新会有问题 (合成依赖 main event loop 的 CADisplayLink / vsync 触发).
        app.run()
        exit(0)
    }
}

/// 跨线程传递 IPCResponse 的可变容器 (Swift 6 sending 检查绕过)
final class ResponseBox: @unchecked Sendable {
    var value: IPCResponse
    init(_ v: IPCResponse) { self.value = v }
}

/// menu bar 图标的菜单 action 接收方. 必须 NSObject 子类才能被 NSMenuItem.target 引用.
@MainActor
final class HostStatusMenuController: NSObject {
    @objc func stopAction() {
        do {
            try HostState.shared.vm?.requestStop()
        } catch {
            NSLog("HVMHost: requestStop 失败 \(error)")
        }
    }

    @objc func killAction() {
        Task { @MainActor in
            try? await HostState.shared.vm?.forceStop()
        }
    }

    @objc func quitAction() {
        // 强制关 VM 然后退出. 不优雅, 但 user 主动选 Quit 时已默认接受数据风险.
        Task { @MainActor in
            try? await HostState.shared.vm?.forceStop()
            HostState.shared.ipcServer?.stop()
            exit(0)
        }
    }
}

/// VMHost 进程全局状态. 只在 @MainActor 访问
@MainActor
final class HostState {
    static let shared = HostState()
    var vm: VMHandle?
    var ipcServer: SocketServer?
    var startedAt: Date?
    var window: NSWindow?
    var view: HVMView?
    var dbgOps: DbgOps?
    var statusItem: NSStatusItem?
    var statusMenu: HostStatusMenuController?

    /// 创建右上角 menu bar 图标 + 菜单. accessory 模式的可见入口.
    /// 菜单里展示 VM 名 + Stop / Kill / Quit. 不放 Show 因为 headless 没主窗口.
    func installStatusItem(displayName: String) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "shippingbox.fill",
                                  accessibilityDescription: "HVM VM running") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "HVM"
            }
        }

        let controller = HostStatusMenuController()
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "HVM · \(displayName)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let stopItem = NSMenuItem(title: "Stop (ACPI)", action: #selector(HostStatusMenuController.stopAction), keyEquivalent: "")
        stopItem.target = controller
        menu.addItem(stopItem)

        let killItem = NSMenuItem(title: "Kill (Force)", action: #selector(HostStatusMenuController.killAction), keyEquivalent: "")
        killItem.target = controller
        menu.addItem(killItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit HVM Host", action: #selector(HostStatusMenuController.quitAction), keyEquivalent: "q")
        quitItem.target = controller
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
        self.statusMenu = controller
    }

    func handle(_ req: IPCRequest) -> IPCResponse {
        guard let vm = self.vm else {
            return .failure(id: req.id, code: "backend.no_vm", message: "VM 未运行")
        }

        switch req.op {
        case IPCOp.status.rawValue:
            let payload = IPCStatusPayload(
                state: stateString(vm.state),
                id: vm.id.uuidString,
                bundlePath: vm.bundleURL.path,
                displayName: vm.config.displayName,
                guestOS: vm.config.guestOS.rawValue,
                cpuCount: vm.config.cpuCount,
                memoryMiB: vm.config.memoryMiB,
                pid: getpid(),
                startedAt: startedAt
            )
            return .encoded(id: req.id, payload: payload, kind: "host status")

        case IPCOp.stop.rawValue:
            do {
                try vm.requestStop()
                return .success(id: req.id)
            } catch let e as HVMError {
                let uf = e.userFacing
                return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
            } catch {
                return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
            }

        case IPCOp.kill.rawValue:
            Task { @MainActor in
                try? await vm.forceStop()
            }
            return .success(id: req.id)

        case IPCOp.pause.rawValue:
            // VZ pause/resume 是 async, 用 Task 桥接 (CompletionHandler / async 都返回, 避开 IPC 阻塞)
            Task { @MainActor in try? await vm.pause() }
            return .success(id: req.id)

        case IPCOp.resume.rawValue:
            Task { @MainActor in try? await vm.resume() }
            return .success(id: req.id)

        default:
            // 把 dbg.* 都交给 DbgOps 处理 (与 GUI VMSession 共享同一份代码)
            if let resp = dbgOps?.tryHandle(req) {
                return resp
            }
            return .failure(id: req.id, code: "ipc.unknown_op",
                           message: "未知 op: \(req.op)")
        }
    }

    private func stateString(_ s: RunState) -> String {
        switch s {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .error(let msg): return "error:\(msg)"
        }
    }
}
