// NewGUIStore.swift — 新 GUI 精简数据 store (业务页 #1, docs/v4/NEW_GUI_MAIN_LAYOUT.md M2)
//
// 不依赖老 AppModel — 直接调视图无关的 HVMControl 门面 (枚举/启停/删除). 不背
// embeddedID / detachedQemuVMs / VZ in-process session 等老 GUI 历史耦合.
// framebuffer 嵌入等强耦合留 NEW_GUI_FRAMEBUFFER.md 子稿.
//
// @Observable 细粒度: sidebar 读 vms+selectedID, detail 读 selected — 各自只在相关
// 字段变时重绘. 1Hz refresh 内 `if fresh != vms` 守卫 (VMSummary Equatable), 列表无
// 变化不赋值, 保 P0-2 帧率.

#if NEW_GUI

import Foundation
import Observation
import HVMControl
import HVMBundle
import HVMCore
import HVMEncryption

/// 动作失败时冒泡给 MainLayoutView → dialog.alert 的错误载体.
/// id 每次新建 (即便 message 相同) 让 .onChange 能识别"又出错了一次".
public struct StoreError: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let message: String
    public let hint: String?

    public init(title: String, message: String, hint: String? = nil) {
        self.id = UUID()
        self.title = title
        self.message = message
        self.hint = hint
    }
}

@MainActor
@Observable
public final class NewGUIStore {
    /// VM 列表 (VMCatalog.list 产物, displayName 升序)
    public private(set) var vms: [VMSummary] = []
    /// 选中 VM id (sidebar 点击 / detail 跟随)
    public var selectedID: UUID?
    /// 最近一次动作错误 (非 nil → MainLayoutView 弹 alert 后清空)
    public var lastError: StoreError?

    /// 正在解锁的 VM (显 spinner / 防重复点)
    public private(set) var unlockingIDs: Set<UUID> = []

    private var pollTimer: Timer?

    // MARK: - 加密 VM 解锁缓存 (进程内, 不落盘; 不含 master KEK)
    /// 解锁后的明文 config (覆盖 catalog 的 nil); 用 @ObservationIgnored 不触发观察 (refresh overlay 才驱动 UI)
    @ObservationIgnored private var unlockedConfigs: [UUID: VMConfig] = [:]
    /// 解锁派生的 subkeys (改 config 重密用)
    @ObservationIgnored private var unlockedSubKeys: [UUID: EncryptionKDF.SubKeySet] = [:]
    /// 解锁密码 (启动时复用不再弹; 仅进程内存)
    @ObservationIgnored private var unlockedPasswords: [UUID: String] = [:]
    /// 末次活动时间 (5min auto-lock 计时)
    @ObservationIgnored private var unlockedAt: [UUID: Date] = [:]

    private static let unlockTTL: TimeInterval = 300   // 5 分钟无活动 auto-lock

    public init() {
        refresh()
        // 启动即选中第一个 (有 VM 时)
        if selectedID == nil { selectedID = vms.first?.id }
    }

    // MARK: - 轮询

    /// 启 1Hz 轮询 (RootView .onAppear 调). .common mode 让 UI tracking (滚动/拖拽) 期间仍刷新.
    /// 不写 deinit (MainActor 类 deinit 为 nonisolated 碰不了 pollTimer); 改为 timer 持 weak self,
    /// self 析构后下一 tick 自我 invalidate. 正常退出走 stopPolling().
    public func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            // self 已析构 → 自我 invalidate (timer.invalidate 留在外层 nonisolated 闭包,
            // 不跨进 MainActor 闭包, 避免 sending 数据竞争告警)
            guard let self else { timer.invalidate(); return }
            // 定时器在 main runloop 触发, 同步标记 MainActor 隔离 (避免每 tick 一个 Task 跳转)
            MainActor.assumeIsolated { self.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 重扫 VMCatalog.list, diff 合并. 列表内容变才赋值 (避免无谓重绘);
    /// 选中的 VM 被删 → 退选到第一个.
    public func refresh() {
        let now = Date()
        // 续命: 选中的已解锁 VM 视为活动 (持续查看不 auto-lock, 跟老 GUI 一致)
        if let sel = selectedID, unlockedAt[sel] != nil { unlockedAt[sel] = now }
        // auto-lock: 末次活动超 TTL 的清掉 (inline, 不调 lock() 防递归)
        for (id, at) in unlockedAt where now.timeIntervalSince(at) > Self.unlockTTL {
            clearUnlock(id)
        }
        // 枚举 + overlay 解锁的明文 config (catalog 给加密 VM 是 config=nil)
        var fresh = VMCatalog.list()
        for i in fresh.indices where fresh[i].isEncrypted {
            if let cfg = unlockedConfigs[fresh[i].id] {
                fresh[i] = fresh[i].withUnlockedConfig(cfg)
            }
        }
        if fresh != vms { vms = fresh }
        if let sel = selectedID, !fresh.contains(where: { $0.id == sel }) {
            selectedID = fresh.first?.id
        } else if selectedID == nil {
            selectedID = fresh.first?.id
        }
    }

    /// 当前选中 VM
    public var selected: VMSummary? {
        guard let selectedID else { return nil }
        return vms.first { $0.id == selectedID }
    }

    // MARK: - 动作 (失败写 lastError, 完成后 refresh)

    /// 启动. 加密 VM 必须传 password (调用方先弹 dialog.input 拿); 明文传 nil.
    public func start(_ s: VMSummary, password: String?) {
        run("启动失败") { try VMControl.start(bundleURL: s.bundleURL, password: password) }
    }

    /// 软关机 (ACPI)
    public func stop(_ s: VMSummary) {
        run("停止失败") { try VMControl.stop(bundleURL: s.bundleURL) }
    }

    /// 强制关机
    public func kill(_ s: VMSummary) {
        run("强制停止失败") { try VMControl.kill(bundleURL: s.bundleURL) }
    }

    /// 删除 (trash / purge / secureErase)
    public func delete(_ s: VMSummary, mode: VMControl.DeleteMode) {
        run("删除失败") { try VMControl.delete(bundleURL: s.bundleURL, mode: mode) }
        // 删的若是选中项, refresh 会自动退选到第一个
    }

    // MARK: - 配置编辑 (业务页 #2, V1/V3)

    /// 改配置 (CPU/内存/网络/选项/ISO 等表单字段). 明文走 VMControl.saveConfig;
    /// 加密 VM 需先解锁 (V2 接入 configKey), 当前未解锁 → 提示.
    /// requireStopped 默认 true (多数字段需停机); 剪贴板等热改字段传 false.
    public func saveConfig(_ s: VMSummary,
                           requireStopped: Bool = true,
                           mutate: (inout VMConfig) throws -> Void) {
        if s.isEncrypted {
            guard let configKey = unlockedSubKeys[s.id]?.config else {
                lastError = StoreError(title: "需先解锁", message: "请先解锁加密 VM 再编辑配置.")
                return
            }
            run("保存失败") {
                try VMControl.saveConfigEncrypted(bundleURL: s.bundleURL,
                                                  requireStopped: requireStopped,
                                                  configKey: configKey,
                                                  mutate: mutate)
                // 重密后刷新缓存的明文 config + 续命 (run 末尾会 refresh overlay)
                self.unlockedConfigs[s.id] = try? EncryptedConfigIO.load(from: s.bundleURL, key: configKey)
                self.unlockedAt[s.id] = Date()
            }
        } else {
            run("保存失败") {
                try VMControl.saveConfig(bundleURL: s.bundleURL,
                                         requireStopped: requireStopped,
                                         mutate: mutate)
            }
        }
    }

    // MARK: - 加密 VM 解锁 (业务页 #2, V2)

    public func isUnlocked(_ id: UUID) -> Bool { unlockedConfigs[id] != nil }
    public func isUnlocking(_ id: UUID) -> Bool { unlockingIDs.contains(id) }
    public func unlockedPassword(_ id: UUID) -> String? { unlockedPasswords[id] }

    /// 解锁加密 VM: 密码 → PBKDF2 master key → deriveAll subkeys → 解密 config → 缓存.
    /// PBKDF2 600k 迭代慢, 走 detached task 不卡主线程. 仅 qemuPerfile scheme.
    public func unlock(_ s: VMSummary, password: String) async {
        guard s.isEncrypted else { return }
        guard s.encryptionScheme == .qemuPerfile else {
            lastError = StoreError(title: "暂不支持",
                                   message: "VZ-sparsebundle 加密 VM 解锁尚未实现 (QEMU 优先).")
            return
        }
        let id = s.id
        let url = s.bundleURL
        unlockingIDs.insert(id)
        defer { unlockingIDs.remove(id) }
        do {
            let result: (cfg: VMConfig, keys: EncryptionKDF.SubKeySet) =
                try await Task.detached(priority: .userInitiated) {
                    let handle = try EncryptedBundleIO.unlock(bundlePath: url, password: password)
                    defer { try? handle.close() }
                    guard let keys = handle.qemuSubKeys else {
                        throw HVMError.encryption(.parseFailed(reason: "解锁返回缺 subkeys"))
                    }
                    return (handle.config, keys)
                }.value
            unlockedConfigs[id] = result.cfg
            unlockedSubKeys[id] = result.keys
            unlockedPasswords[id] = password
            unlockedAt[id] = Date()
            refresh()
        } catch let e as HVMError {
            let uf = e.userFacing
            lastError = StoreError(title: "解锁失败", message: uf.message, hint: uf.hint)
        } catch {
            lastError = StoreError(title: "解锁失败", message: error.localizedDescription)
        }
    }

    /// 主动锁定 (清缓存 + refresh 回到占位)
    public func lock(_ id: UUID) {
        clearUnlock(id)
        refresh()
    }

    /// 清解锁缓存 (不 refresh; auto-lock 在 refresh 内调, 防递归)
    private func clearUnlock(_ id: UUID) {
        unlockedConfigs[id] = nil
        unlockedSubKeys[id] = nil
        unlockedPasswords[id] = nil
        unlockedAt[id] = nil
    }

    /// 动作包装: try → 失败映射 HVMError.userFacing 写 lastError → 总 refresh
    private func run(_ failTitle: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch let e as HVMError {
            let uf = e.userFacing
            lastError = StoreError(title: failTitle, message: uf.message, hint: uf.hint)
        } catch {
            lastError = StoreError(title: failTitle, message: error.localizedDescription)
        }
        refresh()
    }
}

#endif
