# HVM 设计文档索引

本目录收纳 HVM 项目的全部设计文档与决策沉淀。约束变更时必须同步更新相关文档。

## 阅读顺序推荐

想快速了解项目, 按此顺序读:

1. [ARCHITECTURE.md](ARCHITECTURE.md) — 项目全貌、模块划分、进程模型
2. [ROADMAP.md](ROADMAP.md) — 里程碑与不做清单
3. [VM_BUNDLE.md](VM_BUNDLE.md) — `.hvmz` 目录布局与 `config.json` schema
4. 其他专题按需读

## 全部文档

### 核心设计

| 文档 | 职责 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 模块划分、依赖拓扑、进程模型、数据流、核心抽象 |
| [VM_BUNDLE.md](VM_BUNDLE.md) | `.hvmz` bundle 目录结构、`config.json` schema、flock 互斥、schema 演化 |
| [VZ_BACKEND.md](VZ_BACKEND.md) | `Virtualization.framework` 封装、VM 生命周期状态机、事件订阅、配置构建 |
| [STORAGE.md](STORAGE.md) | raw sparse 磁盘格式、扩容、ISO 处理、APFS clonefile 快照 |
| [NETWORK.md](NETWORK.md) | NAT(MVP) + Bridged(审批通过后) + MAC 管理 |

### 前端

| 文档 | 职责 |
|---|---|
| [GUI.md](GUI.md) | `HVM.app` 黑色主题、弹窗约束、ErrorDialog、创建向导、独立/嵌入运行窗口 |
| [CLI.md](CLI.md) | `hvm-cli` 子命令体系、输出格式、退出码、VM 定位策略 |
| [DEBUG_PROBE.md](DEBUG_PROBE.md) | `hvm-dbg` 定位、子命令、扩展原则(零新协议)、AI agent 协作 |

### 支撑

| 文档 | 职责 |
|---|---|
| [BUILD_SIGN.md](BUILD_SIGN.md) | SwiftPM + `scripts/bundle.sh` 构建、ad-hoc 签名、entitlement 注入 |
| [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) | macOS IPSW 装机(全自动)、Linux ISO 装机(半自动) |
| [DISPLAY_INPUT.md](DISPLAY_INPUT.md) | 显示设备、键盘/鼠标设备、窗口容器、截图机制 |
| [ERROR_MODEL.md](ERROR_MODEL.md) | 错误类型层级、用户文案规范、日志脱敏、错误码列表 |
| [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) | QEMU 随包分发、包内目录与签名、**仅 Win/Linux guest arm64**、**运行时零外部依赖** 的工程约定 |

### 治理

| 文档 | 职责 |
|---|---|
| [ENTITLEMENT.md](ENTITLEMENT.md) | entitlement 申请与审批追踪, bridged 相关 SOP |
| [ROADMAP.md](ROADMAP.md) | 里程碑 M0–M6、不做清单、风险项 |

## 文档风格约定

- 中文为主, 术语允许保留英文
- 结构统一:
  - **目标** — 这篇文档想解决什么
  - **约束** — 不得违反的硬规则(来自 CLAUDE.md 或设计决策)
  - **设计** — 具体方案
  - **不做什么** — 明确边界
  - **未决事项** — 尚未决策的问题表, 编号跨文档不重复
- 每篇末尾留 `**最后更新**` 日期
- 文档互链用相对路径

## 未决事项编号空间

| 文档 | 前缀 |
|---|---|
| ARCHITECTURE.md | A* |
| VM_BUNDLE.md | B* |
| VZ_BACKEND.md | C* |
| STORAGE.md | D* |
| NETWORK.md | E* |
| GUI.md | F* |
| CLI.md | G* |
| DEBUG_PROBE.md | H* |
| BUILD_SIGN.md | I* |
| GUEST_OS_INSTALL.md | J* |
| DISPLAY_INPUT.md | K* |
| ERROR_MODEL.md | L* |
| QEMU_INTEGRATION.md | M* |

新加文档 → 分配下一个字母前缀。

## 约束冲突处置

当 docs/ 内描述与 `CLAUDE.md` 冲突时, 以 `CLAUDE.md` 为准。发现冲突应立即:

1. 修正 docs/ 相关文档
2. 若是 docs/ 的设计已实际实施但 CLAUDE.md 未跟进, 同步更新 CLAUDE.md

---

**最后更新**: 2026-04-27
