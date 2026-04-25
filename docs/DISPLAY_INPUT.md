# 显示与输入 (`HVMDisplay`)

## 目标

- 在 Mac 上呈现 guest 的屏幕画面
- 把 host 的键鼠输入传到 guest
- 与 [GUI.md](GUI.md) 的独立/嵌入窗口交互配合
- 给 `hvm-dbg` 的截屏 / 注入能力提供底层

## 设备矩阵

VZ 提供的显示与输入相关类:

| 类 | 用途 | 用在 |
|---|---|---|
| `VZMacGraphicsDeviceConfiguration` | macOS guest 的图形设备 | macOS guest |
| `VZVirtioGraphicsDeviceConfiguration` | 通用 virtio-gpu | Linux guest |
| `VZMacGraphicsDisplayConfiguration` | 每个显示器的分辨率 / ppi | macOS guest(支持多屏) |
| `VZVirtioGraphicsScanoutConfiguration` | virtio scanout | Linux guest |
| `VZUSBKeyboardConfiguration` | USB 键盘 | 所有 guest |
| `VZMacKeyboardConfiguration` | macOS guest 原生键盘(macOS 14+) | macOS guest(优先) |
| `VZUSBScreenCoordinatePointingDeviceConfiguration` | 绝对坐标鼠标 | 所有 guest |
| `VZMacTrackpadConfiguration` | macOS guest trackpad | macOS guest |
| `VZVirtualMachineView` | AppKit NSView, 渲染 frame buffer + 转发输入 | GUI |

## 显示配置策略

### macOS guest

```swift
let display = VZMacGraphicsDisplayConfiguration(
    widthInPixels:  1920,
    heightInPixels: 1080,
    pixelsPerInch:  220     // 与 MacBook Pro Retina 一致
)
let graphics = VZMacGraphicsDeviceConfiguration()
graphics.displays = [display]
```

- 默认单显示器 1920×1080 @ 220 ppi
- 允许多显示器, 每多一屏加一个 display 到数组(MVP 只开一屏, 留扩展口)

### Linux guest

```swift
let scanout = VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)
let graphics = VZVirtioGraphicsDeviceConfiguration()
graphics.scanouts = [scanout]
```

- Linux virtio-gpu 只支持单 scanout? 不, VZ 允许多 scanout, 但驱动支持看 kernel 版本。MVP 单 scanout
- 动态分辨率: 用户改 host 窗口尺寸, guest 内分辨率不会自动跟随 — VZ 不提供 resize event。若需要改分辨率必须 guest 内改

### 分辨率选择

向导允许用户选:

- `720p` (1280×720)
- `1080p` (1920×1080)  — 默认
- `1440p` (2560×1440)
- `Retina` (3024×1890, 约 14" MBP 原生)
- 自定义

不提供"跟随窗口", 因为代价高且易出 bug。

## 输入设备

### 键盘

**macOS guest(macOS 14+)** 优先用 `VZMacKeyboardConfiguration`:
- 原生键盘行为, 支持 Fn / media key / Spotlight 快捷键
- 比 USB 键盘更少的转换损失

**Linux guest / 老 macOS** 用 `VZUSBKeyboardConfiguration`:
- 标准 HID 键盘
- Mac 上的修饰键映射: Command → Meta / Super; Option → Alt; Control → Control

### 指点设备

**macOS guest** 用 `VZMacTrackpadConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration`:
- Trackpad 支持手势、多指、力度
- USB pointing 兜底绝对坐标

**Linux guest** 只用 `VZUSBScreenCoordinatePointingDeviceConfiguration`:
- 绝对坐标 = host 鼠标位置直接映射到 guest 屏幕坐标, 不需要"对齐/鼠标逃逸"
- 滚轮 / 双击 / 右键都支持

VZ 不提供相对坐标鼠标, 不支持 guest 内 FPS 游戏的 `pointer grab` 式鼠标。

### 音频

VZ 支持但默认关:

```swift
// config 里 audio: true 才加
let output = VZVirtioSoundDeviceOutputStreamConfiguration()
output.sink = VZHostAudioOutputStreamSink()
let audio = VZVirtioSoundDeviceConfiguration()
audio.streams = [output]
```

## 窗口容器

### 嵌入态 (M2 唯一显示模式)

`HVMView` (VZVirtualMachineView 子类) 直接挂在主窗口右栏 (`DetailContainerView`) 作为 AppKit subview, 不经 SwiftUI `NSViewRepresentable` 包装。原因: SwiftUI 在 body re-render 时会对承载的 NSView 做 detach/reattach, 导致 VZ Metal drawable 失效 → 黑屏。

```swift
// DetailContainerView.swift (running 状态构造)
let hvmView = session.attachment.view  // session 持有的同一个 VZVirtualMachineView
addSubview(hvmView)                     // 直挂, 不经 hosting
```

关键设置:

- `capturesSystemKeys = true`: Cmd+Tab / Cmd+Space 等被转发给 guest, 不触发 host
- `automaticallyReconfiguresDisplay = false` 在 MVP 固定分辨率
- `viewDidMoveToWindow` 钩子: 进入 window 时通知 `VMSession.bindVMToView`, 此时 `view.virtualMachine` 才被赋值 (Metal drawable 创建的必要时机, 见 [VZ_BACKEND.md](VZ_BACKEND.md))

### 独立窗口 (M2 已弃用)

原计划支持"独立窗口 ⇄ 嵌入态"切换, 通过 `removeFromSuperview()` 把同一个 `VZVirtualMachineView` 在两个 NSWindow 间 reparent。

实测**这条路走不通**: VZ 的 `CAMetalLayer` 在 view 离开 window hierarchy 时 drawable 被销毁, 重新加进新 window 也不会自动重建, guest 屏幕变黑且不可恢复。M2 polish 阶段 (commit 3cc9656) 已移除独立窗口入口, 现在所有 VM 只有嵌入主窗口一种显示形式。

未来若要再上独立窗口, 必须给独立窗口起**独立的 `VZVirtualMachineView` 实例** (`view2.virtualMachine = vm`), 不复用嵌入态那个 view; 同一 VM 由两个 view 同时渲染 VZ 也支持 (内部 frame buffer 多 tap)。

### 键盘 first responder 释放

- 鼠标进入 view → view becomes first responder, 键盘事件直接给 VZ
- **`Cmd + Control`** 组合释放**键盘** first responder, 后续按键不再给 guest
- 再次点画面 → 重新捕获
- 鼠标用 `VZUSBScreenCoordinatePointingDevice` (绝对坐标), **没有 grab 概念**, 鼠标随时可以离开 view, 不需要"释放"

实现 (`Sources/HVMDisplay/HVMView.swift`):

```swift
override func flagsChanged(with event: NSEvent) {
    let combo: NSEvent.ModifierFlags = [.command, .control]
    if event.modifierFlags.intersection(combo) == combo {
        window?.makeFirstResponder(nil)
        onReleaseCapture?()
        return
    }
    super.flagsChanged(with: event)
}
```

### 弹窗期间输入挂起

主窗口出现 modal-style overlay (创建向导 / ErrorDialog) 时, 必须把 VZ view 的输入挂起, 否则:

1. **光标消失**: VZVirtualMachineView 在 `mouseEntered` / `mouseMoved` 里走全局 `NSCursor.hide()` (不是 cursor rect), AppKit 上层 cursor rect 压不过 — 即使 overlay 视觉上盖在前面, VZ view 的 `NSTrackingArea` 仍按几何位置触发 hide, 鼠标在 dialog 区域看不见
2. **键盘冲撞**: VZ first responder 还在, 键盘输入仍然进 guest

机制: `HVMView.inputSuspended: Bool` (Sources/HVMDisplay/HVMView.swift) 拨到 `true` 时:

- 所有 mouse* / scrollWheel / flagsChanged / cursorUpdate 跳过 `super` → guest 不再收到 host 输入, VZ 也不会再 hide cursor
- 设置瞬间一次性多调几次 `NSCursor.unhide()` + `NSCursor.arrow.set()`, 抵消之前累计的 hide (NSCursor 是平衡计数, 不知 VZ 调了几次)

驱动: `MainWindowController.observeDialogActivity` 用 `withObservationTracking` 把 `model.showCreateWizard || errors.current != nil` 同步给所有 `model.sessions.values` 的 `attachment.view.inputSuspended`。

## 截图 / frame buffer 访问

VZ 未公开"截当前 frame"API (至少到 macOS 15)。实现走 AppKit:

```swift
extension VZVirtualMachineView {
    func captureFrame() -> NSImage? {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
```

限制:

- 需要 view 已加到 window 且有效的 CALayer
- 嵌入态或独立窗口都行, view 被隐藏 / 最小化时可能拿到空白或过期缓存
- `hvm-dbg screenshot` 因此要求 VM view 至少被渲染过一次

## 缩略图更新

VMHost 定时(每 10 秒)截图, 写入 `bundle/meta/thumbnail.png`, GUI 列表读取。降采样到 512×320 避免大文件。

## 剪贴板

**macOS guest 与 host 剪贴板**: VZ 原生支持(macOS 14+), 开箱可用。

**Linux guest**: 需要 `spice-vdagent` 或等价组件。VZ 的 virtio-serial 通道暴露给 guest, 剪贴板同步需额外 daemon。MVP 不强制, 未来 [DEBUG_PROBE.md](DEBUG_PROBE.md) 里的 H1 再评估。

## 拖拽文件入 guest

VZ 不支持。用户要传文件走:

- 共享目录 (VirtioFS, [VZ_BACKEND.md](VZ_BACKEND.md) 已有)
- ssh / scp 经 NAT 网络
- 挂 USB mass storage

## HiDPI

- macOS guest 原生 HiDPI
- Linux guest 需 guest 内配置(Xorg DPI / Wayland scale)
- host 端 `VZVirtualMachineView` 自动处理 retina backing, 不用我们操心

## 多显示器(未来)

VZ 允许 macOS guest 多显示器, Linux 通过多 scanout(驱动支持有限)。MVP 不做, 留扩展:

- `MacOSSpec.displays: [DisplaySpec]` 未来新字段
- GUI 显示器管理 UI 独立一页

## 性能注记

- VZ frame buffer 走 Metal 加速, 性能接近原生
- 嵌入/独立切换**不重建 view**, 避免重新分配 Metal 资源
- 截图在 main actor 上做, 频繁截图(例: `hvm-dbg` 的 agent loop 每秒截一次)会占用主线程, 限流到最多 10 FPS

## 不做什么

1. **不做相对坐标鼠标**(VZ 不提供)
2. **不做 pointer lock / 鼠标逃逸 FPS 模式**
3. **不做手势识别拦截**(Touch Bar / trackpad force-click 直接透传)
4. **不做自定义光标 / 鼠标指针样式切换**
5. **不做录屏 / 屏幕录制输出**: 用 macOS 系统自带或第三方即可
6. **不做窗口镜像到外接显示器**(用户把窗口拖过去就行, 系统处理)

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| K1 | Linux guest 是否默认启用 `VZVirtioConsoleDeviceConfiguration` 第二通道给 clipboard agent | MVP 不做, M3 若加剪贴板同步再加 | M3 |
| K2 | macOS guest 是否固定 220ppi | 默认 220, 允许用户改 | 已决 |
| K3 | 是否在 GUI 里暴露分辨率切换 | MVP 只在创建向导里选, 运行后不改 | 已决 |
| K4 | frame buffer 截图的替代方案(若 `cacheDisplay` 性能不够) | 后续评估 CAMetalLayer + presentsWithTransaction | 有性能问题再说 |

## 相关文档

- [GUI.md](GUI.md) — 独立/嵌入窗口交互
- [VZ_BACKEND.md](VZ_BACKEND.md) — 设备挂载时机
- [DEBUG_PROBE.md](DEBUG_PROBE.md) — 截屏与输入注入

---

**最后更新**: 2026-04-25
