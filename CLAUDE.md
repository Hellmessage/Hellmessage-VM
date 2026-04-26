# CLAUDE.md

本项目走 Apple Virtualization.framework 路线。

## 文档约束

- `CLAUDE.md` 只存放约束, 不放其他东西
- `README.md` 存放项目说明(开发完成后再写)
- `docs/` 下的设计文档是决策沉淀, 约束变更必须同步更新

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
- **版本锁定**: 包内 QEMU 与 `scripts/qemu-build.sh` 中的 `QEMU_TAG` (当前 `v10.2.0`), EDK2 与 `scripts/edk2-build.sh` 中的 `EDK2_TAG` (当前 `edk2-stable202508`) 严格绑定; 升级任一组件必须同步改 tag + 重跑 build + 重 commit
- **构建参数固定**: QEMU `--target-list=aarch64-softmmu --enable-cocoa --enable-hvf`; EDK2 `-p ArmVirtPkg/ArmVirtQemu.dsc -a AARCH64 -t GCC5 -b RELEASE` (cross compile via brew aarch64-elf-gcc), 控体积与签名面
- **补丁串行管理**: 所有 QEMU 上游补丁放 `patches/qemu/*.patch` 顺序由 `patches/qemu/series` 决定; 所有 EDK2 上游补丁放 `patches/edk2/*.patch` 顺序由 `patches/edk2/series` 决定; 任一 patch apply 失败立即中断; **禁止 fork 上游仓库**以避免 rebase 黑盒
- **patches/qemu/0001-hvm-win11-lowram.patch** + **patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch** 配对启用 Win11 ARM64 装机: QEMU 加 opt-in `-machine virt,hvm-win11-lowram=on` 在 0x10000000 挂 16MB RAM 孔, EDK2 ArmVirtPkg 按 PcdSystemMemoryBase 选主 RAM + 把额外 /memory 节点注册成 SYSTEM_MEMORY/MMU. 两者必须同时打 (单打 QEMU 那个 stock EDK2 看到额外 /memory 节点会 ASSERT 挂死).
- **产物路径**: 都在仓库 ignore:
  - `third_party/qemu-src/`: 上游 v10.2.0 git clone 源码 (~900M)
  - `third_party/qemu-stage/`: 编译 + 裁剪 + 嵌 swtpm/socket_vmnet + 清 xattr + LICENSE/MANIFEST 后的最终成品 (~180M)
  - `third_party/edk2-src/`: 上游 edk2-stable202508 git clone 源码 (含 submodules, ~700M)
  - `third_party/edk2-stage/`: EDK2 编译 + padding 到 64MB 的 `edk2-aarch64-code.fd` (Win11 patched)
  - `scripts/qemu-build.sh` 优先把 `third_party/edk2-stage/edk2-aarch64-code.fd` 拷进 qemu-stage 的 `share/qemu/`, 没有则降级用 QEMU 自带 firmware
  - `scripts/bundle.sh` 直接从 `third_party/qemu-stage` 拷至 `HVM.app/Contents/Resources/QEMU/`, **不再有中间 `third_party/qemu/` vendor 层**(已废弃)
- **依赖配套**:
  - EDK2 aarch64 firmware: `scripts/edk2-build.sh` 自己 build (clone edk2-stable202508 + apply patches/edk2/* + cross compile RELEASE_GCC AARCH64 via brew aarch64-elf-gcc), 产物给 Win11 ARM64 装机; 跑 `make qemu` 时若没 EDK2 stage 则降级用 QEMU 自带 kraxel firmware (Linux 够用, Win11 boot 会 stuck); vars 模板优先用 patched EDK2 build 出来的 `QEMU_VARS.fd`, 否则用 QEMU 自带 `edk2-arm-vars.fd` 兜底
  - `swtpm` + `libtpms` 由 brew 锁版本 (Win11 TPM 2.0 必需), 由 `qemu-build.sh` 打包入 `Resources/QEMU/bin/swtpm` + dylib 重定向
  - `socket_vmnet` 由 brew 锁版本 (QEMU 走 vmnet bridged/shared 网络的非 root 桥接), 同模式打包入包内
  - **virtio-win 驱动 ISO 不入包** (体积约 700MB), 首次创建 Win VM 时按需下载到 `~/Library/Application Support/HVM/cache/virtio-win/`
- **签名闭环**: `Resources/QEMU/bin/*` 与 `Resources/QEMU/lib/*.dylib` 必须逐文件 codesign; QEMU 二进制使用单独的 `app/Resources/QEMU.entitlements` (含 `com.apple.security.hypervisor`, HVF 必需), **不**与 HVM 主进程共用 entitlement; 整包再 `codesign --deep` 包裹
- **GPL 合规**: QEMU 上游 commit SHA + tag + license 全文写入 `Resources/QEMU/MANIFEST.json` 与 `Resources/QEMU/LICENSE`; HVM 自身仓库 GitHub 公开即满足"对应版本源码可获取"要求
- **进程模型**: HVM 主进程通过 `Process` 启动包内 `qemu-system-aarch64`, **不**链接 `libqemu`; QMP 控制 socket 仅监听 unix domain socket (`run/<vm-id>.qmp`), **严禁 TCP 监听**
- **Bundle 互斥**: QEMU 后端 VM 与 VZ 后端 VM 同样遵守"单 `.hvmz` 单进程"原则, 复用现有 fcntl flock
- **首版优先级**: Linux arm64 跑通通路后再做 Windows arm64; Linux QEMU 通路是 Windows 集成的前置验证
- **socket_vmnet 网络约束**: macOS `vmnet` 必须 root, QEMU 走 socket_vmnet 跨 vmnet 的方案要求一次性 sudoers NOPASSWD 配置:
  - 用户首次需要 bridged/shared 时跑一次 `sudo scripts/install-vmnet-helper.sh [iface...]` 写 `/Library/LaunchDaemons/com.hellmessage.hvm.vmnet.<mode>.plist` 并 `launchctl bootstrap` 入系统域, daemon 以 root 常驻
  - daemon 监听**固定路径** unix socket (与 lima / hell-vm 一致):
    - `/var/run/socket_vmnet` (shared)
    - `/var/run/socket_vmnet.host` (host)
    - `/var/run/socket_vmnet.bridged.<iface>` (bridged)
  - QEMU 启动时 `-netdev stream,addr.type=unix,addr.path=/var/run/socket_vmnet*` 直接连固定 socket, **不再 per-VM fork sidecar 也不再依赖 sudoers NOPASSWD**, 普通用户启动 / 关闭 VM 完全免密
  - **bridged 接口固定走 `vmnet-bridged`**(物理 LAN 桥接), 接口名加入 daemon plist 时只允许 `[a-zA-Z0-9]+`(防 shell 注入)
  - 走 socket_vmnet 后, `com.apple.vm.networking` Apple entitlement 仍可申请, 但**不再阻塞** QEMU 后端 bridged 网络落地
  - 卸载所有 daemon: `sudo scripts/install-vmnet-helper.sh --uninstall`

## 第三方二进制 / Helper 脚本约束 **必须遵守**

防止本机 brew 版本 / dev 期临时位置 与打包版本不一致引入诡异 bug.

- **运行时第三方二进制 / 资源严格只走 .app 包内**:
  - HVM 进程内 (qemu-system-aarch64 / swtpm / EDK2 firmware): 走 `Bundle.main/Resources/QEMU/...`
    - dev: open build/HVM.app → Bundle.main = build/HVM.app
    - prod: open /Applications/HVM.app → Bundle.main = /Applications/HVM.app
  - 外部脚本 (`scripts/install-vmnet-helper.sh` 写 launchd plist): 严格只查 `/Applications/HVM.app` 与 `~/Applications/HVM.app`, 不接受 build/ / third_party/ 等临时位置 (plist 路径写死, 必须长期有效)
  - hvm-cli (`HostLauncher.locateHVMBinary`): 只查 `/Applications/HVM.app` 与 `~/Applications/HVM.app`, 不再 fallback 到 build/HVM.app — dev 期 `hvm-cli start` 前需先 `make install`
  - **严禁 fallback** 到 `/opt/homebrew/*` / `/usr/local/*` / 仓库 `third_party/qemu-stage/*`
  - 仅允许 env override: `HVM_QEMU_ROOT` / `HVM_SWTPM_PATH` / `HVM_SOCKET_VMNET_PATH` / `HVM_APP_PATH` 显式覆盖, 给 CI 与调试用
- **packager 工具例外**: `scripts/qemu-build.sh` 是源 → 包内分发桥梁, 它从 brew 复制 swtpm/socket_vmnet 进 `third_party/qemu-stage/`, 不属于"运行时引用"
- **app 包内第三方二进制 / sh 脚本变更必须 `make install`**:
  - 改完 `third_party/qemu-stage/*`、`scripts/install-vmnet-helper.sh`、或任何被 `bundle.sh` 拷入 .app 的内容后, `make build` 只更新 `build/HVM.app`, 用户实际运行的 `/Applications/HVM.app` 仍是旧版
  - 必须 `make install` 把 `build/HVM.app` 同步到 `/Applications/HVM.app`, 否则:
    - launchd daemon plist 引用的 socket_vmnet 还是旧版本
    - GUI 启动 VM 用的是旧 QEMU/swtpm
    - 用户跑 `install-vmnet-helper.sh` 找不到新版二进制
  - 提交 commit 之前若改动涉及上述项, **必须显式跑 `make install`** 确认线上 .app 同步

## 调试/诊断工作方式约束 **必须遵守**

- **禁止使用 osascript / AppleScript UI scripting 模拟 GUI 点击**(脆弱、依赖屏幕坐标和辅助功能权限, 不可复现)
- 需要启动/停止 VM 走 `hvm-cli` 或 `hvm-dbg`, 不靠 HVM GUI
- 需要在 guest 内做操作(看桌面、点按钮、键入命令)走 `hvm-dbg` 子命令
- `hvm-dbg` 扩展原则: 零新协议实现, 只复用已暴露的公开 VZ API 封装
- 遇到能力缺失**立即扩展 `hvm-dbg`**, 不要退回用 osascript

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
- 老 QEMU VM 已是 raw `.img` (用户从老版本带过来的) 仍可继续运行: DiskSpec.format 字段在 schema v2 时按 path 扩展名兜底推断, 不强制迁移
- ISO 路径**不复制进 bundle**, 只存绝对路径
- 磁盘扩容: VZ raw 走 ftruncate, QEMU qcow2 走 qemu-img resize, guest 内仍需 `resize2fs` / 分区工具

## VM 配置 (config.yaml) 约束 **必须遵守**

- **格式**: YAML 1.1 (Yams 解析). 文件名 `<bundle>/config.yaml`, 不再用 `.json`
- **唯一来源**: 所有 per-VM 的"配置项"必须落到 `<bundle>/config.yaml` 持久化 (磁盘文件名 / 格式 / 大小 / 网卡 / engine 等). **禁止**业务代码在运行时从 `BundleLayout` 等"全局常量"推断 per-VM 路径或格式 — 这种位置一律改为读 `VMConfig` 字段
- `BundleLayout` 仅允许保留**与 VM 无关的** layout 常量 (`disksDirName` / `lockFileName` / `nvramFileName` 等结构性命名), 以及**仅创建时调用一次**的"默认文件名生成器" (`mainDiskFileName(for:)` / `dataDiskFileName(uuid8:engine:)`); **禁止**保留 per-VM 的"运行时入口"常量 (例如已删的 `mainDiskName` / `mainDiskURL(_ bundle)` 老 API)
- **schema 版本**: `VMConfig.currentSchemaVersion` 当前 = 2; 升级走 `ConfigMigrator` 链式 hook (yaml 数据流), 老 schema 必须能升到当前
- **断兼容**: schema v1 (.json) 已断兼容. `BundleIO.load` 检测到 `config.json` 但无 `config.yaml` 时直接报错 "请重新创建 VM 或手动迁移"
- **Codable 字段缺省兜底**: 新加非可选字段时, 必须在 `init(from:)` 提供合理默认 (按 path 扩展名推 / 历史缺省值), 防止老 yaml 解码失败
- **保密**: config.yaml 内不得写入任何密钥 / token / 证书私钥; ISO/IPSW 路径只是绝对路径不算敏感

## 提交信息约束

- 格式: `type(scope): 中文描述 [English summary]`
- type 取值: `feat` / `fix` / `refactor` / `docs` / `chore` / `test`
- scope 取值: 模块名小写(`core` / `bundle` / `storage` / `backend` / `display` / `app` / `cli` / `probe` / `qemu`)
- 每次 commit 前必须 `make build` 通过
