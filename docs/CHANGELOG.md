# 历史 TODO 归档

本文是历史 `docs/v2/` 全项目深审 (2026-05-03) 产出的 45 项 TODO 清单的归档. 当时 v2 设计是"基于现状的下一步行动", 大多已在 2026-05 推进期间完成. 留底作 commit 索引 + 决策溯源, 不再修订内容.

> **现状描述请走 [v1/](v1/)**, 新设计提案走 [v3/](v3/).

## 完成度总览

| 优先级 | 总数 | 已完成 | 重新评估"不动" | 未完成 |
|---|---|---|---|---|
| **P0** (立即修, 影响功能正确性 / 安全) | 6 | 6 | 0 | 0 |
| **P1** (本周做, 可观测性 / UI 合规 / Makefile 增量) | 11 | 11 | 0 | 0 |
| **P2** (持续改进 / 技术债) | 21 | 17 | 4 | 0 |
| **D-** (CLAUDE.md / README 漂移) | 6 | 4 | 0 | 2 (D1/D2 部分完成) |
| **V/L/P-** (v1 todo 悬挂项) | 7 | 4 | 0 | 3 (V-1 / L-2 / P-3) |
| **总计** | **51** | **42** | **4** | **5** |

剩余未完成项已挪 [v1/ROADMAP.md](v1/ROADMAP.md) "残余项指引"。

## P0 — 立即修 (全部完成)

| # | 内容 | commit |
|---|---|---|
| #1 | `bundle.sh` dylib/libexec 签名 `\|\| true` 让 AMFI 拒签 | 29386eb |
| #2 | `install-vmnet-daemons.sh` 白名单 reject 后 `continue` 仍 exit 0 | dffd332 |
| #3 | swtpm sidecar 进程清理时序错可能写坏 NVRAM | 35a3954 |
| #4 | App 退出时 graceful shutdown 不等 forceStop, 留孤儿 QEMU/swtpm | 35a3954 |
| #5 | `BundleLock.release()` 非线程安全, double-close 风险 | dffd332 |
| #6 | `qemu-build.sh` `mktemp` 没 trap, 异常退出泄露 tmp | dffd332 |

## P1 — 本周做 (全部完成)

| # | 内容 | commit |
|---|---|---|
| #7 | UI 业务侧硬编码 `.font(.system(size:))` ≈ 35 处 | 6ebe53d |
| #8 | UI 业务侧硬编码 RGB / 系统色 8 处 | 6ebe53d |
| #9 | UI 业务侧硬编码 padding 数字 ≈ 6 处 | 6ebe53d |
| #10 | hvm-cli / hvm-dbg `OutputFormat.bail` 完全重复 | 08a5190 |
| #11 | `DetailBars.swift` 卡片样式重复 5+ 处 | 08a5190 |
| #12 | `BundleIO` schema v1→v2 断兼容路径无测 | c4b6e19 |
| #13 | QEMU HDP 解析层无 malformed input 测试 | c4b6e19 |
| #14 | 多处 `try? FileManager.removeItem` 静默吞错 | ac8c7c7 |
| #15 | QMP 连接 / 截图错误日志只输 `\(error)` 无法定位 | ac8c7c7 |
| #16 | Makefile 无增量, 每次 `make build` 重签 ~30 个 dylib | 9fd4291 + 4a36ff0 |
| #17 | `install-vmnet-daemons.sh` 拼 plist 不转义 XML | 4a36ff0 |

## P2 — 持续改进 (17 完成 / 4 重新评估"不动")

### A. 错误处理 / 可观测性

- ✅ #18 OCREngine.recognize 失败被降级为 `("boot-logo", 0.5)` (ddbfd38)
- ⚪ #29 `LogSink` 初始化不验证 logsDir 可写 — 重新评估: 已防御 (write 路径 `guard let fh = fileHandle else { return }`), 不动
- ✅ #30 `HVMApp.gracefulShutdownAll` 内 `try? requestStop()` 失败无日志 (35a3954)
- ✅ #31 `ErrorDialog` 只靠注释禁止 `NSAlert`, 无强制 (ddbfd38, verify-build.sh grep 守卫)

### B. 代码精简 / 死代码

- ✅ #19 `DbgOps.guestFramebufferSize()` TODO (f4bc610, VMConfig 加可选 displaySpec)
- ⚪ #20 `ConfigBuilder` enum 包 single static func — 重新评估: 实际有 1 public + 2 private + 1 struct, enum 是合理 namespace, 不动
- ⚪ #21 `HVMTextField.Handler` — 重新评估: 实际是 `ActionButton` (label + handler) 用作文件选择器, 非 onSubmit, 不动. 顺带修 Style 层 2 处硬编码 (f1f872d)
- ⚪ #22 `VMSession.observerToken: UUID?` 死字段 — 重新评估: 有 `addStateObserver` register + cleanup unregister 路径, 非死字段, 不动
- ✅ #23 `QemuPaths.swift` 注释提到 `third_party/qemu-stage` 兜底 (f1f872d)

### C. 配置 / Schema 健壮性

- ✅ #24 `ConfigMigrator` 链式 hook 框架空跑 (f4bc610, 加幂等约束硬规则)
- ✅ #25 `DiskFactory.create / grow` qcow2 分支无测试覆盖 (5fe59a4)
- ✅ #26 `HVMScmRecv` C 层无单测 (5fe59a4, socketpair round-trip 3 cases)
- ✅ #27 Bundle flock 互斥无并发测试 (5fe59a4, BundleLockTests 6 cases)

> 注: 上述测试 target 当时落地; 后于 2026-05 全 app 审计 PR (commit d887ed8) 中按 CLAUDE.md "测试约束" 整体移除 XCTest (CLT only 机器跑不起). 验证手段改走 `make build` + 真机 e2e (`hvm-cli` / `hvm-dbg gui` 自动化)。

### D. 资源生命周期

- ✅ #28 `SidecarProcessRunner` stderr readabilityHandler 在 SIGKILL 时不一定收 EOF (eebe29f)

### E. 脚本健壮性

- ✅ #32 Makefile `run-app` 杀进程靠 `awk NF == 2` 不稳健 (38c81b8, cmdline regex)
- ✅ #33 `verify-build.sh` 用 `plutil -extract` 不检返回码 (38c81b8)
- ✅ #34 `bundle.sh` 在 detached HEAD 时版本号写死 `0.0.1` (38c81b8, 降级到 dev-<sha7>)
- ⚪ #36 `edk2-build.sh` `fix_basetools_for_macos` sed 非幂等 — 重新评估: 已 `if grep -q ... then ok else sed`, 是 idempotent, 不动
- ✅ #37 `qemu-build.sh` `apply_patches` 读 series 末行无 `\n` 时漏读 (38c81b8)
- ✅ #38 patches 孤儿检测缺失 (38c81b8, verify-build.sh 加 check_orphan_patches)

### F. 用户体验

- ✅ #35 `CreateVMDialog` Windows 禁用提示暴露内部路径 (f1f872d)

## D — CLAUDE.md / README 漂移

- 🟡 D1 CLAUDE.md "sidecar fd-passing 路径已下线" 表述不准 — 后续重构 CLAUDE.md 时已对齐 (sidecar 字眼移除, HDP 协议中 SCM_RIGHTS 仍存留)
- 🟡 D2 README.md socket_vmnet 是否入包描述含糊 — 部分完成, 2026-05-05 全量重写 README 已对齐
- ✅ D3 CLAUDE.md `BundleLayout` 老 API 描述 — 已合规 (与代码对齐)
- ✅ D4 docs/v1/QEMU_DISPLAY_PROTOCOL.md 版本号对齐 patch 中 C header
- ✅ D5 v1 todo.md 已完成项滚动清理
- ✅ D6 docs/v1/NETWORK.md socket_vmnet 描述与 CLAUDE.md 一致

## V/L/P — v1 todo 悬挂项

- 🔴 V-1 Apple `com.apple.vm.networking` entitlement — 等审批
- 🔵 L-2 Rosetta share — 字段定义但 ConfigBuilder 未接, 长期
- 📦 L-4 vmnet daemon 热重装 QMP 热重连 — 归档 (方案 C 已暂搁置)
- ✅ P-1 Status / screenshot payload 编码助手
- ✅ P-2 `--engine qemu` flag 加 enum 校验提示
- ⚪ P-3 `qemu-build.sh --check` 模式 — 未做, 低优
- ✅ P-4 GUI + host 子进程 menu bar 双 status item — 已完成

## 后续

- 2026-05-05 全量文档重构: README + v1 全篇按代码现状对齐, v2 归档进本文, v3 状态推到"代码已合入"
- 加密 / 克隆 / GUI 自动化等新能力的现状描述独立为 v1/ENCRYPTION.md / v1/CLONE.md / v1/DEBUG_PROBE.md "gui 子命令" 节

---

**最后更新**: 2026-05-05
