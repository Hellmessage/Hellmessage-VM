# Guest OS 装机 (Linux / Windows)

> 现状文档. QEMU 单后端路线 (`qemu-system-aarch64` + HVF + EDK2 firmware)。
> guest 仅支持 **Linux arm64** 与 **Windows 11 arm64 (实验性)**; macOS guest 已随 VZ 后端整条移除。
> 本文描述 HVM 当前代码的实际装机通路, 不含历史 VZ / macOS guest 内容。

源文件索引见文末「引用源文件」节。

---

## 1. 支持矩阵

| Guest | 架构 | 后端 | 装机入口 | 状态 |
|-------|------|------|----------|------|
| Linux | arm64 (aarch64) | QEMU + HVF | ISO 启动安装 → 切 `bootFromDiskOnly` 走硬盘 | 支持 |
| Windows 11 | arm64 | QEMU + HVF + swtpm + 自家 patched EDK2 | ISO 启动 + unattend 自动跳硬件检查 | 实验性 |
| macOS / x86_64 / riscv64 | — | — | — | **不支持** |

判定来源:
- `GuestOSType` 枚举 (`HVMBundle/VMConfig.swift`) 只有 `linux` / `windows` 两个 case。
- CLI `hvm-cli create --os` 帮助文案: `Guest OS: linux | windows (macOS 已下线 — VZ 后端移除)`。
- 创建向导内 Windows 选项标注「实验性 (QEMU 后端)」(GUI 约束)。

能力边界 (CLAUDE.md「能力边界约束」): 不做 x86_64 / riscv64 guest、不做 TCG 翻译、不做 macOS guest。

---

## 2. 通用约定

### 2.1 ISO 不入 bundle, 只存绝对路径

ISO 不复制进 `.hvmz`, 仅在 `VMConfig.installerISO` 字段存绝对路径。CLI `--iso` 与 GUI 选 ISO 都遵守 (`DetailBootSection.selectISO` 走 NSOpenPanel 写 `installerISO = url.path`)。

### 2.2 ISO 校验 (`HVMStorage/ISOValidator.swift`)

挂载前对 ISO 路径做轻量校验:

- 文件必须存在 (否则 `HVMError.storage(.isoMissing)`)。
- 大小须落在 `[1 MiB, 20 GiB)` (否则 `.isoSizeSuspicious`)。超范围多半是用户选错文件, 早失败优于挂载后 guest 起不来。

只校验存在性 + 大小区间, **不**校验 ISO 内容 / 文件系统签名。

### 2.3 装机两态 / 三态状态机 (config 字段)

装机推进由 `VMConfig` 三个字段驱动, 不靠运行时探测 guest:

- `installerISO: String?` — 安装 ISO 绝对路径; `bootFromDiskOnly=true` 时忽略。
- `bootFromDiskOnly: Bool` — false=从 ISO 装机, true=直接从硬盘启动。
- `windowsDriversInstalled: Bool` — 仅 Windows + `bootFromDiskOnly=true` 生效, 标记 viogpudo 等驱动是否已装。

GUI 详情页 ISO & 启动 section (`DetailBootSection`) 把这三字段映射成按钮:

- **Linux 两态**: 装机中 → 点 [安装完成] 置 `bootFromDiskOnly=true`。
- **Windows 三态**:
  - ① 装机中 (`!bootFromDiskOnly`) → 点 [安装完成] 置 `bootFromDiskOnly=true` + `windowsDriversInstalled=false`
  - ② 待装驱动 (`bootFromDiskOnly && !windowsDriversInstalled`) → guest 内装完驱动后点 [驱动安装完成] 置 `windowsDriversInstalled=true`
  - ③ 驱动就绪 (两者皆 true)
- 选 ISO → `installerISO=path` + `bootFromDiskOnly=false` (重新进装机态); 弹出 ISO → `installerISO=nil` + `bootFromDiskOnly=true` (切仅硬盘)。
- 这些字段相互耦合 (改 ISO 自动取消 `bootFromDiskOnly`), 故走离散即时按钮 `store.saveConfig`, **不**走 draft/saveForm。
- 仅 stopped 可改 (boot/ISO 是启动期拍板)。

---

## 3. Linux arm64 装机

### 3.1 内建发行版目录 (`OSImageCatalog`)

`HVMInstall/OSImageCatalog.swift` 内建一份 hardcoded arm64 发行版列表 (数据采集自 2026-05-03)。当前 7 条:

| id | 显示名 | family | version | SHA256 | 估算大小 |
|----|--------|--------|---------|--------|----------|
| `ubuntu-24.04` | Ubuntu Server 24.04 LTS | ubuntu | 24.04.4 LTS (Noble Numbat) | 有 | ~3.1 GB |
| `ubuntu-22.04` | Ubuntu Server 22.04 LTS | ubuntu | 22.04.5 LTS (Jammy Jellyfish) | 有 | ~1.7 GB |
| `debian-13` | Debian 13 stable (netinst) | debian | 13.4.0 (Trixie) | 有 | ~650 MB |
| `fedora-44` | Fedora Server 44 (netinst) | fedora | 44-1.7 | 有 | ~1.2 GB |
| `alpine-3.20` | Alpine Linux 3.20 (virt) | alpine | 3.20.10 | 有 | ~60 MB |
| `rocky-9` | Rocky Linux 9 (minimal) | rocky | 9.7 | 有 | ~2.0 GB |
| `opensuse-tumbleweed` | openSUSE Tumbleweed (NET) | opensuse | rolling | **nil (跳过校验)** | ~450 MB |

要点:
- `family` 枚举 (`OSImageFamily`): `ubuntu` / `debian` / `fedora` / `alpine` / `rocky` / `opensuse` / `custom`。
- `sha256` 为可选: openSUSE Tumbleweed 是滚动发行 (`-Current` 别名, 每周更新), `sha256=nil` 跳过校验; 其余 6 条都带固定 SHA256。
- **Windows 不在此 catalog**: Win11 ARM64 官方仅 Insider 注册 (法律灰色), Win10 ARM64 官方已无 ISO 来源。Windows ISO 走 `custom` 通路 (用户自填 URL / 本地路径)。
- 每个 entry 带 `hint` 一句话提示 (UI 描述行)。
- 升级流程见 `OSImageCatalog.swift` 头部注释 (webfetch 各发行版 SHA256SUMS → 改 entries → `make build` + 实测下载一条)。

### 3.2 下载器 (`OSImageFetcher`)

`HVMInstall/OSImageFetcher.swift` 提供两条下载入口:

- `downloadIfNeeded(entry:force:onProgress:)` — 走 catalog 内建条目, 下载后 (若 `entry.sha256 != nil`) 流式算 SHA256 校验。
- `downloadCustom(url:force:onProgress:)` — 用户自填 URL, **不**做 SHA256 校验 (来源未知; Win11 ISO 等场景兜底)。

特性:
- **断点续传**: 内部委托 `HVMUtils.ResumableDownloader` 做断点续传 + atomic rename。`partialSize(entry:)` 查半成品大小, 已有 `.partial` 时从断点续。
- **SHA256 校验**: 下载完成后流式 (1 MiB chunk) 算 SHA256 (`CryptoKit.SHA256`), 跑在 detached Task; 3 GB 文件约 5-10s。**不匹配则删除本地文件** (避免次次重下命中坏文件得到同一坏文件) 并抛错。
- 进度阶段 `OSImageFetchPhase`: `downloading` / `verifying` / `completed` / `alreadyCached`; 进度结构带 received/total bytes + bytesPerSecond + ETA。

缓存布局 `~/Library/Application Support/HVM/cache/os-images/` (`HVMPaths.osImagesCacheDir`), 按 family 分子目录:

```
cache/os-images/
├── ubuntu/    <iso 文件名 含小版本号>
├── debian/
├── fedora/
├── alpine/
├── rocky/
├── opensuse/
└── custom/    <用户 URL 文件名>
```

本地文件名 = URL 最后一段 (`cacheFileName`), 含小版本号便于多版本共存。缓存就绪判定 = 文件存在且大小 > 0。

### 3.3 CLI: `hvm-cli osimage`

`hvm-cli/Commands/OsImageCommand.swift` 暴露目录与缓存管理:

- `osimage list` — 列 catalog 内建发行版 (id / version / 缓存状态 / 估算大小 / URL); 支持 `--json`。
- `osimage fetch <id>` — 下载内建 entry (SHA256 校验); `--force` 强制重下。
- `osimage fetch --url <U>` — 下载自定义 URL (跳过校验)。id 与 `--url` 二选一互斥。
- `osimage cache` — 列已缓存文件。

下载进度实时打印百分比 / 速率 / ETA。

### 3.4 Linux 装机流程

1. 拿到 ISO (catalog 下载 / custom 下载 / 本地已有)。
2. 创建 VM: `hvm-cli create --os linux --iso <绝对路径>` (`--os linux` 时 `--iso` 必填), 或 GUI 创建向导选 Linux + 选 ISO。
3. 首次启动 (`bootFromDiskOnly=false`): QEMU 用 stock kraxel firmware (`share/qemu/edk2-aarch64-code.fd`, 单 `-bios`), ISO 走 **virtio-cdrom** (`-drive file=<iso>,if=virtio,media=cdrom,readonly=on`; Ubuntu installer 已验证能 boot)。装机阶段带 `-no-reboot` (installer 拷完触发 reboot 时 QEMU 直接退出, 给用户决策点)。
4. guest 内走发行版 installer (live-server 文本 UI / netinst 等) 装到主盘。
5. 装完后在 GUI 点 [安装完成] (或 `hvm-cli boot-from-disk`), 置 `bootFromDiskOnly=true`。
6. 再 cold start: 不再挂 ISO、不带 `-no-reboot`, 直接从硬盘启动。

Linux GPU: 用 `virtio-gpu-pci` (Linux kernel 自带 driver, OS 期响应 EDID 变化做 dynamic resize, 不依赖额外 guest tools)。

---

## 4. Windows 11 arm64 装机 (实验性)

Windows guest 是实验性能力, 装机比 Linux 复杂, 牵涉 swtpm TPM 2.0、自家 patched EDK2 firmware、unattend 自动跳硬件检查、virtio / UTM Guest Tools 驱动。Windows ISO 不在内建 catalog, 用户自备 (custom 下载或本地路径)。

### 4.1 创建 + 配置 (`WindowsSpec`)

`hvm-cli create --os windows` 创建时挂 `WindowsSpec` (`VMConfig.windows`), 默认值:

| 字段 | 默认 | 含义 |
|------|------|------|
| `secureBoot` | true | SecureBoot 状态 (持久在 nvram vars, 由 patched EDK2 firmware 实现; 无独立 argv) |
| `tpmEnabled` | true | Win11 必需的 TPM 2.0, 走 swtpm 模拟 |
| `bypassInstallChecks` | true | 生成 AutoUnattend.xml 跳过 Setup 硬件检查 |
| `autoInstallVirtioWin` | **false** | 已被 UTM Guest Tools 替代, 默认关 (缺字段也兜底 false) |
| `autoInstallSpiceTools` | true | 首登自动装 UTM Guest Tools (ARM64 vdagent + viogpudo) |

### 4.2 swtpm TPM 2.0

Win11 装机要求 TPM 2.0。HVM 在 QEMU 启动前由 `SwtpmRunner` 起 swtpm sidecar (打包在 `Resources/QEMU/bin/swtpm`), QEMU 启动后通过 socket 连接:

```
-chardev socket,id=chartpm,path=<swtpm.sock>
-tpmdev emulator,id=tpm0,chardev=chartpm
-device tpm-tis-device,tpmdev=tpm0
```

要点 (`QemuHostEntry.swift` / `QemuArgsBuilder.swift`):
- 仅 `guestOS==.windows && windows.tpmEnabled==true` 时注入。
- swtpm 必须在 QEMU 之前 listen, 否则 QEMU 连不上。socket 路径由调用方注入 (避免硬编码 bug); 没传 socket 路径即便 `tpmEnabled=true` 也不挂 TPM device (Win11 装机会卡在「This PC can't run Windows 11」)。
- tpmstate 目录持久化 NV 状态 (Win11 SecureBoot 信任根 + TPM PCR 都在这)。
- **加密 VM**: swtpm 走 `SwtpmKeyHelper` 经 Pipe (fd=0) 注入 32 字节 binary key, swtpm 用此 key 对 NVRAM state 做 AES-256-CBC 加密, 不落明文。
- 缺 swtpm 二进制时提示 `make qemu` 重打包 (从 Homebrew 复制 swtpm 入包) 或临时 `brew install swtpm`。

### 4.3 EDK2 firmware + SecureBoot + win11-lowram patch

Windows guest 不能用 Linux 的 stock kraxel firmware, 必须用 HVM 自家 patched EDK2:

- **双 pflash**: RO code (`share/qemu/edk2-aarch64-code-win11.fd`, 由 `scripts/edk2-build.sh` 自家 build) + RW vars (nvram, SecureBoot 状态持久)。
  - 明文 VM: vars 走 raw `efi-vars.fd`。
  - 加密 VM (qemu-perfile): vars 走 LUKS qcow2 (`encrypt.format=luks` + secret)。
- **win11-lowram patch** (`patches/qemu/0001` + `patches/edk2/0001` 配对): QEMU `-machine virt,hvm-win11-lowram=on` 在 `0x10000000` 挂 16 MB RAM 孔, 让 Win11 ARM64 bootmgfw 的 `ConvertPages` 成功。
  - **当前默认关**, 仅 `guestOS==.windows && env HVM_QEMU_WIN11_LOWRAM=1` 时才加 `,hvm-win11-lowram=on`。
  - 要求配套 patched EDK2 firmware: stock kraxel firmware 看到 `0x10000000` 的 `/memory` 节点会 ASSERT 挂死, 所以默认关。开启路径: `scripts/edk2-build.sh` build 出 patched firmware 拷进 stage, 再 `export HVM_QEMU_WIN11_LOWRAM=1` 启动。
- EDK2 锁定 `edk2-stable202408` (不是 202508; 202508 改了 PlatformBootManagerLibLight 行为, 无 NV BootOrder 时落 EFI Shell 不自动 boot), 详见 CLAUDE.md「QEMU 后端约束」。

> 注: `WindowsSpec.secureBoot` 字段持久化 SecureBoot 意图, 但 argv builder **不**为它生成独立参数 — SecureBoot 由 patched EDK2 firmware + nvram vars 隐式承载。

### 4.4 unattend 自动跳硬件检查 (`WindowsUnattend`)

`HVMQemu/WindowsUnattend.swift` 在启动前生成 `AutoUnattend.xml` 并用 macOS 自带 `/usr/bin/hdiutil makehybrid` 打成 ISO9660+UDF 混合 ISO (零外部依赖), 启动时作为辅助 cdrom 给 Windows Setup 自动读取。

- **三份文件名都写** (不同 Win 版本对大小写要求不一): `Autounattend.xml` (MS 官方) / `autounattend.xml` (24H2 实测更可靠) / `unattend.xml` (兜底)。
- **幂等**: XML 内容未变则复用现有 ISO, 不重打 (`hdiutil` 较慢)。

`AutoUnattend.xml` 两段 (按开关条件性生成):

- **windowsPE pass** (`bypassInstallChecks=true`): `reg add HKLM\System\Setup\LabConfig` 写 `BypassTPMCheck` / `BypassSecureBootCheck` / `BypassRAMCheck` / `BypassCPUCheck` / `BypassStorageCheck` 全 `=0x1`, 外加 `MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU=0x1`, 让 Win11 Setup 跳过全部硬件检查。
- **oobeSystem pass** (`FirstLogonCommands`, 按 `autoInstallVirtioWin` / `autoInstallSpiceTools` 生成):
  - virtio-win 驱动 (默认关): 扫所有盘符找 `%D:\NetKVM` → `certutil -addstore TrustedPublisher` 装 Red Hat 代码签名证书 (nested for 遍历 `.cer`, 不接受 wildcard) → `pnputil /add-driver %D:\*.inf /subdirs /install` 递归装 NetKVM/viostor/viogpudo → `pnputil /scan-devices` 重新枚举, 全程 redirect 到 `C:\HVM-virtio-install.log`。
  - UTM Guest Tools (默认开): 扫所有盘符找 `utm-guest-tools-*.exe`, `start /wait %F /S` NSIS 静默装。

orchestration (`QemuHostEntry.swift`): 仅 windows + 三开关任一开时, 启动前 `WindowsUnattend.ensureISO` 现做现挂; 失败 fail-soft (warn + 不挂第二 cdrom, 用户仍可手动 Shift+F10 在 Setup 里跑 reg add), 不阻塞 VM 启动。

### 4.5 virtio-win 驱动 ISO (`VirtioWinCache`) — 默认禁用

`HVMInstall/VirtioWinCache.swift` 管理 virtio-win.iso 全局缓存 (~700 MB)。

- 下载源: Fedora 官方稳定 channel `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`。
- 缓存: `~/Library/Application Support/HVM/cache/virtio-win/virtio-win.iso` (全局共享, 所有 Win VM 引用同一份, 不每个 VM 复制)。
- 就绪判定: 存在 + 大小 ≥ 100 MB sanity (实际 ~700 MB)。
- 下载: `ensureCached(progress:)` 前台 modal 进度, 先下到 `.partial` 完成后原子 rename。**不做断点续传** (一期; 700 MB 单次下载性价比低, 失败重下)。
- `purge()` 删缓存供重下 / 排错。

**当前默认禁用**: `QemuArgsBuilder` 里挂 virtio-win cdrom 的分支前有 `false &&` 短路, 且 `WindowsSpec.autoInstallVirtioWin` 默认 false。原因: UTM Guest Tools ISO 已内含 ARM64 native NetKVM/viostor/viogpudo + qemu-ga, 覆盖了 virtio-win.iso 该负责的功能。`virtioWinISOPath` 字段保留为 fallback 入口 (去掉 `false &&` 即恢复)。

### 4.6 UTM Guest Tools (`UtmGuestToolsCache`) — 默认启用

`HVMInstall/UtmGuestToolsCache.swift` 管理 UTM Guest Tools ISO 全局缓存 (~120 MB)。

- 下载源: getutm.app 官方 latest 直链 `https://getutm.app/downloads/utm-guest-tools-latest.iso` (`HVM_UTM_GUEST_TOOLS_URL` env 可覆盖, 用于内部镜像 / 离线分发)。
- 缓存: `~/Library/Application Support/HVM/cache/utm-guest-tools/utm-guest-tools.iso` (全局共享, normalize 成无版本号文件名, 升级直接覆盖)。
- 就绪判定: 存在 + 大小 ≥ 50 MB sanity (实际 ~120 MB)。
- 下载: `ensureCached(progress:)` 前台进度, 先下 `.partial` 后原子 rename; 首次访问触发一次 legacy 路径 (`cache/spice-tools/utm-guest-tools.iso`) lazy 迁移。
- 失败策略: fail-soft, VM 仍能启动 — 只是 Windows guest 拖窗口不 dynamic resize; Linux guest 不受影响 (kernel 自带 virtio-gpu 驱动)。

**为何用 UTM Guest Tools 而非 stock spice-guest-tools** (CLAUDE.md「参考实现: UTM」): stock `spice-guest-tools.exe` (spice-space.org) 只有 x86 binary, ARM Win 跑 x86 emu vdagent 调 `D3DKMTEscape` 走不通, 且它装的 stock viogpudo 没实现 QXL escape `SET_CUSTOM_DISPLAY`。UTM Guest Tools 含 ARM64 native `spice-vdagent.exe` + utmapp 自家 `viogpudo.sys`, 完整跑通 dynamic resize 链路。

### 4.7 启动时挂载的 cdrom (装机期)

`QemuArgsBuilder` 给 Windows 装机期 (`!bootFromDiskOnly`) 挂多个 cdrom, **全走 usb-storage** (Win11 EFI bootloader 实测要 USB 路径; virtio-cdrom 在 BdsDxe loading 后 hang 不进 wpe.wim):

- 安装 ISO: `usb-storage` cdrom, `bootindex=0` (优先 boot)。
- unattend ISO: `usb-storage` 第二 cdrom (Win Setup 自动扫所有移动介质找 `Autounattend.xml`)。
- virtio-win ISO: 默认禁用 (见 4.5)。
- UTM Guest Tools ISO: `usb-storage` 第四 cdrom (`autoInstallSpiceTools` 且缓存就绪时挂)。

阶段 3 (驱动已装完, `bootFromDiskOnly && windowsDriversInstalled`): 卸掉 unattend / UTM Guest Tools cdrom (OS 已自给)。

### 4.8 Windows GPU 三态切换

`QemuArgsBuilder` 按 `(bootFromDiskOnly, windowsDriversInstalled)` 切 GPU 设备:

- **阶段 1 装机** (`!bootFromDiskOnly`): `-device ramfb` 单挂。WinPE / Setup 走 BDD 软件画法直接画进 ramfb buffer。
- **阶段 2 待装驱动** (`bootFromDiskOnly && !windowsDriversInstalled`): 仍 `-device ramfb`。OS 端只 enumerate 出「Microsoft Basic Display」, BDD 路径必须 ramfb 兜底。
- **阶段 3 运行** (`bootFromDiskOnly && windowsDriversInstalled`): `-device hvm-gpu-ramfb-pci` (`patches/qemu/0003` 自家融合设备)。boot 期走 ramfb 兼容 EDK2/bootmgfw, OS 期 viogpudo.sys 绑 PCI `1AF4:1050` 切到 virtio-gpu 路径做 dynamic resize。

### 4.9 HVM Guest Helper (`GuestHelperInstaller`)

`HVMDisplayQemu/GuestHelperInstaller.swift` 在 Windows VM 启动 + QGA 就绪后, 把 HVM 自家 guest helper EXE 推进 guest 自动安装。这是与 UTM Guest Tools 不同的另一套 helper, 负责 host↔guest **文件剪贴板** (Cmd+V 文件粘贴等) 通路。

流程 (`install(qgaSocketPath:)`, async):
1. 等 QGA 在 guest 内 ready (qemu-ga.exe Windows service boot 后 30-60s 才起, cheap ping 探测 + 指数退避, 最多 10 min)。
2. 检测 marker `C:\ProgramData\HVM\.helper-installed-v2`; 已装 → 跳过 (幂等)。顺便清老 v1 marker + Run reg key (v1→v2 升级路径)。
3. mkdir `C:\HVMGuestHelper\`。
4. QGA push `hvm-guest-helper.exe` (+ `libunwind.dll`, helper 用 llvm-mingw 链 LLVM unwinder, 缺 DLL 会静默 abort) 到该目录。
5. 注册持久 schtasks `ONLOGON` 任务 (`/RL HIGHEST`, virtio-serial port ACL 拒普通 user 需 admin token; 取代老的 Run reg key)。
6. 写 marker。
7. `schtasks /run` 立即拉起 (one-shot)。失败不算 fatal — 下次 user 登录走 ONLOGON 自动起。

EXE 来源: `HVM.app/Contents/Resources/GuestHelper/hvm-guest-helper.exe` (`locateBundledExe`); 找不到 → nil (Linux/packaging 缺时), helper 不算 VM 启动失败 — 只是文件剪贴板不可用, 其他功能正常。升级路径: marker 文件名带 version, 改名即自动重装。

### 4.10 Windows 装机完整流程

1. 准备: 自备 Win11 ARM64 ISO (custom 下载或本地路径); 创建向导前台触发 `UtmGuestToolsCache.ensureCached` 下载 UTM Guest Tools。
2. 创建 VM: `hvm-cli create --os windows ...` 或 GUI 选 Windows (标注实验性), 挂 `WindowsSpec` 默认值。
3. 首次启动 (阶段 1, `!bootFromDiskOnly`):
   - swtpm 先起, QEMU 接 TPM device。
   - patched EDK2 firmware (双 pflash) boot。
   - 安装 ISO + unattend ISO (+ UTM Guest Tools ISO) 走 usb-storage 挂载, `bootindex=0`。
   - GPU 用 ramfb。带 `-no-reboot`。
   - WinPE 读 `Autounattend.xml` → windowsPE pass 跑 LabConfig Bypass*Check 跳硬件检查 → Setup 装到主盘。
4. 装完后点 [安装完成] → `bootFromDiskOnly=true` + `windowsDriversInstalled=false` (进阶段 2)。cold start, 仍 ramfb。
5. guest 内 OOBE 首登: FirstLogonCommands 自动跑 UTM Guest Tools 静默装 (vdagent + viogpudo + qemu-ga); QGA 就绪后 host 侧 `GuestHelperInstaller` 推 HVM Guest Helper。
6. 驱动装完后点 [驱动安装完成] → `windowsDriversInstalled=true` (进阶段 3)。cold start, GPU 切 `hvm-gpu-ramfb-pci`, viogpudo 接管做 dynamic resize, 卸掉安装期辅助 cdrom。

---

## 5. Boot 流程

### 5.1 Windows boot 链

`patched EDK2 (BdsDxe)` → `bootmgfw` (Win Boot Manager) → `wpe.wim` (WinPE) → Setup UI / 已装系统。

装机期安装 ISO `bootindex=0` 让 firmware 优先从 USB cdrom boot; `Press any key to boot from CD or DVD` 提示后进 wpe.wim。

**timing 上限 20s** (CLAUDE.md「Boot / 装机 timing 上限」): boot 到 Setup/desktop 渲染不超过 20s。任何状态卡同一帧超 20s 默认判失败 (bootmgfw / wpe.wim 加载卡死), 立即查 host log + qemu-stderr + console serial, 不要傻等。

### 5.2 boot 阶段分类 (`BootPhaseClassifier`)

`HVMDisplayQemu/BootPhaseClassifier.swift` 给上层 (截屏 + OCR 后) 做粗分类, 返回 `(phase, confidence)`:

- phase 取值: `bios` / `boot-logo` / `ready-tty` / `ready-gui` / `unknown`。
- 按 guestOS 用不同字符行命中规则 (登录提示符 → `ready-tty` 等)。
- 仅辅助诊断, **不**驱动装机状态机 (后者靠 config 字段, 见 2.3)。

### 5.3 `bootFromDiskOnly` 切换

- false → true: 由用户在 GUI 点 [安装完成] (或 `hvm-cli boot-from-disk`) 触发。装机阶段带 `-no-reboot` 让 installer reboot 时 QEMU 退出, 给用户决策点; 切 true 后 cold start 不再挂 ISO、不带 `-no-reboot`, 直接 boot 主硬盘。
- Linux / Windows 同语义 (Windows 多一个 `windowsDriversInstalled` 三态字段)。
- guest 内 OOBE / 装驱动重启走 `system_reset` (阶段 2/3 不带 `-no-reboot`, host 子进程不退)。

---

## 6. 缓存目录速查

| 内容 | 路径 (`HVMPaths`) | 来源 |
|------|-------------------|------|
| Linux ISO | `cache/os-images/<family>/` | `OSImageFetcher` (catalog / custom) |
| virtio-win.iso (~700 MB) | `cache/virtio-win/virtio-win.iso` | `VirtioWinCache` (默认禁用) |
| UTM Guest Tools (~120 MB) | `cache/utm-guest-tools/utm-guest-tools.iso` | `UtmGuestToolsCache` (默认启用) |

`~` = `~/Library/Application Support/HVM/`。ISO 文件 **不**进 `.hvmz` bundle (只存绝对路径于 config)。

---

## 7. 引用源文件

- `app/Sources/HVMInstall/OSImageCatalog.swift` — Linux 内建发行版目录 + family 枚举
- `app/Sources/HVMInstall/OSImageFetcher.swift` — ISO 下载 + 断点续传 + SHA256 校验 + 缓存
- `app/Sources/HVMInstall/VirtioWinCache.swift` — virtio-win.iso 缓存 (默认禁用)
- `app/Sources/HVMInstall/UtmGuestToolsCache.swift` — UTM Guest Tools ISO 缓存 (默认启用)
- `app/Sources/HVMInstall/InstallProgress.swift` — (残留) macOS 装机进度枚举, 当前装机通路不再使用
- `app/Sources/HVMStorage/ISOValidator.swift` — ISO 存在性 + 大小区间校验
- `app/Sources/HVMQemu/WindowsUnattend.swift` — AutoUnattend.xml 生成 + hdiutil makehybrid 打 ISO
- `app/Sources/HVMQemu/QemuArgsBuilder.swift` — firmware / win11-lowram / swtpm / cdrom / GPU 三态 argv
- `app/Sources/HVMDisplayQemu/GuestHelperInstaller.swift` — Windows HVM Guest Helper (文件剪贴板) 自动装
- `app/Sources/HVMDisplayQemu/BootPhaseClassifier.swift` — boot 阶段粗分类 (诊断辅助)
- `app/Sources/HVM/QemuHostEntry.swift` — 装机 orchestration (swtpm / unattend / 下载触发 / GuestHelper)
- `app/Sources/HVM/GUI/Layout/DetailBootSection.swift` — 详情页 ISO & 启动 section, 两态/三态推进按钮
- `app/Sources/HVMBundle/VMConfig.swift` — `GuestOSType` / `WindowsSpec` / `bootFromDiskOnly` / `windowsDriversInstalled` 字段
- `app/Sources/hvm-cli/Commands/OsImageCommand.swift` — `hvm-cli osimage` 下载 / 缓存 CLI
- `app/Sources/hvm-cli/Commands/CreateCommand.swift` — `hvm-cli create --os linux|windows`
- 配套 patch: `patches/qemu/0001-hvm-win11-lowram.patch` + `patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch` (win11-lowram); `patches/qemu/0003-hw-display-hvm-gpu-ramfb-pci.patch` (GPU 三态融合设备)
