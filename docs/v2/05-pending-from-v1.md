# 来自 v1 todo.md 的悬挂项

v1/todo.md 中的 7 项, 2026-05-04 重新核查代码现状后状态如下: **P-1 / P-4 已实际完成, L-4 已归档(描述过时), P-2 本轮顺手做完**。剩余 V-1 (阻塞) / L-2 / P-3 三项独立等触发。

---

## 🔴 阻塞中(等外部因素)

### [ ] V-1 · Apple `com.apple.vm.networking` entitlement

**现状**:
- 已向 Apple Developer Support 提交申请(2026-04-25),审批中
- [app/Resources/HVM.entitlements](../../app/Resources/HVM.entitlements) 中 `com.apple.vm.networking` 仍在 XML 注释里
- [app/Sources/HVMNet/NICFactory.swift](../../app/Sources/HVMNet) 仍无 `VZBridgedNetworkInterface` case

**审批通过后要做**:
- [ ] [HVM.entitlements](../../app/Resources/HVM.entitlements) 解开 `com.apple.vm.networking` 注释
- [ ] 嵌入 `embedded.provisionprofile`(审批回信指引)
- [ ] [NICFactory.swift](../../app/Sources/HVMNet) 加 `VZBridgedNetworkInterface` case
- [ ] GUI 创建向导网络段加 "桥接 (VZ)" 选项
- [ ] CLI `--network bridged:en0`(已是合法值,但 VZ 端会因 entitlement 缺失报错;审批后报错消失)

**跟 socket_vmnet 关系**: socket_vmnet 已让 QEMU 后端 bridged 网络可用,**不依赖此审批**。审批通过后 VZ 后端的 bridged 才能落,与 QEMU socket_vmnet 路径并存供选。

---

## 🔵 长期(大工程)

### [ ] L-2 · Rosetta share

**现状**:
- VZ 已有 API (`VZLinuxRosettaDirectoryShare`)
- [VMConfig.swift:260](../../app/Sources/HVMBundle/VMConfig.swift:260) 已有 `linux.rosettaShare` 字段(默认 false)
- ConfigBuilder 未集成,GUI/CLI 无开关

**要做**:
- ConfigBuilder Linux 分支装 Rosetta 共享
- 检测 host Rosetta 安装状态(若未装,GUI 提示去 Settings 装)
- GUI 创建向导 Linux 选项加 "启用 Rosetta(运行 x86_64 binary)" 开关
- CLI `--rosetta` 标志

**工作量**: ~200 行 + 实测。

**优先级**: 中低 — Linux ARM guest 不跑 x86_64 binary 也能用,有用户需求再做。

---

### [归档] ~~L-4 · vmnet daemon 热重装时 QMP 热重连(方案 C)~~

**归档原因**: **描述基于已下线的老 fd-passing 路径**。

当前架构(commit ac909b4 起):
- QEMU 直接 `-netdev stream,addr.type=unix,addr.path=...` 连固定路径 daemon socket
- 老的 `extraFdConnections + posix_spawn` fd 透传路径已下线([SidecarProcessRunner.swift:9](../../app/Sources/HVMQemu/SidecarProcessRunner.swift:9) 注释明确)
- daemon 重启后 socket 文件被替换,QEMU `-netdev stream` 持有的连接确实会断,但**痛点低频**(用户重装 daemon 是稀有事件,lima/colima 同款不做热重连)
- 现有方案 A(UI 拦截运行中 VM 时禁用按钮)+ 重启 VM 已够用

**决策**: 等真有用户痛点报告再重新评估,届时重写设计(老的 sendmsg+SCM_RIGHTS 方案不适用新路径)。

---

## ⚪ Polish / 低优

### [x] P-1 · Status / screenshot payload 编码助手 — 已完成

**实际状态**:
- [HVMIPC/Protocol.swift:65](../../app/Sources/HVMIPC/Protocol.swift:65) 已有 `IPCResponse.encoded(id:payload:kind:)` helper
- DbgOps + QemuHostEntry 全部走 `.encoded(...)`,**零 `JSONEncoder()` 残留**(grep 验证)
- 老 v1 todo 估计省 ~10 行,实际省 14 处重复模式(helper 注释已说明)

---

### [x] P-2 · `--engine qemu` flag 加 enum 校验提示 — 已完成 (commit 待落)

**实现**:
- 新建 [hvm-cli/Support/EngineArgument.swift](../../app/Sources/hvm-cli/Support/EngineArgument.swift): `extension Engine: ExpressibleByArgument {}`(同 package 内不需 @retroactive)
- [CreateCommand.swift:25](../../app/Sources/hvm-cli/Commands/CreateCommand.swift:25) `var engine: String?` 改 `Engine?`
- `resolveEngine` 简化:不再 throw / 不再手动 `Engine(rawValue:)`,ArgumentParser 在解析阶段已 fail-fast

**实测**:
```
$ hvm-cli create --name foo --engine xyz ...
Error: The value 'xyz' is invalid for '--engine <engine>'. Please provide one of 'vz' and 'qemu'.

$ hvm-cli create --help
  --engine <engine>       后端引擎: vz | qemu ... (values: vz, qemu)
```
`--help` 自动列 `(values: vz, qemu)`,体验比 hvm-cli 内手动 throw 好。

---

### [ ] P-3 · `qemu-build.sh --check` 模式

**现状**: 未做。

**要做**: `--dry-run` 只跑 preflight + ensure_homebrew + ensure_brew_packages,立即返回。

**优先级**: 极低 — `make qemu` 一辈子跑 1-2 次,投入产出不值。**等真有人折腾 brew 依赖反复跑预检时再做**。

---

### [x] P-4 · GUI + host 子进程 menu bar 双 status item 重复 — 已完成

**实际状态**(方案 A 已落地,与 v1 todo 描述一致):
- [main.swift:13](../../app/Sources/HVM/main.swift:13) 解析 `--gui-embedded` 标志
- [HVMHostEntry.swift:130](../../app/Sources/HVM/HVMHostEntry.swift:130) + [QemuHostEntry.swift:210](../../app/Sources/HVM/QemuHostEntry.swift:210) 各自 `if !embeddedInGUI { installStatusItem(...) }`
- [AppModel.swift:347](../../app/Sources/HVM/UI/App/AppModel.swift:347) `spawnExternalHost` 子进程 argv 注入 `--gui-embedded`
- 副作用 (GUI 中途退出 host 子进程 menu bar 入口消失) 当前未做缓解,实际场景罕见,等用户反馈再补 IPC "恢复 status item" 逻辑

---

## 完成判定

| 项 | 状态 |
|---|---|
| V-1 Apple bridged entitlement | 🔴 等审批 |
| L-2 Rosetta share | 🔵 中低优,等需求 |
| ~~L-4 vmnet 热重连~~ | ⚫ 归档(描述过时) |
| P-1 payload encode helper | ✅ 已完成 |
| P-2 `--engine` enum 校验 | ✅ 已完成 |
| P-3 `qemu-build --check` | ⚪ 极低优,未做 |
| P-4 menu bar 双 status item | ✅ 已完成 |

**剩余可做**: L-2 (Rosetta) + P-3 (qemu-build dry-run) — 都是按需触发型,不阻塞功能开发。

---

**最后更新**: 2026-05-04
