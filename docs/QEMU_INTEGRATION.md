# QEMU 集成（随包分发）

## 产品范围（已收敛）

- QEMU 相关能力 **只考虑 guest 为 ARM64 的 Windows 与 Linux**。  
- **不实现** x86_64、riscv 等其他 guest 架构，也不以「TCG 跨架构跑任意 ISO」为范围；包内可执行文件以 **`qemu-system-aarch64`（在 Apple Silicon 宿主机上跑 AArch64 虚拟机）** 为主线裁剪，不引入多架构 `qemu-system-*` 矩阵以控体积、签名与测试面。
- 与现有 HVM 关系：VZ 仍负责已支持的 **macOS** 与 **Linux arm64** 主路径；QEMU 分支用于在 **不改动「VZ 能力边界」对外承诺** 的前提下，覆盖 **Windows arm64** 等 VZ 不承接的场景，以及产品决定是否对 **Linux arm64** 也走 QEMU（若走，则仍仅 arm64，见上条）。

## 目标

- 在 **保留现有 `Virtualization.framework`（VZ）主路径** 的前提下，为上述 **Windows / Linux 的 arm64 guest** 需要、且 VZ 不覆盖或产品选择用 QEMU 承载的场景，提供 **QEMU 后端**（子进程、包内二进制）。
- **最终用户**安装 HVM 后，**不要求**安装 Homebrew、不要求在系统 PATH 中提供 `qemu-system-*`，不要求下载额外运行时 —— **启动 VM 所需可执行文件与资源均来自 `HVM.app` 包内路径**。
- 应用内通过 `Bundle.main`（或等价 API）解析 QEMU 与各资源路径，**禁止**依赖 `Process` + `which` / 环境变量隐式发现系统 QEMU。

本文档描述 **工程与交付层面** 的约束与推荐实现；UI 入口级是否对 Linux 同时暴露 VZ 与 QEMU 由产品定，但 **QEMU 侧实现与测试仅针对 arm64 Windows/Linux**。

## 约束

### 与 `CLAUDE.md` 的关系

- 当前 `CLAUDE.md` 强调 **Swift + Apple 框架**、不引入 **用户侧** Homebrew/重依赖。QEMU 以 **自研编排 + 包内子进程** 方式接入，**不**以 Swift 链接 `libqemu` 为一期目标。
- 一旦本方案落地，应在 `CLAUDE.md` 中增加**明确例外条款**：**运行时**依赖仅来自 `.app` 包内；**构建时** 允许在受控流程中把 QEMU 产物打入包内（与「用户机器零安装」不矛盾）。
- 若文档与实现冲突，按 `docs/README.md` 中「约束冲突处置」处理。

### 运行时可验证约束（必达）

| 规则 | 说明 |
|------|------|
| **无隐式 PATH** | 不得假定 `/opt/homebrew/bin` 等存在；子进程可执行文件路径由 `Bundle` 内 URL 拼出。 |
| **无首次联网拉 QEMU** | 用户首次启动 HVM 打开 QEMU 类 VM 时，不应再下载 QEMU 本体（资源清单可随版本发布物一并提供，仍属「包内」或安装包内，而非运行时临时下载二进制）。 |
| **版本锁定** | 包内 QEMU 与固件文件与 HVM 版本绑定；升级 App 即升级所带 QEMU 行为，避免「系统 QEMU 与 UI 脱轨」。 |
| **签名校验** | 见下文「签名与隔离」；所有 Mach-O 必须进入签名闭环，避免 Gatekeeper/AMFI 在子进程上失败。 |

### 法律与许可（必做）

- 上游 QEMU 以 **GPL** 等 copyleft 许可发布。随 `HVM.app` 再分发其二进制时，须遵守许可证要求，包括但不限于：**许可证全文或摘要随包**、**提供对应版本的源代码获取方式**（例如指向固定 tag 的公开仓库 + 构建说明，或随发布物附带 `source/` 包）。
- 在「关于」或独立 **第三方许可** 页面中列出 QEMU 及静态链接/携带的库（若采用单文件或 Framework 集），避免合规风险。

## 设计

### 1. 进程模型

- HVM 主进程（`HVM` 可执行文件）**不**内嵌 `libqemu` 执行引擎；**一期推荐**：由 Swift 使用 `Process` 启动包内的 `qemu-system-*`（或统一入口脚本，若需要设置 `DYLD`/`QEMU` 前缀等环境变量，仍由本进程控制）。
- 生命周期、日志、崩溃退出码、资源回收（子进程强杀）由 **专用编排类型** 管理（例如未来 `HVMQemu` / `QemuProcessRunner` 模块），与现有 `VMHandle`（VZ 专用）**并列**，避免在 `ConfigBuilder` 中无限堆 `if qemu`。
- 与 `.hvmz` 的互斥：延续「单 bundle 单打开方」；持锁方应为发起 QEMU 的同一逻辑（与现有一致），避免多进程争用同一磁盘镜像。

### 2. 包内目录布局（建议）

实际目录名以实现为准，以下为便于审查的约定：

```
HVM.app/Contents/
├── MacOS/
│   ├── HVM
│   ├── hvm-cli
│   └── hvm-dbg
└── Resources/
    └── QEMU/                          # 仅作示例名，可改为 Vendor/QEMU 等
        ├── bin/
        │   └── qemu-system-aarch64   # 范围限定 arm64 guest；不打包其他架构的 system 目标
        ├── share/                     # 固件、keymap、bios 等，按 target 需要裁剪
        │   └── ...
        └── lib/                       # 若使用动态库而非完全静态，需一并纳入并签名
```

**路径解析（Swift）**：

- 使用 `Bundle.main.url(forResource:withExtension:subdirectory:)` 或 `Bundle.main.resourceURL?.appendingPathComponent("QEMU/bin/...")` 等 **确定的相对路径**。
- 单元测试与 CLI：若从非 `.app` bundle 运行，需有 **与 `BUNDLE` 环境或 `#if DEBUG` 路径回退** 的明确定义（开发文档单独在实现 PR 中补全），但 **发布形态** 仅以 `.app` 为准。

### 3. 构建与 `bundle.sh` 集成

- **SwiftPM** 仍只负责 Swift 目标；QEMU 不作为 CMake 子工程接入 SwiftPM（避免把「重 C 构建」绑死在每次 `swift build`）。
- **推荐流程**：
  1. 在**受控环境**（开发者机器或 CI）产出 **仅 AArch64 机器/目标相关** 的 QEMU Mach-O 集合与裁减后的 `share` 内容（无 x86_64 guest 等额外 target）。
  2. 将产物放入仓库中固定位置（见下节「产物来源策略」）或仅存在于 CI 工作区。
  3. `scripts/bundle.sh`（或新脚本 `scripts/bundle-qemu.sh` 由其调用）在组装 `HVM.app` 时 **复制** 至 `Contents/Resources/QEMU/`，再参与 **统一签名**（见下节）。

- **与 `make build` 的契约**（需在 Makefile 中写死检查规则之一）：

  - **严格模式**：若包内缺少 QEMU 目录，则 `make build` 失败，提示如何生成/拉取受信产物。  
  - **或** 分 target：`make build` 不启用 QEMU 嵌入（仅 VZ），`make build-all` 嵌入 QEMU（产品发布用）。**若产品要求「安装包即含 QEMU」**，应最终收敛到**默认**发布流包含包内 QEMU。

### 4. 产物来源策略（选其一或组合，需在实现前决策）

| 策略 | 优点 | 缺点 |
|------|------|------|
| **A. 仓库内二进制（LFS/子模块）** | 一条 `make build` 可复现，CI 简单 | 仓库体积大，升级 QEMU 有流程成本 |
| **B. 发布用 artefact 缓存** | 不胀仓库，CI 可缓存 | 本地开发需先拉 artefact 或从 CI 取 |
| **C. 维护者本机构建 + 手拷入 `Resources/QEMU`（仅开发）** | 不自动化 | 易漂移，**不推荐**作长期方案 |

**建议**：以 **A 或 B** 为主，并在 `docs/BUILD_SIGN.md` 中增加「QEMU 资源准备」小节互链到本文（实现时同步改）。

### 5. 签名与 Gatekeeper

- 所有位于 `HVM.app` 内的 **可执行文件** 与 **被加载的动态库** 必须在 **最终的 `codesign` 整包** 前处于一致状态；常见做法：
  - 对 `Resources/QEMU/bin/*`、`Resources/QEMU/lib/*.dylib` **逐文件** `codesign`（与主 App 使用同一证书链或 ad-hoc 规则一致）；
  - 再对 `HVM.app` 做 `codesign --deep` 或依 Apple 建议顺序签外层。
- 若需要 **公证 (notarization)**，须确认 QEMU 及依赖库不触发需要额外 entitlements 的行为；具体以 `codesign` / `spctl` 实测为准。

### 6. 与 VZ 的功能边界（避免用户混淆）

- `VMConfig` / schema 中应能区分 **引擎类型**（例如 `engine: vz | qemu` 或等效枚举），**默认**为 `vz`，与现有用户数据兼容。
- **不**将同一物理磁盘文件在无迁移流程的情况下在 VZ 与 QEMU 间随意切换，除非明确定义「导入/转换」与风险提示（raw/qcow2、设备模型差异等）。

## 不做什么（一期明确排除）

- **非 arm64 的 guest**（x86_64、32 位旧版、riscv 等）：不在 QEMU 方案内实现，不扩展对应 `qemu-system-*` 打包与 UI。
- 不实现「用户自行指定系统 QEMU 路径」作为**默认**路径（会违背「全包在 App 内」；若将来提供 **高级调试开关**，须默认关闭且强提示不受支持）。
- 不把 QEMU 的完整设备矩阵一次性接入 UI；一期以 **能可靠启动/停止 + 可观测日志** 为主（范围仍限于 Win/Linux arm64）。
- 不承诺与 `hvm-dbg` 现有 **仅 VZ 封装** 子命令 100% 等价；QEMU 路径需单独子集或新协议（在 `docs/DEBUG_PROBE.md` 中后续追加）。

## 未决事项（前缀 `M`）

| 编号 | 内容 |
|------|------|
| M1 | **已决（范围收敛）**：包内只考虑带 `qemu-system-aarch64`；宿主机为 Apple Silicon，guest 仅 AArch64 的 **Windows 与 Linux**（见上文「产品范围」）。 |
| M2 | 随包固件（EDK2 等，面向 Win/Linux **arm64**）版权、许可与体积上限？ |
| M3 | 显示：SPICE / VNC / 管道帧缓冲 —— 与现有 `HVMDisplay` 的集成切分？ |
| M4 | 网络：user 模式与现有 HVM 网络配置如何映射到 QEMU `-netdev`？ |
| M5 | 产物进入仓库还是仅 CI 缓存（A vs B 的最终决策）？ |
| M6 | GPL 合规在 UI 中的展示形式（仅 About / 独立「开放源代码许可」页）？ |
| M7 | Linux arm64 是否提供 QEMU 入口、抑或 **仅 VZ**、QEMU 专供 Windows arm64？（产品决策，不影响「仅 arm64」工程边界） |

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 模块与进程模型，后续在「后端」章节增加 QEMU 分支。
- [BUILD_SIGN.md](BUILD_SIGN.md) — `bundle.sh` 与签名顺序，实现嵌入后应追加 QEMU 步骤。
- [VM_BUNDLE.md](VM_BUNDLE.md) — `config.json` 若增加 `engine` 字段，在此文档演化 schema。

---

**最后更新**: 2026-04-27
