# 加密 VM clone + snapshot 支持 (顺带修 qcow2 snapshot 漏 bug)

> 状态: **代码已合入 (2026-05)** (PR-A snapshot / PR-B clone). D9 决策 = 等价复制 + 同密码. 现状回写 [../v1/CLONE.md](../v1/CLONE.md) + [../v1/ENCRYPTION.md](../v1/ENCRYPTION.md).
>
> 父设计稿: [ENCRYPTION.md](ENCRYPTION.md) / [CLONE.md](CLONE.md) (均已合入)
> 关联 TODO: [TODO.md](TODO.md) #14 (clone) / #15 (snapshot) — 已 Done

## 背景

PR-1 ~ PR-10b 落地后, 加密 QEMU VM 已能 `start / encrypt / decrypt / rekey / status` 闭环. 剩下两块用户场景洞:

1. **加密 VM clone 不工作** — `CloneManager.clone` 走 `BundleIO.load` 读 config.yaml, 加密 VM 是 `config.yaml.enc` 报 fileNotFound (TODO.md #14, D9 未决)
2. **加密 VM snapshot 不工作** — `SnapshotManager.create / restore` 只 clone `.img` 文件, 完全跳过 `.qcow2`. 这意味着 **所有 QEMU VM (含明文 + 加密) 的 snapshot 自 PR-1 以来都是假的**: snapshot 目录里 disks/ 是空的, restore 撞 ENOENT (TODO.md #15)

本稿同时解两个洞. snapshot 那个是隐藏老 bug 借此机会一起修, 不是新加能力.

## 目标 + 范围

**做**:
- CloneManager 适配加密 VM: APFS clonefile 整个 bundle (含 LUKS qcow2 字节) + 重生身份字段 + 重写 routing JSON 的 vmId + 重写 config.yaml.enc 内的 vmId/displayName/disks paths
- **CloneManager 永不带 snapshots/** (D15 用户决策): 移除 `Options.includeSnapshots` 字段 + 移除 `CloneCommand --include-snapshots` flag. 加密 / 明文 / VZ / QEMU 一律不带
- SnapshotManager 修 .qcow2 + 加密文件支持: create / restore / list 都要识别 qcow2; restore 同时处理 config.yaml 与 config.yaml.enc

**不做**:
- 跨密码 clone (源密码 A → 目标密码 B): 用户拿到 clone 后自己跑 `hvm-cli rekey` (零成本路径, 不耦合 clone 逻辑)
- 跨 engine clone (VZ ↔ QEMU): 维持 CLONE.md 现有边界, 不变
- 跨机器 clone: scp + 同密码已支持 (PR-8 闭环), 不重做
- VZ-sparsebundle 路径 clone: 推后 (ENCRYPTION.md v2.4 决策)
- qcow2 internal snapshot (`qemu-img snapshot -c`): 维持 APFS clonefile 路线, 不切. 详见"选型对比"

## 选型对比

### #14 加密 VM clone — D9 未决项

| 方案 | 实现 | 用户体验 | 安全边界 | 工作量 | 选用 |
|---|---|---|---|---|---|
| **A. 等价复制 + 同密码** | clonefile 字节复制 (含 LUKS qcow2 + nvram + tpm) + routing JSON 仅改 vmId + config.yaml.enc 解密 → 改字段 → 用同 master KEK 重新加密 | 克隆出来跟源 VM 同密码; 想换密码自跑 `hvm-cli rekey` | 用户克隆 = 自愿复制, 同密码语义清晰 | 小 — 只多 EncryptedConfigEditor + RoutingJSON 处理 | ✅ |
| B. 强制 rekey 到新密码 | clone 时 prompt 旧密码 + 新密码 → 重写所有 LUKS keyslot + 重派 swtpm-key + 重密 config + 写新 routing JSON salt | 克隆出来要输新密码 | 跨 clone 隔离更强 | 大 — clone 内嵌完整 rekey 流程 | ✗ |
| C. 拒绝 clone 加密 VM | 检 detectScheme = 加密就抛错 | 用户必须先 decrypt → clone → encrypt | 无新增 | 0 | ✗ — UX 太差 |

**选 A**. 理由:
- APFS clonefile 是字节级 COW, 对 LUKS 加密 qcow2 / config.yaml.enc / swtpm tpm/permall 都透明 (复制密文字节)
- master KEK 由 PBKDF2(password, salt) 派生; clone 后 salt 不变 + 密码不变 → 同 master KEK → 同 sub keys → 同 LUKS keyslot 能解 → swtpm 同 key 能开 tpm/
- 用户视角: clone 语义就是"复制成等价的另一个 VM". 同密码符合直觉
- 用户视角: 想要不同密码就自己 rekey, 这是已有命令零成本组合
- 安全: clone 是用户自愿动作, 不在威胁模型内 (攻击者拿不到密码就解不了任一台)

### #15 加密 VM snapshot — qcow2 路径

| 方案 | 实现 | 加密兼容 | 工作量 | 选用 |
|---|---|---|---|---|
| **A. 现 APFS clonefile + 修 .qcow2 过滤** | SnapshotManager 字节复制全部磁盘 (.img + .qcow2) | ✅ 透明 (字节复制 LUKS qcow2 ciphertext) | 小 — 改 hasSuffix 过滤 + 复制 config.yaml.enc | ✅ |
| B. 切到 qcow2 internal snapshot (`qemu-img snapshot -c`) | snapshot 元数据存 qcow2 文件内 | ⚠️ 加密 qcow2 internal snapshot 行为待真验; QEMU 文档未明确支持 | 中 — 改 SnapshotManager 整套 | ✗ |
| C. 切到 qcow2 external snapshot (backing chain) | 新建 LUKS qcow2 overlay, 链式回滚 | ✅ 但 overlay 加密 key 与 base 同 master KEK 派生 | 大 — overlay 链管理 | ✗ |

**选 A**. 理由:
- APFS clonefile 已是 ms 级零空间, 性能没必要改
- 字节复制 LUKS ciphertext 不引入新加密路径, 风险最小
- 加密 / 明文 / VZ raw / QEMU qcow2 全部走同一逻辑

### 共用底层判断

两项都基于一个观察: **APFS clonefile(2) 对加密 qcow2 / config.yaml.enc / swtpm state 字节级 COW**, 不需要解密. 解密只是为了改 config 内的 vmId 字段 (clone 才需要; snapshot 里 vmId 不变保留即可).

## 实现要点

### #14 CloneManager 加密分支

**入口分流** (CloneManager.clone):

```
detectScheme(at: source) →
  ├ nil          → 现有明文路径 (BundleIO.load + BundleIO.save)
  ├ qemuPerfile  → 加密路径: prompt password + 解密 config + 改字段 + 同 KEK 加密回写
  └ vzSparsebundle → throw .parseFailed("VZ 加密 clone 暂未实现")
```

**加密路径关键步骤**:

1. PasswordPrompt + EncryptedBundleIO.unlock (源 bundle) → 拿 sub keys + 源 config
2. 同卷判定 + 抢 .edit lock (跟现状一样)
3. **整 bundle clonefile** (字节级):
   - `disks/*.qcow2` 主盘: 文件名不变, clonefile (LUKS header + ciphertext 一起)
   - `disks/data-*.qcow2` 数据盘: uuid8 重生, clonefile 到新名 (跟现状逻辑一样, 只换 .qcow2 过滤)
   - `nvram/efi-vars.qcow2` (LUKS): clonefile
   - `tpm/permall` (swtpm-key 加密): clonefile (源 swtpm-key 来自源 master KEK, clone 后同 KEK 仍能开)
   - `meta/encryption.json` (routing JSON): clonefile, 然后改 vmId 字段
   - `auxiliary/`: clonefile (跟明文路径一样 macOS guest 重生 machine-identifier; 加密 QEMU 不走 macOS, 这块代码路径不触发)
4. **改 config 内字段**:
   - `id` = newID
   - `displayName` = options.newDisplayName
   - `createdAt` = Date()
   - 数据盘 `path` = 重生后的新 uuid8 文件名
   - networks[].mac (按 keepMACAddresses)
5. **EncryptedConfigIO.save 用源 sub.config 写到目标 bundle** — 这是关键: master KEK 不变, sub.config 不变, 目标 .enc 跟源同密钥, 用户用源密码也能解
6. **重写目标 routing JSON 的 vmId** (其他字段保留: scheme / kdfSalt / kdfIterations / encryptedPaths)
7. 失败 → 清理目标 bundle + handle.close 释放 unlock

**关键不变量**:
- 源密码 → 目标密码 (一字不差)
- 源 master KEK → 目标 master KEK (因 salt + 密码不变)
- 源 sub keys → 目标 sub keys (因 master 不变 + HKDF info 字符串不变)
- 但 vmId / displayName / 数据盘文件名 全新

### #15 SnapshotManager 修 qcow2

**改动点** (SnapshotManager.create):

```swift
// 现状: for n in imgs where n.hasSuffix(".img") { ... }
// 改为: for n in imgs where n.hasSuffix(".img") || n.hasSuffix(".qcow2") { ... }
```

config 处理改为同时找 `config.yaml` / `config.yaml.enc`, 哪个存在 copy 哪个 (clonefile, 不解密).

**改动点** (SnapshotManager.restore):

类似. 同时清 `.img` + `.qcow2`; 同时 restore `config.yaml` 或 `config.yaml.enc`. 注意: snapshot 里有 .enc 而当前 bundle 是明文 (反之亦然) → 只可能在用户外部干预下出现, 不防御.

加密 VM snapshot 行为:
- create: 整 LUKS qcow2 + config.yaml.enc + tpm/permall 字节复制. 这一刻的 ciphertext 副本
- restore: 用 snapshot 副本覆盖当前. master KEK / sub keys 没变 (snapshot 期间 routing JSON 也没动)
- 跨密码: 如果 snapshot 创建后用户跑了 rekey 改密, restore 后 LUKS keyslot 仍是**老密码**的 (因为 snapshot 是字节副本, 包含老 LUKS header). 用户必须用 snapshot 那时的密码启动. **是预期行为, UX 文档要写**

### 共享: meta/encryption.json (routing JSON) 处理

CloneManager 加密路径要重写 `vmId` 字段; SnapshotManager 不动 (snapshot 不改身份). 都需要稳定的 read/write API:

```swift
// HVMEncryption/RoutingMetadata.swift 已有:
public enum RoutingJSON {
    public static func read(from url: URL) throws -> RoutingMetadata
    public static func write(_ meta: RoutingMetadata, to url: URL) throws
}
```

CloneManager 加密分支调用 read → 改 .vmId → write. 不新增 API.

## 风险与待验证项

| 编号 | 风险 | 验证方式 | 阻断 |
|---|---|---|---|
| **R1** | clone 后两 VM 同密码 → 用户误以为隔离 | docs/v3/TODO 的 #14 备注 + clone 命令 stdout 显式提示 "新 VM 与源同密码, 想换跑 rekey" | P1 |
| **R2** | clone 后两 VM 同 BitLocker recovery key (Windows tpm/permall 字节复制) | 跟现 CLONE.md "Windows guest 克隆" 风险一样, 文档复述 | P1 |
| R3 | snapshot 创建后 rekey, restore 必须用老密码 | docs + restore 命令 stdout 提示 | P2 |
| R4 | 数据盘 uuid8 重生 后 LUKS header 是否仍能解 | clonefile 是字节级, header 也是字节, 文件名跟密钥派生无关 — 非阻断 | 已论证 |
| R5 | swtpm-key 派生用 master KEK, clone 后 master 不变 → tpm/ 仍能解 | 同上, 非阻断 — HKDF info 字符串是常量, 无随机 | 已论证 |
| **R6** | snapshot 现状是老 bug, 现有用户可能误以为有 snapshot 实际没 | 改 snapshot create 启动期日志显式列出 cloned files; restore 失败给清晰错误 | P1 |

## 落地拆解 (PR 切分)

| PR | 内容 | 时间盒 | 状态 |
|---|---|---|---|
| **PR-A** | SnapshotManager 修 qcow2 + 加密 (.enc) 适配; 单测覆盖 .qcow2 主/数据盘 + 加密 bundle 整 snapshot/restore 真跑 | 0.5 天 | 待开 |
| **PR-B** | CloneManager 加密分支: detectScheme + PasswordPrompt + EncryptedBundleIO.unlock + EncryptedConfigIO.save + RoutingJSON 重写 vmId; CloneCommand stdout 提示 "新 VM 同密码"; 测试: 加密 VM clone → 目标用同密码启动 | 1 天 | 待开 |
| **PR-C** | docs 同步: 回写 docs/v1/STORAGE.md "snapshot 支持 qcow2"; 回写 CLAUDE.md 克隆约束节加 "加密 VM clone 同密码"; TODO.md #14 #15 标 Done | 0.5 天 | 待开 |

合计 ~2 天 / 1 人. PR-A 与 PR-B 独立, 可并行起草, 但 PR-B 测试需要 PR-A 修了 snapshot 才能完整验证 clone-then-snapshot 路径.

每个 PR 必须 `make build` 通过; 加密路径必须真机 e2e (encrypt → clone → 同密码启动 / encrypt → snapshot → 改东西 → restore → 启动).

## 未决事项

| 编号 | 问题 | 当前默认 | 决策时机 |
|---|---|---|---|
| **D9** | 加密 VM clone 是否支持 + 密码策略 | **方案 A 等价复制 + 同密码** (本稿主张) | **本稿评审** |
| D14 | snapshot 的 routing JSON 怎么处理 | snapshot 不改 vmId / 字节复制保留. restore 也不动 routing | 已决 (本稿) |
| **D15** | clone 是否带 snapshots/ | **永不带, 移除 `--include-snapshots` flag** (用户 2026-05-04 决策) — 加密 / 明文 / VZ / QEMU 全部一致. 理由: snapshot 在源 bundle 里有意义 (revert 链), 复制到 clone 目标语义不清 (是新 VM 的"过去状态", 但跟 clone 的"新身份"矛盾). 想要 snapshot 自己 clone 后再 create | 已决 (本稿用户决策) |
| D16 | clone 加密 VM 是否要二次确认 (tpm 双开警告) | 加 `[y/N]` (跟 CLONE.md Win VM 警告 UX 一致) | 已决 (本稿) |
| D17 | snapshot create 是否要 prompt 密码 | **不要** — snapshot 是字节复制, 不解密. UX 上跟明文 VM 一致 | 已决 (本稿) |
| D18 | clone CLI 是否新加 `--password-stdin` 给脚本用 | 不加, 维持跟 encrypt/decrypt 一样仅 tty (CLAUDE.md 安全约束) | 已决 |

## 设计变更日志

### 2026-05-04 v1 — 本稿

初稿. 关键决策:
- D9 (加密 VM clone) 主张方案 A "等价复制 + 同密码". 理由是 APFS clonefile 字节级 COW + master KEK 派生不依赖文件名 / inode → 整 bundle 字节复制后用源密码可解. 不需要 rekey 路径
- 顺带修 SnapshotManager 的 qcow2 老 bug (PR-1 起就有, 加密只是借此暴露)
- snapshot 不需要 prompt 密码 (字节复制不解密)

## 相关文档

- 父稿 [ENCRYPTION.md](ENCRYPTION.md) v2.4 — 加密整体架构
- 父稿 [CLONE.md](CLONE.md) — 明文 clone 决策与边界
- TODO 索引 [TODO.md](TODO.md) — #14 #15
- 实现参考: [HVMStorage/CloneManager.swift](../../app/Sources/HVMStorage/CloneManager.swift) / [HVMStorage/SnapshotManager.swift](../../app/Sources/HVMStorage/SnapshotManager.swift) / [HVMEncryption/EncryptedBundleIO.swift](../../app/Sources/HVMEncryption/EncryptedBundleIO.swift)
