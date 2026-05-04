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
| 1 | hvm-cli config 加密适配 | Pending | 🔴 |
| 2 | hvm-cli disk resize 加密适配 | Pending | 🔴 |
| 3 | hvm-cli iso 加密适配 | Pending | 🔴 |
| 4 | hvm-cli boot-from-disk 加密适配 | Pending | 🔴 |
| 5 | logs/kill/pause/resume 加密 VM 验证 | Pending | 🔴 |
| 6 | LUKS secret fifo / 缩 unlink 窗口 | Pending | 🟡 |
| 7 | master/sub key mlock | Pending | 🟡 |
| 8 | 多盘 encrypt/decrypt/rekey 真机 | Pending | 🟡 |
| 9 | 装机 → reboot → 桌面完整生命周期 | Pending | 🟡 |
| 10 | GUI 加密 (PR-11) | Pending | 🟡, 时间盒 3 天 |
| 11 | delete secure-erase | Pending | 🟡 |
| 12 | rekey 原子性 (staging + journal) | Pending | 🟡 |
| 13 | encrypt 流程临时目录策略对齐 decrypt | Pending | 🟡 |
| 14 | 加密 VM clone | Postponed | 🟢, D9 未决 |
| 15 | 加密 VM snapshot | Pending | 🟢, 真机验证 |
| 16 | create --import-disk --encrypt | Postponed | 🟢, 等用户需求 |
| 17 | macOS / VZ 加密 | Postponed | 🟢, 等 VZ PR |
| 18 | swtpm rewrap | Postponed | 🟢, 等上游 |
| 19 | Ctrl-C 中断清理 | Pending | 🟢 |
| 20 | v1 文档回写 (含 SECURITY.md 新建) | Pending | 📚, 合 PR-12 |
| 21 | CLAUDE.md 加密约束节 | Pending | 📚, 合 PR-12 |
| 22 | README.md 提及加密 | Pending | 📚, 合 PR-12 |

## 不在本清单内 (明确划走)

- **VZ sparsebundle 加密接入** — 推后 (ENCRYPTION.md v2.4 决策), 等用户回头
- **加密性能 benchmark** — LUKS / AES-GCM 性能 vs 明文不在本稿; 真机如果用户反馈卡再测
- **多用户共享加密 VM** (类似 LUKS multi-keyslot 给不同用户) — 不做, 单用户单密码模型
- **HSM / Smart Card 解锁** — 不做, 单密码模型已锁
- **加密备份 (rsync / Time Machine)** — 加密 VM 拷过去就是 ciphertext, Time Machine 走自己的加密, 不需要我们做啥
