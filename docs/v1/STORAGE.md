# 存储设计 (`HVMStorage`)

## 目标

- 双格式按 engine 分流: VZ 用 raw sparse, QEMU 用 qcow2
- `DiskSpec.format` 字段持久化 `config.yaml`, **运行时不靠扩展名推断**
- 充分利用 APFS 稀疏文件 + clonefile, 不自研格式
- 扩容用系统 / qemu-img 工具, 缩容不支持
- snapshot = 整 bundle 的 APFS clone (disks/* + config.yaml)

## 磁盘格式分流

| 后端 | 格式 | 文件名 | 创建工具 | 扩容工具 |
|---|---|---|---|---|
| **VZ** | `raw` sparse | `disks/os.img` | `ftruncate` | `ftruncate` |
| **QEMU** | `qcow2` | `disks/os.qcow2` | `qemu-img create` | `qemu-img resize` |

VZ 的 `VZDiskImageStorageDeviceAttachment` **只接受 raw**, 是硬约束; qcow2 文件丢给 VZ 直接报错. QEMU 后端走 qcow2 是 sparse + 内置压缩 + 可被 `qemu-img info/resize` 安全管理.

### `DiskFormat` 枚举

```swift
public enum DiskFormat: String, Codable, Sendable, CaseIterable {
    case raw       // ftruncate sparse, VZ 必走
    case qcow2     // qemu-img, QEMU 必走
}
```

### `DiskSpec` 字段

```swift
public struct DiskSpec: Codable, Sendable, Equatable {
    public var role: DiskRole          // .main | .data
    public var path: String            // 相对 bundle, 例 "disks/os.qcow2"
    public var sizeGiB: UInt64
    public var readOnly: Bool
    public var format: DiskFormat      // 运行时唯一来源
}
```

`format` 在 schema v2 (`config.yaml`) 必带. v1 已断兼容 (旧 `config.json` 不再读). 老 yaml 缺 `format` 字段时, `DiskSpec.init(from:)` 兜底按 path 扩展名推 (`.qcow2 → .qcow2`, 其他 → `.raw`); 这是 ConfigMigrator 临时桥接, 正常 v2 yaml 都带 `format`.

### 运行时纪律

- 路径走 `disk.path` (相对 bundle), 由 `VMConfig.mainDiskURL(in:)` 等运行时 helper 拼绝对路径
- 格式走 `disk.format`, **禁止靠扩展名推**
- `BundleLayout` 里 `mainDiskFileName(for: engine)` / `dataDiskFileName(uuid8:engine:)` **仅创建时用一次**, 写入 `DiskSpec.path` 后就不再调; 运行时入口的 `mainDiskName` / `mainDiskURL(_ bundle:)` 老 API 已删

## DiskFactory

```swift
public enum DiskFactory {
    public static func create(at url: URL, sizeGiB: UInt64,
                              format: DiskFormat, qemuImg: URL? = nil) throws
    public static func grow(at url: URL, toGiB: UInt64,
                            format: DiskFormat, qemuImg: URL? = nil) throws
    public static func delete(at url: URL) throws
    public static func logicalBytes(at url: URL) throws -> UInt64
    public static func actualBytes(at url: URL) throws -> UInt64
    public static func newDataDiskUUID8() -> String
    public static func inspectImage(at url: URL, qemuImg: URL) throws -> ImportableDiskInfo
    public static func importImage(from src: URL, to dst: URL,
                                   info: ImportableDiskInfo,
                                   targetSizeGiB: UInt64?, qemuImg: URL?) throws
}
```

`format == .qcow2` 时**必须传 `qemuImg`** (路径走 `QemuPaths.qemuImgBinary()`); 否则抛 `creationFailed(errno: ENOENT)`. 调用方拿不到 qemu-img 一般是 `make build-all` 没跑 — 提示用户先做 QEMU 后端构建.

### raw 路径

```swift
let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
ftruncate(fd, off_t(sizeGiB) * 1 << 30)
```

只 `ftruncate`, **不** `posix_fallocate` — 要 sparse 语义, APFS 才能让 64GiB 主盘初始物理占用接近 0. `cp` 默认会膨胀, 复制必须用 `cp -c` (clonefile) 或 `ditto -c`.

### qcow2 路径

```swift
qemu-img create -f qcow2 <path> <sizeGiB>G
qemu-img resize <path> <toGiB>G          // grow
```

stderr 失败时 log + 拷贝失败回滚 (clean up 半成品文件).

### 导入外部镜像 (`inspectImage` + `importImage`)

QEMU 后端的"用现成的 qcow2/raw 当主盘"通路 (例 OpenWrt / Debian cloud image / Alpine 预装):

1. `inspectImage` 调 `qemu-img info --output=json --force-share <path>` 拿 `format` + `virtual-size`
2. 仅放行 `qcow2` / `raw`, 拒绝 `vmdk` / `vhdx` / `vdi` 等 (用 `qemu-img convert` 自己先转)
3. 上限 `importMaxSizeGiB = 2048` GiB (与 GUI stepper 顶值对齐)
4. `importImage` 拷贝到 bundle, `targetSizeGiB > virtualSize` 时拷完再 `grow`; `targetSizeGiB < virtualSize` 直接拒 (缩容不支持)

## 命名约定

```
foo.hvmz/disks/
├── os.img           # VZ 后端主盘 (DiskFormat.raw)
├── os.qcow2         # QEMU 后端主盘 (DiskFormat.qcow2)
└── data-<uuid8>.{img,qcow2}   # 数据盘, uuid8 = UUID 前 8 位 lowercase hex
```

`uuid8` 由 `DiskFactory.newDataDiskUUID8()` 生成. 文件系统不反映"用户起的标签"; 标签若加将存在 `DiskSpec.label` (尚未上字段).

`BundleLayout.mainDiskFileName(for: engine)` 在创建时按 engine 选 `os.img` / `os.qcow2`, 写到 `DiskSpec.path`. 运行时不再调用此 helper, 直接读 `disk.path`.

## 权限

- 磁盘 `0644` (vm owner 读写, 他人只读)
- bundle 目录 `0755`
- 不做 encryption-at-rest, 依赖 FileVault

## 扩容

VZ + QEMU 都**不支持运行时改盘容量**, 必须停机.

### host 侧

`DiskFactory.grow` 按 format 分流: raw → ftruncate, qcow2 → `qemu-img resize`.

### guest 侧

host 扩容后 guest 看到的块设备尺寸变大, 但文件系统不变, 用户在 guest 内自行:

- **Linux**: `growpart /dev/vda 2 && resize2fs /dev/vda2` (或 `xfs_growfs`)
- **macOS**: 磁盘工具 → 内置磁盘 → 分区 → 调整大小
- **Windows**: 计算机管理 → 磁盘管理 → 扩展卷

GUI 弹文字提示, 不在 guest 内自动跑 (需要 guest agent, 当前不做).

## 缩容

**不支持**. 原因:

- 缩到有效数据尾部以下会损坏文件系统; host 不知道真实数据边界
- 需 guest agent 或 `dd` 手动操作, 与最简原则冲突

回收空间应走 "guest 内 `fstrim` / 写 0 → host 再 `cp --sparse=always`" 或重建 VM.

## ISO 处理

### 原则: 不进 bundle, 只存绝对路径

- `VMConfig.installerISO: String?` 存绝对路径
- ISO 1~5 GiB, 多 VM 可共用同源, 复制是浪费
- ISO 只读挂载, 不会被改

### 校验 (`ISOValidator.validate`)

```swift
guard FileManager.default.fileExists(atPath: path) else { throw .isoMissing }
let size = (attrs[.size] as? Int64) ?? 0
guard (1<<20)..<(20<<30) ~= size else { throw .isoSizeSuspicious }
```

ISO 被用户移动 / 删除 → 启动失败, GUI 提示重选.

### 挂载

- VZ Linux + `bootFromDiskOnly==false` → `VZUSBMassStorageDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url:isoURL, readOnly:true, ...))`
- QEMU Windows → `-device usb-storage,drive=cdrom0` + `-drive if=none,...,readonly=on,format=raw`. Windows 还会挂第二个 cdrom 给 unattend.iso (`bypassInstallChecks`) + 第三个挂 UTM Guest Tools ISO 给驱动

装完用户在 GUI 点 "完成安装", `bootFromDiskOnly = true`, 下次启动不再挂 ISO.

### 自动下载 OS 镜像

`HVMInstall/OSImageCatalog.swift` 提供 7 个 Linux 发行版的 arm64 ISO 信息 (Ubuntu / Debian / Fedora / Alpine / Rocky Linux / openSUSE / Custom URL 兜底), 在创建向导内点 "下载" → `OSImageFetcher` 流式拉到 `~/Library/Application Support/HVM/cache/iso/`, 复用同卷镜像不重复下载. 对带 SHA256 的镜像做校验; rolling 镜像 (Alpine edge 等) 跳过校验.

`installerISO` 仍存绝对路径指向 cache 目录; 用户可换成自己的 ISO 文件.

## Snapshot: APFS clonefile

`HVMStorage/SnapshotManager`: 整 bundle 级快照, 存在 `<bundle>/snapshots/<name>/`.

```
foo.hvmz/snapshots/<name>/
├── disks/os.{img,qcow2}     # clonefile(2) of bundle/disks/*
├── disks/data-*.{img,qcow2} # clone 所有数据盘
├── config.yaml              # config 普通 copy (文件小)
└── meta.json                # { name, createdAt }
```

clonefile = APFS copy-on-write, 几乎零空间 + 瞬间完成 (10GB 主盘 ms 级).

### `create / list / restore / delete`

- `create(bundleURL:name:)`: 校验名字 (1-64 char, 字母数字 + `-_.`, 拒 `.` / `..`), clone 所有 `*.img` + `*.qcow2`, 复制 `config.yaml`, 写 `meta.json`
- `list(bundleURL:)`: 扫 `meta.json`, 按 `createdAt` 倒序
- `restore`: 先 clone 到 `bundle/.restore-tmp-xxx/`, 然后清旧 disks, move tmp 进来, 最后 `replaceItemAt(config.yaml)` (同卷 rename 原子). **非原子**: 中途 crash 可能半旧半新, 但 snapshot 仍完整, 可再 restore 一次自愈
- `delete`: 直接 rm 整个 snapshot 目录

### 约束

- VM 必须 stopped (运行中 disk 在写, snapshot 不一致)
- bundle 内全在同一 APFS 卷, clonefile 直接成功; 跨卷会被内核拒绝
- snapshot **是文件不是元数据树**: 没有自动 GC / 父子链, 用户自己管

## 校验与监控

- 启动前 `ConfigBuilder.build` 内 `FileManager.fileExists(atPath:)` 检查所有 disk, 缺则 `BackendError.diskNotFound`
- 不做 fsck 级别修复, guest 自管
- `VolumeInfo` 提供 bundle 所在卷剩余空间查询, 由 GUI banner / VMHost 用 (低空间警告由 GUI 决策)

## 不做什么

1. 不支持 vmdk / vhdx / vdi 等其他外部格式 (导入时拒, 用户自己 `qemu-img convert`)
2. 不做加密卷 (FileVault 兜底)
3. 不做自动 defrag / compact (APFS 自管)
4. 不做磁盘 I/O throttle (VZ / QEMU 都不暴露稳定接口)
5. 不做共享磁盘 (多 VM 同一磁盘, VZ 不支持, flock 也禁止)

## 性能注记

- raw sparse 在 APFS 上顺序写接近原生; 随机 4K 写因 sparse map 维护略 < 5% 开销
- qcow2 顺序写比 raw 慢 5-10% (元数据维护), 随机写差不多; 优势是文件本身可压缩 / 可 `qemu-img info` 查 actual / 跨卷 `qemu-img convert` 转换
- guest 内 `fstrim` / `discard` 通知 host 释放物理空间; Linux 装载选项 `discard` 启用; Windows 在 viostor / NetKVM 装好后默认开启
- 写密集场景建议把 bundle 放外置 NVMe (USB4), 内置 SSD 寿命保护

## 不变量小结

```swift
// 创建时 (engine 决定 format)
let fmt: DiskFormat = (engine == .vz) ? .raw : .qcow2
let name = BundleLayout.mainDiskFileName(for: engine)
let path = "disks/\(name)"
try DiskFactory.create(at: bundleURL.appendingPathComponent(path),
                        sizeGiB: 64, format: fmt, qemuImg: qemuImgURL)
config.disks = [DiskSpec(role: .main, path: path, sizeGiB: 64, format: fmt)]

// 运行时 (走 DiskSpec)
for disk in config.disks {
    let url = bundleURL.appendingPathComponent(disk.path)
    // 后端按 disk.format 分流; 不看扩展名
}
```

## 未决事项

| 编号 | 问题 | 默认 | 决策时机 |
|---|---|---|---|
| D1 | 数据盘标签字段 | 暂不加, 用户记 uuid8 | 用户反馈再决 |
| D2 | snapshot 增量链 | 暂不做, 每次 clone 整 disks | TBD |
| D3 | guest 内自动 resize | 不做, 弹文字提示 | 已决 |

## 相关文档

- [VM_BUNDLE.md](VM_BUNDLE.md) — bundle 布局 / config.yaml schema
- [VZ_BACKEND.md](VZ_BACKEND.md) — 磁盘 attachment 构建
- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — qemu-img 路径
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 装机阶段 ISO 处理 / 自动下载

---

**最后更新**: 2026-05-04
