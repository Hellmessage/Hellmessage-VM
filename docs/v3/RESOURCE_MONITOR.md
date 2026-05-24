# 资源监控 (详情页 inline sparkline)

> 状态: **设计稿** (2026-05-24 起稿)
>
> 父约束: [CLAUDE.md "开发流程约束"](../../CLAUDE.md), [HVM_DBG_GUI_PROTOCOL.md](HVM_DBG_GUI_PROTOCOL.md) (probe id 命名)
>
> 评审通过后回写 v1/MONITORING.md 与 CLAUDE.md "监控约束" 节.

## 目标

- **解决问题**: VM 卡时用户无法判断是 host 资源吃紧 / guest 自身满载 / qemu 进程异常. 现状只有"running / stopped" 两态, 没有任何运行时指标
- **交付**: 详情页 running 顶栏下方紧贴一条 ~60px 高 inline sparkline 卡片, 三条曲线 (CPU / 内存 / 磁盘 IO), 60s 滑窗, 1Hz 采样. stopped 时隐藏
- **范围内**:
  - QEMU 后端: host 进程级 (CPU% / RSS / disk read+write bytes/s) + guest 内 (`/proc/loadavg` / `/proc/meminfo` / `Get-Counter`) 双源
  - VZ 后端: 仅 host 进程级 (无 QGA 等价物)
  - 数据只在内存 (60s 环形 buffer), **不**落盘
- **范围外**:
  - 不做"性能 tab" (60s 已够诊断, 5min/1h 趋势用户用 macOS Activity Monitor)
  - 不做告警 / 阈值 / 通知
  - 不导出 csv / Prometheus / json
  - 不监控 host 整机 (用户自己看 Activity Monitor)
  - 不监控 guest 内进程列表 / top-N (`hvm-dbg exec` 已能跑 `ps aux`)
  - VZ 后端不接 guest 内 (装自家 agent 太重, 见 D3)

## 选型对比

### 选项 A: Host 进程级 only (两后端通用)

| 维度 | 评价 |
|---|---|
| 实现量 | 1-2 天: mach `proc_pid_rusage` + `task_info` 抓 vmhost 子进程 |
| 准确性 | hypervisor 视角. host CPU% 含 qemu emulation 开销, guest idle 时 host 仍可能 5-10% |
| 后端对称 | ✅ 两后端一致 |
| 用户能否诊断卡顿 | ❌ 看到 host CPU 100% 不知是 guest busy 还是 emulation 慢 |

### 选项 B: Host + QEMU QMP

| 维度 | 评价 |
|---|---|
| 实现量 | 2-3 天: A 之上加 QMP `query-blockstats` (磁盘块设备 IO) + `query-cpu-stats` |
| 准确性 | QMP 看到 vCPU 累计 ns + 每块设备 IO bytes, 比 host 视角准 |
| 后端对称 | ❌ VZ 拿不到 QMP, 仍只 host 视角 |
| 用户能否诊断卡顿 | 部分: 能区分 CPU vs IO 瓶颈, 但仍看不到 guest 内"系统 vs 用户"占比 |

### 选项 C: Host + Guest 内 (用户选定 ✅)

| 维度 | 评价 |
|---|---|
| 实现量 | 3-4 天: A 之上加 QGA `guest-exec` 跑 `cat /proc/loadavg` / `cat /proc/meminfo`, Win 跑 `Get-Counter` |
| 准确性 | 最高. guest loadavg / mem 是 guest 内核视角 |
| 后端对称 | ❌ VZ 没 QGA, 仍仅 host. **必须 UI 标注** "Host" 还是 "Host+Guest" |
| 用户能否诊断卡顿 | ✅ 能. host CPU 高 + guest loadavg 低 = emulation 慢 / IO 阻塞; 都高 = guest 业务满载 |
| guest 依赖 | Linux 必须装 qemu-guest-agent (我们已有 file push/pull, 已要求装); Win 同 (virtio-win 自带 qemu-ga.exe) |

**选定 C**. VZ 限制写进 UI 文案与 v1/MONITORING.md "能力边界" 节. 用户阅读 sparkline 时通过 tooltip 知道当前后端的语义.

### sparkline 渲染选型

| 选项 | 评价 |
|---|---|
| **SwiftUI Canvas 自绘** (✅ 选定) | 60 个点 × 3 曲线 × 1Hz, 60fps 重绘开销极低. 走 `HVMColor` token, 不引第三方 |
| Charts framework (macOS 14+) | 适合复杂图. 60s 滑窗 sparkline 没必要拖 Charts, API 调整频繁 |
| 第三方 Swift charting | 违反 CLAUDE.md "三方包白名单" |

## 实现要点

### 字段 / 协议

**采样数据结构** (内存, `app/Sources/HVMCore/Monitor/ResourceSample.swift`):

```swift
public struct ResourceSample: Sendable, Equatable {
    public let timestamp: Date

    // Host 进程级 (vmhost 子进程; QEMU 后端 = qemu-system-aarch64 子进程组聚合)
    public var hostCpuPercent: Double?      // 0.0 ~ 100.0 * vCPU 数 (macOS 惯例)
    public var hostResidentBytes: UInt64?   // RSS
    public var hostDiskReadBytes: UInt64?   // 累计, UI 端差分成 rate
    public var hostDiskWriteBytes: UInt64?

    // Guest 内 (QEMU only; VZ 全 nil)
    public var guestLoadAvg1m: Double?      // Linux /proc/loadavg, Win 折算 (CPU queue length)
    public var guestMemTotalBytes: UInt64?
    public var guestMemAvailableBytes: UInt64?
}

public actor ResourceSampler {
    public init(vmId: UUID, engine: Engine, pid: pid_t, qga: QgaSocket?)
    public func start()                     // 1Hz 定时
    public func stop()
    public var samples: [ResourceSample] { get }  // 最多 60 条
    public func subscribe(_ handler: @escaping ([ResourceSample]) -> Void)
}
```

**host 进程级采样**:

- CPU%: `proc_pid_rusage(pid, RUSAGE_INFO_V4, &info)` 取 `ri_user_time + ri_system_time` (ns), 与上次差分 / 间隔 → CPU%. macOS 惯例: 8 vCPU 满 = 800%
- RSS: 同上 `info.ri_resident_size`
- 磁盘 IO: `info.ri_diskio_bytesread / ri_diskio_byteswritten` (累计)
- 失败处理: pid 不存在 (子进程刚崩) → 返 nil, sparkline 该点断线, **不**抛 error

**guest 内采样 (QEMU only)**:

走现有 [`QgaExec.run`](../../app/Sources/HVMQemu/QgaExec.swift), guest OS 分流:

```swift
// Linux: 单次 cat 拿两文件
sh -c "cat /proc/loadavg; echo ---; cat /proc/meminfo | head -5"

// Windows (PowerShell, 通过 qemu-ga guest-exec):
powershell -NoProfile -Command "
  $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue
  $os  = Get-CimInstance Win32_OperatingSystem
  Write-Output \"LOAD=$cpu`nMEM_TOTAL=$($os.TotalVisibleMemorySize)`nMEM_FREE=$($os.FreePhysicalMemory)\"
"
```

- guest OS 类型从 `VMConfig.guestOS` 取, 启动期已知
- guest-exec 超时设 800ms (1Hz 节奏下留 200ms 余量), 超时 → 该点 guest 字段 nil
- Win PowerShell 启动慢 (100-300ms), `Get-Counter` 自己又要 1s 采样 → 实际 Win 侧采样**降到 0.2Hz** (5s 一次), sparkline 该点用线性插值
- guest-exec 失败 5 次 (5s) → 临时挂起 guest 采样, 30s 后重试; 期间 sparkline 灰显 "guest agent unreachable"

### UI 集成

**位置**: 详情页 running 顶栏 [`DetailTopBar`](../../app/Sources/HVM/UI/Content/DetailBars.swift:106) **下方**, 嵌一个新 `ResourceSparklineBar` View. stopped → 不挂载. probe id `detail.monitor.sparkline.{cpu,mem,io}`.

**布局** (~60px 高, 三列):

```
┌─────────────────────────────────────────────────────────────┐
│ CPU       ╱╲    │ MEM        ▁▂▃▅▆  │ IO        ▁  ▁▃  ▁  │
│ host 45%  ╱  ╲  │ 1.2G/2G     ───── │ R 4M/s W 0     ─── │
│ guest 32% (60s) │ guest 67%    (60s) │ ↑3M ↓1M    (60s)   │
└─────────────────────────────────────────────────────────────┘
```

- 每列宽自适应, 三等分; 高度固定 60px
- mono 字体只用于"代码值" (`45%` / `1.2G`), 标签 "CPU" / "host" 用 SF Pro (CLAUDE.md mono 边界)
- VZ 后端: guest 行换灰文 "guest agent 不可用 (VZ 后端)"
- 颜色: CPU 主色, MEM 主色弱化 60%, IO 中性灰; 走 `HVMColor` token, 不硬编码
- 鼠标悬停 sparkline → tooltip 显示该点时间 + 精确值
- 不可交互 (不点开放大). 想看完整 → `hvm-dbg exec ... cat /proc/stat`

### 数据流

```
ResourceSampler (actor, 1Hz Timer)
   │
   ├─ host: 同步 proc_pid_rusage  → 立即拿到
   │
   ├─ guest (QEMU only): QgaSocket.request guest-exec (async, 800ms timeout)
   │
   └─ 合成 ResourceSample → 推 [ResourceSample] sliding buffer (60 cap)
        │
        └─ AppModel.activeVMMonitor.publishedSamples (@Published)
              │
              └─ ResourceSparklineBar (SwiftUI Canvas) 重绘
```

**生命周期**: VM start → AppModel 起 `ResourceSampler` + observe; VM stop → tearDown 并清 samples. 切换 VM tab → 旧 sampler 继续跑 (后台仍维护 60s buffer, 切回来 sparkline 立即满); VM crash / kill → sampler 自动停 (pid 取不到 stat 5 次连续失败).

### 进程模型

`ResourceSampler` 跑在 **GUI 主进程** (HVMApp), **不**塞进 `--host-mode-bundle` 子进程. 原因:
- 子进程已专注 VM 生命周期管理, 不增加监控职责 (单一职责)
- GUI 进程从 VMHandle 拿 pid + 从现有 QgaSocket 拿 socket, 已具备所有数据
- hvm-cli `status` 命令暂**不**接监控数据 (CLI 用户用 `top -p <pid>` 自己看)

## 风险与待验证项

### P0 must-pass

- **R1**: `proc_pid_rusage` 在 sandboxed app (HVM 走 codesign + entitlement) 能否拿到子进程 stat? Apple 文档说 RUSAGE_INFO 不需要特殊权限, 但实测 sandbox 下偶发 EPERM. **必须真机验证** 8 vCPU VM 满载场景 CPU% 数值合理
- **R2**: QGA guest-exec 1Hz 持续跑会不会拖慢 file push/pull? 现有 QGA 客户端是单 socket 串行, 加监控后采样请求与文件请求会排队. 需在传大文件时验证 sparkline 不卡 + 文件传输不变慢
- **R3**: Windows guest 用 PowerShell + Get-Counter 启动 ~300ms, 在低配 VM (2 vCPU) 上每 5s 跑一次会不会显著占 guest CPU? 真机测 Win11 ARM 装好后看任务管理器里 powershell.exe CPU%

### P1 应该验证

- **R4**: VZ 后端 vmhost 子进程 CPU% 与 host Activity Monitor 显示的 `VMHost` 进程 CPU 数值是否一致 (差 ±5% 可接受)
- **R5**: 详情页快速切 VM (10 个 VM 来回切) sparkline 重绘有无卡顿
- **R6**: sampler 在 VM `pause` 状态下行为 (vCPU 不跑, host CPU% 应该归 0, guest QGA 仍能响应)

### 已知不解决

- macOS guest 内监控: macOS guest 必走 VZ, VZ 无 QGA, 不接 guest 内. 已在 D3 接受
- 单个进程 / 容器粒度: 用户要看 guest 内 nginx CPU% → 自己 `hvm-dbg exec ... top` (设计目的不是替代 guest 内监控工具)

## PR 拆解

| PR | 时间盒 | 范围 | 验收 |
|---|---|---|---|
| **PR-1** | 1 天 | `ResourceSample` 数据结构 + `HostProcessSampler` (proc_pid_rusage 封装, 仅 host 字段). 加 `hvm-dbg monitor-host <vm>` 子命令打印 1Hz 数据 5s 验证 | `make build` + 真机跑加密 / 明文 Win + Linux VM, `hvm-dbg monitor-host` 输出 CPU% / RSS / disk 数值合理 (与 `top -pid X` 一致 ±10%) |
| **PR-2** | 1 天 | `GuestSampler` (QGA guest-exec 封装) + `ResourceSampler` actor 合成. 扩 `hvm-dbg monitor <vm>` 打印双源 | 真机 Linux + Win QEMU VM 输出 guest loadavg / mem 正确; VZ macOS / Linux VM 输出 host-only + UI 标注 nil; guest-exec 失败 5 次自动挂起验证 |
| **PR-3** | 1 天 | `ResourceSparklineBar` SwiftUI Canvas 自绘 + 接 `AppModel.activeVMMonitor`. 详情页挂载 / VM 切换生命周期 | `hvm-dbg gui` 自动化截图: running 详情页有 sparkline 卡片, stopped 无; VZ VM guest 行显灰; 切 VM 卡片即时刷新 |
| **PR-4** | 0.5 天 | 文档回写 v1/MONITORING.md (新建) + CLAUDE.md "监控约束" + README.md 提一句 | 文档已落, 设计稿头改 `代码已合入` |

总计 **3.5 天**.

**每 PR 必须**: `make build` + `make install` + `hvm-dbg gui screenshot` 验证 + smoke 跑加密 VM (验证 sampler 不打破加密路径).

## 未决事项 (Decisions)

| ID | 决策项 | 默认 | 决策时机 |
|---|---|---|---|
| **D1** | sparkline 高度 60px 是否合适, 还是 40 / 80? | 60px (推荐) | PR-3 截图后看视觉, 可微调 |
| **D2** | guest-exec 失败后的 UI 文案: "guest agent 离线" vs "guest 内监控不可用"? | 后者 (更通俗) | PR-3 |
| **D3** | VZ 后端是否未来接自家 agent (走 virtio-serial 拉数据)? | **不接** — 装自家 agent 太重, 用户 fallback 到 Activity Monitor | 永久不接, 除非用户多次反馈强需求 |
| **D4** | sampler 内存占用上限: 60 条 × ~80 bytes = ~5KB, 10 个 VM 同跑 = 50KB. 是否需要"非活动 tab 暂停采样"? | **不暂停** (后台续跑 60s buffer, 切回来立即满) | PR-3 实测 10 VM 跑 1h 内存占用, 超过预期再加暂停 |
| **D5** | hvm-cli `status` 是否带最新一帧 sample? | **不带** (CLI 用户用 `top`) | 永久不接 |
| **D6** | Win Get-Counter 启动慢 → 0.2Hz 采样 + UI 插值, 还是干脆 Win 侧不采 guest? | 0.2Hz + 插值 (推荐) | PR-2 实测 Win11 ARM 上 PowerShell 启动稳定性, 若 >500ms 则降级"Win guest 不采" |
