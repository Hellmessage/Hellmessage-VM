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

### L-1 · QEMU 显示嵌入 HVM 主窗口 ⏳ 进行中 (2026-04-27 启动)

**目标**: QEMU guest 屏幕嵌入主窗口右栏 (跟 VZ HVMView 对齐), 退役独立 `-display cocoa` NSWindow

**方案**: **framebuffer shm + Metal 零拷贝** (非真 virgl GPU 加速)
- guest: virtio-gpu-pci + ramfb 双 console (Linux 用 virtio_gpu / Win 用 viogpudo, 都只发 framebuffer pixel)
- QEMU: 自写 `ui/iosurface.m` backend, framebuffer 写到 POSIX shm
- IPC: AF_UNIX + sendmsg/SCM_RIGHTS 传 shm fd 给 host
- host: mmap shm + `MTLBuffer(bytesNoCopy:)` + Metal fullscreen shader
- 输入: QMP `input-send-event` 走独立 input QMP socket (与控制通道分离)
- 编译: `--disable-cocoa --disable-vnc --disable-sdl --disable-opengl`, 不引 virglrenderer

**为何不走真 virgl GPU 加速**: macOS GL 已 deprecated; Win viogpudo 是 Display-Only 没 GL command stream; framebuffer shm + Metal 对桌面办公已足够流畅, Linux + Win 走同一通路

**参考**: 同作者 hell-vm 已 production 验证, **patch 必须自写**, Swift 侧待定 (见决策点 1)

#### 协议规范 v1.0.0 (已敲定, 详细规范同步落 docs/QEMU_INTEGRATION.md)

**字节序 / 头格式 / 版本号**
- 字节序: little-endian (Apple Silicon + x86 host 都 LE, 无需转换)
- 消息头 8 字节: `{ type:u16, flags:u16, payload_len:u32 }`
- 协议版本号: 单 u32 = `(major<<16)|(minor<<8)|patch`, 起步 `0x00010000` (1.0.0)

**向后兼容策略 (协议演进核心规则, 必须严格执行)**
1. **HELLO 双向版本协商**: host 与 QEMU 各自报告 `proto_version`, 双方取 `min(major,minor)` 作 negotiated_version, 后续行为按协商版本
2. **major 不兼容**: 双方 major 必须相等; 不等则发 `GOODBYE(reason=VERSION_MISMATCH)` + 断连
3. **minor 向下兼容**: 高 minor 端自动降级, 不发对端不认识的可选消息
4. **patch 完全兼容**: 只能修 bug, 不改语义
5. **capability_flags (HELLO 携带 u32 bitmap)**: 声明可选 feature, **旧 bit 永不复用**, 删除 feature 只标 deprecated 不复用 ID. 1.0.0 起步分配:
   - bit 0: `CAP_CURSOR_BGRA` (硬件光标 BGRA payload)
   - bit 1: `CAP_LED_STATE` (LED 反向回传)
   - bit 2: `CAP_VDAGENT_RESIZE` (动态分辨率, vdagent virtio-serial 通道就绪)
   - bit 3-31: 保留, 顺序占用
6. **未知消息 type 容错**: **严格按 `payload_len` skip, 不报错不断连** — 这是向后兼容核心防线
7. **flags bit 容错**: 不识别的 bit ignore 不报错. 1.0.0 已分配:
   - bit 0: `HAS_FD` (本消息含 SCM_RIGHTS fd, host 必须 recvmsg)
   - bit 1: `URGENT` (优先级提示, 留给后续 cursor 加速)
   - bit 2-15: 保留
8. **payload tail extension**: 已有消息加字段**不 bump major**; payload 比版本基础长度长则尾部为扩展段, 旧端 skip 不读
9. **协议变更登记**: 每次改协议必须在 docs/QEMU_INTEGRATION.md 追加版本条目 (date + version + change summary), 永久保留历史; 不允许 in-place 改老条目

**像素 / shm / 流控**
- 像素: 固定 BGRA8 (Metal `.bgra8Unorm` 原生, 零拷贝零转换), guest 其他格式由 QEMU pixman 转
- shm 名: `/qemu-hvm-<uuid8>-<seq>` (≤31 字符 macOS 限制), 创建后立即 `shm_unlink`, fd 经 SCM_RIGHTS 传 host (进程 crash OS 自动清理, 不留垃圾)
- 流控: 不做窗口控制, sendmsg EAGAIN 时 drop 老 DAMAGE; SURFACE/CURSOR/LED 必送; QEMU `dpy_refresh` ~30Hz 天然限流

**1.0.0 基础消息类型 (16-bit ID 分段, 预留扩展空间)**
- 控制 `0x00xx`: HELLO(0x01) / SURFACE_NEW(0x02) / SURFACE_DAMAGE(0x03) / GOODBYE(0xFF)
- cursor `0x001x`: CURSOR_DEFINE(0x10) / CURSOR_POS(0x11)
- 反向回传 `0x002x`: LED_STATE(0x20)
- host→Q `0x008x`: RESIZE_REQUEST(0x80)
- **保留段** (后续版本占用): `0x01xx` 帧高级 / `0x02xx` 输入扩展 / `0x03xx` 音频 / `0xFFxx` 厂商私有

#### Patch 清单 (自写, 不复制 hell-vm)

- **patches/qemu/0002-ui-iosurface-display-backend.patch** (待写, ~500-700 行)
  - 新增 `ui/iosurface.m` + `include/ui/iosurface.h`
  - `qapi/ui.json` 加 `DisplayIOSurface` struct + `DisplayType.iosurface`
  - `ui/meson.build` + 顶层 `meson.build` 加 CONFIG_IOSURFACE (macOS only)
  - `ui/console.c` / `system/vl.c` display init 派发
  - DCL ops 钩: `dpy_gfx_switch` (分辨率变→新 shm) / `dpy_gfx_update` (DAMAGE) / `dpy_mouse_set` / `dpy_cursor_define`
  - listener pthread accept 一个 client, SIGPIPE ignore, vm shutdown munmap+close+shm_unlink 清理
- **patches/qemu/0003-virtio-gpu-ramfb-skip-when-bound.patch** (待写, ~30-50 行)
  - virtio-gpu 收 first scanout 后置 `driver_active` flag
  - ramfb display update 检查 flag 就 return early
  - 防 Win 装完 viogpudo 后 ramfb / virtio-gpu 双路同时刷导致闪烁
- **patches/qemu/0001-hvm-win11-lowram.patch** (**已有**, 不重写, 仅验证与 iosurface 通路正交)

#### 分阶段计划 (~2-3 周)

| Phase | 内容 | 估时 |
|---|---|---|
| 1 | 协议敲定 + 自写 patch A/B + 重编译 + `nc` 验证 socket 握手 | 5-7 天 |
| 2 | Swift HVMDisplay(QEMU): DisplayChannel + FramebufferRenderer (Metal) + FramebufferHostView + InputForwarder + NSKeyCodeToQCode | 3-4 天 |
| 3 | DetailContainerView 加 QEMU 嵌入分支 (退役 RemoteRunningContentView) + QemuArgsBuilder 改用 `-display iosurface` + BundleLayout 加 socket 路径常量 | 2 天 |
| 4 | Win11 兼容: 验证 lowram patch 不冲突 + 写 ramfb 让路 patch + virtio-gpu 自动 enable/disable (osType==.windows 时 off) | 1-2 天 |
| 5 | 端到端: Linux 装机 + Win11 装机 + 多 VM 切换 + 分辨率变更 + 光标 + CapsLock 同步 | 3-4 天 |

#### 决策已敲定 (2026-04-27)

1. ✅ **Swift 侧实现**: 参考 hell-vm 思路**自写**, 不直接复制 (DisplayChannel / FramebufferRenderer / FramebufferHostView / InputForwarder / NSKeyCodeToQCode 都自实现)
2. ✅ **协议头格式**: 8 字节 `{ type:u16, flags:u16, payload_len:u32 }`
3. ✅ **协议版本编码**: 单 u32 `(major<<16)|(minor<<8)|patch`, 从 1.0.0 起
4. ✅ **消息 ID 分配**: 接受分段方案 (0x00xx 控制 / 0x001x cursor / 0x002x 反向 / 0x008x host→Q)
5. ✅ **spice-vdagent 动态分辨率**: 第一版要做 — QEMU argv 加 `virtio-serial-pci` + vdagent chardev (`com.redhat.spice.0`); host 端通过 `RESIZE_REQUEST` → QEMU `dpy_set_ui_info` → guest EDID 变更; guest 装 vdagent 后自动响应 EDID 调分辨率
6. ✅ **CLAUDE.md 第三方依赖白名单更新**: 新增 spice-vdagent 条目说明 — Linux 用户 `apt/dnf install spice-vdagent` 自装; Windows 用包内 spice-guest-tools ISO; **host 端不打包 spice-vdagent 二进制**, 仅 QEMU argv 暴露 virtio-serial chardev 给 guest agent

#### 风险登记

- 自写 ui/iosurface.m 与上游 ui/console.c 升级耦合, 当前锁 QEMU v10.2.0
- macOS shm 名 31 字符限制 (vm-uuid8 + seq 受控)
- Metal `MTLBuffer(bytesNoCopy:)` 要求 page-aligned (mmap 天然满足)
- 多 VM 嵌入: 每 VM 独立 socket + shm, RunningTabsBar 切换走 view detach / re-attach (类比现有 HVMView reparent)
- 工作量大头是 Phase 1 自写 patch A 主体, 失败率最高的也是这一步

#### 进度记录 (各 Phase 完成时追加日期)

- 2026-04-27: 调研完成, 方案敲定为 framebuffer shm + Metal (非真 virgl), 协议草案 + 分阶段 + 决策点落 todo

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

### P-5 · 公共工具函数重构到 app/Sources/HVMUtils 模块
- **现状**: 散在各业务模块的工具函数 (断点续传 / 字节大小格式化 / 错误信息助手 / 路径 escape 等) 缺统一组织, 易出现复制粘贴
- **要做**: 新建 `app/Sources/HVMUtils` SwiftPM target 收纳跨模块复用 helper, 各业务模块依赖之替换内部重复实现
- **入选示例 (待逐个核实)**:
  - 断点续传 (HTTP resumable download)
  - 字节大小格式化 (KB / MB / GB human readable)
  - 错误信息格式化 (errno → 中文 message)
  - 路径 helper (escape / normalize / sanitize)
- **边界**: HVMCore 等基础模块不依赖 HVMUtils, 仅业务层用. 迁移时不改 API 行为, 只搬位置 + 收敛重复
- **触发来源**: 用户反馈 (2026-04-27)
- **工作量**: 看实际散点数量, 估 300-800 行 refactor

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
