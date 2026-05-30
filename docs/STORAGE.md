# STORAGE — 磁盘存储 / 克隆 / 快照

> 现状文档 (QEMU-only)。描述 `app/Sources/HVMStorage/` 各组件当前代码行为。
> 约束源头见 `CLAUDE.md`「磁盘与存储约束」「克隆约束」。
>
> 涉及源文件:
> - `app/Sources/HVMStorage/DiskFactory.swift` — 磁盘创建 / 扩容 / 删除 / 导入
> - `app/Sources/HVMStorage/CloneManager.swift` — 整 VM 克隆
> - `app/Sources/HVMStorage/SnapshotManager.swift` — APFS clonefile 快照
> - `app/Sources/HVMStorage/ISOValidator.swift` — ISO 路径校验
> - `app/Sources/HVMStorage/VolumeInfo.swift` — 卷剩余空间预检
> - `app/Sources/HVMBundle/VMConfig.swift` — `DiskSpec` / `DiskFormat` / `DiskRole`
> - `app/Sources/HVMBundle/BundleLayout.swift` — bundle 内文件名常量

---

## 1. 磁盘格式与唯一来源 (DiskSpec)

### 1.1 两种格式

`DiskFormat` (`VMConfig.swift`) 只有两个 case:

```swift
public enum DiskFormat: String, Codable, Sendable, CaseIterable {
    case raw      // ftruncate sparse
    case qcow2    // qemu-img create / resize
}
```

- **qcow2 是 QEMU 后端的主路径**: 新建 VM 一律 qcow2 (`BundleLayout.mainDiskFileName(for: .qemu)` 恒返 `os.qcow2`)。
- **raw 仅作导入兼容**: 用户从外部带进来的 raw 镜像 (`.img`) 仍可直挂 QEMU 运行 (`DiskSpec.format = .raw`)。HVM 自身不再新建 raw 盘 (VZ 后端已整条移除)。
- 加密 VM 主盘是 LUKS 加密的 qcow2 (`DiskFormat` 仍记 `.qcow2`),加密层透明于本模块的 clonefile/qemu-img 操作。

### 1.2 DiskSpec 是 per-VM 配置的唯一来源

`DiskSpec` (`VMConfig.swift`):

```swift
public struct DiskSpec: Codable, Sendable, Equatable {
    public var role: DiskRole      // .main / .data
    public var path: String        // 相对 bundle root, 例 "disks/os.qcow2"
    public var sizeGiB: UInt64
    public var readOnly: Bool
    public var format: DiskFormat  // 持久化在 config.yaml
}
```

硬约束 (CLAUDE.md「磁盘与存储约束」):

- **路径走 `DiskSpec.path`**,运行时取主盘绝对路径走 `VMConfig.mainDiskURL(in:)` (内部读 `mainDiskRelPath = disks.first(role==.main).path`)。**禁止**用 `BundleLayout` 常量推断主盘路径。
- **格式走 `DiskSpec.format`**,**禁止**靠文件扩展名推断。
- `BundleLayout.mainDiskFileName(for:)` / `dataDiskFileName(uuid8:engine:)` 是**仅创建时调用一次**的默认文件名生成器,注释明确标注「运行时永远从 `VMConfig.mainDiskRelPath` 读,不再调用此函数」。

### 1.3 format 字段的 decode 兜底 (老 yaml)

`DiskSpec.init(from:)` 提供缺省兜底,仅给 schema v1→v2 桥接用:

```swift
if let fmt = decodeIfPresent(format) { self.format = fmt }
else {
    let ext = (path as NSString).pathExtension.lowercased()
    self.format = (ext == "qcow2") ? .qcow2 : .raw   // 仅迁移期桥接
}
```

正常 yaml 一定带 `format` 字段;这段扩展名推断只在缺字段的老配置里触发,不是运行时路径。

---

## 2. DiskFactory — 创建 / 扩容 / 删除 / 导入

`DiskFactory` (enum,纯静态方法) 是所有磁盘文件级操作入口。

### 2.1 create — 显式 format 分流

```swift
public static func create(at url: URL, sizeGiB: UInt64, format: DiskFormat, qemuImg: URL? = nil) throws
```

- 文件已存在 → 抛 `HVMError.storage(.diskAlreadyExists)`。
- `.raw` → `createRaw`: `open(O_WRONLY|O_CREAT|O_EXCL)` + `ftruncate(bytes)`。ftruncate 失败回滚删文件。
- `.qcow2` → `createQcow2`: 必传 `qemuImg`,否则抛 `.creationFailed(errno: ENOENT)`;走子进程 `qemu-img create -f qcow2 <path> <sizeGiB>G`。非零退出码记 stderr 到 log + 删半成品文件 + 抛 `.creationFailed`。
- `qemuImg` 路径来自 `QemuPaths.qemuImgBinary()` (调用方解析,严格走 .app 包内,见 CLAUDE.md「第三方二进制约束」)。

### 2.2 grow — 只增不减

```swift
public static func grow(at url: URL, toGiB: UInt64, format: DiskFormat, qemuImg: URL? = nil) throws
```

- `.raw` → `growRaw`: `fstat` 取旧大小,`newBytes <= oldBytes` 抛 `.shrinkNotSupported`,否则 `ftruncate`。
- `.qcow2` → `growQcow2`: 子进程 `qemu-img resize <path> <toGiB>G`。
- **扩容只改文件容量,guest 内仍需手动扩文件系统** (`resize2fs` / 分区工具),本模块不碰 guest 内分区。

### 2.3 delete

`delete(at:)`: 文件不存在直接 noop;`removeItem` 失败抛 `.ioError(errno: EIO)`。

### 2.4 文件名生成

- 数据盘 uuid8: `newDataDiskUUID8()` = `UUID().uuidString` 去 `-` 取前 8 位小写 hex。
- 主盘文件名: 创建时走 `BundleLayout.mainDiskFileName(for: engine)` → `os.qcow2`。
- 数据盘文件名: `BundleLayout.dataDiskFileName(uuid8:engine:)` → `data-<uuid8>.qcow2`。

### 2.5 容量探测

- `logicalBytes(at:)`: `stat.st_size` — raw 即名义大小;qcow2 是文件本身字节数 (非 guest 虚拟容量)。
- `actualBytes(at:)`: `stat.st_blocks * 512` — 实际物理占用 (raw sparse 显著小于逻辑)。

### 2.6 导入外部镜像 (OpenWrt / Debian cloud image / Alpine 等)

仅放行 qcow2 / raw,其它格式 (vmdk/vhdx/...) 拒绝。

- `inspectImage(at:qemuImg:)`: 走 `qemu-img info --output=json --force-share`,解析 `format` + `virtual-size`。
  - format 非 qcow2/raw → 抛 `.importInvalid`。
  - `virtual-size > importMaxSizeGiB` (2048 GiB) 或 `== 0` → 抛 `.importInvalid`。
  - 返回 `ImportableDiskInfo { format, virtualSizeBytes }`,`virtualSizeGiB` 向上取整到 GiB。
- `importImage(from:to:info:targetSizeGiB:qemuImg:)`:
  - 目标已存在 → `.diskAlreadyExists`。
  - `targetSizeGiB < virtual-size` → `.shrinkNotSupported` (缩容不支持)。
  - `copyItem` 拷贝整文件;若 `targetSizeGiB > virtual-size` 显式放大,调 `grow`;resize 失败回滚删拷贝文件,避免半成品主盘。

---

## 3. VolumeInfo — 卷空间预检

`VolumeInfo` 在磁盘创建/扩容前预检卷剩余空间:

- `space(at:)`: 读 `volumeTotalCapacity` + `volumeAvailableCapacityForImportantUsage`,返 `VolumeSpace { totalBytes, availableBytes }`。
- `assertSpaceAvailable(at:requiredBytes:)`: 阈值 = `max(requiredBytes / 100, 128 MiB)` (raw sparse 创建只需一次性写入估计值);不足抛 `.volumeSpaceInsufficient`。

---

## 4. CloneManager — 整 VM 克隆

整 VM 克隆走 APFS `clonefile(2)` 字节级 COW 复制磁盘 + 装机产物 + 重生身份字段。设计稿 `docs/v3/CLONE.md`。

### 4.1 前置约束

`clone(sourceBundle:options:)` 入口检查顺序:

1. **displayName 校验** (`validateName`): 1-64 字符,不能是 `.`/`..`,不允许 `/` 或 NUL (比 SnapshotManager 略宽,允许中文/空格)。
2. **源 bundle 存在** → 否则 `.bundle(.notFound)`。
3. **目标不能预存在** → 目标路径 `<parent>/<newDisplayName>.hvmz` 已存在抛 `.bundle(.alreadyExists)`。GUI 自动追加 ` 副本 N` 后缀;CLI 用户自己改名。
4. **同 APFS 卷** (`ensureSameVolume`): 比 `stat.st_dev`,跨卷抛 `.storage(.crossVolumeNotAllowed)` — `clonefile(2)` 跨卷会 `EXDEV`,提前探测给更友好报错。复制到外接 NVMe 等场景需用户手动 `cp -R`。
5. **源必须 stopped** (`BundleLock(mode: .edit)`): 内部抢源 `.edit` lock 排他;已被 `.runtime` 持有 (运行中) 抛 `.bundle(.busy)`。**GUI 不自动 stop 源 VM** (用户掌控)。

任意一步失败 → `removeItem(targetBundle)` 清目标残留。**CloneManager 绝不留 partial bundle**。

### 4.2 重生字段 vs 保留字段

| 类别 | 字段 | 原因 |
|------|------|------|
| **重生** | `config.id` (新 `UUID()`) | 撞 id 会冲突 |
| **重生** | `config.displayName` | = `options.newDisplayName` |
| **重生** | `config.createdAt` | = `Date()` |
| **重生** | 数据盘 `data-<uuid8>.*` 文件名 + 同步改 `DiskSpec.path` | 避免 uuid8 撞车 |
| **重生** | `networks[].macAddress` (默认) | 同 LAN 双开 MAC 冲突;`keepMACAddresses=true` 可保留 (用户自负) |
| **保留** | 主盘 `os.qcow2` 文件名 | 主盘命名按 engine 固定,不带 uuid |
| **保留** | 磁盘内容 (clonefile COW) | 整个 clone 的目的 |
| **保留** | `nvram/efi-vars.fd` | EFI BootOrder;重置 = guest 进 EFI Shell |
| **保留** | `tpm/*` (Win11 swtpm state) | 重置 = BitLocker 永久失效 |
| **保留** | `auxiliary/*` | 整目录 clonefile |

> 注: VZ 时代的 `auxiliary/machine-identifier` / `hardware-model` 随 macOS guest 移除,代码注释保留历史说明,QEMU guest 无此字段。

### 4.3 不带的文件

- `.lock` — 目标首次启动自然创建。
- `logs/console-*.log` — 仅预创建空 `logs/` 目录,ConsoleBridge 启动时写。
- `.unattend-stage/` / `unattend.iso` — Windows 装机产物,启动时按需重生。
- **`snapshots/` — 永不带** (D15 决策 2026-05-04,加密/明文一致,无 `--include-snapshots` flag)。

### 4.4 明文克隆流程

`clone` 主路径 (`EncryptedBundleIO.detectScheme == nil` 分支):

1. `BundleIO.load(from: sourceBundle)` 加载源 config (走 schema 升级链 + 校验)。
2. 建目标骨架 (`<target>.hvmz` + `disks/`,0o755)。
3. 主盘 (role=.main): 文件名不变,`cloneFile`。
4. 数据盘 (role=.data): 逐个 uuid8 重生 → 新文件名 → `cloneFile` 到新相对路径 → 改 `config.disks[i].path`;记录 old→new uuid8 映射 (诊断用)。
5. 装机产物子目录整体 `cloneIfExists`: `nvram` / `tpm` / `auxiliary` / `meta` (clonefile 支持目录递归 COW,要求 dst 不存在)。
6. 建空 `logs/` 目录。
7. 重生身份字段 (id/displayName/createdAt/MAC)。
8. `BundleIO.save(config:to:)` 写目标 `config.yaml` (validate 在 save 内)。

`cloneFile` 是 `SnapshotManager.cloneFile` 的本模块别名,复用同一份 `clonefile(2)` 包装 (flags=0 = owner copy,等价 `cp -c`),不在 HVMStorage 内重复实现。

### 4.5 加密 VM 克隆 (D9 = 等价复制 + 同密码)

`cloneEncryptedQEMU` 分支 (源检测到加密 scheme + 必传 `options.password`,否则 `.config(.missingField)`)。QEMU-only: 加密 VM 恒 qemu-perfile (vz-sparsebundle 已随 VZ 移除)。

关键不变量:

- **源密码 → 目标密码一字不差** (clone 不改密码;想换密码用户自跑 `hvm-cli rekey`)。
- **master KEK / sub keys 全程不变**: KEK 由 `PBKDF2(password, salt)` 派生,clone 后 salt + 密码不变 → 同 KEK → 同 LUKS keyslot 能解 / 同 swtpm-key 能开 `tpm/permall`。
- LUKS qcow2 (header + ciphertext)、`config.yaml.enc`、swtpm state 全走 `cloneFile` **字节级复制不解密**。
- **config.yaml.enc 例外**: 需 `EncryptedBundleIO.unlock` 拿 `qemuSubKeys` → 改 vmId/displayName/disks paths → 用源 `subKeys.config` `EncryptedConfigIO.save` 重新加密 (master KEK 不变,用源密码可解目标 .enc)。
- **routing JSON** (`meta/encryption.json`): 读源 → 仅改 `vmId` + `displayName` → 写目标;`salt`/`iter`/`scheme` 不动 (跨机器派生 master KEK 仍正确,因 salt 不变)。

流程结构同明文路径 (主盘字节复制 / 数据盘 uuid8 重生 / nvram+tpm+auxiliary 字节复制 / 重生身份字段 / 空 logs/),失败同样 `removeItem(targetBundle)` 清残留。

> **GUI 暂不接加密 clone** (CLI 路径已支持,走 prompt 密码)。设计稿 `docs/v3/CLONE_SNAPSHOT_ENCRYPTED.md`。

### 4.6 不做的

- **linked clone** (qcow2 backing file 暂不做)。
- **cross-host 克隆**。
- **在线克隆** (源必须 stopped)。
- **schema 升级 / 删源**。

---

## 5. SnapshotManager — APFS clonefile 快照

基于 `clonefile(2)` 的 VM 整体快照,clone `disks/*` + `config.yaml(.enc)`。COW 几乎零空间 + 瞬间完成 (10GB 主盘也是 ms 级)。

### 5.1 布局

```
<bundle>/snapshots/<name>/disks/os.{img,qcow2}
<bundle>/snapshots/<name>/disks/data-*.{img,qcow2}
<bundle>/snapshots/<name>/config.yaml | config.yaml.enc   (按 bundle 加密形态择一)
<bundle>/snapshots/<name>/meta.json                       ({name, createdAt})
```

`clonefile(2)` 直接绑定 (`@_silgen_name("clonefile")`),flags=0 = owner copy。

### 5.2 操作

- **create(bundleURL:name:)**:
  - `validateName`: 1-64 字符,白名单 `字母数字 / - / _ / .`,不能是 `.`/`..` (比 CloneManager 严,禁中文/空格)。
  - 同名快照已存在 → `.diskAlreadyExists`。
  - clone `disks/` 下所有 `.img` / `.qcow2` 文件 (加密 LUKS qcow2 字节复制透明)。
  - config 按加密形态择一 copy (`locateBundleConfig`: 有 `config.yaml.enc` 优先,否则 `config.yaml`,都无抛 `.bundle(.notFound)`)。
  - 写 `meta.json` (`{name, createdAt}`)。
- **list(bundleURL:)**: 读各 `<name>/meta.json`,按 `createdAt` 倒序返 `[Info]`。
- **restore(bundleURL:name:)**: 非原子,分四步,中途 crash 可能半旧半新,但 snapshot 仍完整可重 restore 自愈:
  1. snapshot 磁盘先 clone 到 bundle 内 `.restore-tmp-<8>/` (失败清 tmp 抛错)。
  2. 删 bundle/disks/ 下现有磁盘 (snapshot 是 ground truth)。
  3. tmp 里磁盘 `moveItem` 到 `disks/`,删 tmp。
  4. config atomic replace (`restoreConfig`): 把 snapshot config copy 到 `.config-restore-<8>.tmp` → 清 bundle 现有 `config.yaml` + `config.yaml.enc` 两种 → mv tmp 到对应名。
- **delete(bundleURL:name:)**: 不存在抛 `.ioError(ENOENT)`,否则 `removeItem` 整个 snapshot 目录。

`isDiskFile`: 仅识别 `.img` (raw) 或 `.qcow2` (含 LUKS) 后缀。

### 5.3 加密快照

APFS clonefile 字节级 COW 对 LUKS qcow2 / `config.yaml.enc` / swtpm state 字节复制不解密 (snapshot 不需 prompt 密码)。master KEK / sub keys 全程未变,restore 后用源密码可继续解。

> 边界: snapshot 创建后用户跑 `rekey`,restore 后 LUKS keyslot 是 snapshot 时点的老密码,必须用老密码启动 — 是预期行为。

### 5.4 限制

- VM 必须 **stopped** (running 时 disk 在写,snapshot 不一致)。
- `clonefile` 要求 src/dst 同 APFS volume (bundle 内一切满足)。
- restore 非原子 (见上)。
- **clone 永不带 snapshots/** (CloneManager §4.3)。

---

## 6. ISOValidator — ISO 路径校验

ISO **不进 bundle,只存绝对路径** (config 里仅记 ISO 绝对路径,不复制进 bundle)。

`ISOValidator.validate(at:)`:

- 文件不存在 → `.storage(.isoMissing)`。
- 尺寸不在 `[1 MiB, 20 GiB)` → `.storage(.isoSizeSuspicious)` (超范围八成是选错文件,早失败好过挂载后 guest 无法启动)。

---

## 7. 错误类型速查

本模块抛的 `HVMError.storage(_)` case:

- `.diskAlreadyExists(path:)` — create / import 目标已存在。
- `.creationFailed(errno:path:)` — 创建失败 (含 qemu-img create 非零退出)。
- `.ioError(errno:path:)` — grow / delete / stat / clonefile 失败。
- `.shrinkNotSupported(currentBytes:requestedBytes:)` — 缩容拒绝。
- `.crossVolumeNotAllowed(source:target:)` — clone 跨 APFS 卷。
- `.importInvalid(reason:path:)` — 导入镜像格式/容量非法。
- `.volumeSpaceInsufficient(requiredBytes:availableBytes:)` — 卷空间不足。
- `.isoMissing(path:)` / `.isoSizeSuspicious(bytes:)` — ISO 校验。

`HVMError.bundle(_)`: `.notFound` / `.alreadyExists` / `.busy` (clone 前置)。
