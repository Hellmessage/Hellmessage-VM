# QEMU 加密 — BUG / 遗漏清单 (PR-10b 后)

> 状态: **TODO 清单 v1 (2026-05-04)** — PR-1 ~ PR-10b 已落 + 真机端到端验证 (encrypt → status → encrypt-status → rekey 新/老密码 → decrypt → 明文启动) 全闭环. 本稿沉淀剩余的 BUG / 功能洞 / 安全加固 / 文档同步项, 按优先级分组.
>
> 父设计稿: [ENCRYPTION.md](ENCRYPTION.md) v2.4 (QEMU 路径优先实施).
>
> **范围**: 仅覆盖 QEMU 加密路径. VZ 加密接入 (sparsebundle) 推后, 不在本清单内.

## 当前已落地能力 (基线)

PR-1 ~ PR-10b 全部合入. 覆盖:

- **底层**: SparsebundleTool / MasterKey / PasswordKDF / EncryptionKDF / EncryptedConfigIO / QcowLuksFactory / OVMFVarsLuksFactory / LuksSecretFile / SwtpmKeyHelper / MountReaper / EncryptedBundleIO + RoutingMetadata.
- **后端接入**: VMHost stdin password Pipe / detectScheme 路由 / QemuArgsBuilder LUKS argv + secret 注入 / QemuHostEntry 接 EncryptedBundleIO.unlock.
- **CLI**:
  - `hvm-cli create --encrypt` (新建加密 VM)
  - `hvm-cli encrypt <vm>` (PR-10a, 老明文 → 加密)
  - `hvm-cli decrypt <vm>` (PR-10b, 加密 → 明文)
  - `hvm-cli rekey <vm>` (PR-10b, 改密)
  - `hvm-cli encrypt-status <vm>` (PR-10b, 不解密查 routing JSON)
  - `hvm-cli status` (PR-10b 适配加密 VM, 走 routing + IPC merge)
  - `hvm-cli list` (走 routing 显示加密 VM)
  - `hvm-cli start` (PasswordPrompt + HostLauncher stdin Pipe)
- **真机验证**: 跨机器 cp + 同密码 unlock 通过; rekey 后老密码失效新密码可用; decrypt 后明文 Win11 + Linux 启动正常.

## 优先级分组

### 🔴 高优先级 — 用户日常运维必碰 (CLI 适配缺失)

加密 VM 在 PR-10b 之后能 `start / stop / status / list / encrypt-status`, 但下面这些子命令仍按"明文 VM"假设走代码, 撞到加密 VM 会报错或行为不正确.

| # | 项 | 现状 | 期望 | 影响文件 |
|---|---|---|---|---|
| 1 | `hvm-cli config <vm>` 加密适配 | 直接 `BundleIO.load` 读 config.yaml — 加密 VM 是 `config.yaml.enc`, 报 fileNotFound | 检 detectScheme; 若加密则 PasswordPrompt + EncryptedConfigIO.load 临时解密只读展示, **禁止落盘** | [ConfigCommand.swift](app/Sources/hvm-cli/Commands/ConfigCommand.swift) |
| 2 | `hvm-cli disk <vm> resize` 加密适配 | `DiskFactory.grow` 走 qemu-img resize, 对 LUKS qcow2 需要 `--object secret` + `encrypt.key-secret=sec0` 才行, 现路径不传 secret → qemu-img 报错或破坏 LUKS header | 检 detectScheme; 加密则走 unlock + LuksSecretFile + 调 `QcowLuksFactory.grow` (PR-4 已实现) | [DiskCommand.swift](app/Sources/hvm-cli/Commands/DiskCommand.swift), QcowLuksFactory |
| 3 | `hvm-cli iso <vm>` 加密适配 | 改 ISO 路径需要重写 config.yaml — 加密 VM 撞 BundleIO.load fileNotFound | 检 detectScheme; 加密则 unlock + 改 config + EncryptedConfigIO.save | [IsoCommand.swift](app/Sources/hvm-cli/Commands/IsoCommand.swift) |
| 4 | `hvm-cli boot-from-disk <vm>` 加密适配 | 同上, 改 `bootFromDiskOnly` 字段需要写 config — 加密 VM 报错 | 同上 unlock + EncryptedConfigIO.save | [BootFromDiskCommand.swift](app/Sources/hvm-cli/Commands/BootFromDiskCommand.swift) |
| 5 | `hvm-cli logs <vm>` / `kill` / `pause` / `resume` 验证 | 这几个命令走 BundleLock + IPC, 理论上不读 config.yaml, 应该兼容. **未真机验证** | 真机跑一遍加密 VM 上的 logs / kill / pause / resume, 确认无 BundleIO.load 隐式调用 | [LogsCommand.swift](app/Sources/hvm-cli/Commands/LogsCommand.swift), KillCommand, PauseCommand, ResumeCommand |

**估时**: 0.5 天 (1-4 各 1-2 小时 + 5 半小时验证).

**做法约束**:
- **临时解密的 config 不落盘** — 只在内存里改完, 直接 `EncryptedConfigIO.save` 重写 `.enc`, 中间不留任何明文 yaml
- 改完都过一遍 `make build` + 真机加密 VM 实跑

### 🟡 中优先级 — 安全加固 + 测试 + GUI

| # | 项 | 现状 | 期望 | 影响 |
|---|---|---|---|---|
| 6 | LUKS secret file 落盘风险 | 当前走 `NSTemporaryDirectory()/0600 文件` + 不立即 unlink (QEMU lazy-read 限制). 进程崩溃时残留, 攻击者拿到能解 LUKS | (a) FIFO 替代 file (QEMU 支持 `file=fifo:<path>`?? 待验证); 或 (b) ramfs/tmpfs 强制内存; 或 (c) 退而求其次缩 unlink 窗口到 QEMU bind 后立即 unlink | LuksSecretFile, QemuArgsBuilder, QemuHostEntry |
| 7 | master key / sub key in-memory 防 swap | Swift `SymmetricKey` / `Data` 默认可被换出到 swap, 攻击者能从 swapfile 抠 key | mlock(2) 包装 `SymmetricKey` 内存; SecureErase 复用类似 helper | MasterKey, EncryptionKDF, SwtpmKeyHelper |
| 8 | 多盘 (data disk) encrypt / decrypt / rekey 真机验证 | encrypt / decrypt / rekey 代码循环了 `config.disks`, 但**真机只跑过单盘 (主盘)**. 多盘场景 (主 + 数据盘) 端到端没测 | 创建 1 主 + 1 数据盘 Linux/Win VM → encrypt → 真启动 → rekey → decrypt → 真启动, guest 内能挂载读写两盘 | EncryptVMOperation, DecryptVMOperation, RekeyVMOperation |
| 9 | 完整 boot 验证 (装机后 reboot) | 加密 Linux 装机 + 加密 Win11 装机已通过, 但**装机完成 → reboot → 重新输密码 → 正常启动到桌面**这个完整路径没跑全程 | 跑一次完整生命周期, 截图归档 (供 v1/SECURITY.md 使用) | 真机测试 |
| 10 | GUI 加密 (PR-11) 未落 | CLI 全闭环, GUI 还按"明文 VM"假设. 用户 GUI 创建 / 启动 / 详情都不知加密这条路 | (a) Create wizard 加 "加密" checkbox + 双密码框; (b) start 期密码 modal; (c) 详情页显示加密状态 + KDF 信息; (d) encrypt / decrypt / rekey 入口按钮; (e) 弹窗走 HVMModal, 表单走 HVMTextField + HVMToggle | UI/Content/CreateWizard, UI/Dialogs, UI/App/AppModel, **新增** UI/Dialogs/EncryptionPrompt |
| 11 | `hvm-cli delete <vm>` 加密 secure-erase | 当前 `delete` 直接 `rm -rf bundle`, 加密 VM 删除后磁盘上仍可能 ciphertext 残留 (APFS COW + free block 不擦) | 加密 VM delete 时 (a) 提示 "已加密,删除后 ciphertext 仍在 free 块,理论上可恢复 — 想要彻底清擦请选 secure delete"; (b) 选 secure delete 走 SecureErase 单遍 random (现有). 或干脆默认 secure | DeleteCommand, SecureErase |
| 12 | rekey 半成功原子性 | rekey 流程: (1) 各 LUKS keyslot amend old→new (2) 重写 config.yaml.enc (3) 重写 routing JSON. 第 2 / 3 步崩溃 → keyslot 是新密码, 但 routing salt 或 config.enc 是老 key 派生的, 不一致. 用户用旧也不行用新也不行 | 加 .rekey-staging 临时目录 (类似 decrypt), 全部成功后 atomic rename. 失败回滚 keyslot (再 amend new→old). 或更简单: 写 rekey-journal (记录已切换的 keyslot 数量), 启动期检测残留 journal 提示 | RekeyVMOperation |
| 13 | encrypt / decrypt 中途崩溃恢复 | encrypt: 部分 disk 转完 LUKS, config.yaml 还没替换 → 用户拿到"半加密 VM" (能 list 但启动不了). decrypt: 同理 | encrypt: 临时目录 `.encrypting-<8>` 落地 + atomic rename, 失败留临时目录 + 主 bundle 不动 (decrypt 已是这模式). encrypt 现状: 先转再替换, 但**临时目录策略**没像 decrypt 那么清晰. 审一遍 encrypt 流程; 必要补齐 | EncryptVMOperation |

**估时**: 6 + 7 = 1 天; 8 + 9 = 0.5 天; 10 = 3 天 (GUI 大头); 11-13 = 1.5 天.

### 🟢 低优先级 — 边角 / 推后

| # | 项 | 现状 | 期望 | 备注 |
|---|---|---|---|---|
| 14 | 加密 VM clone 支持 | D9 未决. 当前 clone 走 APFS clonefile, **加密 VM clone 后两 VM 共用同一 master key + 同一 LUKS keyslot**, 一个改密另一个跟着走 (同 file inode) | 设计期: (a) 拒绝克隆 (最简); (b) clone 后强制 rekey (派生新 master key + 重写所有 keyslot + 重密 config); (c) 用户选择. 决策时机: 用户实际碰到再说 | CloneManager |
| 15 | 加密 VM snapshot 支持 | 当前 SnapshotCommand 走 qcow2 internal snapshot, LUKS qcow2 是否支持 internal snapshot **未验证**. qemu-img snapshot 对 encrypted qcow2 的行为待真跑 | 真机跑 `hvm-cli snapshot create / list / revert` 在加密 VM 上, 看 qemu-img 报不报错 | SnapshotCommand |
| 16 | `hvm-cli disk import-disk + encrypt` | 用户从其他工具导入 raw .img 做新 VM, 创建期能不能直接加密? 当前 `create --encrypt` 只支持新建空盘 | 加 `create --import-disk <path> --encrypt` 路径 (qemu-img convert raw → LUKS qcow2 同 encrypt 命令) | CreateCommand, EncryptVMOperation 复用 |
| 17 | macOS guest 加密路径 | macOS guest 必走 VZ, VZ 加密接入推后. 当前 macOS VM 不能加密 (`create --encrypt` 强制 engine=qemu) | 待 VZ 加密接入 PR (sparsebundle 路径), 不在 QEMU 范围 | docs/v3/ENCRYPTION.md 双路径 VZ 分支 |
| 18 | swtpm rewrap 支持 | 当前 rekey / decrypt 强制重置 TPM (BitLocker recovery key 全丢). swtpm 0.10 没 rewrap 工具. 上游若加 rewrap → 我们可保留 TPM state | 监控 swtpm release notes; 等上游有了再适配. **不在我们能解决的范围内** | SwtpmKeyHelper |
| 19 | Ctrl-C 期间清理 | `hvm-cli encrypt / decrypt / rekey` 进行中 Ctrl-C → 临时目录残留, secret 文件可能残留. 当前 defer 不一定跑 (Swift 信号处理) | 注 SIGINT handler → 显式清残留 + exit. 或干脆"不可中断, 提示用户等" | Encrypt/Decrypt/RekeyVMOperation, hvm-cli main |

**估时**: 各 0.5-2 天; 优先级最低, 等用户实际反馈再排.

### 📚 文档同步 — 治理义务

| # | 项 | 当前 | 应做 |
|---|---|---|---|
| 20 | v1 文档回写 | docs/v1/STORAGE.md / VM_BUNDLE.md / CLI.md 没提加密路径; 设计稿在 v3 静默 | (a) v1/STORAGE.md 加 "加密 VM 磁盘形态" 节; (b) v1/VM_BUNDLE.md 加加密 bundle 结构 (config.yaml.enc / meta/encryption.json / nvram/*.qcow2); (c) v1/CLI.md 加 6 个加密命令; (d) **新建 v1/SECURITY.md** 总述威胁模型 + 双路径保护等价 |
| 21 | CLAUDE.md 加密约束节 | CLAUDE.md 没加密相关硬约束 | 加 "加密约束" 节: 必须 password every time / 不缓存 / 跨机器 portable / 不引第三方 crypto / config.yaml.enc 唯一格式 / LUKS passphrase 强制 base64 / TPM 重置后果 / VZ 加密暂未接入 |
| 22 | README.md 提及加密能力 | README 当前说"VM 管理 + 双后端", 没 mention 加密 | 加 "VM 加密 (QEMU 后端)" 一段, 链回 docs/v3/ENCRYPTION.md |

**估时**: 1 天 (主要是 v1/SECURITY.md 起草).

## 推荐处理顺序

1. **🔴 1-5 (CLI 适配缺失)** — 0.5 天 — 用户最常碰到的实际功能洞, 做完日常运维顺
2. **🟡 6-7 (secret fifo + key mlock)** — 1 天 — 安全加固, 不影响功能但减少 attack surface
3. **🟡 8-9 (多盘 + 完整 boot 真机验证)** — 0.5 天 — 实测覆盖
4. **🟡 10 (GUI PR-11)** — 3 天 — GUI 用户场景闭环
5. **🟡 11-13 (delete secure-erase + rekey/encrypt 原子性)** — 1.5 天 — 灾难恢复
6. **🟢 14-19 (边角)** — 按用户反馈排
7. **📚 20-22 (文档)** — 1 天 — 合并到 PR-12 一起做

## 状态字段

| 状态 | 含义 |
|---|---|
| `Pending` | 已识别, 未开始 |
| `In progress` | 实施中 (commit 在 develop 分支) |
| `Done` | 已合入, 真机验证过 |
| `Postponed` | 推后 (等用户反馈 / 上游能力 / 其他依赖) |

| # | 项 | 状态 | 备注 |
|---|---|---|---|
| 1 | hvm-cli config 加密适配 | Done | 🔴, 走 EncryptedConfigEditor |
| 2 | hvm-cli disk list/add/resize/delete 加密适配 | Done | 🔴, add/resize 走 QcowLuksFactory |
| 3 | hvm-cli iso 加密适配 | Done | 🔴, 走 EncryptedConfigEditor |
| 4 | hvm-cli boot-from-disk 加密适配 | Done | 🔴, 走 EncryptedConfigEditor |
| 5 | logs/kill/pause/resume 加密 VM 验证 | Done | 🔴, kill/pause/resume 仅 IPC 不读 config; logs 走 routing JSON 不需密码; 真机 e2e 已跑 |
| 6 | LUKS secret 缩 unlink 窗口 | Done | 🟡, QMP 连接成功后立即 unlink (从 VM 全生命周期 → 启动期秒级). fifo 推后 (现状已够) |
| 7 | master key mlock | Done | 🟡, SecureBytes (mlock + memset_s) 包 MasterKey. SubKeySet (CryptoKit SymmetricKey) 不动 |
| 8 | 多盘 encrypt/decrypt/rekey 真机 | Done | 🟡, MultiDiskTest VM (1主64G + 1数据4G) e2e: encrypt/rekey/decrypt/start 全过 |
| 9 | 装机 → reboot → 桌面完整生命周期 | Pending | 🟡 |
| 10 | GUI 加密 (PR-11) | Done (待自动化测) | 🟡, PR-11a-e 已落: VMListItem 重构 / 启动密码 modal / CreateVMDialog 加密 toggle / CloneVMDialog 加密源 / 详情页加密区 + Encrypt/Decrypt/Rekey 三 dialog. 真机 e2e (PR-11f) 走 PR-G GUI 协议自动化测 |
| 11 | delete secure-erase | Done | 🟡, hvm-cli delete --purge 加密 VM 默认走 SecureErase; 明文 VM 加 --secure-erase opt-in |
| 12 | rekey 原子性 | Done | 🟡, **重排顺序**: 全部 addNewKeyslot → atomic write config+routing (replaceItemAt) → 全部 removeOldKeyslot. 任何 crash 点都能用一个密码解 |
| 13 | encrypt 临时目录策略对齐 | Done | 🟡, encrypt 替换阶段改 "rename .old-encrypt → mv 新 → secure-erase 旧"; mv 失败回滚 |
| 14 | 加密 VM clone | Done | 🟢→🔴 升级, D9=方案 A 同密码 + 整字节复制. CloneManager 加密分支 + GUI 暂未接入 (PR-11) |
| 15 | 加密 VM snapshot | Done | 🟢, 顺带修 SnapshotManager qcow2 老 bug (PR-1 起所有 QEMU VM snapshot 都是空) |
| 16 | create --import-disk --encrypt | Postponed | 🟢, 等用户需求 |
| 17 | macOS / VZ 加密 | Postponed | 🟢, 等 VZ PR |
| 18 | swtpm rewrap | Postponed | 🟢, 等上游 |
| 19 | Ctrl-C 中断清理 | Done | 🟢, HVMCore/SignalGuard.swift 第一次警告不退 + 5s 内二次 _exit(130) + atexit cleanup 兜底 |
| 20 | v1 文档回写 (含 SECURITY.md 新建) | Pending | 📚, 合 PR-12 |
| 21 | CLAUDE.md 加密约束节 | Pending | 📚, 合 PR-12 |
| 22 | README.md 提及加密 | Pending | 📚, 合 PR-12 |

## 🛠 工具链 / 测试基建 (新增类别)

| # | 项 | 状态 | 备注 |
|---|---|---|---|
| **G1** | hvm-dbg GUI 测试协议 (HDP-GUI) | Done | 🛠, 用户提议 2026-05-04. PR-G1 (probe server + screenshot) / PR-G2+G3 (ProbeRegistry + gui list/click/type/read) / PR-G5 (PR-11 dialog 补 .hvmProbe). **D-G2 决策变更**: 弃 NSAccessibility 路径, 走自家 closure 注册表 (SwiftUI a11y 不暴露给程序内查询; ProbeRegistry 直接 closure 调用更稳). PR-G4 (event subscribe) 推后 (YAGNI). 真机 e2e: hvm-dbg gui 自动化跑通 Win11 → encrypt → decrypt 全 GUI 链路 |

## 🔍 代码审计 (2026-05-04) — 中/低/安全/约束/优化项

> 来源: 全 `app/Sources/` (排除 Tests) 静态审计 (~36K 行 Swift/C). 高严重 BUG 已在 commit 中修复 (5 项落地, 3 项确认误报). 下表是非阻塞但应排日程清掉的项. 编号 A-* 是 audit, 跟主 TODO 数字号区分.

### A. 中严重 BUG

> 状态更新 (2026-05-04 第二轮): A 节 11 项中, 实修 5 项 + 误报 5 项 + 重复主 #12 1 项. 详见 status 列.

| # | 项 | 文件 | 状态 | 备注 |
|---|---|---|---|---|
| A1 | IPC `Frame` 16MB 上限过宽 | [Frame.swift:9](app/Sources/HVMIPC/Frame.swift) | **Done** | 收紧到 8 MiB (`Frame.maxPayloadBytes`); 满足 console 256KB / screenshot 5K 显示器 ≈ 5.5MB / 普通命令几 KB |
| A2 | `IPSWFetcher` 按 `postingDate` 去重 | [IPSWFetcher.swift:219](app/Sources/HVMInstall/IPSWFetcher.swift) | **误报** | 实际已用 `dedup[e.buildVersion]` 作主键, postingDate 仅作版本选择 |
| A3 | `ConsoleBridge.appendChunk` 内 `logHandle == nil` 判断与 open 之间有窗口竞态 | [ConsoleBridge.swift:153](app/Sources/HVMBackend/ConsoleBridge.swift) | **误报** | 整个函数体在 `lock.lock(); defer { lock.unlock() }` 内, 检查+open+write 都原子 |
| A4 | `MacInstaller` `defer { consoleBridge.close() }` 在装机过程中过早关 console | [MacInstaller.swift:99](app/Sources/HVMInstall/MacInstaller.swift) | **误报** | `defer` 在函数退出时触发, 此时 VZ 实例已释放; 后续若调 `VMHandle.start()`, 是另一个独立的 ConsoleBridge |
| A5 | `BundleIO.load` 主盘路径未走 `isDiskPathInSandbox`, `../../../etc` 风险 | [BundleIO.swift:114](app/Sources/HVMBundle/BundleIO.swift) | **Done** | 重排顺序: sandbox 校验 → 主盘唯一 → 存在性. 防攻击者控制 path 触发 stat() 任意路径 |
| A6 | `RekeyVMOperation` config.enc + routing JSON 改密非原子 | [RekeyVMOperation.swift](app/Sources/HVMEncryption/RekeyVMOperation.swift) | Done (#12) | — |
| A7 | `EncryptionKDF.deriveAll` 重复 derive 4 次 + master 多次进普通堆 | [EncryptionKDF.swift](app/Sources/HVMEncryption/EncryptionKDF.swift) | **Done** | 单次进 `masterKey.withBytes` mlock buffer, 4 子 key 在同一 closure 内算完, 暴露面 4→1 |
| A8 | `DetailContainerView.onChange` 重新 subscribe 形成订阅链 | [DetailContainerView.swift:142](app/Sources/HVM/UI/Content/DetailContainerView.swift) | **误报** | `withObservationTracking` 的 onChange 是单次回调, 触发后 tracker 失效再 subscribe 是 Observation 标准模式; refresh 改的是本地字段不在 AppModel 里, 不会触发新一轮 |
| A9 | `AppModel.stateTickTimer` 单例 dealloc 时未 invalidate | [AppModel.swift:267](app/Sources/HVM/Services/AppModel.swift) | **Skipped** | 尝试加 deinit invalidate 与 @MainActor 隔离冲突, 卫生收益不抵 nonisolated(unsafe) 暴露面成本; AppModel 单例进程退出即销毁, 实际无影响. `[weak self]` 已防 stale closure |
| A10 | `SidecarProcessRunner.stderrFileHandle.write` 在 readabilityHandler 回调与 termination 路径间无 lock | [SidecarProcessRunner.swift:130](app/Sources/HVMQemu/SidecarProcessRunner.swift) | **Done** | readability 回调拿 `fh = stderrFileHandle` snapshot 进锁, termination 路径 close + nil 进同把锁; tradeoff: 不把 write 整块包锁 (磁盘 fsync 慢会阻塞 termination) |
| A11 | `QemuLaunchCommand` `c.close()` 无 defer, 抛错时 QmpClient 泄漏 | [QemuLaunchCommand.swift:152](app/Sources/hvm-dbg/Commands/QemuLaunchCommand.swift) | **Done** | guard let client 后立即 `defer { client.close() }`; close 幂等, 末尾显式调那行删除 |

### B. 低严重 BUG

| # | 项 | 文件 | 备注 |
|---|---|---|---|
| B1 | `LogSink.writeLine` `try? fh.write` 静默吞日志写错 | [LogSink.swift:142](app/Sources/HVMUtils/LogSink.swift) | 至少 `os_log` 一次 |
| B2 | `BundleLock.write` JSON encode 失败无 log, 诊断难 | [BundleLock.swift:77](app/Sources/HVMBundle/BundleLock.swift) | 加 warning |
| B3 | `ResumableDownloader` partial 文件 promote 与 size 检查间无锁 | [ResumableDownloader.swift:399](app/Sources/HVMInstall/ResumableDownloader.swift) | 包 lock |
| B4 | `recv_fd.c` VLA `int fds[fd_count]` 实际 fd_count ≤ 1 安全, 理论可栈溢出 | [recv_fd.c:64](app/Sources/HVMScmRecv/recv_fd.c) | 改固定大小 (FD_MAX = 4) |
| B5 | `LuksSecretFile.write` 不处理 EINTR, 短写重试可丢字节 | [LuksSecretFile.swift:51](app/Sources/HVMEncryption/LuksSecretFile.swift) | 加 EINTR 循环 |
| B6 | `SecureErase.SecRandomCopyBytes` 返回码未检查 | [SecureErase.swift:56](app/Sources/HVMEncryption/SecureErase.swift) | 检查 errSecSuccess |

### C. 安全问题

| # | 项 | 严重 | 文件 | 备注 |
|---|---|---|---|---|
| C1 | `Paths.sanitizeForFilesystem` 未禁 `.` 开头, 允许 `.ssh-uuid8/` 隐藏目录 | 中 | [Paths.swift:56](app/Sources/HVMUtils/Paths.swift) | 显式禁 dot-leading |
| C2 | `SocketServer` socket 父目录创建未指定权限, bind 前的 unlink 存在 symlink 攻击窗口 (低概率, 单用户场景) | 中 | [SocketServer.swift:28](app/Sources/HVMIPC/SocketServer.swift) | 父目录 0700 + bind 前 lstat 检查 |
| C3 | `ExecCommand.readLine` 读密码后 String 未清零, core dump 可泄漏 | 中 | [ExecCommand.swift:75](app/Sources/hvm-dbg/Commands/ExecCommand.swift) | 改 SecureBytes (HVMEncryption 已有) |
| C4 | `gui.type/read` 暴露全部 identifier, 无白名单 (release 默认未启 ProbeServer 已部分 mitigate) | 低 | [GuiCommand.swift:180](app/Sources/hvm-dbg/Commands/GuiCommand.swift) | 加 identifier 前缀白名单 |
| C5 | `BundleLock` `.lock` 文件 0o644 应改 0o600 | 低 | [BundleLock.swift:47](app/Sources/HVMBundle/BundleLock.swift) | umask + chmod |

### D. CLAUDE.md UI 约束违规

| # | 项 | 严重 | 文件 | 备注 |
|---|---|---|---|---|
| D1 | `StatusBadge` 硬编码 `.padding(.horizontal, 10) .vertical, 4)` | 高 | [DetailBars.swift:42](app/Sources/HVM/UI/Content/DetailBars.swift) | 新增 `HVMSpace.statusBadgePadH/V` 或复用现有 token |
| D2 | `MenuPopoverView` `Divider().padding(.leading, 70)` 硬编码 | 中 | [MenuPopoverView.swift:71](app/Sources/HVM/UI/Shell/MenuPopoverView.swift) | 改相对计算或 token |
| D3 | `Theme.swift` HVMFont 内部多处 `.padding(.vertical, 8/7)` 硬编码 | 低 | [Theme.swift:183/215/281/333/367](app/Sources/HVM/UI/Style/Theme.swift) | 组件层豁免也应文档化原因 |
| D4 | `CloneVMDialog` `.padding(.top, 2)` 硬编码 | 低 | [CloneVMDialog.swift:128](app/Sources/HVM/UI/Dialogs/CloneVMDialog.swift) | `HVMSpace.v2` |
| D5 | `HVMToggle` `.padding(2)` 硬编码 | 低 | [HVMToggle.swift:68](app/Sources/HVM/UI/Style/HVMToggle.swift) | `HVMSpace.v2` |

### E. 优化点 (非 bug, 排日程)

| # | 项 | 严重 | 文件 |
|---|---|---|---|
| E1 | `LogSink` 每行 log 都 `synchronize()`, 改按天 rotate 时再 sync | 中 | [LogSink.swift:36](app/Sources/HVMUtils/LogSink.swift) |
| E2 | `AppModel.startIpswFetch.onProgress` 每帧 spawn 新 Task, 改 debounce | 中 | [AppModel.swift:650](app/Sources/HVM/Services/AppModel.swift) |
| E3 | `ExecCommand.waitForAny` `usleep(150_000)` 改事件驱动 (console.read 加 long-poll) | 中 | [ExecCommand.swift:170](app/Sources/hvm-dbg/Commands/ExecCommand.swift) |
| E4 | `FramebufferRenderer` `MTLBuffer` deallocator 不处理 munmap 失败 | 中 | [FramebufferRenderer.swift:170](app/Sources/HVMDisplayQemu/FramebufferRenderer.swift) |
| E5 | `Frame.readExact` 单字节循环, 改批量读 | 中 | [Frame.swift:49](app/Sources/HVMIPC/Frame.swift) |
| E6 | screenshot/console payload 已 base64 又套 JSON 双层编码, 改 binary frame | 中 | [HVMIPC/Protocol.swift](app/Sources/HVMIPC) |
| E7 | `DiskFactory.readToEnd()` 无 timeout, qemu-img 大输出会阻塞 | 低 | [DiskFactory.swift:129](app/Sources/HVMStorage/DiskFactory.swift) |
| E8 | `ResumableDownloader` `Pipe()` 不读, 缓冲满后子进程阻塞, 改 `nullDevice` | 低 | [ResumableDownloader.swift:270](app/Sources/HVMInstall/ResumableDownloader.swift) |
| E9 | `IPResolver` ARP 缓存 5s 过短, 改 30-60s | 低 | [IPResolver.swift:47](app/Sources/HVMNet/IPResolver.swift) |
| E10 | `IPCCall` 每次 GUI 命令新建 socket, 加连接池 | 低 | [IPCCall.swift:25](app/Sources/HVMGuiProbe/IPCCall.swift) |
| E11 | `DetailBars.list.first(where:)` 每帧 O(N), 加 dict cache | 低 | [DetailBars.swift:94](app/Sources/HVM/UI/Content/DetailBars.swift) |
| E12 | `CreateVMDialog.onAppear` 同步 IO 阻塞主线程 | 低 | [CreateVMDialog.swift:123](app/Sources/HVM/UI/Dialogs/CreateVMDialog.swift) |
| E13 | `SidebarView` VM > 100 时无 search filter | 低 | [SidebarView.swift:48](app/Sources/HVM/UI/Content/SidebarView.swift) |
| E14 | `SignalGuard` signal context 用 `String.withCString`, 严格说应改纯 C 字串 | 低 | [SignalGuard.swift:131](app/Sources/HVMUtils/SignalGuard.swift) |

### F. 高严重 BUG — 已修 (本审计 commit)

| # | 项 | 文件 | 修法 |
|---|---|---|---|
| F1 | `SocketServer` 每条 IPC 连接 `Thread().start()` 无上限 | [SocketServer.swift:97-126](app/Sources/HVMIPC/SocketServer.swift) | 改 concurrent `DispatchQueue` + 32 路硬上限 (HVMIPC + ProbeServer 共享) |
| F2 | `QmpClient.readLineBlocking` 单字节 `recv` 不处理 EINTR / 不区分 EOF | [QmpClient.swift:269](app/Sources/HVMQemu/QmpClient.swift) | EINTR continue + EOF 显式抛 |
| F3 | `QmpClient.readLoop` recv 把 EINTR 当 EOF, QMP 命令丢 | [QmpClient.swift:303](app/Sources/HVMQemu/QmpClient.swift) | EINTR continue, n==0 才 EOF |
| F4 | `DisplayChannel.recvIntoBuffer` throw 时 sink.pointee 已存的 fd 不被关闭, 调用方追不到 → fd 泄漏 | [DisplayChannel.swift:296](app/Sources/HVMDisplayQemu/DisplayChannel.swift) | 加 `drainSink()` 在所有 throw 前关 sink fd |
| F5 | `ProbeServer` 用 `DispatchQueue.main.sync` 阻塞 IPC 线程, 主线程繁忙时长抖 | [ProbeServer.swift:60](app/Sources/HVMGuiProbe/ProbeServer.swift) | 改 Task @MainActor + DispatchSemaphore |
| F6 | `ExecCommand` sentinel 解析失败返 `exit=-1`, 与 guest 真返 -1 无法区分 | [ExecCommand.swift:218](app/Sources/hvm-dbg/Commands/ExecCommand.swift) | 改抛 `ExecSentinelError.notFound` → ExitCode(7) |

### G. 高严重 BUG — 误报 (审计回溯, 不修)

| # | 项 | 误报原因 |
|---|---|---|
| G1 | `VMHandle.delegate` 强引用环 | VZ.delegate 是 weak; Delegate 闭包 `[weak self]`; 无环. 仅 `vm` / `delegate` 字段在 stop 后未清, 是次态遗留, 不是泄漏 (下次 start 会覆盖) |
| G2 | `EncryptVMDialog.Task.detached` data race | progressLog 闭包内已用 `Task { @MainActor in ... }` hop 主线程; @State 跨 struct copy 通过 SwiftUI 共享存储, 不是真 race |
| G3 | `AppModel.startIpswFetch [self]` retain | AppModel 是单例, 注释明确说明 (line 636); Task 短生命; URLSession 后台 queue 不持久持有 |

## 不在本清单内 (明确划走)

- **VZ sparsebundle 加密接入** — 推后 (ENCRYPTION.md v2.4 决策), 等用户回头
- **加密性能 benchmark** — LUKS / AES-GCM 性能 vs 明文不在本稿; 真机如果用户反馈卡再测
- **多用户共享加密 VM** (类似 LUKS multi-keyslot 给不同用户) — 不做, 单用户单密码模型
- **HSM / Smart Card 解锁** — 不做, 单密码模型已锁
- **加密备份 (rsync / Time Machine)** — 加密 VM 拷过去就是 ciphertext, Time Machine 走自己的加密, 不需要我们做啥
