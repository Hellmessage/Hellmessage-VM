# QEMU / EDK2 / swtpm 集成与随包分发

> 现状文档 — 描述当前代码与构建脚本的实际行为。基于:
> `scripts/qemu-build.sh` / `scripts/edk2-build.sh` / `scripts/bundle.sh`、
> `patches/qemu/*` / `patches/edk2/*`、
> `app/Sources/HVMQemu/QemuPaths.swift` / `QemuArgsBuilder.swift`、
> `app/Resources/QEMU.entitlements`、CLAUDE.md「QEMU 后端约束」+「第三方二进制约束」。
>
> 约束变更必须同步本文 + CLAUDE.md。本文不写设计选型讨论 (那在 `docs/v4/QEMU_ONLY_PIVOT.md`),
> 只记"当前是什么样、为什么这么定"。

HVM 走 **QEMU 后端单一路线**: `qemu-system-aarch64` + HVF 加速 + 自家 HDP iosurface 显示。
QEMU 是唯一后端, 承载 **Linux arm64** + **Windows arm64** 两类 guest。本文讲清楚从上游源码到
随 `.app` 分发的整条链路。

---

## 1. 架构限定与版本锁定

### 1.1 架构限定: 仅 aarch64

- 只编 `qemu-system-aarch64` 一个 target (`--target-list=aarch64-softmmu`)。
- host = Apple Silicon (arm64), guest = AArch64, 走 **HVF** (Apple Hypervisor.framework) 硬件加速。
- **不打包** `qemu-system-x86_64` / `qemu-system-riscv64` 等其他架构, **不做 TCG 翻译**。
  用户要 x86_64 / riscv64 guest → 能力边界, 直接拒绝 (CLAUDE.md「能力边界约束」)。
- macOS guest 不支持 (QEMU 无 Apple Silicon macOS 虚拟化授权路径)。

### 1.2 版本锁定

| 组件 | tag | 锁定位置 |
|------|-----|----------|
| QEMU | `v10.2.0` | `scripts/qemu-build.sh` 顶部 `QEMU_TAG` |
| EDK2 | `edk2-stable202408` | `scripts/edk2-build.sh` 顶部 `EDK2_TAG` |
| swtpm / libtpms | brew 锁版本 | `scripts/qemu-build.sh` `BREW_PACKAGES` |

升级任一组件: **同步改 tag → 重跑 build → 重 commit**。两脚本顶部注释都标了"修改必须同步 CLAUDE.md"。

源码仓库:
- QEMU: `https://gitlab.com/qemu-project/qemu.git`
- EDK2: `https://github.com/tianocore/edk2.git`

### 1.3 为什么 EDK2 用 stable202408 不用 202508

`stable202408` 的 `PlatformBootManagerLibLight` 仍保留"**无 NV BootOrder 时自动 boot first device**"行为
(跟 QEMU 自带 kraxel firmware 一致)。这正是装机所需 — 新 VM 没有持久化的 BootOrder, 必须能自动从
ISO 引导。

`stable202508` 上游改了 Light 库行为: 无 BootOrder 时落 **EFI Shell**, 不再自动 boot first device。
切到 202508 必须额外打 patch 把 `PlatformBootManagerLibLight` 替换成 full 版才能装机。为避免这块额外
维护成本, 当前锁死 `stable202408`。

---

## 2. configure 固定参数

`scripts/qemu-build.sh` 的 `build_qemu()` 用固定 configure 参数 (改动需同步 CLAUDE.md + MANIFEST):

```
../configure \
    --prefix="$STAGING_DIR" \
    --target-list=aarch64-softmmu \
    --enable-cocoa \
    --enable-hvf \
    --enable-iosurface \
    --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-curses \
    --disable-debug-info --disable-werror --disable-fuse --disable-spice \
    --disable-libssh --disable-curl --disable-libnfs --disable-libiscsi \
    --disable-rbd --disable-glusterfs --disable-rdma
```

关键三个 `--enable`:

- **`--enable-hvf`** — Apple Hypervisor.framework 加速。aarch64-on-aarch64 必需, argv 里 `-accel hvf`
  不允许 fallback 到 TCG。
- **`--enable-iosurface`** — **HVM 自家 patch 0002 引入**的 macOS-only display backend
  (`-display iosurface,socket=...`)。生产显示通路走它 (HDP 协议, IOSurface 嵌入主窗口零拷贝)。
  configure 能识别这个 option 依赖 patch 0002 同时 patch 了 `scripts/meson-buildoptions.sh`
  (该 `.sh` 由 `meson-buildoptions.py` 从 `meson_options.txt` 派生, 不打进 patch 则 configure
  报 unknown option)。
- **`--enable-cocoa`** — 保留作 fallback / 调试后端 (自开独立 `NSWindow`)。生产路径由 HVM 主进程
  argv 选 `iosurface`, cocoa 仅在没注入 iosurface socket 时兜底。

`--disable-*` 一串都是 Win/Linux arm64 guest 用不到的远程块后端 / 显示后端, 关掉缩短编译时间、缩小
产物、避免环境探测带来的脆弱性。其中:
- `--disable-fuse` — macFUSE 头文件与 QEMU `fuse.c` 不兼容; 我们也不需要把镜像导出成 FUSE 文件系统。
- `--disable-spice` — **不链 libspice-server**。vdagent / webdav / clipboard 全是 HVM 主进程内自实现的
  single-client 模式 (连 QEMU 的 chardev `server=on` socket), QEMU 不打 spice patch。

---

## 3. 补丁串行管理

### 3.1 规则

- QEMU 补丁放 `patches/qemu/*.patch`, 顺序由 `patches/qemu/series` 决定。
- EDK2 补丁放 `patches/edk2/*.patch`, 顺序由 `patches/edk2/series` 决定。
- `series` 文件: 一行一个文件名, `#` 开头注释, 空行忽略。
- 应用方式: `git apply --check` 后 `git apply` (`apply_patches()`)。任一 patch apply 失败立即中断,
  **禁止用 `--reject` / `--3way` 救场, 必须 rebase**。
- **禁止 fork 上游仓库** — 避免 rebase 黑盒。源码每次 `git reset --hard <tag>` + `clean -fdx` 回干净态再 apply。

### 3.2 QEMU 三个 patch

| patch | 作用 |
|-------|------|
| `0001-hvm-win11-lowram.patch` | opt-in 16MB RAM 孔 |
| `0002-ui-iosurface-display-backend.patch` | HDP iosurface display backend |
| `0003-hw-display-hvm-gpu-ramfb-pci.patch` | hvm-gpu-ramfb-pci 混合显示设备 |

**0001 — Win11 lowram**
QEMU 加 opt-in `-machine virt,hvm-win11-lowram=on`: 在 `0x10000000` (PCIe MMIO 头部) 让出 16MB
挂一块 RAM 孔, 给 Win11 ARM64 `bootmgfw.efi` 用 (它在该地址做 `ConvertPages`)。
改 `hw/arm/virt.c` (新增 `VIRT_HVM_WIN11_LOWRAM` memmap 项, 默认 size=0) + `hw/arm/boot.c`
(`extra_ram_size > 0` 时往 DTB 写额外 `/memory` 节点)。默认 `size=0` 不挂, 行为与 stock QEMU 完全一致。
**必须配套 EDK2 patch 0001** — 单打这个、配 stock EDK2 会因看到额外 `/memory` 节点而 ASSERT 挂死。

**0002 — iosurface display backend**
新增 `-display iosurface,socket=<path>`: AF_UNIX SOCK_STREAM + POSIX shm + SCM_RIGHTS 把 framebuffer
的 IOSurface fd 传给 HVM 主进程, 实现零拷贝嵌入显示。协议规范 = **HDP (HVM Display Protocol) v1.0.0**,
canonical 文档 `docs/QEMU_DISPLAY_PROTOCOL.md`, C 侧镜像头 `include/ui/hvm_display_proto.h`
(8 字节小端 header)。同时 patch `scripts/meson-buildoptions.sh` 让 configure 识别 `--enable-iosurface`。

**0003 — hvm-gpu-ramfb-pci 混合设备**
新 PCI 设备 `hvm-gpu-ramfb-pci` (套版 `hw/display/virtio-vga.c`, 把 VGA 路径换成 ramfb), 单设备
同时挂 **ramfb** (UEFI/bootmgfw GOP 兼容) + **virtio-gpu-pci** (OS 期 dynamic resize):
- boot 期 (`g->enable == 0`) 走 `ramfb_display_update` → `dpy_gfx_replace_surface`, 兼容 EDK2 GOP /
  `bootmgfw.efi`。
- OS 期 (`g->enable == 1`, guest virtio-gpu driver 装好、第一条 `SET_SCANOUT` 到达) 走 virtio-gpu
  cmd handler 自己的 `dpy_gfx_update`, 做动态分辨率。
- `reset_hold` hook 把 `g->enable` 拉回 0 + `ramfb_resend_surface`, 防 virtio-gpu reset_bh 把 console
  顶成 "Display output is not active." placeholder。
- vendor/device id 复用 `0x1AF4/0x1050` (Red Hat virtio-gpu), 让 Windows 端 `viogpudo.inf` 自动 match,
  不需要改 guest driver。

Windows guest argv 三态切换 (见 §7.2)。

### 3.3 EDK2 一个 patch

`0001-armvirt-extra-ram-region-for-win11.patch`:
ArmVirtPkg 改两点配合 QEMU patch 0001 —
1. 按 `PcdSystemMemoryBase` 选主 RAM (而非取最低地址), 把额外 `/memory` 节点收集到 `gHvmExtraMemoryGuid`
   GUID HOB;
2. `MemoryPeim` 把额外区注册成 `EFI_RESOURCE_SYSTEM_MEMORY` + 加 MMU 页表。

否则 Win11 `bootmgfw` 在 `0x10000000` 调 `ConvertPages` 会因 GCD 不识别该地址而失败。
**这两个 patch (QEMU 0001 + EDK2 0001) 必须成对启用。**

---

## 4. 产物路径与双 firmware 策略

### 4.1 产物路径 (全部仓库 ignore)

| 路径 | 内容 |
|------|------|
| `third_party/qemu-src/` | QEMU v10.2.0 git clone 源码 (~900M) |
| `third_party/qemu-stage/` | configure `--prefix` 输出 + 裁剪 + 嵌 swtpm + 嵌 dylib + 清 xattr + LICENSE/MANIFEST 后的最终成品 (~180M)。**bundle.sh 直接从这里拷进 .app**, 无中间 vendor 层 |
| `third_party/edk2-src/` | edk2-stable202408 git clone 源码 (含 submodules, ~700M) |
| `third_party/edk2-stage/` | EDK2 编译 + padding 到 64MB 的 `edk2-aarch64-code.fd` (Win11 patched) + `edk2-aarch64-vars.fd` + MANIFEST |

`qemu-stage` 的目录结构 (拷进 `.app/Contents/Resources/QEMU/` 时保持):
```
bin/    qemu-system-aarch64 / qemu-img / qemu-storage-daemon / qemu-nbd / qemu-io / qemu-edid / swtpm
lib/    全部非系统依赖 dylib (重定向后)
share/qemu/  edk2-aarch64-code.fd / edk2-aarch64-code-win11.fd / edk2-aarch64-vars.fd / efi-virtio.rom / keymaps / ...
LICENSE / LICENSE.LGPL / MANIFEST.json
```

### 4.2 裁剪 share

`prune_share()` 删掉非 aarch64 的固件 / ROM / 设备树 (PowerPC slof/skiboot、SPARC、RISC-V opensbi、
s390、LoongArch、x86 vgabios/bios/linuxboot 等), 把 `share/qemu` 从 ~250MB 缩到 ~4MB。
NIC boot ROM 只保留 `efi-virtio.rom` (virtio-net-pci 必需), 删 e1000/rtl8139/ne2k 等 x86 模拟 NIC ROM。

### 4.3 双 firmware 策略

UEFI 固件分两套, 因为 Linux 与 Windows 对固件要求不同:

- **Linux** → `share/qemu/edk2-aarch64-code.fd`
  = QEMU `make install` 自带的 **kraxel build** (来自 `pc-bios/edk2-aarch64-code.fd.bz2`, 跟 brew QEMU 同源)。
  `fetch_edk2_firmware()` 只校验存在 + 大小 + padding 到 64MB, 不替换。跟 Ubuntu / Linux arm64 ISO 实战兼容。
  argv: 单 `-bios <code.fd>`。

- **Windows** → `share/qemu/edk2-aarch64-code-win11.fd`
  = `scripts/edk2-build.sh` **自家 build** (clone edk2-stable202408 → apply EDK2 patch 0001 →
  cross compile `ArmVirtPkg/ArmVirtQemu.dsc -a AARCH64 -t GCC5 -b RELEASE` via brew `aarch64-elf-gcc`)。
  qemu-build.sh 把 `third_party/edk2-stage/edk2-aarch64-code.fd` 拷成 `edk2-aarch64-code-win11.fd`。
  必须用这个 patched 版才能装 Win11 (含 extra-RAM-region patch)。
  argv: 双 pflash (RO code + RW vars)。
  **fail-soft**: 没跑 `make edk2` 时这步只 warn 跳过, `make build` 仍出 `.app`, 但 Win11 VM 启动会报缺 firmware。

- **vars 模板** → `share/qemu/edk2-aarch64-vars.fd`
  QEMU 不带 64-bit vars, 用自带的 32-bit `edk2-arm-vars.fd` (空 vars 通用), padding 到 64MB。
  创建 Win VM 时拷贝到 `<bundle>/nvram/efi-vars.fd` 作 RW NVRAM。

> QEMU virt 机器的 pflash device 固定 64MB, 所有 `.fd` 都用 python `truncate` padding 到 64MB,
> 否则启动报 "device requires 67108864 bytes ... provides X bytes"。

---

## 5. 零依赖: dylib bundle + swtpm 嵌入

**硬约束**: 最终用户机器零运行时依赖, 所有运行时产物随 `.app` 包内分发 (socket_vmnet 除外, 见 §6)。

### 5.1 为什么必须 bundle dylib

主 qemu 二进制 (`qemu-system-aarch64` / `qemu-img` / `qemu-storage-daemon` / `qemu-nbd` / `qemu-io` /
`qemu-edid`) 与 swtpm 都链 brew 的 `libcapstone` / `libgnutls` / `libpixman` / `libglib` / `libslirp` /
`libzstd` / `libtpms` 等。不 bundle 的后果:

1. 偷偷依赖 host homebrew (违反零依赖);
2. 加固运行时 (`flags=runtime`) 的库校验会拒绝加载非同 team 的 ad-hoc dylib — homebrew 升级重签
   dylib 后, QEMU 一起来就 `signal 9` / `signal 6` 崩。**历史教训 (2026-05-30)**: brew 升级 capstone
   后整个 VM 启动链断。

### 5.2 嵌入流程

两个函数 (`bundle_swtpm()` 处理 swtpm, `bundle_qemu_dylibs()` 处理 6 个主 qemu 二进制), 共用递归
helper `bundle_dylib_deps()`:

1. `cp` brew 二进制 / dylib 进 `stage/{bin,lib}`, `chmod u+w`;
2. `codesign --remove-signature` 去掉 brew 的 ad-hoc 签名 (否则 `install_name_tool` 被 codesign
   integrity 拦);
3. BFS 递归收集所有非系统 dylib 引用 (跳过 `/usr/lib` `/System` `@executable_path`/`@rpath`/`@loader_path`),
   逐个拷进 `lib/`;
4. `install_name_tool -id @executable_path/../lib/<name>` 改自身 install name;
5. `install_name_tool -change <brew绝对路径> @executable_path/../lib/<name>` 改引用方;
6. 用 tmpfile 当 "已处理" set 防重复 / cycle, 多二进制共用的 dylib (glib 等) 只拷一次。

校验: `otool -L qemu-system-aarch64` 不应再含 `/opt/homebrew` / `/usr/local`, 有残留即打包不完整。

> 实现细节坑: `bundle_dylib_deps` 用 process substitution + 数组而非 `cmd | while read` pipeline —
> 后者尾段在 subshell, 嵌套递归时 `install_name_tool` 看似执行实际不生效。

### 5.3 swtpm / libtpms

swtpm + libtpms 由 brew 锁版本 (Win11 TPM 2.0 必需), `bundle_swtpm()` 把 `swtpm` 拷进
`stage/bin/swtpm` 并递归重定向 dylib (`libtpms` 等)。argv 里 Windows + `tpmEnabled` 时挂
`-chardev socket,id=chartpm` + `-tpmdev emulator` + `-device tpm-tis-device`, swtpm daemon 由
host 端 `SwtpmRunner` 先启起。

### 5.4 --relocate-dylibs 快速修复

`bash scripts/qemu-build.sh --relocate-dylibs` 只对现有 `third_party/qemu-stage` 重做 dylib 嵌入
(不全量重编 qemu), 给 "homebrew 升级后 dylib 失效" 快速修复。之后 `make build` 重签。
(Makefile `BUNDLE_STAMP` 依赖 `$(QEMU_BIN)`, re-stage 后 `make build` 自动重 bundle。)

---

## 6. 运行时只走 .app 包内

### 6.1 路径解析 (`QemuPaths.swift`)

`QemuPaths.resolveRoot()` 探测顺序, **严格只走 .app 包内, 不 fallback 到 brew / third_party**:

1. 环境变量 `HVM_QEMU_ROOT` (CI / 调试显式覆盖, 对所有自动探测优先);
2. `Bundle.main/Contents/Resources/QEMU`
   - dev: `open build/HVM.app` → `Bundle.main = build/HVM.app`
   - prod: `open /Applications/HVM.app` → `Bundle.main = /Applications/HVM.app`

派生路径 (都基于 `resolveRoot()`):
- `qemuBinary()` → `bin/qemu-system-aarch64`
- `qemuImgBinary()` → `bin/qemu-img` (创建 / 扩容 qcow2 必经)
- `edk2Firmware()` → `share/qemu/edk2-aarch64-code.fd`
- `shareDir()` → `share/qemu` (argv `-L` 选项)

**严禁** fallback 到 `/opt/homebrew/*` / `/usr/local/*` / `third_party/qemu-stage/*`。仅允许 env
override (`HVM_QEMU_ROOT` / `HVM_SWTPM_PATH` / `HVM_APP_PATH`) 给 CI 与调试。
`socket_vmnet` 是唯一例外 (本来就由 brew 提供, 不入 `.app`)。

> **包内二进制 / 脚本变更必须 `make install`**: `make build` 只更新 `build/HVM.app`, 用户实际跑的
> `/Applications/HVM.app` 仍是旧版。改完 `third_party/qemu-stage/*` 或被 bundle.sh 拷入 .app 的内容,
> 必须 `make install` 同步。

### 6.2 socket_vmnet 不入包

vmnet 网络走系统级 `socket_vmnet` launchd daemon, **二进制不打包入 .app**: 用户机器自行
`brew install socket_vmnet`, `scripts/install-vmnet-daemons.sh` 从 brew 路径写 launchd plist。
QEMU argv 直接 `-netdev stream,addr.type=unix,addr.path=<sock>,reconnect-ms=2000` 连 daemon
(4-byte length-prefix framing 与 QEMU stream 协议兼容)。详见 CLAUDE.md「socket_vmnet 网络约束」。

### 6.3 GPL 合规 (MANIFEST + LICENSE)

`write_manifest()` 在 stage 写:
- `MANIFEST.json` — 记录 `qemu_tag` / `qemu_commit` (上游 HEAD SHA) / `qemu_repo` / `build_time_utc` /
  `host_arch` / `build_options` / `patches` (series 中实际生效列表) / `edk2_firmware_source`。
- `LICENSE` (= QEMU `COPYING`, GPLv2) + `LICENSE.LGPL` (= `COPYING.LIB`)。

EDK2 stage 同样写 MANIFEST (`edk2_tag` / `edk2_commit` / patches) + `LICENSE` (EDK2 `License.txt`)。

合规闭环: 上游 commit SHA + tag + license 全文随包分发, HVM 自身源码 (含 patches/) GitHub 公开,
即满足 "对应版本源码可获取"。

### 6.4 签名闭环

`scripts/bundle.sh` 由内向外逐文件 codesign (dylib → libexec → bin):
- `Resources/QEMU/bin/*` 与 `Resources/QEMU/lib/*.dylib` 逐文件签名。
- QEMU 子进程用**独立** entitlement `app/Resources/QEMU.entitlements` (仅含
  `com.apple.security.hypervisor`, HVF 必需), **不**与 HVM 主进程 entitlement 共用。
- 用 Apple Development 证书时加 `--options runtime` (加固运行时), 这正是 §5.1 dylib 必须同包签名的原因。
- 整包再 `codesign --deep` 包裹。

---

## 7. 进程模型与 argv 概览

### 7.1 进程模型

- HVM 主进程通过 `Process` 启动包内 `qemu-system-aarch64`, **不链接 libqemu**。
- QMP 控制 socket 仅监听 **unix domain socket** (`-qmp unix:<path>,server=on,wait=off`),
  **严禁 TCP 监听**。
- `argv` 由 `QemuArgsBuilder.build(_ inputs:)` 纯函数构造 (不做 IO, 路径 / socket 全由调用方注入)。
- Bundle 互斥: 单 `.hvmz` 单进程 (fcntl flock)。

### 7.2 argv 概览 (`QemuArgsBuilder.swift`)

输出顺序固定 (便于测试 + 排错)。主要段落:

- **机器 + 加速器**: `-machine virt,gic-version=3` (Windows + `HVM_QEMU_WIN11_LOWRAM=1` 时追加
  `,hvm-win11-lowram=on`) / `-cpu host` / `-accel hvf` (不允许 fallback TCG)。
- **资源**: `-smp` / `-m <MiB>M` / `-name` / 可选 `-pidfile` (orphan reaper 锚点)。
- **装机控制**: 非 `bootFromDiskOnly` 时加 `-no-reboot` (装机 reboot 让 QEMU 退出给用户决策点);
  `-monitor none` (只走 QMP)。
- **serial console**: `-chardev socket,id=cons0,...server=on,wait=off` + `-serial chardev:cons0`
  (host 端 `QemuConsoleBridge` 作 client)。
- **UEFI firmware** (双 firmware 策略, §4.3):
  - Linux: `-bios <stock edk2-aarch64-code.fd>`。
  - Windows: 双 pflash, RO `edk2-aarch64-code-win11.fd` + RW nvram (明文 raw `efi-vars.fd`, 或加密
    qemuPerfile 时 LUKS qcow2 + `secret` object)。
  - `-L share/qemu` 找 keymap / firmware descriptor。
- **磁盘** (总线按 guestOS 分流, format 直接读 `disk.format` 不靠扩展名推断):
  - Windows: `-drive if=none` + `-device nvme` (Win11 ARM PE 内置 NVMe 驱动, 装机直接见盘)。
  - Linux: `-drive if=virtio` (内核 virtio-blk)。
  - 加密 qcow2 时一次性注入 `secret,id=sec_disk` + 每盘 `encrypt.format=luks,encrypt.key-secret=sec_disk`。
- **ISO / cdrom**:
  - Windows: usb-storage cdrom (`bootindex=0` 装机 ISO + unattend ISO + UTM Guest Tools ISO);
    需先 `-device qemu-xhci,id=xhci`。
  - Linux: `-drive ...,if=virtio,media=cdrom`。
- **PCIe root ports**: 预定义 4 个 `pcie-root-port` (NIC 挂上去走 PCIe native MSI-X, 避免 legacy
  bridge 高 frame rate 丢中断)。
- **网络**: `.user` → `-netdev user`; vmnet (`.vmnetShared/.vmnetHost/.vmnetBridged`) →
  `-netdev stream,addr.type=unix,addr.path=<sock>,reconnect-ms=2000` 连 socket_vmnet daemon
  (daemon 未就绪抛 `configInvalid` 引导去 GUI 装 daemon)。
- **显示** (三态切换):
  - Linux: `-device virtio-gpu-pci`。
  - Windows 阶段 1/2 (装机 / 装驱动): `-device ramfb` 单挂。
  - Windows 阶段 3 (`bootFromDiskOnly && windowsDriversInstalled`): `-device hvm-gpu-ramfb-pci`
    (patch 0003 融合设备, boot 走 ramfb / OS 走 virtio-gpu)。
  - `-display iosurface,socket=...` (注入 iosurface socket 时) 或回退 `-display cocoa`。
  - `-device usb-kbd` / `-device usb-tablet` (绝对坐标鼠标)。
- **virtio-serial 复用通道**: vdagent (`com.redhat.spice.0`) / qga (`org.qemu.guest_agent.0`) /
  webdav (`org.spice-space.webdav.0`) / hvm-clipboard (`com.hellmessage.hvm-clipboard.0`) 任一启用就
  加一条 `virtio-serial-pci,id=vsp0`, 各挂一个 `virtserialport` (chardev `server=on`, host 端各自作
  single-client 连入)。
- **QMP 控制**: `-qmp unix:<path>,server=on,wait=off` (control) + 可选第二条输入专用 QMP
  (`HVMDisplayQemu.InputForwarder` 用, 与 control 分离避免 accept 争抢)。
- **TPM** (Windows + `tpmEnabled` + 已启 swtpm): `-chardev socket,id=chartpm` + `-tpmdev emulator` +
  `-device tpm-tis-device`。

---

## 8. 构建命令速查

| 命令 | 行为 |
|------|------|
| `make qemu` (= `scripts/qemu-build.sh`) | 拉 QEMU 源 → apply patches → configure/build → 裁剪 → 嵌 swtpm + dylib → 写 MANIFEST/LICENSE → 落 `third_party/qemu-stage/` |
| `make edk2` (= `scripts/edk2-build.sh`) | 拉 EDK2 源 → apply patch → cross compile ArmVirtQemu AARCH64 RELEASE → pad 64MB → 落 `third_party/edk2-stage/` |
| `make build` | SwiftPM 编译 + `bundle.sh` 组装签名 `.app`。**不**编译 QEMU/EDK2; stage 不存在则跳过嵌入 (仍出 `.app`, 但不带 QEMU 后端) |
| `make build-all` | 完整发布: 先 `make edk2` + `make qemu` 再 `make build` |
| `make install` | 同步 `build/HVM.app` → `/Applications/HVM.app` (包内二进制 / 脚本变更后必跑) |
| `scripts/qemu-build.sh --relocate-dylibs` | 只对现有 stage 重做 dylib 嵌入 (homebrew 升级后快速修复) |

> `make qemu` / `make edk2` 仅打包者机器跑, 允许自动装 Homebrew + 一组锁定 brew 包 (仅用于编译源码)。
> 最终用户机器零依赖, 所有运行时产物随 `.app` 包内分发。
