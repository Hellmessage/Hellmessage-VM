# HVM 架构总览

> 现状文档 (非设计提案). 描述当前代码实际形态: **QEMU 后端单一路线** (`qemu-system-aarch64`
> + HVF 加速 + HDP IOSurface 显示), guest 仅 **Linux arm64 + Windows arm64**. VZ
> (Apple Virtualization.framework) 后端 + macOS guest 已于 2026-05-30 整条移除.

## 一句话定位

HVM 是 Apple Silicon Mac 上的 QEMU 虚拟机管理器: 一个 SwiftPM 工程产出 **三个二进制**, 用包内
`qemu-system-aarch64` 跑 Linux / Windows arm64 guest, 主进程通过 HDP IOSurface 协议把 QEMU
画面零拷贝嵌进原生窗口. 全部逻辑走 Swift + Apple framework, 仅 QEMU/swtpm 第三方二进制随 `.app` 分发.

## 三个二进制 — 各管一摊

工程定义在 `app/Package.swift`, 三个 `.executable` product:

| 二进制 | target | 职责 |
| --- | --- | --- |
| `HVM` (→ `HVM.app`) | `HVM` | **双角色单 binary**: 默认启动是 GUI 主进程 (AppKit + SwiftUI); 带 `--host-mode-bundle <path>` argv 时变成 **VMHost 子进程** 接管单个 bundle 跑 QEMU |
| `hvm-cli` | `hvm-cli` | 用户 CLI: 创建 / 启停 / 删除 / 克隆 / 加密 / 磁盘 / 共享目录 / 快照 等命令式操作 |
| `hvm-dbg` | `hvm-dbg` | 调试/自动化探针: screenshot / key / mouse / ocr / exec / file push-pull / paste-files / webdav-test / `gui`(HDP-GUI 自动化) |

入口分派在 `app/Sources/HVM/main.swift`: argv `[1] == "--host-mode-bundle"` 走 VMHost
模式 (`HVMHostEntry.run`), 否则走 GUI (`NewGUIAppLauncher.run`). `hvm-cli` / `hvm-dbg`
各有独立 `@main` (`HvmCli.swift` / `HvmDbg.swift`, swift-argument-parser).

## Target 拓扑 (16 个)

依赖自底向上, 上层只能依赖下层. 三个可执行 target 在顶端聚合.

```
                 HVM (app)        hvm-cli        hvm-dbg
                  │  GUI+host       │ CLI           │ probe CLI
   ┌──────────────┼─────────────────┼───────────────┤
   │     HVMControl (cli+GUI 共用控制层)             │
   │      │                                          │
   │  HVMGuiProbe   HVMDisplayQemu ── HVMScmRecv(C)   │
   │      │              │                            │
   ├── HVMInstall    HVMQemu      HVMStorage  HVMEncryption
   │      │              │            │ │          │
   │      └────── HVMNet ┘            │ └──────────┤
   │                  │               │            │
   │              HVMBundle ──────────┘────────────┘
   │                  │
   │   HVMIPC      HVMUtils
   │      │           │
   └──────┴─── HVMCore ┘   (基础库, 无下游依赖)
```

各 target 职责一句话:

- **HVMCore** — 基础库, 无依赖. 错误模型 (`HVMError` / `ErrorCodes`)、日志 (`Logger` / `LogSink` / `LoggingPreferences`)、路径 (`Paths` / `SocketPaths`)、Unix socket 原语、`SignalGuard`、`VMnetBridgeProbe`、`Tunables`、版本号.
- **HVMUtils** — 跨模块无业务语义 helper: `Format`(字节格式化)、`Hashing`(sha256)、`FSCleanup`、`ResumableDownloader`、`CliExit`. 仅依赖 HVMCore.
- **HVMBundle** — `.hvmz` bundle 的读写与状态: `VMConfig`(config.yaml schema, Yams)、`BundleIO`、`BundleLayout`、`BundleDiscovery`、`BundleLock`(fcntl flock 单进程互斥)、`ConfigMigrator`、`ThumbnailWriter`.
- **HVMStorage** — 磁盘与整 VM 存储操作: `DiskFactory`(qemu-img create/resize)、`CloneManager`(APFS clonefile COW 克隆)、`SnapshotManager`、`ISOValidator`、`VolumeInfo`. 依赖 HVMBundle/HVMNet(克隆重生 MAC)/HVMEncryption(加密 VM 分支).
- **HVMNet** — 网卡配置: `MACAddress`(生成)、`NICFactory`、`IPResolver`. (vmnet daemon 提权走 GUI Services 层 + scripts, 见下.)
- **HVMInstall** — 安装资源下载/缓存: `OSImageCatalog` / `OSImageFetcher`(Linux/Windows ISO)、`UtmGuestToolsCache`、`VirtioWinCache`、`InstallProgress`. macOS IPSW 部分已删.
- **HVMIPC** — host 子进程 ↔ cli/dbg 的 JSON-over-unix-socket 协议: `Protocol`(IPCRequest/Response + IPCOp 枚举)、`Frame`(length-prefix framing)、`SocketServer` / `SocketClient`. 仅依赖 HVMCore.
- **HVMQemu** — QEMU 进程编排与控制: `QemuArgsBuilder`(argv 构造)、`QemuProcessRunner`、`QmpClient`/`QmpProtocol`(QMP unix socket)、`QemuPaths`(包内二进制解析)、`Qga*`(qemu-guest-agent exec/file/dir)、`SpiceWebdavServer`(共享目录 WebDAV)、`Swtpm*`(Win11 TPM 2.0)、`QemuConsoleBridge`(serial→console.log)、`SidecarOrphanReaper`、`WindowsUnattend`.
- **HVMScmRecv** — 唯一 C target. `recvmsg` + cmsg 胶水层接收 SCM_RIGHTS 传来的 fd (Swift 调不了 `CMSG_*` 宏). 仅供 HVMDisplayQemu 接 HDP `SURFACE_NEW` 携带的 shm fd.
- **HVMEncryption** — 整 VM 加密: `EncryptedBundleIO` / `EncryptedConfigIO` / `RoutingMetadata`(routing JSON)、`PasswordKDF`(PBKDF2)/`EncryptionKDF`/`MasterKey`/`SecureBytes`、`QcowLuksFactory` / `OVMFVarsLuksFactory`(LUKS keyslot)、`SwtpmKeyHelper`、`Encrypt/Decrypt/RekeyVMOperation`(CLI+GUI 同源事务)、`SecureErase`. (sparsebundle 工具留存但 VZ-sparsebundle 加密 scheme 已随 VZ 下线, 加密 VM 恒 qemuPerfile.)
- **HVMDisplayQemu** — QEMU 画面嵌入: HDP v1.0.0 socket 客户端 (`DisplayChannel` / `HDPProtocol`)、Metal 零拷贝渲染 (`FramebufferRenderer` / `FramebufferHostView`)、输入转发 (`InputForwarder` / `NSKeyCodeToQCode`)、`VdagentClient`(SPICE vdagent 复用: 文本/文件粘贴/共享目录)、`PasteboardBridge` / `FilePasteBridge` / `HVMFileClipboardBridge`、`OCREngine`、`CGSPrivate`(键盘捕获私有 API)、`BootPhaseClassifier`.
- **HVMControl** — **视图无关的 VM 控制门面, cli + GUI store 共用单一来源**. `VMCatalog`(枚举)、`VMControl`(启停/删除/改 config/磁盘/加密事务)、`HostLauncher`(fork `--host-mode-bundle` 子进程)、`VMSummary`. 不链接后端实现 (只 fork host 子进程). 详见下文「控制层单一来源」.
- **HVMGuiProbe** — HDP-GUI 测试协议: `ProbeRegistry`(控件注册)、`ProbeServer`(unix socket, 仅 `HVM_GUI_PROBE=1` 启)、`HVMProbeViewModifier`(`.hvmProbe(...)`)、`ScreenshotRenderer`. 让 `hvm-dbg gui click/type/read/screenshot` 能驱动主进程 GUI.
- **HVM** (executable) — GUI 主进程 (`GUI/**` SwiftUI 新 GUI + `NewGUIStore`) + VMHost 子进程入口 (`HVMHostEntry` / `QemuHostEntry`) + vmnet 提权服务 (`Services/VMnetSupervisor`). 聚合上述大多数库.
- **hvm-cli** (executable) — 命令式 CLI, 每个动作一个 `Commands/*Command.swift` (create / start / stop / clone / encrypt / disk / shared-folder / snapshot ...), 走 HVMControl + HVMStorage + HVMEncryption.
- **hvm-dbg** (executable) — 调试/自动化 CLI, `Commands/*Command.swift` (screenshot / key / mouse / ocr / exec / file / paste-files / gui / webdav ...). 仅复用已暴露的 IPC/QMP/HDP API, 零新协议.

> 测试约束: 工程**不含 testTarget**, 不写 XCTest (CLT-only 机器跑不起). 验证走 `make build`
> (编译期保证) + 真机 e2e (`hvm-cli` / `hvm-dbg gui`).

## 进程模型

三层进程, 通过 unix domain socket 通信, bundle 用 flock 单进程互斥.

```
  ┌─────────────────────────────┐
  │ GUI 主进程 (HVM.app)         │   NewGUIStore (@Observable)
  │  - SwiftUI 新 GUI            │   1Hz refresh → VMCatalog.list
  │  - 嵌入 framebuffer (HDP)    │
  └───────────┬─────────────────┘
              │ fork: Process("HVM --host-mode-bundle <path>")
              │  password 经 stdin pipe 透传 (加密 VM)
              ▼
  ┌─────────────────────────────┐    HDP IOSurface socket
  │ VMHost 子进程                │◀───────────────┐ (画面/输入/vdagent)
  │  (HVM --host-mode-bundle)    │                │
  │  HVMHostEntry → QemuHostEntry│                │
  │  - 抢 BundleLock(.runtime)   │   QMP unix socket │
  │  - 起 IPC SocketServer       │◀──────┐        │
  │  - 起 SpiceWebdav / swtpm    │       │        │
  └───────────┬─────────────────┘       │        │
              │ Process("qemu-system-aarch64 ...")  │
              ▼                          │        │
  ┌─────────────────────────────┐       │        │
  │ qemu-system-aarch64 (包内)   │───────┴────────┘
  │  + HVF 加速 + swtpm sidecar  │
  └─────────────────────────────┘
```

关键点:

1. **GUI ↔ host 子进程是同一个 `HVM` binary 的两种角色** (省去单独 helper bundle). GUI 通过
   `HostLauncher.launch` fork 子进程并立即拿到 pid; 子进程在 `main.swift` 顶部按 argv 分派到
   `HVMHostEntry.run`.
2. **加密 VM 密码经 stdin pipe 透传**: 父进程 `proc.run()` 后 write password + close write 端;
   子进程 `main.swift` read-to-EOF (1s timeout) 拿到密码, 调 `EncryptedBundleIO.unlock`. 明文
   VM 父进程立即 close (子进程读到 EOF 当作明文).
3. **VMHost 子进程职责** (`QemuHostEntry`): 解析包内 QEMU 路径 (`QemuPaths`)、orphan reaper 清上次
   崩溃残留、抢 `BundleLock(.runtime)`、起 IPC `SocketServer` (供 cli/dbg `status`/`stop`/`kill`/
   `dbg.*`)、构造 QEMU argv (`QemuArgsBuilder`)、起 `QemuProcessRunner` + `QmpClient`、按需起
   swtpm / SpiceWebdav server.
4. **IPC**: `HVMIPC` 的 JSON-over-unix-socket. socket 路径 `~/Library/Application Support/HVM/
   run/<uuid>.sock`, **严禁 TCP 监听**. op 枚举见 `Protocol.swift` (`status` / `stop` / `kill` /
   `pause` / `resume` / 一组 `dbg.*` / `clipboard.*` / `display.*`). 带 `protoVersion` 做版本协商.
5. **QMP**: host 子进程对 QEMU 的控制走 `QmpClient`, 仅监听 `run/<uuid>.qmp` unix socket.
6. **HDP IOSurface**: QEMU patch 0002 引入的 macOS-only display backend (`-display iosurface,
   socket=...`). QEMU 把渲染面 IOSurface 的 shm fd 经 AF_UNIX + SCM_RIGHTS 传给 host 子进程
   (`HVMScmRecv` 收 fd), host 侧 `FramebufferRenderer` 用 Metal 零拷贝渲染进 `FramebufferHostView`,
   再嵌进 GUI 详情页. 协议规范 `docs/QEMU_DISPLAY_PROTOCOL.md`.
7. **bundle 单进程互斥**: 一个 `.hvmz` 同时只能被一个进程打开, `BundleLock` 用 fcntl flock
   (`.runtime` / `.edit` 两 mode). cli/dbg 不持锁, 通过 `BundleLock.inspect` 拿到 host 子进程
   写入 lock 的 socketPath 再发 IPC.

## 控制层单一来源: HVMControl

VM 的「枚举 / 启停 / 删除 / 改配置 / 加密事务」全部收口到 `HVMControl` target, **hvm-cli 命令与
GUI 的 `NewGUIStore` 共用同一套**, 不再各抄一份扫盘/拼装逻辑 (历史教训: 同模式逻辑抄多份必漂移).

- `VMCatalog.list` — 扫 `~/Library/Application Support/HVM/VMs/` 下所有 `.hvmz` → `[VMSummary]`
  (displayName 升序). 明文走 `BundleIO.load`, 加密 VM 不解密走 routing JSON 拿 displayName/id/guestOS.
  运行态走 `BundleLock.isBusy` (flock 非阻塞探测).
- `VMControl` — 动作门面:
  - `start(bundleURL:password:)` → 委托 `HostLauncher.launch` fork host 子进程; 已 running 抛 `.bundle(.busy)`.
  - `stop` / `kill` / `status` → `BundleLock.inspect` 拿 socketPath → `SocketClient` 发 IPC.
  - `delete(mode:)` → `.trash` / `.purge` / `.secureErase`, 必须 stopped.
  - `saveConfig` / `addDisk` / `resizeDisk` / `deleteDisk` / `setClipboardSharing` 等, **内部分流
    明文 (`VMControl.*`) 与加密 (`VMControl.*Encrypted`)** — 业务侧不直接碰 `BundleIO.save` /
    `EncryptedConfigIO.save`.
  - `encryptVM` / `decryptVM` / `rekeyVM` → 包装 `HVMEncryption` 的三个 Operation (CLI 同源).
- `HostLauncher` — fork `--host-mode-bundle` 子进程. `locateHVMBinary` 探测顺序: `HVM_APP_PATH`
  env → **跟随调用方自身位置** (`Bundle.main` 的兄弟 `HVM` / 兄弟 `HVM.app`) → `/Applications`
  兜底. 让 "我从哪个 build 出来就用哪个 build 的 HVM + 包内 QEMU", dev 期无需先 `make install`.

GUI 侧 `NewGUIStore` (`@Observable @MainActor`) 即是这套门面的薄封装: 1Hz `refresh()` 调
`VMCatalog.list`, 所有动作转发 `VMControl.*`, 失败走 `lastError` 冒泡到 `MainLayoutView` 弹错误
dialog. 它**不依赖**老 `AppModel`, 也不抄后端拼装逻辑.

## GUI 结构 (HVM target 内)

唯一 GUI 是新 GUI (`app/Sources/HVM/GUI/**`, `GUI=new` 恒开; 老 `UI/**` 已退役删除). 入口
`NewGUIAppLauncher`, 主界面 `Layout/MainLayoutView` 两栏骨架 (sidebar 240 列表 + detail 详情页 +
statusbar). 详情页 `DetailOverviewView` 铺 inline 可编辑 section (资源 / 网络 / 磁盘 / ISO&启动 /
共享目录 / 选项 / 加密). 自绘组件库 `HVMUI.*` (Button/TextField/Toggle/Select/Modal...) 强制传
`probeID` 给 HDP-GUI 自动化测试 (编译期 enforce). dialog 走 `HVMUI.DialogPresenter`. vmnet daemon
提权走 `Services/VMnetSupervisor` (osascript admin Touch ID + `scripts/install-vmnet-daemons.sh`).

## 第三方二进制与运行时资源边界

- **运行时第三方二进制/资源严格只走 `.app` 包内** (`Bundle.main/Resources/QEMU/...`):
  `qemu-system-aarch64` / `qemu-img` / `swtpm` / EDK2 firmware / 配套 dylib 全 bundle 进 .app,
  逐文件 codesign, 零依赖宿主机 Homebrew. 解析走 `QemuPaths` / `SwtpmPaths`, **严禁 fallback** 到
  `/opt/homebrew` / `third_party/`. 仅 env override (`HVM_QEMU_ROOT` 等) 给 CI/调试用.
- **`socket_vmnet` 例外不入包**: 用户机器自行 `brew install socket_vmnet`, GUI 通过 osascript
  admin 装 launchd daemon, QEMU 用 `-netdev stream` 直连固定路径 unix socket. 见 `docs/NETWORK.md`.
- **packager 工具例外**: `scripts/qemu-build.sh` + `scripts/edk2-build.sh` 在打包者机器编译 QEMU
  (`v10.2.0`) / EDK2 (`edk2-stable202408`) 源码 + 嵌 swtpm dylib, 产物随 .app 分发; 最终用户机器零依赖.
  `make build` 自身不编译 QEMU, 完整发布走 `make build-all`.

## 数据与路径布局

- 用户数据根: `~/Library/Application Support/HVM/` (`VMs/` 存 `.hvmz` bundle + `cache/` + `logs/` + `run/` socket).
- VM bundle: `<name>.hvmz/` — `config.yaml` (YAML 1.1, schema v3) / `disks/*.qcow2` / `nvram/efi-vars.fd` /
  `tpm/*` (Win11 swtpm) / `logs/console-*.log` (guest serial) / `.lock`. 加密 VM 用 `config.yaml.enc` +
  routing JSON + LUKS 包裹 qcow/vars.
- host 侧日志 → `~/Library/Application Support/HVM/logs/`; guest serial console.log → `<bundle>/logs/`.

## 关联文档

- `docs/QEMU_INTEGRATION.md` — QEMU 后端集成细节、patch 串行管理.
- `docs/QEMU_DISPLAY_PROTOCOL.md` — HDP IOSurface 显示协议 v1.0.0.
- `docs/NETWORK.md` — socket_vmnet 网络方案.
- `docs/v4/QEMU_ONLY_PIVOT.md` — VZ 移除 / QEMU-only 转向决策.
- `docs/v4/NEW_GUI*.md` — 新 GUI 主线设计.
- `docs/v3/HVM_DBG_GUI_PROTOCOL.md` — HDP-GUI 自动化测试协议.
- `CLAUDE.md` — 全量约束 (身份命名 / 交付 / 构建 / QEMU 后端 / 第三方二进制).
