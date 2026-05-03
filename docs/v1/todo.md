# todo.md (历史归档)

> **本文件保留作历史追溯**, 当前 TODO 一律走 [../v2/](../v2/)。
>
> v2 入口: [../v2/README.md](../v2/README.md) — 2026-05-03 全项目深审产出的 45 项 TODO, 按 P0/P1/P2 分级。
>
> 原 v1/todo.md 的"阻塞中 / 长期 / Polish"段(V-1 / L-2 / L-4 / P-1 ~ P-4)已迁到 [../v2/05-pending-from-v1.md](../v2/05-pending-from-v1.md) 统一管理。

## ✅ 已完成 (供历史追溯, 滚动归档)

- (2026-05-04) **剪贴板共享 + macOS 风快捷键 + detached 窗口重写**: `HVMDisplayQemu.PasteboardBridge` 双向 UTF-8 文本同步走 vdagent virtio-serial; VMConfig 加 `clipboardSharingEnabled` (默认 true) + `macStyleShortcuts` (host cmd→guest ctrl 转发, 默认 true); IPC 加 `clipboard.setEnabled` 运行时切换; detached borderless 窗口重写, 嵌入 ⇄ 独立切换稳定; README 同步过时项

- (2026-05-03) **自动下载 OS 镜像 (新功能)**: 新建 `OSImageCatalog` 内置 7 个 arm64 Linux 发行版 (Ubuntu 24.04 LTS / Ubuntu 22.04 LTS / Debian 13 / Fedora 44 / Alpine 3.20 / Rocky 9 / openSUSE Tumbleweed) + `OSImageFetcher` (catalog 下载 + custom URL 兜底 + SHA256 校验); UI: `OSImagePickerDialog` (linux 列发行版, windows 显示 Win11 Insider/UUP 提示 + Win10 不可用警告) + `OSImageFetchDialog` (含 `verifying` 阶段); CLI: `hvm-cli osimage list / fetch / cache / rm`; 缓存路径 `~/Library/Application Support/HVM/cache/os-images/<family>/`; CreateVMDialog Linux/Windows 分支 ISO 字段下加 "Download…" 按钮入口

- (2026-05-03) **P-5 公共工具函数重构 (HVMUtils)**: 新建 `HVMUtils` SwiftPM target 收纳 `Format.bytes/rate/eta` (替换 4 处重复) + `Hashing.sha256Hex` (替换 2 处重复) + `ResumableDownloader` (从 IPSWFetcher 抽出 generic 断点续传 + If-Range + 416 重试 + atomic rename, 给 OS 镜像下载共用); IPSWFetcher 改为 wrapper, 调用方行为不变; 实测散点只有 ~60 行 refactor (todo 原估 300-800 行高估了 — 多处"看似重复"实为业务耦合不该抽)

- (2026-05-03) **phase 4 socket_vmnet hell-vm 同款重构**: NetworkMode 切 5-mode (none/nat/vmnetShared/vmnetHost/vmnetBridged); QEMU 直接 `-netdev stream,addr.type=unix,addr.path=...` 接 daemon 固定路径 socket, 退役 sidecar fd-passing; install-vmnet-daemons.sh 走 osascript Touch ID 安装 launchd plist (label `com.hellmessage.hvm.vmnet.*`); 新建 VMSettingsNetworkSection 4 文件接 EditConfigDialog, 删老 vmnet UI 设施

- (2026-04-30) **L-1 QEMU 显示嵌入主窗口**: framebuffer shm + Metal 零拷贝方案完整落地 — patches/qemu/0002-ui-iosurface-display-backend.patch + 0003-hw-display-hvm-gpu-ramfb-pci.patch 自写; HVMDisplayQemu 模块 (DisplayChannel / HDPProtocol / FramebufferRenderer / FramebufferHostView / InputForwarder / NSKeyCodeToQCode / VdagentClient); QemuArgsBuilder 接 `-display iosurface,socket=...`; HDP 协议 v1.0.0 规范固化到 docs/QEMU_DISPLAY_PROTOCOL.md

- (2026-04-30) **M-3 GUI Snapshot 操作**: DetailBars 加 TerminalSection("Snapshots") 列表 + New Snapshot 按钮接 SnapshotCreateDialog + Restore / Delete 走 ConfirmPresenter

- (2026-04-27) **L-3 (A1+B1)**: 多 VM 并发管理 UX — GUI 主窗口右栏顶部加 RunningTabsBar (运行中 VM 横向 tab + × 关闭, 切换走 selectedID 复用现有 transition); CLI `hvm-cli list --watch -w` + `--interval` (默认 2s, ANSI 清屏 + DispatchSource SIGINT 优雅退出, json 模式不清屏方便 jq pipe). 多 NSWindow 方向因 VZ Metal drawable 跨 window reparent 黑屏限制不可行, 已在 plan 备注

- (2026-04-27) **U-1 / U-2 / U-3**: 三项实测全部验证通过 — Linux arm64 装机 (QEMU+HVF) 稳定 / Win11 arm64 装机 (swtpm+virtio-win+EDK2) 闭环 / socket_vmnet bridged 真出网

- (2026-04-26) **M-1**: NetworkMode 加 .shared (跨 HVMBundle/HVMNet/HVMQemu/CLI 同步); GUI CreateVMDialog 加 Engine 选择器 (Linux 专用) + Network 段 (NAT/Bridged/Shared) + 接口枚举 + sudoers 检测 + osascript+复制 helper; EditConfigDialog 同步加 Network 编辑; install-vmnet-helper.sh 打包入 .app

- (2026-04-26) **M-2**: GUI Disks section 列表 + DiskAddDialog / DiskResizeDialog + 数据盘 delete 走 ConfirmPresenter

- (2026-04-26) **M-4**: QEMU host 进程加 thumbnail 10s 定时器 (与 VZ 同周期); HVMBundle 抽 ThumbnailWriter atomic 写盘 helper, VZ 与 QEMU 路径共用

- (2026-04-26) **bug fix**: GUI 启动 QEMU VM 走外部进程 (spawn HVM 自身 --host-mode-bundle); stop/kill 通过 IPC client fallback (修「VZ 后端不支持 windows」错误)

- (2026-04-26) **S 系列**: docs/DEBUG_PROBE.md 加 QEMU 后端附注 (S-2); README 加 socket_vmnet bridged 使用 (S-3); Makefile 加 `make xed` (S-4); S-1 代码已就位, 实测合并到 U-3

- (2026-04-26) **G 系列**: VZ/QEMU 共用 helper (BootPhaseClassifier / OCRTextSearch / GuestOSType.defaultFramebufferSize)

- (2026-04-26) **F 系列**: QEMU dbg.* 串口通道 (boot_progress / console.read / console.write)

- (2026-04-26) **E4 系列**: QEMU dbg.* 截屏 + 输入 (screenshot/status/ocr/find_text/key/mouse)

- (2026-04-26) **E0-E3 系列**: socket_vmnet 集成 (Swift + 打包入 .app + sudoers helper)

- (2026-04-26) **D 系列**: GUI Win 选项 + virtio-win 自动下载 + swtpm sidecar + 自动打包

- (2026-04-26) **C 系列**: hvm-cli/start 双后端派发, hvm-dbg qemu-launch 端到端验证

- (2026-04-26) **A/B 系列**: HVMQemu 模块, QmpClient

- (2026-04-26) **app/ 重构**: SwiftPM 包下沉到 `app/` 子目录

## 当前未完成项

未完成项已迁到 [../v2/05-pending-from-v1.md](../v2/05-pending-from-v1.md) (V-1 / L-2 / L-4 / P-1 ~ P-4)。

## v2 优化项

完整 45 项 TODO 总览见 [../v2/](../v2/), 按优先级分:

- [01-P0-immediate.md](../v2/01-P0-immediate.md) — P0 立即修
- [02-P1-this-week.md](../v2/02-P1-this-week.md) — P1 本周做
- [03-P2-techdebt.md](../v2/03-P2-techdebt.md) — P2 技术债
- [04-doc-drift.md](../v2/04-doc-drift.md) — 文档与代码漂移
- [05-pending-from-v1.md](../v2/05-pending-from-v1.md) — 来自 v1/todo.md 的悬挂项
- [06-already-compliant.md](../v2/06-already-compliant.md) — 已合规项审核留痕

---

**最后更新**: 2026-05-04
