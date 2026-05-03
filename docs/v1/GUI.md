# GUI 设计 (`HVM.app`)

## 目标

- 单一 macOS 原生 GUI 管理多台 VM (VZ + QEMU 双后端共存)
- 严格深色主题, 不跟随系统
- 业务侧只写编排, 不重画样式 — 所有控件走自绘组件层 (`HVM/UI/Style/*` + `HVM/UI/Content/Buttons.swift`)

## 技术栈

- **SwiftUI** + **AppKit** 混合: 主窗口 / 弹窗 / sidebar / detail bar 走 SwiftUI; 主 NSWindow / detached NSWindow / status item / menu popover 走 AppKit
- `@Observable` (Swift 5.9+) — `AppModel` / `VMSession` / `QemuFanoutSession` / `ErrorPresenter` / `ConfirmPresenter`
- 全主线程: UI 路径 `@MainActor`
- 不引入 Combine / TCA / RxSwift

## 主题规范 (token)

风格 token 集中在 `app/Sources/HVM/UI/Style/Theme.swift`, 业务侧**禁止**裸写颜色 / 字号 / 数字 padding:

| token | 用途 |
|---|---|
| `HVMColor.bgBase` `bgCard` `bgCardHi` `border` `accent` `textPrimary` `textSecondary` 等 | 中性深灰 #18181B 主底 + 一组卡片层 |
| `HVMSpace.xs / s / m / l / xl` | 间距 |
| `HVMRadius.s / m / l` | 圆角 |
| `HVMFont.body / small / title / heading / mono / monoSmall` | mono 仅用于 UUID / MAC / 路径 / shell 命令 / build 号; 正文 / 标题 / 按钮 / 表单一律 SF Pro |
| `HVMBar.height` `HVMWindow.minWidth` 等 | 结构常量 |

`HVMApp` 全局锁 `NSAppearance(named: .darkAqua)`, 主窗口背景固定深色, 系统切 Light 不跟随。

## 主窗口结构

borderless NSWindow + 自家 toolbar (`HVM/UI/Shell/Toolbar.swift`) + `MainWindowController`. 内部三段:

```
┌────────────────────────────────────────────────────────────┐
│ Toolbar [traffic light] [HVM] ... [+]                      │  ← Shell/Toolbar
├──────────────┬────────────────────────────────────────────┤
│ SidebarView  │  DetailContainerView                        │
│ (VM 列表 +    │  └─ DetailBars (VM 详情 / 嵌入 framebuffer) │
│  状态指示)    │                                             │
│              │                                             │
├──────────────┴────────────────────────────────────────────┤
│ RunningTabsBar (运行中 VM 多任务切换条; 多 VM 并发)         │  ← Content/RunningTabsBar
└────────────────────────────────────────────────────────────┘
```

- `SidebarView` (`HVM/UI/Content/SidebarView.swift`): VM 列表 + GuestIcon + 状态点
- `DetailContainerView` / `DetailBars`: 选中 VM 的详情 + 配置概览 + 主操作按钮; 嵌入运行时承载 `FramebufferHostView` (QEMU) 或 VZ view
- `RunningTabsBar`: 多个 VM 同时运行时的快速切换条, 跟选中态 / 嵌入态联动
- `StatusBar` + `MenuPopoverView`: menu bar 常驻 status item, 点出 popover 切显隐主窗口

> **menu bar 双 status item 残留**: GUI 主进程 + 子进程 (`--host-mode-bundle`) 各注册一个 status item, 视觉上重复 (见 docs/v2/05 P-4 待清理)。

## detached 独立窗口

QEMU 后端 VM 可"弹出独立窗口", 与主窗口嵌入路径**共存于同一 fanout session** — 同一份 IOSurface 多个 framebuffer view 同步显示。

`DetachedVMWindowController` (`HVM/UI/Detached/DetachedVMWindowController.swift`) 关键决策:

- **borderless** NSWindow (`StyleMask = [.borderless, .resizable, .miniaturizable]`) — 彻底去掉系统 titlebar, 自家全管 toolbar 与拖动
- 圆角 10pt (`contentView.layer.cornerRadius`), 背景固定 `NSColor.black` + `darkAqua`
- 自画 macOS 风红绿灯三按钮 (close=红 / minimize=黄 / zoom=绿), 跟系统视觉一致但行为我们自管
- `BorderlessKeyableWindow` override `canBecomeKey/Main = true`, 否则 borderless 默认拿不到 key window
- 顶部 toolbar 一条 (28pt + 1pt divider): traffic light + GuestBadge + 名字 + 状态 + 配置摘要 + Pause/Stop/Kill + clipboard toggle + 关闭 detached
- 底部无 chrome, framebuffer 顶到底 (Parallels/VMware Fusion 风格)
- 输入: 各 view 自带 `InputForwarder`, key window 那个 view 拿到 `NSEvent`, 主嵌入 + detached 自动只有一边发输入到 guest

## 弹窗约束 (CLAUDE.md 权威, 必须遵守)

1. **只能通过点击右上角 X 按钮关闭**
2. **禁止点击遮罩层关闭**
3. **禁止 `NSAlert` / `.alert()`** — 错误对话框统一走 `ErrorDialog`
4. **禁止业务侧自拼 `ZStack(蒙底 + 居中卡片)`** — 一律套 `HVMModal`
5. 装机 / 下载等不可中断流程: `HVMModal(closeAction: nil)` 隐 X

### `HVMModal` (`HVM/UI/Style/HVMModal.swift`)

合规多 modal 容器: 顶栏标题 + X (走 `IconButtonStyle`) / content / 可选 footer。点击遮罩**不**关闭。所有业务弹窗都套这一层, 不再自画卡片。

### `DialogOverlay` (`HVM/UI/Dialogs/DialogOverlay.swift`)

App 级合规 modal 栈容器, 同一时刻只渲染一个 modal, 队列排队:

- `ErrorDialogOverlay(presenter: errors)` — `ErrorPresenter` 单例驱动
- `ConfirmDialogOverlay(presenter: confirms)` — `ConfirmPresenter` 单例驱动
- 各业务 sheet (CreateVMDialog / EditConfigDialog / ...) 由 `AppModel` 字段驱动并入栈

### 业务弹窗清单 (`HVM/UI/Dialogs/`)

| 弹窗 | 触发 |
|---|---|
| `CreateVMDialog` | 新建 VM 向导 (macOS / Linux / Windows arm64) |
| `EditConfigDialog` | 编辑 VM 配置 (CPU / 内存 / 网络 / 磁盘等), 含 `VMSettingsNetworkSection` 子节 |
| `ErrorDialog` | 全项目唯一错误入口, 队列排队, 折叠 details |
| `ConfirmDialog` | 二次确认 (Kill / 删除 / 还原 snapshot 等) |
| `DiskAddDialog` / `DiskResizeDialog` | 数据盘加 / 主盘扩容 |
| `SnapshotCreateDialog` | 创建 snapshot |
| `CloneVMDialog` | 整 VM 克隆 (form / running / done 三态; 详情页 actionRow "Clone" 触发) |
| `OSImagePickerDialog` | Linux 创建向导选 OSImageCatalog 内置发行版或自定 URL |
| `OSImageFetchDialog` | OSImage 下载进度 modal |
| `IPSWFetchDialog` (`HVM/UI/IPSW/`) | macOS IPSW 下载进度, `IpswCatalogPicker` 选具体 build |
| `VirtioWinFetchDialog` | Win VM 创建时按需下载 virtio-win 驱动 ISO |
| `UtmGuestToolsFetchDialog` | Win VM 装 UTM Guest Tools ISO 进度 |
| `InstallDialog` | macOS / Linux / Windows 装机进度 |

## 自绘组件清单 (CLAUDE.md UI 控件约束)

业务侧 (`UI/Content` `UI/Dialogs` `UI/IPSW` `UI/Shell`) **必须**用以下自绘组件, 不准退回 SwiftUI 原生。`UI/Style/**` 是组件实现层, 不受此约束。

| 需求 | 必用 | 禁用 |
|---|---|---|
| 下拉 / 单选 | `HVMFormSelect` (Style/Theme.swift) / `HVMNetModeSegment` | `Picker` / `Menu` |
| 按钮 | `PrimaryButtonStyle` / `GhostButtonStyle` / `IconButtonStyle` / `HeroCTAStyle` / `PillAccentButtonStyle` 五选一 (Content/Buttons.swift) | 裸 `Button` 无 `.buttonStyle(...)` (list row `.plain` 例外) |
| 输入框 | `HVMTextField` (Style/HVMTextField.swift) | `TextField` / `SecureField` / `.textFieldStyle(.roundedBorder)` |
| 开关 | `HVMToggle` (Style/HVMToggle.swift) | `Toggle` |
| Modal 弹窗 | `HVMModal` 容器 | 业务侧自拼 `ZStack(蒙底 + 卡片)` |
| Section 卡片 | `TerminalSection(title) { ... }` (Style/Theme.swift) | 自画"标题 + 卡片"复读 |
| 弹出锚点定位 | `HVMPopupPanel` (Style/HVMPopupPanel.swift, `HVMFormSelect` 内部用) | — |

新增"自绘 X" 必须放 `app/Sources/HVM/UI/Style/HVMX.swift` 并把 CLAUDE.md 清单加一行。

## 创建向导 (`CreateVMDialog`)

- **类型选择**: macOS (VZ) / Linux (默认 VZ, 可切 QEMU) / **Windows arm64 (实验性: QEMU 后端)** — Windows 选项必须显式标"实验性 (QEMU 后端)" + 强制 `engine=qemu`, 缺 QEMU 产物 (`make qemu` 未跑) 时灰掉并提示
- **基础参数**: 名称 / CPU / 内存 / 主盘 GiB
- **安装源**:
  - macOS: 走 `IpswCatalogPicker` + `IpswFetchDialog` (Use Latest / Choose Version / Browse)
  - Linux: 走 `OSImagePickerDialog` 选 `OSImageCatalog` 7 发行版 (Ubuntu 24.04 / 22.04 LTS / Debian 13 / Fedora 44 / Alpine 3.20 / Rocky 9 / openSUSE Tumbleweed) 或自填 ISO 路径; 已下载有 cached 标记
  - Windows: 自家提供 ISO 路径 (Windows ISO 不入 catalog, 走 custom URL 兜底); 创建过程会触发 `VirtioWinFetchDialog` 按需下载 virtio-win 驱动 ISO 到 `cache/virtio-win/`
- **网络**: `HVMNetModeSegment` 选 NAT / Bridged / Shared / Host (Bridged / Shared / Host 只 QEMU 后端可选, VZ bridged 等 entitlement 审批)
- **Bundle 位置**: 默认 `~/Library/Application Support/HVM/VMs/<name>.hvmz`
- **确认**: 摘要展示全部参数, 点 `创建` 落盘 `config.yaml` (schema v2) + 进入装机流程

## 多 VM 并发与 RunningTabsBar

- 同一时刻可启动多台 VM, 每台 VM 一个 `VMHost` 子进程, GUI 主进程通过 IPC 拉取状态
- `RunningTabsBar` 列出所有 running VM, 切换"主窗口当前显示哪一台 guest"
- 切到非当前 VM 嵌入画面隐藏 (子进程不停), 切回再显
- 同时只有一个 VM 处于嵌入显示, 其他可用 detached 独立窗口

## 输入捕获

- 鼠标进入 framebuffer 自动捕获, 输入直发 guest
- `Cmd+Control` 释放捕获 (跟 VZVirtualMachineView 一致), 释放时把 stuck modifier / pressed key 全部 keyUp 防卡键
- 释放后点 framebuffer 任意位置重新捕获

### macOS 风快捷键 cmd→ctrl 映射

QEMU 后端 `FramebufferHostView` 默认 `macStyleShortcuts = true` (跟 `VMConfig.macStyleShortcuts` 同步):

- `Cmd+C/V/A/Z/X/T/W` 等 host cmd 组合 → 映射成 guest `ctrl+...` qcode (`cmdQcode = "ctrl"`), 让 macOS 用户用 macOS 习惯快捷键操作 Linux/Windows guest
- `macStyleShortcuts = false` 时退回原生 `meta_l` (Win 键), 完全裸传
- 副作用: cmd 由 down→up 时给所有 stuck 字符键补 keyUp; `cmdKeyUpMonitor` 拦截 macOS 原生"按住 .command 时字符 keyUp 不送 NSView"的已知行为, 避免 guest 卡键

## 剪贴板共享 (PasteboardBridge)

`HVMDisplayQemu/PasteboardBridge.swift` — host ↔ QEMU guest 双向 UTF-8 文本剪贴板桥, 走 `VdagentClient` CLIPBOARD 通道:

- host 端 `NSPasteboard.general` 监听 `changeCount`, host 复制 → 推 guest
- guest 端 vdagent 推回 → 写 host pasteboard
- 走 `lastWrittenChangeCount` 去抖, 避免环回
- detached 窗口 toolbar 有 clipboard toggle 控制开关; IPC `clipboard.setEnabled` 可远程切换
- macOS guest 直接走 Apple Virtualization 自带 pasteboard 通道, 无需此桥

## ErrorDialog 与错误队列

`ErrorPresenter` 单例 (`AppModel.errors`), 队列排队 — 前一个关掉再弹下一个。details 折叠展示, 等宽字体, 可复制。所有业务侧报错统一 `errors.present(...)`, **任何地方都不能用 `NSAlert`**。

## 设置 / 网络面板

- 没有独立 Settings 窗口, 配置在 `EditConfigDialog` 内
- `VMSettingsNetworkSection` (含 ModePickers / NICCard / VmnetDaemon 子分): 网络 NIC 卡片化展示, 一键安装 socket_vmnet daemon (走 `osascript do shell script with administrator privileges` 弹原生 Touch ID, 详见 NETWORK.md)

## 不做什么

1. 不做托盘菜单业务管理 — status item 仅显隐主窗口入口, 不在 menu 里展示 VM 列表
2. 不做浅色主题 / 主题切换
3. 不做自定义缩放 / 字体大小
4. 不做 Touch Bar 支持
5. 不做多窗口同时操作同一 VM (一个 VM 只能在嵌入或 detached 之一)

## 相关文档

- [DEBUG_PROBE.md](DEBUG_PROBE.md) — hvm-dbg, GUI 操作的可编程替代
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — VZ / QEMU display 与输入设备
- [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) — HDP framebuffer 协议
- [NETWORK.md](NETWORK.md) — socket_vmnet daemon 装/卸
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 装机向导背后流程

---

**最后更新**: 2026-05-04
