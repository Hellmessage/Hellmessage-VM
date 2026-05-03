# 显示与输入 (`HVMDisplay` + `HVMDisplayQemu`)

VZ 与 QEMU 两个后端走完全不同的显示通路, 但对 GUI 上层暴露一致的"挂在主窗口的 NSView" 抽象.

## 目标

- 把 guest 屏幕渲染到 host 上的 NSView
- 把 host 键盘 / 鼠标 / 滚轮事件转发给 guest
- 与 [GUI.md](GUI.md) 的嵌入主窗口模式配合
- 给 `hvm-dbg` 截屏 / 注入能力提供底层
- 双向剪贴板 (UTF-8 文本) — 仅 QEMU 后端走 vdagent, VZ macOS guest 走 VZ 自带

## 模块拆分

| 模块 | 后端 | 职责 |
|---|---|---|
| `HVMDisplay/HVMView` | VZ | `VZVirtualMachineView` 子类, 挂主窗口右栏 |
| `HVMDisplay/EmbedContainer` | VZ | `ViewAttachment` + `EmbeddedVMContent` (NSViewRepresentable) |
| `HVMDisplay/HIDKeyMap` + `KeyboardEmulator` | VZ (dbg) | macOS keycode → VZ 注入 |
| `HVMDisplay/MouseEmulator` | VZ (dbg) | hvm-dbg 注入鼠标 |
| `HVMDisplay/ScreenCapture` | VZ | NSView `cacheDisplay` 截屏 → PNG |
| `HVMDisplay/ThumbnailGenerator` | 共用 | 缩略图 down-scale 写 `bundle/meta/` |
| `HVMDisplay/OCREngine` + `OCRTextSearch` | dbg | Vision framework, 调试用文本检索 |
| `HVMDisplay/BootPhaseClassifier` | dbg | 启动画面阶段识别 |
| `HVMDisplayQemu/DisplayChannel` | QEMU | HDP v1.0.0 client (AF_UNIX + SCM_RIGHTS) |
| `HVMDisplayQemu/HDPProtocol` | QEMU | HDP wire 类型定义 |
| `HVMDisplayQemu/FramebufferRenderer` | QEMU | shm BGRA → CGImage |
| `HVMDisplayQemu/FramebufferHostView` | QEMU | NSView 容器, 嵌入主窗口右栏 |
| `HVMDisplayQemu/InputForwarder` | QEMU | QMP `input-send-event` 键鼠转发 |
| `HVMDisplayQemu/NSKeyCodeToQCode` | QEMU | macOS keycode → QEMU qcode |
| `HVMDisplayQemu/VdagentClient` | QEMU | virtio-serial 上的 spice-vdagent client (resize / clipboard) |
| `HVMDisplayQemu/PasteboardBridge` | QEMU | NSPasteboard ↔ vdagent clipboard |
| `HVMScmRecv` | QEMU | C 侧 `recvmsg` SCM_RIGHTS fd 接收 (Swift 不能直接做) |

## VZ 后端

### 设备挂载 (`ConfigBuilder`)

| 类 | 用途 |
|---|---|
| `VZMacGraphicsDeviceConfiguration` + `VZMacGraphicsDisplayConfiguration` | macOS guest, 1920×1080 @ 220 ppi 单显示器 |
| `VZVirtioGraphicsDeviceConfiguration` + `VZVirtioGraphicsScanoutConfiguration` | Linux guest, 1024×768 单 scanout |
| `VZMacKeyboardConfiguration` | macOS guest, 比 USB 键盘转换损失小 |
| `VZUSBKeyboardConfiguration` | Linux guest |
| `VZMacTrackpadConfiguration` | macOS guest, 支持手势 / 多指 / 力度 |
| `VZUSBScreenCoordinatePointingDeviceConfiguration` | macOS / Linux 都加, 绝对坐标兜底 |

VZ 不暴露相对坐标鼠标, 不支持 guest 内 FPS 游戏的 pointer grab 模式.

分辨率在创建向导固定 (1080p), 运行后不暴露切换 — 跟随 host 窗口需要 `automaticallyReconfiguresDisplay` + guest 端 X/Wayland 响应, 当前 fbcon / installer 阶段会出现大片黑边, 暂关.

### `HVMView` (VZVirtualMachineView 子类)

`app/Sources/HVMDisplay/HVMView.swift`:

- `capturesSystemKeys = true`: Cmd+Tab / Cmd+Space 等系统快捷键也转发给 guest
- `automaticallyReconfiguresDisplay = false`: 固定 scanout, 装机阶段视觉稳定
- `viewDidMoveToWindow` → `onEnteredWindow` 钩子, 此时 `view.virtualMachine = vm` 才能让 Metal drawable 创建
- **不碰** `wantsLayer` / `layer.contentsGravity`: VZ 内部管 CAMetalLayer, 外部改会让 drawable 失效 → 黑屏

### 嵌入主窗口

唯一显示模式 (M2 polish 后已弃用独立窗口). `EmbedContainer.swift`:

```swift
public final class ViewAttachment {
    public let view: HVMView          // VMSession 持有同一引用
}

public struct EmbeddedVMContent: NSViewRepresentable {
    public func makeNSView(context: Context) -> HVMView { attachment.view }
    public func updateNSView(_ nsView: HVMView, context: Context) {}
}
```

SwiftUI `NSViewRepresentable` 直接交出 `HVMView`, 不再包中间 container — 之前的 `DetailContainerView` 在 SwiftUI body re-render 时被 detach/reattach, Metal drawable 失效黑屏. 现在 hosting 全权负责 view 的 window lifecycle, VZ Metal 不再受打扰.

### 键盘 first responder 与 release

- 鼠标进入 view → first responder, 键盘事件给 VZ
- **`Cmd + Control`** combo 释放键盘捕获, 后续按键给 host
- 再次点画面回到 VZ
- 鼠标走绝对坐标 (`VZUSBScreenCoordinatePointingDevice`), **没有 grab 概念**, 鼠标随时可移出 view

实现 `HVMView.flagsChanged`: 检测 `[.command, .control]` → `window.makeFirstResponder(nil)` + 调 `onReleaseCapture`.

### Caps Lock 同步

macOS 物理 Caps Lock 只发 `flagsChanged` 不发 keyDown, VZ 默认收不到 → guest 始终大写关. `HVMView` 镜像 `hostCapsLockOn`, flagsChanged 翻转时合成 HID 0x39 一次按下/抬起送 guest. 第一次 keyDown 之前补一次"初始同步": app 启动时若已是 Caps On, guest 先 toggle 跟上.

### 弹窗期间输入挂起

主窗口出现 modal-style overlay (创建向导 / ErrorDialog) 时, 必须挂起 VZ view 输入. 否则:

1. **光标消失**: VZ 在 `mouseEntered` / `mouseMoved` 走全局 `NSCursor.hide()` (不是 cursor rect), AppKit 上层 cursor rect 压不过, 鼠标在 dialog 区看不见
2. **键盘冲撞**: VZ first responder 还在, 键盘进 guest

机制: `HVMView.inputSuspended: Bool` 拨 `true` 时:

- mouse* / scrollWheel / flagsChanged / cursorUpdate **跳过 super** → guest 不收 host 输入, VZ 也不再 hide cursor
- 立刻 `unhideCursorAggressively()` 多次 `NSCursor.unhide()` + `NSCursor.arrow.set()` (NSCursor 是平衡计数, 不知 VZ 调过几次)

`MainWindowController.observeDialogActivity` 用 `withObservationTracking` 把 `model.showCreateWizard || errors.current != nil` 同步给所有 session 的 `attachment.view.inputSuspended`.

`captureReleased` (Cmd+Ctrl 主动释放) 走相同机制, `inputBlocked = inputSuspended || captureReleased`. 用户点回 VZ view 内 (mouseDown) 自动 false.

### VZ 截屏 (`ScreenCapture`)

VZ 不公开"截当前 frame" API. 走 AppKit:

```swift
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: rep)
let image = NSImage(size: view.bounds.size).adding(rep)
```

限制:

- view 必须已加到 window 且有效的 CALayer (Metal drawable 在线)
- view 隐藏 / 最小化时拿到空白或过期缓存
- `hvm-dbg screenshot` 因此要求 VM view 至少被渲染过一次

### 缩略图

VMHost / GUI 定时截图, `ThumbnailGenerator` down-scale 到 ~512×320, 写 `bundle/meta/thumbnail.png`, 列表读取. 频率限制最多 ~10 FPS.

### macOS guest 剪贴板

VZ 自带 (macOS 14+), 开箱可用. 不需要 vdagent.

## QEMU 后端 (HDP)

### 总览

QEMU 显示走 HVM 自定义协议 **HDP (HVM Display Protocol) v1.0.0**, 由 patches/qemu/0002 引入.

```
QEMU host 进程  ──── -display iosurface,socket=<path> ────► AF_UNIX SOCK_STREAM
                                                            ├── HELLO 协商 (双向)
                                                            ├── SURFACE_NEW + SCM_RIGHTS shm fd
                                                            ├── SURFACE_DAMAGE 矩形
                                                            ├── CURSOR_DEFINE / CURSOR_POS
                                                            └── LED_STATE / RESIZE_REQUEST / GOODBYE
HVM GUI 主进程 ──── DisplayChannel + FramebufferRenderer ──► CALayer.contents = CGImage
```

POSIX shm (`shm_open`) 由 QEMU 端创建并 mmap; HDP 把 shm fd 通过 `SCM_RIGHTS` cmsg 给 host. host 端 `mmap` 只读映射, surface size 变化时旧 fd 自动失效, 等下一个 SURFACE_NEW. 协议规范见 [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md).

### 支持的显示设备

`patches/qemu/0003-hw-display-hvm-gpu-ramfb-pci.patch` 加了新设备 `hvm-gpu-ramfb-pci`: 单 PCI 设备同时挂 ramfb + virtio-gpu-pci, vendor/device id 复用 `0x1AF4/0x1050` 让 Windows `viogpudo.inf` 自动 match. 内部 dispatcher 按 `g->parent_obj.enable` 切:

- 0 → ramfb_display_update (UEFI / Win Setup / 没驱动的早期 OS 期)
- 1 → virtio-gpu cmd handler (viogpudo / Linux virtio-gpu 接管 dynamic resize)

`ui_info` 始终转给 virtio-gpu, vdagent / EDID 通路在 OS 期立刻拿到 host 尺寸 hint.

argv 选择由 `HVMQemu/QemuArgsBuilder` 按 guest 阶段决定:

- 装机阶段 (Linux / Win 都没驱动) → 单挂 `ramfb`
- Windows guest 装完驱动 + `windowsDriversInstalled=true` → `hvm-gpu-ramfb-pci`
- Linux guest 默认 virtio-gpu

### `DisplayChannel` (HDP host client)

`HVMDisplayQemu/DisplayChannel.swift`:

```swift
public final class DisplayChannel {
    public let events: AsyncStream<Event>   // helloDone / surfaceNew / damage / cursor* / ledState / disconnected

    public init(socketPath: String,
                hostCapabilities: HDP.Capabilities = .hostAdvertised)
    public func connect() async throws
    public func disconnect()
}
```

后台 read thread 持续收消息, `SCM_RIGHTS` fd 在 `SurfaceArrival` 里直接交给 `FramebufferRenderer`, 消费者 mmap + close fd 副本. fd 不消费就泄漏. SCM_RIGHTS 的 C 侧实现在 `HVMScmRecv` 模块 (Swift 不能直接做 cmsg 拼装).

HELLO 协商: host 与 QEMU 各自宣告 capabilities (cursorBGRA / ledState / vdagentResize), 取交集; major 不一致直接断连.

socket 路径: `BundleLayout.iosurfaceSocketURL(bundleURL)`, 一般在 `<bundle>/run/hdp.sock`, VMHost 启动 QEMU 前由本地 listener 创建.

### `FramebufferRenderer` + `FramebufferHostView`

- Renderer: shm BGRA buffer + damage 矩形 → CGImage
- HostView: NSView 子类, `layer.contents = CGImage`. 嵌主窗口同样走 `NSViewRepresentable`, 与 VZ 路径在 GUI 上层等价

### 输入: `InputForwarder` (QMP)

`HVMDisplayQemu/InputForwarder.swift`. 鼠标 / 键盘 / 滚轮事件走独立 QMP socket `<bundle>/run/qmp.input`, 与控制 QMP 分开:

- `-qmp unix:<path>.input,server=on,wait=off` 由 QemuArgsBuilder 单独开
- 单连接 + serial DispatchQueue, 所有 send 串行 (sendmsg 不能并发)
- 简化握手: connect → drain greeting → `qmp_capabilities` → drain return → ready, 后续 server 推送的 event 全部 drain
- 鼠标走绝对坐标 (0..32767, `usb-tablet` / `virtio-tablet` 标准), host 端 view 坐标归一化, 同点重复不发去重

QMP `input-send-event` 命令:

```json
{ "execute": "input-send-event",
  "arguments": { "events": [
     { "type": "key", "data": { "down": true,
                                 "key": { "type": "qcode", "data": "a" } } },
     { "type": "abs", "data": { "axis": "x", "value": 16383 } },
     { "type": "btn", "data": { "down": true, "button": "left" } } ] } }
```

### `NSKeyCodeToQCode`

把 macOS HID keycode 翻成 QEMU qcode 字符串 (上游 `qapi/ui.json` `QKeyCode`). 维护一份对照表, 按 macOS 物理键位 (USB HID Usage) 来源, 不是 character map.

### macOS 风快捷键 (`macStyleShortcuts`)

仅 QEMU 后端 (Win / Linux guest) 生效, VZ macOS guest 忽略. 默认 true.

- `cmd+c → ctrl+c` 等: host 按 cmd 时, host view 把对应 qcode 替换成 `ctrl_l`
- 副作用: 失去发 Win/super 键的能力 (用鼠标点开始菜单代替)
- 关闭 → 退回老逻辑 `cmd → meta_l` (Win 键)
- view-instance 级开关, **不持久化到 host 子进程**, 改完无须重启 VM

### 截屏 (`HVMQemu/QemuScreenshot`)

走 QMP `screendump`:

```
QMP screendump → PPM 临时文件 → PPMReader → CGImage → 可选 down-scale → PNG bytes
```

输出形态对齐 VZ `ScreenCapture.capturePNG`, 上层 `QemuHostState` 用统一接口, GUI / hvm-dbg 不区分后端.

## 剪贴板共享

### 状态

- VZ macOS guest: VZ 自带, 不需配置
- QEMU Linux guest: 走 spice-vdagent + `PasteboardBridge`
- QEMU Windows guest: 装 spice-guest-tools (含 vdagent.exe) 后通路打通; UTM Guest Tools ISO 也含 ARM64 native vdagent

### `VdagentClient`

`HVMDisplayQemu/VdagentClient.swift`. 通过 QEMU 的 virtio-serial chardev unix socket (path=`com.redhat.spice.0`) 跟 guest spice-vdagent 双向通话:

- `MONITORS_CONFIG`: host 改窗口尺寸 → guest xrandr / `SetDisplayConfig` 改分辨率 (动态 resize)
- `ANNOUNCE_CAPABILITIES`: 协商 caps. UTM Guest Tools (Win) 报 `caps=0x46B7`, bit 6 (SELECTION) 缺, 需要 host 端兼容
- `CLIPBOARD_GRAB / REQUEST / CLIPBOARD / RELEASE`: 双向剪贴板传输

socket / write 错误 silently swallow + warn — vdagent 通道挂了不阻塞主流程.

### `PasteboardBridge`

`HVMDisplayQemu/PasteboardBridge.swift`:

- **host → guest**: 1Hz Timer 轮询 `NSPasteboard.general.changeCount`, 变化 → 读 `NSPasteboard.string(forType:.string)` → `vdagent.sendClipboardText(text)` (内部 GRAB → 等 guest REQUEST → 回 CLIPBOARD)
- **guest → host**: `vdagent.onClipboardTextReceived` 回调 → `NSPasteboard.setString(...)`. 记录 `lastWrittenChangeCount`, 下次轮询比对避免 echo

NSPasteboard 没有事件 API, 必须轮询 — 跟 UTM (UTMPasteboard 1Hz) 一致. 启动时**不**把当前 host 剪贴板推 guest, 避免 "用户启动 VM 时 host 上恰好有不相关内容也被同步" 的不直观行为.

VMConfig 字段: `clipboardSharingEnabled: Bool` (默认 true). 运行中可通过 IPC `clipboard.setEnabled` 即时切换, 不必重启 VM.

## 多显示器 / HiDPI

- VZ macOS guest 原生 HiDPI, view backing 自动 retina
- VZ Linux guest 需 guest 内配置 (Xorg DPI / Wayland scale)
- QEMU 多 scanout 在 viogpudo / Linux virtio-gpu 装好驱动后由 vdagent 触发 dynamic resize
- 多显示器 GUI 暂未暴露, MacOSSpec / VirtioGraphicsScanoutConfiguration 都支持数组, 留扩展口

## 不做什么

1. 不做相对坐标鼠标 (VZ 不提供; QEMU 上 abs 模式跟 host 鼠标行为最匹配)
2. 不做 pointer lock / 鼠标逃逸 FPS 模式
3. 不做手势识别拦截 (Touch Bar / trackpad force-click 直接透传)
4. 不做自定义光标样式切换
5. 不做录屏 (用 macOS 自带或第三方)
6. 不做拖拽文件入 guest (走共享目录 / scp / USB mass storage)
7. 不做独立窗口 (VZ Metal drawable 在 reparent 时会失效, 已下线; 后续若做必须每窗口独立 `VZVirtualMachineView` 实例)

## 性能注记

- VZ frame buffer 走 Metal 加速, 接近原生
- HDP 单 shm BGRA, dirty-region damage 推送, 主窗口零拷贝 `CGImage`; 实测 Win11 桌面 ~60fps
- 截图限流 ≤10 FPS, 主线程 cacheDisplay 不阻塞 VM
- `InputForwarder` 同点重复鼠标坐标去重, 减少 QMP 流量

## 未决事项

| 编号 | 问题 | 默认 | 决策时机 |
|---|---|---|---|
| K1 | macOS guest 是否暴露分辨率选择 | 创建向导固定 1080p | 用户反馈再加 |
| K2 | 多显示器 GUI | 暂不做 | TBD |
| K3 | HDP cursorBGRA 硬件光标渲染 | 已声明 capability, host renderer 暂走简单实现 | M3 优化 |
| K4 | Linux guest 剪贴板默认 | 装系统时若有 spice-vdagent 自动启 | 已决 |

## 相关文档

- [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) — HDP v1.0.0 wire 规范
- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — `hvm-gpu-ramfb-pci` / patches 清单
- [VZ_BACKEND.md](VZ_BACKEND.md) — VZ 设备挂载
- [GUI.md](GUI.md) — 嵌入主窗口交互
- [DEBUG_PROBE.md](DEBUG_PROBE.md) — `hvm-dbg` 截屏 / 注入 / OCR

---

**最后更新**: 2026-05-04
