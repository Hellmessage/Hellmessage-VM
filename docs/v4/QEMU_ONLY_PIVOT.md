# QEMU-only 转向 — 剥离 VZ + 统一显示通路

> 状态: **设计稿** 2026-05-30 — 待用户评审. 项目级战略转向 (跨 CLI / GUI / backend / config / 加密 / docs), 非单业务页.
>
> 关联: 本转向使 [NEW_GUI_FRAMEBUFFER.md](NEW_GUI_FRAMEBUFFER.md) 的 "VZ 画面推迟" 升级为 "VZ 彻底移除"; 显示通路 (截图 + 内嵌) 统一到 QEMU HDP IOSurface 单一来源.

---

## 背景 / 动机

- **VZ bridged networking entitlement (`com.apple.vm.networking`) 申请一直未批** → VZ 桥接网络始终拿不到, VZ 网络能力半残 (只 NAT)
- **QEMU 后端已满足全部目标场景**: Linux arm64 (双后端本就支持) + Windows arm64 (VZ 根本不支持, 一直靠 QEMU) + 整盘加密 (qemu-perfile, VZ-sparsebundle 一直未接入)
- **VZ 维护成本高**: 双后端分支 (backend / display / install / network / config / 加密 全要伺候两套) + VZ 离屏窗口 hack (截图拐杖) + macOS guest 特殊装机路径 (IPSW / VZMacOSInstaller) + 一堆 VZ 专属约束
- **结论**: 收敛到 **QEMU-only**, 砍掉 VZ 整条通路. macOS guest 随之下线 (VZ 是 macOS guest 唯一通路, QEMU 跑不了 macOS)

### 关键洞察 (显示通路简化)

VZ 的**离屏 NSWindow** (`HVMHostEntry` -20000,-20000) 纯粹是"VZVirtualMachineView 必须 attach window 才能建 Metal drawable"的拐杖 — **QEMU 根本不需要**. QEMU 画面是 IOSurface 共享内存 (HDP backend ship 出去), 跟 NSWindow / Window Server 无关, 永远在.

→ 剥 VZ 后**离屏截屏概念消失**, 显示模型变干净:

```
QEMU 子进程
   └─ framebuffer = IOSurface (HDP 共享内存, 永远在, 无需窗口)
         ├─ 截图     = 抓一帧 → PNG       (CLI/dbg, 无需 GUI/渲染/窗口)
         └─ GUI 内嵌  = 同一块 IOSurface 连续刷 (fanout)
   截图 + 内嵌 同源, 一条 HDP 通路
```

---

## 目标 / 范围

三阶段 (顺序强相关: P1 先简化, P2/P3 在干净基座上做):

| 阶段 | 内容 | 价值 |
|---|---|---|
| **P1 剥离 VZ** | 砍 VZ backend / display / install(macOS) / network bridged-vz / config(engine=vz,guestOS=macOS,vz-sparsebundle) / CLI / GUI / 离屏窗口 / CLAUDE.md VZ 约束 | 单后端, 代码量大降, 维护成本砍半 |
| **P2 统一显示通路** | 截图 + 内嵌都走 QEMU HDP IOSurface 单一来源; 删 VZ 离屏截屏路径; 截图机制重设计 (见选型) | 一条通路, 截图 = 抓帧 |
| **P3 内嵌优化** | NEW_GUI_FRAMEBUFFER F 系列在 QEMU-only 基座上收尾 + 优化 (无 VZ 分支) | 详情页画面嵌入干净落地 |

### 不做 (out of scope)

- **保留 VZ 代码 dormant** → 不做 (彻底删; 若未来 entitlement 下来 + 要 macOS guest, 从 git 历史捡, 不留死代码拖维护)
- **QEMU 跑 macOS** → 做不到 (QEMU 无 Apple Silicon macOS 虚拟化授权路径), macOS guest 直接下线
- **VZ 画面 IOSurface 回读桥** → 已弃 (NEW_GUI_FRAMEBUFFER.md 结论), VZ 整个没了更不用谈
- **数据迁移工具** (VZ VM → QEMU VM 转换) → 不做; 现存 VZ/macOS VM 启动期给清晰错误, 用户自行重建 (见风险)

---

## 选型对比

### 选型 1: VZ 移除策略 — 一次删光 vs 分两步 (先收口禁用, 后删码)

| 方案 | 做法 | 优 | 劣 |
|---|---|---|---|
| **A. 分两步 (P1a 收口 → P1b 删码)** ✅ 推荐 | P1a: 创建只出 QEMU (CLI/GUI 拒 vz + macOS) + 启动遇 vz config 报"VZ 已下线" + 默认全 QEMU; **不删码**. P1b: 确认实际 QEMU-only 跑顺后, 大扫除删 HVMDisplay / HVMBackend VZ / HVMInstall Mac* / 离屏窗口 / config 简化 | P1a 低风险快速达成"事实 QEMU-only"; 删码 (P1b) 跟新功能解耦, 可单独验证; 出问题 P1a 可回退 | 两步, P1a→P1b 间有过渡期残留 VZ 死码 |
| B. 一次删光 | 单 PR 删所有 VZ + 改 config + 改 CLI/GUI | 一步到位无残留 | 巨型 PR (40+ 文件 4 模块), 编译断点多, 难 review, 出错难定位 |

**选 A**: VZ 横跨 HVMBackend/HVMDisplay/HVMInstall/HVMNet + CLI/GUI/config/加密, 一次删光是巨型 PR. 分两步: 先让"创建/启动事实上只有 QEMU"(P1a, 行为收口), 再分模块删码 (P1b, 多个小 PR 各自编译过 + smoke).

### 选型 2: macOS guest — 一并下线 vs 保留壳

| 方案 | 优 | 劣 |
|---|---|---|
| **A. 一并下线** ✅ 推荐 | VZ 没了 macOS guest 本就无通路; 砍 GuestOSType.macOS + MacOSSpec + IPSW/install 整条; 大幅简化 | 老 macOS VM 不能开 (用户需理解) |
| B. 保留 GuestOSType.macOS 壳 | 枚举不破坏老 config 解码 | 留个永远报错的 case, 误导; install/IPSW 代码还得留 |

**选 A**: macOS guest 整条下线. `GuestOSType` 收敛到 `linux` / `windows`. 老 config 带 `macOS` → 解码兜底报"已下线" (见风险 R1).

### 选型 3: 截图机制 (P2) — 保 IPC 子进程抓帧 vs hvm-dbg 直连 HDP 抓帧

| 方案 | 做法 | 优 | 劣 |
|---|---|---|---|
| **A. 保 IPC `dbgScreenshot`, 子进程抓 IOSurface** ✅ 推荐 | 现机制不变, 只删 VZ 离屏抓帧分支; QEMU 子进程持 IOSurface, 收到 IPC 抓最新帧编码 PNG 回 | 改动最小 (VZ 删了它本就只剩 QEMU 路); hvm-dbg 不需自己连 HDP socket + 处理 SCM_RIGHTS fd; 子进程是 IOSurface 天然持有者 | IPC round-trip (但截图非高频, 无所谓) |
| B. hvm-dbg 直连 HDP socket 一次性抓帧 | hvm-dbg 自己 connect HDP, 抓一个 SURFACE_NEW, mmap, 编码 PNG | 不经子进程; 跟 GUI fanout 同款消费者 | hvm-dbg 要引 DisplayChannel + HVMScmRecv + mmap 逻辑; 多一个 HDP 消费者跟 GUI fanout 抢/并存复杂; 子进程已有 IOSurface 何必绕 |

**选 A**: 剥 VZ 后截图本就只剩 QEMU 一条路 (子进程抓 IOSurface 编码). 保现有 IPC 机制, 只删 VZ 离屏分支即可 — 这就是"截图重设计"的实质 (从双路 collapse 成单路, 不是另起炉灶). hvm-dbg 不必自己连 HDP.

---

## 实现要点 (各阶段触点)

### P1a — 行为收口 (不删码)

- **CLI create**: `--engine vz` 拒 (报 "VZ 已下线"); `--os macOS` / `--ipsw` 拒; 默认 engine 恒 qemu
- **GUI create wizard** (老 + 新): 引擎选择去掉 VZ; OS 去掉 macOS
- **启动/枚举**: `HostLauncher.launch` / `VMControl.start` 遇 `config.engine == .vz` → 抛 "VZ 已下线, 请重建为 QEMU VM"; `VMCatalog.list` 对 vz VM 标记不可启动 (仍列出让用户看到 + 删)
- **install / ipsw 命令**: 标记 deprecated / 报下线

### P1b — 删码 (分模块小 PR)

| PR | 删什么 |
|---|---|
| P1b-1 | **HVMDisplay 整模块** (HVMView / VZViewRepresentable / VZ display) + `HVMHostEntry` 离屏 window + VZ 分派; HostEntry 只留 QemuHostEntry |
| P1b-2 | **HVMBackend VZ** (ConfigBuilder VZ / VMHandle VZ / MacPlatform / VZErrorMapping / RunState VZ 分支) |
| P1b-3 | **HVMInstall Mac*** (MacInstaller / RestoreImageHandle / MacAuxiliaryFactory / IPSWFetcher) + CLI install/ipsw 命令 + GUI IPSW UI |
| P1b-4 | **config 简化**: `Engine` 收敛 (删 .vz 或保留枚举但创建只 qemu — 见 D3) / `GuestOSType` 删 macOS / `EncryptionScheme` 删 vzSparsebundle / 删 MacOSSpec / DiskSpec VZ raw 分支 (QEMU 恒 qcow2) |
| P1b-5 | **HVMNet** VZ bridged attachment (NICFactory VZ) + 老 GUI VZ 相关 dialog/session (VMSession / DetailContainerView VZ 分支 / sessions[]) |
| P1b-6 | **CLAUDE.md / docs 清理**: 删 "VZ 能力边界" / "支持的 Guest OS" macOS / 磁盘 VZ raw / VZ 网络 / 签名 VZ entitlement 等 VZ 约束; docs/v1 VZ_BACKEND.md 归档 |

### P2 — 显示通路统一

- 删 VZ 离屏截屏 (随 P1b-1 离屏窗口删除自然消失)
- `dbgScreenshot` handler 只留 QEMU IOSurface 抓帧路 (选型 3-A)
- 文档化: 截图 = 抓 HDP IOSurface 一帧; 内嵌 = fanout 连续帧; 同源

### P3 — 内嵌优化

- NEW_GUI_FRAMEBUFFER F2-F4 在 QEMU-only 基座收尾: 删 DetailOverviewView VZ 占位分支 (无 VZ); 画面/配置 TAB; 输入接线; z-order 遮罩
- 优化项 (待用户明确, 见 D5): 性能 / 交互 / letterbox / 连接中 loading

---

## 风险与待验证

| 级别 | 项 | 缓解 |
|---|---|---|
| **R1** | 现存 VZ / macOS VM 启动失败 / config 解码崩 | P1a 启动期清晰报错 (不崩); config `init(from:)` 对 engine=vz / guestOS=macOS 兜底解码成功但标"不可用" (不抛). **删除前 audit**: 扫 `~/Library/Application Support/HVM/VMs/*` 列出 engine=vz / guestOS=macOS 的 VM, 报告用户 |
| **R2** | 加密 vz-sparsebundle VM (若有) | 实际未接入过 (一直 qemu-perfile), 现存应为 0; routing JSON scheme=vz-sparsebundle 检测到报下线 |
| **R3** | config schema 改动断老 yaml 兼容 | `Engine` / `GuestOSType` / `EncryptionScheme` 删 case 要保 Codable 兜底 (老 yaml 带 vz/macOS 解码不崩, 走"不可用"). schema 版本是否 +1 → D4 |
| **R4** | 删码编译断点 (模块依赖) | P1b 分模块小 PR, 每 PR `make build` 过 + smoke; 删一个模块前先 grep 它的被依赖点 |
| **R5** | 双后端测试基建 (hvm-dbg / install) 含 VZ 假设 | 随 P1b-3 清理; hvm-dbg screenshot/exec 等 QEMU 通路保留 |

**P0 must-pass**: P1a 后 `make build` + 创建只出 QEMU + 老 QEMU VM 照常启停/截图/内嵌; vz config VM 报错不崩. P1b 各 PR 编译过 + QEMU e2e 回归 (启动→截图→内嵌→停). audit 脚本列现存 vz/macOS VM.

---

## PR 拆解

| PR | 阶段 | 标题 | 验收 |
|---|---|---|---|
| **P1a** | 收口 | feat(core): VZ/macOS 创建+启动收口下线 (CLI/GUI 拒 vz/macOS + 启动报错 + audit 脚本) | 创建只出 QEMU; vz VM 启动清晰报错不崩; audit 列现存 vz/macOS VM |
| **P1b-1** | 删码 | refactor(display): 删 HVMDisplay 模块 + HVMHostEntry 离屏 window + VZ 分派 | `make build`; QEMU 启动/截图/内嵌回归 |
| **P1b-2** | 删码 | refactor(backend): 删 HVMBackend VZ (ConfigBuilder/VMHandle/MacPlatform/VZError) | build + QEMU 启停回归 |
| **P1b-3** | 删码 | refactor(install): 删 HVMInstall Mac* + CLI install/ipsw + GUI IPSW UI | build + create/start QEMU 回归 |
| **P1b-4** | 删码 | refactor(config): Engine/GuestOSType/EncryptionScheme 收敛 + 删 MacOSSpec + DiskSpec qcow2-only | build + 老 QEMU yaml 解码 + 加密 VM 回归 |
| **P1b-5** | 删码 | refactor(net,app): 删 HVMNet VZ bridged + 老 GUI VZ session/dialog | build + QEMU 网络/老 GUI 回归 |
| **P1b-6** | 删码 | docs(claude): 清 CLAUDE.md VZ 约束 + docs VZ 归档 | 文档一致 |
| **P2** | 显示 | refactor(dbg): 截图 collapse 成 QEMU IOSurface 单路 + 文档化 | hvm-dbg screenshot QEMU 正常; 无 VZ 残留 |
| **P3-*** | 内嵌 | (NEW_GUI_FRAMEBUFFER F2-F4 QEMU-only 收尾 + 优化) | 详见 FRAMEBUFFER 子稿 |

> **规模**: P1 是大扫除 (8 PR), P2 小, P3 复用 FRAMEBUFFER. 分阶段每 PR 独立编译 + smoke gate.

**合入后回写**: `CLAUDE.md` (删 VZ 约束 / 改"仅 QEMU 单后端"基调 / supported guest = linux+windows) + `docs/v1` (VZ_BACKEND.md 归档, ARCHITECTURE/STORAGE/NETWORK 去 VZ) + 设计稿状态 + README + TODO + FRAMEBUFFER 子稿 (VZ 占位删除).

---

## 未决事项 (Decisions)

| ID | 决策 | 当前默认 | 决策时机 |
|---|---|---|---|
| **D1** | VZ 移除策略 | 分两步 P1a 收口 → P1b 删码 (选型 1-A) | 评审 |
| **D2** | macOS guest | 一并下线 (选型 2-A) | 评审 |
| **D3** | `Engine` 枚举: 删 .vz case vs 保留枚举但只用 .qemu | **保留枚举留 .vz case 但创建/启动只 qemu** (老 yaml 解码不崩 + 改动小); 还是彻底删 enum 退化成无字段? | 评审 / P1b-4 |
| **D4** | config schema 版本是否 +1 | 倾向**不升版本** (删 case 走 Codable 兜底, 不算结构变更); 若 D3 删字段则需迁移 hook | P1b-4 |
| **D5** | P3 内嵌"优化"具体指什么 | **待用户明确**: 性能 / 交互 / letterbox / 连接 loading / 嵌入方式? | 评审 |
| **D6** | 截图机制 | 保 IPC 子进程抓 IOSurface (选型 3-A) | 评审 |
| **D7** | 现存 vz/macOS VM 处理 | audit 列出 + 启动报错引导重建; 不做自动转换 | 评审 |

---

**评审请确认**: D1 (分两步删) + D2 (macOS 一并下线) + D3 (Engine 枚举留 case vs 删) + D5 (内嵌优化具体指什么, 这个我还需要你说清楚) + D6 (截图保 IPC 单路). 确认后从 **P1a 收口** 起 (低风险, 快速达成事实 QEMU-only), 再分模块 P1b 删码.

**特别需要你回答的**: **D5 — "虚拟机界面内嵌功能的优化" 具体指什么?** (性能卡顿 / 交互不顺 / 画面比例 / 连接慢 / 还是嵌入架构本身想换?) 这块设计稿留白, 等你说清楚再补 P3 细节.
