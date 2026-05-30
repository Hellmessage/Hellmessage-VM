# HVM 文档

基于当前代码现状梳理的开发者文档（**QEMU-only 单后端**，guest 仅 Linux + Windows arm64；VZ 后端 / macOS guest 已移除）。

项目硬约束在仓库根 [CLAUDE.md](../CLAUDE.md)，与本目录冲突时以 CLAUDE.md 为准。

## 文档索引

### 总览与工程

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 项目全貌、16 个 target 拓扑与依赖、三二进制角色、GUI↔host↔QEMU 进程模型、HVMControl 控制层 |
| [BUILD_SIGN.md](BUILD_SIGN.md) | SwiftPM 构建、`make build` / `build-all` / `install`、bundle.sh 签名闭环、双 entitlement、零运行时依赖 |
| [VM_BUNDLE.md](VM_BUNDLE.md) | `.hvmz` 目录布局、`config.yaml` schema v3 全字段、Yams 序列化、ConfigMigrator、BundleLock flock 互斥 |
| [ERROR_MODEL.md](ERROR_MODEL.md) | HVMError 错误模型、退出码映射、HVMIPC 协议、SignalGuard 信号处理、日志落盘规则 |

### QEMU 后端与显示

| 文档 | 内容 |
|---|---|
| [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) | QEMU/EDK2/swtpm 随包分发、版本锁定、patch 串行管理、dylib bundle 零依赖、双 firmware 策略 |
| [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) | HDP IOSurface 显示协议 v1.0.0（AF_UNIX + shm + SCM_RIGHTS）、消息格式、ramfb + virtio-gpu 双路 |
| [DISPLAY_INPUT.md](DISPLAY_INPUT.md) | framebuffer 零拷贝渲染、键鼠捕获（Cmd+Opt）、修饰键状态镜像、macStyle 映射、dynamic resize |

### 存储 / 加密 / 网络

| 文档 | 内容 |
|---|---|
| [STORAGE.md](STORAGE.md) | 磁盘 qcow2/raw、DiskFactory、CloneManager（APFS clonefile）、SnapshotManager、ISOValidator |
| [ENCRYPTION.md](ENCRYPTION.md) | 整 VM 落盘加密（PBKDF2 + HKDF 子 key + LUKS qcow2 + swtpm + AES-GCM config）、encrypt/decrypt/rekey |
| [NETWORK.md](NETWORK.md) | socket_vmnet daemon、NAT/shared/host/bridged 模式、`-netdev stream` 接法、daemon 健康探测 |

### Guest 与数据共享

| 文档 | 内容 |
|---|---|
| [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) | Linux ISO 装机（OSImageCatalog 下载）、Windows 11 装机（unattend / virtio-win / UTM Guest Tools / swtpm） |
| [SHARING.md](SHARING.md) | 共享目录（SPICE WebDAV）、文本/图片剪贴板、Cmd+V 文件粘贴（vdagent file_xfer）、文件传输（QGA） |

### 入口与界面

| 文档 | 内容 |
|---|---|
| [CLI.md](CLI.md) | `hvm-cli` 全子命令参考（21 顶层 + 子命令）、参数、退出码、加密密码输入 |
| [DEBUG_PROBE.md](DEBUG_PROBE.md) | `hvm-dbg` 调试探针全子命令、HDP-GUI 自动化协议（`.hvmProbe` + ProbeRegistry） |
| [GUI.md](GUI.md) | 新 GUI：HVMUI 组件库、Theme token、强制 probeID、NewGUIStore、两栏主界面 + 详情页 inline 编辑 + dialog 体系 |

### 规划 / 路线图

| 文档 | 内容 |
|---|---|
| [HEADLESS.md](HEADLESS.md) | 无头模式现状分析 + 路线图 TODO（P0 `-display none` / P1 解耦 AppKit / P2 console / P3 launchd 自启 / P4 远程显示）|

## 推荐阅读顺序

1. [ARCHITECTURE.md](ARCHITECTURE.md) — 先建立项目全貌与模块拓扑
2. [VM_BUNDLE.md](VM_BUNDLE.md) — `.hvmz` 与 config schema 是数据模型基础
3. [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — 唯一后端的随包分发与构建
4. [BUILD_SIGN.md](BUILD_SIGN.md) — 怎么编出带签名的 `.app`
5. 按需读各专题（存储 / 加密 / 网络 / 显示 / 共享 / 装机 / CLI / hvm-dbg / GUI）

> 文档为当前代码现状描述，非设计提案。代码迭代后需同步更新对应文档。
