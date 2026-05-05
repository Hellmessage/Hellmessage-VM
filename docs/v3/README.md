# HVM v3 — 新设计决策

本目录沉淀 v2 清单之外、需要单独立项设计的新能力。每份文档代表一项独立提案,从「设计稿 → 评审 → PR 拆解 → 合入」逐步推进,合入后再回写 `docs/v1/` 现状描述与 `CLAUDE.md` 约束。

## 目录

| 文档 | 主题 | 状态 |
|---|---|---|
| [CLONE.md](CLONE.md) | VM 克隆(APFS clonefile + 身份字段重生) | **代码已合入**, 现状回写 [../v1/CLONE.md](../v1/CLONE.md); macOS guest 双开 (C2) 仍标实验性 |
| [ENCRYPTION.md](ENCRYPTION.md) | VM 整盘加密(混合 + 强制密码 + 跨机器 portable) | **代码已合入** (QEMU per-file 全闭环), 现状回写 [../v1/ENCRYPTION.md](../v1/ENCRYPTION.md); VZ-sparsebundle 启动解锁推后 |
| [CLONE_SNAPSHOT_ENCRYPTED.md](CLONE_SNAPSHOT_ENCRYPTED.md) | 加密 VM clone + snapshot (D9 同密码 + 修 qcow2 老 bug) | **代码已合入** (PR-A snapshot / PR-B clone) |
| [SIGINT_CLEANUP.md](SIGINT_CLEANUP.md) | 加密长事务 SIGINT 防中断 + atexit cleanup | **代码已合入** (PR-C SignalGuard) |
| [GUI_ENCRYPTION.md](GUI_ENCRYPTION.md) | GUI 加密适配 (PR-11) | **代码已合入** (PR-11a/b/c 全落), 现状回写 [../v1/GUI.md](../v1/GUI.md) "加密 VM GUI 集成" 节 |
| [HVM_DBG_GUI_PROTOCOL.md](HVM_DBG_GUI_PROTOCOL.md) | hvm-dbg ↔ HVM GUI 测试协议 (HDP-GUI) | **代码已合入** (PR-G1/G2/G3/G5), D-G2 走自家 ProbeRegistry 不走 NSAccessibility |
| [FILE_COPY.md](FILE_COPY.md) | Win / Linux guest 单文件 push/pull (QGA `guest-file-*`) | **实现中** (PR-A/B/C/D 代码合入 2026-05-06); 待真机 P0 gate 验证后转 "代码已合入" |
| [TODO.md](TODO.md) | QEMU 加密 BUG / 遗漏清单 + 工具链 | **TODO 清单 v1**, 大多已 Done; 仍存的低优项已挪 [../v1/ROADMAP.md](../v1/ROADMAP.md) "残余项指引" |

## 与 v1 / CHANGELOG 的关系

- **v1**: 现状描述,代码长什么样
- **CHANGELOG** ([../CHANGELOG.md](../CHANGELOG.md)): 历史 v2 TODO 清单归档, 已完成动作的滚动留底
- **v3**: 新增能力的设计提案,把项目带到下一步

新设计在 v3 评审通过 + 实现合入后:

1. 把"现状描述"部分(bundle 布局、CLI、GUI、错误处理等)迁回 `docs/v1/` 对应文档
2. 把"约束"部分(必须 / 禁止 / 边界)同步进 `CLAUDE.md`
3. 在 v3 文档头标 `状态: 已合入`,留底不删,作为决策溯源

## 治理

- 单文档 = 单提案,**禁止**把多个不相关能力堆一份
- 文档头必须有 `状态: 设计稿 / 评审中 / 实现中 / 已合入` 标记
- 涉及 CLAUDE.md 约束变更的 v3 项,必须在"落地拆解"小节列出 CLAUDE.md 的具体改动
- 所有 v3 提案必须有"未决事项 (Decisions)"小节,明确哪些细节待确认

---

**最后更新**: 2026-05-06 (FILE_COPY PR-A/B/C/D 代码合入; 待真机 P0 gate)
