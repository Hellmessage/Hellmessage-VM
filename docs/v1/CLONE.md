# 整 VM 克隆 (`CloneManager`)

## 目标

- 从一个 `.hvmz` 复制出**独立**的新 `.hvmz`, 与源同时可运行
- APFS clonefile(2) copy-on-write: 100GB 主盘 ms 级完成, 物理空间到首次写时才分配
- 身份字段重生 (id / MAC / machine-identifier / 数据盘 uuid8) 防同 LAN 双开冲突 / Apple 服务撞机
- 装机后 NVRAM / TPM / hardware-model 字节保留 (重生 = guest 启动失败 / BitLocker 失效)

> 设计稿 [../v3/CLONE.md](../v3/CLONE.md) (代码已合入). 本篇是当前代码现状描述。

## 与 Snapshot 的差异

| 维度 | Snapshot (SnapshotManager) | Clone (CloneManager) |
|---|---|---|
| 输出位置 | `<bundle>/snapshots/<name>/` | 全新 `<other>.hvmz/` (跨 bundle) |
| 用途 | 时间点回滚 | 派生新 VM, 与源同时跑 |
| 身份字段 | 不变 (restore 还是同一台) | id / displayName / MAC / machine-identifier 全重生 |
| 数据盘文件名 | 不变 | uuid8 重生 + DiskSpec.path 同步 |
| 实现复用 | clonefile(2) | 同 clonefile(2), 复用 `SnapshotManager.cloneFile` |

## 入口签名

```swift
public enum CloneManager {
    public struct Options: Sendable {
        public var newDisplayName: String      // 必填 (1-64 字符, 不允许 / NUL)
        public var targetParentDir: URL?       // nil = 源父目录
        public var keepMACAddresses: Bool      // 默认 false (重生)
        public var password: String?           // 加密源 VM 必传, 明文 VM 必为 nil
    }

    public struct Result: Sendable {
        public let sourceBundle: URL
        public let targetBundle: URL
        public let newID: UUID
        public let renamedDataDiskUUID8s: [String: String]   // 老 → 新映射
    }

    public static func clone(sourceBundle: URL, options: Options) throws -> Result
}
```

## 克隆步骤 (明文 VM)

1. 验证新名称 (1-64 字符, 禁 / NUL)
2. 校验源路径存在 / 目标不存在 / 目标父目录存在
3. **同卷校验**: `stat(2)` 比 `st_dev` (clonefile 跨卷 `EXDEV`)
4. **抢源 `.edit` lock** (排他, 与 `.runtime` 冲突 → `.bundle(.busy)`)
5. 创建目标骨架目录
6. 主盘 clonefile (文件名不变, APFS COW 复制)
7. 数据盘 clonefile, uuid8 重生 → 改文件名 + 同步 `DiskSpec.path`
8. clonefile 子目录: nvram / tpm / auxiliary / meta (APFS COW, 内容字节保留)
9. macOS guest: 重生 `auxiliary/machine-identifier` (`VZMacMachineIdentifier()`)
10. 创建空 `logs/` 目录
11. 重生身份字段: `id` / `displayName` / `createdAt` / `networks[].macAddress`
12. 保存 `config.yaml` (validate 内置)
13. 任意一步失败 → `removeItem(targetBundle)` 清残留, 不留 partial bundle

## 字段处理矩阵

### 重生

| 字段 | 出处 | 原因 |
|---|---|---|
| `config.id` | UUID() | 同 ID 撞 flock / host log 子目录 |
| `config.displayName` | `options.newDisplayName` | 用户输入 |
| `config.createdAt` | `Date()` | 新 VM 时间戳 |
| `config.networks[].macAddress` | `MACAddressGenerator.random()` | 同 LAN 双开避免冲突; `keepMACAddresses=true` 保留 |
| `auxiliary/machine-identifier` (macOS) | `VZMacMachineIdentifier()` | 同 identifier 同时跑 Apple 服务视为同机 |
| `disks/data-<uuid8>.{img,qcow2}` 文件名 | `DiskFactory.newDataDiskUUID8()` | 防文件名冲突 |
| `disks[i].path` (数据盘) | 跟 uuid8 同步 | 跟文件名走 |

### 保留 (字节复制不动)

| 字段 / 文件 | 原因 |
|---|---|
| `disks/os.{img,qcow2}` (主盘文件名) | 主盘命名按 engine 是固定值, 无 uuid |
| `disks/*` 内容 | APFS clonefile COW, 写时复制 |
| `auxiliary/aux-storage` (macOS) | 装机后 NVRAM-equivalent, 丢失整 VM 报废 |
| `auxiliary/hardware-model` (macOS) | 与 IPSW 装机绑定, 重生 = guest 拒启 |
| `nvram/efi-vars.{fd,qcow2}` | EFI BootOrder; 重置 = 进 EFI Shell |
| `tpm/*` (Win11 swtpm) | 重置 = BitLocker 永久失效 |
| `meta/thumbnail.png` | 视觉延续 |
| `config.engine` / `guestOS` / `cpu/memory` 等 | 克隆不是迁移 |

### 不带文件 (skip)

- `.lock` (目标首次启动自动创建)
- `logs/console-*.log` (新 VM 一身轻; host 日志按 `<displayName>-<uuid8>` 自然分流)
- `.unattend-stage/` / `unattend.iso` (Win 装机产物, 启动时按需重生)
- `snapshots/` (D15: 永不带, 加密 / 明文 / VZ / QEMU 一律. 没有 `--include-snapshots` 选项 — 用户决策 2026-05-04)

## 错误路径

| 错误 | 抛出 | 退出码 |
|---|---|---|
| 源不存在 | `.bundle(.notFound)` | 3 |
| 目标已存在 | `.bundle(.alreadyExists)` | 1 |
| 目标父目录不存在 | `.bundle(.notFound)` | 3 |
| 跨卷 clonefile | `.storage(.crossVolumeNotAllowed)` | 1 |
| IO 错误 | `.storage(.ioError)` | 1 |
| 源运行中 (BundleLock 抢不到) | `.bundle(.busy)` | 4 |
| 加密源缺密码 | `.config(.missingField)` | 2 |
| 名称非法 (含 / NUL) | `.config(.invalidEnum)` | 2 |

任意失败 → 自动清掉目标残留 (`removeItem(targetBundle)`), 不留 partial bundle。

## 加密 VM 克隆 (D9 等价复制 + 同密码)

走 CloneManager 内 `qemuPerfile` 分支, 详见 [ENCRYPTION.md](ENCRYPTION.md):

1. unlock 源 → 拿 sub keys + config (master KEK 派生)
2. LUKS qcow2 字节级复制 (header + ciphertext, 不解密 — APFS clonefile 仍生效)
3. 数据盘 uuid8 重生 (LUKS header 不依赖文件名)
4. nvram / tpm / auxiliary 字节复制 (sub keys 不变 → 同密码可解)
5. 重生身份字段 (跟明文一致)
6. **config.yaml.enc**: 解密 → 改 vmId / displayName / disks → 用源 `sub.config` 重新加密
7. **meta/encryption.json**: 改 vmId, salt / iter / scheme 不动 (跨机器派生 KEK 仍正确)

新 VM 跟源同密码; 换密码自跑 `hvm-cli rekey`。

> VZ-sparsebundle 加密 clone 推后 (跟 VZ 加密接入一致)。

## CLI 入口

```
hvm-cli clone <vm> --name <new-name>
                   [--target-dir <path>]
                   [--keep-mac]
                   [--force]
                   [--format human|json]

参数:
  vm              源 VM 名称或 bundle 路径
  --name          新 VM 显示名 (1-64 字符)
  --target-dir    目标父目录 (缺省 = 源父目录, 必须与源同 APFS 卷)
  --keep-mac      保留所有 NIC MAC (默认: 重生; 用户自负不双开)
  --force         加密 VM 跳过二次确认
```

加密源 VM: prompt 密码 + 二次确认 (`--force` 跳过)。详见 [CLI.md](CLI.md)。

## GUI 入口

VM 详情页 stopped 视图 `actionRow` "Clone" 按钮 → `CloneVMDialog` 三态:

- **Form**: 输新名 + 保留 MAC toggle + 加密 VM 时输密码
- **Running**: Spinner "克隆中…", 不可中断 (`closeAction = nil`)
- **Done**: ✔ 摘要 + Reveal / Done 按钮

加密 VM 提示: "字节级 COW + 新 VM 同源密码, 换密码自跑 rekey"。
Windows 克隆警告: TPM 字节保留, 但部分场景需重新激活 (跟 Microsoft 激活策略相关)。

## 不做什么

1. 不做 linked clone (VZ raw 不支持 backing; APFS clonefile 已接近 linked 的空间效率)
2. 不做 cross-engine 克隆 (不是迁移工具, 换 engine 走"导出磁盘 + 新建 VM 导入")
3. 不重生 NVRAM / TPM (重生 = guest 启动失败 / BitLocker 失效)
4. 不重生 macOS hardware-model (与 IPSW 装机绑定)
5. 不在线克隆 (源必须 stopped, GUI 不自动 stop)
6. 不做 schema 升级 (源 schema 必须等于当前)
7. 不带 `snapshots/` (D15 决策)
8. 不删源 (clone 是 copy 不是 move)
9. 不复制 host 侧 log (`~/Library/.../HVM/logs/<displayName>-<uuid8>/` 自然 per-uuid 分流)

## 依赖

- `HVMBundle`: BundleIO / BundleLayout / BundleLock / DiskFactory
- `HVMEncryption`: EncryptedBundleIO / EncryptedConfigIO / RoutingMetadata (加密分支)
- `HVMNet`: MACAddressGenerator (重生 NIC MAC)
- `HVMStorage.SnapshotManager`: cloneFile() 包装器复用
- Darwin: stat(2) 同卷探测

## 真机验证状态

设计稿 [../v3/CLONE.md](../v3/CLONE.md) 列了几条待真机验证项 (C1 / C2 / C3), 当前已基本覆盖, 但 macOS guest 双开 (Apple 服务行为) 仍标"实验性, 未充分验证"。

## 相关文档

- [../v3/CLONE.md](../v3/CLONE.md) — 设计稿与字段决策溯源
- [../v3/CLONE_SNAPSHOT_ENCRYPTED.md](../v3/CLONE_SNAPSHOT_ENCRYPTED.md) — 加密 VM clone + snapshot 决策
- [STORAGE.md](STORAGE.md) — clonefile / SnapshotManager
- [VM_BUNDLE.md](VM_BUNDLE.md) — 字段重生 / 保留矩阵
- [ENCRYPTION.md](ENCRYPTION.md) — 加密 VM 路径
- [CLI.md](CLI.md) — `hvm-cli clone`
- [GUI.md](GUI.md) — `CloneVMDialog`

---

**最后更新**: 2026-05-05
