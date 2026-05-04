# 加密长事务 SIGINT 清理 (encrypt / decrypt / rekey)

> 状态: **代码已合入 (2026-05)** (PR-C SignalGuard). 现状回写 [../v1/ENCRYPTION.md](../v1/ENCRYPTION.md) "长事务 SIGINT 防中断" 节.
>
> 父设计稿: [ENCRYPTION.md](ENCRYPTION.md) (代码已合入)
> 关联 TODO: [TODO.md](TODO.md) #19 — 已 Done

## 背景

`hvm-cli encrypt / decrypt / rekey` 是**长事务**, 实际跑下来 5s ~ 数分钟 (取决于盘大小):

- `encrypt`: 每盘 `qemu-img convert` raw/qcow2 → LUKS qcow2, 全盘加密一次
- `decrypt`: 每盘 `qemu-img convert` LUKS qcow2 → qcow2/raw, 全盘解密一次  
- `rekey`: LUKS keyslot amend 两步法 + 重写 config.yaml.enc + 改 routing JSON salt

中途 Ctrl-C 会留下问题:
- **encrypt**: 部分盘已转完 LUKS, 但 config.yaml 还没替换 → bundle 处于"半加密"状态. 下次启动既不能按明文起 (config 还是明文但 disk 已 LUKS), 也不能按加密起 (没 routing JSON)
- **decrypt**: 部分盘已解密成 qcow2, 但 config.yaml.enc 还在 → 同样卡半路
- **rekey**: keyslot 已切到新密码但 config.yaml.enc 还是老 sub.config 加密的 → 用户两个密码都解不开

加上 Swift 的 `defer` 在 SIGINT 默认行为下**不一定执行** (signal handler 直接 exit, 不走 stack unwind). 所以临时目录 `.encrypting-<8>/` / `.decrypting-<8>/` / 临时 secret 文件可能残留.

## 目标 + 范围

**做**:
- 拦 SIGINT (Ctrl-C) + SIGTERM, 让长事务 **不可中断** — 打印警告 "操作进行中, 请等待结束 (X 秒后强制结束 ...)" 后继续跑完
- 强制超时上限保底: 第二次 SIGINT 在短窗口 (5s) 内重复出现 → 真退出, 但前打印明确"残留可能"清理建议
- 残留路径在 main exit 时尝试 best-effort 清理 (即便事务跑完了, 也不留 `.encrypting-*` 这种半路目录)

**不做**:
- 不做"checkpoint cancellation" (在安全点检查 cancel flag 优雅退出): 实现复杂, 收益有限. 操作通常 < 30s, 用户等就好
- 不拦其他命令的 SIGINT (`start / status / list / config get` 等): 短命令 + 无副作用, 现状 default 行为 (直接 exit) 没问题
- 不做 launchd / 系统级看门狗

## 选型对比

| 方案 | 实现 | 用户体验 | 数据安全 | 工作量 | 选用 |
|---|---|---|---|---|---|
| **A. 拦 SIGINT 不可中断 + 二次按真退出** | sigaction 注 handler, 设全局 atomic, 打印警告 + 继续跑; 二次 ≤5s 内则 exit(130) | 第一次 Ctrl-C 看到警告 "等等 ..."; 二次按真退 (用户自负) | 良 — 单 Ctrl-C 不破坏 | 小 — 一个 SignalGuard 模块 + 加几行 main | ✅ |
| B. checkpoint cancellation | EncryptVMOperation 在每盘转换前后 check flag, cancel 时回滚已完成的盘 | 体验顺 (秒级响应 Ctrl-C) | 中 — 回滚逻辑本身复杂, 可能引新 bug | 大 — 三个 Operation 都改 + 回滚路径 | ✗ |
| C. 不拦, 现状 (defer 不跑) | 保持现状 | 用户单按 Ctrl-C 直接残留 | 差 | 0 | ✗ |

**选 A**. 理由:
- 加密事务 5s ~ 数分钟. 拦截后用户等的代价小; checkpoint 实现代价大
- 一次 Ctrl-C 给警告 + 二次硬退是 Unix 用户熟悉模式 (例: `git commit` 中途 Ctrl-C 第二次才退)
- 配合 main exit 期 best-effort cleanup, 即使硬退也尽量清残留

## 实现要点

### SignalGuard 模块

`HVMCore/SignalGuard.swift` (新增):

```swift
public enum SignalGuard {
    /// 注 SIGINT + SIGTERM handler. 进入 "保护期" 后第一次信号打印警告, 二次 ≤5s 内 exit(130).
    /// 重复调用 install() 复位计数.
    public static func install(message: String = "操作进行中, 请等待结束; 再次 Ctrl-C 强制退出 (可能留残留)")

    /// 解除保护. 后续信号走默认行为.
    public static func uninstall()

    /// 注册 cleanup 回调. main exit 期 + 二次硬退期 best-effort 调用.
    /// 回调本身必须无锁 / 不阻塞 (signal handler 上下文 async-signal-safe 限制).
    public static func registerCleanup(_ block: @escaping () -> Void)
}
```

实现关键点:
- 用 sigaction(2), 不用 Swift `signal()` (signal 行为不一致)
- handler 内只设 atomic flag + 写 stderr (write(2) 是 async-signal-safe). 不分配内存, 不调 Swift 标准库
- 主线程或事务函数定期 check flag (实际上不 check; 跑完 finally cleanup)
- cleanup 回调用 `atexit(3)` 注册 → main 正常退出也跑

### 三个 Operation 接入

EncryptVMOperation / DecryptVMOperation / RekeyVMOperation 各自:

```swift
public static func encrypt(...) throws -> Result {
    SignalGuard.install()
    SignalGuard.registerCleanup {
        try? FileManager.default.removeItem(at: tmpDir)
        // ... 其他 best-effort 清理
    }
    defer {
        SignalGuard.uninstall()
        // 同步清理: 跟 cleanup 回调里同样的逻辑, 但走 throw 路径
    }
    // ... 现有事务逻辑
}
```

注意: defer 与 atexit cleanup 都跑同样动作时要 idempotent (FileManager.removeItem 对已删路径 silently noop, OK).

### CLI 入口

hvm-cli main 不需要改 — 各 Operation 内部 install/uninstall. 但需要确保 `EncryptCommand.run` / `DecryptCommand.run` / `RekeyCommand.run` 在 Operation 跑期间不被外层 ArgumentParser 干扰. 简单 review 一遍.

## 风险与待验证项

| 编号 | 风险 | 验证方式 | 阻断 |
|---|---|---|---|
| **R1** | sigaction handler 内调用非 async-signal-safe 函数 → undefined behavior | 严格只用 write(2) + atomic + _exit. 不调 print / Swift API | P0 |
| R2 | 二次 Ctrl-C 间隔判断的 monotonic clock 选 | clock_gettime(CLOCK_MONOTONIC); 不能用 Date | P1 |
| R3 | atexit cleanup 在 abort/SIGKILL 不跑 | 接受. 文档说明 "kill -9 不保证清理, 用 hvm-cli 工具手动清残留" | 已决 |
| **R4** | 用户正常 stdin 输完密码后 SIGINT 中断 PasswordPrompt → readpassphrase 退出码 | readpassphrase 自身处理; 不在 SignalGuard 范围. SignalGuard 只在 Operation 期保护 | 已论证 |
| R5 | 多线程 / async — install 是否要 reentrant | 三个 Operation 串行, 不会嵌套. install/uninstall 同 reentrant 计数兜底 | 已论证 |

## 落地拆解 (PR 切分)

| PR | 内容 | 时间盒 | 状态 |
|---|---|---|---|
| **PR-A** | `HVMCore/SignalGuard.swift` 模块 + 单测 (signal 触发 + cleanup 跑) | 0.5 天 | 待开 |
| **PR-B** | EncryptVMOperation / DecryptVMOperation / RekeyVMOperation 接入 SignalGuard. 真机验证: 跑加密时 Ctrl-C → 看到警告 + 跑完; 二次 Ctrl-C → exit + 残留可清 | 0.5 天 | 待开 |
| **PR-C** | docs: TODO.md #19 标 Done | 0.1 天 | 与 PR-B 合 |

合计 ~1 天 / 1 人. PR-A / PR-B 串行 (B 依赖 A).

## 未决事项

| 编号 | 问题 | 当前默认 | 决策时机 |
|---|---|---|---|
| D19 | 二次 Ctrl-C 的窗口期 | 5s (Unix 用户预期范围) | 已决 (本稿) |
| D20 | exit code | 第一次 Ctrl-C 不退出, 跑完正常 0/非 0; 二次硬退用 130 (= 128 + SIGINT) | 已决 |
| D21 | 是否给 GUI 也接 (取消按钮) | 不接 — GUI 用 modal "操作进行中" 不可关 + IPC 实施超时 (后续 PR-11 GUI 范围) | 已决 |
| D22 | 是否记录 Ctrl-C 事件到 host log | 是 — `os.Logger` info 一行 "user pressed Ctrl-C during encrypt" | 已决 |

## 设计变更日志

### 2026-05-04 v1 — 本稿

初稿. 关键决策:
- 选方案 A: 第一次 Ctrl-C 警告 + 不可中断, 二次 ≤5s 硬退
- atexit cleanup 兜底 main 退出路径
- checkpoint cancellation (方案 B) 推后, 不在本稿

## 相关文档

- 父稿 [ENCRYPTION.md](ENCRYPTION.md) v2.4
- TODO 索引 [TODO.md](TODO.md) — #19
- 实现参考: [HVMEncryption/EncryptVMOperation.swift](../../app/Sources/HVMEncryption/EncryptVMOperation.swift) / [DecryptVMOperation.swift](../../app/Sources/HVMEncryption/DecryptVMOperation.swift) / [RekeyVMOperation.swift](../../app/Sources/HVMEncryption/RekeyVMOperation.swift)
