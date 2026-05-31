# 无头模式 (Headless Mode) 现状与路线图

> **本文是路线图 / 规划文档,非纯现状描述**(与索引内其他文档定位不同)。
> 「现状」小节是已核实的当前实现,「路线图」小节是待办 TODO,落地后回写「现状」并删对应 TODO。
> 设计变更 / 开新阶段前按 [CLAUDE.md](../CLAUDE.md) 「开发流程约束」先出设计稿评审。

## 现状 (已核实)

VM **计算层面早已是无头的**,但 host 进程被 AppKit 绑死,跑不进「无图形会话」环境。

### 显示是「可选挂载」的客户端通路

- [QemuHostEntry.swift:156](../app/Sources/HVM/QemuHostEntry.swift) + `:206` — host 进程**无条件**分配 iosurface socket 并传入 argv builder
- [QemuArgsBuilder.swift:325](../app/Sources/HVMQemu/QemuArgsBuilder.swift) — `iosurfaceSocketPath != nil` 恒走 `-display iosurface`(server 模式:QEMU bind socket 等客户端连);`cocoa` 分支是死代码(仅手动构造 Inputs 调试时可达)

```
QEMU 恒用 -display iosurface (server 模式, QEMU bind socket 等客户端)
   ├─ GUI 启动:FramebufferHostView 连 socket 拉像素 → 有画面
   └─ CLI 启动:无人连 socket → framebuffer 堆 IOSurface 没人消费 → 本身就无窗口
```

`hvm-cli start` 起的 VM **不弹任何 QEMU 窗口**,QEMU 照常跑。

### host 进程的 AppKit 绑定(真正的缺口)

| 绑定点 | 代码位置 | 为何挡住真无头 |
|---|---|---|
| `NSApplication.run()` 常驻 | [QemuHostEntry.swift:470](../app/Sources/HVM/QemuHostEntry.swift) | AppKit 主循环需连 WindowServer (Aqua 会话) |
| `setActivationPolicy(.accessory)` | `:282` | 无 GUI 会话下 NSApplication 起不来 |
| status item 菜单栏图标 | `:290-291` | CLI 无头启动也冒出菜单栏图标 |
| `-display iosurface` 渲染 IOSurface | argv builder | IOSurface 分配依赖 WindowServer;纯算力 VM 白渲染浪费 |

**结论**:进程能后台 detach,但跑不进「没有图形会话的环境」(SSH 登录 / launchd boot daemon / CI runner / 无显示器无登录的 Mac mini)。这是无头模式通常真正想要的能力。

### 已有的无头基础设施(可复用)

- 进程 detach 模型:`hvm-cli start` → `HostLauncher.launch()` fork `HVM.app --host-mode-bundle`,父进程立即返回 pid
- IPC 控制(不依赖 AppKit):`SocketServer` 监听 `run/<id>.sock`,start/stop/kill/status/pause/resume 全通
- 密码 stdin pipe 透传(加密 VM,不经 argv / env)
- 孤儿回收:`SidecarOrphanReaper.reapByPidFile`
- console serial 已落 `console-*.log`(`QemuConsoleBridge`)
- guest 内执行:`hvm-cli exec` / `hvm-dbg exec`(qemu-guest-agent)
- `HVM_NO_TRAY=1`:VMHost 永不显菜单栏 tray(`TrayCoordinator` 硬覆盖);无图形会话时 NSStatusBar 不可用本就 fail-soft(VM 照跑)。真·纯无头(无 AppKit 绑定)仍待 P1。

---

## 路线图

```
现状 ── P0 ──────── P1 ──────────── P2 ──────────── P3 ──────────── P4
半无头   纯无头开关   解耦 AppKit       串口/console     launchd/SSH      远程显示
(已有)   -display     无 WindowServer   无头交互          开机自启         (可选)
         none         也能跑            attach console   守护进程
         ▲ 低风险      ▲ 核心改造        ▲ 体验补全        ▲ 部署能力       ▲ 先写设计稿
         半天          2-3 天            1-2 天           1-2 天          视需求
```

### P0 — 纯无头开关 `-display none` (低风险, 半天)

给「纯算力 VM,不需要画面」一条不渲染 framebuffer 的路径,省掉 IOSurface 分配。

- [ ] `QemuArgsBuilder.Inputs` 加 `headless: Bool`;`true` 时发 `-display none`,不分配 iosurface socket
- [ ] `config.yaml` 加 `headless` 字段(默认 `false` 保持现状;schema 走 `init(from:)` 缺省兜底,不升 schema 版本)
- [ ] `hvm-cli start --headless` 透传;GUI 暂不接(创建/启动时拍板,非热切换)
- [ ] **验收**:`hvm-cli start --headless <vm>` 后 argv 含 `-display none` 且无 iosurface socket 文件;`hvm-dbg exec` 仍能跑命令(guest 活着)
- 边界:`-display none` 后 GUI 无法事后挂画面(无 socket server),这是启动时拍板的模式

### P1 — 解耦 AppKit,无 WindowServer 也能跑 (核心, 2-3 天)

> **开工前先出设计稿**(大改 + 新架构,符合 CLAUDE.md 开发流程约束)。

让 host 进程在没有 Aqua 图形会话时也能启动 —— 整个路线图的关键卡点。

- [ ] 抽 `HostRunLoop` 抽象:有图形会话 → 现有 `NSApplication.run()` + status item;无图形会话 → 纯 `RunLoop.main.run()` / `dispatchMain()`,跳过 NSApplication / accessory policy / status item
- [ ] 会话检测:`CGSessionCopyCurrentDictionary` / 探测能否连 WindowServer,失败走无图形分支
- [ ] 无图形分支强制隐含 P0 的 `-display none`(无 WindowServer 无法分配 IOSurface)
- [ ] IPC server 复用(本就不依赖 AppKit),确认 start/stop/kill/status 全通
- [ ] **验收**:`ssh localhost 'hvm-cli start --headless <vm>'`(无 Aqua 会话)能起 VM,`status` / `stop` 正常 —— 最大能力跃迁

### P2 — 串口 / console 无头交互 (体验补全, 1-2 天)

无头跑起来后,得有办法不靠 framebuffer「看见」和「进入」guest。

- [ ] `hvm-cli console <vm>` / `hvm-dbg console attach` 把 serial socket 双向接到当前终端(类 `virsh console`)
- [ ] `hvm-cli shell` 交互式包装(复用 qemu-guest-agent exec 通路)
- [ ] **验收**:无头启动的 Linux VM,`hvm-cli console` 能看内核启动日志 + 登录拿 shell

### P3 — launchd 自启 / 开机守护 (部署能力, 1-2 天)

让无头 VM 像服务一样开机自动拉起。

- [ ] 生成 per-VM launchd plist(label namespace `com.hellmessage.hvm.*`),`hvm-cli enable <vm>` / `disable <vm>` 写/删 plist
- [ ] 复用孤儿回收 + launchd `KeepAlive`
- [ ] 加密 VM 无法无人值守自启(密码走 stdin pipe)→ P3 仅支持明文 VM,加密 VM 显式报错引导
- [ ] **验收**:`hvm-cli enable <vm>` 后重启 Mac(或 `launchctl kickstart`),明文 VM 自动起来

### P4 — 远程显示 (可选, 视需求)

> **必先写设计稿**(跨网络显示是新架构)。

无头 host 上偶尔想看画面时的远程通路。

- [ ] 选项 A:QEMU `-display vnc` / SPICE over TCP —— ⚠ 与 CLAUDE.md「严禁 TCP 监听」冲突,显示 socket 是否破例需先定决策 (Decision)
- [ ] 选项 B:iosurface framebuffer 经 HDP 转发到远端 `HVM.app`(本地无窗口,远程客户端连)
- [ ] 设计稿:选型对比 + 安全边界 + PR 拆解

---

## 切入点建议

| 诉求 | 路径 |
|---|---|
| Mac mini 无显示器跑 VM 集群 | P0 → **P1**(P1 是卡点,P0 是前置) |
| 只想省资源(无画面 VM 别渲染 framebuffer) | 单做 **P0** |
| 服务化 / 开机自启 | P0 → P1 → P3 |

## 未决事项 (Decisions)

- **D1**:`headless` 是 per-VM config 字段,还是 `start` 时的 runtime flag?当前默认 config 字段(持久化,重启保持)。决策时机:P0 开工
- **D2**:P4 远程显示走 TCP(违反现约束)还是 HDP 转发?决策时机:P4 设计稿
- **D3**:无图形会话检测失败时,是报错退出还是自动降级 `-display none`?当前倾向自动降级 + warn。决策时机:P1 设计稿
