# VM Bundle (`.hvmz`) 布局与 `config.yaml` Schema

> 现状文档 (QEMU-only). 描述当前代码实现, 非设计提案.
> 源码: `app/Sources/HVMBundle/**` (BundleLayout / BundleIO / BundleLock / ConfigMigrator /
> VMConfig / BundleDiscovery / ThumbnailWriter) + `app/Sources/HVMEncryption/`
> (RoutingMetadata / EncryptedBundleIO / EncryptedConfigIO).

每个 VM 是一个 **目录 bundle**, 扩展名 `.hvmz`, 默认落在
`~/Library/Application Support/HVM/VMs/<displayName>.hvmz`。bundle 内既有配置 (`config.yaml`
或加密形态 `config.yaml.enc`), 又有磁盘 / NVRAM / TPM 等持久化数据。本文先列布局, 再展开
`config.yaml` 的 schema v3 全字段, 最后讲互斥锁与加密路由。

---

## 1. `.hvmz` 目录布局

布局常量集中在 `BundleLayout`(`app/Sources/HVMBundle/BundleLayout.swift`),
**不允许业务侧自己拼相对路径**。一个典型 (明文) QEMU VM 长这样:

```
Ubuntu.hvmz/
├── config.yaml              # VM 配置 (YAML 1.1). 明文 VM 用这个
├── .lock                    # fcntl flock 互斥锁文件 + 持有者信息 JSON
├── disks/
│   ├── os.qcow2             # 主盘 (role=main), qcow2
│   └── data-<uuid8>.qcow2   # 可选数据盘 (role=data)
├── nvram/
│   ├── efi-vars.fd          # EFI variable store (BootOrder 等; 明文)
│   └── efi-vars.qcow2       # 加密 VM 专用 LUKS NVRAM (与 efi-vars.fd 互斥)
├── tpm/                     # swtpm 持久化 TPM 状态 (Win11 必需; 含 permall)
├── logs/
│   └── console-<date>.log   # guest serial 输出 (内核启动 / dmesg). 唯一允许写 bundle 的 .log
├── meta/
│   ├── thumbnail.png        # VM 缩略图 (atomic 写入)
│   └── encryption.json      # 加密 VM 的 routing 元数据 (明文; 仅加密 VM 有)
├── snapshots/               # qcow2 快照 (按需创建; clone 永不带)
├── run/                     # 运行时 socket (console.sock 等; 运行期生成)
├── unattend.iso             # Windows 装机产物 (AutoUnattend.xml 打包; 按需重生)
└── .unattend-stage/         # unattend ISO 的 staging 源目录 (启动后可清)
```

### 1.1 各路径要点

| 路径 | 常量 / helper | 说明 |
|------|--------------|------|
| `config.yaml` | `BundleLayout.configFileName` / `configURL` | 明文配置. YAML 1.1 |
| `config.yaml.enc` | `EncryptedConfigIO.configEncFileName` | 加密配置. 与 `config.yaml` **互斥**, 同 bundle 不可同时存在 |
| `config.json` | `BundleLayout.legacyConfigFileName` | 老 v1 (JSON) 文件名. **仅** 用于 `BundleIO.load` 探测并报"已断兼容"错误 |
| `.lock` | `lockFileName` / `lockURL` | fcntl flock 互斥; 文件内容记录持有者 (见 §5) |
| `disks/` | `disksDirName` / `disksDir` | 所有磁盘; 主盘 + 数据盘. 创建时按 engine 命名 (恒 qcow2) |
| `nvram/efi-vars.fd` | `nvramFileName` / `nvramURL` | 明文 EFI variable store |
| `nvram/efi-vars.qcow2` | `nvramLuksFileName` / `nvramLuksURL` | 加密 VM 的 LUKS NVRAM, 与 `.fd` 互斥; "加密/明文"靠哪个文件存在判定 |
| `tpm/` | `tpmStateDir` | swtpm 状态 (Win11 TPM 2.0); 加密 VM 加密其中的 `permall` |
| `logs/console-<date>.log` | `logsDir` | guest serial; **唯一**允许写 bundle/logs 的来源 (host 侧 .log 走全局 `HVMPaths.logsDir`) |
| `meta/thumbnail.png` | `metaDir` / `thumbnailName` | `ThumbnailWriter.writeAtomic` 原子落盘 |
| `meta/encryption.json` | `RoutingJSON.locationForQemuBundle` | 加密 routing 元数据 (明文, KDF 参数; 见 §6) |
| `snapshots/` | `snapshotsDirName` / `snapshotDir` | qcow2 快照. clone 永不携带 |
| `run/console.sock` | `serialSocketURL` | 运行时 serial socket. 注: HDP iosurface / QMP / vdagent 等 socket 走全局 `HVMPaths.runDir` (per-uuid), **不**在 bundle 内 |
| `unattend.iso` | `unattendISOURL` | Win11 SetupBypass / 驱动自动装 ISO; `WindowsUnattend.ensureISO` 启动前幂等生成 |
| `.unattend-stage/` | `unattendStageDir` | 打 ISO 前的源目录, 启动后可删 |

> 历史残留常量 `auxiliary` / `aux-storage` / `machine-identifier` / `hardware-model`
> 仍在 `BundleLayout` 中定义, 但属于已移除的 VZ / macOS guest 路径, QEMU-only 下不产出对应文件。

### 1.2 创建时落盘的目录骨架

`BundleIO.create`(明文)与 `EncryptedBundleIO.createQEMU`(加密)创建 bundle 时, 只 mkdir
以下骨架(`0o755`): `disks/` + `logs/` + `meta/` + `nvram/`。`tpm/` / `snapshots/` /
`run/` / `unattend.iso` 等按需在运行 / 装机 / 加密时再生成。
`BundleIO.create` 对已存在路径(哪怕空目录)直接抛 `.bundle(.alreadyExists)`, 不覆盖。

---

## 2. `config.yaml` Schema v3 — `VMConfig` 全字段

`VMConfig`(`app/Sources/HVMBundle/VMConfig.swift`)是 `config.yaml` 的 Codable 映射,
`Codable + Sendable + Equatable`。`Equatable` 让上层 store 做 `if fresh != vms` 的去抖守卫。

### 2.1 顶层字段

| 字段 | 类型 | 缺省 / 兜底 | 说明 |
|------|------|------------|------|
| `schemaVersion` | `Int` | — | 当前 `3`(`VMConfig.currentSchemaVersion`) |
| `id` | `UUID` | 创建时 `UUID()` | VM 唯一标识 |
| `createdAt` | `Date` | 创建时 `Date()` | 创建时间 |
| `displayName` | `String` | — | 显示名 (也决定 bundle 文件名) |
| `guestOS` | `GuestOSType` | — | `linux` / `windows` (枚举只剩这两个, macOS 已移除) |
| `engine` | `Engine` | `.qemu` | 后端引擎. 单 case `qemu`; 老 config 带 `"vz"` 或缺字段 → 兜底 `.qemu` |
| `cpuCount` | `Int` | — | vCPU 数 (热插拔不支持, 改需停机) |
| `memoryMiB` | `UInt64` | — | 内存 MiB (热插拔不支持) |
| `disks` | `[DiskSpec]` | — | 磁盘数组. 必须恰有 1 个 `role=main` |
| `networks` | `[NetworkSpec]` | `[]` | 网卡数组 |
| `installerISO` | `String?` | `nil` | 安装 ISO 的 **绝对路径** (不复制进 bundle); `bootFromDiskOnly=true` 时忽略 |
| `bootFromDiskOnly` | `Bool` | `false` | 装完切 true 直走硬盘 |
| `windowsDriversInstalled` | `Bool` | 缺字段 → 取 `bootFromDiskOnly` 值 | Win 三态: false 挂 ramfb 单设备 / true 挂 `hvm-gpu-ramfb-pci` 让 viogpudo 接管 |
| `clipboardSharingEnabled` | `Bool` | `true` | host↔guest 剪贴板共享 (vdagent). 仅 QEMU 生效, 可运行中 IPC 热切 |
| `macStyleShortcuts` | `Bool` | `true` | host `cmd`→guest `ctrl` 转发. GUI view 级开关, 不持久化到 host 子进程 |
| `displaySpec` | `DisplaySpec?` | `nil` | framebuffer 显式尺寸; nil 走 `guestOS.defaultFramebufferSize` 兜底 |
| `macOS` | `MacOSSpec?` | `nil` | macOS guest 专有 (现已不产出新值, 字段保留) |
| `linux` | `LinuxSpec?` | `nil` | Linux 专有 |
| `windows` | `WindowsSpec?` | `nil` | Windows 专有 |
| `encryption` | `EncryptionSpec?` | `nil` | 加密元信息 (v3 新增); nil / `enabled=false` → 明文 VM |
| `sharedFolders` | `[SharedFolderSpec]` | `[]` | SPICE WebDAV 共享目录 |

> **可选字段不触发 schema 升级**: `displaySpec` / `sharedFolders` 等是 additive 可选字段,
> 老 yaml 缺它们时 `init(from:)` 兜底为 nil / `[]`, 不需要 `ConfigMigrator` 介入。
> 只有改变结构语义(如 v2→v3 加 `encryption`)才 bump `schemaVersion`。

### 2.2 `DiskSpec`(磁盘)

| 字段 | 类型 | 缺省兜底 | 说明 |
|------|------|---------|------|
| `role` | `DiskRole` | — | `main` / `data` |
| `path` | `String` | — | 相对 bundle 根 (如 `disks/os.qcow2`). 运行时唯一来源 |
| `sizeGiB` | `UInt64` | — | 容量 GiB |
| `format` | `DiskFormat` | 缺 → 按 path 扩展名推 (`.qcow2`→qcow2, 否则 raw) | `raw` / `qcow2`. 运行时读此字段, **不靠扩展名推断** |
| `readOnly` | `Bool` | `false` | 只读盘 |

QEMU-only 下新建盘恒 `qcow2`(`BundleLayout.mainDiskFileName` / `dataDiskFileName` 都返
`.qcow2`)。`raw` 仅给导入的 raw 镜像兜底。`format` 缺省按扩展名推断仅作 v1→v2 桥接,
正常 yaml 一定带 `format`。

### 2.3 `NetworkSpec`(网卡, 别名 `NetworkConfig`)

| 字段 | 类型 | 缺省兜底 | 说明 |
|------|------|---------|------|
| `mode` | `NetworkMode` | 未知值 → `.user` | `user` / `vmnetShared` / `vmnetHost` / `vmnetBridged` / `none` |
| `macAddress` | `String` | — | 小写冒号分隔; `generateRandomMAC()` 用 `52:54:00:xx:xx:xx` |
| `socketVmnetPath` | `String?` | `nil` | vmnet* 模式 socket 路径; 空则走 `SocketPaths.*` 标准约定 |
| `bridgedInterface` | `String?` | `nil`(实际推导兜底 `en0`) | bridged 模式桥接的宿主网卡 |
| `deviceModel` | `NICModel` | `.virtio` | `virtio` / `e1000e` / `rtl8139` |
| `enabled` | `Bool` | `true` | false 时启动不挂; 运行中可 QMP 热插拔 |

`mode` 的 `init(from:)` 做老枚举名迁移: `nat→user` / `shared→vmnetShared` /
`hostOnly→vmnetHost` / `bridged→vmnetBridged`。计算属性
`effectiveSocketPath` / `effectiveBridgedInterface` / `qemuStableSuffix` 派生运行时值。

### 2.4 `SharedFolderSpec`(共享目录, SPICE WebDAV)

| 字段 | 类型 | 缺省兜底 | 说明 |
|------|------|---------|------|
| `hostPath` | `String` | — | host 绝对路径 (入口校验, 不许相对 / symlink 越界) |
| `name` | `String` | — | WebDAV root 名; 限 `[a-zA-Z0-9_-]{1,32}`(`sanitizeName`) |
| `readOnly` | `Bool` | `true` | 默认只读 |
| `autoMount` | `Bool` | `true` | guest 自动挂载 (v1 不暴露) |

仅 QEMU + Linux/Windows guest 生效; VM running 改 `sharedFolders` 被拒(chardev 不支持热挂)。

### 2.5 `EncryptionSpec`(加密元信息, v3 新增)

| 字段 | 类型 | 缺省兜底 | 说明 |
|------|------|---------|------|
| `enabled` | `Bool` | `false` | 明文 VM 为 false |
| `scheme` | `EncryptionScheme?` | `nil` | 仅 `qemuPerfile`(`"qemu-perfile"`); VZ-sparsebundle 已移除 |
| `createdAt` | `Date?` | `nil` | 加密时间 (仅展示) |

> **KDF 参数(salt / iterations)不在这里**, 而在 routing JSON(`meta/encryption.json`)。
> 原因: config 本身可能被加密(`config.yaml.enc`), 要解 config 才能读 KDF 参数会陷死循环;
> routing JSON 是加密外的明文, 跨机器 portable 入口。详见 §6。

### 2.6 OS 专有 spec

- `MacOSSpec`: `ipsw` / `autoInstalled` — macOS guest 已移除, 字段保留作 schema 结构稳定。
- `LinuxSpec`: `kernelCmdLineExtra` / `rosettaShare`。
- `WindowsSpec`: `secureBoot`(默认 true) / `tpmEnabled`(true) / `bypassInstallChecks`(true) /
  `autoInstallVirtioWin`(**默认 false** — UTM Guest Tools 已替代 virtio-win.iso) /
  `autoInstallSpiceTools`(true)。缺字段时 `init(from:)` 全部走上述默认。

### 2.7 关键计算属性 / helper(运行时入口)

- `effectiveDisplaySpec` — framebuffer 权威尺寸: 优先 `displaySpec`, 否则
  `guestOS.defaultFramebufferSize`(Linux `1024×768`, Windows `1920×1080`)。
- `mainDiskRelPath` / `mainDiskURL(in:)` — 主盘路径从 `disks` 里 `role=.main` 那条读,
  **禁止**用 `BundleLayout` 常量推断主盘路径。
- `validate()` — 校验 `engine ∈ [.qemu]`; `BundleIO.save` / `hvm-cli create` 主动调,
  Codable 本身不强制(保留容错)。

---

## 3. YAML 1.1 (Yams) + 序列化

- **格式**: YAML 1.1, 由 `Yams`(libyaml 包装)解析, 文件名固定 `config.yaml`(不再用 `.json`)。
- **encode 选项**(`BundleIO.save` 与 `EncryptedConfigIO.save` 一致, 保证 round-trip 字节稳定):
  `indent = 2` / `sortKeys = true` / `allowUnicode = true`。
- **原子写入**: 先写 `.config.yaml.tmp`, 再 `replaceItemAt` / `moveItem`。加密配置同款,
  走 `.config.yaml.enc.tmp` 中转。

### 3.1 加载流程(`BundleIO.load`)

1. 无 `config.yaml` 但有 `config.json` → 报 **已断兼容** 错误("请重新创建 VM 或手动迁移")。
2. 仅解析 `_SchemaEnvelope`(只取 `schemaVersion`)决定后续:
   - `schemaVersion > current` → `.invalidSchema`(让用户升 HVM)。
   - `schemaVersion < current` → 走 `ConfigMigrator.migrate` 升级链拿到当前版本 yaml,再 decode。
   - 相等 → 直接 decode。
3. decode 出 `VMConfig` 后做 **sandbox 校验**(先于任何路径 stat): 所有 disk 的 `path`
   必须落在 `disks/` 下、不含 `..`(`isDiskPathInSandbox`), 防 `path="../../etc/passwd"`。
4. 校验主盘唯一(恰 1 个 `role=main`)且文件存在, 否则抛对应错。

---

## 4. Schema 版本与迁移链(`ConfigMigrator`)

`VMConfig.currentSchemaVersion = 3`。历史:

| 版本 | 格式 | 变化 | 状态 |
|------|------|------|------|
| v1 | JSON (`config.json`) | 初版, `DiskSpec` 无 `format` | **已断兼容** — load 检测到 `config.json` 直接报错 |
| v2 | YAML (`config.yaml`) | 加 `DiskSpec.format`(raw / qcow2) | 仍可读, 自动升 v3 |
| v3 | YAML | 加顶层 `encryption: EncryptionSpec?` | 当前 |

`ConfigMigrator.migrate(data:from:to:)` 链式升级 `v_n → v_n+1 → … → current`, 一步一步,
不跨版本跳。当前实现只有一条 hook `migrate_v2_to_v3`:

- additive — 仅在 `encryption` 缺省时加 `encryption: { enabled: false }`, 并把 `schemaVersion`
  改 3, 用 Yams round-trip 重 dump。
- **幂等约束**(硬规则): 每条 hook 必须满足 `hook(hook(x)) ≡ hook(x)`。`migrate_v2_to_v3`
  先 grep `schemaVersion >= 3` 提前 return, 多套防御。
- 升级后 `BundleIO.save` 会以 `currentSchemaVersion` 重写 yaml, 下次 load 直接走当前版本。

---

## 5. 唯一来源原则 + 互斥锁

### 5.1 唯一来源原则(per-VM 配置)

所有 per-VM 配置项(磁盘路径 / 格式 / 大小 / 网卡 / engine 等)**只**落 `config.yaml`,
运行时读 `VMConfig` 字段, **禁止**从 `BundleLayout` 等全局常量推断 per-VM 路径或格式:

- 主盘路径 → `VMConfig.mainDiskRelPath` / `mainDiskURL(in:)`, **不**用 `BundleLayout` 推断。
- 磁盘格式 → `DiskSpec.format`, **不**靠文件扩展名推断。
- `BundleLayout` 仅保留 **与 VM 无关** 的结构性命名常量(`disksDirName` / `lockFileName` /
  `nvramFileName` 等), 以及 **仅创建时调一次** 的默认文件名生成器
  (`mainDiskFileName(for:)` / `dataDiskFileName(uuid8:engine:)`)。

### 5.2 `BundleLock` — fcntl flock 单进程互斥

`BundleLock`(`app/Sources/HVMBundle/BundleLock.swift`)对 `<bundle>/.lock` 做
`flock(LOCK_EX | LOCK_NB)`, 实现 **一个 `.hvmz` 同时只能被一个进程打开**(CLAUDE.md
能力边界硬约束)。

- **两种 mode**: `runtime`(VM 运行)/ `edit`(改配置)。抢锁失败抛 `.bundle(.busy)`
  (附持有者 pid / mode)或 `.lockFailed`。
- **持有者信息**: 抢到锁后把 `HolderInfo`(`pid` / `host` / `socketPath` / `mode` / `since`,
  JSON + iso8601)写入 `.lock` 文件正文 —— **这是诊断信息, 不是锁本身**。`runtime` 模式
  在此记录 IPC 监听的 socket 路径, 让别的进程知道去哪儿连。
- **只读探测**: `BundleLock.isBusy(_:)`(尝试抢锁立即释放, `hvm-cli list` 判 VM 是否在跑)
  与 `inspect(_:)`(只读持有者信息, 不抢锁)。
- **release 线程安全**: `release()` 由 `NSLock` 串行化 + `released` 守卫, 防 `deinit` 与显式
  release 并发导致 `close(fd)` 跑两次(macOS `close` 非幂等)。
- **跨主机限制**: `flock` 只在本机 inode 上互斥。init 时 `statfs` 探测卷类型, 非 `apfs`/`hfs`
  (NFS/SMB/exFAT 等)给一次 warning(进程级 dedup, 不强禁)—— 跨主机同开同一 bundle 会破坏
  `disks/` 数据。

---

## 6. 加密 VM 的文件路由

加密 VM 走 **qemu-perfile** scheme(VZ-sparsebundle 已随 VZ 移除)。明文 ↔ 加密的差异:

| 项 | 明文 VM | 加密 VM (qemu-perfile) |
|----|---------|------------------------|
| 配置文件 | `config.yaml` | `config.yaml.enc`(AES-256-GCM) |
| NVRAM | `nvram/efi-vars.fd` | `nvram/efi-vars.qcow2`(LUKS) |
| 磁盘 | `disks/*.qcow2` | `disks/*.qcow2`(qcow2 LUKS) |
| TPM | `tpm/permall` | `tpm/permall`(加密) |
| routing 元数据 | 无 | `meta/encryption.json`(明文) |

判定方式: `EncryptedBundleIO.detectScheme` 看 `meta/encryption.json` 是否存在;
`EncryptedConfigIO.isEncrypted` 看 `config.yaml.enc` 是否存在; `config.yaml` 与
`config.yaml.enc` **互斥**, `efi-vars.fd` 与 `efi-vars.qcow2` **互斥**。

### 6.1 `config.yaml.enc` 二进制格式(`EncryptedConfigIO`)

```
[0..3]   magic = "HENC"  (0x48 0x45 0x4E 0x43)
[4]      format version = 0x01
[5..7]   reserved = 0,0,0
[8..]    AES.GCM.SealedBox.combined (12B nonce + ciphertext + 16B auth tag)
```

8 字节头部对齐, `head -c 8` / `xxd | head -1` 可一眼识别。明文 = `config` → YAML(同
`BundleIO.save` 选项)→ utf8 → AES-256-GCM seal(随机 12B nonce)。解密失败(auth tag 校验
不过)统一报 `.wrongPassword`(密码错或文件被改, 用户视角等价)。

### 6.2 `meta/encryption.json`(routing 元数据, 明文)

`RoutingMetadata`(`app/Sources/HVMEncryption/RoutingMetadata.swift`)是加密外的明文 JSON,
snake_case 字段, 是 **跨机器 portable 入口**(目标机读 JSON 拿 KDF 参数 + 输密码 →
PBKDF2 派生 master KEK → 解锁)。注意它有 **自己的 schema 版本**(与 `VMConfig.schemaVersion`
不同维度), 当前 `RoutingMetadata.currentSchemaVersion = 3`。

| 字段 (JSON key) | 类型 | 说明 |
|-----------------|------|------|
| `schemaVersion` | `Int` | routing JSON 自身版本(v3 加 `guest_os`) |
| `vm_id` | `UUID` | VM id |
| `scheme` | `EncryptionScheme` | `qemu-perfile` |
| `display_name` | `String` | 显示名(解锁前 GUI 用) |
| `guest_os` | `GuestOSType?` | v3 加; 老 v2 JSON 缺 → 调用方兜底 `.linux` |
| `kdf_algo` | `String` | `"pbkdf2-sha256"` |
| `kdf_iterations` | `UInt32` | PBKDF2 迭代数(`PasswordKDF.defaultIterations = 600_000`) |
| `kdf_salt` | `Data` | 16 字节随机 salt(JSON base64) |
| `kdf_keylen` | `Int` | 派生 key 长度 `32`(256 bit) |
| `encrypted_paths` | `[String]?` | 诊断用: 哪些文件被加密(`config.yaml.enc` / `disks/os.qcow2` / `disks/data-*.qcow2` / `nvram/efi-vars.qcow2` / `tpm/permall`) |

加密 routing JSON 位置由 `RoutingJSON.locationForQemuBundle` 给出
(`<bundle>/meta/encryption.json`), atomic 写入。解锁主流程:
读 routing JSON → PBKDF2(password, salt) → master KEK → `EncryptionKDF.deriveAll` 派生子 key →
`EncryptedConfigIO.load` 解出 `VMConfig`。

---

## 7. Codable 缺省兜底约定

新增非可选字段时, **必须** 在 `init(from:)` 提供合理默认, 防老 yaml 解码失败。本仓库已落的兜底:

- `engine` 缺(或老值 `"vz"`)→ `.qemu`。
- `disks[].format` 缺 → 按 path 扩展名推(`.qcow2`→qcow2, 否则 raw)。
- `disks[].readOnly` 缺 → `false`。
- `networks` 缺 → `[]`; `networks[].mode` 老枚举名迁移(`nat→user` 等), 未知值 → `.user`;
  `deviceModel` 缺 → `.virtio`; `enabled` 缺 → `true`。
- `bootFromDiskOnly` 缺 → `false`; `windowsDriversInstalled` 缺 → 取 `bootFromDiskOnly` 的值。
- `clipboardSharingEnabled` / `macStyleShortcuts` 缺 → `true`。
- `windows.*` 缺 → 各自默认(多为 true; `autoInstallVirtioWin` 例外为 false)。
- `sharedFolders` 缺 → `[]`。
- `encryption` 缺 → `nil`(`ConfigMigrator` v2→v3 会补 `enabled: false`)。

> 反例(历史教训): 加密 VM 改 config 只修一处 `BundleIO.save` 而漏其它写 config 的路径,
> 导致 ISO 切换 / CPU·内存编辑 / disk 增删 / 剪贴板共享等同模式调用点全有同 bug。改
> `sharedFolders` 等配置必须走加密分流(`EncryptedConfigEditor.save` / store 的 `saveConfig`),
> **禁止**业务侧直接 `BundleIO.save`。

---

## 相关源文件

- `app/Sources/HVMBundle/BundleLayout.swift` — 目录布局常量 + 路径 helper
- `app/Sources/HVMBundle/VMConfig.swift` — schema v3 Codable + 全字段 + 兜底 + helper
- `app/Sources/HVMBundle/BundleIO.swift` — create / load / save(原子写, sandbox 校验)
- `app/Sources/HVMBundle/BundleLock.swift` — fcntl flock 单进程互斥 + 持有者信息
- `app/Sources/HVMBundle/ConfigMigrator.swift` — schema 迁移链(v2→v3)
- `app/Sources/HVMBundle/BundleDiscovery.swift` — `.hvmz` 枚举 / 引用解析
- `app/Sources/HVMBundle/ThumbnailWriter.swift` — `meta/thumbnail.png` 原子落盘
- `app/Sources/HVMEncryption/RoutingMetadata.swift` — `meta/encryption.json` 路由元数据
- `app/Sources/HVMEncryption/EncryptedBundleIO.swift` — 加密 VM 路由层 (create / unlock)
- `app/Sources/HVMEncryption/EncryptedConfigIO.swift` — `config.yaml.enc` 加解密格式
