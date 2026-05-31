// TrayCoordinator.swift — 单一 tray 归属协调 (见 docs/TRAY_OWNERSHIP_DESIGN.md, 方案 A).
//
// 每个 VMHost (--host-mode-bundle) 进程跑一个 TrayCoordinator. 规则:
//   - GUI 在世 (持 gui-owner.lock) → 所有 VMHost 撤 tray, 只剩 GUI 那一个 tray.
//   - 无 GUI → 抢 tray-leader.lock 的那个 VMHost 显**一个聚合 tray** (列全部运行中 VM + 各自停/强停),
//     其余 VMHost 不显. leader 进程死 → flock 自动释放 → 存活者下一 tick 补位.
// 1.5s 轮询兜底 + DistributedNotificationCenter 即时唤醒 (gui 起落 / leader 让位).
//
// HVM_NO_TRAY=1 硬覆盖: 永不显 tray (headless / CI).

import AppKit
import Foundation
import HVMCore
import HVMControl

@MainActor
final class TrayCoordinator: NSObject {
    // DistributedNotificationCenter 通知名 (同用户跨进程). GUI 与 VMHost 共用.
    static let nGuiUp        = Notification.Name("com.hellmessage.hvm.gui.up")
    static let nGuiDown      = Notification.Name("com.hellmessage.hvm.gui.down")
    static let nLeaderReleased = Notification.Name("com.hellmessage.hvm.tray.leaderReleased")
    // 第二个 GUI 实例启动时发: 已在世的那个 GUI 收到 → 前置窗口, 新实例自退 (GUI 单例化).
    static let nGuiShowWindow = Notification.Name("com.hellmessage.hvm.gui.showWindow")

    private var timer: Timer?
    private var leaderLock: ProcessFileLock?
    private var statusItem: NSStatusItem?
    private let pollInterval: TimeInterval = 1.5

    private var noTray: Bool {
        ProcessInfo.processInfo.environment["HVM_NO_TRAY"] == "1"
    }

    /// 启动协调 (VMHost 主线程调一次).
    func start() {
        let dnc = DistributedNotificationCenter.default()
        for name in [Self.nGuiUp, Self.nGuiDown, Self.nLeaderReleased] {
            dnc.addObserver(self, selector: #selector(onSignal),
                            name: name, object: nil)
        }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = t
        tick()
    }

    @objc private func onSignal() {
        // DNC 回调在主线程 (我们注册时主 runloop), 即时跑一 tick 让接管/让位无可见延迟.
        tick()
    }

    /// 单次协调判定.
    private func tick() {
        if noTray {
            relinquish()
            return
        }
        // GUI 在世 → 让位
        if ProcessFileLock.isHeld(path: HVMPaths.guiOwnerLockPath) {
            relinquish()
            return
        }
        // 无 GUI → 争 leader
        if leaderLock == nil {
            leaderLock = ProcessFileLock(path: HVMPaths.trayLeaderLockPath)
        }
        if leaderLock != nil {
            showOrRefreshTray()
        } else {
            // 别的 VMHost 是 leader → 不显 (但保留轮询, 它死了我补位)
            removeStatusItem()
        }
    }

    /// 放弃 leadership + 撤 tray (GUI 出现 / noTray / 进程收尾).
    private func relinquish() {
        removeStatusItem()
        if leaderLock != nil {
            leaderLock?.release()
            leaderLock = nil
            // 通知存活的其它 VMHost 立刻重选 (避免短暂无 tray)
            DistributedNotificationCenter.default().postNotificationName(
                Self.nLeaderReleased, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        relinquish()
    }

    // MARK: - 聚合 tray 渲染

    private func showOrRefreshTray() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                if let img = NSImage(systemSymbolName: "shippingbox.fill",
                                     accessibilityDescription: "HVM") {
                    img.isTemplate = true
                    button.image = img
                } else {
                    button.title = "HVM"
                }
            }
            statusItem = item
        }
        statusItem?.menu = buildMenu()
    }

    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let running = VMCatalog.list().filter { $0.runState == .running }
        let menu = NSMenu()

        let header = NSMenuItem(title: "HVM — \(running.count) 台运行中", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for vm in running {
            let vmItem = NSMenuItem(title: vm.displayName, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let stop = NSMenuItem(title: "停止 (ACPI)", action: #selector(stopVM(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = vm.bundleURL.path
            sub.addItem(stop)
            let kill = NSMenuItem(title: "强制停止", action: #selector(killVM(_:)), keyEquivalent: "")
            kill.target = self
            kill.representedObject = vm.bundleURL.path
            sub.addItem(kill)
            vmItem.submenu = sub
            menu.addItem(vmItem)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开 HVM 主界面", action: #selector(openMainUI), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let stopAll = NSMenuItem(title: "停止所有 VM", action: #selector(stopAllVMs), keyEquivalent: "")
        stopAll.target = self
        menu.addItem(stopAll)
        return menu
    }

    // MARK: - 菜单动作 (经 IPC 跨进程控每台 VM)

    @objc private func stopVM(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async {
            try? VMControl.stop(bundleURL: url)
        }
    }

    @objc private func killVM(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async {
            try? VMControl.kill(bundleURL: url)
        }
    }

    @objc private func stopAllVMs() {
        let running = VMCatalog.list().filter { $0.runState == .running }
        DispatchQueue.global(qos: .userInitiated).async {
            for vm in running { try? VMControl.stop(bundleURL: vm.bundleURL) }
        }
    }

    @objc private func openMainUI() {
        // 拉起 GUI (同一 HVM.app, 无 --host-mode-bundle 即 GUI 模式). GUI 起后取 gui-owner.lock,
        // 本 leader 收到 gui.up / 下一 tick 让位.
        // VMHost 进程本身是 HVM.app 的实例, 普通 open 会被 LaunchServices 当"已在运行"只激活不新建 GUI;
        // createsNewApplicationInstance 强制起一个全新进程 (无 --host-mode-bundle 即 GUI 模式).
        // 若已有 GUI 在世, 新实例抢 gui-owner.lock 失败会自退并前置已有 GUI (NewGUIApp 单例逻辑).
        let appURL = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: nil)
    }
}
