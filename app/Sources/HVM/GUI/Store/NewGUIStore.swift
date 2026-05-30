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

    private var pollTimer: Timer?

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
        let fresh = VMCatalog.list()
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
        guard !s.isEncrypted else {
            lastError = StoreError(title: "需先解锁",
                                   message: "加密 VM 的配置编辑需先解锁 (后续 PR 接入).")
            return
        }
        run("保存失败") {
            try VMControl.saveConfig(bundleURL: s.bundleURL,
                                     requireStopped: requireStopped,
                                     mutate: mutate)
        }
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
