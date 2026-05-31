# TRAY_OWNERSHIP_DESIGN.md — 单一 tray 归属与接管设计稿

> 状态: **已落地** (2026-05-31, 方案 A)。实现: `HVMCore/ProcessFileLock.swift` + `HVMCore/Paths.swift` (两 lock 路径) + `HVM/TrayCoordinator.swift` (选主+聚合菜单+DNC) + `QemuHostEntry` 接入 (删旧 per-VM status item + `QemuStatusMenuController`) + `NewGUIApp` (持 gui-owner.lock + 单例化 + gui.up/down 广播 + "停止所有并退出")。时序 §4.4 五条 + 崩溃补位经 `lsof` 锁持有者 e2e 验证通过。决策见 §7。
>
> **追加实现点 (评审外, 实测发现)**: VMHost 也是 HVM.app 的实例 → 普通 `open HVM.app` 被 LaunchServices 当"已运行"不启 GUI。故 "打开主界面" 走 `NSWorkspace.OpenConfiguration.createsNewApplicationInstance=true` 强制新实例; GUI 启动抢 `gui-owner.lock` 失败即判定"已有 GUI", 广播 `gui.showWindow` 让在世 GUI 前置窗口后自退 (**GUI 单例化**)。

## 1. 目标 + 范围

让 HVM 在任意时刻**最多只有一个菜单栏 tray**, 由"当前的管理者"持有, 并在 GUI 与后台之间平滑接管:

- **CLI 启动的 VM**: 不再每个 VMHost 各显一个 tray; 多个 VM 共用**一个聚合 tray**, 列出全部运行中 VM + 各自停止/强停。
- **主界面启动后**: 接管 tray (CLI VM 的 tray 自动消失, 由主 GUI 统一管理)。
- **主界面退出后 (仍有 VM 在跑)**: 回退到后台 tray 模式 (单个聚合 tray 重新出现), 不丢失对运行中 VM 的控制。
- **全程恒一个 tray**: GUI 在 → GUI 的 tray; GUI 不在但有 VM 跑 → 单个后台 tray; 无 VM 且无 GUI → 无 tray。

### 不做 (本期越界)

- 真·headless (无窗口服务器 / SSH) 下的 tray —— NSStatusBar 需要登录图形会话, 无会话时 fail-soft 不显 tray (VM 照跑), 留 `HEADLESS.md`。
- tray 里嵌 VM 画面 —— 画面窗口仍由 GUI 开 (现状不变)。
- 通知中心 / Dock badge 等额外 UI。

## 2. 现状 (问题定性)

调研结论 (`NewGUIApp.swift` / `QemuHostEntry.swift` / `HostLauncher.swift`):

- **每个 VMHost (`--host-mode-bundle`) 都装自己的 NSStatusItem** ("HVM · \<name\> (qemu)" + Stop/Kill/Quit), 因为
  `HostLauncher.launch` **从不传 `--gui-embedded`** → `embeddedInGUI` 恒 false → "GUI 派生跳过 status item" 是死代码。
- 主 GUI 另有一个聚合 tray ("显示主窗口" / "退出 HVM"), **不列 VM**。
- 结果: GUI + N 个 VM = **N+1 个 tray**。VMHost 是 `.accessory` NSApplication (有 runloop, 能持 NSStatusItem)。
- 进程间发现只有 `BundleLock.isBusy/inspect` (flock) + per-VM IPC socket; **没有 "GUI 在不在" 的探测**, 也没有 tray 归属协调。
- GUI "退出" 真终止进程, VMHost 独立存活 (tray 留着); 关窗口则降 `.accessory` 留 tray。

## 3. 选型对比 (D1 — 谁在"无 GUI 时"持有那个聚合 tray)

三方都能做到"恒一个 tray + GUI 优先", 区别在**无 GUI 时谁渲染聚合 tray**:

| | A — VMHost 选主 (推荐) | B — 独立 tray-agent 进程 | C — GUI 单例常驻 (window/tray 两态) |
|---|---|---|---|
| 无 GUI 时 tray 由谁渲染 | 选主出的某个 VMHost | 一个专用 agent 进程 | 始终是 GUI 进程 (降 `.accessory`) |
| 新增进程 / 模式 | 无 (复用 VMHost 的 runloop) | 新 `--tray-agent` 模式 | 无 (复用 GUI) |
| CLI↔GUI 耦合 | 无 (CLI VM 自给自足出 tray) | 中 (谁来 spawn agent) | 高 (CLI 启 VM 须确保拉起 GUI 单例) |
| 聚合菜单代码 | VMHost 侧新写 (轻量 NSMenu) | agent 侧新写 | GUI 复用 (sidebar 逻辑已在) |
| "GUI 退出→回退" 语义 | GUI 真退 → VMHost 接 tray | GUI 退 → 拉起/复活 agent | GUI 有 VM 时"退出"=降 tray, 不真退 |
| headless 纯后台友好度 | 高 (无需 GUI 进程) | 高 | 低 (总有个 GUI 进程) |
| 崩溃恢复 | flock 自动释放 + 轮询重选, 强健 | agent 崩溃需重拉 | GUI 崩溃需 VMHost 重拉, 退化成 A 的复杂度 |
| 复杂度集中点 | 选主 + 重选 (轮询解决) | agent 生命周期 (spawn/teardown) | GUI "退出" 语义 + CLI 拉起 GUI |

**推荐 A (VMHost 选主聚合 tray)**:
- CLI 用户不被强拉一个完整 GUI 进程 (符合本项目对零额外依赖 / headless 友好的取向)。
- 无新进程 / 新模式, 复用 VMHost 已有的 `.accessory` NSApplication runloop。
- flock 选主天然抗崩溃 (持有者进程死 → 锁自动释放 → 存活者轮询补位)。
- GUI 优先靠"GUI 在时 VMHost 不显 tray"即可, 接管/回退都落到一个轮询循环里。

C 是强备选 (语义上最贴合"交给主界面接管 / 回退 tray 模式"), 但把 CLI 跟 GUI 进程强绑, 且 headless 不友好; 若你更想要"永远只有 GUI 这一个管理者", 选 C。

## 4. 推荐方案 A 的机制

### 4.1 协调原语: 两把 flock + 轮询 (1–2s)

`~/Library/Application Support/HVM/run/` 下:

- **`gui-owner.lock`** — GUI 进程启动即 `flock(LOCK_EX)` 持有到退出 (崩溃自动释放)。"GUI 在" ⟺ 此锁被占。
- **`tray-leader.lock`** — 当前 tray leader VMHost 持有。

每个 VMHost 跑一个轻量 `TrayCoordinator` 定时器 (1–2s), 复用 `BundleLock.isBusy` 同款非阻塞探测:

```
每 tick:
  guiPresent = isLocked(gui-owner.lock)          // LOCK_EX|LOCK_NB 探测后立即释放
  if guiPresent:
      释放 tray-leader.lock (若持有); 隐藏自己的 tray
  else:
      if tryAcquire(tray-leader.lock):           // 已持有则维持
          我是 leader → 扫 VMCatalog 运行中 VM, 重建聚合 NSMenu, 显示 tray
      else:
          隐藏自己的 tray (别人是 leader)
```

- 进程崩溃: flock 随进程死自动释放 → 存活 VMHost 下一 tick (≤2s) 补位。
- 可选优化: `DistributedNotificationCenter` 发 `gui.up/gui.down/leader.released` 即时唤醒, 把接管延迟从"≤2s"降到"即时"; 轮询作兜底 (D2)。

### 4.2 GUI 侧

- 启动: 取 `gui-owner.lock` 持有到退出; 现有 GUI tray 照常。
- "退出 HVM" (userRequestedQuit): **默认不停 VM** (符合"回退 tray"诉求) → 进程终止 → `gui-owner.lock` 释放 → VMHost 接管 tray。
  额外加一项 "停止所有 VM 并退出" (D3)。
- 关窗口降 `.accessory`: 仍持 `gui-owner.lock` (GUI 还在), VMHost 不显 tray —— 此时唯一 tray 还是 GUI 的。

### 4.3 VMHost 侧

- 删除死的 `--gui-embedded` 静态判定, 改由 `TrayCoordinator` 动态决定显隐 (保留 `HVM_NO_TRAY` env 作"永不显 tray"硬覆盖, 给 headless / CI)。
- leader 的聚合 NSMenu (扫 `VMCatalog`, 运行中过滤):
  - 头部 "HVM — N 台运行中"
  - 每台: `name` → Stop (ACPI) / Kill (Force) (经该 VM 的 IPC socket, `VMControl.stop/kill` 已支持跨进程)
  - "打开 HVM 主界面" → `open <HVM.app>` (拉起 GUI; GUI 取 gui-owner.lock → leader 下 tick 让位)
  - "停止所有并退出" (可选)

### 4.4 接管时序 (验收即按这几条走)

1. **CLI 启 3 VM (无 GUI)**: 3 个 VMHost 起, 仅 1 个抢到 `tray-leader.lock` 显**一个**聚合 tray 列 3 台; 另 2 个不显。
2. **GUI 启动**: 取 `gui-owner.lock` → leader VMHost 下 tick 探到 guiPresent → 撤 tray + 放 leader 锁。屏上只剩 GUI tray。
3. **GUI 退出 (VM 仍跑)**: `gui-owner.lock` 释放 → 某 VMHost 下 tick 抢 leader → 重新显聚合 tray。
4. **leader VMHost 的 VM 停了 (进程退)**: leader 锁自动释放 → 存活 VMHost 补位继续显 tray。
5. **最后一台 VM 停 + 无 GUI**: 无人持 leader 锁 → 无 tray (符合预期)。

## 5. 风险与待验证项

- **P0-1 恒一个 tray, 无重复无丢失**: 接管窗口期 (轮询间隔内) 可能瞬间 0 或 2 个 tray。用 flock 单一持有者 + "guiPresent 时主动撤" 收敛; DNC 即时唤醒可消除可见闪烁。必须实测 5 条时序无双 tray / 无长时间无 tray。
- **P0-2 崩溃恢复**: `kill -9` leader VMHost / GUI 后, 存活者必须 ≤2s 补位; flock 随进程死释放是关键 (实测 kill -9 后锁确实释放)。
- **P0-3 跨进程停 VM**: leader VMHost 通过别的 VM 的 IPC socket 发 stop/kill 必须生效 (验证 `VMControl.stop/kill` 对非自身 bundle 可用)。
- **P0-4 .accessory 显 NSStatusItem**: CLI 直接 `open`/Process 起的 `.accessory` VMHost 能否稳定出 status item (登录图形会话下应可; 无会话 fail-soft)。
- **P0-5 不误杀 VM**: GUI 退出 / leader 切换绝不能停任何 VM (除非用户显式"停止所有并退出")。
- **待验证 e2e**: `hvm-cli start` 3 台 throwaway VM → 数 tray (应 1) → `open HVM.app` → 数 tray (应 1, 且是 GUI 的) → 退出 GUI → 数 tray (应 1, VMHost 的) → 停所有 → 数 tray (应 0)。tray 渲染无法走 hvm-dbg gui (它是 NSMenu 不是 probe 控件), 用 screenshot + 进程/锁状态 (`lsof` flock / `pgrep`) 间接验证, 并显式标"tray 菜单点击未自动化测"。

## 6. PR 拆解

| PR | 内容 | 时间盒 | 验收 |
|---|---|---|---|
| PR-A | `TrayCoordinator` (两 flock + 轮询) + VMHost 接入 (删死 `--gui-embedded`, 加 `HVM_NO_TRAY`) | ≤1.5天 | CLI 启多 VM 只出 1 个聚合 tray; 单 VM 行为不回归 |
| PR-B | GUI 取/放 `gui-owner.lock` + 接管/回退 + "退出不停 VM" 语义 + 可选"停止所有并退出" | ≤1天 | 时序 §4.4 全过 |
| PR-C | 聚合 NSMenu (列 VM + per-VM stop/kill + 打开主界面) + 可选 DNC 即时唤醒 | ≤1.5天 | 菜单可停/强停任意 VM; 接管无可见闪烁 |
| PR-D | 回写 `CLAUDE.md` (新 tray 归属约束) + `ARCHITECTURE.md` / `HEADLESS.md` | — | 文档与实现一致 |

## 7. 未决事项 (Decisions)

| # | 议题 | 决策 (2026-05-31 敲定) |
|---|---|---|
| D1 | 无 GUI 时聚合 tray 由谁渲染 | **A — VMHost 选主** |
| D2 | 协调原语 | **flock 轮询 (1–2s) + DNC 即时唤醒兜底** |
| D3 | GUI "退出" 对运行中 VM | **不停 VM (回退 tray)**, 菜单另加 "停止所有 VM 并退出" 项 |
| D4 | 聚合 tray 菜单丰富度 | **列 VM + per-VM Stop/Kill + 打开主界面**; 不在 tray 开画面窗口 |
| D5 | GUI 自己的 tray 是否也列 VM | **保持简洁 (显窗口/退出)**, VM 管理走主窗口 |
| D6 | headless 无图形会话 | **fail-soft 不显 tray, VM 照跑** (本期不专门做) |
