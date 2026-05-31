# ENCRYPTION.md — 整 VM 落盘加密

> 现状文档 (代码已合入). QEMU-only 单后端路线下整 VM 的落盘加密能力.
> 源码: `app/Sources/HVMEncryption/**` (17 文件) + 收口 `app/Sources/HVMControl/VMControl+Encryption.swift`.
> 设计沉淀历史散落在 `docs/v3/ENCRYPTION.md` / `docs/v3/CLONE_SNAPSHOT_ENCRYPTED.md` (本文档为现状汇总).

---

## 1. 威胁模型 + 整体方案

### 1.1 威胁模型

加密目标: 一台 Mac 上的 `.hvmz` bundle (或拷到另一台 Mac 的 bundle) 在 **VM 未运行 / host 用户未登录** 时, 攻击者拿到磁盘字节也读不出 VM 内容 (磁盘数据 / 网卡 MAC / TPM secrets / BitLocker recovery key 等).

**防御边界 (做到的)**:

- 整盘 (主盘 + 数据盘) 内容走 qcow2 native LUKS (AES-256-XTS) 加密
- OVMF VARS (EFI BootOrder 等) 走 LUKS qcow2 加密
- swtpm NVRAM state (Win11 TPM 2.0) 走 swtpm 自带 AES-256-CBC 加密
- `config.yaml` (磁盘布局 / 网卡 MAC / 共享目录路径等) 走 AES-256-GCM 加密成 `config.yaml.enc`
- 密钥不落盘: 解锁靠用户密码现场 PBKDF2 派生, 无 Keychain / iCloud / 任何本机持久状态依赖 → **跨机器 portable**

**不防御的 (明确边界)**:

- VM **运行期** root 攻击者直接 dump 进程内存 (mlock 防不住 root, 见 `SecureBytes.swift`)
- 物理介质层 secure-erase 不可靠 (APFS/SSD wear leveling; `SecureErase.swift` 仅 best-effort 单 pass 覆写 "提高成本", 真正彻底防御靠 host FileVault 全盘加密 — 文档强烈建议用户开)
- 弱密码字典爆破 (PBKDF2 600k 仅抬高单次成本, 不能救烂密码)

### 1.2 整体方案 (QEMU per-file scheme)

加密 VM 恒走 **qemu-perfile** scheme — `.hvmz` 是真实目录, 逐文件 in-place 加密:

| 加密点 | 文件 | 算法 / 工具 | 子 key |
|---|---|---|---|
| 主盘 / 数据盘 | `disks/*.qcow2` | qcow2 native LUKS (AES-256-XTS) | `qcow2Disk` |
| OVMF VARS (Win) | `nvram/efi-vars.qcow2` | qcow2 native LUKS (AES-256-XTS) | `qcow2Nvram` |
| swtpm state (Win) | `tpm/permall` 等 | swtpm `--key` AES-256-CBC | `swtpm` |
| VM 配置 | `config.yaml.enc` | AES-256-GCM (CryptoKit) | `config` |
| **路由元数据** | `meta/encryption.json` | **明文** (KDF 入口) | — |

> 注: swtpm-key 子 key 已派生并由 `SwtpmKeyHelper` 走 stdin 注入 swtpm; 但 encrypt/decrypt/rekey 三个 Operation 目前对 Win TPM 的策略是**重置**而非 rewrap (见 §3), 所以 swtpm 加密在"创建即加密"路径生效, 在"明文转加密"路径表现为 TPM 重置.

另有 `vzSparsebundle` scheme (整 bundle 套 hdiutil 加密 sparsebundle) 是历史方案, 随 VZ 后端移除已**推后 / 未接 GUI** (见 §5).

---

## 2. 密钥层级 (三层)

```
用户密码 (String, UTF-8)
   │  PasswordKDF.deriveMasterKey()  ── PBKDF2-SHA256, salt=16B, iter=600k, keylen=32
   ▼
master KEK (MasterKey, 32 字节, mlock 守护)
   │  EncryptionKDF.deriveAll()  ── HKDF<SHA256>, salt=空, info=用途字符串, L=32
   ▼
4 个子 key (EncryptionKDF.SubKeySet, 各 32 字节 SymmetricKey)
   ├─ qcow2Disk   info="qcow2-disk"   → LUKS 主盘/数据盘 passphrase
   ├─ qcow2Nvram  info="qcow2-nvram"  → LUKS OVMF VARS passphrase
   ├─ swtpm       info="swtpm"        → swtpm --key (stdin 注入)
   └─ config      info="config"       → AES-256-GCM config.yaml.enc
```

### 2.1 第一层: 密码 → master KEK (`PasswordKDF.swift`)

- 算法: **PBKDF2-SHA256** (Apple CommonCrypto `CCKeyDerivationPBKDF`, 无第三方依赖)
- 参数 (照实际代码常量):
  - `defaultIterations = 600_000` (2024 OWASP 推荐, 1Password/Bitwarden 同档)
  - `saltLengthBytes = 16` (2^128 唯一性, 防 rainbow table)
  - `derivedKeyLengthBytes = 32` (256-bit AES key)
  - `minSafeIterations = 100_000` (安全下限, 防 routing JSON 被改成 `iter=10` 这种灾难; 低于此拒绝派生)
- salt 走 `SecRandomCopyBytes` (Apple CSPRNG) 生成, 写入明文 routing JSON
- 选 PBKDF2 而非 argon2id 的理由: CommonCrypto 内置零依赖; routing JSON 留 `kdf_algo` 字段给未来切 argon2id (升 schema v4)
- 性能 (代码注释实测): M1 ~150ms / 派生, M3 ~80ms / 派生 — 仅首启解锁等待, 不影响运行期 I/O

### 2.2 第二层: master KEK → 4 子 key (`EncryptionKDF.swift`)

- 算法: **HKDF<SHA256>** (CryptoKit `HKDF<SHA256>.deriveKey`)
- salt **留空** (master KEK 已经 PBKDF2(16B random salt) 派生, 自带高熵)
- info 字符串当用途上下文 + 版本: `SubKeyKind` 枚举 rawValue 是稳定字符串 `qcow2-disk` / `qcow2-nvram` / `swtpm` / `config` — **改了等于换 key, 老 VM 解不开** (代码注释硬约束)
- `deriveAll()` 单次进 `master.withBytes` mlock buffer 内算完 4 个子 key, master KEK 明文字节在普通堆暴露面收到 1 次 (避免 4 次 `derive()` 各暴露一次)
- 未来加新加密点 (例 backup-key) 只加新 `SubKeyKind` case, info 唯一不冲突, 不破坏老 VM (老 VM 只用 4 个老子 key)

### 2.3 master KEK 内存防护 (`MasterKey.swift` + `SecureBytes.swift`)

- `MasterKey` 内部走 `SecureBytes` (class): `calloc` + `mlock` 防 swap + 销毁前 `memset_s` 清零 (防编译器优化掉 secure-zero)
- 32 字节强校验, 不 Codable / 不 print / 不 log
- `mlock` 失败 (RLIMIT_MEMLOCK 限制) 仅 warning 不抛, 降级非锁内存
- `random()` 走 `SecRandomCopyBytes` (HVM 内部加密恒走密码派生, master.random 仅留接口)

### 2.4 明文 routing JSON 是 KDF 入口 (`RoutingMetadata.swift`)

`meta/encryption.json` 是**唯一明文文件**, 跨机器 portable 的核心 — 目标机读它拿 KDF 参数 + 输密码就能派生同样的 master KEK, 不依赖任何本机状态.

字段 (snake_case, JSON):

| 字段 | 含义 |
|---|---|
| `schema_version` | routing JSON 自己的版本, 当前 **3** (≠ VMConfig schemaVersion) |
| `vm_id` / `display_name` | VM 标识 (解锁前 GUI 列表显示用) |
| `scheme` | `qemu-perfile` (唯一; vz-sparsebundle 已下线) |
| `guest_os` | v3 加: linux/windows, 让解锁前 GUI 正确显示 guest 类型 (老 v2 缺 → 兜底 .linux) |
| `kdf_algo` | `pbkdf2-sha256` (未来切 argon2id 升 v4) |
| `kdf_iterations` | 600000 |
| `kdf_salt` | 16 字节 random (JSON base64 编) |
| `kdf_keylen` | 32 |
| `encrypted_paths` | 诊断用, 列被加密文件 (config.yaml.enc / disks / nvram / tpm) |

routing JSON **不含任何密钥 / 密码 / 派生输出** — 只有 salt + 迭代参数, 暴露它不降低安全性 (PBKDF2 设计上 salt 公开).

I/O 走 `RoutingJSON.write/read` (atomic, prettyPrinted + sortedKeys, base64 编 salt). QEMU 路径位置 `RoutingJSON.locationForQemuBundle()` = `<bundle>/meta/encryption.json`.

---

## 3. Lifecycle: encrypt / decrypt / rekey

三个 Operation 都是 **冷迁移 (必 stopped)**, 收口在 `VMControl+Encryption.swift` (`encryptVM` / `decryptVM` / `rekeyVM`), 内部由 `assertStoppedIfNeeded(requireStopped: true)` 强制停机, 解析 `QemuPaths.qemuImgBinary()` + (Win) `share/qemu/edk2-aarch64-vars.fd` OVMF 模板, 业务侧不碰后端路径.

### 3.1 加密 (`EncryptVMOperation.swift` — 明文 → 加密)

`hvm-cli encrypt <vm>` / GUI [加密 VM]:

1. 检测已加密则拒绝 (`detectScheme != nil`)
2. 加载明文 config, 校验 `engine == .qemu` (VZ engine VM 加密暂不支持)
3. 生成 salt + master KEK + 4 子 key
4. 建临时目录 `.encrypting-<8char>/` 旁建加密文件 (**失败可清, 不破原数据**)
5. 逐 disk `qemu-img convert -O qcow2 -o encrypt.format=luks,...` (raw/qcow2 → LUKS qcow2, 统一改 `.qcow2` 后缀 + `DiskSpec.format=.qcow2`)
6. Win VM: 现有 `efi-vars.fd` → `qemu-img convert -f raw` 成 LUKS qcow2 (保留 BootOrder); 没现有 vars 则用 stock 模板走 `OVMFVarsLuksFactory.create`
7. 写临时 `config.yaml.enc` + 临时 routing JSON
8. **替换阶段** (`rollbackTmpDir = false`, 之后不可回滚): disks 先 rename 旧成 `.old-encrypt` → mv 新 → 全部 mv 成功才 `SecureErase` 旧 (TODO #13 加固: 原 "先 erase 后 mv" 风险 mv 失败留空 disks/, 改成 rename 中转保证可恢复). NVRAM 同模式
9. mv 明文 `config.yaml` → secure-erase, mv 临时 `config.yaml.enc` 进来, 写 `meta/encryption.json`
10. **Win VM 重置 TPM**: `SecureErase.eraseDirectory(tpm/)` (旧 state 是明文 binary, 新 swtpm-key 解不开; tpm/permall 含 BitLocker recovery key 高敏感, 走 secure-erase 非裸 rm). `tpmReset = true` 警告用户 BitLocker / SecureBoot 信任根重置

失败回滚: 转换阶段任意抛错 → 临时目录留着 (用户手动清), 主 bundle 未动保持明文.

### 3.2 解密 (`DecryptVMOperation.swift` — 加密 → 明文)

`hvm-cli decrypt <vm>`:

1. 检测加密形态 + `EncryptedBundleIO.unlock(password)` 拿 master + 4 子 key + config
2. 临时目录 `.decrypting-<8>/`:
   - disks: `qemu-img convert --image-opts driver=qcow2,...encrypt.key-secret=sec0 -O qcow2` (LUKS qcow2 → 明文 qcow2; **不切回 raw / 不改 engine**)
   - Win OVMF VARS: LUKS qcow2 → raw `efi-vars.fd`
   - config.yaml.enc → `BundleIO.save` 写明文 `config.yaml` (置 `config.encryption = nil`)
3. 替换阶段: 删旧加密 disks/nvram + config.yaml.enc + `meta/encryption.json`, mv 明文进来
4. **Win VM: secure-erase `tpm/`** (swtpm state 之前用 swtpm-key 加密, 解密后无 key; 启动期 swtpm 在空目录初始化新明文 state)

### 3.3 改密 (`RekeyVMOperation.swift` — LUKS keyslot 重写)

`hvm-cli rekey <vm>`. **毫秒级** (不重密 DEK, 只重写 LUKS keyslot + atomic 写 config/routing), TODO #12 原子化重排:

1. `unlock(oldPassword)` → oldSubKeys + config
2. 派生 newSalt + newMaster + newSubKeys
3. **每 disk + nvram: `addNewKeyslot`** (老+新 keyslot 都激活, 老密码仍能解)
4. **atomic 切换 `config.yaml.enc` + routing JSON**: 先写 `.staging` 临时文件 → `replaceItemAt` (APFS rename(2) atomic) 替换; 让 config+routing 两写等价为单 atomic boundary
5. **每 disk + nvram: `removeOldKeyslot`** (只剩新 keyslot)
6. **Win VM: 重置 TPM** (swtpm-key 也变, 现有 state 用 old swtpm-key 解不开)

**原子化保证** (LUKS rekey 两步 amend, 包内 qemu-img 10.2 无 `reencrypt` 子命令):
- crash 在 step 3-4 边界前 → routing/config 仍 old, 老密码可解 (新 keyslot 加了无害)
- crash 在边界后 → routing/config 已新, 新密码可解 (老 keyslot 残留无害)
- 核心目标: **绝不发生"两个密码都解不开"灾难**

底层 LUKS 操作在 `QcowLuksFactory.swift`:
- `addNewKeyslot`: `qemu-img amend -o encrypt.new-secret=sec_new,encrypt.state=active`
- `removeOldKeyslot`: `qemu-img amend -o encrypt.old-secret=sec_old,encrypt.state=inactive`
- 内联 `rekey()` (两步合一) 留作 fallback; step 2 失败抛 `.luksRekeyHalfDone` (老+新 keyslot 都活, 用户重试可恢复)

---

## 4. 解锁缓存 (V2: subkeys/config, 5min auto-lock)

GUI 侧 `NewGUIStore` (`app/Sources/HVM/GUI/Store/NewGUIStore.swift`) 持解锁缓存:

- `unlockedConfigs: [UUID: VMConfig]` — 解出的明文 config
- `unlockedSubKeys: [UUID: EncryptionKDF.SubKeySet]` — 4 子 key (改 config / 磁盘操作复用, 不重派生)
- `unlockedPasswords` / `unlockedAt` — 密码 (rekey 等需要) + 末次活动时间
- **`unlockTTL = 300` 秒 (5 分钟无活动 auto-lock)**: `refresh()` (1Hz) 内 inline 检查, 超 TTL 调 `clearUnlock(id)` 清缓存. 当前选中的已解锁 VM 视为活动持续续命

解锁路径 `unlock(s, password)`: `Task.detached(.userInitiated)` 跑 `EncryptedBundleIO.unlock` (PBKDF2 600k 阻塞, 不阻 main), 成功缓存 subkeys/config/password/时间戳.

**加密/解密/rekey 后必 `clearUnlock(id)` + `refresh()`** (硬约束): 加密把明文 config.yaml 变 config.yaml.enc / 解密反之 / rekey 换 subkeys — 旧解锁缓存全失效, 不 clear 会指向不存在的明文/密文.

底层路由 `EncryptedBundleIO.swift`:
- `unlock(bundlePath, password)`: 读 routing JSON → PBKDF2 派生 master → `unlockQEMU` 派生 4 子 key + `EncryptedConfigIO.load` (错 key → `.wrongPassword`) → 返 `UnlockedHandle`
- `create(...)`: 建加密骨架 (mkdir + config.yaml.enc + routing JSON), **不建磁盘内容** (调用方用 subKeys 自己做)
- `detectScheme(at:)`: 看 `meta/encryption.json` 是否存在判 qemu-perfile (不解密, 给 list/GUI 标 [加密])

---

## 5. 两 scheme: qemu-perfile (主) vs vzSparsebundle (推后)

`EncryptionSpec.EncryptionScheme` 枚举当前**只剩 `qemuPerfile = "qemu-perfile"`** 一个 case (`VMConfig.swift`). `vzSparsebundle` 随 VZ 后端移除已从枚举删除 — 老 routing JSON 带 `"vz-sparsebundle"` 解码会失败, 但用户实际无此类 VM (QEMU-only 路线).

`RoutingMetadata.schemaVersion` 当前 = 3:
- v1: 初稿 (kek_source / keychain_item) — 已废
- v2: 加 kdf_* 字段 (强制密码 + 跨机器 portable)
- v3: 加 guest_os 字段 (解锁前 GUI 正确显示 Win/Linux)

### vzSparsebundle 残留代码 (推后, 未接 GUI)

整 hdiutil sparsebundle 工具层 (`SparsebundleTool.swift`) + stale 挂载回收 (`MountReaper.swift`) 仍在仓库, 但**不接 GUI / 加密 VM 恒不走此路**:

- `SparsebundleTool`: 包 `hdiutil create/attach/detach/info/chpass`. 固定 AES-256 + APFS + SPARSEBUNDLE + layout=NONE + nospotlight. 密码绝不进 argv 走 stdin (`-stdinpass` NUL-terminated); `-plist` 输出走 `PropertyListSerialization` 解析; chpass 改密毫秒级 (只换 KEK 不重密 DEK); 多语言识别 hdiutil auth 错 (含 "error 35" 语言无关兜底)
- `MountReaper`: host crash 后残留的 stale sparsebundle 挂载回收 — `info()` 列挂载 → 过滤 HVM 自家 (`.hvmz.sparsebundle` 后缀 + vmsRoot 前缀) → `BundleLock.isBusy` 探活 → 没人持的 force detach. QEMU 路径不需要 reap (swtpm-key 走 Pipe 不落盘, LuksSecretFile 走 NSTemporaryDirectory + defer cleanup)

GUI 入口对 vzSparsebundle 加密 VM 解锁直接报 "暂不支持 (QEMU 优先)" (`NewGUIStore.unlock` guard `encryptionScheme == .qemuPerfile`).

---

## 6. SIGINT 防中断 (`SignalGuard.swift`, 不留 partial bundle)

加密长事务 (encrypt/decrypt/rekey, qemu-img convert 分钟级) 中途 Ctrl-C 可能留半成品. `SignalGuard` (`HVMCore`) 防中断:

- **第一次 Ctrl-C**: write(2) 打警告到 stderr "操作进行中, 请等待结束 (再次 Ctrl-C 强制退出, 可能留残留)", **不打断**当前事务, 让 LUKS keyslot / qemu-img convert 跑完
- **5s 内二次 Ctrl-C**: 跑 atexit cleanup 后 `_exit(130)`, 用户自负残留风险

实现关键:
- `sigaction(2)` 注册 SIGINT/SIGTERM handler, handler 内只调 async-signal-safe 函数 (`write` / `clock_gettime(CLOCK_MONOTONIC)` / `_exit`), 不调 Swift API / print / NSDate
- `install(message:)` reentrant 计数 (嵌套安全); `registerCleanup` 注册兜底 (例 `removeItem(tmpDir)`); `clearCleanup` 事务正常完成后清防 atexit 重复跑
- 限制: SIGKILL / abort 完全拦不住 (文档说明用户自负); 不支持嵌套不同事务

各 Operation 用法 (encrypt/decrypt):
```swift
SignalGuard.install(message: "⚠ 加密操作进行中 ...")
SignalGuard.registerCleanup { try? FileManager.default.removeItem(at: tmpDir) }
defer { SignalGuard.uninstall(); SignalGuard.clearCleanup() }
```
rekey 无临时目录 (in-place 改 keyslot), 但防中断价值最高 — keyslot 改一半 Ctrl-C 会让 config.enc 与 keyslot 不匹配, 故 `install` 但不 `registerCleanup`.

> 另: `SignalGuard.ignoreSIGPIPE()` 是独立能力 (进程级永久装 SIG_IGN), 防 IPC server 给已退出 client 写响应时 SIGPIPE 杀掉 host 进程 — 与加密事务防中断不同通路.

---

## 7. 关键工具层细节

### 7.1 LUKS passphrase 编码 (`LuksSecretFile.swift`)

LUKS spec 要求 passphrase 是合法 UTF-8 字符串, 但子 key 是 32 字节 binary (PBKDF2/HKDF 输出, 大概率含非 UTF-8 字节). 解决: **32 字节 binary → base64 ASCII (44 字符)** 写 0o600 临时文件, qemu-img `--object secret,file=<path>` 一次性读完, defer `unlink`.

- 跨机器一致性: 同 32 字节 binary → 同 base64 → 同 LUKS passphrase → 同样解
- 文件 `open(O_CREAT|O_EXCL, 0o600)` 防 race, NSTemporaryDirectory (用户自家 /var/folders, 0o700 跨用户不可读)
- **不走** `ps` 可见的 `secret-key=base64,data=...` argv 形式

### 7.2 LUKS 加密参数 (`QcowLuksFactory.swift` / `OVMFVarsLuksFactory.swift`)

create/convert 固定 `encrypt.format=luks,encrypt.cipher-alg=aes-256,encrypt.cipher-mode=xts` (AES-256-XTS). grow/resize 需 key 解 header. `isLuksEncrypted` 走 `qemu-img info --output=json` 字符串识别 (不需 key, LUKS metadata 明文).

### 7.3 swtpm key 注入 (`SwtpmKeyHelper.swift`)

swtpm `--key fd=0,mode=aes-256-cbc,format=binary,remove=false`: 32 字节 binary key 走 **Pipe (stdin) 注入不落盘** (anonymous pipe 走内核内存). swtpm 不像 LUKS — `format=binary` 接受任意 32 字节, 不要求 UTF-8 (base64 限制不适用本路径). `Injector.flush()` 在 `process.run()` 后写 32 字节 + close write 端 (swtpm 读到 EOF), idempotent.

### 7.4 config.yaml.enc 落盘格式 (`EncryptedConfigIO.swift`)

```
[0..3]   magic = "HENC" (0x48 0x45 0x4E 0x43)
[4]      format version = 0x01
[5..7]   reserved = [0,0,0]
[8..]    AES.GCM.SealedBox.combined (12B nonce + ciphertext + 16B auth tag)
```
8 字节头对齐让 `head -c 8` / `xxd` 一眼识别. seal 用 `config` 子 key (CryptoKit 自动 12B random nonce). open 失败 (auth tag 验证失败 = 密码错或文件被改) 统一报 `.wrongPassword`. 与明文 `config.yaml` 互斥 (同 bundle 不能同时存在).

### 7.5 secure-erase (`SecureErase.swift`)

单文件 best-effort: `open(O_WRONLY)` + 64KiB chunk random 覆写 (SecRandomCopyBytes) + fsync + unlink. 用于加密化转换清旧明文 (config.yaml / efi-vars.fd / 旧 raw disks / 旧 swtpm tpm/permall). 单 pass 即可 (SSD 上 1 pass 与 7 pass 差不多, Schneier 7-pass 是磁性介质时代过时建议). `eraseDirectory` 递归 erase + rmdir.

---

## 8. CLAUDE.md 关联约束

### 8.1 克隆约束里的加密 VM (D9 = 等价复制 + 同密码)

整 VM 克隆 (`HVMStorage/CloneManager`) 对加密 VM 走 "等价复制 + 同密码" (CLI `hvm-cli clone <enc-vm>` 已支持; GUI 暂不接):

- prompt 源密码 + APFS clonefile 字节级 COW + 用源 sub.config 重新加密 config.yaml.enc
- **新 VM 跟源同密码** — 想换密码用户自跑 `hvm-cli rekey`. master KEK / sub keys 全程不变 → LUKS keyslot 同步可解 / swtpm tpm/permall 同步可开
- routing JSON 仅改 vmId + displayName, salt/iter 保留
- 保留字段 (重生必坏): `nvram/efi-vars.fd` (EFI BootOrder) / `tpm/*` (Win11 swtpm; 重置 = BitLocker 永久失效)
- 重生字段: `config.id` / `displayName` / `createdAt` / `disks/data-<uuid8>` 文件名 / `networks[].macAddress`
- 不带: `.lock` / `logs/console-*.log` / Win 装机产物 / **`snapshots/` (永不带)**

设计稿 `docs/v3/CLONE_SNAPSHOT_ENCRYPTED.md`.

### 8.2 GUI 加密 dialog 约束 (新 GUI 业务页 #3)

整 VM 加密事务接进新 GUI. 入口 `DetailEncryptionSection` (详情页最底沉底), 走单参数化三态 dialog `NewGUIEncryptionDialog` (mode: encrypt/decrypt/rekey):

- **事务收口走 `VMControl.{encryptVM,decryptVM,rekeyVM}` + `NewGUIStore.{encrypt,decrypt,rekey}` async, 禁止 dialog 直调 Operation**: VMControl 包装内部解析 qemu-img + Win OVMF VARS 模板, dialog/store 不碰后端路径
- **三态 `form → running → done`**: form 收密码 + 校验 + 警告; running 显 spinner + `encProgress` 日志 + "请勿关闭"; done 显 ✔ + (tpmReset 时) TPM 红字
- **running 态 `closeAction=nil` (X 不显) + 无任何按钮**: 加密事务不可中断 (CLAUDE.md X-only-close)
- **加密/解密后必 `clearUnlock(id)` + `refresh()`**: 旧解锁缓存失效 (P0-1)
- **失败走 dialog 内联 error, store 加密方法不设全局 `lastError`**: 避免 dialog inline + 全局 alert 双弹. store `encrypt/decrypt/rekey` 返 `(ok, [tpmReset,] error: String?)`
- **解密 / 改密不要求先解锁**: dialog 自收密码 (跟 CLI 一致)
- **Win guest 加密/改密重置 TPM**: tpmReset 来自 Operation Result (不猜), form + done 态红字预警 (BitLocker recovery key 失效); 解密无 TPM 重置
- **入口 gating**: 明文 + QEMU + 非 macOS → [加密 VM]; 加密 qemuPerfile → [改密]+[解密]; vzSparsebundle → 灰显 "GUI 暂未接入走 hvm-cli". 入口仅 stopped 可点, 动作读 `store.selected` 防 stale probe 闭包
- probeID: `detail.encryption.{encrypt,rekey,decrypt}` / `dialog.{encrypt,decrypt,rekey}.{close,cancel,confirm,done}` / `dialog.{encrypt,decrypt,rekey}.field.{password,confirm,old,new}`

详见 `docs/v4/NEW_GUI_ENCRYPTION.md`.

### 8.3 破坏性操作二次确认

加密 VM 的 **解密** 是不可逆/丢数据动作之一 (CLAUDE.md 破坏性约束), GUI 走 `dialog.confirm(destructive: true)` (解密本身在 dialog form 态已有 TPM/BitLocker 警告). rekey 重置 TPM 同样在 form + done 态红字预警.

---

## 9. 文件索引 (`app/Sources/HVMEncryption/**`)

| 文件 | 职责 |
|---|---|
| `PasswordKDF.swift` | PBKDF2-SHA256 600k: 密码 → master KEK; salt 生成 |
| `EncryptionKDF.swift` | HKDF-SHA256: master KEK → 4 子 key (info 字符串区分用途) |
| `MasterKey.swift` | 32 字节 master KEK 值类型 (SecureBytes 守护) |
| `SecureBytes.swift` | mlock 防 swap + memset_s 清零的字节缓冲 |
| `RoutingMetadata.swift` | 明文 routing JSON (KDF 入口, 跨机器 portable) + I/O |
| `LuksSecretFile.swift` | 32B binary → base64 ASCII 临时 secret 文件 (LUKS UTF-8 要求) |
| `QcowLuksFactory.swift` | qcow2 LUKS create/grow/addNewKeyslot/removeOldKeyslot/rekey/探测 |
| `OVMFVarsLuksFactory.swift` | raw OVMF VARS 模板 → LUKS qcow2 (Win EFI 加密) |
| `SwtpmKeyHelper.swift` | swtpm `--key` 走 stdin Pipe 注入 (不落盘) |
| `EncryptedConfigIO.swift` | config.yaml.enc AES-256-GCM 读写 (HENC magic) |
| `EncryptedBundleIO.swift` | 加密 VM 路由层 (create/unlock/detectScheme + handle) |
| `EncryptVMOperation.swift` | 明文 → 加密冷迁移 (临时目录 + 替换 + TPM 重置) |
| `DecryptVMOperation.swift` | 加密 → 明文冷迁移 |
| `RekeyVMOperation.swift` | 改密 (LUKS keyslot 重写 + config/routing atomic 切换) |
| `SparsebundleTool.swift` | hdiutil sparsebundle 工具层 (vzSparsebundle scheme, 推后) |
| `MountReaper.swift` | stale sparsebundle 挂载回收 (vzSparsebundle, 推后) |
| `SecureErase.swift` | 单文件/目录 best-effort secure delete |

收口: `app/Sources/HVMControl/VMControl+Encryption.swift` (encryptVM/decryptVM/rekeyVM 三态包装).
防中断: `app/Sources/HVMCore/SignalGuard.swift`.
GUI store: `app/Sources/HVM/GUI/Store/NewGUIStore.swift` (解锁缓存 + 5min auto-lock + 加密事务 async).
