# TODO

整理截至 2026-04-26 之后剩下的事. 按"是否阻塞"+"工程量"排序.

> 注: 完整设计沉淀仍在 `docs/QEMU_INTEGRATION.md` / `docs/ROADMAP.md`.
> 本文件只列**未完成项**, 完成后从这里删除即可.

---

## 🔴 阻塞中 (等外部因素)

### V-1 · Apple `com.apple.vm.networking` entitlement
- **现状**: 已向 Apple Developer Support 提交申请 (2026-04-25), 审批中
- **审批通过后要做**:
  - `app/Resources/HVM.entitlements` 解开 `com.apple.vm.networking` 注释
  - 嵌入 `embedded.provisionprofile` (审批回信指引)
  - `HVMNet/NICFactory` 加 `VZBridgedNetworkInterface` case
  - GUI 创建向导网络段加 "桥接 (VZ)" 选项
  - CLI `--network bridged:en0` (现已是合法值, 但 VZ 端会因 entitlement 缺失报错; 审批后报错消失)
- **跟 socket_vmnet 关系**: socket_vmnet 已让 QEMU 后端 bridged 网络可用, **不依赖此审批**.
  审批通过后 VZ 后端的 bridged 才能落, 与 QEMU socket_vmnet 路径并存供选

---

## 🟠 中期 (中等工程, 200-500 行)

### M-3 · GUI Snapshot 操作
- **现状**: CLI 有 `hvm-cli snapshot create/list/restore/delete`; GUI 半成品
- **要做**: 详情面板 Snapshots 段, 列表 + 创建 dialog (已有 SnapshotCreateDialog 骨架) + 还原确认
- **工作量**: ~200 行

---

## 🔵 长期 (大工程, > 500 行 或需要重大调研)

### L-1 · QEMU 显示嵌入 HVM 主窗口
- **现状**: QEMU 用 `-display cocoa` 自开独立 NSWindow; 不与 HVM 主窗口右栏共享
- **方案候选**:
  - **A. SPICE**: QEMU `-spice unix:...,addr=...,disable-ticketing=on` + Swift 实现 SPICE 客户端;
    上游 spice-gtk 是 GTK, 没 macOS 原生客户端, 要自己写或集成 vinagre/remote-viewer
  - **B. Pixman 帧管道**: QEMU 暴露 frame buffer 给 host 进程 (UDS), 自己渲到 NSView;
    QEMU 不原生支持, 要 patch
  - **C. VirtioGPU 直接渲染**: macOS 端用 IOSurface 接收, 复杂度极高
- **决策**: 暂不做; 等用户用一段时间独立 cocoa 窗口反馈痛点
- **工作量**: 大头 (1-2 周)

### L-2 · Rosetta share
- **现状**: VZ 已有 API (`VZLinuxRosettaDirectoryShare`); 我们没集成
- **要做**: VMConfig 加 `linux.rosettaShare` (已有字段, 但 ConfigBuilder 没用)
  + ConfigBuilder 装 Rosetta 共享; 需检测 host Rosetta 安装状态
- **工作量**: ~200 行 + 实测

### L-4 · vmnet daemon 热重装时 QMP 热重连 (方案 C)
- **背景**: 当前 popover 上「重装 / 修复 shared + host」按钮会 bootout daemon →
  老 daemon 进程被杀 → 运行中 VM 的 QEMU fd=3 收到 EOF, `-netdev socket,fd=3` 标 disconnected.
  QEMU 不会自行重连 (fd 模式没有 path 信息), 用户必须重启 VM 才能恢复网络.
- **现已落地的最低防护**: GUI popover 加运行中 VM 检测, 占用对应 daemon 时禁用按钮 (待补).
  脚本侧 bootstrap retry + 等 bootout 完成 (已落, 修了 EIO race).
- **真正零感知方案**:
  1. 重装前 HVM 收集每个运行中 VM 的 `(qmpSocket, netdev_id, daemon_path)` 清单
  2. daemon 重启完成后, 对每个 VM:
     a. HVM 自己 `socket(AF_UNIX)+connect()` 新 daemon 拿新 fd
     b. 通过 QMP socket 用 `sendmsg(2) + SCM_RIGHTS` 把新 fd 传给运行中 QEMU
     c. QMP `getfd name=netfd-N` 把 fd 在 QEMU 内部命名
     d. QMP `netdev_del id=netN` + `netdev_add socket,id=netN,fd=netfd-N`
- **工程量评估**:
  - QmpClient 扩 `sendFD(qmpSocket:, fd:)`: ~80 行 (sendmsg 控制消息封装)
  - 重装编排: vmnet 重装前快照 + 重装后批量重连: ~150 行
  - 边界处理: guest 内 ARP/MAC 学习 stale (一般 30s 自愈), 重连失败时降级提示: ~50 行
  - 总 ~300 行 + 调试
- **决策**: 暂搁置. lima/colima 也都不做 (用户重装/重启 daemon 是稀有事件); 现有方案 A (UI 拦截) + 重启 VM 已经够用. 等用户反馈痛点再做

---

## ⚪ Polish / 低优 (可有可无)

### P-1 · Status / screenshot payload 编码助手
- **现状**: VZ DbgOps + QEMU QemuHostState 都有 4-5 行重复的 `JSONEncoder().encode + ipc.encode_failed` 模式
- **决策**: 4-5 行不抽更清晰, 抽出来一个 helper `encodePayloadResponse<T>(req:_, payload:T)` 可省 ~10 行
- **优先级**: 极低

### P-2 · `--engine qemu` flag 加 enum 校验提示
- **现状**: CLI `--engine vz|qemu` 字符串拼写错只在 `parseEngine` throw 时才报;
  ArgumentParser 可加 `Enum + RawRepresentable` 自动校验
- **工作量**: 30 分钟

### P-3 · `qemu-build.sh` --check 模式
- **现状**: 跑 `make qemu` 第一次要拉源码 + 编译 30 分钟; 想确认 brew deps / 路径配置正确不带编译
- **要做**: `--dry-run` 只跑 preflight + ensure_homebrew + ensure_brew_packages

### P-4 · GUI + host 子进程 menu bar 双 status item 重复
- **现状**: GUI 启动 QEMU/VZ host 子进程后, 主 GUI 与 host 子进程各自注册 NSStatusItem, menu bar 同时出现 2 个 HVM 图标
  - 主 GUI: `app/Sources/HVM/HVMApp.swift` (`HVM //0 running` 弹出)
  - 子进程 QEMU host: `app/Sources/HVM/QemuHostEntry.swift:434-474` `installStatusItem` (`HVM · <name> (qemu)` 弹出)
  - 子进程 VZ host: `app/Sources/HVM/HVMHostEntry.swift:~277` 同款
- **设计意图**: host 进程能独立运行 (`hvm-cli start` 起的 VM 无 GUI), 给用户独立 Stop/Kill 入口; 跟主 GUI 共存时是冗余
- **方案候选**:
  - **A** (推荐): GUI `spawnExternalHost` 给子进程加 env `HVM_HIDE_STATUS_ITEM=1`, host entry 启动时检测该 env 跳过 `installStatusItem`. 优点改动最小, hvm-cli 起的 host (无 env) 仍显图标
    - 副作用: GUI 中途退出但 host 子进程仍跑时, menu bar 入口消失. 可加退出 hook 给所有派生 host 发"恢复 status item" IPC, 或退出时一并 stop 所有派生 host
  - **B**: host 进程永远不注册 status item; hvm-cli 用户从终端控制 (彻底简化, hvm-cli 用户体验回退)
  - **C**: GUI ↔ host IPC 协调动态隐藏/恢复 (语义最优, 工程量大)
- **工作量**: ~20 行 (方案 A)

---

## ✅ 最近完成 (供历史追溯, 滚动清理)

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

---

**最后更新**: 2026-04-27 (L-3 完成: GUI RunningTabsBar + CLI list --watch)
