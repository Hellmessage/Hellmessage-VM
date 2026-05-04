# 整 VM 加密 (`HVMEncryption`)

## 目标

- 整台 VM 落盘加密, 用户控制密码 (不依赖 FileVault 或硬件密钥)
- 跨机器 portable: 把 `.hvmz` 整目录 + routing JSON 拷到另一台 Mac, 知道密码就能解
- 长事务防崩: SIGINT / SIGTERM / 异常退出不留 partial bundle
- 密码改动毫秒级: rekey 走 LUKS keyslot 重写, 不重新加密磁盘

> 设计稿 [../v3/ENCRYPTION.md](../v3/ENCRYPTION.md) v2.4. 本篇是当前代码现状描述。

## 双 scheme 分流

| scheme | 后端 | 落盘形态 | 状态 |
|---|---|---|---|
| `qemu-perfile` | QEMU | 每文件独立加密 (qcow2 LUKS / OVMF LUKS / swtpm key / config AES-GCM) | ✅ 全闭环 |
| `vz-sparsebundle` | VZ | 整 bundle 套 hdiutil sparsebundle (AES-256 + APFS) | 🟡 仅"创建"接通, 启动解锁推后 |

`VMConfig.encryption.scheme` 字段持久化, `EncryptedBundleIO.detectScheme(_:)` 启动时根据 routing JSON 路径判断 (优先看 `<bundle>/meta/encryption.json`, 否则 `<bundle>.encryption.json`)。

## 加密 bundle 落盘布局

### `qemu-perfile` (QEMU 主路径)

```
foo.hvmz/
├── config.yaml.enc        — AES-256-GCM("HENC" magic + ver + reserved + nonce 12B + cipher + tag 16B)
│                            子 key: EncryptionKDF.SubKeySet.config
├── meta/
│   └── encryption.json    — routing JSON (明文), 跨机器派生 KEK 入口
├── disks/
│   ├── os.qcow2           — qcow2 LUKS-aes-256-xts (子 key: qcow2Disk)
│   └── data-<uuid8>.qcow2 — 同 LUKS qcow2
├── nvram/                 — Win VM only
│   └── efi-vars.qcow2     — OVMF VARS LUKS qcow2 (子 key: qcow2Nvram; raw 模板 → qemu-img convert 加密)
└── tpm/                   — Win VM only
    └── permall            — swtpm encrypt: aes-256-cbc + format=binary, fd=0 注入 (子 key: swtpm)
```

### `vz-sparsebundle` (VZ 路径, 创建已落)

```
<parent>/
├── foo.hvmz.sparsebundle/         — hdiutil AES-256 + APFS 整体加密容器
│   └── /Volumes/HVM-<uuid8>/      — attach mountpoint
│       └── foo.hvmz/
│           ├── config.yaml        — 明文 (sparsebundle 自加密)
│           └── [其余文件结构同明文 VM]
└── foo.hvmz.encryption.json       — routing JSON (明文), 落 sparsebundle 外部
```

## routing JSON schema

`<bundle>/meta/encryption.json` (qemu-perfile) 或 `<bundle>.encryption.json` (vz-sparsebundle), 始终明文, JSON 编码:

| 字段 | 类型 | 用途 |
|---|---|---|
| `schemaVersion` | Int | routing JSON 版本, 当前 3 (v3 含 `guest_os` 字段) |
| `vm_id` | UUID | VM 唯一标识 (与 config.id 一致) |
| `scheme` | enum | `vz-sparsebundle` \| `qemu-perfile` |
| `display_name` | String | VM 显示名, 仅诊断 |
| `guest_os` | String? | `linux` \| `windows` \| nil → 兜底 .linux |
| `kdf_algo` | String | `pbkdf2-sha256` (未来升 argon2id 预留) |
| `kdf_iterations` | UInt32 | 默认 600k (2024 OWASP) |
| `kdf_salt` | base64 | 16 字节 random, JSON 编 base64 |
| `kdf_keylen` | Int | 32 (256-bit) |
| `encrypted_paths` | [String]? | 仅 qemu-perfile 诊断列表; vz-sparsebundle 为 nil |

> routing JSON 故意明文, 因为没它派生不出 master KEK; 用户备份加密 VM 必须把 routing JSON 一起带 (qemu-perfile 在 bundle 内自动跟随; vz-sparsebundle 在 bundle 外, 别忘记)。

## 密钥派生 (KDF)

```
user password
  ↓ PasswordKDF (PBKDF2-SHA256, 600k iter, 16B salt) — CommonCrypto
master KEK (32B, SecureBytes mlock + memset_s)
  ↓ EncryptionKDF (HKDF-SHA256, info 标签区分用途) — CryptoKit
  ├─ qcow2Disk    (32B) — qemu-img --object secret 注入主磁盘 + 数据盘
  ├─ qcow2Nvram   (32B) — OVMF VARS qcow2 LUKS (Win VM)
  ├─ swtpm        (32B) — swtpm --key fd=Pipe 注入 (Win VM)
  └─ config       (32B) — config.yaml.enc AES-256-GCM
```

参数选型:

- **PBKDF2-SHA256 600k iter**: 1Password / Bitwarden 同款; 升 argon2id 预留 `kdf_algo` 字段开关
- **HKDF-SHA256**: 派生子 key salt 留空 (master 已 PBKDF2 派生, 自带高熵), info 标签区分用途防 key reuse
- **AES-256-GCM** (config): CryptoKit 内置, nonce 12B + auth-tag 16B
- **AES-256-XTS** (qcow2): qemu-img 内置 LUKS, 标准 LUKS2 header
- `MasterKey` / `SecureBytes` 用 `calloc + mlock + memset_s` 防 swap / core dump 残留

## 加密事务支持的操作

| CLI 入口 | 函数 | 流程 |
|---|---|---|
| `hvm-cli encrypt <vm>` | `EncryptVMOperation` | 明文 → 加密. 创临时目录逐磁盘 qemu-img convert 转 LUKS, swtpm 重置, atomic rename |
| `hvm-cli decrypt <vm>` | `DecryptVMOperation` | 加密 → 明文. 逆向 qemu-img convert 拆 LUKS, atomic rename |
| `hvm-cli rekey <vm>` | `RekeyVMOperation` | 改密. addNewKeyslot → 改 routing JSON salt+iter → removeOldKeyslot, 毫秒级 |
| `hvm-cli encrypt-status <vm>` | (走 routing JSON) | 不需密码, 只打印 scheme + KDF 参数 + encrypted_paths |
| `hvm-cli create --encrypt` | `EncryptedBundleIO.create*` | 创建即加密, 强制 engine=qemu |

启动解锁:

```
hvm-cli start <vm>  / GUI Start
  ↓ EncryptedBundleIO.detectScheme()
  ↓ tty prompt 密码 (或 --password-stdin / GUI EncryptionPasswordDialog)
  ↓ PasswordKDF (从 routing JSON 取 salt/iter 派生) → master KEK
  ↓ EncryptionKDF.deriveAll() → 4 子 key
  ↓ 解 EncryptedConfigIO → config 明文
  ↓ qemu-img --object secret + swtpm --key fd 注入子 key 起 QEMU
  → VM 启动
```

## Windows guest 加密例外

- `encrypt`: 重置 swtpm key (新生成), 因此 BitLocker / Win Hello 等绑 TPM 的功能会失效, 进 guest 后需重新激活
- `rekey`: 同样重置 swtpm key (swtpm 0.10 上游无 rewrap 工具)
- `decrypt`: swtpm key 仍重置, 需重新激活
- 这是已知约束, GUI / CLI 弹二次确认明确告知

## 加密 VM 克隆

走 D9 等价复制 + 同密码 (CloneManager 加密分支):

1. unlock 源 → 拿 sub keys + config (master KEK 派生)
2. LUKS qcow2 字节级复制 (header + ciphertext, 不解密)
3. 数据盘 uuid8 重生 (LUKS header 不依赖文件名)
4. nvram / tpm / auxiliary 字节复制 (sub keys 不变 → 同密码可解)
5. 重生身份字段 (id / displayName / createdAt / MAC / machine-identifier)
6. config.yaml.enc: 解密 → 改 vmId/displayName/disks → 用源 sub.config 重新加密
7. routing JSON 改 vmId, salt/iter 保留 (master KEK 派生仍正确)

新 VM 跟源同密码; 想换密码自跑 `hvm-cli rekey`。详见 [CLONE.md](CLONE.md)。

## 长事务 SIGINT 防中断

`SignalGuard` (HVMEncryption/SignalGuard.swift, 走 v3 SIGINT_CLEANUP.md):

- encrypt / decrypt / rekey 进入 critical section 时注册 `SIGINT` / `SIGTERM` handler 改成 "标记中止", 不直接 exit
- 操作完一个原子步骤后检查标记, 安全位置才 exit (避免半写入)
- atexit cleanup 钩子: 临时目录 / 临时文件 / 内存 SecureBytes 自动清
- GUI 加密事务 dialog `closeAction = nil` 不让用户关 (走相同 SIGINT-safe 路径)

## 安全约束

- master KEK / sub keys 在 `SecureBytes` (mlock + memset_s 销毁), 不写日志
- 日志 redact 关键字: `password / passphrase / token / key / secret`
- routing JSON 落明文是 by design (派生 KEK 入口); 不存储任何派生后密钥
- 任何代码 / 日志 / 错误 / 报错文案**不**输出 master KEK / sub keys / password / KDF 中间值

## 已实现 / 未实现

**已实现 (QEMU 路径)**:

- ✅ `qemu-perfile` 全 lifecycle: create-encrypted / encrypt / decrypt / rekey / unlock-for-start
- ✅ Linux + Windows guest 加密 (Win 含 nvram + swtpm 加密)
- ✅ 加密 VM clone (D9 同密码字节级 COW)
- ✅ 加密 VM snapshot (走 SnapshotManager.cloneFile, snapshot 也是密文)
- ✅ GUI: CreateVMDialog 加密 toggle / Encrypt+Decrypt+Rekey+EncryptionPasswordDialog 四 dialog / sidebar lock 标识
- ✅ CLI: encrypt / decrypt / rekey / encrypt-status / create --encrypt / start --password-stdin
- ✅ SIGINT-safe 长事务

**未实现 / 推后**:

- ❌ `vz-sparsebundle` 启动解锁路径 (v2.4 决策 QEMU 优先)
- ❌ VZ engine VM encrypt / decrypt / rekey (raw → LUKS qcow2 改引擎需单独 PR)
- ❌ swtpm rewrap (swtpm 0.10 上游无工具, 只能重置 TPM)
- ❌ argon2id KDF (kdf_algo 字段已预留)
- ❌ macOS guest 加密 (VZ-only, 跟 vz-sparsebundle 一起推后)

## 相关文档

- [../v3/ENCRYPTION.md](../v3/ENCRYPTION.md) — v2.4 设计稿
- [../v3/CLONE_SNAPSHOT_ENCRYPTED.md](../v3/CLONE_SNAPSHOT_ENCRYPTED.md) — 加密 VM clone + snapshot 决策
- [../v3/SIGINT_CLEANUP.md](../v3/SIGINT_CLEANUP.md) — SignalGuard 设计
- [VM_BUNDLE.md](VM_BUNDLE.md) — `EncryptionSpec` 字段
- [STORAGE.md](STORAGE.md) — qcow2 LUKS 与磁盘格式分流
- [CLI.md](CLI.md) — encrypt / decrypt / rekey / encrypt-status 命令
- [GUI.md](GUI.md) — 加密 dialog 与 sidebar 标识

---

**最后更新**: 2026-05-05
