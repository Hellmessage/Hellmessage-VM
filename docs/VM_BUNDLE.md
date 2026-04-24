# VM Bundle 格式 (`.hvmz`)

## 目标

一个 `.hvmz` 目录自包含一台 VM 的**全部持久化状态**, 可整个拷贝迁移。设计要点:

1. 目录而非单文件, 方便编辑 / diff / 增量备份
2. 与 hell-vm 的 `.hellvm` 严格隔离, 扩展名不同, 内部结构也不同
3. 同一时刻仅允许一个进程打开(flock 互斥), 避免两处并发改 config 或写磁盘
4. ISO 只存路径, 不复制进 bundle(避免重复占用几 GB)
5. config 带 `schemaVersion`, 允许未来平滑升级

## 目录布局

```
foo.hvmz/
├── config.json              — VMConfig 的 JSON 序列化(权威配置)
├── auxiliary/               — VZ 需要的附加数据
│   ├── aux-storage          — macOS guest 的 VZMacAuxiliaryStorage 文件
│   ├── machine-identifier   — macOS guest 的 VZMacMachineIdentifier (Data)
│   └── hardware-model       — macOS guest 的 VZMacHardwareModel (Data)
├── disks/                   — 所有磁盘镜像
│   ├── main.img             — 主盘, 启动盘
│   └── data-<uuid8>.img     — 可选数据盘, 命名 data-<uuid 前 8 字符>.img
├── nvram/                   — Linux guest 的 EFI 变量存储
│   └── efi-vars.fd          — VZEFIVariableStore 后端文件
├── logs/                    — 本 VM 的运行日志, 独立于全局 logs
│   └── <yyyy-mm-dd>.log
├── .lock                    — flock 占用文件, 存当前持有者 PID + socket path
└── meta/                    — 非关键元数据, 可重建
    ├── thumbnail.png        — GUI 列表展示的 VM 截图缩略图
    └── last-boot.json       — 上次启动时间 / 运行时长
```

### 为什么 auxiliary 与 nvram 分开

- `auxiliary/` 仅 macOS guest 使用, VZ 要求的**一次性**生成数据(hardware-model 不可变), 丢了整台 VM 报废
- `nvram/` 仅 Linux guest 使用, EFI 变量可重置(重置意味着要重走一次 EFI shell 手动选 boot entry)
- 分开命名, `guestOS` 判定即可知该看哪个

## `config.json` Schema (v1)

```json
{
  "schemaVersion": 1,
  "id": "4F8E2B1A-0B25-44C1-9A2E-9E58CBE2D43C",
  "createdAt": "2026-04-25T03:00:00Z",
  "displayName": "ubuntu-2404",
  "guestOS": "linux",
  "cpuCount": 4,
  "memoryMiB": 8192,
  "disks": [
    {
      "role": "main",
      "path": "disks/main.img",
      "sizeGiB": 64,
      "readOnly": false
    }
  ],
  "networks": [
    {
      "mode": "nat",
      "macAddress": "52:54:00:A1:B2:C3"
    }
  ],
  "installerISO": "/Users/me/Downloads/ubuntu-24.04-live-server-arm64.iso",
  "bootFromDiskOnly": false,
  "macOS": null,
  "linux": {
    "kernelCmdLineExtra": null,
    "rosettaShare": false
  }
}
```

### 字段规范

| 字段 | 类型 | 说明 |
|---|---|---|
| `schemaVersion` | Int | 当前 `1`。读到更大的版本号时报错退出, 不做向后兼容猜测 |
| `id` | UUID | bundle 创建时生成, 跟随 bundle 一生。用于 IPC 订阅 topic |
| `createdAt` | ISO8601 | 创建时间, 仅作展示, 不参与逻辑 |
| `displayName` | String | 展示名, 允许与目录名不一致, 允许中文 |
| `guestOS` | `"macOS"` \| `"linux"` | 其他值拒绝 |
| `cpuCount` | Int | 范围 `[VZVirtualMachineConfiguration.minimumAllowedCPUCount, maximumAllowed]` |
| `memoryMiB` | UInt64 | MiB 为单位。VZ 要求至少 128 MiB, 上限为 `maximumAllowedMemorySize`(物理内存 - 系统余量) |
| `disks` | [DiskSpec] | 至少一项, 第一项 role 必须 `"main"` |
| `networks` | [NetworkSpec] | 可空, 空表示无网卡 |
| `installerISO` | String? | 绝对路径, 仅 `bootFromDiskOnly=false` 时有意义; **不复制进 bundle** |
| `bootFromDiskOnly` | Bool | 安装机完成后置 true, VZ 不再尝试从 CD 引导 |
| `macOS` | MacOSSpec? | 仅 `guestOS="macOS"` 时非空 |
| `linux` | LinuxSpec? | 仅 `guestOS="linux"` 时非空 |

### DiskSpec

```json
{
  "role": "main" | "data",
  "path": "disks/main.img",          // 相对 bundle root
  "sizeGiB": 64,                      // 新建时的逻辑大小
  "readOnly": false
}
```

- `role="main"` 只能且必须有一个
- `path` **必须相对路径**且落在 `disks/` 下, 绝对路径或跳出 bundle 拒绝
- `sizeGiB` 只是记录创建时的尺寸, host 侧权威大小取 `stat(path).st_size`

### NetworkSpec

```json
{
  "mode": "nat" | "bridged",         // bridged 审批通过才启用
  "macAddress": "52:54:00:A1:B2:C3", // 可选, 不填自动随机
  "bridgedInterface": "en0"          // 仅 mode="bridged" 时有效
}
```

详见 [NETWORK.md](NETWORK.md)。

### MacOSSpec

```json
{
  "ipsw": "/Users/me/UniversalMac_15.0_24A335_Restore.ipsw",
  "autoInstalled": true              // 装机完成标记, GUI 隐藏重装入口
}
```

### LinuxSpec

```json
{
  "kernelCmdLineExtra": null,
  "rosettaShare": false              // 是否向 guest 暴露 Rosetta 翻译共享目录
}
```

## 命名规则

- **Bundle 目录名**: 任意, 但扩展名必须 `.hvmz`。GUI/CLI 创建时默认用 `displayName` 小写 + `-` 替换空格
- **主盘**: 固定 `disks/main.img`
- **数据盘**: `disks/data-<uuid 前 8 字符>.img`, 例如 `disks/data-4f8e2b1a.img`
- **ISO**: 不进 bundle, 只记路径
- **缩略图**: `meta/thumbnail.png`, 512×320 JPEG/PNG 均可

## 互斥锁 (flock)

### 为什么必须锁

- VZ 不允许两个 `VZVirtualMachine` 同时使用同一份磁盘文件, 写到一半会损坏
- config.json 并发修改会竞争
- macOS auxiliary 数据并发写更危险

### 锁文件设计

`bundle/.lock` 是一个普通文件, 存当前持有者信息:

```
{
  "pid": 12345,
  "host": "MacBookPro.local",
  "socketPath": "/Users/me/Library/Application Support/HVM/run/4f8e2b1a.sock",
  "mode": "runtime" | "edit",
  "since": "2026-04-25T03:10:00Z"
}
```

### 获取 / 释放

```swift
public final class BundleLock {
    public enum Mode { case runtime, edit }
    public init(bundleURL: URL, mode: Mode) throws {
        // 1. open(bundle/.lock, O_RDWR | O_CREAT, 0644)
        // 2. flock(fd, LOCK_EX | LOCK_NB) 失败 → 抛 .busy(pidFromFile)
        // 3. truncate + 写入当前 pid/socket/mode/since
    }
    public func release() {
        // flock(fd, LOCK_UN); close(fd)
        // 写入一个"已释放"的标记(可选)或直接保留文件
    }
    deinit { release() }
}
```

### 进程崩溃后的锁

- flock 是内核持有, 进程退出自动释放, 不会留死锁
- `.lock` 文件里的 PID 可能过期, 新进程获取锁时覆盖即可
- GUI 列表刷新时, 若发现某 bundle 的 `.lock` 里 PID 不存在且 flock 能拿到, 视为 `stopped`

### 与 hell-vm 的互不干扰

- 扩展名不同: `.hvmz` vs `.hellvm`
- 锁文件名不同: HVM 用 `.lock`, hell-vm 用什么与我们无关
- 两套工具同时运行不同 bundle 完全安全

## schema 演化策略

- 新字段**只加不改**, 加字段必须带默认值, 旧 bundle 缺字段时走默认
- 删字段**保留 JSON key**, 读取时忽略, 避免老 HVM 报错
- 不兼容变更(改字段语义、重命名字段)必须升 `schemaVersion`, 并提供一次性迁移函数 `migrateV1toV2(json)`
- 迁移函数写在 `HVMBundle/Migration.swift`, 每次升级跑一次, 写回磁盘
- 当前版本读到更高版本号时**拒绝加载**, 提示升级 HVM

## I/O 原子性

config.json 写入走 "写临时 + rename" 原子替换:

```swift
let tmp = bundleURL.appendingPathComponent("config.json.tmp")
try data.write(to: tmp, options: .atomic)
try FileManager.default.replaceItem(at: configURL, withItemAt: tmp, ...)
```

避免半写入的 config 导致下次加载崩溃。

## 验证

加载 bundle 时必做校验:

1. `config.json` 存在且可解析为 `VMConfig`
2. `schemaVersion <= 1`(当前)
3. `guestOS` 合法枚举值
4. 主盘文件存在
5. `macOS` guestOS 必须有 `auxiliary/hardware-model` 和 `machine-identifier`, 否则识别为"未完成创建"
6. 所有 DiskSpec.path 落在 `disks/` 下且不是 symlink 指向 bundle 外

失败都抛 `BundleError.invalid(reason:)`, GUI 用 ErrorDialog 展示。

## 删除 bundle

- GUI 删除 = 移入废纸篓(`NSWorkspace.recycle`), 不直接 `rm -rf`
- CLI `hvm-cli delete <bundle>`:
  - 默认也走废纸篓
  - `--purge` 才直接 `rm -rf`, 要求 `--force` 二次确认
- 删除前必须确认 `.lock` 未被持有

## 示例: 创建一个 Linux bundle

```bash
hvm-cli create \
  --name ubuntu-2404 \
  --os linux \
  --cpu 4 --memory 8 \
  --disk 64 \
  --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso \
  --path ~/VMs/
# 创建 ~/VMs/ubuntu-2404.hvmz/
#   config.json (schemaVersion=1, bootFromDiskOnly=false)
#   disks/main.img (64 GiB sparse)
#   nvram/efi-vars.fd (空)
```

## 不做什么

1. **不加密 bundle**: 文件系统级 FileVault 已负责
2. **不签名 bundle**: 不做完整性校验, 用户改 config.json 自负
3. **不做 bundle 内嵌 snapshot**: 快照走 APFS clonefile(见 [STORAGE.md](STORAGE.md))
4. **不做网络同步 / iCloud Drive 放置指引**: 同步工具与 flock / sparse 文件冲突, 明确不支持

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| B1 | 是否支持"模板 bundle" (只读, 克隆出实例) | 不做, 用 clonefile 手动克隆即可 | 已决 |
| B2 | config.json 是否允许注释 (JSON5) | 不允许, 纯 JSON, 避免解析器复杂化 | 已决 |
| B3 | 是否引入 `config.lock` 编辑模式(区别于 `runtime`) | 保留 mode 字段, 暂不使用 | M2 GUI 编辑时定 |

---

**最后更新**: 2026-04-25
