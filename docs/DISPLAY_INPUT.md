# 显示渲染与输入处理

> 现状文档 (非设计提案). 描述当前代码 (`app/Sources/HVMDisplayQemu/**` + GUI 桥接层)
> 在 **QEMU 后端单一路线** 下的 host view 侧实现: HDP IOSurface framebuffer 零拷贝
> 渲染到 `NSView`, NSEvent 键鼠转发, 键盘捕获双态, 修饰键卡键防护, 动态分辨率.
>
> 本文聚焦 **host view 侧** (`FramebufferHostView` / `FramebufferRenderer` /
> `InputForwarder` / fanout 接线). HDP wire 协议本身 (HELLO / SURFACE_NEW / SCM_RIGHTS /
> 消息编码) 是另一篇 canonical 规范 [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md)。

涉及源文件:

| 文件 | 职责 |
| --- | --- |
| `HVMDisplayQemu/FramebufferHostView.swift` | MTKView 子类, 拦 NSEvent 键鼠, 捕获双态, 修饰键镜像, Cmd+V/拖放文件粘贴 |
| `HVMDisplayQemu/FramebufferRenderer.swift` | Metal 零拷贝渲染 shm framebuffer → drawable |
| `HVMDisplayQemu/DisplayChannel.swift` | HDP host-side 客户端 (连 iosurface socket, 收 surface/cursor/led, 发 RESIZE_REQUEST) |
| `HVMDisplayQemu/InputForwarder.swift` | 独立 QMP socket 发 `input-send-event` 键鼠事件给 guest |
| `HVMDisplayQemu/NSKeyCodeToQCode.swift` | macOS keyCode → QEMU qcode 静态映射表 |
| `HVMDisplayQemu/CGSPrivate.swift` | Skylight 私有 API 禁/启 macOS 全局热键 |
| `HVMDisplayQemu/VdagentClient.swift` | SPICE vdagent 客户端 (含 MonitorsConfig resize hint) |
| `HVM/GUI/Display/QemuFanoutSession.swift` | 单 VM 一个 channel/forwarder, 多 view 扇出, resize debounce |
| `HVM/GUI/Display/QemuFramebufferView.swift` | SwiftUI ↔ AppKit 桥, 详情区画面嵌入 |

---

## 1. 显示通路概览

### 1.1 链路

```
QEMU (-display iosurface,socket=…)
   │  HDP wire 协议 (AF_UNIX SOCK_STREAM)
   ▼
DisplayChannel  ── AsyncStream<Event> ──▶  QemuFanoutSession
   │  SURFACE_NEW 携带 SCM_RIGHTS shm fd                │ 扇出 (dup fd)
   ▼                                                    ▼
FramebufferRenderer.bindShm(fd:info:)        FramebufferHostView.bindSurface(_:)
   │  mmap shm → MTLBuffer(bytesNoCopy:) → MTLTexture
   ▼
FramebufferRenderer.draw(in: MTKView)  ── 全屏 triangle-strip + 采样 ──▶  drawable
```

像素**全程零拷贝**: QEMU 把 framebuffer 写进 POSIX shm, 通过 `SCM_RIGHTS` 把 shm fd
传给 host; host `mmap` 同一物理页, `device.makeBuffer(bytesNoCopy:)` 让 GPU 直接
view 自该映射, `buffer.makeTexture(...)` 建 BGRA8 2D 纹理. fragment shader 采样到
drawable, 无任何 CPU `memcpy` (`FramebufferRenderer.swift`)。

### 1.2 FramebufferRenderer 要点

- **shader 内嵌**: 4-vertex triangle strip 全屏 quad + 采样纹理, 用
  `device.makeLibrary(source:)` 运行时编译, 不依赖 SwiftPM `.metal` 编译流程。
- **stride 约束**: `bytesPerRow` (= `info.stride`) 必须 ≥256B 对齐, 由 QEMU iosurface
  backend (`patches/qemu/0002` 的 `IOS_STRIDE_ALIGN`) 保证。客户端只校验下界
  (`stride >= width*4 && stride % 16 == 0 && size >= stride*height`), 不自己推。
- **格式**: 只接受 `HDP.PixelFormat.bgra8`, 其他格式直接 `close(fd)` 拒绝。
- **deallocator 自动 munmap**: `MTLBuffer(bytesNoCopy:deallocator:)` 在 GPU 释放最后
  一个引用后 `munmap`, 持引用即保活, 切新 surface 时老 buffer 释放自动回收老映射。
- **letterbox 等比缩放**: `draw(in:)` 按 guest framebuffer 实际比例 `min(dw/tw, dh/th)`
  居中渲染到 drawable, 未覆盖区 = MTKView `clearColor` (黑) 自然黑边, 不拉伸。
- **空 drawable 仍 present**: 没绑 surface 时也 `present` 一个空 drawable, 让 MTKView
  不卡帧。
- **snapshotCGImage**: thumbnail 用. 旧零拷贝路径会让 bg PNG encode 跟 GPU 抢同一
  物理页 cache (用户报每 ~10s 鼠标卡顿), 现改 main actor 一次性 `memcpy` ~8MB 到独立
  `Data` 再交 bg 线程 encode, 跟 GPU mmap 脱钩。

### 1.3 FramebufferHostView 帧驱动

- MTKView **必须直接是嵌入主窗口的 view**, 不放在普通 NSView 内 — 否则 AppKit 在
  `NSHostingView` layout 切换中触发 `viewWillMoveToWindow`/`viewDidMoveToWindow`,
  让 MTKView 内部 `CVDisplayLink` 失效, `draw(in:)` 永不被调 → 画面卡死。
- `preferredFramesPerSecond = 60` + `isPaused = false`, **不**启 `enableSetNeedsDisplay`
  (那会切成"仅 needsDisplay 才 draw", NSWindow resize 后 guest 静止时卡在最后一帧)。
- `SURFACE_NEW` → `bindSurface` (renderer.bindShm + 缓存 `guestFbSize` + 触发首帧);
  `SURFACE_DAMAGE` → `markFramebufferDirty` (`setNeedsDisplay`, AppKit 合并 burst 到下一
  displayLink tick, 绝不同步 `view.draw()` 防 block main thread)。

### 1.4 fanout (单 channel 多 view)

`QemuFanoutSession` 一个 VM 一个实例, 持有唯一的 `DisplayChannel` + `InputForwarder`:

- **single-client 限制**: QEMU iosurface socket / QMP input socket 都是单 client。多 view
  (主嵌入 + detached 独立窗口) 共存时**共享同一 channel/forwarder**, 不能各连各的。
- `addSubscriber(view, isResizeMaster:)`: 注入 `view.forwarder = self.forwarder`,
  若已收过 SurfaceNew 则 `dup(cachedSurfaceFD)` 重放给新 view, 同步当前 LED / cursor。
- **HDP channel 重连**: guest reset 让 QEMU 短暂关 socket 时, 不 tearDown fanout (会丢
  view 订阅永久黑屏), 而是新建 `DisplayChannel` 重连同一路径, view 订阅保留, 等新
  SURFACE_NEW 到达自然恢复画面。
- **连接重试 60s 窗口** (600 × 100ms): 加密 VM 子进程 PBKDF2 解锁 + LUKS keyslot + swtpm +
  unattend regen 让 QEMU 真正 listen 晚至 5–20s, 老 5s 窗口对加密 VM 不够。

### 1.5 硬件光标

guest 走 `usb-tablet` 1:1 绝对坐标, host 鼠标位置即 guest 位置, 光标位置不用 host 维护。
HDP `CURSOR_DEFINE` 推 BGRA 像素 → host 装成 `NSCursor` 自画 overlay (virtio-gpu 硬件光标
不在 framebuffer 像素里); `CURSOR_POS.visible` 控制 host 是否跟着藏。`applyCurrentCursor`
三态: guest 隐藏 → `NSCursor.hide()`; guest 有自画 → set; 都没有 (BDD 软件路径) → 藏 host
鼠标 (光标已画进 framebuffer)。`NSCursor.hide/unhide` 引用计数, view 销毁前必须净计数 = 0。

---

## 2. 输入捕获双态

`FramebufferHostView.isCaptured` (默认 `false` = released):

| 态 | 行为 |
| --- | --- |
| **released** (默认) | view 收键鼠, 但 macOS 系统快捷键 (Cmd+Tab / Cmd+Space / Mission Control / 截图) 仍由 macOS 处理, 不进 guest。常用模式, 操作 host menubar / 切窗口正常 |
| **captured** | `CGSSetGlobalHotKeyOperatingMode(.disable)` 禁 macOS 全局热键, 所有键 (含 cmd+tab) 全送 guest |

### 2.1 切换快捷键: Cmd+Opt (硬约束)

`flagsChanged` 内检测 `[.command, .option]` 同时刚按下 (`cur` 含两者, `lastModifiers`
不全含) → toggle。**禁止再用老的 Cmd+Ctrl** (跟 Mission Control / 截图 / 第三方 app 严重
冲突已废弃)。Cmd+Opt 本身不送 guest (当 meta 用), toggle 路径走 `captureInput` /
`releaseCapture` (内部 `releaseAllPressedKeys` + `lastModifiers = []`), 后续松键 set diff
自然干净。

### 2.2 禁用 macOS 全局热键

`CGSPrivate.swift` 用 `@_silgen_name` 直接 link Skylight 私有 API
`CGSSetGlobalHotKeyOperatingMode`, 封装成 `HVMSetGlobalHotKeyOperatingMode(.disable/.enable)`:

- 私有 API (UTM 长期依赖, macOS 14+ 至今未坏); 失败 silent (sandbox / 未来 macOS 可能 no-op)。
- captured 时禁用让 cmd+tab / cmd+space 也透传 first responder (本 view) → guest。

### 2.3 captured 视觉反馈

`captureInput` 显示右上角 HUD overlay `⌘⌥  退出捕获` (`NSVisualEffectView` `.hudWindow`
+ `NSTextField`, 走原生 AppKit addSubview 而非 SwiftUI, 因为 view 本身是 MTKView)。
`releaseCapture` 隐藏。

### 2.4 退出 captured 闭环 (硬约束)

`releaseCapture` 内 `HVMSetGlobalHotKeyOperatingMode(.enable)` 必须被任何退出路径触发,
否则系统热键留在 disable 状态用户无法 cmd+tab 切别 app (体验灾难)。所有路径:

- 用户再按 Cmd+Opt (`flagsChanged`)
- `viewWillMove(toWindow: nil)` — view 离开 window hierarchy
- `resignFirstResponder` — AppKit 让本 view 丢 first responder
- `inputCaptureEnabled = false` 的 `didSet`

每条都先 `if isCaptured { releaseCapture() }` 再 `releaseAllPressedKeys()`。

### 2.5 inputCaptureEnabled 总开关

`inputCaptureEnabled` (默认 `true`) 设 `false` 时: `acceptsFirstResponder = false`,
所有 mouse/key/scroll 处理函数直接 return, 不藏 host 鼠标, 立即释放 first responder,
自动 `releaseCapture`。主用途: 同 VM 有 detached 独立窗口 / dialog 活时, 让主嵌入 view
让出输入。GUI 侧 `QemuFramebufferView.applyDialogState` 在 dialog 弹出时设
`inputCaptureEnabled = false` + `isPaused = true` + 叠遮罩 (三保险防 Metal 层穿透盖住 dialog)。

---

## 3. 修饰键状态镜像 (卡键防护)

老 bug "shift / cmd 一直按着" 的根治。`FramebufferHostView` 维护三件套:

| 字段 | 含义 |
| --- | --- |
| `lastModifiers: NSEvent.ModifierFlags` | 上一次 modifier 全量快照, `flagsChanged` 用 **set diff** 算 down/up (跟 UTM `VMMetalView.lastModifiers` 同款) |
| `pressedModifierQcodes: Set<String>` | 已发 keyDown 未发 keyUp 的 **modifier** qcode (如 `{"shift","ctrl_r"}`) |
| `pressedNormalKeyQcodes: Set<String>` | 已发 keyDown 未发 keyUp 的 **非修饰键** qcode (如 `{"a","tab"}`) |

### 3.1 flagsChanged set diff

`syncModifiersToGuest(flags)`: 把 `flags` 经 `modifierQcodes(from:)` 算出 target 集合,
跟 `pressedModifierQcodes` 做差集 — 多的发 `keyUp`, 少的发 `keyDown`, 然后
`pressedModifierQcodes = target` + 更新 `lastModifiers`。forwarder 未连时不发但
`lastModifiers` 仍更新 (等 forwarder 上线后 `becomeFirstResponder` 再同步)。

### 3.2 releaseAllPressedKeys 一并清光

`viewWillMove(toWindow:nil)` / `resignFirstResponder` / 进出 captured / `inputCaptureEnabled
= false` 时调 `releaseAllPressedKeys`: 补发 `pressedNormalKeyQcodes` + `pressedModifierQcodes`
**全部** keyUp, 清三件套。**根治点**: 老逻辑只清 normal key 不清 modifier, 用户 cmd+tab
切走再回来 guest 端 cmd 永远 keyDown → "cmd 一直按着"。现在 normal + modifier 一起清。

### 3.3 becomeFirstResponder 重同步

重获焦点时 `syncModifiersToGuest(NSEvent.modifierFlags)` 用当前实时 modifier 重对齐 —
用户在失焦期间按/松了 modifier (例如按住 cmd 切回来), 内部 `lastModifiers` 过期, 不 sync
则 guest 端 cmd 永远没 keyDown, cmd+s 不生效。

### 3.4 Cmd 时字符键 keyUp 丢失补偿

macOS 已知行为: 按住 `.command` 时字符键 `keyUp` 不送 `NSView`, 后果是 guest 看 keyDown
没对应 keyUp → auto-repeat 卡键。`installCmdKeyUpMonitor` 装 `NSEvent` local monitor (仅
`.keyUp`), 在本 view 是 first responder + inputCaptureEnabled + modifier 含 cmd 时把 event
直接路由给 `self.keyUp`, 然后 return event 放行。进出 window 时 install/uninstall 防泄漏
(UTM 同款做法)。

### 3.5 不发 isARepeat / CapsLock 单一 source

- `keyDown` 里 `if event.isARepeat { return }` — repeat 由 guest 自己做。
- CapsLock **不在** `flagsChanged` 发 toggle (会跟 keyDown 路径的 `syncCapsLockIfNeeded`
  双重 toggle 抵消)。单一 source: `keyDown` 时 `syncCapsLockIfNeeded` 比对 host bit vs
  `expectedGuestCaps` (本地预期 + 翻转, HDP `LED_STATE` 校正乱序), 不一致才发一次
  `caps_lock` toggle。

---

## 4. 左右修饰键独立映射

`NSEvent.ModifierFlags` 公开 API 不区分左右, 但 raw bit 区分 (跟 Carbon
`kEventKeyModifier*` 同源, 跨 macOS 10.5–15+ 稳定)。`FramebufferHostView` 底部私有扩展:

```swift
leftShift   = 0x0002    rightShift   = 0x0004
leftControl = 0x0001    rightControl = 0x2000
leftOption  = 0x0020    rightOption  = 0x0040
leftCommand = 0x0008    rightCommand = 0x0010
```

`modifierQcodes(from:)` 按这些 bit 拆 qcode: `shift`/`shift_r`, `ctrl`/`ctrl_r`,
`alt`/`alt_r`。每类都有兜底分支: 某些合成事件 / 远程键盘只设 `.shift` 不设 left/right bit
时退化到左侧 (`shift`)。普通键 keyCode → qcode 走 `NSKeyCodeToQCode.swift` 的静态映射表
(ANSI 字母 / 数字 / 符号 / 编辑控制 / 方向 / F1–F15 / 小键盘全覆盖)。

---

## 5. macStyleShortcuts (host cmd → guest ctrl)

`FramebufferHostView.macStyleShortcuts` (默认 `true`), 由 GUI 按 `VMConfig.macStyleShortcuts`
设置, 详情页"选项" section toggle 可热改 (`DetailOptionsSection`, framebuffer view 实时读
无须重启 VM)。

- **开** (默认): `modifierQcodes` 把左右 cmd 都映射成 `ctrl` (用户记忆里 cmd 是"主操作键",
  cmd+c → ctrl+c)。`Set` 自动去重, 用户同时按左 cmd 和 ctrl 时不重复 keyDown。
  副作用: 失去发 Win/super 键能力 (Win11 开始菜单要鼠标点)。
- **关**: 回老逻辑, cmd → `meta_l` / `meta_r` (Win 键), 用户用 control+c 复制。

注意 Cmd+Opt 捕获 toggle 跟 macStyleShortcuts 无关 (toggle 在映射之前的 `flagsChanged`
分支拦截, 不进 `modifierQcodes`)。

---

## 6. Cmd+V 文件粘贴拦截

host Finder Cmd+C 文件 → 切 framebuffer view 按 Cmd+V → 走 SPICE vdagent file_xfer 落
guest `~/Downloads` (设计/边界见 CLAUDE.md「Cmd+V 文件粘贴」节)。本文只讲 view 侧拦截判定。

### 6.1 拦截三条 (`keyDown` 内, 全过才吃掉这次 Cmd+V)

```swift
if macStyleShortcuts,
   let onFilePaste,
   event.modifierFlags.contains(.command),
   !event.modifierFlags.contains(.option),    // 排除 Cmd+Opt (capture toggle 副产物)
   !event.modifierFlags.contains(.shift),      // 排除 Cmd+Shift+V 等其他业务快捷键
   !event.modifierFlags.contains(.control),
   event.charactersIgnoringModifiers == "v" {
    if let urls = Self.readPasteboardFileURLs(), !urls.isEmpty {
        onFilePaste(urls)
        return   // *不* 走 keystroke 路径; closure 已 own 这次 Cmd+V
    }
}
```

1. **macStyleShortcuts = true** (用户在用 mac 习惯, Cmd 当主操作键)
2. **Cmd 单按** (排除 Opt / Shift / Ctrl 同按)
3. **NSPasteboard 有 file URLs** (`urlReadingFileURLsOnly: true`, 仅 `isFileURL` 的 NSURL,
   排 https / RTF 等)

任一不过 → 走老的 keystroke 路径 (cmd+v → ctrl+v 文本粘贴)。判定在 normal-key qcode 发送
**之前**, 避免双发。`onFilePaste` 闭包由 GUI 层注入 (内部走 IPC `clipboard.paste-files` →
VMHost `FilePasteBridge`)。

### 6.2 文件拖放 (复用同后端)

`registerForDraggedTypes([.fileURL])` + `draggingEntered`/`performDragOperation`: 拖入接受
判定 `filePasteboardURLs(from:)` 同样要求 `inputCaptureEnabled && macStyleShortcuts &&
onFilePaste != nil && 至少 1 个 file URL`, `performDragOperation` 调同一 `onFilePaste(urls)`
闭包。视觉走 `dropOverlay` (半透明黑底 + 中央 "释放鼠标 — 把 N 个文件拖到虚拟机")。

> **现状提示**: 新 GUI `QemuFramebufferView.makeNSView` 里 `onFilePaste` 接线标注 "留 F3",
> 即 Cmd+V/拖放文件粘贴在新 GUI 详情区画面嵌入侧尚未接 closure (view 侧拦截逻辑已就绪,
> 等 GUI 注入 closure)。

---

## 7. 鼠标坐标 (letterbox + 绝对坐标)

`FramebufferRenderer` 等比 letterbox 渲染, 黑边占 view 上下/左右空间但 guest 视野里没有。
`viewCoords(event)` 必须按 **letterbox 区域**归一化, 不能按整 view, 否则 host 鼠标在 view
中央时 guest 收到的归一化坐标偏:

- 按 `scale = min(viewW/gw, viewH/gh)` 算 letterbox 区域 (`lbW`/`lbH`/`lbX`/`lbY`), 黑边里
  clamp 到 letterbox 边缘, 并 `forwarder.setViewSize(lbW, lbH)`。
- `guestFbSize` 未 bind 时退化到整 view 比例 (画面也没出来, 视觉对齐无影响)。

`InputForwarder` 把 view 坐标归一化到 `0..32767` 绝对坐标 (`usb-tablet`/`virtio-tablet`
标准), 同坐标重复不发 (`lastAbsX/lastAbsY` dedup)。键鼠通过**独立** QMP socket
(`-qmp unix:<path>.input`) 发 `input-send-event` (不复用控制 QMP, 避免 accept 争抢);
单连接 serial DispatchQueue 串行化所有 send。

---

## 8. 动态 resize

host 拖窗口改 guest 分辨率, 两条通路并发 (guest 哪条 work 哪条生效):

| # | 通路 | 适用 |
| --- | --- | --- |
| A | HDP `RESIZE_REQUEST` → QEMU patch 0002 handler → `dpy_set_ui_info` → EDID | Linux virtio-gpu (内核 driver 收 EDID 改分辨率); 对 ramfb 是诊断信号 |
| B | vdagent `VDAgentMonitorsConfig` (`sendMonitorsConfig`) → guest spice-vdagent → SetDisplayConfig | Windows (ramfb / viogpudo 不响应 EDID, 必须走 spice 协议) |

### 8.1 触发链

- `FramebufferHostView.mtkView(_:drawableSizeWillChange:)` 把 drawable pixel 尺寸 (已乘
  retina scale) 经 `onDrawableSizeChange?(w, h)` 推上层。
- **但** `QemuFanoutSession.addSubscriber` **故意**设 `view.onDrawableSizeChange = nil`:
  盲绑会让任何 drawableSizeWillChange (window setContentSize / 主嵌入 ↔ detached 切换 /
  chrome 估算误差) 都盲发 resize, 用户没拖窗口 guest 也被改分辨率。
- 实际入口走 `DetachedVMWindowController.windowDidEndLiveResize` → `requestResizeFromUser`
  → `scheduleResize` (只在用户真正拖窗口结束时发)。

### 8.2 debounce + dedup

`scheduleResize` (`QemuFanoutSession`):

- **debounce 300ms**: 拖动期间高频被调, 新尺寸来就 cancel 旧 `DispatchWorkItem`, 停
  300ms 才真正下发 (防 Win guest 一边拖一边反复改分辨率刷屏)。
- **dedup**: 跟 `cachedSurfaceInfo` (guest 当前 framebuffer) 一致 → 跳过; 没收过
  SURFACE_NEW (不知 guest 状态) → 不盲发。
- 下发: `channel.requestResize(w, h)` (HDP, GUI 自家直连 iosurface socket) +
  background queue `ipcSetMonitors` → IPC `display.setMonitors` → VMHost 持久 vdagent
  `sendMonitorsConfig` (vdagent 是 single-client socket, GUI 不直连, 走 VMHost 转)。

### 8.3 DisplayChannel.requestResize 不检查 caps

`requestResize` **不**检查 `negotiatedCaps` (跟 hell-vm 一致): iosurface backend 不一定
advertise `vdagentResize` cap 但仍能处理 RESIZE_REQUEST。cap check 静默丢请求会让用户拖
窗口 guest 不改分辨率即使 vdagent 已装好。只检查 `sockFD >= 0` (已 connect 才发)。

### 8.4 vdagent MonitorsConfig 编码

`VdagentClient.sendMonitorsConfig(width:height:)`: 单显示器, 32-bit color, 原点 (0,0),
dedup (`lastSentSize` 同尺寸不重发)。wire 格式 `VDAgentMonitorsConfig` (8B:
num_of_monitors=1 + flags) + `VDAgentMonConfig` (20B: height, width, depth=32, x=0, y=0)。

---

## 9. 测试入口

- `hvm-dbg display-resize <vm> --width W --height H` — 触发 host→guest dynamic resize
  (并发跑 HDP RESIZE_REQUEST + vdagent MONITORS_CONFIG, 打印各通路结果),
  `DisplayResizeCommand.swift`。
- `FramebufferHostView.probeShowDropOverlay(count:)` / `probeHideDropOverlay()` — GUI probe
  测试绕过真实 drag 流程, 给截图验证拖放 overlay 视觉。
- 显示状态验证优先 `hvm-dbg screenshot --output X.png` 自己肉眼看 (CLAUDE.md 不依赖 OCR)。

---

## 10. 关键约束速查

- 退出 captured **必须** `releaseCapture` 还原全局热键 (viewWillMove/resignFirstResponder/
  inputCaptureEnabled=false 全查 `if isCaptured`)。
- 卡键防护**必须**清 normal key + modifier 双份 (`releaseAllPressedKeys`)。
- 捕获 toggle **只用 Cmd+Opt**, 禁用 Cmd+Ctrl。
- Cmd+V 文件粘贴拦截**三条全过** (macStyleShortcuts + Cmd 单按 + file URLs)。
- resize **不绑** `onDrawableSizeChange` 盲发, 只在 live resize 结束 + debounce + dedup 后下发。
- `bytesPerRow`/stride ≥256B 对齐 (QEMU patch 0002 保证); 渲染端只校验下界。
- 多 view 共享单 channel/forwarder (iosurface / QMP input / vdagent 都是 single-client)。
