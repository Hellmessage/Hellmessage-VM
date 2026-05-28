# 跨 session TODO 清单

> 总览 / 持续追踪 / 防遗忘. 每开新 session 先读这份, 知道当前节奏在哪里.
>
> 跟 [docs/v1/ROADMAP.md](v1/ROADMAP.md) 不同 — ROADMAP 是历史 v2 残余清单, 已基本归档.
> 本文件聚焦**当前进行中**的工作 + **新发现的待办**.
>
> **最后更新**: 2026-05-29 (Phase D 进行中 4/7, D1+D2+D3+D4 已合, 剩 D5~D7; Esc 关 dialog 后 hover 需 click 激活 known issue 留待 D7 后深挖)

---

## 当前主线 — 新 GUI 重构 (docs/v4/NEW_GUI.md)

### Phase T (Theme) — ✅ 全合
- [x] **T1** Theme/ 7 个 token 文件 (HVMColor / Font / Space / Radius / Border / Motion / HVMTheme namespace) — commit `a991024`
- [x] **T2** NewGUIRootView Showcase 演示页 (色板 / 字号 / spacing / radius / motion) — commit `a991024`

### Phase C (Components) — ✅ 全合
- [x] **C1** HVMUI.Button (5 variant + hover/press/disabled + probe) — commit `e1e80b8`
- [x] **C1b** HVMUI.Button 按 R1-R9 重做 (3 size + focus ring + loading + iconPosition) — commit `5b89ac4`, polish in `f0d4787`
- [x] **C2** HVMUI.TextField + HVMUI.SecureField (size + 7 状态 + focus ring + a11y + 设计规范 R1-R9) — commit `81d510f`
- [x] **C3** HVMUI.Toggle + HVMUI.Checkbox (3 size + spring + indeterminate + probe) — commit `6580347`, fixes `07573af` `e10f81b`
- [x] **C4** HVMUI.Select (下拉 + 搜索 + 键盘导航 + generic value + probe) — commit `0d76252`, fixes `f0d4787` `03dbdaf` `94b9770` `458828a` `d6fbc6d`
- [x] **C5** HVMUI.Section + HVMUI.Divider + HVMUI.Badge (业务页骨架基石; layered shadow + double border + 6 variant Badge + h/v Divider) — commit `5a23c51`
- [x] **C6** HVMUI.Icon (5 size + 9 color) + HVMUI.KbdHint (typed Key enum + size) + HVMUI.Tooltip (自绘 hover 500ms delay + 4 edge + 可选 kbd hint) — 辅助组件
- [x] **C7** probeID 必传 (breaking change: 6 组件 `probeID: String?` → `probeID: String`) + 派生 probe id (Select trigger/search) + 命名规范 `<scene>.<role>.<element>` 升进 NEW_GUI.md R6 + CLAUDE.md "UI 控件使用约束" 节 — commit `2179639`
- [x] **C8** Showcase 整理 — 顺序重组 (header → 操作类 Button → 输入类 TextField → 开关类 Toggle → 复杂类 Select → 容器装饰 Section/Icon → Theme token 参考) + sectionCard helper delegate `HVMUI.Section` (统一组件不留独立 helper) + 每节加 description 副文案. 视觉回归 baseline 截图**不存进 repo** (PNG 占空间, 临时用 hvm-dbg gui screenshot 即可)

### Phase D (Dialog) — 进行中 4/7
- [x] **D1** DialogHost overlay + DialogPresenter + ObservableObject + @EnvironmentObject + DialogHandle stack 多 dialog 嵌套支持; **未**迁移 Select popover (留独立后续 PR, 当前 zIndex 反向 hack 暂留)
- [x] **D2** FocusTrap (content .disabled when isPresenting) + EscRouter (.focusable + .focusEffectDisabled + .onKeyPress(.escape) 关栈顶) + dialog 永远在顶 (.zIndex 999_999) + Esc 卡死 fix (dismissTop 前 dialogFocused=false) + 嵌套 Esc 噔噔提示音 fix (.onChange of stack.count re-focus)
- [x] **D3** HVMUI.AlertDialog (info / warn / error / success 4 档) + dialog.alert async API + 派生 probe id (`<probeID>.confirm` / `.close`) + present onDismiss 回调让任何关闭路径都 resume continuation
- [x] **D4** HVMUI.ConfirmDialog (含 destructive 主按钮) + dialog.confirm async API + ResumeCoordinator 保证 Esc/X/取消/主按钮 任一关闭路径只 resume 一次 ConfirmResult
- [ ] **D5** HVMUI.InputDialog (单字段 + 多字段表单 + validation hook)
- [ ] **D6** HVMUI.WizardDialog (步骤指示器 + 上下一步 + 取消)
- [ ] **D7** Dialog probe id 命名规范固化 + 文档

### Phase L (Lint) — 待
- [ ] **L1** scripts/check-gui-tokens.sh 防漂移 lint script (扫 GUI/ 内 Color(red:/ Font.system(size:/ padding(数字) 等硬编码)
- [ ] **L1.5** Makefile 加 `make check-gui` target 接 L1 script

---

## 已知 work-around / known issue

### Dialog 关闭后 hover 需 click 一次激活 (PR-D2/D3/D4 已知)

- **现象**: Esc 关 dialog 后, 鼠标移动到界面任何按钮**不显示 hover 高亮**, 需鼠标 click 一次界面任意位置才激活 hover. (X 按钮关 / 主按钮关 / 取消按钮关 都 OK, 只有 Esc 关后有此问题)
- **根因推测**: SwiftUI `.focused($dialogFocused)` 在 Esc 关 dialog 时让 dialog 渲染层失去 first responder, 主 view 的 NSTrackingArea 没自动重新 fire mouseMoved 事件让 hover 重启
- **尝试过的失败修法**: NSEvent local monitor / NSApp.activate + makeKey / makeFirstResponder(nil) / CGWarpMouseCursorPosition 均无效或引入新 bug (界面卡死)
- **当前 work-around**: 无, 用户需 click 一次激活
- **后续考虑**: D2 之外的 EscRouter 路径 (例 NSWindow keyEquivalent override, 或者业务页接入时单独处理), 留 D7 Probe 规范 / PR-D8 之后再深挖

### PR-D1 work-around 清理 (PR-D8 OverlayContainer 迁移)

这些是 PR-C4 修 popover 时的治标手段, 后续 PR-D1 OverlayContainer 落地后应清掉.

- [ ] **ScrollView VStack children 反向 zIndex** ([NewGUIApp.swift](../app/Sources/HVM/GUI/NewGUIApp.swift)) — `headerBlock.zIndex(110)` → `footerBlock.zIndex(10)`, 让上面 sectionCard 内的 Select popover 浮在下方 sectionCard 之上. PR-D1 后 popover 渲染到 root-level ZStack, 不再需要此 hack.
- [ ] **selectsBlock 内 VStack children 反向 zIndex** ([NewGUIApp.swift](../app/Sources/HVM/GUI/NewGUIApp.swift)) — `fieldRow Basic .zIndex(40)` → `probe HStack .zIndex(10)`, 让上面 fieldRow 内的 popover 浮在下方 fieldRow 之上.
- [ ] **Select trigger.zIndex(10) / errorMessage.zIndex(1)** ([HVMUISelect.swift](../app/Sources/HVM/GUI/Components/HVMUISelect.swift)) — 让 popover 浮在 errorMessage 之上. PR-D1 后 popover 渲染脱离 VStack 层级, 此 zIndex 也可删.
- [ ] **Select popover 仍受 ScrollView clip 限制** — 如果 popover 超 ScrollView 可见区底部, 会被裁. 当前靠 Showcase 顺序调整 (selectsBlock 放最上) 缓解. PR-D1 后浮窗渲染到 NSWindow 顶层完全脱离 ScrollView.

---

## 未决事项 (Decisions, docs/v4/NEW_GUI.md)

| ID | 决策 | 当前状态 |
|---|---|---|
| D1 | accent 色用青 `#06B6D4` | ✅ 已决 (用户 2026-05-28 拍板) |
| D2 | mono 字体: SF Mono / JetBrains Mono / 系统 default | 待 (T1 内已用系统 monospaced, 暂保留) |
| D3 | Dialog 蒙底: `Color.black.opacity(0.5)` vs blur material | 待 (D1 PR 内决) |
| D4 | HVMSelect 搜索算法: 子串 / fuzzy / 拼音首字母 | ✅ 已用子串 (C4 已合, 中文友好) |
| D5 | Wizard 步骤指示器位置: 顶部水平 vs 左侧垂直 | 待 (D6 PR 内决) |
| D6 | 业务页迁移顺序 — 第一个业务页是哪个 | 待用户拍板; 建议 VM 列表 |
| D7 | Dialog 加 "撤销" 提示 (例: 删除后 5s 内可撤) | 待 (业务页迁移时按需) |
| D8 | 老 GUI 何时退役 | 待 (新 GUI 全业务页迁完后) |

---

## 业务页迁移 (新 GUI 基础设施全合后)

每个业务页独立子稿 `docs/v4/NEW_GUI_<feature>.md`. 引 NEW_GUI.md 作 R1-R9 + Theme/Components/Dialog 基础设施前置依赖.

- [ ] `docs/v4/NEW_GUI_MAIN_LAYOUT.md` — sidebar + detail 两栏主窗口骨架 + 工具栏
- [ ] `docs/v4/NEW_GUI_VM_LIST.md` — VM 列表项 (running/stopped/encrypted 状态 / 加密锁图标 / context menu)
- [ ] `docs/v4/NEW_GUI_VM_DETAIL.md` — 详情页 (overview / sharing / network / disk / 加密 等 section)
- [ ] `docs/v4/NEW_GUI_CREATE_VM.md` — 创建 VM Wizard (复用 HVMUI.WizardDialog)
- [ ] `docs/v4/NEW_GUI_ENCRYPTION.md` — 加密 / 解密 / rekey dialog
- [ ] `docs/v4/NEW_GUI_FILE_TRANSFER.md` — 文件传输 dialog
- [ ] `docs/v4/NEW_GUI_NETWORK.md` — 网络配置 + vmnet daemon 控制
- [ ] `docs/v4/NEW_GUI_FRAMEBUFFER.md` — VM 窗口 framebuffer 嵌入 (HDP 接入)

---

## 老 GUI 残余 (D8 触发后)

- [ ] 老 GUI `app/Sources/HVM/UI/**` 整套删除 (Style / Content / Dialogs / Shell / Detached / IPSW / App / Settings 全 ~70+ 文件)
- [ ] `app/Sources/HVM/HVMApp.swift` 删除 (HVMAppDelegate + HVMAppLauncher)
- [ ] `app/Sources/HVM/main.swift` 删除 `#if NEW_GUI / #else` 分流, 永远走新 GUI
- [ ] Makefile 删除 `GUI ?= new` 开关 + 删 `GUI=old` 分支
- [ ] docs/v1/GUI.md 删除老 GUI 现状描述, 替换成新 GUI 现状

---

## 用户反馈待复现 / 确认

用户视觉反馈, 修复合入后等用户再次确认是否真解决.

- [ ] **"那根青色细线"** ([commit `94b9770`](../README.md) 描述, [`458828a`](../README.md) 已修) — 用户 2026-05-29 看到 popover 内有青色细线, 推测是 sectionCard `.overlay(border)` 透出. 修法已落 (border 移到 `.background` 内). **用户再次开 popover 时若仍见到, 提供新截图重新定位**.
- [ ] **Showcase 字段 demo 共享 binding 错觉** — Showcase 内多个相似字段共享 `$vmName` / `$autoStart` 等 binding, 用 hvm-dbg gui type 一个会同步影响其他. 业务页接入时每个字段独立 binding, 此 Showcase artifact 不影响生产.

---

## 跨主题低优 (单独提案才动手)

- [ ] **PR-D1 OverlayContainer 之后**: VM detail 页 popover (例如"添加共享目录"小卡片) 也走全局 OverlayContainer
- [ ] **i18n** — 设计稿明确 NEW_GUI.md 不引 LocalizedStringKey, 硬中文. 未来真要 i18n 时单独立项
- [ ] **VoiceOver / a11y 全覆盖** — R5 规范要求 accessibilityLabel/Hint/Value, 已落 C1-C4 字段类组件. 业务页接入时统一审计一遍.
- [ ] **键盘快捷键全局集成** — Cmd+N 新建 VM / Cmd+, 设置 / Cmd+W 关窗 等. 业务页接入时统一规划.

---

## 治理

- 完成的项 `[x]` 标记 + 加 commit hash 引用
- 下次 session 开始时先读这份, 看上次卡在哪
- 完成全 Phase C/D/L 后, 本文件可压缩, 把已合 PR 归档到 docs/v4/NEW_GUI.md 的"实现历史"小节
