# Guest OS 装机流程 (`HVMInstall`)

## 目标

- 用最简交互把 guest OS 装到 bundle 的主盘
- 支持 macOS (Apple Silicon) 和 Linux (arm64) 两条路径
- 其他 OS 明确不支持

## 支持矩阵

| Guest | 架构 | 方式 | HVM 自动化程度 |
|---|---|---|---|
| macOS 13+ | arm64 | IPSW + `VZMacOSInstaller` | 全自动, 进度条完成即可 |
| Linux arm64 | arm64 | ISO + EFI 启动 | 半自动, guest 内交互靠用户/hvm-dbg |
| Windows | any | N/A | **不支持**, 向导里不出现 |
| macOS Intel | x86_64 | N/A | **不支持**, VZ 不做 TCG |
| riscv64 / 其他 | 非 arm64 | N/A | **不支持** |

## macOS Guest 装机

### 前置

- 一份与物理 Mac 兼容的 macOS IPSW 文件(restore image)
- 来源:
  - **HVM 内建下载器**(推荐): 走 `VZMacOSRestoreImage.fetchLatestSupported()` 取 Apple 当前推荐的 IPSW URL, `URLSession.downloadTask` 流式落到 `~/Library/Application Support/HVM/cache/ipsw/<buildVersion>.ipsw`
    - GUI: 创建向导 macOS 分支点 `Use Latest`
    - CLI: `hvm-cli ipsw fetch` (或先 `hvm-cli ipsw latest` 看元信息再决定是否下)
  - 用户自带 IPSW 文件(任意来源, 例 ipsw.me): 直接在向导 / `--ipsw` 里指定路径

### 流程

```
1. 创建向导选 macOS
2. 用户选 IPSW 文件(或点"自动下载", HVM 进度条下载到 cache)
3. VZMacOSRestoreImage.load(from: ipswURL) 校验 IPSW
4. 从 restoreImage.mostFeaturefulSupportedConfiguration 拿到最低 CPU/RAM 建议
   → 与用户填的配置比对, 不足时给提示
5. 创建 bundle 目录 + disks/main.img
6. 写 auxiliary 数据:
      aux = try VZMacAuxiliaryStorage(creatingStorageAt: auxURL,
                                      hardwareModel: restoreImage.mostFeaturefulSupportedConfiguration.hardwareModel,
                                      options: [.allowOverwrite])
      // 同时生成 machine-identifier 保存
7. 构建 VZVirtualMachineConfiguration, guestOS = .macOS
8. VZVirtualMachine + VZMacOSInstaller(virtualMachine:, restoringFromImageAt: ipswURL)
9. installer.install { progress in ... } 异步安装
10. 安装完成 → config.macOS.autoInstalled = true
                → config.bootFromDiskOnly = true
                → 存 bundle
11. 用户点"进入 VM", 首次启动走正常 VM 流程
```

### 进度上报

```swift
installer.progress.observe(\.fractionCompleted) { progress, _ in
    mainActor { self.installProgress = progress.fractionCompleted }
}
```

GUI 显示进度条, CLI `hvm-cli install foo` 打印 `Installing macOS: 42%`。

### 失败处理

| 失败 | 处理 |
|---|---|
| IPSW 版本太老 VZ 不认 | 启动前校验 `VZMacOSRestoreImage.isSupported`, 失败报 `InstallError.ipswUnsupported` |
| 磁盘空间不足 | 安装前预检 bundle 卷剩余 > IPSW 大小 × 2 |
| 安装中进程崩 | bundle 半成品, 标记 `autoInstalled = false`, 下次启动报"未完成安装"提示重装 |
| hardware-model 已写入但安装失败 | 因为 hardware-model 一旦生成就是 bundle 绑定, 删 bundle 重来 |

### hardware-model 与 machine-identifier 的永久性

- `hardware-model` 在 auxiliary 创建时就固化, 之后不可变
- `machine-identifier` 是每台 VM 的唯一标识, 也不变
- 如果用户误删 `auxiliary/` → bundle 作废, 无法恢复
- 备份建议: 整 bundle 目录复制, 不单独动 auxiliary

### macOS guest 使用限制

- 不能装 macOS 12 及以前(VZ macOS guest 最低 13.0, 对应 IPSW 是 13.0+)
- 不能装 Intel macOS(arm64 only)
- 不能在 guest 里起另一个 macOS VM(嵌套虚拟化 VZ 不支持)
- 不能给 guest 额外装驱动(无 kext, 所有设备走 VZ 虚拟)

## Linux Guest 装机

### 前置

- arm64 的发行版 ISO, 例:
  - Ubuntu Server 24.04 arm64
  - Debian 13 arm64
  - Fedora arm64
  - Alpine Linux arm64

### 流程

```
1. 创建向导选 Linux
2. 用户选 ISO 文件(保持路径, 不复制进 bundle)
3. 创建 bundle:
      disks/main.img (空的 raw sparse)
      nvram/efi-vars.fd (新建, VZEFIVariableStore init)
      config.bootFromDiskOnly = false
      config.installerISO = <绝对路径>
4. 用户点"启动"
5. VM 启动, EFI 引导菜单可能自动从 ISO 启动(取决于 ISO 是否有默认 EFI 引导条目)
      若 EFI 默认先跑 HDD, 用户进 EFI shell (ESC or F2) 手动选 CD
6. 用户在 guest 内完成安装(分区/选包/设密码等), HVM 不介入
7. 安装完毕, guest 自己关机, 或用户点停机
8. 用户执行 hvm-cli boot-from-disk foo (或 GUI 按钮)
      → config.bootFromDiskOnly = true
9. 下次启动不挂 ISO, 直接从硬盘启动
```

### 为什么 Linux 不做全自动

理由:

1. 每个发行版安装器 UI 不同(Ubuntu 用 curtin, Debian 用 d-i, Fedora 用 Anaconda)
2. 自动化需要 preseed / kickstart / cloud-init, 要求用户预制配置文件, 比手动还烦
3. 不做是**对的简单**, 用户一次性操作, 之后 bundle 即可重复使用

**若用户要批量装**, 推荐路线:

- 用 `cloud-init` 支持的镜像(Ubuntu Cloud Image, Debian GenericCloud)
- 把 cloud-init metadata 做成第二个 ISO 挂载
- 首启自动跑 cloud-init 完成 user/ssh key 配置
- 不需要安装器, 镜像直接能启动

这不是 HVM 的核心流程, 文档里给出 pointer, 不做成 wizard:

```bash
# 用 cloud-init 镜像
curl -LO https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img
# 转 raw
qemu-img convert -f qcow2 -O raw ubuntu-24.04-server-cloudimg-arm64.img main.img   # 若装了 qemu-img; 否则走 dd

# 在 HVM 里:
hvm-cli create --name cloud --os linux --cpu 2 --memory 2 --disk 0 --path ~/VMs/
# 手动 cp main.img 到 bundle/disks/, 调整 config.bootFromDiskOnly=true
# 做 seed ISO (cloud-init metadata), 挂载
# 启动 → 自动配置完成
```

这是 advanced 路线, GUI 向导不展开。

### EFI 变量存储

```swift
let nvramURL = bundle.appendingPathComponent("nvram/efi-vars.fd")
let variableStore: VZEFIVariableStore
if FileManager.default.fileExists(atPath: nvramURL.path) {
    variableStore = VZEFIVariableStore(url: nvramURL)
} else {
    variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
}
let bootLoader = VZEFIBootLoader()
bootLoader.variableStore = variableStore
```

用户如果在 EFI shell 里设了启动顺序, 这些信息会落 `efi-vars.fd`, 下次生效。

### Linux 的 rosetta share(可选)

`config.linux.rosettaShare = true` 时:

```swift
let rosetta = try VZLinuxRosettaDirectoryShare()   // 若未安装 Rosetta 2 会抛
let share = VZVirtioFileSystemDeviceConfiguration(tag: "RosettaShare")
share.share = rosetta
```

guest 内挂载:

```
mount -t virtiofs RosettaShare /mnt/rosetta
/mnt/rosetta/rosetta /path/to/x86_64-binary
# 或注册 binfmt_misc 让 x86_64 binary 自动走 rosetta
```

这让 arm64 Linux guest 能跑 x86_64 Linux binary。

未安装 Rosetta 2 时 HVM 提示用户:

```bash
softwareupdate --install-rosetta --agree-to-license
```

## 安装状态机

```swift
public enum InstallState: Equatable {
    case idle
    case downloading(fraction: Double)   // 仅 IPSW 自动下载
    case preparing                       // 校验 IPSW / 创建 aux
    case installing(fraction: Double)    // VZMacOSInstaller progress
    case finalizing                      // 写 config / 切 bootFromDiskOnly
    case succeeded
    case failed(InstallError)
}
```

### InstallError

```swift
public enum InstallError: Error {
    case ipswNotFound(path: String)
    case ipswUnsupported(reason: String)
    case ipswDownloadFailed(reason: String)
    case auxiliaryCreationFailed(reason: String)
    case diskSpaceInsufficient(requiredBytes: UInt64, availableBytes: UInt64)
    case installerFailed(reason: String)
    case rosettaNotInstalled
    case isoNotFound(path: String)
}
```

## 进度与日志

- IPSW 下载: 按 100ms 节流推送 progress event
- macOS 安装: VZ 自己 progress, 我们 observe + 转发
- Linux: 只输出 serial console 到 bundle log, 不算 "安装进度"
- 日志全落 `bundle/logs/<date>.log`

## hvm-cli install

```bash
# 对已创建 bundle 启动装机
hvm-cli install foo

# macOS: 自动化
# Linux: 只是启动 VM 挂 ISO, 用户进 guest 自己装

# 看进度
hvm-cli install foo --format json --follow
{ "phase": "installing", "fraction": 0.42 }
{ "phase": "installing", "fraction": 0.55 }
...
{ "phase": "succeeded" }
```

## IPSW 缓存管理

- 缓存目录: `~/Library/Application Support/HVM/cache/ipsw/`
- 文件名:
  - `<buildVersion>.ipsw` — 完成态(由 VZ 报告的 `buildVersion` 派生,同 build 视为同一份)
  - `<buildVersion>.ipsw.partial` — 半成品,下载未完成 / 中断时留在原地
- 命中策略: `.ipsw` 存在且 size > 0 即视为可用; 真正的内容校验交给后续 `RestoreImageHandle.load`(VZ 内部签名校验)
- 下载实现: `HVMInstall.IPSWFetcher.downloadIfNeeded(entry:force:onProgress:)`,基于 `URLSessionDataTask` + 自管 `FileHandle`,100ms 节流上报进度

### 断点续传

不用 `URLSessionDownloadTask` 的 `resumeData` blob(跨进程不可靠 / tmp 路径不可控),自己管文件 + HTTP `Range` 头:

1. 下载中文件名 `<build>.ipsw.partial`;完成后**原子** rename 成 `<build>.ipsw`
2. 下次 `fetch` 检查 `.partial` size > 0 → 发 `Range: bytes=N-` 请求续传
3. 服务器三种响应分别处理:
   - `206 Partial Content` → seek-to-end 追加,`Content-Range` 头解析完整文件大小
   - `200 OK` (服务器忽略 Range)→ truncate `.partial`,从头开始
   - `416 Range Not Satisfiable` → `.partial` 已等于完整大小,直接 promote 成 `.ipsw`
4. App 崩溃 / 系统重启 / `kill -9` 都不影响 `.partial`,下次 fetch 自动续

Apple CDN 静态 IPSW 资源原生支持 Range 请求,该路径稳定。`--force` 同时清 `.ipsw + .partial` 强制全新下载;`hvm-cli ipsw rm <build>` 也会清两者。

### 接口一览

- CLI:
  - `hvm-cli ipsw latest` — 查询最新, 不下载
  - `hvm-cli ipsw fetch [--force] [--format json --follow]` — 下载 (已缓存默认跳过, 有 .partial 自动续传)
  - `hvm-cli ipsw list` — 列出本地缓存(完成态 + 半成品分两段输出)
  - `hvm-cli ipsw rm <build|all>` — 删除单个或全部缓存(含 .partial)
- GUI 接口: 创建向导 macOS 分支 `Use Latest` 按钮 → 弹 `IpswFetchDialog` 模态进度条 → 完成后回填 ipsw 路径(中途关闭 App 也安全,下次按钮再点继续从断点)
- 不自动清理 cache,以免下次装机重下;空间紧张时用户手动 `hvm-cli ipsw rm all`

## 不做什么

1. **不做 Windows 装机向导 / 任何 Windows 提示**
2. **不内置 Linux 发行版清单**: 用户自带 ISO, HVM 不做 ISO 镜像站
3. **不做自动 cloud-init seed ISO 生成工具**: 太 niche, 用户自己做
4. **不做 Linux 安装器自动按键**: 用 `hvm-dbg` 配合 cloud-init 脚本化, 不写硬编码
5. **不做 guest 内包管理器调用**

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| J1 | 是否做内置 IPSW 下载器 | **已决: 做**. 走 `VZMacOSRestoreImage.fetchLatestSupported` + `URLSessionDownloadTask`,落 `cache/ipsw/<build>.ipsw`,不解析 SUCatalog | M3 已决 |
| J2 | Linux 向导是否推荐特定发行版 | 不推荐, 用户自带 ISO | 已决 |
| J3 | 是否支持"从已装好的系统迁移" | 不支持, 走 dd + raw image 手动挂 | 已决 |

## 相关文档

- [VZ_BACKEND.md](VZ_BACKEND.md) — 构建 VM 配置
- [VM_BUNDLE.md](VM_BUNDLE.md) — auxiliary / nvram 字段
- [STORAGE.md](STORAGE.md) — 主盘创建
- [CLI.md](CLI.md) — `hvm-cli install` 子命令

---

**最后更新**: 2026-04-25
