# GUI 设计 (`HVM.app`)

## 目标

- 提供一个简洁的 macOS 原生 GUI 管理多台 VM
- 严格黑色主题, 不跟随系统
- 极简交互: 列表 / 创建向导 / 运行窗口 / 设置, 没了

## 技术栈

- **SwiftUI** 为主, 窗口层面的细节用 AppKit(自定义 NSWindow mask)
- **@Observable** (Swift 5.9+) 做 ViewModel
- **全主线程**: UI 逻辑在 `@MainActor`
- 不引入 Combine / ReactiveSwift / TCA

## 主题规范

### 色板

| 用途 | 颜色 | 值 |
|---|---|---|
| 主背景 | `hvm.bg.primary` | `#0A0A0C` |
| 次级背景 (卡片) | `hvm.bg.secondary` | `#141418` |
| 分割线 | `hvm.separator` | `#25252A` |
| 主文本 | `hvm.text.primary` | `#F0F0F3` |
| 次级文本 | `hvm.text.secondary` | `#8A8A92` |
| 禁用文本 | `hvm.text.disabled` | `#4A4A52` |
| 强调色 (按钮 / 高亮) | `hvm.accent` | `#5B8DFF` |
| 成功 (running) | `hvm.status.ok` | `#4CD964` |
| 警告 | `hvm.status.warn` | `#FFB020` |
| 错误 | `hvm.status.err` | `#FF4A4A` |

在 `HVMCore/Theme.swift` 里用 `Color(name:)` 查色, 不散写 hex。

### 不跟随系统

```swift
// HVMApp.swift
WindowGroup {
    MainView().preferredColorScheme(.dark)
}
```

`NSApp.appearance = NSAppearance(named: .darkAqua)` 全局锁死。系统切到 Light 时, HVM 仍黑。

### 字体

- 正文 SF Pro Text 13pt
- 标题 SF Pro Display 17pt / 22pt
- 等宽(日志、IP 显示) SF Mono 12pt

## 窗口结构

### 主窗口

- 标题栏: `HVM` + VM 总数(例 `HVM · 3 VMs`)
- 尺寸: 默认 960×600, 最小 720×480
- 不允许全屏(`collectionBehavior.remove(.fullScreenPrimary)`), 避免误入全屏遮挡运行中的 VM 子窗口
- 不支持 tab 合并(`tabbingMode = .disallowed`)

### 左右布局

```
┌───────────────────────────────────────────────────┐
│ ≡  HVM · 3 VMs                              [+]  │
├───────────────┬───────────────────────────────────┤
│ foo           │                                   │
│ (running)     │                                   │
│ ─────────     │        VM 详情 / 缩略图            │
│ ubuntu-2404   │                                   │
│ (stopped)     │        [Start] [Stop] [Open]      │
│ ─────────     │                                   │
│ macOS-seq     │                                   │
│ (paused)      │                                   │
│               │                                   │
│               │                                   │
│               │                                   │
│               │                                   │
│  [+] New VM   │                                   │
└───────────────┴───────────────────────────────────┘
```

- 左栏 240pt 宽, VM 列表, 支持上下键盘导航
- 右栏根据选中 VM 状态动态切换:
  - 选中 **stopped / paused**: 显示缩略图、配置摘要、主操作按钮
  - 选中 **running 且当前为嵌入态**: 显示 guest 实时画面(live `VZVirtualMachineView`)
  - 选中 **running 且当前为独立窗口态**: 显示占位 "正在独立窗口中运行" + 配置摘要 + 操作按钮 + [嵌入] 按钮
- 右上角 `+` 快速启动新建向导

### VM 显示窗口(独立 ⇄ 嵌入)

运行中的 VM **默认打开独立窗口**。独立窗口关闭按钮的行为**不是关闭 VM**, 而是**将 guest 画面嵌入主窗口右栏**, VM 持续运行。真正要停机必须显式点 `Stop` / `Kill`。

#### 独立窗口态

```
┌───────────────────────────────────────────────────┐
│ [✕][—][▢]  foo — Ubuntu 24.04 arm64 · running    │
├───────────────────────────────────────────────────┤
│                                                   │
│                                                   │
│           guest screen frame buffer               │
│              (VZVirtualMachineView)               │
│                                                   │
│                                                   │
├───────────────────────────────────────────────────┤
│ 4 CPU · 8 GiB · nat · 64 GiB    [Stop] [Kill] [⎇]│
└───────────────────────────────────────────────────┘
```

- 左上 `[✕]` **语义重载为 "嵌入主窗口"**: 点击后窗口关闭, 但 VM 进程不退出, 画面无缝转移到主窗口右栏
- `[—]` 最小化, `[▢]` 全屏(此窗口允许全屏, 区别于主窗口)
- 底部 status bar 配置摘要 + 操作按钮: `Stop`(软关机) / `Kill`(强关机) / `[⎇]`(保持独立, 见下)
- 关闭整个 `HVM.app` 时, 独立窗口会自动转嵌入态后再退出

#### 嵌入态

VM 画面占满主窗口右栏, 顶部一条 40pt status bar:

```
┌───────────────┬───────────────────────────────────┐
│ foo  ●        │ foo · running · 1h23m    [↗ 弹出] │
│ (running)     ├───────────────────────────────────┤
│ ─────────     │                                   │
│ ubuntu-2404   │                                   │
│ (stopped)     │       guest frame buffer          │
│               │         (嵌入模式)                 │
│               │                                   │
│               ├───────────────────────────────────┤
│               │ 4C · 8G · nat    [Stop] [Kill]    │
└───────────────┴───────────────────────────────────┘
```

- `[↗ 弹出]` 把画面重新弹成独立窗口, 是 `[✕]` 的反向操作
- 切换到列表其他 VM, 嵌入画面隐藏(但 VMHost 进程不停), 切回来再显示
- 同时只有一个 VM 处于嵌入显示, 其他正在运行的 VM 要么独立窗口, 要么在右栏占位里显示 "[嵌入] 按钮切到此 VM"

#### 关闭 VM 的所有入口

显式停机入口, 缺一不可:

1. 独立窗口底部 `Stop` / `Kill`
2. 嵌入态右栏底部 `Stop` / `Kill`
3. 主窗口左栏列表项右键菜单 `Stop` / `Kill`
4. 详情面板(stopped VM 以外的状态) 按钮
5. `hvm-cli stop/kill <vm>`

`Stop` 二次确认 = 否(软关机无破坏性, 让 guest 自己收尾); `Kill` 二次确认 = 是(可能丢数据)。

#### 状态切换摘要

```
                      start VM
                         │
                         ▼
                 ┌──────────────┐
                 │ 独立窗口态    │◀──── [↗ 弹出]
                 └──────┬───────┘
                        │ [✕]
                        ▼
                 ┌──────────────┐
                 │  嵌入态       │
                 └──────┬───────┘
                        │ [Stop] / [Kill]
                        ▼
                 ┌──────────────┐
                 │   stopped    │
                 └──────────────┘
```

#### 输入捕获

- 鼠标进入 guest view 自动捕获(pointer lock + 键盘重定向)
- **`Cmd+Control` 释放捕获**, 回到 host
- 释放后右上角弹短暂提示 `已释放, 点画面重新进入`
- 嵌入态同样支持捕获, 不因"画面在主窗口"而弱化

#### 粘贴板

- macOS guest: 依赖 guest 内 `Virtualization` 相关服务(见 VZ 文档), 开箱可用
- Linux guest: 需 guest 内安装 `spice-vdagent` 或等价组件, MVP 不强求, 用户自己配

## 弹窗约束(必须遵守)

**全项目所有弹窗统一规范**, GUI.md 是权威。

### 强制项

1. **只能通过右上角 X 按钮关闭**
2. **禁止点击遮罩层(背景暗色区域)关闭**
3. **禁止按 `Esc` 键关闭**(会被误触)
4. **禁止使用 `NSAlert`, `.alert()` SwiftUI modifier**
5. 弹窗必须显式有一个 `[关闭]` 或 `[取消]` 按钮, 对应 X 按钮功能

### 实现

封装 `HVMModalContainer`:

```swift
public struct HVMModalContainer<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    let content: () -> Content

    public var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .allowsHitTesting(false)            // 关键: 遮罩不拦截点击, 也不响应
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color("hvm.separator"))

                content()
                    .padding(16)
            }
            .background(Color("hvm.bg.secondary"))
            .cornerRadius(10)
            .frame(width: 480)
        }
    }
}
```

关键: `Color.black.opacity(0.6).allowsHitTesting(false)` 确保遮罩不拦截点击, 也就不存在"点遮罩关闭"的可能性。

### 键盘

- `Cmd+W` 关闭(通用快捷键, 等效点 X)
- `Esc` **不绑定**, 因为容易误触丢失输入数据

## ErrorDialog: 统一错误入口

**禁止在任何地方用 `NSAlert`**。所有错误走:

```swift
public struct HVMErrorDialog: View {
    public struct Model {
        public var title: String
        public var message: String
        public var details: String?          // 折叠显示完整栈/errno
        public var primaryAction: (label: String, handler: () -> Void)?
        public var secondaryAction: (label: String, handler: () -> Void)?
    }
    // ...
}
```

### 行为

- 标题与 message 必填, details 可折叠
- details 固定等宽字体, 可复制(`TextSelection(.enabled)`)
- `primaryAction` 默认文案 `好`
- 只显示一个 ErrorDialog, 连续多个错误队列排队, 前一个关掉再弹下一个

### 调用

```swift
@Environment(\.errorPresenter) var error

error.present(.init(
    title: "启动 VM 失败",
    message: "磁盘被另一个进程占用",
    details: "bundle: /Users/me/VMs/foo.hvmz\npid: 47820",
    primaryAction: ("好", {})
))
```

`errorPresenter` 是 App 级单例, 注入 Environment。

## 创建向导

多步骤向导, 单窗口 480 宽固定, 下一步/上一步/取消三按钮。

### 步骤

1. **类型选择**: macOS / Linux(其余灰色不可点, 旁边说明"VZ 不支持")
2. **基础参数**:
   - 名称(默认填 `new-vm-<8hex>`, 允许改)
   - CPU 核心数(滑块, 默认 `physicalCoresHalf`)
   - 内存(滑块, 默认 4 GiB, 下限 1, 上限 `physicalMem - 4`)
   - 主盘大小(滑块, 默认 64 GiB, 下限 16, 上限剩余空间 - 10)
3. **安装源**:
   - macOS: IPSW 文件选择, 或自动下载按钮(显示进度)
   - Linux: ISO 文件选择
4. **网络**: NAT(默认) / Bridged(灰色当 entitlement 未就绪)
5. **Bundle 位置**: 默认 `~/Library/Application Support/HVM/VMs/<name>.hvmz`, 允许改到其他目录
6. **确认**: 摘要展示全部参数, 点 `创建` 落盘 + 进入安装流程

### 取消

- 任何步骤点 X 或 `取消` → 弹二次确认 `放弃创建?`(仍走 `HVMModalContainer`)
- 确认后不留下半成品 bundle

## VM 列表项

```
┌──────────────────────────────────────┐
│ ● foo                     4C · 8G    │
│   Linux · ubuntu-2404 · running      │
└──────────────────────────────────────┘
```

- 左侧圆点颜色 = 状态(绿 running / 灰 stopped / 黄 paused / 红 error)
- 右上角配置摘要
- 第二行: guestOS · displayName · runState

## 详情面板

右栏选中 VM 后展示:

```
[缩略图 320×200]

foo
Linux · ubuntu 24.04 arm64

状态: running · 已运行 1 小时 23 分
CPU:  4 核
内存: 8 GiB
主盘: 64 GiB (已占用 12 GiB)
网络: NAT · 02:AB:CD:EF:12:34
IP:   192.168.64.5           (guest agent 汇报)

[启动]  [停止]  [打开窗口]  [...]
```

- `[...]` 二级菜单: 编辑配置、重启、强制关机、在 Finder 中显示、删除
- 删除走二次确认 ErrorDialog 风格

## 设置窗口

独立窗口 520×400:

- 常规: 默认 bundle 目录、日志级别
- 网络: 桥接 entitlement 状态(只读展示, 链接到 ENTITLEMENT.md)
- 缓存: 清理 IPSW 缓存按钮
- 关于: 版本、commit hash、team ID(留空, 遵守安全约束不显示)

## 深色 title bar

SwiftUI 默认 title bar 会跟随系统。强制:

```swift
.background(WindowAccessor { window in
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: .darkAqua)
})
```

## 无障碍

- 所有按钮有 `accessibilityLabel`
- VoiceOver 友好, 状态用文字(`running` / `stopped`) 而非仅颜色
- 键盘可完整操作, 不依赖鼠标

## 国际化

- 文案走 `Localizable.strings`, 默认中文
- 英文翻译延后(不阻塞 MVP), 占位 key 直接用中文短语

## 性能

- VM 列表 ≤ 500 项时全量渲染, 不做虚拟滚动
- 缩略图异步加载, 不阻塞主线程
- frame buffer 渲染由 VZ 自己负责, GUI 侧只承载 `VZVirtualMachineView`

## 不做什么

1. **不做托盘菜单 / menu bar extra**: 单窗口应用, 不驻留
2. **不做多窗口同时操作同一 VM**
3. **不做浅色主题 / 主题切换**
4. **不做自定义缩放 / 字体大小**
5. **不做 Touch Bar 支持**(Touch Bar 已 EOL)

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| F1 | VM 列表右键菜单项 | 最小集: 启动/停止/打开/删除, 后续按需加 | M2 |
| F2 | 创建向导是否支持"克隆现有 VM" | MVP 不做, 用户 clonefile 手动克隆 | 已决 |
| F3 | 运行窗口独立 vs 嵌入主窗口 | 默认独立, 关闭按钮切嵌入, 支持双向切换 | 已决 |
| F4 | 嵌入态切到其他 VM 时是否保留 view | 仅保留 VMHost 进程, view 隐藏; 切回再显示 | 已决 |
| F5 | 是否支持多 VM 同时嵌入(分屏) | MVP 只支持一个嵌入, 其他用独立窗口 | 已决 |

## 相关文档

- [ERROR_MODEL.md](ERROR_MODEL.md) — ErrorDialog 数据模型
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — VZVirtualMachineView 与输入
- [ARCHITECTURE.md](ARCHITECTURE.md) — 进程模型(HVMHost)

---

**最后更新**: 2026-04-25
