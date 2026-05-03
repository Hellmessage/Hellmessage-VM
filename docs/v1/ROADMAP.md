# 路线图

## 里程碑一览

| 里程碑 | 目标 | 状态 |
|---|---|---|
| **M0** | 项目骨架 (SwiftPM + Makefile + docs) | ✅ 已完成 |
| **M1** | CLI 起 Linux guest (VZ) | ✅ 已完成 |
| **M2** | GUI 基础 (列表 / 向导 / detached 窗口) | ✅ 已完成 |
| **M3** | macOS guest (IPSW + 内建下载器) | ✅ 已完成 |
| **M4** | 桥接网络 | ⏳ VZ bridged 待 entitlement; QEMU 走 socket_vmnet 已完成 |
| **M5** | hvm-dbg 完整化 (OCR / find-text / wait / exec) | ✅ 已完成 |
| **M6** | 打磨 + 文档完善 | 🟡 进行中 |
| **QEMU 集成** (跨 M4-M6) | Linux/Windows arm64 QEMU 后端 | ✅ 已完成 |
| **OS 镜像自动下载** | OSImageCatalog 7 发行版 | ✅ 已完成 (2026-05-03) |
| **剪贴板 + macOS 快捷键** | QEMU 后端 vdagent + cmd→ctrl | ✅ 已完成 (2026-05-04) |

以下只排优先级, 不排日期(个人项目, 按进展推进)。当前主体能力已闭环, 残余项收纳在 [../v2/](../v2/)。

## M0 — 项目骨架 ✅

- `app/Package.swift` 16 个 target / `Makefile` / `scripts/bundle.sh` / `app/Resources/*` 全就绪
- CLAUDE.md + docs/v1 全部文档完整
- `make build` 出带 entitlement 签名的 `build/HVM.app`

## M1 — CLI 起 Linux guest ✅

- `HVMBundle` 读写 config.yaml v2 (Yams) + BundleLock (fcntl) + ConfigMigrator 框架
- `HVMStorage` `DiskFactory.create/grow/delete`, raw + qcow2 双格式
- `HVMNet` 五种 NetworkMode (`user / vmnetShared / vmnetHost / vmnetBridged / none`)
- `HVMBackend` `VMHandle` actor + VZ 配置构建
- `hvm-cli` `create / list / status / start / stop / kill / delete / boot-from-disk` 全可用
- 签名 / entitlement 接通

## M2 — GUI 基础 ✅

- `HVMDisplay.VZViewRepresentable` 嵌入主窗口
- 黑色主题 + 列表 + 详情 + 创建向导 (Linux + macOS + Windows 三分支)
- 自绘 UI 控件: `HVMFormSelect / HVMTextField / HVMToggle / HVMModal / TerminalSection / PrimaryButtonStyle / GhostButtonStyle / IconButtonStyle / HeroCTAStyle / PillAccentButtonStyle`(详见 GUI.md)
- ErrorDialog 统一弹窗, 禁用 NSAlert
- detached borderless 窗口已重写, 嵌入态 ⇄ 独立切换
- 列表缩略图(`ThumbnailWriter`, VZ + QEMU 共用 atomic 写, 10s 周期)

## M3 — macOS guest ✅

- `HVMInstall.RestoreImageHandle` / `MacInstaller` / `MacAuxiliaryFactory`(幂等校验)
- `IPSWFetcher` 走 `HVMUtils.ResumableDownloader`(断点续传 + If-Range + 416 重试 + atomic rename)
- GUI 创建向导 macOS 分支 + `IpswFetchDialog` 进度模态
- `hvm-cli install / ipsw {latest, fetch, list, rm}`
- 详情面板显示 IPSW 版本与 `autoInstalled`

## M4 — 桥接网络 (拆为两条)

### QEMU 后端 socket_vmnet bridged ✅

- `socket_vmnet` 由用户 brew 装(不打包入 .app), launchd plist label `com.hellmessage.hvm.vmnet.*`
- `scripts/install-vmnet-daemons.sh` 走 `osascript ... with administrator privileges` 走 Touch ID/密码框, 装 `shared + host + N 个 bridged.<iface>`
- QEMU argv 直接 `-netdev stream,addr.type=unix,addr.path=...` 接 daemon 固定路径(无 sidecar fd-passing)
- GUI VMnetSupervisor 安装 + 卸载 + 状态检测

### VZ 后端 bridged ⏳

需 `com.apple.vm.networking` entitlement 审批(2026-04-25 提交, 进行中)。落地步骤见 [ENTITLEMENT.md](ENTITLEMENT.md), 残余项见 [../v2/05-pending-from-v1.md](../v2/05-pending-from-v1.md) V-1。

## M5 — hvm-dbg 完整化 ✅

- 子命令: `screenshot / status / boot-progress / key / mouse / console / exec / ocr / find-text / wait / qemu-launch`
- `HVMIPC` 协议含文本/按键/鼠标 op
- VZ + QEMU 双后端串口通道(`dbg.boot_progress / console.read / console.write`)
- VZ + QEMU 共用 `BootPhaseClassifier / OCRTextSearch`
- Vision OCR 集成

## M6 — 打磨 🟡

- bugfix + 文档查漏补缺
- 当前 v2 收纳的 P-1 ~ P-4 polish 项
- `make build` + `make install` SOP 完善
- README 已对齐当前能力(2026-05-04 同步剪贴板 / cmd→ctrl / detached borderless)

## 重大跨 M 完成项

### QEMU 后端集成(横跨 M4–M6)✅

- `HVMQemu` 模块: `QemuArgsBuilder / QmpClient / QemuProcessRunner / SwtpmRunner / WindowsUnattend`
- 上游 patch:
  - `patches/qemu/0001-hvm-win11-lowram.patch` + `patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch` 配对(Win11 ARM64 装机)
  - `patches/qemu/0002-ui-iosurface-display-backend.patch`(macOS-only iosurface display backend, HDP v1.0.0)
  - `patches/qemu/0003-hw-display-hvm-gpu-ramfb-pci.patch`(Win 三态融合显卡)
- `HVMDisplayQemu`: HDP socket 客户端 + Metal 零拷贝 + vdagent 剪贴板 + 输入转发
- 进程独立 entitlement `app/Resources/QEMU.entitlements` 含 `com.apple.security.hypervisor`
- GPL 合规 `Resources/QEMU/MANIFEST.json + LICENSE`

### OS 镜像自动下载(2026-05-03)✅

- `HVMInstall.OSImageCatalog` 内置 7 个 arm64 Linux: Ubuntu 24.04 LTS / Ubuntu 22.04 LTS / Debian 13 / Fedora 44 / Alpine 3.20 / Rocky 9 / openSUSE Tumbleweed
- `OSImageFetcher`: catalog 下载 + custom URL 兜底 + SHA256 校验
- UI: `OSImagePickerDialog` (Linux 列发行版 / Windows 显示 Insider/UUP 提示) + `OSImageFetchDialog` (含 `verifying` 阶段)
- CLI: `hvm-cli osimage list / fetch / cache / rm`
- 缓存路径 `~/Library/Application Support/HVM/cache/os-images/<family>/`

### HVMUtils 重构(2026-05-03, P-5)✅

- 新建 `HVMUtils` SwiftPM target
- 收纳 `Format.bytes/rate/eta`(替 4 处重复)+ `Hashing.sha256Hex`(替 2 处)+ `ResumableDownloader`(IPSWFetcher 抽出, 给 OS 镜像共用)
- IPSWFetcher 改 wrapper, 行为不变

### 剪贴板共享 + macOS 风快捷键 + detached 窗口(2026-05-04)✅

- `HVMDisplayQemu.PasteboardBridge` 双向 UTF-8 文本同步, 走 vdagent virtio-serial
- VMConfig 新增 `clipboardSharingEnabled` + `macStyleShortcuts`(host cmd→guest ctrl)
- detached borderless 窗口重写, 与嵌入态切换稳定

## 持续项

- **文档与代码同步**: CLAUDE.md 约束变更 → docs/v1 同步 → 漂移登记 docs/v2/04-doc-drift.md
- **依赖审计**: 每季度检查 SwiftPM 三方依赖白名单(当前 `swift-argument-parser` + `Yams`)
- **安全审计**: team ID / 证书 SHA / 私钥路径 不出现在日志 / 报错文案

## 不做的事 (远期也不做)

(综合各模块"不做什么"章节, 以及根 CLAUDE.md "VZ 能力边界约束")

1. VZ 后端 Windows guest(VZ 无 TPM, Win11 装不上; Win10 ARM 已无 ISO 来源)
2. x86_64 / riscv64 guest(无 TCG 翻译)
3. 嵌套虚拟化
4. host USB 设备直通(VZ API 不支持)
5. 热插拔 CPU / 内存(VZ 不支持)
6. CPU / NUMA pinning
7. memory ballooning
8. VM live migration
9. 多 VM 共享同一 bundle(单进程 flock 互斥)
10. 插件系统 / 动态 dylib 加载
11. 多租户 / 权限系统
12. 远程管理(IPC 仅 Unix domain socket, 严禁 TCP listen)
13. 遥测 / 自动上报
14. 自更新(Sparkle)
15. App Store / TestFlight / Developer ID 公证
16. Homebrew / CocoaPods 等包管理(SwiftPM 唯一)
17. 浅色主题
18. Touch Bar 支持
19. 自定义磁盘格式(VZ raw + QEMU qcow2 是唯一组合)
20. 磁盘加密(依赖 FileVault)
21. VPN / WireGuard 集成
22. 端口转发管理
23. record/replay 宏
24. osascript UI scripting(详见根 CLAUDE.md "调试工作方式约束")

## 残余项指引

未完成项已统一迁到 [../v2/05-pending-from-v1.md](../v2/05-pending-from-v1.md):

- **V-1** Apple `com.apple.vm.networking` entitlement(等审批)
- **L-2** Rosetta share 集成
- **L-4** vmnet daemon 热重装时 QMP 热重连(方案 C, 已暂搁置)
- **P-1 ~ P-4** polish 项

完整未来动作清单见 [../v2/](../v2/) 各 P0/P1/P2 文件。

## 风险项

| 风险 | 等级 | 缓解 |
|---|---|---|
| `com.apple.vm.networking` 审批不通过或延迟 | 中 | QEMU socket_vmnet 已承接 bridged; ENTITLEMENT.md 有 AMFI 退路 |
| VZ API 在 macOS 新版本破坏性变更 | 低 | Apple 通常保兼容, deprecation 跟进 |
| QEMU 上游 v10.2.0 后续版本 patch rebase | 中 | patches/ 顺序由 series 文件管, 升级必须重测 |
| EDK2 stable202508+ 行为变化(Win11 boot 路径) | 低 | 锁定 stable202408, 升级前实测 |
| Vision OCR 在中文 / Win 控制台 误识 | 中 | 优先用 `hvm-dbg exec` (qga) 验证, OCR 仅截图肉眼对照 |

## 版本发布策略

- git tag `v0.1.0` / `v0.2.0` / ... 每个 M 结束打 minor tag
- 不做 release page(个人用)
- 不维护 CHANGELOG(commit log 即是)
- 不公证不分发, ad-hoc Apple Development 签名

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 全局模块视角
- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — QEMU 后端集成
- [ENTITLEMENT.md](ENTITLEMENT.md) — VZ bridged 前置依赖
- [todo.md](todo.md) — 已完成项历史
- [../v2/](../v2/) — 当前 TODO

---

**最后更新**: 2026-05-04
