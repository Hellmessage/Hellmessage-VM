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

## 🟢 用户参与 (实测验证, AI 做不了)

### U-1 · Linux arm64 ISO 真装机
- **目的**: 验证 QEMU 后端 + HVF 在真实 Linux installer 上的稳定性
- **步骤**:
  ```bash
  make build-all
  build/hvm-cli create --name ubuntu --os linux --engine qemu \
      --cpu 4 --memory 4 --disk 32 \
      --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso
  build/hvm-cli start ubuntu
  # 观察 cocoa 窗口 GRUB / installer 流程
  ```
- **关注**:
  - QEMU 进程稳定性 (无随机崩溃)
  - virtio-blk 性能 (装机吞吐)
  - virtio-net NAT 出网正常
  - hvm-dbg screenshot/key/mouse 在装机界面真能注入 (E4a/E4b 已做未实测)

### U-2 · Win11 arm64 ISO 真装机
- **目的**: 验证 swtpm + virtio-win + EDK2 SecureBoot 完整闭环
- **步骤**:
  ```bash
  make build-all
  open build/HVM.app   # GUI 创建向导选 Windows (实验性) → 填 Win11 ARM ISO 路径
  # → 自动下 virtio-win.iso (~700MB modal) → Create
  # → 选中 VM → Start
  # → 装机 Browse 驱动 → E:\amd64\w11 → viostor.sys → 看到磁盘 → 继续装
  ```
- **关注**:
  - swtpm 真被 Win11 信任 (TPM 检查通过)
  - SecureBoot NVRAM 跨重启持久 (pflash 双 drive)
  - virtio-win driver 注入成功 (装机能见盘)
  - 装完重启 OS 不蓝屏

### U-3 · socket_vmnet bridged 真出网
- **前置**: 跑过 `scripts/install-vmnet-helper.sh` 一次配 sudoers
- **步骤**:
  ```bash
  build/hvm-cli create --name foo --os linux --engine qemu \
      --network bridged:en0 ...
  build/hvm-cli start foo
  # guest 内验证 IP 是物理 LAN 段, 跨机 ping / ssh 通
  ```

---

## 🟡 短期可做 (小工程, < 200 行)

### S-1 · QEMU 后端 hvm-dbg qemu-launch 接 socket_vmnet sidecar 也用
- **现状**: `QemuHostEntry` (生产路径) 已支持 socket_vmnet bridged; `QemuLaunchCommand`
  (调试路径) 也加了, 但未实测
- **工作量**: 已经做过 (E1 commit), 需实测确认

### S-2 · docs/DEBUG_PROBE.md 加 QEMU 后端 dbg.* 章节
- **现状**: 文档主要描述 VZ 路径; QEMU 等价实现细节 (QMP screendump → PPM, send-key qcode 映射,
  input-send-event abs 32767 等) 没归档
- **工作量**: 1-2 小时, 纯文档

### S-3 · README.md 加 socket_vmnet bridged 使用方法
- **现状**: README 只示例 NAT; bridged 流程 (helper 脚本 + `--network bridged:en0`) 没写

### S-4 · `xed` 命令封装到 Makefile
- **现状**: 文档让用户 `xed app/Package.swift`; 加 `make xed` 等 alias 更顺手
- **工作量**: 5 分钟

---

## 🟠 中期 (中等工程, 200-500 行)

### M-1 · GUI 加 bridged 网络选项 + sudoers 自动检测引导 dialog
- **现状**: `CreateVMDialog` 硬编码 `NetworkSpec(mode: .nat)`; 用户走 GUI 创建无法选 bridged
- **要做**:
  - CreateVMDialog 加 Network 段 (Picker: NAT / Bridged / Shared / Host)
  - 选 Bridged 时弹接口选择 + 检测 `/etc/sudoers.d/hvm-socket-vmnet` 是否就绪
  - 缺则在 dialog 内插提示卡片 + "Run install-vmnet-helper.sh" 按钮 (NSWorkspace 开 Terminal)
  - EditConfigDialog 同步加网络模式可改
- **关联**: 之前 D2 时记为 E3b, 推迟到 GUI 真有 bridged 入口时一起做
- **工作量**: ~300 行 (UI + sudoers 检测 helper)

### M-2 · GUI 数据盘 add/remove + 扩容
- **现状**: CLI 有 `hvm-cli disk add/grow/list/delete`; GUI 详情面板没暴露
- **要做**: VM 详情面板加 Disks 段, 列表 + 加按钮 + 大小调整
- **工作量**: ~250 行

### M-3 · GUI Snapshot 操作
- **现状**: CLI 有 `hvm-cli snapshot create/list/restore/delete`; GUI 半成品
- **要做**: 详情面板 Snapshots 段, 列表 + 创建 dialog (已有 SnapshotCreateDialog 骨架) + 还原确认
- **工作量**: ~200 行

### M-4 · QEMU 后端的 GUI 列表 thumbnail
- **现状**: VZ 路径有 `ThumbnailCache` (`ScreenCapture` 抓离屏 window); QEMU 路径没接, 缩略图为空
- **要做**: 用 `QemuScreenshot` 定期抓 → 写到 `bundle/meta/thumbnail.png` (与 VZ 路径同位置)
- **工作量**: ~150 行

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

### L-3 · 多 VM 并发管理 UX
- **现状**: GUI 一次只嵌入一个 VM (`embeddedID`), 切换要先 detach;
  CLI 各 VM 独立 host 进程, 无统一面板
- **要做**: GUI tabs 或多窗口; CLI `hvm-cli list --watch` 持续状态
- **工作量**: 难估; UX 设计不小

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

---

## ✅ 最近完成 (供历史追溯, 滚动清理)

- (2026-04-26) **G 系列**: VZ/QEMU 共用 helper (BootPhaseClassifier / OCRTextSearch / GuestOSType.defaultFramebufferSize)
- (2026-04-26) **F 系列**: QEMU dbg.* 串口通道 (boot_progress / console.read / console.write)
- (2026-04-26) **E4 系列**: QEMU dbg.* 截屏 + 输入 (screenshot/status/ocr/find_text/key/mouse)
- (2026-04-26) **E0-E3 系列**: socket_vmnet 集成 (Swift + 打包入 .app + sudoers helper)
- (2026-04-26) **D 系列**: GUI Win 选项 + virtio-win 自动下载 + swtpm sidecar + 自动打包
- (2026-04-26) **C 系列**: hvm-cli/start 双后端派发, hvm-dbg qemu-launch 端到端验证
- (2026-04-26) **A/B 系列**: HVMQemu 模块, QmpClient
- (2026-04-26) **app/ 重构**: SwiftPM 包下沉到 `app/` 子目录

---

**最后更新**: 2026-04-26
