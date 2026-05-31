# 克隆反指纹设计 (Machine Identity)

## 1. 目标 + 范围

**目标**: 每台 VM 对 guest 暴露一份**唯一且持久**的"机器硬件身份", 克隆时整套重生 →
克隆体与源/彼此**不可被识别为同一台机器**; 并把厂商/型号串伪装成合理的真实 OEM 硬件
(等同 UTM / VMware 的 host-passthrough SMBIOS), 让 guest 内软件看到一台"正常的真实机器"。

**正当性边界 (必须遵守)**: 这是**通用 VM-manager 能力**(用户管理自有 VM, 用于软件兼容性 /
授权解绑 / 隐私防关联), **不**针对任何特定反作弊 / 反欺诈 / 反检测 / 沙箱产品做定向绕过,
**不**内置任何"击败某安全控制"的硬编码逻辑。仅做"给每台 VM 一份合理且唯一的硬件身份"。

**做**:
- SMBIOS Type 1 (System): UUID / Serial / Manufacturer / Product / Family / SKU
- SMBIOS Type 2 (Baseboard): Serial / Manufacturer / Product
- SMBIOS Type 3 (Chassis): Serial / Asset Tag
- 磁盘 serial (nvme / virtio-blk 的 `serial=`)
- NIC MAC (**已做** — clone 已重生, 见 CloneManager)
- TPM EK: 克隆重置 (生成全新 swtpm 状态 → 新 EK)

**不做 (能力边界)**:
- **guest OS 层身份** (Windows MachineGUID / Machine SID / ProductID, Linux `/etc/machine-id`):
  这些在 guest 内由 OS 安装时生成, host 改不了。要重置需 guest 内 `sysprep` (Win) /
  `systemd-machine-id-setup` (Linux)。**v1 不碰**, 文档显式告知用户克隆后如需彻底切断需在 guest 内做。
- CPU 序列 / 主机名 (主机名 guest 内改)。

## 2. 指纹面清单 + 当前状态

| 面 | guest 怎么读 | 当前 HVM 状态 | 风险 |
|---|---|---|---|
| SMBIOS system UUID | `wmic csproduct get uuid` / `dmidecode -s system-uuid` | **未设 `-uuid`/`-smbios`** → QEMU arm virt 默认 | 所有 HVM VM 雷同 |
| SMBIOS serial / vendor | `Win32_BIOS.SerialNumber` / dmidecode | 未设 → QEMU 默认 ("QEMU"...) | 暴露是 QEMU + 雷同 |
| baseboard / chassis serial | dmidecode type 2/3 | 未设 | 雷同 |
| 磁盘 serial | `Get-PhysicalDisk`.SerialNumber / `lsblk -o SERIAL` | nvme 固定 `hvm-<driveId>`; virtio 无 | 克隆雷同 |
| NIC MAC | ipconfig / ip link | **clone 已重生** ✓ | OK |
| TPM EK | `tpmtool` / TBS | **clone 字节复制 → 同 EK** | 克隆可关联 + BitLocker 双开冲突 |

## 3. 设计

### 3.1 config.yaml 新增 `MachineIdentity`

```swift
public struct MachineIdentity: Codable, Sendable, Equatable {
    public var systemUUID: String        // SMBIOS type1 UUID (= -uuid); 大写无连字符? 用标准 UUID 串
    public var systemSerial: String      // type1 serial
    public var systemSKU: String?        // type1 sku (可选)
    public var baseboardSerial: String   // type2 serial
    public var chassisSerial: String     // type3 serial
    public var oemProfile: OEMProfile    // 厂商/型号串来源 (见 3.3)
    // 磁盘 serial 落到各 DiskSpec.serial (见 3.2), 不放这里
}
```
- `VMConfig.machineIdentity: MachineIdentity?` (可选, 缺省 = 老 VM, 走 backfill)
- `DiskSpec` 加 `serial: String?` (每盘独立 serial)

### 3.2 QemuArgsBuilder 发射

```
-uuid <systemUUID>
-smbios type=1,manufacturer=<oem.mfr>,product=<oem.product>,version=<oem.ver>,serial=<systemSerial>,uuid=<systemUUID>,sku=<systemSKU>,family=<oem.family>
-smbios type=2,manufacturer=<oem.mfr>,product=<oem.board>,serial=<baseboardSerial>
-smbios type=3,manufacturer=<oem.mfr>,serial=<chassisSerial>,asset=<...>
# 磁盘:
nvme:        -device nvme,drive=<id>,serial=<disk.serial>
virtio-blk:  -drive if=none,id=<id>,... + -device virtio-blk-pci,drive=<id>,serial=<disk.serial>
             (从当前 `if=virtio` 改成 device 形态才能挂 serial; Linux 盘行为变更, 单列 PR 验证 boot)
```
- 缺 `machineIdentity` (老 VM 未 backfill) → 维持现状不发 smbios (向后兼容)。

### 3.3 OEM profile (厂商伪装)

合理的真实 OEM 串, 按 guestOS 选默认, **唯一标识字段 (serial/uuid) 始终随机**:
- **Windows ARM**: 拟 `Microsoft Corporation` / `Surface Pro X` 或 Qualcomm 开发板系列 (ARM Win 常见)
- **Linux ARM**: 拟通用 OEM, 或 `QEMU`→改 generic
- profile 是一组固定字符串模板 (mfr/product/version/family/board), **不含**任何唯一标识 (那些随机生成)
- v1 提供 1-2 个内置 profile + 默认; 不暴露用户自定义 (后续可加)

### 3.4 生成 / 重生时机

- **create** (`VMControl.create`): 生成随机 `MachineIdentity` + 每盘随机 serial → 写 config。
- **clone** (`CloneManager` 两路): 重生 `MachineIdentity` (新 systemUUID/serials) + 每盘新 serial
  (跟 id/mac/createdAt 一起在"重生身份字段"块)。**加密路径同样重生** (写进重加密的 config.yaml.enc)。
- **clone 的 TPM 重置**: 克隆**不复制** `tpm/` 目录 → 首启 swtpm 自建全新状态 (新 EK)。
  - 明文: 首启建明文 swtpm 状态。
  - 加密: 首启 swtpm 用 clone 的 swtpm-key 子密钥建加密状态 (子密钥与源同, 因 master KEK 同)。
  - 代价: 克隆的 Windows 首启 BitLocker 失配 → 需恢复密钥 (用户已确认接受)。nvram (SecureBoot/BootOrder) 仍复制。
- **migration backfill** (`ConfigMigrator` 或 load 时): 老 VM 无 `machineIdentity` →
  **从 config.id 确定性派生**一份 (而非纯随机), 使老 VM 的指纹**跨重启稳定**且不与他人撞
  (派生: `systemUUID = config.id`; serials = `id` 的 hash 截断)。这样老 VM 升级后指纹稳定, 不触发 guest "新硬件"。

### 3.5 持久化必要性 (P0)

身份**必须落 config 持久**, 不能每次启动随机: 否则 guest 每次开机看到"换了硬件" →
Windows 重新激活地狱 / 驱动重装 / Linux NetworkManager 重设。create 时定一次, 此后稳定,
仅 clone 显式重生。

## 4. 选型对比

| 方案 | 优 | 劣 | 取舍 |
|---|---|---|---|
| **A. 持久 MachineIdentity 入 config (选)** | 稳定 / 可控 / 克隆精确重生 / 跨机 portable | config schema +字段, 要迁移 | ✅ |
| B. 启动时随机 (不持久) | 改动小 | guest 每启认作新硬件 → 激活/驱动灾难 | ✗ |
| C. 仅从 config.id 派生 (不存独立字段) | 零 schema 改 | 克隆若也派生自新 id 则 OK, 但无法独立控制各字段 / 无法伪装 OEM | 仅用于 backfill 老 VM |

## 5. PR 拆解 (颗粒 ≤ 2 天)

- **PR-1**: `MachineIdentity` + `DiskSpec.serial` 入 VMConfig (schema 兼容 + Codable 缺省兜底) +
  `MachineIdentityFactory` (随机生成 / 从 id 确定性派生) + OEM profile 表。验收: 编译 + 老 yaml 解码不崩。
- **PR-2**: QemuArgsBuilder 发射 `-uuid` + `-smbios 1/2/3` + 磁盘 serial (含 virtio-blk 改 device 形态)。
  验收: 起 Linux + Windows VM, guest 内 `dmidecode` / `Win32_*` 读到设定值, 两不同 VM 不同。
- **PR-3**: create 生成 + clone 重生 + clone 不复制 tpm/ + migration backfill。
  验收: 真机 e2e — 克隆加密+明文 VM, guest 内对比源/克隆 SMBIOS UUID/serial/TPM EK 全不同, 源不变。
- **PR-4**: 文档回写 CLAUDE.md (克隆约束 + QEMU 约束加 SMBIOS 小节) + GUI 克隆/创建提示 TPM 重置。

## 6. 风险 / P0 must-pass

- **P0-1 持久稳定**: 同一 VM 多次启动 SMBIOS 不变 (验: 连启两次 dmidecode 一致)。
- **P0-2 老 VM 不破**: 无 machineIdentity 的老 yaml 解码正常 + backfill 后指纹稳定 (不每启变)。
- **P0-3 virtio-blk 改 device 形态后 Linux 仍正常 boot** (改了磁盘挂载方式, 必须真机验 Linux 启动 + 数据盘可见)。
- **P0-4 加密克隆**: 重生身份写进重加密 config.yaml.enc, 且 routing 仍正确 (跟现有加密克隆 e2e 合并验)。
- **P0-5 TPM 重置**: 克隆首启 swtpm 自建新状态成功 (明文 + 加密两种), guest 见到一个可用的新 TPM。
- **P0-6 ARM Windows SMBIOS 生效**: 确认 QEMU arm virt + EDK2 把 `-smbios` 传进 guest (arm 走 firmware SMBIOS, 需实测 Win `Win32_ComputerSystemProduct.UUID` 真变)。

## 7. Decisions

| # | 决策 | 选定 |
|---|---|---|
| D1 | 目标范围 | **反关联 + 伪装真实 OEM 厂商串** (通用 VM-manager 能力, 不定向绕过特定安全控制) |
| D2 | clone TPM EK | **重置 (新 EK)** — 反指纹 + 避 BitLocker 双开; 克隆 Win 首启需恢复密钥 |
| D3 | 应用范围 | **create + clone 都生成**, 老 VM **backfill** (从 id 确定性派生) |
| D4 | 持久化 | 入 config.yaml (P0-1), 不每启随机 |
| D5 | OEM profile 自定义 | v1 内置 1-2 profile + 默认, 不开放用户自定义 (后续可加) |
| D6 | guest OS 层身份 (Win SID / machine-id) | v1 不碰, 文档告知用户需 guest 内 sysprep |
