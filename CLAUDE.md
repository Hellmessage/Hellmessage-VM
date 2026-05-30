# CLAUDE.md

**所有回答必须使用中文**

本项目走 Apple Virtualization.framework 路线。

## 文档约束

- `CLAUDE.md` 只存放约束, 不放其他东西
- `README.md` 存放项目说明(开发完成后再写)
- `docs/` 下的设计文档是决策沉淀, 约束变更必须同步更新
- `docs/TODO.md`: 跨 session TODO 清单, 当前进行中工作 + 待办项追踪; **每开新 session 先读**, 知道节奏卡在哪

## 身份与命名约束 **必须遵守**

- App bundle ID: `com.hellmessage.vm`(已在 Apple Developer 注册, Team ID `Q7L455FS97`)
- App 显示名: `HVM`, 产物 `HVM.app`
- CLI 工具: `hvm-cli`
- 调试探针: `hvm-dbg`
- VM bundle 扩展名: `.hvmz`(与 hell-vm 的 `.hellvm` 区分, 两项目 bundle 可共存于同一目录不冲突)
- 用户数据根: `~/Library/Application Support/HVM/`(VMs/ + cache/ + logs/)

## 交付约束 **必须遵守**

- 代码变更后必须 `make build` 验证
- `make build` 通过才算任务完成, 否则视为未完成
- 空白 Mac 上 `make build` 一条命令跑通, 除 Xcode Command Line Tools 和 Apple Developer 证书外**零手动依赖**
- **HVM 主体**不引入 Homebrew / Vendor / 编译外部 C 项目等重依赖, 所有逻辑走 Swift + Apple framework
- **QEMU 后端例外**(详见下「QEMU 后端约束」): 打包者机器允许 `scripts/qemu-build.sh` + `scripts/edk2-build.sh` 自动安装 Homebrew 与一组锁定 brew 包, 仅用于编译 QEMU + EDK2 源码; **最终用户机器**仍零依赖, 所有运行时产物随 `.app` 包内分发
- `make build` 自身**不**编译 QEMU / EDK2; 缺 QEMU 产物时 `.app` 仍可构建但不嵌入 QEMU 后端; 完整发布走 `make build-all`(先 `make edk2` + `make qemu` 再 `make build`)

## 修复验证约束 **必须遵守**

任何 bug 修复 / 新功能落地后, 仅 `make build` 通过 **不算完成**, 必须做"完整测试":

1. **`make build` + `make install`** — 编译 + 签名 + 同步 `/Applications/HVM.app`
2. **同模式遗漏点扫查** — 用 `grep` 过一遍仓库, 找出所有"看起来一样的相关调用点", 全部修完才能交差. 例: 修 "加密 VM 改 config" 路径时必须 `grep BundleIO.save / BundleIO.load` 整树, 把 ISO 切换 / cpu/mem 编辑 / disk 加删 / 剪贴板共享等所有写 config 的地方一起修, 不能只修用户当前撞到的那一个
3. **smoke 验证 binary 存活** — `hvm-cli list` / `hvm-dbg --help` / 其他 readonly CLI 命令, 至少跑一遍确认进程不崩
4. **改动模块的 e2e 走一遍** — 加密 VM 改动走 hvm-cli 创建 → encrypt → 锁定 → 解锁 → 改 config → 启动验证; UI 改动走 `hvm-dbg gui` 自动化 (HVM_GUI_PROBE=1 启 server) 跑通主路径; 命令行改动直接 `build/hvm-cli <subcommand>` 跑实际命令
5. **回归扫查** — 改动涉及共用 helper 时 (例如 `AppModel.saveConfig`), grep 所有调用方确认无遗漏
6. **明确报告未测的项** — 若某些路径无法在本地复现 (例如多 VM 并发 / 跨 Mac portable), 在交付报告中显式列出 "**未实测**: ...", 不假装测过
7. **真机操作受限时**: 若需要用户密码 (例如加密 VM 启动 / vmnet daemon 安装) 不能自动跑, 创建 throwaway 测试 VM 用 agent 自家密码跑通主路径; 实在跑不了的明确告知用户哪步要他配合

反例 (历史教训): "加密 VM `安装完成` 按钮报 Bundle 未找到" 这条, 当时只修了 `installCompletedAction` 一处, 没扫 `BundleIO.save` 全树, 留下 ISO / cpu/mem / disk 等所有同模式调用点全有同 bug; 直到用户撞到才发现. 必须避免。

## 构建约束

- 所有构建产物输出到根目录 `build/`(`build/HVM.app`, `build/hvm-cli`, `build/hvm-dbg`)
- SwiftPM 是唯一构建系统, 产物由 `scripts/bundle.sh` 组装 + 签名成 `.app`
- 同时兼容 Xcode: `xed app/Package.swift` 可直接打开、编辑、构建(产裸二进制, 无 entitlement, 仅用于开发期调试)
- 真实运行必须走 `make build`(出带 entitlement 签名的 .app)

## 代码约束

- 代码文件使用中文注释
- 模块命名前缀 `HVM`(与主 App target 同名)
- SwiftPM 6 tools-version, 目标 platform macOS 14+
- 仅依赖官方 framework + 以下白名单内的三方包, **不引白名单外的任何三方包**:
  - `swift-argument-parser` (CLI 参数解析)
  - `Yams` (YAML 1.1 解析, libyaml C 包装; BundleIO 读写 config.yaml 用)

## 测试约束 **必须遵守**

- **不写 XCTest** — `import XCTest` / `XCTestCase` / `XCTAssert*` 一律禁止
- 原因: XCTest framework 仅 Xcode.app 自带, 用户机器 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools` (CLT only) 时 swift test 直接 `no such module 'XCTest'` 跑不起. 历史 38 个测试在 CLT 设置下静默失效, 维护成本高反误判 "测试通过"
- **不在 `app/Tests/` 下落任何 .swift 文件** — Tests/ 整个目录已清, 不重建. Package.swift 不再带 `.testTarget(...)`
- **验证手段**: 走 `make build` (编译期保证) + 真机 e2e (`hvm-cli` / `hvm-dbg gui` 自动化). 不用单测框架
- 例外: 若未来真要加测试, 先在 docs/v3/ 起设计稿讨论框架选型 (swift-testing / Quick-Nimble / 纯 Swift assertion 函数), 不得直接落 XCTest

## 签名与 Entitlement 约束

- 必须的 entitlement: `com.apple.security.virtualization`(Apple Developer 账号自带, 不用申请)
- 签名方式: 自动 `codesign --sign "Apple Development"` ad-hoc 签名, 不公证不分发
- 桥接网络 (`com.apple.vm.networking`) 已向 Apple 提交申请, 审批中。批准前**只实现 NAT 网络**, 审批后再加 `.bridged` case
- 签名相关代码或日志**不得输出任何 team ID / 证书 SHA / 私钥路径**

## GUI 约束

- 黑色风格界面 (中性深灰 #18181B 主底, 不纯黑)
- **弹窗只能通过点击右上角 X 按钮关闭**, 禁止点击遮罩层关闭
- 所有错误对话框走统一 ErrorDialog, 禁止用 `NSAlert`
- 主窗口默认深色, 不跟随系统主题
- VM 创建向导中 Windows 选项必须标注「**实验性 (QEMU 后端)**」, 与 macOS / Linux 视觉区分
- **加密 VM 在 GUI** (PR-11 已落):
  - 列表 sidebar 显示 `lock.fill` 锁图标 + "Encrypted" 标签
  - `VMListItem.config: VMConfig?` 可选 — 加密 VM 解锁前 nil, 走 routing JSON 拿 displayName/id; 详情页 view 必须 `if let cfg = item.config` 兜底
  - 启动加密 VM 走 `requestStartWithPasswordIfNeeded` 自动弹 `EncryptionPasswordDialog`; 不要直接调 `start(item)` 不传 password
  - 创建 / clone / encrypt / decrypt / rekey 全部走 dialog (CreateVMDialog 的加密 toggle / CloneVMDialog 加密源 prompt / Encrypt+Decrypt+RekeyVMDialog 三独立 dialog), 加密事务进行中 `closeAction = nil` 不可关
  - 加密事务后台 `Task.detached` 跑, 完成回主线程刷 list — 不阻 UI
  - VZ-sparsebundle 加密 GUI 暂未接入 (推后跟 ENCRYPTION.md v2.4 一致)
- **文件传输** (Sharing 区, 设计稿 `docs/v3/FILE_COPY.md`):
  - 详情页 Sharing 区 [传文件到 VM…] / [从 VM 取文件…] 按钮 → NSOpenPanel/NSSavePanel → `FileTransferDialog`
  - 仅 QEMU 后端 + VM running 时按钮可用, 其它态 disabled + 灰文案
  - dialog 三态: form / running (closeAction = nil 不可关) / done; 取消语义 v1 不支持中断 chunk 循环
  - IPC 走 `Task.detached` 跑 `SocketClient.request` (长事务 600s 不能阻 main)
  - VZ 后端走 `VZSharedDirectory` + virtiofs 的方案推后单独提案
- **Cmd+V 文件粘贴** (设计稿 `docs/v3/HOST_FILE_PASTE.md`, 跟 FileTransferDialog 走不同通路):
  - 用户在 Finder Cmd+C 文件 → 切到 VM framebuffer view 按 Cmd+V → 自动走 SPICE vdagent VD_AGENT_FILE_XFER_* 流到 guest, 落 **guest `~/Downloads`** (不是当前焦点目录, 那个能力推 v2 自家 guest agent)
  - **仅 QEMU 后端 + Linux/Windows guest** (vdagent 通路). VZ 后端 / macOS guest 不接 (vdagent 不存在)
  - **拦截条件**: `FramebufferHostView.keyDown` + `macStyleShortcuts=true` + Cmd 单按 (排除 Cmd+Opt / Cmd+Shift / Cmd+Ctrl) + NSPasteboard 有 file URLs. 三条全过才吃掉这次 Cmd+V; 任一不过走老的文本粘贴路径
  - **vdagent 单 socket 多协议复用** — `PasteboardBridge` (文本) / `FilePasteBridge` (文件) / `SpiceWebdavServer` (共享目录) 共享同一 `QemuHostState.shared.vdagent` 实例, 不同 callback slot 不抢; 启动顺序 vdagent connect → PasteboardBridge install (按 config) → FilePasteBridge **lazy install** (第一次 `clipboard.paste-files` 请求到达时)
  - **边界**: 文件夹 skip + 通知 "暂不支持"; 单文件 > 4 GiB skip + 引导走共享目录; 多文件串行不并发 (vdagent socket 单 client + SPICE chunks 不可 interleave); v1 不支持中途取消
  - **chunk 大小硬约束**: `VdagentClient.fileXferChunkSize = 2000` 字节. SPICE upstream `VD_AGENT_MAX_DATA = 2048`, 减 chunk header (8B) + msg header (20B) + DATA id/size (12B) = 2008, 取 2000 保守. **禁止**放大这个常量 (会让 spice-vdagent 解码失败)
  - **超时**: CAN_SEND_DATA 30s (探 guest spice-vdagent 是否在线) / 终态 SUCCESS 600s (单文件 4 GiB @ 50 MiB/s 上限). 超时不 hang, 返 fail 让 GUI 弹 ErrorDialog
  - **GUI 反馈**: 成功 → `UNUserNotificationCenter` 原生通知 (首次 requestAuthorization, 拒绝 → silently 不通知); 失败 / 部分跳过 → `ErrorDialog` 列原因. **禁止** NSAlert
  - **host → guest 文件传输统一走 vdagent file_xfer (后续方向)** — 当前 `FileTransferDialog` 还走 QGA (1-10 MB/s), 后续应迁到 vdagent (~50 MB/s) 统一通路. 暂保留两条通路, v1.1 决策合并
  - **测试**: `hvm-dbg paste-files <vm> --file ...` 模拟整条通路, 不依赖 framebuffer view 的 NSPasteboard 拦截 (server 端走相同 `clipboard.paste-files` IPC, 但绕过 Cmd+V 触发)
- **键盘捕获 / 释放快捷键** (UTM 风格, 设计稿 `docs/v3/INPUT_CAPTURE.md`):
  - **统一 `Cmd+Opt`** 切换捕获 (VZ + QEMU 两后端一致). 老的 `Cmd+Ctrl` 因跟 macOS 系统快捷键 (Mission Control / 截图 / 第三方 app) 严重冲突已废弃, **禁止**再用
  - **QEMU 后端 captured 模式**: `CGSSetGlobalHotKeyOperatingMode(.disable)` (Skylight 私有 API, `HVMDisplayQemu/CGSPrivate.swift`) 禁用 macOS 全局热键, cmd+tab / cmd+space 也送 guest. 右上角 `⌘⌥ 退出捕获` overlay 显式提示
  - **退出 captured 闭环**: `viewWillMove(toWindow:nil)` / `resignFirstResponder` / `inputCaptureEnabled=false` 必须查 `if isCaptured { releaseCapture() }`, 否则系统热键留在 disable 状态用户无法 cmd+tab 切别 app — **体验灾难**
  - **修饰键状态镜像** (修 "shift/cmd 一直按着" 老 bug): `FramebufferHostView` 维护 `lastModifiers` + `pressedModifierQcodes` + `pressedNormalKeyQcodes` 三件套; `flagsChanged` 用 set diff 双向发, `becomeFirstResponder` sync 当前实时 modifier, `resignFirstResponder` / `viewWillMove(toWindow:nil)` / 进出 captured 时 `releaseAllPressedKeys()` 一并清光. **禁止**只清 normal key 不清 modifier
  - **左右修饰键独立映射**: NSEvent.ModifierFlags raw bit (`leftShift = 0x2`, `rightShift = 0x4` 等) → qcode `shift` / `shift_r` 等. 合成事件兜底走左侧
  - **VZ 后端**只统一释放快捷键 (Cmd+Opt), **不**加 captured 双态 (VZ framework 已经 `capturesSystemKeys = true` 把 cmd+tab 转 guest), **不**做 modifier 镜像 (VZ 自己管)

## UI 控件使用约束 **必须遵守**

防止业务页与 Theme 漂移, 减少视觉/交互不一致. 边界仅约束业务层 (`app/Sources/HVM/UI/{Content,Dialogs,IPSW,Shell}/**`); `app/Sources/HVM/UI/Style/**` 是组件实现层, 不受约束.

- **下拉框 / 单选**: 必须使用 `HVMFormSelect` 或 `HVMNetModeSegment`, **禁止**直接用 SwiftUI `Picker` / `Menu`
- **按钮**: 必须使用 `PrimaryButtonStyle` / `GhostButtonStyle` / `IconButtonStyle` / `HeroCTAStyle` / `PillAccentButtonStyle` 五种之一, **禁止**裸 `Button` 不带 `.buttonStyle(...)` (除非是嵌在 list row / list cell 里走 `.plain` 的纯点击区)
- **输入框**: 必须使用 `HVMTextField`, **禁止**直接用 SwiftUI `TextField` / `SecureField` (含 `.textFieldStyle(.roundedBorder)` / `.textFieldStyle(.plain)` 等)
- **开关**: 必须使用 `HVMToggle`, **禁止**直接用 SwiftUI `Toggle`
- **Modal 弹窗**: 必须套 `HVMModal` 容器 (顶栏标题+X / content / 可选 footer), **禁止**业务侧再自己拼 `ZStack(蒙底 + 居中卡片)`. 装机 / 下载等不可中断流程: `closeAction = nil` 隐藏 X
- **Section 卡片**: 详情区分组用 `TerminalSection(title) { ... }`, **禁止**自画 "标题 + 卡片" 复读
- **同需求复用**: 碰到与上述五类相同的需求, **必须**用现有自绘组件; 现有组件不满足时**先扩展 / 改造现有组件**, 而不是新建别名或绕开自绘
- **新组件准入**: 新增"自绘 X"必须放在 `app/Sources/HVM/UI/Style/HVMX.swift`, 并把上述清单里加一行约束; 不得散落到业务文件里
- **风格 token**: 所有颜色 / 字号 / 间距 / 圆角必须走 `HVMColor` / `HVMFont` / `HVMSpace` / `HVMRadius`, **禁止**业务侧硬编码 `Color(red:...)` / `Font.system(size:...)` / 数字 padding
- **mono 字体使用边界**: `HVMFont.mono` / `HVMFont.monoSmall` 仅用于"代码值" (UUID / MAC / 文件路径 / shell 命令展示 / build 号), 正文 / 标题 / 按钮 / 表单一律 SF Pro

### 新 GUI (HVMUI) 强制 probeID — 业务页全覆盖自动化测试

新 GUI (`app/Sources/HVM/GUI/**`, `GUI=new` 编译路径) 所有交互组件 `probeID: String` **必传** (非可选). 业务侧每个实例都得给唯一 probe id, 编译期 enforce.

- 影响组件: `HVMUI.Button` / `HVMUI.TextField` / `HVMUI.SecureField` / `HVMUI.Toggle` / `HVMUI.Checkbox` / `HVMUI.Select`
- 不影响 (非交互): `Section` / `Divider` / `Badge` / `Icon` / `KbdHint` / `Tooltip`
- `isDisabled` 时跳过 probe 注册 (即使 probeID 已传), 防 hvm-dbg gui click disabled 控件触发副作用. 但 disabled 实例仍**必须**传 probeID (保持 codebase 习惯 + 切换 enable/disable 时不丢 probe id)
- 命名规范 `<scene>.<role>.<element>`:
  - 业务页例: `dialog.encrypt.field.password` / `toolbar.button.create` / `detail.section.network.toggle.bridged` / `vmlist.row.item-<vmID>`
  - Showcase: `showcase.<role>.<element>`
  - **唯一性**: 同 view 树内不重复
- 派生 probe id (复合控件): 不需业务侧传, 组件内部自动派生
  - `<select.probeID>.trigger` — Select trigger button
  - `<select.probeID>.search`  — Select 内 search field
  - **Dialog 系派生** (业务侧只传 base, dialog 内子控件自动派生; 完整规范见 [docs/v3/HVM_DBG_GUI_PROTOCOL.md "Dialog probe id 命名规范" 节](docs/v3/HVM_DBG_GUI_PROTOCOL.md)):
    - `<dialog.probeID>.close` — 右上 X (all dialogs)
    - `<dialog.probeID>.confirm` — Alert / Confirm / Input 主按钮
    - `<dialog.probeID>.cancel` — Confirm / Input / Wizard 副按钮 (取消)
    - `<dialog.probeID>.field.<idx>` — InputDialog 第 idx 个字段
    - `<dialog.probeID>.prev` / `.next` / `.complete` — WizardDialog 导航 (按 currentIndex 派生当前)
    - `<dialog.probeID>.step.<idx>` — WizardDialog 步骤指示器 (仅 past step 注册, current/future 不点)
- 业务侧 closure / binding 必须 `@MainActor @Sendable` (跟 ProbeAction 签名对齐)

**为什么强制**: 业务侧偷懒不传 probeID 会让 hvm-dbg gui 自动化覆盖率漏斗, 业务页接入 dialog / wizard 后再补麻烦. 必传让 "每个可点 / 可输 / 可切控件都能被自动化测" 成为编译期保证 (而不是 lint 后置). 详细规范见 [docs/v4/NEW_GUI.md "R6" 节](docs/v4/NEW_GUI.md) + [docs/v3/HVM_DBG_GUI_PROTOCOL.md "Dialog probe id 规范" 节](docs/v3/HVM_DBG_GUI_PROTOCOL.md).

### 新 GUI 主界面 + 数据 store (业务页 #1, docs/v4/NEW_GUI_MAIN_LAYOUT.md)

新 GUI (`GUI=new`, 默认) 主界面是 `app/Sources/HVM/GUI/Layout/MainLayoutView.swift` 两栏骨架 (toolbar / sidebar 240 + detail / statusbar). `HVM_GUI_SHOWCASE=1` 退回组件 Showcase (`NewGUIRootView`).

- **VM 控制走 `HVMControl` library, 单一来源**: 枚举 / 启停 / 删除 一律走 `VMCatalog.list` / `VMControl.{start,stop,kill,status,delete}` (target `HVMControl`, hvm-cli + 新 GUI store 共用). **禁止**业务侧 / store 再抄一份 `BundleDiscovery` + `BundleLock` + `HostLauncher` 拼装逻辑 (历史教训: 同模式逻辑抄多份必漂移). 新增控制能力先加到 `VMControl`, 两端自动同步
- **数据 store `NewGUIStore`** (`@Observable @MainActor`, `GUI/Store/`): 不依赖老 `AppModel`, 不背 embeddedID / detached 窗口等老 GUI 耦合. 1Hz `refresh()` 内 `if fresh != vms` 守卫 (VMSummary Equatable) 防无谓重绘. 动作失败走 `lastError` (HVMError.userFacing) 冒泡, `MainLayoutView` `.onChange` 弹 `dialog.alert(level:.error)`. 注入走 `.environment(store)` + 子 view `@Environment(NewGUIStore.self)`; dialog 仍走 `@EnvironmentObject HVMUI.DialogPresenter` (两套注入并存)
- **detail 按钮动作读 `store.selected` (不捕获渲染时 vm)**: `hvmProbe` onAppear 只注册一次, view 复用不重注册 → probe 闭包会 stale. 真人点击无此问题 (SwiftUI 闭包是当前的), 但 hvm-dbg gui 自动化会撞旧 vm. 动作读 `store.selected` 让它始终命中当前选中项. **新业务页凡 "静态 probeID + 随选中变化的闭包" 都照此处理**
- **文件 / 类型名不得与老 GUI `UI/**` 撞** (SwiftPM 用文件名出 .o, 同模块两同名 struct 也重定义): 撞名时新 GUI 侧加 `NewGUI` 前缀 (例 `NewGUISidebarView` 避开老 `UI/Content/SidebarView.swift`). 老 UI/ 未 `#if` 门控, `GUI=new` 时仍编译
- **后端启停验证用 throwaway / 用户授权的 VM**: 启停 e2e 走 `hvm-cli` (稳定脱离 shell 会话) 或 `make run-app` (`open` 启 GUI 脱离会话); **不要**手动 `./HVM.app/Contents/MacOS/HVM &` 后台启 GUI 再启 VM (孙子 QEMU 进程随 shell 会话清理被 `signal 9` 杀, 误判启动失败)
- **无顶部 toolbar**: 窗口顶部仅原生标题栏. 新建 VM = sidebar 列表底部全宽主按钮 (`sidebar.button.create`); 刷新 = statusbar 右侧工具图标 (`statusbar.button.refresh`, 列表 1Hz 自动刷新, 手动为兜底)
- probeID 命名: `sidebar.button.create` / `statusbar.button.refresh` / `vmlist.row.item-<vmID>` / `vmlist.confirm.delete-<vmID>` / `vmlist.input.password-<vmID>` / `detail.button.{start,stop,kill,delete}` / `main.alert.error`

## VZ 能力边界约束 **必须遵守**

以下能力 **VZ 不支持**, 即使用户要求也不得尝试实现, 直接提示用户能力边界:

- **x86_64 / riscv64 guest** — VZ 只支持原生 arm64, 无 TCG 翻译
- **VZ 后端不支持 Windows guest** — VZ 无 TPM, Win11 无法装; Win10 ARM 已无 ISO 来源。**Windows arm64 由 QEMU 后端承载**, 详见 `docs/QEMU_INTEGRATION.md`
- **host USB 设备直通** — VZ API 不支持 `usb-host` 类语义, 只支持虚拟 USB mass storage。若用户要求插 U 盘直通, 明确告知做不到, 建议 `dd` 成 image 再 `VZUSBMassStorageDevice` 挂载
- **多 VM 共享同一 bundle** — 一个 `.hvmz` 同时只能被一个进程打开, 用 fcntl flock 互斥
- **热插拔 CPU/内存** — VZ 不支持运行时改 CPU/mem 数量, 必须停机重配

## 支持的 Guest OS 约束

- **macOS** — Apple Silicon only, 通过 IPSW + `VZMacOSInstaller` 装机, **仅 VZ 后端**
- **Linux** — arm64 ISO 启动安装, 装完切 `bootFromDiskOnly` 直走硬盘; **默认 VZ 后端**, 可选 QEMU 后端 (双后端)
- **Windows** — arm64 only, **仅 QEMU 后端** (VZ 不支持), 配置 `engine=qemu` 强制
- **其他** — 不支持, 配置不允许保存其他 `GuestOSType`

## QEMU 后端约束 **必须遵守**

QEMU 后端用于覆盖 VZ 不承接的 Windows arm64 与可选 Linux arm64 场景, 详见 `docs/QEMU_INTEGRATION.md`。

- **架构限定**: 仅 `qemu-system-aarch64`(Apple Silicon 宿主机 + AArch64 guest), 不打包 x86_64 / riscv 等其他 `qemu-system-*` 目标
- **版本锁定**: 包内 QEMU 与 `scripts/qemu-build.sh` 中的 `QEMU_TAG` (当前 `v10.2.0`), EDK2 与 `scripts/edk2-build.sh` 中的 `EDK2_TAG` (当前 `edk2-stable202408`) 严格绑定; 升级任一组件必须同步改 tag + 重跑 build + 重 commit. **EDK2 用 stable202408 不是 202508**: 上游 202508 改了 `OvmfPkg/Library/PlatformBootManagerLibLight` 行为 (无 NV BootOrder 时落 EFI Shell, 不再自动 boot first device), 切到 202508 必须额外 patch 改用 PlatformBootManagerLib full 才能装机.
- **构建参数固定**: QEMU `--target-list=aarch64-softmmu --enable-cocoa --enable-hvf --enable-iosurface`; EDK2 `-p ArmVirtPkg/ArmVirtQemu.dsc -a AARCH64 -t GCC5 -b RELEASE` (cross compile via brew aarch64-elf-gcc), 控体积与签名面. `--enable-iosurface` 是 HVM patch 0002 引入的 macOS-only display backend (`-display iosurface,socket=...`, AF_UNIX + POSIX shm + SCM_RIGHTS), 协议规范见 `docs/QEMU_DISPLAY_PROTOCOL.md` v1.0.0; configure 识别该选项依赖 patch 0002 内同时 patch 了 `scripts/meson-buildoptions.sh` (该 .sh 是从 `meson_options.txt` 由 `meson-buildoptions.py` 派生的中间文件, 不打进 patch 则 configure 报 unknown option 必须改用 `-D` 直传 — 所以新加任何自家 feature option 时必须同步打 .sh). cocoa 保留作 fallback/调试, 生产路径由 HVM 主进程 argv 选 `iosurface`
- **补丁串行管理**: 所有 QEMU 上游补丁放 `patches/qemu/*.patch` 顺序由 `patches/qemu/series` 决定; 所有 EDK2 上游补丁放 `patches/edk2/*.patch` 顺序由 `patches/edk2/series` 决定; 任一 patch apply 失败立即中断; **禁止 fork 上游仓库**以避免 rebase 黑盒
- **patches/qemu/0001-hvm-win11-lowram.patch** + **patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch** 配对启用 Win11 ARM64 装机: QEMU 加 opt-in `-machine virt,hvm-win11-lowram=on` 在 0x10000000 挂 16MB RAM 孔, EDK2 ArmVirtPkg 按 PcdSystemMemoryBase 选主 RAM + 把额外 /memory 节点注册成 SYSTEM_MEMORY/MMU. 两者必须同时打 (单打 QEMU 那个 stock EDK2 看到额外 /memory 节点会 ASSERT 挂死).
- **patches/qemu/0003-hw-display-hvm-gpu-ramfb-pci.patch**: 新 PCI 设备 `hvm-gpu-ramfb-pci` (套版 hw/display/virtio-vga.c, 把 VGA 路径换成 ramfb), 单设备同时挂 ramfb (UEFI/bootmgfw GOP 兼容) + virtio-gpu-pci (OS 期 viogpudo.sys / 内核 virtio-gpu driver 接管做 dynamic resize). vendor/device id 复用 0x1AF4/0x1050 让 viogpudo.inf 自动 match. Windows guest argv 走 `-device hvm-gpu-ramfb-pci` 替代单挂 ramfb. 内部 dispatcher 按 `g->parent_obj.enable` 切: 0 走 ramfb_display_update, 1 走 virtio-gpu cmd handler 自己的 dpy_gfx_update. ui_info 始终转给 virtio-gpu 让 vdagent / EDID 通路在 OS 期立刻拿到 host 端尺寸 hint.
- **产物路径**: 都在仓库 ignore:
  - `third_party/qemu-src/`: 上游 v10.2.0 git clone 源码 (~900M)
  - `third_party/qemu-stage/`: 编译 + 裁剪 + 嵌 swtpm + 清 xattr + LICENSE/MANIFEST 后的最终成品 (~180M, 不含 socket_vmnet)
  - `third_party/edk2-src/`: 上游 edk2-stable202408 git clone 源码 (含 submodules, ~700M)
  - `third_party/edk2-stage/`: EDK2 编译 + padding 到 64MB 的 `edk2-aarch64-code.fd` (Win11 patched)
  - `scripts/qemu-build.sh` 把 `third_party/edk2-stage/edk2-aarch64-code.fd` 拷进 qemu-stage 的 `share/qemu/edk2-aarch64-code-win11.fd` (Windows guest 专用); Linux guest 用 QEMU 自带 kraxel firmware (`edk2-aarch64-code.fd`)
  - `scripts/bundle.sh` 直接从 `third_party/qemu-stage` 拷至 `HVM.app/Contents/Resources/QEMU/`, **不再有中间 `third_party/qemu/` vendor 层**(已废弃)
- **依赖配套**:
  - EDK2 aarch64 firmware: 双 firmware 策略 — Linux 用 QEMU 自带 kraxel firmware (`edk2-aarch64-code.fd`, 跟 brew QEMU 同源); Windows 用 `scripts/edk2-build.sh` 自家 build (clone edk2-stable202408 + apply patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch + cross compile RELEASE_GCC AARCH64 via brew aarch64-elf-gcc), 落 `share/qemu/edk2-aarch64-code-win11.fd`; vars 模板用 QEMU 自带 `edk2-arm-vars.fd` (空 vars 通用)
  - `swtpm` + `libtpms` 由 brew 锁版本 (Win11 TPM 2.0 必需), 由 `qemu-build.sh` 打包入 `Resources/QEMU/bin/swtpm` + dylib 重定向
  - **主 qemu 二进制依赖 dylib 必须 bundle (零依赖硬约束)**: `qemu-system-aarch64` / `qemu-img` / `qemu-storage-daemon` / `qemu-nbd` / `qemu-io` / `qemu-edid` 都链 brew 的 `libcapstone` / `libgnutls` / `libpixman` / `libglib` / `libslirp` / `libzstd` 等. `qemu-build.sh` 的 `bundle_qemu_dylibs()` (复用 `bundle_dylib_deps`, 跟 swtpm 同款) 把这些全拷进 `Resources/QEMU/lib/` + `install_name_tool` 重定向到 `@executable_path/../lib/`. **不这么做的后果**: qemu 偷偷依赖 host homebrew (违反零依赖), 且加固运行时 (`flags=runtime`) 库校验拒绝加载非同 team 的 adhoc dylib — homebrew 升级重签 dylib 后 QEMU 一起来就 `signal 9` 崩. 历史教训 2026-05-30: brew 升级 capstone 后整个 VM 启动链断. 改 brew 依赖版本 / 新增 qemu link 库后必须重跑打包让新 dylib 入 lib/
  - **`make qemu-build.sh --relocate-dylibs`**: 只对现有 `third_party/qemu-stage` 重做 dylib 嵌入 (不全量重编 qemu), 给"homebrew 升级后 dylib 失效"快速修复; 之后 `make build` 重签. Makefile `BUNDLE_STAMP` 依赖 `$(QEMU_BIN)`, re-stage 后 `make build` 自动重 bundle
  - `socket_vmnet` **不入包**: 用户机器自行 `brew install socket_vmnet`, `scripts/install-vmnet-daemons.sh` 从 brew 路径拉 binary 写 launchd plist. 见下条网络约束
  - **virtio-win 驱动 ISO 不入包** (体积约 700MB), 首次创建 Win VM 时按需下载到 `~/Library/Application Support/HVM/cache/virtio-win/`
- **签名闭环**: `Resources/QEMU/bin/*` 与 `Resources/QEMU/lib/*.dylib` 必须逐文件 codesign; QEMU 二进制使用单独的 `app/Resources/QEMU.entitlements` (含 `com.apple.security.hypervisor`, HVF 必需), **不**与 HVM 主进程共用 entitlement; 整包再 `codesign --deep` 包裹
- **GPL 合规**: QEMU 上游 commit SHA + tag + license 全文写入 `Resources/QEMU/MANIFEST.json` 与 `Resources/QEMU/LICENSE`; HVM 自身仓库 GitHub 公开即满足"对应版本源码可获取"要求
- **进程模型**: HVM 主进程通过 `Process` 启动包内 `qemu-system-aarch64`, **不**链接 `libqemu`; QMP 控制 socket 仅监听 unix domain socket (`run/<vm-id>.qmp`), **严禁 TCP 监听**
- **Bundle 互斥**: QEMU 后端 VM 与 VZ 后端 VM 同样遵守"单 `.hvmz` 单进程"原则, 复用现有 fcntl flock
- **首版优先级**: Linux arm64 跑通通路后再做 Windows arm64; Linux QEMU 通路是 Windows 集成的前置验证
- **socket_vmnet 网络约束** (hell-vm 同款 osascript admin Touch ID 方案, 详见 `docs/NETWORK.md`):
  - macOS `vmnet` 必须 root, 用 `socket_vmnet` 系统级 launchd daemon 把权限闭环
  - **socket_vmnet 二进制不打包入 .app**: 用户机器自己 `brew install socket_vmnet`. `scripts/install-vmnet-daemons.sh` 从 brew 路径 (`/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet`) 拉 binary 写 launchd plist
  - **提权方式**: GUI `编辑配置 → 网络 → 安装 daemon` 按钮通过 `VMnetSupervisor.installAllDaemons` 走 `osascript "do shell script ... with administrator privileges"` 弹原生 Touch ID / 密码框, 一次到位装 shared + host + N 个 bridged.<iface>. **不**写 `/etc/sudoers.d/*`, **不**拉 Terminal sudo bash, **不**做自动 kickstart 防 stale (daemon 由 launchd KeepAlive 管)
  - **plist label namespace**: `com.hellmessage.hvm.vmnet.*` (与 lima / hell-vm / colima 区分, 互不干扰)
  - daemon 监听**固定路径** unix socket (跟 socket_vmnet 上游 / lima / hell-vm 一致):
    - `/var/run/socket_vmnet` (shared)
    - `/var/run/socket_vmnet.host` (host)
    - `/var/run/socket_vmnet.bridged.<iface>` (bridged)
  - **QEMU 接 socket_vmnet 协议**: socket_vmnet daemon 用 4-byte length-prefix framing, 跟 QEMU `-netdev stream` 协议**兼容** (lima / hell-vm 同款). QEMU argv 直写 `-netdev stream,id=netN,addr.type=unix,addr.path=<sock>,reconnect-ms=2000` 直连 daemon, **不需要** `socket_vmnet_client` wrapper, **不需要**父进程 `socket()/connect()` 把 fd 透传给子进程 (socket_vmnet 集成中老的 sidecar fd-passing 路径已下线; HDP 协议内 IOSurface fd 仍走 SCM_RIGHTS, 由 `HVMScmRecv` 提供 C 胶水层 — 这是不同通路, 与 socket_vmnet 无关)
  - **reconnect-ms=2000 必须保留** (QEMU 7.2+ 选项, 我们 10.2.0 自带): daemon `--restart` / bootout-bootstrap 重起时 socket 短暂断开, QEMU 每 2s 自动重连. 实测 28/30 ping 透传, daemon 重起 12s 期间 0 丢包 — 让 [重启 daemon] 按钮对已连 VM 几乎透明. 去掉这个选项 = 任何 daemon flip 都让 running VM 永久掉网, 用户必须手动停 + 启 VM
  - **bridged 接口名只允许 `[a-zA-Z0-9]+`** (防 shell 注入, install-vmnet-daemons.sh 内部做白名单校验)
  - **共存检测**: 跟 hell-vm 同款**不**做共存检测 — 用户若已装 lima/colima 的 socket_vmnet daemon, install-vmnet-daemons.sh 会 unlink 别家 socket 重建. 用户需先卸别家
  - VZ 后端 `vmnetBridged` 走 Apple `VZBridgedNetworkDeviceAttachment` (依赖 `com.apple.vm.networking` entitlement, 申请中); `vmnetShared / vmnetHost` 在 VZ 上退化到 NAT
  - 卸载所有 HVM 装的 daemon: `sudo scripts/install-vmnet-daemons.sh --uninstall` (或 GUI 网络面板 "卸载全部" 按钮)
  - **daemon 在 ≠ bridge 在** (重要陷阱, 2026-05-23 实测撞过): vmnet.framework 内核侧 bridge attach 可能进入"半死"状态 — daemon 进程在跑, socket 文件在, launchctl 视图正常, QEMU 能连上 socket, 但帧根本不打到物理 iface (tcpdump 0 帧 from guest MAC). 多次 bootout/bootstrap 残留是已知触发. **idempotent install 跳过修不了**这条 (它的幂等检查正好绕开破坏性重启). **唯一可靠的修复**: bootout + bootstrap 强制重起 daemon (会断已连 VM 的网络, 不可避免). 入口:
    - GUI: 状态栏 vmnet popup / VM 设置网络面板的 **[重启 daemon]** 按钮 (走 osascript admin)
    - CLI: `sudo scripts/install-vmnet-daemons.sh --restart` (跟 `--uninstall` 区别: plist 保留, 仅重起内核态)
    - 启 VM 前 `HVMQemu/VMnetBridgeProbe` 做 ~200ms 响应性轻探, 抓 socket 孤儿 / 协议错配 / daemon 拒服务; **不抓** silent-bridge-死 (实测 user-space 无法可靠区分, 见 `docs/v3/VMNET_DAEMON_HEALTH.md` R5)

## 第三方二进制 / Helper 脚本约束 **必须遵守**

防止本机 brew 版本 / dev 期临时位置 与打包版本不一致引入诡异 bug.

- **运行时第三方二进制 / 资源严格只走 .app 包内**:
  - HVM 进程内 (qemu-system-aarch64 / swtpm / EDK2 firmware): 走 `Bundle.main/Resources/QEMU/...`
    - dev: open build/HVM.app → Bundle.main = build/HVM.app
    - prod: open /Applications/HVM.app → Bundle.main = /Applications/HVM.app
  - 外部脚本 (`scripts/install-vmnet-daemons.sh` 写 launchd plist): GUI VMnetSupervisor 严格只查 `Bundle.main/Resources/scripts/install-vmnet-daemons.sh`. dev 期 Bundle.main = `build/HVM.app`, prod 期 = `/Applications/HVM.app`. plist 内 `ProgramArguments[0]` 是 `socket_vmnet` 的 brew 绝对路径, 与 .app 位置无关
  - `HostLauncher.locateHVMBinary` (hvm-cli + GUI store 共用, 在 `HVMControl` target): 探测顺序 (1) `HVM_APP_PATH` env → (2) **跟随调用方自身位置** (`Bundle.main.executableURL` 的兄弟 `HVM` 或兄弟 `HVM.app/Contents/MacOS/HVM`) → (3) `/Applications/HVM.app` / `~/Applications/HVM.app` 兜底. 跟随自身位置 = "我从哪个 build 出来就用哪个 build 的 HVM + 包内 QEMU": 装进 .app 时 hvm-cli 兄弟即 `Contents/MacOS/HVM`; dev 期 `build/hvm-cli` 兄弟即 `build/HVM.app` (**dev 不必先 `make install`**, 也不会误用 `/Applications` 旧版). GUI (build/HVM.app 自身) 启 host 子进程时 `Bundle.main` 即自己, 同样自洽
  - **严禁 fallback** 到 `/opt/homebrew/*` / `/usr/local/*` / 仓库 `third_party/qemu-stage/*` (`socket_vmnet` 例外, 它本来就由 brew 提供, 不在 .app 内)
  - 仅允许 env override: `HVM_QEMU_ROOT` / `HVM_SWTPM_PATH` / `HVM_APP_PATH` 显式覆盖, 给 CI 与调试用 (老的 `HVM_SOCKET_VMNET_PATH` 已废弃, 走 brew)
- **packager 工具例外**: `scripts/qemu-build.sh` 是源 → 包内分发桥梁, 它从 brew 复制 swtpm 进 `third_party/qemu-stage/`, 不属于"运行时引用". socket_vmnet 不再走打包 (brew 直接装)
- **app 包内第三方二进制 / sh 脚本变更必须 `make install`**:
  - 改完 `third_party/qemu-stage/*`、`scripts/install-vmnet-daemons.sh`、或任何被 `bundle.sh` 拷入 .app 的内容后, `make build` 只更新 `build/HVM.app`, 用户实际运行的 `/Applications/HVM.app` 仍是旧版
  - 必须 `make install` 把 `build/HVM.app` 同步到 `/Applications/HVM.app`, 否则:
    - GUI 启动 VM 用的是旧 QEMU/swtpm
    - GUI VMnetSupervisor 拉的是旧版 install-vmnet-daemons.sh (脚本内逻辑可能与新二进制不兼容)
  - 提交 commit 之前若改动涉及上述项, **必须显式跑 `make install`** 确认线上 .app 同步

## 共享目录约束 **必须遵守**

详见 [docs/v1/SHARING.md](docs/v1/SHARING.md) + 设计稿 [docs/v3/SHARED_FOLDER.md](docs/v3/SHARED_FOLDER.md).

- **协议固定**: SPICE WebDAV over virtio-serial `org.spice-space.webdav.0` mux 协议. **不**新走 9p / virtiofs / SMB / 其他通路 (一致性 + 共用 UTM Guest Tools 链路)
- **后端限定**: 仅 QEMU 后端 + Linux / Windows guest. VZ 后端 / macOS guest 启动期 warn + 忽略 sharedFolders (推后 VZ_SHARED_DIRECTORY.md 单独提案)
- **WebDAV server 在 Swift 主进程内自实现**, **不**链 libspice-server / libphodav, **不**给 QEMU 加 `--enable-spice`. 跟 vdagent / qga 同款 single-client 模式 (HVM 主进程作 client 连 QEMU chardev server=on socket); QEMU 不打 spice patch
- **socket 路径**: `HVMPaths.webdavSocketPath(for: vmId)` = `~/Library/Application Support/HVM/run/<uuid>.webdav.sock`. 禁止业务侧自己拼路径
- **路径安全 (硬约束)**: `WebDavHandler.toHostURL` / `composeDest` 必须 (a) 拒 `..` / `.` / 空段; (b) `resolvingSymlinksInPath` 后比 `standardizedFileURL.path` 仍在 root 子树. 改这两函数必加 fuzz 测试覆盖 escape 场景
- **空 sharedFolders 不起 server**: `config.sharedFolders.isEmpty` → 不注入 chardev argv + 不起 SpiceWebdavServer, 不占 socket 路径
- **改 sharedFolders 必走加密分流**: 走 `EncryptedConfigEditor.save` / `AppModel.saveConfig` (内部分流 BundleIO.save / EncryptedConfigIO.save), 禁止直接 BundleIO.save (加密 VM 历史教训, grep BundleIO.save 全树确认)
- **VM running 改 sharedFolders 拒**: chardev 不支持热挂, 落 `bundle.busy` 让用户先停 VM. GUI / CLI 都遵守
- **name 字符集硬限**: `SharedFolderSpec.sanitizeName` + CLI 校验仅允许 `[a-zA-Z0-9_-]{1,32}`. 防 WebDAV URL 注入 / shell metachar
- **hostPath 必须绝对路径 + 真实存在**: CLI / GUI 入口校验. 防相对路径歧义
- **server 启失败 fail-soft**: server 起不来只 log warn, **不**阻塞 VM 启动 (共享目录非 VM 必需)
- **guest 端依赖外置, 不自家 build**: Win 走 UTM Guest Tools 自带 `spice-webdavd-arm64-latest.msi`; Linux 让用户 `sudo apt install spice-webdavd`. **不**自家 build phodav 替代上游

## 调试/诊断工作方式约束 **必须遵守**

- **禁止使用 osascript / AppleScript UI scripting 模拟 GUI 点击**(脆弱、依赖屏幕坐标和辅助功能权限, 不可复现)
- 需要启动/停止 VM 走 `hvm-cli` 或 `hvm-dbg`, 不靠 HVM GUI
- 需要在 guest 内做操作(看桌面、点按钮、键入命令)走 `hvm-dbg` 子命令
- 需要 host ↔ guest 复制文件走 `hvm-dbg file push/pull`(QEMU 后端, qemu-guest-agent `guest-file-*` API; 1-10 MB/s; 软警告 100 MiB / 硬上限 4 GiB; 设计稿 `docs/v3/FILE_COPY.md`)
- 想测 host → guest 文件粘贴 (Cmd+V 通路) 走 `hvm-dbg paste-files <vm> --file ...`(走 SPICE vdagent file_xfer, 落 guest `~/Downloads`; 模拟 GUI Cmd+V 但绕过 NSPasteboard 拦截; 设计稿 `docs/v3/HOST_FILE_PASTE.md`)
- 需要长期 host ↔ guest 共享 host 目录走"共享目录" (SPICE WebDAV; `hvm-cli shared-folder add` / GUI 详情页 Sharing 区; 详见 `docs/v1/SHARING.md`)
- 调试 WebDAV 协议层走 `hvm-dbg webdav-test` (44 case 离线单测) + `hvm-dbg webdav-serve --listen` (起 server 监听本地 socket 给 curl / Python client 测)
- `hvm-dbg` 扩展原则: 零新协议实现, 只复用已暴露的公开 VZ API 封装
- 遇到能力缺失**立即扩展 `hvm-dbg`**, 不要退回用 osascript

### HVM GUI 自动化测试 (HDP-GUI 协议, PR-G 落地后强制)

测试 HVM 主进程 GUI 自身行为 (创建向导 / 加密 dialog / 详情页等) 走 **HDP-GUI 协议**. 设计稿 [docs/v3/HVM_DBG_GUI_PROTOCOL.md](docs/v3/HVM_DBG_GUI_PROTOCOL.md).

- **启用 server**: `HVM_GUI_PROBE=1 open /Applications/HVM.app` — release 默认不启 (体积 +几十 KB, 不暴露 socket)
- **socket**: `~/Library/Application Support/HVM/run/hvm-dbg-gui.sock` (0600, 同用户)
- **hvm-dbg gui 子命令**:
  - `hvm-dbg gui ping` — 验 server 启动
  - `hvm-dbg gui list [--prefix X]` — 列 ProbeRegistry 已注册控件
  - `hvm-dbg gui click --identifier X` — 触发 button.action / 切 toggle
  - `hvm-dbg gui type --identifier X --text "..."` — 给 textField 输文字
  - `hvm-dbg gui read --identifier X` — 读 textField/toggle 当前值
  - `hvm-dbg gui screenshot --output X.png` — 截主窗口 + dialog → PNG
- **业务侧接入**: SwiftUI 控件加 `.hvmProbe(id: "<scene>.<role>.<name>", label: "...", action: .button { ... })`
  - 命名规范: `<scene>.<role>.<name>`. 例 `dialog.encryptVM.button.encrypt` / `toolbar.button.newVM` / `dialog.encryptionPassword.input.password`
  - **不**走 SwiftUI `.accessibilityIdentifier(_:)` — 实测 macOS 14+ 不暴露给程序内 a11y 查询 (要 VoiceOver 激活), 走自家 ProbeRegistry 直接 closure 注册更稳
- **GUI 测试优先级**: 任何 GUI 改动 (新 dialog / 新按钮) **优先**用 hvm-dbg gui 自动化测, 不让用户手动点

## 日志路径约束 **必须遵守**

落盘日志严格分两类:

- **HVM 软件本身的 host 侧 .log** → 全部落 `~/Library/Application Support/HVM/logs/`
  - 顶层 `<yyyy-MM-dd>.log`: `LogSink` mirror `os.Logger` 的输出(跨 VM 共享)
  - 子目录 `<displayName>-<uuid8>/`: 该 VM 的 host 侧 .log
    - `host-<date>.log` — VMHost 进程 stdout/stderr (HVM `--host-mode-bundle`)
    - `qemu-stderr.log` — QEMU host 进程 stderr
    - `swtpm.log` / `swtpm-stderr.log` — swtpm 自身 / 进程 stderr
  - 路径必须走 `HVMPaths.vmLogsDir(displayName:id:)`,**禁止**业务侧自己拼 `bundle.appendingPathComponent("logs/...")`

- **虚拟机自己的 .log (guest 内部产生的)** → 留在 `<bundle>.hvmz/logs/`
  - `console-<date>.log` — guest serial 输出 (内核启动 / systemd / dmesg)
  - 由 `ConsoleBridge` (VZ) / `QemuConsoleBridge` (QEMU) 写,**这是唯一允许写 bundle/logs/ 的来源**

- **dev 期 / debug 期的所有 .log 同样适用上述规则**: 临时 / 排查 / 试验性日志一律走全局 `HVMPaths.logsDir`,严禁散落到 `/tmp` / 仓库根 / 终端 redirect 到任意路径。Tests 临时文件除外 (落 `NSTemporaryDirectory()` 即可)。

- VM 删除时**不**自动清理 `<displayName>-<uuid8>/` 子目录,留作排查老问题; orphan 子目录由用户手动清。

- **全局日志开关 (`LoggingPreferences`)**: 状态栏 toggle / UserDefaults key `com.hellmessage.vm.logging.enabled`, 跨进程 (GUI / hvm-cli / `--host-mode-bundle` 子进程) 共享 `com.hellmessage.vm` UserDefaults suite。**关闭时**:
  - LogSink 不再写顶层 `<yyyy-MM-dd>.log`
  - GUI / hvm-cli 派生 VMHost 子进程不再创建 `host-<date>.log` (Process stdout/stderr → `/dev/null`, vmLogsDir 子目录也不创建)
  - VMHost 子进程 (QemuHostEntry / hvm-dbg qemu-launch) 不再创建 `qemu-stderr.log` / `swtpm.log` / `swtpm-stderr.log`
  - guest serial `console-*.log` 不受影响 (那是 guest 自己的输出, 留在 `<bundle>/logs/`)
  - 切换时机: LogSink 即时生效; 子进程 host log / qemu / swtpm 在 VM 启动时拍板, 运行中切换不影响已开 fd, 下次启 VM 才生效

## 磁盘与存储约束

- 磁盘格式按 **engine 分流**, 持久化到 `DiskSpec.format` 字段 (config.yaml):
  - **VZ 后端**: `raw sparse file` (`.img`) — VZDiskImageStorageDeviceAttachment 只接受 raw, 强约束
  - **QEMU 后端**: `qcow2` (`.qcow2`) — qemu-img create / resize
- 创建时主盘文件名 (BundleLayout.mainDiskFileName(for:)):
  - VZ:   `<bundle>/disks/os.img`,    DiskSpec.format = .raw
  - QEMU: `<bundle>/disks/os.qcow2`,  DiskSpec.format = .qcow2
- 创建时数据盘 (BundleLayout.dataDiskFileName(uuid8:engine:)): 同上规则, format 跟随 engine
- 运行时**严格走 config.yaml 的 DiskSpec**:
  - 路径走 `DiskSpec.path` (运行时 helper: `VMConfig.mainDiskURL(in:)`), **禁止**用任何 BundleLayout 常量推断主盘路径
  - 格式走 `DiskSpec.format`, **禁止**靠文件扩展名推断
- DiskFactory.create / grow 入口要求显式传 `format: DiskFormat` 参数:
  - .raw → ftruncate
  - .qcow2 → 调 qemu-img (要求传 `qemuImg: URL` 参数, 走 `QemuPaths.qemuImgBinary()`)
- 老 QEMU VM 已是 raw `.img` (用户从老版本带过来的) 仍可继续运行: DiskSpec.format 字段缺失时按 path 扩展名兜底推断, 不强制迁移
- ISO 路径**不复制进 bundle**, 只存绝对路径
- 磁盘扩容: VZ raw 走 ftruncate, QEMU qcow2 走 qemu-img resize, guest 内仍需 `resize2fs` / 分区工具

## 克隆约束 **必须遵守**

整 VM 克隆走 `HVMStorage/CloneManager`. 设计稿 `docs/v3/CLONE.md`, 现状 `docs/v1/STORAGE.md "Clone"` 节. 关键边界:

- **必须 stopped**: CloneManager 内部抢源 `.edit` lock; 已被 `.runtime` 持有 → `.bundle(.busy)`. **GUI 不自动 stop 源 VM** (用户掌控)
- **必须同 APFS 卷**: clonefile(2) 跨卷 `EXDEV`. 提前 `stat.st_dev` 探测, 跨卷抛 `.storage(.crossVolumeNotAllowed)`. 复制到外接 NVMe 等场景需用户手动 `cp -R` 或先在同卷克隆再移动
- **目标不能预存在**: 抛 `.bundle(.alreadyExists)`. GUI 自动追加 ` 副本 N` 后缀; CLI 用户自己改名
- **失败一律清目标**: 任意一步抛错 → `removeItem(targetBundle)`. CloneManager **绝不留 partial bundle**
- **重生字段** (撞车风险, 必须重生): `config.id` (UUID) / `config.displayName` / `config.createdAt` / `auxiliary/machine-identifier` (macOS guest, `VZMacMachineIdentifier()`) / `disks/data-<uuid8>.*` 文件名 + `DiskSpec.path` 同步 / `networks[].macAddress` (默认; `--keep-mac` 可保留)
- **保留字段** (重生必坏): `auxiliary/hardware-model` (与 IPSW 装机绑定, 重生 = macOS guest 拒启) / `auxiliary/aux-storage` (装机后 NVRAM-equivalent) / `nvram/efi-vars.fd` (EFI BootOrder; 重置 = guest 进 EFI Shell) / `tpm/*` (Win11 swtpm; 重置 = BitLocker 永久失效)
- **不带文件**: `.lock` (目标首次启动自然创建) / `logs/console-*.log` / `.unattend-stage` + `unattend.iso` (Win 装机产物按需重生) / **`snapshots/` (永不带, 加密 / 明文 / VZ / QEMU 一律. 没有 `--include-snapshots` 选项, D15 用户决策 2026-05-04)**
- **不做的**: linked clone (VZ raw 不支持 backing) / cross-engine 克隆 / cross-host 克隆 / 在线克隆 / schema 升级 / 删源
- **macOS guest 双开警告**: 同一 hardware-model + 重生 machine-identifier 理论可同时跑两台, 但 Apple 服务行为未充分验证 (docs/v3/CLONE.md C2 待真机). 用户需理解 iCloud / 序列号风险
- **Windows guest 克隆**: tpm 状态保留 → 装机后激活通常仍生效, 但部分场景需重新激活. GUI 弹窗 done 态显式提示
- **加密 VM 克隆 (D9 = 等价复制 + 同密码)**: CLI 路径已支持 (`hvm-cli clone <enc-vm>` 走 prompt 密码 + APFS clonefile 字节级 COW + 用源 sub.config 重新加密 config.yaml.enc). **新 VM 跟源同密码** — 想换密码用户自跑 `hvm-cli rekey`. master KEK / sub keys 全程不变 → LUKS keyslot 同步可解 / swtpm tpm/permall 同步可开. routing JSON 仅改 vmId + displayName, salt/iter 保留. **GUI 暂不接** (PR-11 GUI 加密范围). VZ-sparsebundle 加密 clone 推后 (跟 VZ 加密接入一致). 设计稿 `docs/v3/CLONE_SNAPSHOT_ENCRYPTED.md`

## VM 配置 (config.yaml) 约束 **必须遵守**

- **格式**: YAML 1.1 (Yams 解析). 文件名 `<bundle>/config.yaml`, 不再用 `.json`
- **唯一来源**: 所有 per-VM 的"配置项"必须落到 `<bundle>/config.yaml` 持久化 (磁盘文件名 / 格式 / 大小 / 网卡 / engine 等). **禁止**业务代码在运行时从 `BundleLayout` 等"全局常量"推断 per-VM 路径或格式 — 这种位置一律改为读 `VMConfig` 字段
- `BundleLayout` 仅允许保留**与 VM 无关的** layout 常量 (`disksDirName` / `lockFileName` / `nvramFileName` 等结构性命名), 以及**仅创建时调用一次**的"默认文件名生成器" (`mainDiskFileName(for:)` / `dataDiskFileName(uuid8:engine:)`); **禁止**保留 per-VM 的"运行时入口"常量 (例如已删的 `mainDiskName` / `mainDiskURL(_ bundle)` 老 API)
- **schema 版本**: `VMConfig.currentSchemaVersion` 当前 = 3 (v3 引入加密 routing 字段 + sparsebundle / qemuPerfile 双 scheme); 升级走 `ConfigMigrator` 链式 hook (yaml 数据流), 老 schema 必须能升到当前
- **断兼容**: schema v1 (.json) 已断兼容. `BundleIO.load` 检测到 `config.json` 但无 `config.yaml` 时直接报错 "请重新创建 VM 或手动迁移". v2 (.yaml, 早期无加密) 仍可读, 走 ConfigMigrator 升 v3
- **Codable 字段缺省兜底**: 新加非可选字段时, 必须在 `init(from:)` 提供合理默认 (按 path 扩展名推 / 历史缺省值), 防止老 yaml 解码失败
- **保密**: config.yaml 内不得写入任何密钥 / token / 证书私钥; ISO/IPSW 路径只是绝对路径不算敏感

## 开发流程约束 **必须遵守**

任何**新功能 / 重大修改 / 架构决策**, 都必须**先落地设计稿, 再开始编码**. 这条优先级高于"快速试错": 写代码前先把范围 / 选型 / 边界 / PR 拆解写在文档里, 用户敲定后再动手, 避免"做完才发现方案不对"返工.

- **设计稿位置**: `docs/v3/<TOPIC>.md` (v2 → v3 能力归档, 单提案单文档, 状态机: `设计稿` → `评审中` → `实现中` → `代码已合入`); 索引登 `docs/v3/README.md`. **新 GUI 重构主线**走独立目录 `docs/v4/<TOPIC>.md` + 索引 `docs/v4/README.md` (NEW_GUI.md 及后续业务页子稿)
- **设计稿必须包含**:
  - **目标 + 范围** (做什么, 不做什么)
  - **选型对比** (至少 2 个备选 + tradeoff 表; 不能只列已选方案)
  - **实现要点 / 字段或接口设计** (类型签名 / 文件结构 / 关键算法)
  - **风险与待验证项** (P0 must-pass gate 单列)
  - **PR 拆解** (每 PR 时间盒 + 验收, 颗粒 ≤ 2 天)
  - **未决事项 (Decisions)** (D1 / D2 ... 表; 标注当前默认 + 决策时机)
- **评审通过再动代码**: 用户口头同意或文档敲定后再开第一个 PR. **禁止**先动代码再补文档
- **设计变更先回写设计稿**: 开发期发现方案不可行 / 需调整 → **先改 `docs/v3/<TOPIC>.md` 标"设计变更"**, 用户确认后再改代码. 反面: PR-1 落 sparsebundle 后才发现"VZ 用 sparsebundle / QEMU 用 per-file 混合"才是真正方案 — 这种返工应该在设计稿阶段拍板, 不进代码
- **实现合入后回写**:
  - 现状描述回写 `docs/v1/` 对应文档
  - 约束回写 `CLAUDE.md` 对应小节
  - 设计稿头部状态改 `代码已合入`, 留底不删 (决策溯源)
- **不在此约束范围**: bugfix / 文档错字 / 单纯重构 / 已有功能 < 50 行的小修小补 / 紧急修线上问题
- **判定参考**: 不确定要不要先写文档时, 默认"要写". 沉没成本 (写了文档发现不需要做) 永远小于"做错了重做"成本

例: [docs/v3/CLONE.md](docs/v3/CLONE.md) / [docs/v3/ENCRYPTION.md](docs/v3/ENCRYPTION.md) 都是先稿后码.

## 提交信息约束

- 格式: `type(scope): 中文描述 [English summary]`
- type 取值: `feat` / `fix` / `refactor` / `docs` / `chore` / `test`
- scope 取值: 模块名小写(`core` / `bundle` / `storage` / `backend` / `display` / `app` / `cli` / `probe` / `qemu`)
- 每次 commit 前必须 `make build` 通过

## Agent 协作约束 **必须遵守**

Agent (Claude Code 等) 跨 session / 跨电脑都要保留, 写入项目 CLAUDE.md 而非 ~/.claude/projects/.../memory/.

### 回复语言: 中文

跟用户的所有对话回复一律用中文 (代码 / 命令 / 文件名 / log 原文等技术 token 保留英文). 包括: 任务汇报 / 方案说明 / 进度更新 / 错误解释 / 提问澄清. 不切英文, 不混用. 代码内中文注释已是项目约定 (见 "代码约束").

### TODO 元数据回写合并到主 commit

`docs/TODO.md` 这类**跟 PR 强绑定**的进度元数据更新, 跟当前主功能 commit 合并, **不**单独切 commit. 同理: 设计稿状态头从"实现中" → "代码已合入" / `docs/v4/README.md` 索引行同步 / NEW_GUI.md 的"PR 拆解"已合标记等.

- 单独 commit TODO 改动只是 PR 的元数据回写, 没独立信息量, 让 git log 多 noise
- 合并后, 一条 PR 的代码 + 文档 + 进度回写在一个 commit 一目了然
- 操作: 主 commit 前一并 stage TODO.md / 设计稿状态 / 索引更新; commit type 用主功能的 (例 `feat(gui,docs)`)
- 已分两 commit 但都未 push 时安全修复: `git reset --soft HEAD~2` 把改动放回 staged 区, 重新合并 commit (不算 amend, 不破坏 working tree)
- 已 push 的不动 — Git Safety Protocol 优先

**例外**: TODO 改动跟当前主 PR 完全无关 (例如修补遗漏的旧 PR 进度) / 纯设计稿大改 (例如增补设计规范节, 体量大独立成段) 可单独 commit.

### 待开发项写入 docs/TODO.md, 不靠 session 记忆

任何"现在不做但后续要做"的项 (待办 / 已知 work-around / 用户反馈待复现 / 设计变更暂缓 / 未决项), 立即写入 `docs/TODO.md` 对应小节, **不**留在 session 上下文里 "等会再处理".

- session 上下文跨 conversation 会丢; TODO.md 跨 session 持久
- TODO.md 已划好分区: 主线 PR 进度 / 已知 work-around / 未决事项 / 业务页迁移 / 老 GUI 残余 / 用户反馈待复现 / 跨主题低优
- 新发现的待办: 立即 append 到对应分区, 用 `[ ]` 标未做
- 完成时 `[ ] → [x]` + 加 commit hash 引用 (跟主 commit 一起回写, 见上条约束)
- "下个 session 记得做 X" 这种话不允许出现 — 必须落 TODO.md

### commit 前先询问用户, 不自动 commit

改动落地 + verify 通过后, **不**自动 `git commit`. 报告 "改动 + verify 结果", 让用户决定是否 commit / 是否调整 commit message / 是否合并到上一个 commit (amend / squash).

- 用户可能想看完效果再 commit (例如 GUI 视觉验证需要真鼠标 hover 试)
- 用户可能想分批 / 一次性 commit 多个相关改动 (减少 git log 噪音)
- 用户可能想撤回某改动 (没 commit 比 reset 已 commit 容易)
- 自动 commit 让用户失去 staging 决策权, 反复出现 commit→reset→re-commit 浪费时间

操作:
- 改动 + verify (make build / screenshot / hvm-dbg gui 等) 后, 输出"改动汇总 + verify 结果", 询问 "要 commit 吗"
- 用户明确说 "commit" / "落进 commit" / "提交" 才执行 `git commit`
- 用户继续给新需求时, 沿用已 staged 改动累积, 等 batch 完成后再统一询问
- 已合 PR (用户已确认 commit 的) 后续 polish 不在此约束内, 但仍提示一下

**例外**: 用户明确说 "做完直接 commit" / "自动 commit 不用问" 时, 该 session 内可自动 commit. 默认仍需询问.

### 参考实现: UTM, 不再参考 hell-vm

凡是 "其他 QEMU app / SPICE / vdagent / Win driver 怎么做" 问题, **默认查 UTM 源码**.

- UTM 源码本地: `/Volumes/DEVELOP/Github/UTM/`, 主仓库 utmapp/UTM
- 关键路径:
  - `Configuration/UTMQemuConfiguration+Arguments.swift` — QEMU argv 构造
  - `Services/UTMSpiceIO.m` — SPICE client 接入
  - `Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift` — display + resize
  - `patches/qemu-*.patch` / `patches/spice-*.patch` — UTM 对上游 patch
- UTM Guest Tools (Windows guest 装包, `getutm.app/downloads/utm-guest-tools-latest.iso`)
  内含 ARM64 native vdagent.exe + utmapp 自家 viogpudo.sys (含 QXL escape SET_CUSTOM_DISPLAY).
  **不要**用 stock spice-guest-tools-latest.exe (只 x86, ARM Win 跑不通 dynamic resize)
- 若 web 调研声称 "UTM 也有 X 问题", **必须验证**当前 UTM master / 最近 release,
  不能仅凭老 issue 描述就下定论 (老 issue 描述的场景可能已修)

### 自主调试不让用户操作 GUI

调试 / 验证 / 测试 guest 内行为时**自己解决**, **不写**"请你 click X" / "请你跑 Y"
这种步骤推回给用户. 大量手动操作累积成本远高于让 agent 自动化.

- guest 内任何操作走 hvm-dbg 自动化 (key / mouse / screenshot / ocr / exec)
- VM 需要 restart → 自己 stop + start, 不让 user "请重启"
- 实在自动化卡死 (协议层不通) → 才告诉 user, 提供单一 minimal action + 解释 why

### hvm-dbg 缺功能时扩展, 不要绕路

凡是 "hvm-dbg 现有功能不能完成 X" 时, **新加子命令到 hvm-dbg**, 不绕路 (硬编码 unattend / 让用户 powershell / inline shell hack 都是 anti-pattern).

- 新建 `app/Sources/hvm-dbg/Commands/XxxCommand.swift` + 加到 `HvmDbg.swift` subcommands
- 配套 host 端 `IPCOp.dbgXxx` + `handleDbgXxx` handler (`QemuHostEntry.swift`)
- hvm-dbg 现有命令存在 bug → fix 现有命令, 不让用户绕开
- 加完命令立即用它跑测试, 验证通了才认为 fix 完成

### 端到端验证用 hvm-dbg, 不依赖 OCR 文本判断成败

OCR (Vision framework) 在 Win 控制台 / 中文 IME / 倾斜窗口 等场景误识率高
(如 `pnputil` → `prputil`, `/` → `I`, `BASICDISPLAY` → `BASICOTSPLAY`). 实际命令
跑了, OCR 看上去字符乱.

- 验证 cmd 是否成功执行 → 优先用 `hvm-dbg exec` (qemu-guest-agent 跑命令 + 拿 stdout)
- 验证 framebuffer / 显示状态 → 优先 `hvm-dbg screenshot --output X.png` 加 `Read X.png`
  自己肉眼看, 不依赖 ocr 文本

### Boot / 装机 timing 上限: 20 秒

VM 启动到 Setup / desktop 渲染**不会超过 20s** (用户 Apple Silicon Mac 实测上限).
任何状态卡同一帧超过 20s **默认判失败**, 不要"再等等看 wpe.wim 加载完". 触发条件:

- EDK2 BdsDxe boot 进度条画面显示同一帧超过 20s → bootmgfw / wpe.wim 加载已卡死
- bootmgfw "Press any key to boot from CD or DVD" 提示之后 20s 没切到 Setup → wpe.wim 加载失败
- Setup UI 渲染后任意 phase 同一帧超过 20s 没动 (除非显式点击触发 longwait, 例如 partition format)

这是诊断**最重要的判定线**: 不要 ScheduleWakeup 大于 30s 等待 boot 进度. 超时立刻
查 host log + qemu-stderr + console serial, 不要假设"再等等就行".
