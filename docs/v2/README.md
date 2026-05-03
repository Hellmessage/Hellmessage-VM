# HVM v2 — 优化与技术债 TODO

本目录是 2026-05-03 完成的全项目深审 (代码质量 / UI 合规 / 错误处理 / 构建打包 / 测试覆盖) 落地清单, 共 **38 项审查发现** + **7 项 v1 todo.md 悬挂** = **45 项**。

> v1 文档(`docs/v1/`)是按"现有代码逻辑"重构的现状描述; v2 是"基于现状的下一步行动"。两者职能不同, 请勿混用。

## 目录

| 文档 | 内容 | 项数 |
|---|---|---|
| [01-P0-immediate.md](01-P0-immediate.md) | 立即修(影响功能正确性 / 安全) | 6 |
| [02-P1-this-week.md](02-P1-this-week.md) | 本周做(可观测性 / 易出事的脆弱点 / UI 合规) | 11 |
| [03-P2-techdebt.md](03-P2-techdebt.md) | 持续改进 / 技术债 | 21 |
| [04-doc-drift.md](04-doc-drift.md) | CLAUDE.md / README.md 与代码漂移 | 2 |
| [05-pending-from-v1.md](05-pending-from-v1.md) | v1 todo.md 中尚未消化的悬挂项 (V-1 / L-2 / L-4 / P-1~P-4) | 7 |
| [06-already-compliant.md](06-already-compliant.md) | 已合规、本次审过免列(留底防回归) | 12 |

## 优先级总览

| 阶段 | 时间盒 | 核心交付 |
|---|---|---|
| **立即** | 1-2 天 | 修签名漏洞 / 接口名注入风险 / swtpm 孤儿与时序 / app graceful shutdown / BundleLock 线程安全 / mktemp trap |
| **本周** | 3-5 天 | UI token 体系铺平(批量 ~50 处替换) + 测试盲区补上(BundleIO v1 检测、HDP fuzz) + Makefile 增量签名 |
| **持续** | 与功能开发并行 | 每周清 2-3 项, 主要是错误观测、配置 schema 中心化、脚本健壮性、测试覆盖 |

## 修复关键拐点

1. **#1 + #2** 是真实可让用户失败的安全 / 正确性问题, 优先级最高
2. **#7-9** 一次性扩充 `HVMFont / HVMColor / HVMSpace` token, 可批量替换业务侧 ~50 处 UI 漂移
3. **#16** Makefile 增量能让日常 `make build` 从 ~30s 降到 ~5s, 工程师体验显著提升
4. **#12 + #13** 测试盲区补完后, 任何后续 schema 升级 / 协议改动都有兜底保障

## 审查方法 / 数据来源

- 全量扫描 `app/Sources/` 168 个 Swift 文件 / ~28k 行
- 全量审 `scripts/*.sh` + `Makefile` + `app/Package.swift`
- 全量审 `app/Tests/` 8 个测试 target 与覆盖盲区
- 全量审 `docs/v1/*.md` × CLAUDE.md × README.md 三方漂移
- 5 路并行 Agent 深审 + 关键事实人工核验

## 修复完成后流程

每完成一项:
- 标记对应文档中的 `[ ]` 为 `[x]`, 记录完成日期
- 若涉及 CLAUDE.md 约束变化, 同步更新 CLAUDE.md
- 涉及 docs/v1/ 文档现状描述变化时, 同步修订 v1
- 全部 P0 + P1 完成后, v2 这套文档可滚动归并到一份 `CHANGELOG.md`

---

**最后更新**: 2026-05-03
