# HVM 设计文档索引 (v1 — 现状描述)

本目录是 HVM 项目的"现状快照", 描述代码现在长什么样。**历史 TODO 归档**走 [../CHANGELOG.md](../CHANGELOG.md), **新能力设计提案 / 决策溯源**走 [../v3/](../v3/)。

> 顶级入口见 [../README.md](../README.md)。

## 阅读顺序推荐

想快速了解项目, 按此顺序读:

1. [ARCHITECTURE.md](ARCHITECTURE.md) — 项目全貌、17 模块划分、双后端进程模型
2. [ROADMAP.md](ROADMAP.md) — 已完成里程碑 + 不做清单
3. [VM_BUNDLE.md](VM_BUNDLE.md) — `.hvmz` 目录与 `config.yaml` schema v3
4. [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — Windows / Linux QEMU 后端集成
5. [ENCRYPTION.md](ENCRYPTION.md) — 整 VM 加密 (qcow2 LUKS / config.yaml.enc / KDF)
6. [CLONE.md](CLONE.md) — 整 VM 克隆 (APFS clonefile + 加密分支)
7. 其他专题按需读

## 全部文档

### 核心设计

| 文档 | 职责 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 17 模块划分、依赖拓扑、VZ + QEMU 双后端进程模型、数据流、核心抽象 |
| [VM_BUNDLE.md](VM_BUNDLE.md) | `.hvmz` 目录结构、`config.yaml` schema v3、flock 互斥、ConfigMigrator |
| [VZ_BACKEND.md](VZ_BACKEND.md) | `Virtualization.framework` 封装、VM 生命周期、事件订阅、VZ 配置构建 |
| [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) | QEMU 子进程编排、随包分发、HVF 后端、Win11 三件套 (swtpm + EDK2 + virtio) |
| [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) | HDP v1.0.0: AF_UNIX + POSIX shm + SCM_RIGHTS 显示协议规范 |
| [STORAGE.md](STORAGE.md) | raw sparse / qcow2 / 加密 LUKS qcow2、扩容、ISO 处理、APFS clonefile |
| [NETWORK.md](NETWORK.md) | NAT (user-mode) + socket_vmnet shared/host/bridged + MAC 管理 |
| [ENCRYPTION.md](ENCRYPTION.md) | 整 VM 加密 (qcow2 LUKS / sparsebundle / config.yaml.enc / PBKDF2 + HKDF KDF) |
| [CLONE.md](CLONE.md) | 整 VM 克隆 (APFS clonefile + 身份字段重生 + 加密分支) |

### 前端

| 文档 | 职责 |
|---|---|
| [GUI.md](GUI.md) | `HVM.app` 黑色主题、自绘 UI 控件、ErrorDialog、4 步创建向导、加密 dialog、detached 窗口 |
| [CLI.md](CLI.md) | `hvm-cli` 子命令 (含 encrypt/decrypt/rekey/clone/snapshot)、输出格式、退出码 |
| [DEBUG_PROBE.md](DEBUG_PROBE.md) | `hvm-dbg` 子命令 (含 `gui *` HDP-GUI 自动化)、扩展原则、AI agent 协作 |

### 支撑

| 文档 | 职责 |
|---|---|
| [BUILD_SIGN.md](BUILD_SIGN.md) | SwiftPM + `scripts/bundle.sh` 构建、ad-hoc 签名、QEMU 子进程独立 entitlement |
| [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) | macOS IPSW 装机、Linux ISO 装机、Win11 unattend、`OSImageCatalog` 7 发行版 |
| [DISPLAY_INPUT.md](DISPLAY_INPUT.md) | 显示设备、键鼠、剪贴板共享 (PasteboardBridge)、macOS 风快捷键 |
| [ERROR_MODEL.md](ERROR_MODEL.md) | `HVMError` 层级、用户文案规范、日志脱敏 |

### 治理

| 文档 | 职责 |
|---|---|
| [ENTITLEMENT.md](ENTITLEMENT.md) | entitlement 申请追踪, bridged SOP |
| [ROADMAP.md](ROADMAP.md) | 里程碑 M0–M6(全部完成)、加密 / 克隆 / GUI 自动化新里程碑、不做清单、风险项 |
| [todo.md](todo.md) | 历史已完成项滚动归档 |

## 文档风格约定

- 中文为主, 术语允许保留英文
- 结构统一: **目标 → 约束 → 设计 → 不做 → 未决**
- 每篇末尾留 `**最后更新**` 日期
- 文档互链用相对路径(都在 v1/ 内, 例如 `[STORAGE.md](STORAGE.md)`)
- 与 v3 / 顶级互链用 `../v3/...` / `../README.md` / `../CHANGELOG.md`

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
| QEMU_DISPLAY_PROTOCOL.md | N* |
| ENCRYPTION.md | O* |
| CLONE.md | P* |

新加文档 → 分配下一个字母前缀。

> 历史 v1/todo.md 中遗留的 V/L/P 系列已挪 [ROADMAP.md](ROADMAP.md) "残余项指引" + [../CHANGELOG.md](../CHANGELOG.md) 归档。

## 约束冲突处置

当 docs/ 内描述与项目根 `CLAUDE.md` 冲突时, **以 `CLAUDE.md` 为准**。发现冲突应立即:

1. 修正 docs/v1/ 相关文档(已落地能力)
2. 若 docs/v1 设计已实施但 CLAUDE.md 未跟进, 同步更新 CLAUDE.md

---

**最后更新**: 2026-05-05
