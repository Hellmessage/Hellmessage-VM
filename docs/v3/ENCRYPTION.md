# VM 整盘加密 (`HVMEncryption`)

> 状态: **设计稿 v2.3 — 混合方案 + 强制密码 + LUKS passphrase base64 编码 (2026-05-04)**, PR-1 ~ PR-5 已落地, 后续 7 个 PR 待开。
>
> **设计变更日志**:
> - **v1**: 单方案 A "sparsebundle 套整 bundle", 双后端透明 — **已废弃**
> - **v2**: 改混合方案 — VZ 走 sparsebundle / QEMU 走 per-file native — **被 v2.2 部分覆盖**
> - **v2.1**: E0/E1/E2 PoC 通过, D10/D11/D12 锁定
> - **v2.2**: 用户拍板 **强制密码 + 跨机器 portable** — 取消 Keychain 缓存路径, master KEK 永远从 password PBKDF2 派生, salt + iter 写明文 routing JSON
> - **v2.3 (当前)**: PR-5 实施时发现 **LUKS passphrase 必须 UTF-8 合法**, 32 字节 binary key 不能直接当 passphrase. 锁定 D13: **sub key → base64 编码 ASCII 字符串当 LUKS passphrase**, 通过公共 `LuksSecretFile` 模块强制. PR-4 测试侥幸 (用了合法 UTF-8 字节 0x42 等) 已修
>
> 见底部"设计变更"小节定位历史决策依据.

## 目标

- **per-VM 加密**: 每台 VM 一把独立 master KEK (派生子 key 给各个加密点), 一台泄露不波及其他
- **双后端混合实现**:
  - **VZ** → sparsebundle 套整 bundle (整体容器级加密, **VZ raw 不能 in-place 加密的硬约束**)
  - **QEMU** → 每个文件独立加密 (qcow2 LUKS / OVMF VARS LUKS / swtpm key / AES-GCM config), **接近 VMware per-file 形态**
- **跨机器 portable** (v2.2 硬要求): 加密 VM 拷到任意 macOS 机器, 输原密码即可启动. 不依赖目标机 Keychain / 不依赖 iCloud / 不依赖 HVM 安装时机
- **强制密码每次输入** (v2.2 硬要求): 启动 VM 必须输密码, **不**提供"记住密码"选项. 用户对密码可控, 防设备未锁屏被启 VM
- **macOS 原生路径**: 走 hdiutil sparsebundle / qcow2 LUKS / Apple CryptoKit, 不引第三方加密库, 不写自家 crypto
- **不破坏现有 bundle 语义**: VZ 路径 attach 后挂载点目录布局 1:1, QEMU 路径文件位置不变 (内容 ciphertext)
- **可逆**: 用户可把已加密 VM 转回明文, 反之亦然 (冷迁移, 不在线)
- **改密**: master KEK 改 → 重密 keyslot (qcow2 / sparsebundle keybag, 毫秒级, 不重密 DEK)
- **忘密不可恢复**: 不留 master key / 后门 / Keychain 缓存

## VMware 模型对照

| 模块 | VMware | HVM (混合方案) |
|---|---|---|
| 加密对象 | `.vmx` / `.vmdk` / `.nvram` / `.vmem` / `.vmss` / 快照 | **VZ**: 整 bundle (`.hvmz.sparsebundle`) **QEMU**: per-file (qcow2 / efi-vars-luks / swtpm / config) |
| 数据密钥 (DEK) | AES-256, 包于 vmx | **VZ**: AES-256-XTS 由 sparsebundle 内 keybag 管 **QEMU**: AES-256-XTS 由 qcow2 LUKS keyslot 管 / AES-GCM-256 由 CryptoKit 用 |
| 密钥包 (KEK) | 用户密码 / KMS / vCenter | 用户密码 / Keychain 随机 KEK (Touch ID) — 双后端共用 |
| 解锁时机 | power-on 输密码 | start VM 时 attach sparsebundle (VZ) / 派生 4 个子 key 注入 QEMU + swtpm (QEMU) |
| 改密 | 不重密 DEK | **VZ**: `hdiutil chpass` (毫秒) **QEMU**: 各 keyslot 重写 + AES-GCM config 重密 (毫秒) |
| 限制 | 加密 VM 不能 PXE / 部分 USB 限制 | 见下"能力边界" |
| 不可恢复 | 是 | 是 |

### 实现差异(为什么不是 1:1 VMware)

VMware 是 hypervisor 内部解密 vmdk → bytes 在 VMware 进程内存. HVM 走两条路:

| 维度 | VMware | HVM-VZ (sparsebundle) | HVM-QEMU (per-file) |
|---|---|---|---|
| 磁盘上看到的 | N 个加密文件 | 1 个加密 sparsebundle blob | N 个独立加密文件 ✅ 形似 VMware |
| 运行期 host root 能否偷读 magic | ❌ (VMware 进程内存) | ⚠️ 挂载点明文可读 | ✅ 偷不到 (QEMU 进程内部解密) |
| crash 残留 | 无 (VMware 进程退出即明文消失) | sparsebundle auto-detach 兜底 | 无 (qcow2 ciphertext on disk) |

**根因**: `VZDiskImageStorageDeviceAttachment` 只接受真实 raw 字节, **VZ 没有 hypervisor 内部 decrypt hook**. 所以 macOS guest (= 必走 VZ) 永远只能容器级加密. Linux/Windows guest 走 QEMU 时拿到 VMware 同等保护 (per-file + 运行期 host 隔离).

威胁模型评估见 [docs/v1/SECURITY.md](../v1/SECURITY.md) (本稿合入后落地). HVM 单机产品场景, 实际威胁主要是磁盘 / 笔记本被偷 — 双后端在此模型下保护等价.

## 路线选型

| 方案 | 加密范围 | VZ 兼容 | QEMU 兼容 | 改动量 | 选用 |
|---|---|---|---|---|---|
| A. sparsebundle 套整 bundle (双后端共用) | 整 VM | ✅ 透明 | ✅ 透明 | 中 | ✗ — 实现 ≠ VMware, 运行期 host 进程可读挂载点明文 |
| B. qcow2 LUKS only | 仅 disks | ❌ raw 不支持 | ✅ native | 小 | ✗ — VZ 后端裸奔 |
| C. APFS 加密卷 / FileVault 子卷 | 全部 (全有/全无) | ✅ | ✅ | 0 | ✗ — 不是 per-VM, 无法 per-VM 改密 / per-VM 迁移 |
| **D. 混合: VZ-sparsebundle + QEMU-per-file** | 双后端全保护 | ✅ 容器级 | ✅ per-file native | 大 | ✅ |

**选 D**. 理由:
- VZ raw 限制无解 → 必须容器级
- QEMU 走 native LUKS 拿 VMware-like per-file + 运行期隔离, 不浪费 QEMU 内置能力
- 双路径用同一 master KEK 统一 (HKDF 派生), CLI / GUI / config schema 接口一致

## 双路径详细设计

### 路径 1: VZ 后端 (sparsebundle 套整 bundle)

#### Bundle 结构

```
~/Library/Application Support/HVM/VMs/Foo.hvmz.sparsebundle/   # 真实落盘
├── Info.plist
├── token                          # KEK 解 DEK 的 keybag (hdiutil 维护)
└── bands/                         # 分块 ciphertext (默认 8 MiB / band)

# attach 后挂载点 (运行期临时存在)
~/Library/Application Support/HVM/mounts/<uuid8>/Foo.hvmz/
    ├── config.yaml                # 普通 yaml (在加密卷内自然受保护)
    ├── disks/os.img               # raw, VZ 直读
    ├── disks/data-*.img           # 数据盘 raw
    ├── nvram/efi-vars.fd          # EFI VARS
    ├── auxiliary/                 # macOS aux-storage / hardware-model / machine-identifier
    ├── snapshots/                 # bundle 内 snapshot (clonefile, 在加密卷上仍 COW)
    ├── meta/thumbnail.png
    └── .lock
```

判定: `~/Library/.../VMs/` 下面是 `Foo.hvmz/` (目录 = 明文) 还是 `Foo.hvmz.sparsebundle/` (目录 = 加密容器). 同卷可共存.

挂载点路径用 `<uuid8>` 而非 `<displayName>`: 避免中文 / 特殊字符 / 同名 VM 冲突.

#### 工具层 (PR-1, **已落地**)

`HVMEncryption/SparsebundleTool.swift`:

```swift
public enum SparsebundleTool {
    public static func create(at: URL, password: String, options: CreateOptions) throws
    public static func attach(at: URL, password: String, mountpoint: URL) throws -> AttachInfo
    public static func detach(mountpoint: URL, force: Bool = false) throws
    public static func info() throws -> [InfoEntry]                  // 列已 attach 的 image
    public static func chpass(at: URL, oldPassword: String, newPassword: String) throws
}
```

固定决策: AES-256, FS=APFS, layout=NONE, spotlight=off. 密码不进 argv (走 stdin NUL-terminated).

PR-1 测试覆盖 (8 个真跑 hdiutil): create / attach / write / detach round-trip / re-attach 持久化 / 错密码 / chpass 正反路径 / info 列已挂载 / detach 已卸载 noop. **多语言 stderr 识别** (en / zh-Hans / zh-Hant / ja / es / fr / de + 兜底 "error 35").

### 路径 2: QEMU 后端 (per-file native 加密)

#### Bundle 结构

```
~/Library/Application Support/HVM/VMs/Foo.hvmz/        # 仍是普通目录, 单独文件加密
├── config.yaml                                        # AES-GCM in-place (HVM 主进程读)
├── disks/os.qcow2                                     # qcow2 LUKS native
├── disks/data-*.qcow2                                 # qcow2 LUKS native
├── nvram/efi-vars.qcow2                               # qcow2 LUKS wrap (替代原 efi-vars.fd raw)
├── tpm/permall                                        # swtpm --key 加密
├── meta/thumbnail.png                                 # 不加密 (无敏感)
├── meta/encryption.json                               # 路由信息 (明文): scheme=qemu-perfile, kek_source, ...
└── .lock
```

判定: 看 `meta/encryption.json` 是否存在 + `scheme` 字段值. 加密 / 明文 QEMU VM 共用 `.hvmz` 目录扩展名 (与 VZ 加密的 `.hvmz.sparsebundle` 区分).

#### 加密点四件套

| 加密点 | 工具 | DEK 来源 |
|---|---|---|
| `disks/*.qcow2` | qcow2 native LUKS (`qemu-img create -o encrypt.format=luks,encrypt.key-secret=sec0`) | HKDF(master, "qcow2-disk") |
| `nvram/efi-vars.qcow2` | 同上, OVMF VARS 改成 LUKS qcow2 | HKDF(master, "qcow2-nvram") |
| `tpm/*` | swtpm `--key file=<unix-socket>,mode=aes-cbc-256,format=binary` | HKDF(master, "swtpm") |
| `config.yaml` | Apple CryptoKit `AES.GCM`, in-place 加密 (HVM 主进程读) | HKDF(master, "config") |

#### 待 PoC 验证 (P0 must-pass before PR-6)

| 编号 | 项目 | 验证 |
|---|---|---|
| **E1** | swtpm `--key` 是否支持加密 NVRAM state | 5 分钟 PoC: 用 HVM 打包的 swtpm 跑一遍 `--key file=...,mode=aes-cbc-256` 看能否启动 + reboot 后能否解密 |
| **E2** | QEMU `-object secret,id=,file=<path>` socket / file 兼容性 | 测试 `mkfifo` / unix domain socket 能否当作 `file=`; 不行就走 0600 临时文件 + 启动后 unlink |
| **E3** | qcow2 LUKS rekey 性能 | `qemu-img reencrypt` (qemu 8.x+) on 64 GiB qcow2; 期望 < 100 ms (keyslot only) |

E1 / E2 不通过 → 改方案 (e.g., swtpm 走 sparsebundle 子方案, secret 走 envvar via `secret-key=base64,data=...`).

## 密钥管理

### 三层密钥(v2.2)

```
user password (用户记忆 / 输入, 永远不落盘)
       │
       │  PBKDF2-SHA256(password, salt, iter=600k, keylen=32)
       │  salt 16 字节随机, 每 VM 独立, 写明文 routing JSON
       ↓
master KEK (32 字节, HVM 进程内存中, 启动后即刻 drop)
       │
       ├─ VZ path:    feed password 字符串给 hdiutil → hdiutil 自家 PBKDF2 → keybag → DEK
       │              (注: VZ 路径 master KEK 不在 HVM 进程持有, hdiutil 自包管 KDF)
       │
       └─ QEMU path:  HKDF-SHA256(master, info=...) →
                       ├─ qcow2-disk-key  (32B) → -object secret,id=sec_disk,file=…
                       ├─ qcow2-nvram-key (32B) → -object secret,id=sec_nvram,file=…
                       ├─ swtpm-key       (32B) → swtpm --key fd=N
                       └─ config-key      (32B) → AES.GCM.SealedBox(config.yaml)

DEK (qcow2/sparsebundle 内部 keyslot, HVM 进程**绝不持有**)
```

**关键**: master KEK 是 password + salt 的纯函数, 永远从输入端派生, **不缓存到 Keychain / 不写盘**. salt 公开(写明文)— 标准做法, 不损失安全性.

### KEK 来源 (单一)

| 来源 | 启动体验 | 风险 |
|---|---|---|
| **`password`** (唯一) | 每次启动手输 | 输错重试; 密码丢失数据不可恢复 |

**v2.2 删除 Keychain 缓存路径**. 理由:
1. 跨机器 portable 必须 password 派生 (Keychain 不跨机器)
2. 用户拍板"取消记录密码, 强制每次输" — VeraCrypt / BitLocker / FileVault Recovery 同款. 安全 / 直观, 防设备未锁屏直接启 VM
3. 简化代码 (不需要 KeychainKEK 模块) + 简化 UX (不需要 "记住密码 (Touch ID)" 切换 / 钥匙串损坏 fallback)

### KDF 参数 (写 routing JSON, 跨机器必备)

| 参数 | 默认值 | 备注 |
|---|---|---|
| `kdf_algo` | `pbkdf2-sha256` | 算法 ID (未来切 argon2id 时升 v2 字段) |
| `kdf_iterations` | `600000` | 2024 OWASP 推荐值, 1Password / Bitwarden 同款. M1/M2/M3 单次派生 ~150 ms 可接受 |
| `kdf_salt` | 16 字节 random, base64 | 每 VM 独立, 创建时一次性生成 |
| `kdf_keylen` | `32` | 256 bit AES |

routing JSON 例:
```json
{
  "schemaVersion": 2,
  "vm_id": "<uuid>",
  "scheme": "qemu-perfile",
  "kdf_algo": "pbkdf2-sha256",
  "kdf_iterations": 600000,
  "kdf_salt": "Y2NkZjI4NDY2NTQ4ZmE5Y2RkYWRkOTQ2",
  "kdf_keylen": 32,
  "display_name": "Foo"
}
```

### 跨机器迁移

```
源机:                        目标机:
1. Foo.hvmz/.sparsebundle    1. cp -R Foo.hvmz/sparsebundle from 源
   或 Foo.hvmz/ (QEMU 路径)      到目标 ~/Library/.../HVM/VMs/
2. routing JSON 同上          2. 自动识别加密 VM (扩展名 / routing JSON)
                              3. 启动 → 弹密码框
                              4. 输源机密码
                                 ↓
                                 PBKDF2(password, salt from routing JSON)
                                 → master KEK
                                 ↓
                                 [VZ] hdiutil attach
                                 [QEMU] HKDF 派生 → 注入
                              5. VM 起
```

**目标机不需安装任何额外组件**(只要装了 HVM). Keychain / iCloud / 网络都不需要.

### 改密 (rekey)

VZ 路径: `hdiutil chpass <sparsebundle>` — 仅换 keybag, 几毫秒.

QEMU 路径:
1. 用户输老密码 → PBKDF2 → 老 master KEK → HKDF → 老 4 子 key
2. 用户输新密码 → 生成新 salt → PBKDF2 → 新 master KEK → HKDF → 新 4 子 key
3. `qemu-img reencrypt` 改各 qcow2 keyslot (毫秒)
4. swtpm: stop → 用老 key 解出 state, 用新 key 重写 → start (短停机)
5. AES-GCM 重密 config.yaml
6. 写新 salt 到 routing JSON

### 忘密 / 失锁

数据永久不可读. **不留后门 / 不留 Keychain 备份 / 不留 master KEK escrow**.

## config.yaml schema 变化 (v3)

### 顶层加 `encryption` 字段

```yaml
schemaVersion: 3
encryption:
  enabled: true
  scheme: vz-sparsebundle      # vz-sparsebundle | qemu-perfile
  created_at: 2026-05-04T...
```

明文 VM 的 `encryption` 字段缺省 / `enabled: false`.

KDF 参数 (`kdf_algo` / `kdf_iterations` / `kdf_salt` / `kdf_keylen`) **不**写到 config.yaml — config.yaml 自身可能加密 (QEMU 路径), 解开 config.yaml 才能读 KDF 参数会陷死循环. 所以 KDF 参数全在 routing JSON.

### 路由元数据(明文,在加密**外**) — 跨机器 portable 关键

VZ 路径: sparsebundle **同级**写 `Foo.hvmz.encryption.json`(明文,只放 routing + KDF):

```json
{
  "schemaVersion": 2,
  "vm_id": "<uuid>",
  "scheme": "vz-sparsebundle",
  "kdf_algo": "pbkdf2-sha256",
  "kdf_iterations": 600000,
  "kdf_salt": "<16 bytes base64>",
  "kdf_keylen": 32,
  "display_name": "Foo"
}
```

注: VZ 路径 master KEK 不由 HVM 派生 (hdiutil 自管 PBKDF2), 所以这里的 `kdf_*` 字段对 VZ 路径**仅记录信息, 不参与启动派生**. 但写在 routing JSON 里方便后续 cross-engine 改密 / 工具诊断.

QEMU 路径: `<bundle>/meta/encryption.json` 直接放在 bundle 内 (config.yaml 加密了, 这个路由文件不能加密):

```json
{
  "schemaVersion": 2,
  "vm_id": "<uuid>",
  "scheme": "qemu-perfile",
  "kdf_algo": "pbkdf2-sha256",
  "kdf_iterations": 600000,
  "kdf_salt": "<16 bytes base64>",
  "kdf_keylen": 32,
  "display_name": "Foo",
  "encrypted_paths": ["disks/os.qcow2", "disks/data-*.qcow2", "nvram/efi-vars.qcow2", "tpm/permall", "config.yaml"]
}
```

**跨机器 portable 全靠 routing JSON**: 目标机读 routing JSON → 拿 salt + iter → PBKDF2(password, salt) → 派生同样的 master KEK → 解密 / 启动.

不挂载 / 不解密就能列 VM + 显示加密状态. 路由文件**不含**任何密码 / KEK / DEK 可解密信息.

### ConfigMigrator

v2 → v3: `encryption` 缺省塞 `enabled: false` 即升完. 无破坏性变更.

## 生命周期

### 创建加密 VM

VZ 路径:
```
1. 用户向导勾"加密"+ 输密码 (一次, 创建时确定)
2. EncryptedBundleIO.create:
   a. 生成 16 字节 random salt → 写 .encryption.json routing (含 kdf_* 参数)
   b. SparsebundleTool.create(at:.hvmz.sparsebundle, password:user-input, ...)
      (hdiutil 自家 PBKDF2 包 password 到 keybag)
   c. SparsebundleTool.attach → mountpoint
   d. 在 mountpoint 内走原 BundleIO.create (写 config.yaml 等)
   e. detach (除非紧接着启动)
```

QEMU 路径:
```
1. 用户向导勾"加密"+ 输密码
2. EncryptedBundleIO.create:
   a. mkdir <bundle>.hvmz/...
   b. 生成 16 字节 random salt → 写 meta/encryption.json routing (含 kdf_* 参数)
   c. master_KEK = PBKDF2-SHA256(password, salt, iter=600k, keylen=32)
   d. 4 子 key = HKDF-SHA256(master, info=...)
   e. QcowLuksFactory.create(disks/os.qcow2, sizeGiB, key=qcow2-disk-key)
   f. QcowLuksFactory.create(nvram/efi-vars.qcow2, ..., key=qcow2-nvram-key)
   g. swtpm state 用 swtpm-key 加密初始化 (Win VM)
   h. EncryptedConfigIO.save(config, key=config-key) → config.yaml AES-GCM in-place
   i. master_KEK / 子 key 立即从内存清理 (尽量, Swift Data 不强保证)
```

### 启动加密 VM

VZ 路径:
```
1. 检测 .hvmz.sparsebundle 形态
2. 读 sibling .encryption.json (信息性, 不参与解密)
3. 弹密码框 → 用户输 password
4. SparsebundleTool.attach(at:, password:user-input, mountpoint:)
   (hdiutil 自家 PBKDF2 解 keybag)
5. BundleIO.load(mountpoint/<name>.hvmz)
6. 走原 flock + VZ engine 启动路径
```

QEMU 路径:
```
1. 检测 <bundle>/meta/encryption.json scheme=qemu-perfile
2. 读 routing JSON 拿 kdf_salt + kdf_iterations
3. 弹密码框 → 用户输 password
4. master_KEK = PBKDF2-SHA256(password, salt, iter, 32)
5. 4 子 key = HKDF-SHA256(master, info=...)
6. EncryptedConfigIO.load(config.yaml, key=config-key) 解出 VMConfig
   (失败 → 密码错, 提示重试)
7. 子 key 走 fd= (swtpm) 或 file= (qemu-img secret) 注入:
    - swtpm 走 --key fd=<dup2 透传>, 不落盘
    - QEMU 走 -object secret,file=<run/<uuid>.key.{disk,nvram}> 0600 临时文件
8. QEMU 启动后 HVM 立即 unlink 临时 key 文件 (子进程已读完, fd 还在)
9. master_KEK / 4 子 key 从 HVM 内存清理
```

### 停止加密 VM

VZ:
```
1. engine 退出 → flock 释放
2. SparsebundleTool.detach(mountpoint:)
3. detach 失败 → 重试 -force (告警 + 写 host log)
```

QEMU:
```
1. QEMU + swtpm 退出
2. 临时 key 文件已在启动后 unlink, 进程结束自然消失
3. flock 释放
```

### 删除加密 VM

VZ: `rm -rf .hvmz.sparsebundle + .hvmz.encryption.json`, keychain 模式删 Keychain item.

QEMU: `rm -rf <bundle>.hvmz`, keychain 模式删 Keychain item.

### Clone / Snapshot 与本稿 (`docs/v3/CLONE.md`) 的交互

**加密 VM 的克隆暂不支持**, 留 PR 后续补:

- VZ 路径: `cp -R sparsebundle` + 提示 chpass — 简单
- QEMU 路径: 复杂 — 需要 `qemu-img reencrypt` 全套 4 个 key 派生新 master, 不是一键 cp

详见底部"未决事项 D9".

### 加密化 / 去加密化(冷迁移)

- `hvm-cli encrypt <vm>`: VM 停 → 创建新加密 bundle → cp 内容进去 → 删旧目录
- `hvm-cli decrypt <vm>`: VM 停 → 创建空目录 → 解密内容拷出来 → 删加密 bundle

二者都需 1× bundle 大小的临时空间; 主盘大时 (几十 GB) 耗时分钟级, GUI 走进度条.

## CLI / GUI 接口

### CLI (PR-10 落地)

```
hvm-cli create --encrypt [--kek-source password|keychain] ...
hvm-cli encrypt <vm> [--kek-source ...]
hvm-cli decrypt <vm>
hvm-cli rekey <vm> [--kek-source ...]
hvm-cli encrypt-status <vm>
```

`hvm-cli list` 区分明文 / 加密 (VZ-sparsebundle / QEMU-perfile) 三种形态.

### GUI (PR-11 落地)

- 创建向导: 加 "加密整个虚拟机" 复选框 + KEK 源 (`HVMFormSelect`) + 密码输入 (`HVMTextField` secure 模式)
- VM 详情页: 加密区, "改密"/"移除加密"/"加密(明文 VM)" 按钮
- 启动时 password 模式: `HVMModal` + 密码框 (X 关闭 = 中止启动)
- 错误: `ErrorDialog` 标准, 不用 NSAlert

### 约束遵循 (CLAUDE.md UI 控件 / 弹窗约束)

- 密码框: `HVMTextField(variant: .secure)` (Style/HVMTextField.swift 已支持 secure)
- KEK 源选择: `HVMFormSelect`
- 弹窗: `HVMModal` X 关闭, **禁止**遮罩点击关闭
- 错误: `ErrorDialog`, **禁止** NSAlert
- 全程走 `HVMColor` / `HVMFont` / `HVMSpace` / `HVMRadius` token

## 异常处理

### 启动期

| 失败点 | VZ 路径 | QEMU 路径 |
|---|---|---|
| Keychain 拉 KEK 取消 | 中止启动 | 中止启动 |
| Keychain item 不存在 | 降级密码框 + 提示 "Keychain 项目缺失" | 同 |
| 解锁失败 (密码错) | hdiutil attach EAUTH → 提示重试, 3 次中止 | qcow2 LUKS open EAUTH → 提示重试 |
| stale mount (上次 crash 没 detach) | 自动 force detach 再重试 1 次 | 不适用 (无 mount) |
| flock 失败 | "VM 已在另一进程运行", detach 后退出 | 同 |
| engine 启动失败 | 走原错误流程, **defer detach 必执行** | swtpm/QEMU 子进程错误标准流程 |

### 运行期

| 事件 | VZ | QEMU |
|---|---|---|
| host crash / kill -9 | sparsebundle stale, 下次启动 force detach | 临时 key 文件随 process 死随 unlink, 无残留 |
| 主机休眠 / 锁屏 | sparsebundle 不会自动 detach, KEK 已在 Keychain unlock 状态保留 | QEMU 进程内 key 在 RAM 保留, 锁屏不清 |
| FileVault 关 / 用户登出 | sparsebundle 跟登录会话绑, 登出强制 detach → VM 被 SIGTERM | QEMU 进程被登出杀掉 |
| 容器空间不足 (写满) | sparsebundle 容器达上限 → I/O 错; banner 提示 grow | qcow2 sparse 自然增长到 host disk full → guest I/O 错 |

### stale mount 清理 (PR-7)

`HVMPaths.runDir/mounts.json` 维护 `<sparsebundle path, mountpoint, vm uuid>` 记录. HVM 主进程 / VMHost 启动前扫一遍, 不一致就 force detach + 清记录.

QEMU 路径无 mount, 但临时 key 文件清理: `~/Library/.../HVM/run/<uuid>.key.*` 启动期 unlink. 兜底: VMHost 启动时扫 `run/` 删孤儿 key 文件.

## 不做什么

1. **不实现自家 crypto**: 全交给 macOS DiskImages / qcow2 LUKS / Apple CryptoKit / Keychain
2. **不支持 cross-engine 加密迁移**: 加密 VZ VM 不能直接转加密 QEMU VM, 反之亦然 (engine 锁死, 且加密形态完全不同)
3. **不实现 KMS / vCenter 风格 key server**: 单机产品不需要
4. **不加密共享资源**: IPSW / virtio-win driver / OS image cache 一律明文 (`~/Library/.../HVM/cache/`)
5. **不加密 host 侧 log**: `~/Library/.../HVM/logs/*` 排查问题用, 加密妨碍调试
6. **不加密 socket / run 目录**: IPC / QMP / HDP / vdagent / swtpm socket 一律明文, 生命周期短
7. **不做 TPM-bound KEK**: macOS 没 TPM, Secure Enclave 由 Keychain 替代
8. **不做"配置改写需密码"**: VMware restriction 留 v4
9. **不做在线加密化 / 去加密化**: 必须冷迁移
10. **不实现密码强度校验**: 仅提示
11. **不实现密码恢复**: 忘了就忘了
12. **加密 VM 暂不支持克隆 (本稿)**: 见未决 D9

## 风险与待验证项

P0 (must-pass before 对应 PR):

| 编号 | 项目 | 状态 | 阶段 |
|---|---|---|---|
| **E0** | HVM 包内 qemu-img 是否支持 LUKS create / info | ✅ **2026-05-04 验证通过**: qemu-img 10.2.0 含 luks block driver, AES-256-XTS / SHA256 / 16M iter PBKDF2 全 OK | PR-4 前 |
| **E1** | swtpm `--key` 加密 NVRAM 是否真支持 | ✅ **2026-05-04 验证通过**: swtpm 0.10.1 支持 `--key file=<path>,mode=aes-256-cbc,format=binary,remove=true`(读完自删)+ `--key fd=<fd>` (HVM 主进程 dup2 透传) | PR-6 前 |
| **E2** | QEMU `-object secret,file=...` 注入路径 | ✅ **2026-05-04 验证通过**: 0600 文件 file= 形式工作正常, 启动期一次性读完后 HVM 可立即 unlink. **意外发现**: fifo 也能当 file= (可未来优化, 不落盘) | PR-5 前 |
| **T1** | VZ + QEMU 进程 sandbox / TCC 能否读写自家挂载的 sparsebundle (VZ 路径) | 待真机跑 | **PR-9 前** |
| **T4** | host crash 后 stale mount 清理 (VZ 路径) | 待 PR-7 落 MountReaper 后跑 | **PR-9 前** |

P1:

| 编号 | 项目 |
|---|---|
| E3 | qcow2 LUKS rekey 性能 (`qemu-img reencrypt` on 64 GiB qcow2) |
| T2 | sparsebundle band 大小对 VM I/O 性能影响 |
| T3 | 加密层 AES-NI 实测 overhead |
| T5 | Keychain `userPresence` 在 SSH / 远程登录 fallback |
| T6 | 大 sparsebundle (100 GB+) clone / chpass / detach 时延 |
| T7 | sparsebundle 跨 macOS 大版本兼容 (Sonoma / Sequoia / Tahoe) |
| T8 | Time Machine / iCloud 备份 sparsebundle 行为 |
| T9 | 关 FileVault 时加密 VM 是否仍能用 |

## 落地拆解 (PR 切分)

| PR | 内容 | 时间盒 | 状态 |
|---|---|---|---|
| **PR-1** | `HVMEncryption/SparsebundleTool.swift` (hdiutil 包装) + 8 个真跑测试 + `EncryptionError` enum + 多语言 stderr 识别 | 1 天 | **✅ 已落** |
| **~~PR-2 (旧)~~** | ~~`KeychainKEK.swift`~~ — **v2.2 取消**, 不需要 Keychain 缓存 | — | ❌ 废 |
| **PR-2 (新)** | `MasterKey.swift` (32 字节值类型 + random) + `PasswordKDF.swift` (PBKDF2-SHA256, 600k iter) + 单测 | 1 天 | 待开 |
| **PR-3** | `EncryptionKDF.swift` (HKDF-SHA256 派生 4 个子 key) + `EncryptedConfigIO.swift` (CryptoKit AES-GCM in-place 包 config.yaml) + ConfigMigrator v2→v3 | 2 天 | 待开 |
| **PR-4** | **`QcowLuksFactory.swift`** — qcow2 LUKS create / resize / rekey (走 amend 两步, qemu-img 10.2 没 reencrypt). 10 个真跑测试 | 1.5 天 | **✅ 已落** |
| **PR-5** | **`OVMFVarsLuksFactory.swift`** + `LuksSecretFile.swift` (公共) + `BundleLayout.nvramLuksFileName`. qemu-img convert raw fd → LUKS qcow2. **argv 改造移到 PR-9** (需 VMHost 启动期 secret 注入). 6 个真跑测试 | 0.5 天 | **✅ 已落** |
| **PR-6** | **`SwtpmKeyHelper.swift`** — Pipe 透传 32 字节 binary key 到 swtpm stdin (fd=0); argv `--key fd=0,mode=aes-256-cbc,format=binary,remove=false`; 不落盘. 6 个测试 (4 单元 + 2 真跑 swtpm) | 1 天 | **✅ 已落** |
| **PR-7** | `HVMPaths.mountpointFor(uuid:)` + `mountsRoot` + `MountReaper.reapStaleMounts` (VZ stale sparsebundle force detach, BundleLock.isBusy 跨进程探活). QEMU 路径不需 reap (Pipe + NSTemporaryDirectory cleanup). 4 测真跑 hdiutil. T4 真机 panic 模拟留 PR-9. | 1 天 | **✅ 已落** |
| **PR-8** | `EncryptedBundleIO` 路由层 + `RoutingMetadata` (snake_case JSON, schema v2). create/unlock/detectScheme + Create/UnlockedHandle lifecycle (VZ detach 兜底). 跨机器 portable 闭环 (源 cp → 目标 unlock 同密码同 VM ID). 10 测真跑. | 2 天 | **✅ 已落** |
| **PR-9** | `VMHost` / engine 启动路径接入 + T1 实测 (双后端真跑加密 VM) | 2 天 | 待开 |
| **PR-10** | `hvm-cli encrypt / decrypt / rekey / encrypt-status` 子命令 + e2e | 2 天 | 待开 |
| **PR-11** | GUI 创建向导加密复选框 + 详情页加密区 + 密码 modal | 3 天 | 待开 |
| **PR-12** | 文档同步: 现状回写 v1 (新建 SECURITY.md / 改 STORAGE.md / VM_BUNDLE.md / CLI.md / GUI.md) + 约束回写 CLAUDE.md "加密约束" 节 + 本稿状态改 "代码已合入" | 1 天 | 待开 |

合计 ~16.5 天 / 1 人. 顺序串行 (PR-2 / PR-4 可并行起草).

每个 PR 必须 `make build` 通过. **禁止 squash 跨 PR 合并** — 每个 PR 独立可 revert.

## 未决事项

| 编号 | 问题 | 当前默认 | 决策时机 |
|---|---|---|---|
| D1 | 加密 VM 的 host 侧 console log 是否也加密 | 不加密 (留排查) | 已决 |
| D2 | "明文 + 加密"两种 VM 同时存在, 还是全局开关 | 允许共存 | 已决 |
| D3 | sparsebundle band 大小默认值 (VZ 路径) | 8 MiB (待 T2) | T2 后 |
| D4 | sparsebundle 容器初始上限策略 | `+ 32 GiB` (可 grow) | 已决 |
| ~~D5~~ | ~~Keychain 模式是否要求回退密码~~ | **v2.2 删除 — 取消 Keychain 缓存, 一律密码** | 已决 |
| D6 | 是否支持加密 VM 放外置 NVMe | 支持 (sparsebundle 与卷无关; qcow2 同) | 已决 |
| ~~D7~~ | ~~Mac Studio / mini 无 Touch ID 的 keychain 体验~~ | **v2.2 删除 — 不再用 Touch ID** | 已决 |
| D8 | 加密 VM 的迁移工具 | **v2.2 改: 直接 cp + 输密码即可 (含 routing JSON 跨机器派生)** | 已决 |
| **D9** | 加密 VM 的克隆是否支持 | 不支持 (本稿). 后续 PR 补; VZ 易 (cp + chpass), QEMU 难 (4 个 key 全部 reencrypt) | 待决 — 看用户需求 |
| **D10** | swtpm 加密方式 | ✅ **已决 (E1 通过)**: 走 `--key fd=<fd>,mode=aes-256-cbc,format=binary` — HVM 主进程 dup2 透传 fd, 不落盘. swtpm `--key` 原生支持, 无需 sparsebundle fallback | 已决 |
| **D11** | QEMU secret 注入方式 | ✅ **已决 (E2 通过)**: 走 `-object secret,id=<id>,file=<path>` — HVM 写 0600 临时文件 (`run/<uuid>.luks-key.{disk,nvram}`), 启动 QEMU 后立即 unlink. fifo 形式作未来优化项 (跳过磁盘) | 已决 |
| **D12** | QEMU OVMF VARS 加密形态 | 走 `-drive if=pflash,driver=qcow2,file.filename=<luks qcow2>,file.driver=luks,file.key-secret=sec_nvram`. **OVMF VARS 走 qemu-img convert raw → LUKS qcow2** (PR-5 已落 OVMFVarsLuksFactory), 不是空白 qcow2 — 必须从 stock template 拷字节, 否则 OVMF 起不来 | ✅ 已落 PR-5 |
| **D13** | LUKS passphrase 编码 (32 字节 binary 不是 UTF-8 合法) | ✅ **base64 编码后 ASCII 字符串当 passphrase**. LUKS spec 要求 passphrase UTF-8 合法; PBKDF2 / HKDF 输出 32 字节 binary 大概率含非 UTF-8 字节 (0x80-0xBF 等). 走 `bytes.base64EncodedString()` → ASCII 字符串 → `LuksSecretFile` 写入 → qemu-img / qemu-system 当 passphrase. 跨机器一致性: 同 32 字节 → 同 base64 → 同 LUKS passphrase | ✅ 已决 PR-5 |

## 设计变更日志

### 2026-05-04 v2.3 — LUKS passphrase base64 编码 (本稿当前状态)

**变更**: PR-5 实施 OVMFVarsLuksFactory 时 qemu-img convert 报 "Data from secret sec0 is not valid UTF-8". 根因: LUKS spec 要求 passphrase UTF-8 合法, 但 32 字节 binary master/sub key 大概率含非 UTF-8 字节.

**触发**: PR-5 真跑测试遇到 0x88 等非 UTF-8 字节失败 (PR-4 测试用 0x42 / 0x01 / 0x02 等合法 UTF-8 字节侥幸通过).

**影响**:
- 新增 `HVMEncryption/LuksSecretFile.swift` 公共模块 — 把 32 字节 binary 走 `base64EncodedString()` → ASCII 字符串 → 写 0o600 file → qemu-img secret file=
- `QcowLuksFactory` (PR-4) + `OVMFVarsLuksFactory` (PR-5) 都通过 LuksSecretFile 注入 — 删私有 SecretFile 副本
- D13 已决: base64 编码后 ASCII 字符串当 LUKS passphrase
- 跨机器一致性: 同 32 字节 → 同 base64 → 同 LUKS passphrase, portable 不变

**保留 v2.2 决策**:
- 强制密码 + 跨机器 portable + 无 Keychain 缓存
- master KEK = PBKDF2(password, salt) + HKDF 派生 4 子 key
- 密钥统一从用户输入派生

### 2026-05-04 v2.2 — 强制密码 + 跨机器 portable

**变更**: 用户拍板 "取消记录密码, 强制每次输". 同时新增硬要求 "加密 VM 复制到其他机器输密码即开".

**触发**: 用户两个连续反馈 —
1. "加密盘要实现复制到其他机器也能通过密码启动" (portability)
2. "取消记录密码, 强制要求每次都输入密码" (no Keychain cache)

**影响**:
- **删 KeychainKEK 模块** (`KeychainKEK.swift` 已写但作废, 不进 PR)
- **新模块**: `PasswordKDF.swift` (PBKDF2-SHA256, 600k iter)
- **PR-2 重定义**: 从 KeychainKEK 改为 MasterKey + PasswordKDF
- **routing JSON schema 升 v2**: 加 `kdf_algo` / `kdf_iterations` / `kdf_salt` / `kdf_keylen` 字段, 跨机器派生 master KEK 必备
- **D5 / D7 删除**: 不再讨论 Keychain 模式, 一律密码
- **新增 D9-portability**: 加密 VM 跨机器迁移作硬要求
- **生命周期"启动"步骤改写**: 永远从用户输入派生, 不查 Keychain
- **HVMError 删 keychain*** 5 个 case, ErrorCodes 同步删
- **PR 总数微调**: 11 PR + 1 PR-1 已落 = 12 PR 不变, 但 PR-2 范围收窄, 工时 1 天

**保留 v2.1 决策**:
- 双后端混合 (VZ-sparsebundle / QEMU-per-file)
- 三个 PoC E0/E1/E2 通过结果
- D10 / D11 / D12 锁定 (swtpm fd= / QEMU file= / OVMF LUKS)

### 2026-05-04 v2.1 — E0/E1/E2 PoC 通过, D10/D11/D12 锁定

**变更**: PR-2 起手前先跑了 E0(qemu-img LUKS) / E1(swtpm `--key`) / E2(QEMU `-object secret`) 三个 PoC, 全部通过. 设计稿不需要架构改动, 仅锁定原方案细节:

- swtpm 走 `--key fd=<fd>,mode=aes-256-cbc,format=binary`(HVM dup2 透传 fd, 不落盘)
- QEMU secret 走 `-object secret,file=<0600 path>` + 启动后立即 unlink
- OVMF VARS 走 LUKS qcow2 + `-drive file.driver=luks`

无需 sparsebundle fallback / argv data= fallback. **可放心进 PR-2**.

### 2026-05-04 v2 — 改混合方案

**变更**: 单方案 A (sparsebundle 套整 bundle, 双后端共用) → 混合 (VZ-sparsebundle + QEMU-per-file).

**触发**: 用户反馈 v1 设计与 VMware "per-file 独立加密" 形态差距过大 — 运行期 host root 进程能直接读挂载点明文; QEMU 走 native LUKS 能拿 VMware 同等的 per-file + 运行期 host 隔离, 不浪费 QEMU 内置能力.

**影响**:
- PR-1 (`SparsebundleTool`) 实现保留, 仍为 VZ 路径主力工具
- 新增 PR-4 (QcowLuksFactory) / PR-5 (OVMF LUKS) / PR-6 (swtpm --key) 三个 PR, 走 QEMU per-file
- PR-3 (HKDF KDF + EncryptedConfigIO) 新增模块替代原"sparsebundle 内 config.yaml 自然受保护"假设
- 加密形态判定从"看扩展名 .hvmz vs .hvmz.sparsebundle"扩为"VZ 看扩展名 / QEMU 看 meta/encryption.json"
- config schema v3 加 `scheme: vz-sparsebundle | qemu-perfile` 区分
- 工时从 12.5 天 → 16.5 天

**保留 v1 决策**:
- 双层密钥模型 (DEK / KEK) 不变
- KEK 来源 (password / keychain) 不变
- ConfigMigrator v2→v3 + sibling routing JSON 思路不变 (VZ 形态)
- 不实现自家 crypto / 单机不做 KMS / 忘密不可恢复 等"不做什么"全保留

### 2026-05-04 v1 — 设计稿单方案 A (已废弃)

文件第一版, 单方案 sparsebundle 套整 bundle. 见 git log 5028348 之前版本.

## 相关文档

- [VM_BUNDLE.md](../v1/VM_BUNDLE.md) — bundle 布局 / config schema (v3 加密字段需追加)
- [STORAGE.md](../v1/STORAGE.md) — 磁盘格式与 DiskFactory (PR-12 加 LUKS 子节)
- [VZ_BACKEND.md](../v1/VZ_BACKEND.md) — VZ entitlement / disk attachment
- [QEMU_INTEGRATION.md](../v1/QEMU_INTEGRATION.md) — QEMU 进程模型 / argv (PR-12 加 secret 注入子节)
- [ENTITLEMENT.md](../v1/ENTITLEMENT.md) — 现有 entitlement (本稿不增)
- [CLONE.md](CLONE.md) — VM 克隆设计 (与本稿 D9 交互)
- [../../CLAUDE.md](../../CLAUDE.md) — 全局约束 (PR-12 加"加密约束"节)

---

**最后更新**: 2026-05-04
**状态**: 设计稿混合方案 v2.3; PR-1 ~ PR-8 已落, 加密底层 + 路由层 + 跨机器 portable 闭环全部就绪. T1 / T4 真机 panic 留 PR-9. 可进 PR-9 (VMHost 启动接入)
