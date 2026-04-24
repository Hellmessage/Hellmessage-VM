# 路线图

## 里程碑一览

| 里程碑 | 目标 | 大致范围 | 关键交付 |
|---|---|---|---|
| **M0** | 项目骨架 | SwiftPM + Makefile + CLAUDE.md + docs | `make build` 能出空壳 .app |
| **M1** | CLI 起 Linux guest | `hvm-cli` 能创建并启动 Ubuntu arm64 | `hvm-cli create/start/stop` 可用 |
| **M2** | GUI 基础 | `HVM.app` 列表 + 向导 + 独立/嵌入运行窗口 | 用户完全不用 CLI 也能装机跑 VM |
| **M3** | macOS guest | IPSW 装机 + `VZMacOSInstaller` 流程 | 能装一台 macOS guest 跑起来 |
| **M4** | 桥接网络 | `com.apple.vm.networking` 审批通过后落地 | guest 在物理 LAN 有独立 IP |
| **M5** | hvm-dbg 完整化 | OCR / find-text / wait / exec 全量 | AI agent 能无 osascript 操控 guest |
| **M6** | 打磨 + 文档完善 | bugfix + 缺口补完 | 个人日常可用 |

以下只排优先级, 不排日期(个人项目, 按进展推进)。

## M0 — 项目骨架

### 范围

- `Package.swift`, `Makefile`, `scripts/bundle.sh`, `Resources/*`
- 所有 HVM* 模块目录创建, 只有 namespace 占位文件
- `HVMCore`: 空 `Logger` wrapper, 空 `HVMError` 根
- `HVM` target 出一个最小 SwiftUI 空窗口, 能被签名打包
- CLAUDE.md + docs/ 全部文档 ✅ (本轮已完成)

### 完成标准

```bash
git clone
make build
open build/HVM.app    # 空窗口, 黑色, 30 秒后退出
```

- `codesign -d --entitlements -` 能看到 `com.apple.security.virtualization`
- 无任何三方依赖(除 swift-argument-parser)
- Xcode `xed Package.swift` 能打开

## M1 — CLI 起 Linux guest

### 范围

1. `HVMBundle`: 读写 `config.json` v1, BundleLock 实现
2. `HVMStorage`: `DiskFactory.create/grow/delete`, ISO 路径校验
3. `HVMNet`: 仅 NAT, MAC 自动生成
4. `HVMBackend`: `VMHandle`, `start/stop/pause/resume`, NAT + Linux EFI 配置构建
5. `hvm-cli`:
   - `create` (Linux, 非交互式)
   - `list` / `status`
   - `start` (headless 模式)
   - `stop` / `kill`
   - `delete`
6. `HVMIPC`: 最小 socket 协议, state 订阅
7. 签名 / entitlement 接通

### 完成标准

```bash
hvm-cli create --name u1 --os linux --cpu 4 --memory 4 --disk 32 \
               --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso
hvm-cli start u1
# 进 guest 手动走安装器(通过 VZ serial console 或用 hvm-dbg screenshot 侧路观察)
# 安装完后:
hvm-cli boot-from-disk u1
hvm-cli stop u1
hvm-cli start u1
# 重启到已装系统
```

### 不做

- GUI 窗口 UI (M2)
- macOS guest (M3)
- 桥接网络 (M4)
- `hvm-dbg` 除 screenshot / status 外命令 (M5)

## M2 — GUI 基础

### 范围

1. `HVMDisplay`: `VZVirtualMachineView` 封装, 独立/嵌入切换
2. `HVM.app`:
   - 主窗口: 黑色主题, 列表 + 右栏详情
   - 创建向导(Linux 分支)
   - 独立运行窗口 ⇄ 嵌入态
   - ErrorDialog 统一弹窗
   - 设置窗口占位
3. GUI → IPC → VMHost 的启动联通
4. 缩略图生成 + 列表展示

### 完成标准

用户鼠标全程操作:
1. 打开 HVM.app
2. 点 `+` → 向导填 Linux VM 参数 → 创建
3. 向导结束后列表里出现 VM
4. 点 `Start` → 独立窗口出现 → 进 guest 装 OS
5. 点独立窗口 X → 嵌入主窗口
6. 点 `Stop` 正常关机
7. 列表 VM 缩略图更新

### 不做

- macOS 装机向导 (M3)
- 多显示器 / 高级显示设置 (延后)
- 剪贴板同步 (延后)

## M3 — macOS guest

### 范围

1. `HVMInstall`:
   - `VZMacOSRestoreImage.load` + `VZMacOSInstaller` 封装
   - IPSW 下载器(可选, 不做则用户自带)
   - auxiliary 数据生成与持久化
2. GUI 创建向导加 macOS 分支
3. `hvm-cli install foo` 对 macOS 全自动
4. 详情面板显示 IPSW 版本、是否 `autoInstalled`

### 完成标准

```bash
hvm-cli create --name mac1 --os macOS --cpu 4 --memory 8 --disk 80 \
               --ipsw ~/Downloads/UniversalMac_*.ipsw
hvm-cli install mac1     # 全自动安装, 进度条
hvm-cli start mac1       # 进首次启动向导 → 设用户密码 → 桌面
```

或在 GUI 里全程点鼠标完成。

### 不做

- Rosetta share(延后到 M4/M5 窗口)

## M4 — 桥接网络

### 触发条件: Apple 审批通过

### 范围

1. 更新 `Resources/HVM.entitlements` 启用 `com.apple.vm.networking`
2. 嵌入 `embedded.provisionprofile`
3. `HVMNet.BridgedAttachment` 启用
4. GUI 创建向导网络页加 "桥接" 选项 + 接口选择下拉
5. CLI `--network bridged:en0`
6. 运行时 fallback: entitlement 没到位 → `bridged_not_entitled` 错误 + 向导灰掉桥接

### 完成标准

```bash
hvm-cli create --network bridged:en0 ...
# guest 在物理 LAN 得 192.168.1.x IP, host 与 guest 互 ping, 从第三台机子也能 ssh guest
```

## M5 — hvm-dbg 完整化

### 范围

1. `hvm-dbg` 全子命令:
   - `screenshot` / `status` / `boot-progress`
   - `key` / `mouse`
   - `console` / `exec`
   - `ocr` / `find-text`
   - `wait`
2. `HVMIPC` 协议扩展(文本/按键/鼠标事件 op)
3. 集成 `Vision` OCR
4. 示例 agent loop 文档

### 完成标准

```bash
# 不用 osascript, 用 hvm-dbg 完成:
hvm-dbg wait mac1 --for text --match "Sign In" --timeout 120
center=$(hvm-dbg find-text mac1 "Sign In" | jq -r '.center | "\(.[0]),\(.[1])"')
hvm-dbg mouse mac1 click --at "$center"
hvm-dbg key mac1 --text "mypassword"
hvm-dbg key mac1 --press "Return"
```

### 不做

- guest agent 协议(见 DEBUG_PROBE.md 不做什么)
- 剪贴板同步 (K1 未决事项, 按需要再说)

## M6 — 打磨

### 范围

- 各模块补充测试
- 日志轮转实现
- 缩略图异步加载优化
- 文档查漏补缺
- 打开 GitHub issue 按优先级修 bug
- 给 README.md 写安装/使用说明(此前一直是空的)

## 持续项(不属于任何里程碑)

- **文档与代码同步**: CLAUDE.md 约束变更 → docs/ 同步更新 → 代码对齐
- **Xcode 16 / macOS 15 / Swift 6 新 API 跟进**: 新的 VZ API 出现时评估是否采纳
- **依赖审计**: 每季度检查 swift-argument-parser 是否仍是唯一依赖
- **安全审计**: 敏感字段过滤 (team ID / 证书 / 私钥) 不被日志泄露

## 不做的事 (远期也不做)

(综合各模块 "不做什么" 章节, 便于一眼览看)

1. Windows guest 支持
2. x86_64 / riscv64 guest 支持
3. 嵌套虚拟化
4. host USB 设备直通
5. 热插拔 CPU / 内存
6. CPU / NUMA pinning
7. memory ballooning
8. VM live migration / save-state snapshot
9. 插件系统 / 动态 dylib 加载
10. 多租户 / 权限系统
11. 远程管理 (TCP listen)
12. 遥测 / 自动上报
13. 自更新 (Sparkle)
14. App Store / TestFlight / Developer ID 公证
15. Homebrew / CocoaPods / 其他包管理
16. 浅色主题
17. Touch Bar 支持
18. 自定义磁盘格式 (qcow2 / vmdk / vdi)
19. 磁盘加密 (依赖 FileVault)
20. 多 VM 共享单磁盘
21. VPN / WireGuard 集成
22. 端口转发管理
23. GUI 拖拽文件入 guest
24. record/replay 宏
25. osascript UI scripting

## 风险项

| 风险 | 等级 | 缓解 |
|---|---|---|
| `com.apple.vm.networking` 审批不通过或延迟 | 中 | MVP 只走 NAT, 桥接作增量; ENTITLEMENT.md 有退路(AMFI) |
| VZ API 在 macOS 新版本破坏性变更 | 低 | Apple 通常保兼容, 但 API deprecation 要跟进 |
| `VZVirtualMachineView` 截图 API 不稳定 | 低 | DISPLAY_INPUT.md K4 有备选方案 |
| guest 内时钟 / 随机数等质量问题 | 低 | 标配 entropy 设备 + VZ 时间同步 |
| AI agent 依赖的 OCR 在 non-Latin 文字下准确率 | 中 | Vision framework 多语言支持良好, 但需实测 |

## 版本发布策略

- 用 git tag 打 `v0.1.0` / `v0.2.0` / ...
- 每个 M 结束打一个 minor tag, 补丁修复打 patch
- 不做 release page, 个人用
- 不维护 CHANGELOG(commit log 即是)

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 全局模块视角
- [ENTITLEMENT.md](ENTITLEMENT.md) — M4 前置依赖
- 各模块文档 — 每个 M 的实现细节分散其中

---

**最后更新**: 2026-04-25
