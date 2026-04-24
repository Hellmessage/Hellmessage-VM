# 存储设计 (`HVMStorage`)

## 目标

- 最简磁盘格式, 零外部依赖
- 充分利用 APFS 的稀疏文件和 clonefile 特性
- 扩容与快照用系统工具, 不自研格式

## 磁盘格式: raw sparse

### 为什么 raw

| 格式 | 取舍 |
|---|---|
| **raw sparse** ✅ | APFS 原生稀疏, VZ 直接支持 `VZDiskImageStorageDeviceAttachment`, 无需第三方工具 |
| qcow2 ❌ | 需要 qemu-img, 引入 Homebrew 或 vendor, 违反零依赖约束; VZ 不认 qcow2 头 |
| APFS disk image (UDIF) ❌ | hdiutil 创建, 但 VZ 要的是裸块设备文件, UDIF 的元数据壳会让 attachment 报错 |

选 raw。APFS 的 sparse 特性意味着:

- `truncate -s 64G main.img` 只占元数据, 实际物理占用为 0
- guest 写到哪, host 才分配到哪
- `du -h` 显示实际占用, `ls -l` 显示逻辑大小
- `cp` 默认会膨胀成完整大小, 复制必须用 `cp -c`(clonefile) 或 `ditto` 保留稀疏

### 创建

```swift
public enum DiskFactory {
    /// 创建一个 sizeGiB 大小的 raw sparse 文件, 已存在则抛错
    public static func create(at url: URL, sizeGiB: UInt64) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.diskAlreadyExists(path: url.path)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw StorageError.creationFailed(errno: errno) }
        defer { close(fd) }
        let bytes = off_t(sizeGiB) * 1024 * 1024 * 1024
        guard ftruncate(fd, bytes) == 0 else {
            throw StorageError.creationFailed(errno: errno)
        }
        // 不预分配 (fallocate), 就要 sparse 语义
    }
}
```

**关键**: 只 `ftruncate`, 不 `fallocate` / `posix_fallocate`, 保持 sparse。

### 权限

- 主盘 / 数据盘 `0644`(vm owner 读写, 他人只读)
- bundle 目录 `0755`
- 不做 encryption-at-rest, 依赖 FileVault

## 主盘 / 数据盘命名

- **主盘**: `<bundle>/disks/main.img` — 固定, 唯一, 角色 `main`
- **数据盘**: `<bundle>/disks/data-<uuid8>.img` — 其中 `<uuid8>` 是 UUID 前 8 个十六进制字符小写

示例:

```
foo.hvmz/disks/
├── main.img              # 64 GiB
├── data-4f8e2b1a.img     # 100 GiB, 用户命名 "backup"
└── data-9c77ed02.img     # 500 GiB, 用户命名 "datasets"
```

文件系统上不反映"用户命名", 用户命名只存 `config.json.disks[].label`(后加字段, 非 MVP 必需)。

## 扩容

VZ **不支持运行时改磁盘大小**, 必须停机。

### host 侧

```bash
# 停 VM 后
truncate -s 128G foo.hvmz/disks/main.img
# sparse, 几乎瞬间完成
```

Swift 封装:

```swift
public enum DiskFactory {
    /// 扩容到新大小, 不支持缩容
    public static func grow(at url: URL, toGiB: UInt64) throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw StorageError.ioError(errno: errno) }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw StorageError.ioError(errno: errno) }
        let oldBytes = st.st_size
        let newBytes = off_t(toGiB) * 1024 * 1024 * 1024
        guard newBytes > oldBytes else {
            throw StorageError.shrinkNotSupported(currentBytes: oldBytes, requestedBytes: newBytes)
        }
        guard ftruncate(fd, newBytes) == 0 else { throw StorageError.ioError(errno: errno) }
    }
}
```

### guest 侧

host 扩容后, guest 看到的块设备尺寸变大, 但文件系统没变。用户需:

- **Linux**: `growpart /dev/vda 2 && resize2fs /dev/vda2` (或 `xfs_growfs`)
- **macOS**: 磁盘工具 → 选择内置磁盘 → 分区 → 调整大小

HVM 不自动在 guest 内跑 resize 命令(需要 guest agent, 超 MVP 范畴)。GUI 弹提示告诉用户下一步怎么做。

## 缩容

**不支持**。原因:

1. 缩容到有效数据尾部以下会损坏文件系统, 需先在 guest 内 shrink FS, host 不知道真实数据边界
2. 需要额外工具链(guest agent 或 `dd` 手动操作), 违反最简原则

用户需要"回收空间"应走:

- guest 内写 0 清空未使用区域 → host 侧 `cp --sparse=always` 重新打包
- 或直接重建 VM

## ISO 处理

### 原则

**ISO 文件不复制进 bundle**, 只在 config 记绝对路径。

理由:

- ISO 通常 1~5 GiB, 复制浪费空间、拖慢创建流程
- 多台 VM 可能共用同一 ISO(同一 Ubuntu 版本), 复制就是重复
- ISO 不被修改, 只读挂载安全

### 校验

加载 config 时:

```swift
if let iso = config.installerISO {
    guard FileManager.default.fileExists(atPath: iso.path) else {
        throw StorageError.isoMissing(path: iso.path)
    }
    // 尺寸 > 1 MiB, < 20 GiB, 作为基本 sanity
    let size = try FileManager.default.attributesOfItem(atPath: iso.path)[.size] as? Int64 ?? 0
    guard (1 << 20)..<(20 << 30) ~= size else {
        throw StorageError.isoSizeSuspicious(bytes: size)
    }
}
```

ISO 被用户移动/删除时, 启动失败, GUI 提示"ISO 不在原位置, 请重新选择"。

### 挂载

```swift
let iso = VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
let cdrom = VZUSBMassStorageDeviceConfiguration(attachment: iso)
```

仅在 `bootFromDiskOnly == false` 时挂载, 安装完成后用户在 GUI 里点"完成安装 → 改为从硬盘启动", config 写 `bootFromDiskOnly=true`, 下次不再挂 ISO。

## 快照: APFS clonefile

VZ 本身不提供快照。我们用 APFS 的 clonefile 做:

```bash
cp -c foo.hvmz/disks/main.img foo.hvmz/disks/main.img.snap-2026-04-25
```

或 Swift API:

```swift
import Darwin

public enum SnapshotFactory {
    public static func clone(src: URL, dst: URL) throws {
        guard clonefile(src.path, dst.path, 0) == 0 else {
            throw StorageError.cloneFailed(errno: errno)
        }
    }
}
```

### 约束

- **VM 必须停机**: 运行中磁盘的 clone 会拿到脏数据
- **同一 APFS 卷**: 跨卷 clonefile 会退化为完整复制
- **快照只是文件**: 没有元数据、没有自动 GC、用户自己管理

### 为什么不做 snapshot 管理 UI

MVP 不做。理由:

1. 做好 snapshot 管理需要元数据(快照树、时间戳、父子关系), 是另一个完整子系统
2. 用户拷文件即可, 复杂度留给他
3. 未来若要做, 建议走独立 `snapshots/` 目录 + `snapshots.json` 索引, 届时升 schemaVersion

CLI 先提供最小命令:

```bash
hvm-cli snapshot create <bundle> --label before-upgrade
# 产出 foo.hvmz/disks/main.img.before-upgrade
```

不做 revert, 用户自己 `mv` 换回来。

## 校验与修复

- 启动前 `stat` 所有 disk 路径, 缺失抛 `diskNotFound`
- 文件存在但大小为 0 视为"未初始化", 提示用户
- 不做 fsck 级别的修复, guest 自己管

## 空间监控

- VMHost 进程定时(每 10 秒)采集 bundle 所在卷的剩余空间
- 低于 1 GiB 发告警到 IPC, GUI 弹 banner "磁盘空间不足, guest 写入可能失败"
- 低于 100 MiB 且 VM 在 `.running` 时**不强制暂停**, 只发最高级告警(强行暂停可能让 guest 数据更糟)

## 不做什么

1. **不支持 qcow2 / vmdk / vdi 等外部格式**
2. **不做加密卷**(FileVault 兜底)
3. **不做自动 defrag / compact**(APFS 自管)
4. **不做磁盘 I/O throttle**(VZ 不暴露)
5. **不做 shared disk(多 VM 同一磁盘)**(VZ 不支持, flock 也禁止)

## 性能注记

- raw sparse 在 APFS 上顺序写接近原生, 随机 4K 写因 sparse map 维护略有开销(< 5%)
- guest 内 `fstrim`/`discard` 可以把已删除块通知给 host, host 释放物理空间:
  - Linux: VZVirtioBlockDevice 支持 `DISCARD`, 需内核 `ext4 discard` 挂载选项
  - macOS: 自动 trim
- 写密集场景建议把 bundle 放外置 NVMe(USB4), 内置 SSD 寿命保护

## 接口草图

```swift
public enum DiskSpecPath {
    /// bundle/disks/main.img
    public static func main(_ bundle: URL) -> URL
    /// bundle/disks/data-<uuid8>.img, uuid8 自动生成
    public static func newData(_ bundle: URL) -> URL
}

public enum DiskFactory {
    public static func create(at url: URL, sizeGiB: UInt64) throws
    public static func grow(at url: URL, toGiB: UInt64) throws
    public static func delete(at url: URL) throws
    public static func actualBytes(at url: URL) throws -> UInt64     // 物理占用
    public static func logicalBytes(at url: URL) throws -> UInt64    // 逻辑大小
}

public enum SnapshotFactory {
    public static func clone(src: URL, dst: URL) throws
}

public enum StorageError: Error {
    case diskAlreadyExists(path: String)
    case creationFailed(errno: Int32)
    case ioError(errno: Int32)
    case shrinkNotSupported(currentBytes: off_t, requestedBytes: off_t)
    case isoMissing(path: String)
    case isoSizeSuspicious(bytes: Int64)
    case cloneFailed(errno: Int32)
}
```

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| D1 | 是否做 "数据盘自动标签" | 不做, 用户命名只影响 UI, 底层走 uuid8 | 已决 |
| D2 | snapshot 是否落 `snapshots/` 子目录 | MVP 同 `disks/`, 后续可加子目录重命名 | M2 重评 |
| D3 | 是否在扩容后自动提示 guest 扩分区 | 只弹说明文, 不自动操作 | 已决 |

## 相关文档

- [VM_BUNDLE.md](VM_BUNDLE.md) — bundle 布局
- [VZ_BACKEND.md](VZ_BACKEND.md) — 磁盘 attachment 构建
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — 装机阶段磁盘处理

---

**最后更新**: 2026-04-25
