# 新 GUI 业务页 — VM 画面 framebuffer 嵌入

> 状态: **实现暂停 (待 QEMU-only 转向)** 2026-05-30 — F1/F2 初版代码已撤回 (给 [QEMU_ONLY_PIVOT.md](QEMU_ONLY_PIVOT.md) 剥 VZ 留干净基座). 本稿作为该转向的 **P3 内嵌** 阶段, 在纯 QEMU 基座上收尾. **届时 VZ 相关内容 (推迟/占位/进程模型分叉) 全部失效删除** — 项目无 VZ 后, 详情页 running 直接 = QEMU 画面, 无 VZ 分支.
>
> 决策保留: **D2 嵌详情区不做 detached** / **D3 画面 ⇄ 配置 TAB 切换**. D1 (QEMU-only) 已被 QEMU_ONLY_PIVOT 升级为"VZ 彻底移除". 业务页 #4 (AppKit Metal view ↔ SwiftUI 桥). PR F1-F4 待 P1 剥 VZ 完成后重启.
>
> 前置依赖: [NEW_GUI.md](NEW_GUI.md) 基础设施 + [NEW_GUI_MAIN_LAYOUT.md](NEW_GUI_MAIN_LAYOUT.md) (`NewGUIStore` + `HVMControl`) + [NEW_GUI_VM_DETAIL.md](NEW_GUI_VM_DETAIL.md) (详情页 `DetailOverviewView` + runningNote 占位待替换).
>
> 显示底层 (HDP 协议 / DisplayChannel / FramebufferHostView / QemuFanoutSession / InputForwarder) 已在老 GUI 全验证, 本稿只做**新 GUI 的嵌入桥接 + fanout 生命周期 + 输入态管理**, 不碰 HDP 协议 / Metal 渲染. 决策溯源: [docs/v1/QEMU_DISPLAY_PROTOCOL.md](../v1/QEMU_DISPLAY_PROTOCOL.md) (HDP v1.0.0) + [docs/v3/INPUT_CAPTURE.md](../v3/INPUT_CAPTURE.md).

---

## 目标

把运行中 VM 的画面嵌进新 GUI 详情页 (替换当前 `runningNote` 占位 "画面嵌入待 framebuffer 子稿"), 让新 GUI 脱离老 GUI 独立看画面 + 操作 guest:

- **QEMU 后端画面嵌入** (Linux / Windows guest): 详情页运行态显 `FramebufferHostView` (Metal), 复用 `QemuFanoutSession` HDP 通路. 键鼠转发 + 输入捕获 (Cmd+Opt) + 动态分辨率
- VM running 时详情区从"配置 section"切到"画面 + 精简工具条"; 停机切回配置编辑
- fanout 生命周期挂 `NewGUIStore` (照搬老 `AppModel.ensureQemuFanout` 模式, 不依赖老 AppModel)

### 不做 (out of scope) — **VZ 画面本稿不做, 单列原因**

- **VZ 后端画面嵌入 (macOS / Linux VZ guest)** → **推迟, 单独提案**:
  - **根因**: 新 GUI 走 `VMControl.start` → fork `--host-mode-bundle` 子进程, VZ VM 跑在子进程, 渲染到**离屏 NSWindow** (`HVMHostEntry` -20000,-20000), GUI 主进程**拿不到** `VZVirtualMachine` 实例. 老 GUI 能显 VZ 是因为它把 VZ 跑在**主进程** (`AppModel.sessions[]` 持 `VZVirtualMachine` + `HVMView`), 与子进程路径是两套
  - VZ 无 iosurface backend (QEMU patch 0002 是 QEMU 专属), VZ Metal drawable 在子进程内, 无 HDP/IOSurface IPC 通路
  - **VZ 未来方向已定 (2026-05-30 用户讨论结论): 走 (a) 进程内 VZ**, 不走 (b) IOSurface 桥:
    - **(a) 进程内 VZ run** (✅ 首选, 留 `NEW_GUI_FRAMEBUFFER_VZ.md`): 新 GUI store 复用现成 `VMSession`(`bundleURL:config:` 标准独立, 内建 `HVMView`+`VMHandle`, 仅 `sessionDidEnd` hook, 不深耦 AppModel) + start 按 engine 分流 (VZ→进程内 `VMSession.start`, QEMU→子进程 HDP). **VZ 输入免费**: `HVMView`(=VZVirtualMachineView) 嵌新 GUI 主窗口作 firstResponder, Apple 框架原生处理键鼠, 无需注入. 复用 wiring 非新写显示代码, 中等工作量
    - **(b) IOSurface 回读桥** (❌ 弃): host-mode-bundle 子进程把 VZ Metal drawable 每帧 readback 成 IOSurface 走 HDP-like IPC. 显示可行但 **VZ 输入是死结** — VZ 无 QMP 等价带外注入 API, offscreen 窗口非 key window 收不到合成 NSEvent. 重 (每帧 readback) + 高风险, 不做
  - per-backend 自然分工 = 各自最优: QEMU 走 IPC (零拷贝 HDP), VZ 走进程内 (原生显示+输入). 不强求"统一通路"
  - 本稿期间: VZ VM running 详情页保留占位文案改为 "VZ 画面嵌入推迟 (走老 GUI / hvm-dbg screenshot)"
- **detached 独立画面窗口** (老 GUI `DetachedVMWindowController`) → v1 不做, 留 D2 决 (先嵌详情区, 弹窗 follow-up)
- **HDP 协议 / Metal 渲染 / 输入转发实现** → 已全有, 不改
- **Cmd+V 文件粘贴 / 剪贴板 / 共享目录** → 已在 `FramebufferHostView` (onFilePaste) + vdagent 通路, 本稿接线即可, 不新实现

---

## 项目当前状态 (设计前提)

老 GUI 已落地全链 (新 GUI 直接复用, 同 `HVM` target 编译):

| 组件 | 文件 | 职责 |
|---|---|---|
| `FramebufferHostView` | `HVMDisplayQemu/FramebufferHostView.swift` | MTKView 子类: 渲染 IOSurface + 键鼠转发 + 输入捕获双态 + modifier 镜像 + onFilePaste |
| `QemuFanoutSession` | `HVM/UI/Content/QemuFanoutSession.swift` | HDP socket 连接 + 多 view fd dup 扇出 + resize + `onDisconnected` hook. 构造只需 `vmID` + `bundleURL` |
| `DisplayChannel` | `HVMDisplayQemu/DisplayChannel.swift` | HDP 客户端 (HELLO 协商 / SURFACE_NEW / cursor / LED / SCM_RIGHTS fd) |
| `InputForwarder` | `HVMDisplayQemu/InputForwarder.swift` | 独立 QMP socket 发绝对坐标鼠标 + qcode 键盘 |

`QemuFanoutSession` 对 `AppModel` **无强耦合** (只 vmID/bundleURL + 上层设 `onDisconnected` hook 拆 fanout). 老 `AppModel.ensureQemuFanout(id:bundleURL:)` (line 1622) = 建 fanout + 设 hook + 存字典. 新 GUI store 照搬即可.

`VMSummary` 已带 `id` / `bundleURL` / `engine` / `runState` — 建 QEMU 显示视图所需全有, 无须新增字段.

新 GUI 详情页 `DetailOverviewView` 当前运行态只显 `runningNote` 文本占位 (line ~245).

---

## 选型对比

### 选型 1: 画面位置 — 详情区嵌入 vs 独立窗口 vs 两者

| 方案 | 做法 | 优 | 劣 |
|---|---|---|---|
| **A. 详情区嵌入** ✅ 推荐 (v1) | running + QEMU 时详情右栏从"配置 section"切到"画面 + 精简工具条" | 不弹窗, detail 是主战场跟新 GUI 对齐; 选中即见画面; 复用老 `DetailContainer.buildQemuEmbedded` 模式 | 详情区窄 (sidebar 240 + 余), 画面 letterbox 等比; SwiftUI↔AppKit 混合架构 |
| B. 独立 detached 窗口 | 详情留占位 + [打开画面] 弹 borderless 窗 | 复用 `DetachedVMWindowController`; 画面大 | 弹窗打断; 主+detached 选中态切换复杂; v1 过重 |
| C. 两者都做 (老 GUI 现状) | 嵌入 + N detached 共用 fanout | 最灵活 | v1 范围爆炸; fanout 多 subscriber 生命周期 + 输入态跨窗复杂 |

**选 A** (v1 嵌详情区): 最小可用 + 跟新 GUI "详情即主战场" 一致. detached (B) 留 D2 follow-up — fanout 多 subscriber 机制已支持, 加 detached 是增量.

### 选型 2: SwiftUI ↔ AppKit 桥接 — NSViewRepresentable 包 vs 详情区整体 AppKit

| 方案 | 做法 | 优 | 劣 |
|---|---|---|---|
| **A. `NSViewRepresentable` 包稳定容器** ✅ 推荐 | `QemuFramebufferView: NSViewRepresentable`, `makeNSView` 建一次 container NSView + 内挂 `FramebufferHostView` (存 Coordinator), `updateNSView` 只重绑 fanout/config; 详情区 SwiftUI 里 `if running+qemu { QemuFramebufferView(...) }` | 跟新 GUI SwiftUI 详情自然融合; view 身份稳定 (Coordinator 持 fbView 跨 update 不重建) | MTKView 在 SwiftUI 树内, 需防 SwiftUI 重建打断 Metal drawable (Coordinator 持有 + makeNSView 只建一次缓解) |
| B. 详情区整块换成 AppKit `NSHostingController` 包 | running 时详情容器走纯 AppKit (老 GUI DetailContainerView 模式) | 老 GUI 已验证稳定; Metal drawable 不受 SwiftUI layout 干扰 | 新 GUI 详情是 SwiftUI, 整块切 AppKit 破坏架构一致性; 配置 section (SwiftUI) 和画面 (AppKit) 切换割裂 |

**选 A**: `NSViewRepresentable` 是 SwiftUI 嵌 AppKit 标准路. 关键纪律: **Coordinator 持 `FramebufferHostView` 实例, `makeNSView` 只建一次**, SwiftUI 复用 view 时 `updateNSView` 不重建 (Metal drawable 稳定). MTKView 不直接做 representable 的 root (套一层 container NSView 防 displayLink 受 SwiftUI 影响, 跟老 GUI "MTKView 不嵌 NSHostingView" 同理).

### 选型 3: fanout 生命周期归属 — NewGUIStore vs 独立 manager

| 方案 | 优 | 劣 |
|---|---|---|
| **A. NewGUIStore 持 fanout 字典** ✅ 推荐 | 跟老 `AppModel.qemuFanouts` 同模式; store 已是 VM 控制单一来源 (启停/状态), fanout 跟 runState 联动自然; `@ObservationIgnored` 字典不触发重绘 | store 体量增 (但 fanout 是 VM 运行态的一部分, 归属合理) |
| B. 独立 `QemuFanoutManager` 单例 | store 瘦 | 跟 runState 联动要跨对象同步; 多一个生命周期源 |

**选 A**: `NewGUIStore` 加 `@ObservationIgnored qemuFanouts: [UUID: QemuFanoutSession]` + `ensureQemuFanout(_:)` / `tearDownFanout(_:)`. VM 停止 / disconnected 时拆. 跟 `unlockedConfigs` 等 ignored 字典同款.

---

## 实现要点

### NewGUIStore fanout 生命周期 (`GUI/Store/NewGUIStore.swift`)

```swift
@ObservationIgnored private var qemuFanouts: [UUID: QemuFanoutSession] = [:]

/// running QEMU VM 的 HDP fanout. 已有复用, 否则建 + start + 设 onDisconnected hook.
@MainActor func ensureQemuFanout(_ s: VMSummary) -> QemuFanoutSession {
    if let f = qemuFanouts[s.id] { return f }
    let f = QemuFanoutSession(vmID: s.id, bundleURL: s.bundleURL)
    f.onDisconnected = { [weak self] in self?.tearDownFanout(s.id); self?.refresh() }
    f.start()
    qemuFanouts[s.id] = f
    return f
}

@MainActor func tearDownFanout(_ id: UUID) {
    qemuFanouts[id]?.stop()
    qemuFanouts[id] = nil
}
```

- VM 停止 (refresh 检测 runState .stopped) 或 onDisconnected → tearDownFanout. 防泄漏.
- fanout `start()` 异步连 socket (子进程刚启动 socket 可能未就绪, DisplayChannel 内部重试).

### QemuFramebufferView (`GUI/Layout/QemuFramebufferView.swift`, 新, NSViewRepresentable)

```swift
struct QemuFramebufferView: NSViewRepresentable {
    let vm: VMSummary
    let store: NewGUIStore
    let dialogPresenting: Bool   // dialog 活时暂停 + 遮罩 (防 Metal z-order 穿透)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let fb = FramebufferHostView(frame: .zero)
        fb.macStyleShortcuts = vm.config?.macStyleShortcuts ?? true
        fb.onFilePaste = { [weak store] urls in store?.pasteFiles(vm, urls) }   // vdagent file_xfer
        container.addSubview(fb)   // 约束铺满
        context.coordinator.fbView = fb
        store.ensureQemuFanout(vm).addSubscriber(fb, isResizeMaster: true)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 只更新可变态 (dialog 遮罩 / config 变), 不重建 fbView
        context.coordinator.fbView?.inputCaptureEnabled = !dialogPresenting
        context.coordinator.fbView?.isPaused = dialogPresenting
        // dialog 活: 叠不透明遮罩 (老 GUI DetailContainerView fbViewMask 同款)
    }

    final class Coordinator { var fbView: FramebufferHostView? }
}
```

- **resize master**: 详情区嵌入即唯一 view → isResizeMaster=true (拖窗口 resize → `fanout.requestResizeFromUser` → guest 改分辨率, vdagent 通路).
- **dialog z-order 防穿透**: CAMetalLayer 不尊重 AppKit sibling z-order, 新 GUI dialog (`.hvmDialogHost` overlay) 可能被画面穿透盖住. 缓解: `dialogPresenting` (= `dialog.isPresenting`) 时 `isPaused=true` + 叠不透明遮罩 + `inputCaptureEnabled=false` (老 GUI 三保险同款).

### DetailOverviewView 运行态分支 + 画面/配置 TAB (`GUI/Layout/DetailOverviewView.swift`)

D3: running QEMU 时详情顶部加 **segmented [画面][配置]** (`@State runningTab`, 默认 `.screen`), 切换画面 ⇄ 配置. running VZ 无画面 → 不显 tab, 直接配置 + VZ 占位.

```swift
enum RunningTab { case screen, config }
@State private var runningTab: RunningTab = .screen

// detail body:
if vm.runState == .running && vm.engine == .qemu {
    // 顶部 tab segmented (header 区, 不随画面/配置滚动)
    runningTabBar   // [画面] [配置] — HVMUI.Button ghost/primary 按选中, probeID detail.tab.{screen,config}
    switch runningTab {
    case .screen:
        QemuFramebufferView(vm: vm, store: store, dialogPresenting: dialog.isPresenting)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .config:
        configSections(vm)   // 现有 section ScrollView (running 多字段 disabled)
    }
} else if vm.runState == .running && vm.engine == .vz {
    vzPlaceholder + configSections(vm)   // VZ 占位 "画面推迟" + 配置
} else {
    configSections(vm)   // stopped: 配置 section (现状)
}
```

- **切 VM / 停机时 reset `runningTab = .screen`** (跟 draft sync 同款守卫, 避免停机后停在已隐藏的画面 tab).
- tab 默认 `.screen` (running 主任务是看画面); 用户切 `.config` 看/改配置 (running disabled 字段照旧).
- **画面 tab 不进 ScrollView** (Metal view 需稳定 superview); 配置 tab 仍是现有 ScrollView. 两 tab 切换 = SwiftUI 条件渲染 (画面 tab 离开时 fbView 随 representable 销毁? → 见 P0-1: 切 tab 不应每次重建 fanout; QemuFramebufferView 复用 store fanout, fbView 重建只重新 addSubscriber, surface replay 即恢复, 不闪太久; 若闪明显则 F2 用 `.opacity`/`isHidden` 保活而非条件移除).
- 工具条 (停止/强制停止/捕获提示): 复用 header actionButtons + Cmd+Opt 提示.

### 输入捕获单一态 (跨 view 防泄漏)

- v1 只嵌一个 view (无 detached) → 输入捕获是单 view 局部态 (`FramebufferHostView.isCaptured`), 无跨 view 冲突. `CGSSetGlobalHotKeyOperatingMode` 是 process-global, 单 view 自洽.
- **退出 captured 闭环必须保**: `viewWillMove(toWindow:nil)` / `resignFirstResponder` / dialog 活 `inputCaptureEnabled=false` 时 `releaseCapture()` (CLAUDE.md 硬约束, FramebufferHostView 已实现, 嵌入时不破坏).
- detached (D2) 引入多 view 时再上升到 store 单一 `isCaptured` 态 (本稿不做).

---

## 风险与待验证

| 级别 | 项 | 缓解 |
|---|---|---|
| **P0-1** | NSViewRepresentable 被 SwiftUI 重建 → Metal drawable 断 / 画面黑 | Coordinator 持 fbView, makeNSView 只建一次, updateNSView 不重建; view 身份稳定 (running 分支 vm.id 不变期间不重算). e2e: 切 dialog / resize 不黑屏 |
| **P0-2** | dialog (确认/错误) 被 CAMetalLayer 穿透盖不住 | `dialog.isPresenting` → isPaused + 不透明遮罩 + inputCaptureEnabled=false (老 GUI 三保险). e2e: running VM 上弹 stop 确认框, 框可见可点 |
| **P0-3** | fanout 子进程 socket 未就绪 / 连接延迟 → 画面区空白卡住 | DisplayChannel 内部重试; 详情区显 "正在连接画面…" loading 直到首帧 (SURFACE_NEW). 超时 (CLAUDE.md boot 20s 线) 显错误 + 重连按钮 |
| **P0-4** | VM 停止 / disconnected → fanout 不拆 → 泄漏 + 残画面 | refresh 检测 .stopped → tearDownFanout; onDisconnected hook 拆 + refresh. e2e: 停 VM → 画面消失切回配置 |
| **P0-5** | 输入捕获 captured 态退出闭环漏 → 系统热键卡 disable, 用户无法 cmd+tab | FramebufferHostView 既有 releaseCapture 闭环不破坏; 嵌入/移除/dialog 活都查 isCaptured 释放. e2e: 捕获后切走 app, cmd+tab 正常 |
| P1 | 详情区窄, 画面 letterbox 黑边 | FramebufferHostView 等比缩放已支持; v1 接受黑边 (detached D2 给大画面) |
| P1 | running 切 stopped 详情区 SwiftUI 重布局闪 | 分支切换加 transition; 可接受 |

**P0 must-pass gate**: throwaway QEMU Linux VM 启动 → 新 GUI 详情区显画面 (hvm-dbg screenshot 验证有内容非黑) → 键鼠转发 (hvm-dbg 发键 guest 收到) → resize 改分辨率 → 弹 dialog 不穿透 → 停 VM 画面消失. 输入捕获 Cmd+Opt 因需真键盘**部分手动 / hvm-dbg 模拟**.

> **测试手段**: 画面验证走 `hvm-dbg screenshot` (截 guest framebuffer) + `Read` 肉眼看 (不靠 OCR, CLAUDE.md 约束); 新 GUI 窗口截图走 `hvm-dbg gui screenshot`. 键鼠走 hvm-dbg 注入.

---

## PR 拆解

每 PR ≤ 2 天. 走 `GUI=new`.

| PR | 标题 | 验收 |
|---|---|---|
| **F1** | feat(gui): NewGUIStore fanout 生命周期 (ensureQemuFanout/tearDownFanout + onDisconnected + 停机拆) | `make build`; throwaway QEMU VM 启动 → store 建 fanout 连上 socket (log 验证 HELLO 协商); 停机拆 (P0-4) |
| **F2** | feat(gui): QemuFramebufferView (NSViewRepresentable + Coordinator 持 fbView) + DetailOverviewView running 分支 (QEMU 画面 / VZ 占位 / stopped 配置) + "连接中" loading | hvm-dbg gui screenshot 详情区显画面非黑 (P0-1/P0-3); 切 dialog 不黑 |
| **F3** | feat(gui): 输入转发接线 (resize master / onFilePaste) + dialog z-order 遮罩 + 输入捕获闭环 + 精简工具条 | hvm-dbg 发键鼠 guest 收到; 弹 stop 确认不穿透 (P0-2); resize 改分辨率; 捕获退出闭环 (P0-5) |
| **F4** | docs + 回写 (CLAUDE.md 新 GUI framebuffer 约束 / 设计稿状态 / README / TODO) + e2e 全路径 | 启动→显画面→键鼠→resize→dialog→停机 e2e; VZ 占位文案 |

> **规模**: 比 ENCRYPTION 大 (AppKit 桥 + Metal + 输入 + 进程模型坑), 4 PR. F2 (桥接) + F3 (输入+z-order) 是硬骨头.

**合入后回写**: `CLAUDE.md` (新 GUI framebuffer 约束: QEMU-only / NSViewRepresentable Coordinator 持 view / dialog z-order 遮罩 / fanout 挂 store / 输入捕获闭环 / VZ 推迟原因) + 设计稿状态 + README + TODO.

---

## 未决事项 (Decisions)

| ID | 决策 | 当前默认 | 决策时机 |
|---|---|---|---|
| **D1** | v1 范围: QEMU-only vs QEMU+VZ | **✅ QEMU-only** (VZ 进程模型推迟单独提案) | ✅ 用户 2026-05-30 |
| **D2** | detached 独立画面窗口 | **✅ v1 不做** (先嵌详情区, fanout 多 subscriber 已支持留 follow-up) | ✅ 用户 2026-05-30 |
| **D3** | running QEMU 详情区布局 | **✅ 画面 ⇄ 配置 TAB 切换** (用户定: 详情顶部 segmented [画面][配置], 默认画面; running 也能切回看/改配置) | ✅ 用户 2026-05-30 |
| **D4** | VZ running 占位文案 / 是否给 [用老 GUI 打开] 按钮 | 纯文案提示 (走老 GUI / hvm-dbg); 不加跳老 GUI 按钮 (避免耦合) | F2 内定 |
| **D5** | 输入捕获快捷键提示 UI (Cmd+Opt overlay) | 复用 FramebufferHostView 既有 overlay; 详情工具条加文字提示 | F3 内定 |
| **D6** | "连接中" 超时阈值 | 跟 boot 20s 线一致 (CLAUDE.md), 超时显重连按钮 | F2 内定 |
| **D7** | VZ 画面未来方案: 进程内 VZ run vs IOSurface 回读桥 | 推迟单独提案 `NEW_GUI_FRAMEBUFFER_VZ.md`, 本稿不决 | 后续 |

---

**评审请确认**: D1 (QEMU-only v1, VZ 推迟) + D2 (先嵌入不 detached) + D3 (画面占满详情) + PR 拆解 F1-F4 + P0 gate (throwaway QEMU VM 画面/键鼠/resize/dialog/停机 e2e, 输入捕获部分手动). 确认后从 F1 (fanout 生命周期) 起.

**特别提示**: 本稿最大不确定性是 **VZ 画面** — 用户若要求 VZ 也嵌, 那是另一个更大的提案 (进程内 VZ 运行或 IOSurface 桥), 不在本稿. 请确认接受 "v1 QEMU-only, VZ 推迟" 的范围.
