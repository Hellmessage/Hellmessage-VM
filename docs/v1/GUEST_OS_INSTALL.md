# Guest OS 装机流程 (`HVMInstall`)

## 目标

- 用最简交互把 guest OS 装到 bundle 主盘
- 三条主路径: macOS (VZ) / Linux arm64 (VZ 默认, 可选 QEMU) / Windows arm64 (仅 QEMU)
- 自动下载常用 OS 镜像, 用户不必手动找 ISO / IPSW

## 支持矩阵

| Guest | 架构 | 后端 | 自动化程度 |
|---|---|---|---|
| macOS 13+ | arm64 | **仅 VZ** | 全自动 (IPSW + `VZMacOSInstaller`) |
| Linux | arm64 | VZ 默认, 可选 QEMU | 半自动 (ISO 启动 + 用户在 guest 完成安装), ISO 走 OSImageCatalog 自动下载 |
| Windows 10/11 | arm64 | **仅 QEMU** (强制 `engine=qemu`) | 半自动, swtpm vTPM 2.0 + EDK2 自家 firmware + virtio-win 驱动 |
| macOS Intel / x86_64 / riscv64 | 非 arm64 | — | **不支持** (CLAUDE.md VZ 能力边界 + QEMU 仅打 aarch64-softmmu) |

## macOS guest 装机

### IPSW 来源

`HVMInstall/IPSWFetcher.swift` + `RestoreImageHandle.swift`, 三种解析路径 + 断点续传:

1. **最新版** — `VZMacOSRestoreImage.fetchLatestSupported()` 取 Apple 当前推荐
   - GUI: 创建向导 `Use Latest`
   - CLI: `hvm-cli ipsw fetch` (默认行为)
2. **指定版本** — 从 ipsw.me API 拉 `VirtualMac2,1` 全量历史 (50+ 版本) 按 build 选
   - GUI: `Choose Version…` → `IpswCatalogPicker` (列 osVersion / build / postingDate / cached)
   - CLI: `hvm-cli ipsw catalog` 列表 + `hvm-cli ipsw fetch --build <BUILD>` 下载
   - 数据源说明: Apple `mesu.apple.com` 只发当前最新一版, 没历史; ipsw.me 是社区维护的 IPSW 索引, 稳定多年, 免认证。`signed=false` 旧 IPSW 仍可用于 VZ guest (VZ 不校验当前签名)
3. **任意 URL** — 用户手填
   - CLI: `hvm-cli ipsw fetch --url <URL>` (GUI 不暴露)
4. 用户自带本地 IPSW: GUI `Browse` / CLI `--ipsw <path>`

### 装机流程

```
1. 创建向导选 macOS, 选/下 IPSW (走 IPSWFetchDialog 进度)
2. VZMacOSRestoreImage.load(from:) 校验
3. 根据 mostFeaturefulSupportedConfiguration 给 CPU/RAM 建议下限
4. 创建 bundle: disks/os.img (raw sparse) + auxiliary 数据 + machine-identifier
5. VZMacOSInstaller(virtualMachine:, restoringFromImageAt:) 异步装
6. progress observe → GUI 进度条 / CLI `--format json --follow` 流式
7. 完成 → config.macOS.autoInstalled = true + bootFromDiskOnly = true
```

### 缓存与断点续传

- 缓存 `~/Library/Application Support/HVM/cache/ipsw/<buildVersion>.ipsw`
- 半成品 `<build>.ipsw.partial` + `.meta` (ETag / Last-Modified)
- HTTP `Range: bytes=N-` + `If-Range: <validator>`; 200 / 206 / 416 三种响应分别处理
- App 崩溃 / kill / 重启都不影响 partial; 下次 fetch 自动续
- `--force` 清三件 (`.ipsw + .partial + .meta`) 强制全新下载

### hardware-model 永久性

- auxiliary 创建时固化 hardware-model + machine-identifier, 不可变
- 误删 `auxiliary/` → bundle 作废, 备份建议整 bundle 复制

### 失败处理

| 失败 | 处理 |
|---|---|
| IPSW 版本 VZ 不认 | 启动前 `VZMacOSRestoreImage.isSupported`, 报 ipswUnsupported |
| 磁盘空间不足 | 预检 bundle 卷剩余 > IPSW 大小 × 2 |
| 装机中崩 | 半成品标 `autoInstalled=false`, 下次启动报 "未完成安装" |

### 限制

- 不能装 macOS 12 及更早 (VZ 最低 13.0)
- 不能装 Intel macOS (arm64 only)
- 不能嵌套虚拟化 (在 macOS guest 内再起 VM)
- 不能装 kext / 额外驱动 (设备一律 VZ 虚拟)

## Linux guest 自动下载

### OSImageCatalog (2026-05-03 落地)

`HVMInstall/OSImageCatalog.swift` 内置 7 个 arm64 发行版 entry, **family** + **version** 维度组织:

| family | entry 示例 |
|---|---|
| `ubuntu` | Ubuntu Server 24.04 LTS / 22.04 LTS |
| `debian` | Debian 13 stable (netinst) |
| `fedora` | Fedora Server 44 (netinst) |
| `alpine` | Alpine Linux 3.20 (virt) |
| `rocky` | Rocky Linux 9 (minimal) |
| `opensuse` | openSUSE Tumbleweed (NET) |

每条 entry 含 `id` / `displayName` / `family` / `version` / `url` / 可选 `sha256` / `hint`。

### OSImageFetcher

`HVMInstall/OSImageFetcher.swift`, 走 `ResumableDownloader` (`HVMUtils/ResumableDownloader.swift`) + SHA256 校验:

- 缓存路径 `~/Library/Application Support/HVM/cache/os-images/<family>/<file>.iso`
- catalog 命中 entry → SHA256 校验; custom URL 模式跳过校验
- 半成品 `.partial` + `.meta`, 同 IPSW 续传

CLI:

```
hvm-cli osimage list                                列 catalog (含已缓存标记)
hvm-cli osimage fetch <id|--url URL> [--force]      下载
       [--format json] [--follow]
hvm-cli osimage cache [--family ubuntu|...|custom]  列已缓存
hvm-cli osimage rm <id|all>                         删
```

GUI: 创建向导 Linux 分支 → `OSImagePickerDialog` 选 entry / 自填 URL → `OSImageFetchDialog` modal 进度 → 完成回填 ISO 路径。

### 装机流程

```
1. 创建向导选 Linux, 选 OSImageCatalog entry (按需自动下载) 或自带 ISO 路径
2. 创建 bundle:
      disks/os.img (VZ raw sparse) 或 disks/os.qcow2 (QEMU)
      nvram/efi-vars.fd (VZ; QEMU 走 EDK2 vars)
      config.installerISO = <绝对路径>
      config.bootFromDiskOnly = false
3. start: EFI 引导 ISO; 用户进 guest 装 (HVM 不介入)
4. 装完用户停机 → hvm-cli boot-from-disk foo (或 GUI 按钮)
5. 下次启动直走硬盘
```

ISO 路径**不复制进 bundle**, 只存绝对路径 (CLAUDE.md 磁盘约束)。

### 为什么 Linux 不做全自动

每发行版安装器 UI 不同 (Ubuntu curtin / Debian d-i / Fedora Anaconda); preseed / kickstart / cloud-init 比手动还烦。批量场景推荐用 cloud-init 镜像 + seed ISO, 不在 GUI 向导展开。

### 后端选择

- Linux 默认 VZ (体验更轻); QEMU 后端可选 (`engine=qemu`), 走 socket_vmnet 桥接 / 共享网络更灵活
- VZ 后端可启用 `rosettaShare = true` 让 arm64 guest 跑 x86_64 Linux binary (`mount -t virtiofs RosettaShare /mnt/rosetta`); 未装 Rosetta 2 时 HVM 提示 `softwareupdate --install-rosetta --agree-to-license`

## Windows arm64 装机 (QEMU 后端)

### 强约束

- **仅 QEMU 后端**: VZ 不支持 Windows guest (无 TPM, Win11 装不了; Win10 ARM 已无 ISO 来源)
- 配置 `engine=qemu` 强制, 创建向导 Windows 选项标"实验性 (QEMU 后端)"
- 缺 QEMU 产物 (`make qemu` 未跑) 时灰掉提示需先 `make build-all`

### Windows ISO 来源

ARM64 Windows ISO 不入 `OSImageCatalog` (官方分发不稳, 无固定直链), 走 custom URL 兜底:

- 用户自带 ISO 路径填入 (CLI `--iso` / GUI `Browse`)
- 或 `hvm-cli osimage fetch --url <URL>` 缓存 (跳过 SHA 校验)

### 自动下载 virtio-win 驱动 ISO

`HVMInstall/VirtioWinCache.swift` — Win11 ARM64 装机必需 (没驱动 Setup 看不到 virtio-blk 磁盘):

- 缓存 `~/Library/Application Support/HVM/cache/virtio-win/virtio-win.iso`
- 全局共享: 所有 Win VM 引用同一份 (~700MB 一次, 不每个 VM 复制)
- 上游稳定 alias: `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`
- **不入包** (CLAUDE.md QEMU 后端约束 — 体积约 700MB)
- 创建 Win VM 时按需下载, GUI 走 `VirtioWinFetchDialog` 前台 modal 进度
- 已存在 + size ≥ 100MB sanity → 直接复用; 失败重新下 (一期不做断点续传)

### UTM Guest Tools ISO

QEMU `QemuArgsBuilder` 当前优先挂 UTM Guest Tools ISO (`HVMInstall/UtmGuestToolsCache.swift`), 含 ARM64 native vdagent + utmapp 自家 viogpudo (含 QXL escape SET_CUSTOM_DISPLAY) + qemu-ga, 覆盖 stock virtio-win 该负责的全部职责。stock virtio-win.iso 字段保留为 fallback 入口, 后续若需要老通路再启用。

### swtpm vTPM 2.0 sidecar

Win11 必需 TPM 2.0:

- `swtpm` + `libtpms` 由 brew 锁版本, 由 `scripts/qemu-build.sh` 打包入 `Resources/QEMU/bin/swtpm` + dylib 重定向 (CLAUDE.md QEMU 后端约束)
- 主进程通过 `Process` 启 swtpm + `unix:<run/<vm>.swtpm.sock>`, QEMU argv `-tpmdev emulator,id=tpm0,chardev=chrtpm` `-device tpm-tis-device,tpmdev=tpm0` 接入
- swtpm 自身日志 → `<vm>-<uuid8>/swtpm.log` + `swtpm-stderr.log`

### EDK2 firmware (Win11 patched)

- Linux guest: 用 QEMU 自带 kraxel firmware `edk2-aarch64-code.fd`
- Windows guest: 用 `scripts/edk2-build.sh` 自家 build (clone `edk2-stable202408` + apply `patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch` + cross compile RELEASE_GCC AARCH64), 落 `share/qemu/edk2-aarch64-code-win11.fd`
- 配套 `patches/qemu/0001-hvm-win11-lowram.patch` (`-machine virt,hvm-win11-lowram=on` 在 0x10000000 挂 16MB RAM 孔). 两个 patch 必须同时打 (单打任一会 ASSERT 挂死, 见 CLAUDE.md QEMU 后端约束)
- vars 模板用 QEMU 自带 `edk2-arm-vars.fd` 即可

### 装机流程

```
1. 创建向导选 Windows arm64 (自动 engine=qemu)
2. 准备 ARM64 Windows ISO (用户自带或 osimage fetch --url)
3. 触发 VirtioWinFetchDialog 按需下载 virtio-win.iso 到全局 cache
4. 创建 bundle: disks/os.qcow2 (QEMU) + edk2 vars 副本
5. start: 主进程拉 swtpm + QEMU; QEMU argv 注 ISO + virtio-win.iso + UTM Guest Tools ISO + tpm-tis-device
6. 用户进 Setup 完成安装 (UTM Guest Tools 提供 viogpudo / qemu-ga / vdagent)
7. 装完 boot-from-disk
```

详见 [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md)。

## 安装状态机 (`HVMInstall/InstallProgress.swift`)

```
idle → downloading(fraction) → preparing → installing(fraction) → finalizing → succeeded | failed(InstallError)
```

`InstallError` 含: `ipswNotFound` / `ipswUnsupported` / `ipswDownloadFailed` / `auxiliaryCreationFailed` / `diskSpaceInsufficient` / `installerFailed` / `rosettaNotInstalled` / `isoNotFound` 等。

## 进度与日志

- IPSW / OSImage 下载: 100ms 节流 progress, GUI 进度条 / CLI `--format json --follow` 流式
- macOS 装机: VZ 自己 progress, observe + 转发
- Linux: 只输出 serial console 到 `<bundle>/logs/console-<date>.log`, 不算"安装进度"
- 全 host 端日志走 `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/` (CLAUDE.md 日志路径约束)

## hvm-cli install

```
hvm-cli install foo                      # macOS 全自动; Linux 走 start + 手动安装
hvm-cli install foo --format json --follow
{ "phase": "installing", "fraction": 0.42 }
{ "phase": "succeeded" }
```

## 不做什么

1. 不内置 Linux 发行版包仓库 (catalog 只挂 ISO 链接, 不镜像)
2. 不做自动 cloud-init seed ISO 生成工具 (用户自己做)
3. 不做 Linux 安装器自动按键 (不写硬编码; 用 `hvm-dbg` + cloud-init 脚本化)
4. 不做"从已装好的系统迁移" (用户走 dd + raw image 手动挂)
5. 不做 Windows 全自动装机 (硬编码 unattend 是 anti-pattern, 见 CLAUDE.md)

## 相关文档

- [VZ_BACKEND.md](VZ_BACKEND.md) — VZ VM 配置
- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — QEMU 后端 (Win11 firmware / swtpm / patches)
- [VM_BUNDLE.md](VM_BUNDLE.md) — auxiliary / nvram / config.yaml 字段
- [STORAGE.md](STORAGE.md) — 主盘创建 (vz=raw / qemu=qcow2)
- [CLI.md](CLI.md) — `hvm-cli install` / `ipsw` / `osimage` 子命令

---

**最后更新**: 2026-05-04
