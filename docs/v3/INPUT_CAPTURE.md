# INPUT_CAPTURE — 键盘捕获 / 释放重构 (UTM 风格)

**状态**: 代码已合入 2026-05-24
**作者**: hell
**对应代码**:
- `app/Sources/HVMDisplayQemu/FramebufferHostView.swift` (重写键盘 / 捕获)
- `app/Sources/HVMDisplayQemu/CGSPrivate.swift` (新增, 私有 API)
- `app/Sources/HVMDisplay/HVMView.swift` (统一释放快捷键)
- `app/Sources/HVMDisplayQemu/NSKeyCodeToQCode.swift` (左右修饰键 qcode 已存在, 无改动)

## 背景

老的 `FramebufferHostView` 键盘逻辑有两类用户可感知 bug:

1. **修饰键卡死** ("shift / cmd / ctrl / alt 一直被按着"): 用户按住 cmd → `cmd+tab` 切到别的 app → 切回, guest 端 cmd 永远 keyDown 状态. 后续输入全部变成 cmd+X 组合.
2. **cmd+xxx 没映射成功**: 用户按住 cmd → 点 view → 按字符键, 组合键失效 (guest 收到字符但没收到 cmd).

老的释放快捷键 `Cmd+Ctrl` 跟 macOS 系统快捷键 (Mission Control / 截图 / 第三方 app) 严重冲突, 用户经常无意触发, 体验差.

参考 UTM 同款实现 (`Platform/macOS/Display/VMMetalView.swift`, QEMU 后端 SPICE display), 重构两个核心改动:
- modifier 状态独立追踪 + 失焦清光 (修上述 bug)
- 引入 captured / released 双态 + Cmd+Opt 切换 (取代 Cmd+Ctrl)

## 目标

- 修复 modifier 卡死: 任何路径让 view 失焦或退出捕获时, 已发给 guest 的所有按键都 keyUp 清掉
- 修复 cmd+xxx 失效: 重获 first responder 时立即把当前 host modifier 状态推给 guest
- 左右修饰键独立映射 (`shift` vs `shift_r`, `ctrl` vs `ctrl_r` 等), Win 端 IME / 游戏可分辨
- 释放快捷键改 Cmd+Opt, 跟系统快捷键不冲突 (UTM 默认相同)
- 加入"captured 模式": 用户主动切入后, macOS 全局热键 (cmd+tab / cmd+space) 禁用, 全部送 guest. 解决 "Windows 任务切换怎么按" 这种长期 pain point
- VZ 后端释放快捷键也同步 (用户体感统一)

## 非目标

- **不**做真正的相对鼠标 + warp + lock 模式 (UTM 有, 我们 QEMU usb-tablet 只支持 abs 坐标, 改 guest 端硬件配置需要装驱动, 范围扩大太多)
- **不**改 `macStyleShortcuts` 单向 cmd→ctrl 行为 (避免老用户行为变化, 后续可再做 UTM 风格双向 swap)
- **不**给用户暴露偏好选项 (Cmd+Opt vs Ctrl+Opt 二选一, 第一版硬编码 Cmd+Opt)
- **不**做 VZ 后端的 captured 双态 (VZ framework 自己接管 modifier, `capturesSystemKeys = true` 已经做了类似事情, 不必再叠一层 CGS hack)

## 选型对比

### 方案 A: 仅 modifier 镜像 + 失焦清光 (最小修复)

只追踪 `pressedModifierQcodes` set, `resignFirstResponder` / `viewWillMove(toWindow:nil)` 一并 keyUp. 不引入 captured 双态.

- ✅ 改动小 (≤ 100 行), 风险低
- ✅ 修复 modifier 卡死的所有已知场景
- ❌ 用户仍然不能在 Windows guest 里按 cmd+tab 切应用 (被 macOS 拦)
- ❌ 释放快捷键还是 Cmd+Ctrl 冲突

### 方案 B: A + 左右修饰键区分

加 NSEvent.ModifierFlags raw bit (`leftShift = 0x2` 等), `modifierQcodes(from:)` 区分左右.

- ✅ Win 端右 Shift 跟左 Shift 区分 (IME / 游戏正确)
- ✅ qcode 表已经有 `shift_r` / `ctrl_r` / `alt_r` / `meta_r`, 不用改 NSKeyCodeToQCode
- ❌ 仍没解决"cmd+tab 怎么进 guest"

### 方案 C: B + captured 双态 + CGSSetGlobalHotKeyOperatingMode + 右上角 overlay (选定)

引入 `isCaptured: Bool`, **Cmd+Opt** toggle:
- `captured = true`: `CGSSetGlobalHotKeyOperatingMode(.disable)` 禁用系统热键, 所有键送 guest
- `captured = false`: 还原, 跟普通 NSView 行为一致

UTM 同款做法 (`VMMetalView.captureMouse`). CGS 私有 API 历史稳定 (UTM 长期依赖至今未坏).

- ✅ 完整解决 "Windows 任务切换" pain point
- ✅ 跟 UTM 用户体验对齐 (老 UTM 用户上手零成本)
- ❌ 用私有 API (`@_silgen_name` link, 未来 macOS 可能改 ABI). 失败 silent 退化为方案 B 行为 (HVMSetGlobalHotKeyOperatingMode 返 false 不致命)
- ❌ 多一个 NSVisualEffectView overlay subview (微小性能损耗)

**用户选 C**.

### 方案 D (拒绝): 跨进程 HIDEventTap

用 `CGEventTapCreate` 在 host 全局拦截所有键鼠 → 包装成 NSEvent → 灌给 view. UTM 没用这条路.

- ❌ 需要 Accessibility 权限 (用户得在系统设置授权, 体验断裂)
- ❌ tap 跑在主线程之外, 跟 NSEvent 同步路径会有时序问题
- ❌ macOS 沙盒下完全不可用

## 实现要点

### 1. modifier 镜像

```swift
private var lastModifiers: NSEvent.ModifierFlags = []
private var pressedModifierQcodes: Set<String> = []
private var pressedNormalKeyQcodes: Set<String> = []
```

- `lastModifiers`: 用户最后一次 flagsChanged 时的 NSEvent.ModifierFlags 全量
- `pressedModifierQcodes`: 已经发给 guest `keyDown` 但还没发 `keyUp` 的 modifier qcode 集合 (例如 `{"shift", "ctrl_r"}`)
- `pressedNormalKeyQcodes`: 同上, 非修饰键 (例如 `{"a", "tab"}`)

`flagsChanged` 用 `syncModifiersToGuest(_:)` 算 set diff 双向发:

```swift
private func syncModifiersToGuest(_ flags: NSEvent.ModifierFlags) {
    let target = modifierQcodes(from: flags)
    if let fw = forwarder {
        for q in pressedModifierQcodes.subtracting(target) { fw.keyUp(qcode: q) }
        for q in target.subtracting(pressedModifierQcodes) { fw.keyDown(qcode: q) }
        pressedModifierQcodes = target
    }
    lastModifiers = flags
}
```

### 2. 左右修饰键区分

`NSEvent.ModifierFlags` 公开 API 不区分左右, raw bit 区分 (Carbon `Events.h` 同源, 历史稳定):

```swift
private extension NSEvent.ModifierFlags {
    static var leftShift:    NSEvent.ModifierFlags { .init(rawValue: 0x0002) }
    static var rightShift:   NSEvent.ModifierFlags { .init(rawValue: 0x0004) }
    static var leftControl:  NSEvent.ModifierFlags { .init(rawValue: 0x0001) }
    static var rightControl: NSEvent.ModifierFlags { .init(rawValue: 0x2000) }
    static var leftOption:   NSEvent.ModifierFlags { .init(rawValue: 0x0020) }
    static var rightOption:  NSEvent.ModifierFlags { .init(rawValue: 0x0040) }
    static var leftCommand:  NSEvent.ModifierFlags { .init(rawValue: 0x0008) }
    static var rightCommand: NSEvent.ModifierFlags { .init(rawValue: 0x0010) }
}
```

`modifierQcodes(from:)` 按 left / right bit 分配 `shift` / `shift_r` 等. 合成事件 (NSEvent.keyEvent(with:...)) 通常只设公开 `.shift` 不设 left/right bit, **必须**兜底:

```swift
if flags.contains(.shift), !flags.contains(.leftShift), !flags.contains(.rightShift) {
    s.insert("shift")
}
```

### 3. captured 双态

```swift
public private(set) var isCaptured: Bool = false

private func captureInput() {
    guard !isCaptured else { return }
    releaseAllPressedKeys()                          // 防 cmd+opt 本身两键卡 guest
    HVMSetGlobalHotKeyOperatingMode(.disable)
    isCaptured = true
    captureOverlay?.isHidden = false
}

private func releaseCapture() {
    guard isCaptured else { return }
    releaseAllPressedKeys()
    HVMSetGlobalHotKeyOperatingMode(.enable)
    isCaptured = false
    captureOverlay?.isHidden = true
}
```

**关键**: 任何路径退出 captured 都必须 `HVMSetGlobalHotKeyOperatingMode(.enable)`. 否则用户切到别 app 后 cmd+tab 全局失效, 体验灾难. `viewWillMove(toWindow: nil)` / `resignFirstResponder` / `inputCaptureEnabled = false` 三处必须查 `if isCaptured { releaseCapture() }`.

### 4. flagsChanged 内的 toggle 检测

```swift
let toggle: NSEvent.ModifierFlags = [.command, .option]
let bothNow = cur.intersection(toggle) == toggle
let bothPrev = lastModifiers.intersection(toggle) == toggle
if bothNow && !bothPrev {
    if isCaptured { releaseCapture() } else { captureInput() }
    return       // Cmd+Opt 本身不送 guest
}
```

toggle 触发后 `lastModifiers` 已经被 `releaseAllPressedKeys` reset 为 `[]`. 用户后续松开 cmd 或 opt 时, `syncModifiersToGuest` 算 diff 干净 (target = 实际剩余 modifier, current pressed set = 空, 自然只发新 keyDown).

### 5. CGS 私有 API

```swift
@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetGlobalHotKeyOperatingMode")
private func _CGSSetGlobalHotKeyOperatingMode(_ cid: Int32, _ mode: Int32) -> Int32
```

无 framework link 依赖 (Skylight 已经默认 link). Sandbox 下 silently no-op (HVM 没启 sandbox, OK).

### 6. 右上角 overlay

`NSVisualEffectView(material: .hudWindow)` + `NSTextField` "⌘⌥ 退出捕获". `setupCaptureOverlay()` 在 init 时 add subview, `layoutCaptureOverlay()` 在 viewDidMoveToWindow 时 pin 到右上 (constant 10pt 边距).

不走 SwiftUI overlay (FramebufferHostView 是 MTKView 子类, 直接 addSubview NSView 更简单, 也不污染 SwiftUI hosting 路径).

### 7. VZ 后端统一

`HVMDisplay/HVMView.swift` 的 release-capture 快捷键从 `[.command, .control]` 改为 `[.command, .option]`. 其他逻辑不动 (VZ framework 自己管 modifier, 我们改不到).

## 风险与待验证

| 编号 | 风险 / 验证项 | 默认 | 状态 |
|---|---|---|---|
| R1 | CGSSetGlobalHotKeyOperatingMode 在未来 macOS 失效 | 失败 silent (返 false), 退化为方案 B 行为 (Cmd+Tab 仍归 macOS, 但其他都好) | UTM 长年依赖, macOS 14/15 实测 OK |
| R2 | 私有 NSEvent.ModifierFlags raw bit 错位 | Carbon Events.h 历史稳定, UTM 同款 raw bit 用了十年 | 未实测但风险极低 |
| R3 | Cmd+Opt 跟 macOS 系统快捷键冲突 | macOS 默认无 Cmd+Opt 单独快捷键 (只有 Cmd+Opt+Esc 强退等组合) | 实测 macOS 14 无误触发 |
| R4 | 用户按 Cmd+Opt 进入 captured 后, cmd+opt 本身仍被 host 看到 | `captureInput()` 内 `releaseAllPressedKeys()` 清光, lastModifiers = []; 后续用户松开走正常 diff | 设计上闭环, **未真机实测** |
| R5 | view 销毁时 captured 状态泄漏 (系统热键留 disable) | `viewWillMove(toWindow: nil)` 强制 `releaseCapture` | 已写, **未真机实测** |
| R6 | 多 view 共存 (主嵌入 + detached) 时 captured 状态串扰 | 每个 view 独立 isCaptured 状态, 但 CGS 是 process-global; 两个 view 都 captured 后只要任一调 .enable 就还原 | 待验证. 当前 detached 用 `inputCaptureEnabled=false` 让出主嵌入, 应只一个 view 是 captured 候选 |
| R7 | Win/Linux guest 内右 Shift 按键真的能跟左 Shift 区分 | qcode `shift_r` 走 QMP input-send-event, guest 端 USB HID 看到 right shift usage code | **未实测** |
| R8 | becomeFirstResponder 时 forwarder 未注入 | syncModifiersToGuest 内 guard fw, 更新 lastModifiers 不发. 等 addSubscriber 注入后下次 NSEvent 自然同步 | 设计上 OK |
| R9 | Cmd+Opt+其他键 (例如用户按 Cmd+Opt+S 想发组合键) | toggle 路径优先, 进入 captured. 用户按 S 之前要先松 Cmd+Opt | 行为设计如此, UTM 同样 |

## PR 拆解

实际一次性落 (hotfix 性质, 不切多 PR):

- **PR-1** (本次): 全部改动一次性合入
  - 新建 `CGSPrivate.swift`
  - 重写 `FramebufferHostView.swift` 键盘部分 + overlay
  - `HVMView.swift` 释放快捷键改 Cmd+Opt
  - `make build` + `make install` 通过

## 未决事项

| 编号 | 问题 | 当前默认 | 决策时机 |
|---|---|---|---|
| I1 | 是否给用户暴露 "Cmd+Opt vs Ctrl+Opt" 二选一偏好 | 硬编码 Cmd+Opt | 用户反馈第一版 OK 不做; 若有冲突再加偏好 |
| I2 | 是否把 `macStyleShortcuts` 改成 UTM 风格双向 swap (cmd↔ctrl) | 保留单向 cmd→ctrl | 行为变化大, 等用户主动要求 |
| I3 | VZ 后端是否也加 captured 双态 | 不加 (VZ framework 已经 `capturesSystemKeys = true`) | 用户没抱怨 VZ 卡键, 不动 |
| I4 | 工具栏 / 详情页是否加 capture 切换按钮 | 不加, 仅 Cmd+Opt | UI 复杂度 vs 触发率权衡, 后续看用户反馈 |
| I5 | captured 模式下鼠标是否切相对坐标 (UTM 真正的 capture mode) | 不切 (usb-tablet only abs) | 涉及 guest 端硬件配置变更, 范围扩大太多, 推后单独提案 |

## 决策溯源

- 2026-05-24 用户报告"键盘映射有问题, shift/cmd/ctrl/alt 卡按 + cmd+xxx 失效"
- 同日调研 UTM `VMMetalView.swift` 确认 modifier 镜像 + 失焦清光 + Cmd+Opt 三件套是业界共识
- 用户敲定方案 C (完整 capture 双态), 不切渐进
- 代码一次性合入 (单 PR)

## 相关文档

- [../v1/DISPLAY_INPUT.md](../v1/DISPLAY_INPUT.md) — 现状描述 (键盘 first responder 与 release / QEMU 输入捕获双态)
- [../v1/QEMU_DISPLAY_PROTOCOL.md](../v1/QEMU_DISPLAY_PROTOCOL.md) — HDP wire 规范 (cursor / LED 同步通路)
- UTM `Platform/macOS/Display/VMMetalView.swift` — 参考实现
