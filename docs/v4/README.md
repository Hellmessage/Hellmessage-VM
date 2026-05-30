# HVM v4 — 新 GUI 重构

本目录沉淀**新 GUI 重构**这条主线的设计提案. 跟 [v3](../v3/README.md) (上一波 v2 → v3 已基本合入的能力提案) 平行, v4 专注 GUI 体系从零设计.

每份文档代表一项独立提案, 从「设计稿 → 评审 → PR 拆解 → 合入」逐步推进. 合入后再回写 `docs/v1/` 现状与 `CLAUDE.md` 约束.

## 目录

| 文档 | 主题 | 状态 |
|---|---|---|
| [NEW_GUI.md](NEW_GUI.md) | 新 GUI 基础设施 (Linear 风 Theme token + 自绘 Dialog 框架 + 基础组件库 + HVMUI namespace + 组件设计规范 R1-R9) | **实现中** 2026-05-29, PR-T1+T2 / C1+C1b / C2 / C3 / C4 已合, 剩 C5-C8 + D1-D7 + L1 |
| [QEMU_ONLY_PIVOT.md](QEMU_ONLY_PIVOT.md) | **QEMU-only 转向** — 剥离 VZ (entitlement 未批 + QEMU 已满足) + 统一显示通路 (截图/内嵌同源 HDP IOSurface) + 内嵌优化. 项目级战略转向 | **设计稿** 2026-05-30 |

后续业务页子稿登记位置 (每业务页独立提案, 引 NEW_GUI.md 作基础设施前置依赖):

| 子稿 | 主题 | 状态 |
|---|---|---|
| [NEW_GUI_MAIN_LAYOUT.md](NEW_GUI_MAIN_LAYOUT.md) | sidebar + detail 两栏主窗口骨架 + VM 列表 + 精简新 store + HVMControl 共享控制层 (折叠原 VM_LIST 子稿) | **代码已合入** 2026-05-30, M1-M6 全合 |
| ~~`NEW_GUI_VM_LIST.md`~~ | (已折叠进 NEW_GUI_MAIN_LAYOUT.md — sidebar 即 VM 列表, 不拆两份) | 折叠 |
| [NEW_GUI_VM_DETAIL.md](NEW_GUI_VM_DETAIL.md) | 详情页完整配置编辑 (资源/磁盘/网络/ISO/共享/选项 + **加密 VM 解锁编辑** + **vmnet daemon 安装**) | **代码已合入** 2026-05-30, V1-V9 全合 |
| `NEW_GUI_CREATE_VM.md` | 创建 VM Wizard (复用 HVMUI.WizardDialog) |
| [NEW_GUI_ENCRYPTION.md](NEW_GUI_ENCRYPTION.md) | 加密 / 解密 / rekey dialog (三态自定义 dialog + NewGUIStore async) | **代码已合入** 2026-05-30, E1-E3 全合 |
| `NEW_GUI_FILE_TRANSFER.md` | 文件传输 dialog |
| ~~`NEW_GUI_NETWORK.md`~~ | (核心已覆盖: NIC 字段编辑走 VM_DETAIL **V5** `DetailNetworkSection` + vmnet daemon 安装/重启/卸载走 **V6** `DetailVmnetDaemonView`. 剩 per-iface live 状态 / guest IP 显示 / daemon 健康探测细节 → TODO 低优, 不单拆业务页) | 覆盖 (V5+V6) |
| [NEW_GUI_FRAMEBUFFER.md](NEW_GUI_FRAMEBUFFER.md) | VM 画面 framebuffer 嵌入 (QEMU HDP; VZ 推迟) | **实现中** 2026-05-30, F1-F4 |

## 跟 v3 / v1 / CHANGELOG 的关系

- **v1** ([../v1/](../v1/)): 现状描述, 代码长什么样
- **v3** ([../v3/](../v3/)): 上一波 v2 → v3 设计提案 (大部分已合: CLONE / ENCRYPTION / SHARED_FOLDER / 等)
- **v4** (本目录): 新 GUI 重构主线 — 跟 v3 平行, 独立立项
- **CHANGELOG** ([../CHANGELOG.md](../CHANGELOG.md)): 历史 v2 TODO 清单归档

为什么单独立 v4 不复用 v3:
- v3 是一波具体能力 (克隆/加密/共享/etc) 的归档, 大多已合
- 新 GUI 重构是**整条 GUI 体系**重做, 范围大 + PR 多 (18 PR 起步)
- 单独立项目录可隔离, 不污染 v3 索引

## 治理

- 单文档 = 单提案, **禁止**把多个不相关能力堆一份
- 文档头必须有 `状态: 设计稿 / 评审中 / 实现中 / 已合入` 标记
- 涉及 CLAUDE.md 约束变更的 v4 项, 必须在"落地拆解"小节列出 CLAUDE.md 的具体改动
- 所有 v4 提案必须有"未决事项 (Decisions)"小节
- **进度追踪**: 跨 session 走 [../TODO.md](../TODO.md), 设计稿内部状态头仅大节点

---

**最后更新**: 2026-05-29 (从 v3 拆出 NEW_GUI.md, 单独立 v4 主线)
