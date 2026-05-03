# QEMU 集成 (随包分发)

## 产品范围 (已收敛)

- QEMU 后端**仅**承载 ARM64 guest: **Windows arm64 (强制 QEMU)** + **可选 Linux arm64** (双后端, 默认 VZ)
- 包内可执行只打 `qemu-system-aarch64` (Apple Silicon 宿主机 + AArch64 guest), 不打 x86_64 / riscv 等其他 `qemu-system-*` 目标 — 控体积、签名面、测试面
- 与 HVM 主路径关系: VZ 仍负责 macOS + Linux arm64 主路径; QEMU 覆盖 Windows arm64 (VZ 不承接, 没有 TPM) 与 Linux arm64 备用后端
- **首版优先级**: Linux arm64 通路先验证 (EDK2/HVF/iosurface 显示链路) → 再做 Windows arm64 (virtio-win 驱动 + swtpm + virtio-gpu 显示)

## 关键决策 (已锁)

| 项 | 决策 | 备注 |
|---|---|---|
| **QEMU 版本** | `v10.2.0` (2025-12) | HVF 路径稳定 + virtio-scsi 多队列; 升级必须同步改 `scripts/qemu-build.sh` 的 `QEMU_TAG` + 重 commit |
| **EDK2 版本** | `edk2-stable202408` | **不**用 stable202508 — 后者 `OvmfPkg/Library/PlatformBootManagerLibLight` 改了行为 (无 NV BootOrder 时落 EFI Shell, 不再自动 boot first device), 切到 202508 必须额外 patch 改用 PlatformBootManagerLib full 才能装机 |
| **产物来源** | 本地 / CI 编译落 `third_party/qemu-stage/` + `third_party/edk2-stage/`, 仓库 ignore | `make qemu` / `make edk2` 一键复现 |
| **Linux 后端** | VZ + QEMU 双后端: 默认 VZ, 高级模式可选 QEMU | Windows 强制 QEMU |
| **双 firmware 策略** | Linux 用 QEMU 自带 kraxel (`edk2-aarch64-code.fd`), Windows 用自家 patched build (`edk2-aarch64-code-win11.fd`) | 详见下「双 firmware」 |
| **vars 模板** | QEMU 自带 `edk2-arm-vars.fd` padding 到 64MB (空 vars 32/64-bit 通用) | 创建 Win VM 时拷贝到 `<bundle>/nvram/efi-vars.fd` |
| **virtio-win 驱动 ISO** | **不入包**, 首次创建 Win VM 按需下载到 `~/Library/Application Support/HVM/cache/virtio-win/` | 体积约 700MB |
| **TPM** | `swtpm` + `libtpms` brew 锁版本, swtpm 二进制 + 依赖 dylib 重定向打入 `Resources/QEMU/bin/swtpm` | Win11 TPM 2.0 必需 |
| **socket_vmnet** | **不入包**, 用户机器自行 `brew install socket_vmnet` | 详见 [NETWORK.md](NETWORK.md) |
| **补丁管理** | `patches/qemu/series` + `patches/edk2/series` 单文件 `.patch` | 任一 apply 失败立即中断, 禁止 fork 上游 |
| **GPL 合规** | LICENSE 全文 + commit SHA + tag 写入 `Resources/QEMU/MANIFEST.json` + `LICENSE` | HVM 仓库 GitHub 公开即满足"对应版本源码可获取" |

## 目录布局

```
third_party/                          — 全部 gitignored
├── qemu-src/                         — 上游 v10.2.0 git clone (~900M)
├── qemu-stage/                       — 编译 + 裁剪 + 嵌 swtpm + 清 xattr + LICENSE/MANIFEST 后成品 (~180M)
│   ├── bin/
│   │   ├── qemu-system-aarch64
│   │   ├── qemu-img
│   │   ├── swtpm                     — 由 qemu-build.sh `bundle_swtpm` 从 brew 拷入并 install_name_tool 重定向
│   │   └── ...
│   ├── share/qemu/
│   │   ├── edk2-aarch64-code.fd      — Linux 用 (QEMU 自带 kraxel)
│   │   ├── edk2-aarch64-code-win11.fd — Windows 用 (自家 build, 由 edk2-stage 拷入)
│   │   └── edk2-aarch64-vars.fd      — vars 模板 (padding 到 64MB)
│   ├── libexec/                      — qemu-bridge-helper 等
│   ├── lib/                          — swtpm 依赖的 libtpms 等 dylib (install_name_tool 重写到 @rpath)
│   ├── LICENSE / LICENSE.LGPL
│   └── MANIFEST.json                 — qemu_tag / qemu_commit / edk2_tag / edk2_commit / configure 选项
├── edk2-src/                         — 上游 edk2-stable202408 git clone (含 submodules, ~700M)
└── edk2-stage/                       — patched + RELEASE GCC AARCH64 build + padding 到 64MB
    └── edk2-aarch64-code.fd          — Win11 patched code firmware (拷贝到 qemu-stage/share/qemu/edk2-aarch64-code-win11.fd)
```

`scripts/bundle.sh` 直接从 `third_party/qemu-stage` 拷至 `HVM.app/Contents/Resources/QEMU/`, **不再有中间 `third_party/qemu/` vendor 层** (老路径已废弃)。

## 双 firmware 策略

历史:
- 早期: Linaro releases (仅发 `QEMU_EFI.fd` 不发 `QEMU_VARS.fd`) — 弃用
- 中期: retrage edk2-nightly RELEASE build — 实测 v10.2.0 与 Ubuntu 24.04.4 arm64 ISO 不兼容 (EDK2 splash 后不试 boot device, 卡 "Start boot option") — 弃用

当前:
- **Linux** 用 **QEMU 自带 kraxel build** (`pc-bios/edk2-aarch64-code.fd.bz2`, v10.2.0 源码 tarball 自带, `make install` 后落 `share/qemu/edk2-aarch64-code.fd`); 跟 brew QEMU 同源, 与 Ubuntu / Win11 arm64 ISO 实战兼容
- **Windows** 用 **自家 build** (`scripts/edk2-build.sh`): clone `edk2-stable202408` + apply `patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch` + cross compile RELEASE GCC AARCH64 (via brew `aarch64-elf-gcc`); 落 `third_party/edk2-stage/edk2-aarch64-code.fd`; `qemu-build.sh` 拷至 `share/qemu/edk2-aarch64-code-win11.fd`
- **vars 模板** 用 **QEMU 自带 32-bit `edk2-arm-vars.fd`** padding 到 64MB (空 vars 32/64-bit 通用; 与 hell-vm / lima 同 hack); 创建 Win VM 时拷贝到 `<bundle>/nvram/efi-vars.fd` 作 SecureBoot NVRAM 持久层

QEMU virt 机器 pflash device 固定 64MB, 必须 padding 否则启动报 `device requires 67108864 bytes`。

## 补丁串行管理

`patches/qemu/series` 与 `patches/edk2/series` 一行一个补丁文件名, `#` 注释, 空行忽略。任一 patch `git apply --check` 失败 → `qemu-build.sh` / `edk2-build.sh` 立即中断, **禁止 `--reject` / `--3way` / `--ignore-whitespace`**。

每个 patch 由 `git format-patch` 产出, 必须含 `Subject:` + 正文 `Why:` 段说明动机。跨大版本升级时 rebase 全部补丁; 上游已合并的从 series 删除。**禁止 fork 上游仓库** (rebase 黑盒, 难审查)。

### patches/qemu (3 个)

| 序号 | 文件 | 用途 |
|---|---|---|
| 0001 | `0001-hvm-win11-lowram.patch` | opt-in `-machine virt,hvm-win11-lowram=on` 在 0x10000000 挂 16MB RAM 孔, Win11 ARM64 bootmgfw 兼容; **必须配套 EDK2 0001 同时打**, 否则 stock EDK2 看到额外 `/memory` 节点会 ASSERT 挂死 |
| 0002 | `0002-ui-iosurface-display-backend.patch` | 引入 macOS-only display backend `-display iosurface,socket=...` (AF_UNIX + POSIX shm + SCM_RIGHTS); 协议规范见 [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) v1.0.0; 同时 patch `scripts/meson-buildoptions.sh` 让 configure 识别 `--enable-iosurface` (该 .sh 是 `meson_options.txt` 由 `meson-buildoptions.py` 派生的中间文件, 不打进 patch 则 configure 报 unknown option, 必须改用 `-D` 直传) |
| 0003 | `0003-hw-display-hvm-gpu-ramfb-pci.patch` | 新 PCI 设备 `hvm-gpu-ramfb-pci` (套版 `hw/display/virtio-vga.c`, VGA 路径换成 ramfb): 单设备同时挂 ramfb (UEFI/bootmgfw GOP 兼容) + virtio-gpu-pci (OS 期 viogpudo.sys / 内核 virtio-gpu driver 接管做 dynamic resize); vendor/device id 复用 0x1AF4/0x1050 让 viogpudo.inf 自动 match; Windows guest argv 走 `-device hvm-gpu-ramfb-pci` 替代单挂 ramfb; 内部 dispatcher 按 `g->parent_obj.enable` 切: 0 走 `ramfb_display_update`, 1 走 virtio-gpu cmd handler 自己的 `dpy_gfx_update`; `ui_info` 始终转给 virtio-gpu 让 vdagent / EDID 通路在 OS 期立刻拿到 host 端尺寸 hint |

cocoa 保留作 fallback / 调试; 生产路径由 HVM 主进程 argv 选 `iosurface`。

### patches/edk2 (1 个)

| 序号 | 文件 | 用途 |
|---|---|---|
| 0001 | `0001-armvirt-extra-ram-region-for-win11.patch` | ArmVirtPkg 按 `PcdSystemMemoryBase` 选主 RAM (而非取最低地址), 收集额外 `/memory` 节点到 GUID HOB, MemoryPeim 注册成 `SYSTEM_MEMORY` + 加 MMU 页表; 配套 QEMU 0001 让 Win11 ARM64 bootmgfw 在 0x10000000 的内存操作能成功 |

## 构建参数 (锁定, 改必须同步 `CLAUDE.md`)

### QEMU `configure`

```
--prefix=$STAGING_DIR
--target-list=aarch64-softmmu      # 只打 AArch64 system 目标
--enable-cocoa                     # fallback / 调试
--enable-hvf                       # Apple Hypervisor.framework 加速 (HVF)
--enable-iosurface                 # patch 0002 引入的 macOS-only 显示后端
--disable-docs / --disable-gtk / --disable-sdl / --disable-vnc / --disable-curses
--disable-debug-info / --disable-werror / --disable-fuse / --disable-spice
--disable-libssh / --disable-curl / --disable-libnfs / --disable-libiscsi
--disable-rbd / --disable-glusterfs / --disable-rdma
```

`--disable-fuse`: macFUSE 头与 QEMU `fuse.c` 不兼容, 我们也不需要镜像导出成 FUSE 文件系统。其余 disable 都是 Win/Linux arm64 guest 用不到的远程块/显示后端, 缩短编译 + 缩小产物 + 避免环境探测引入的脆弱性。

### EDK2 build

```
-p ArmVirtPkg/ArmVirtQemu.dsc -a AARCH64 -t GCC5 -b RELEASE
```

cross compile 经 brew `aarch64-elf-gcc`。

### brew 依赖 (锁定, 仅打包者机器装)

```
meson ninja pkgconf glib pixman libslirp dtc capstone swtpm libtpms
```

(EDK2 build 还需要 `aarch64-elf-gcc`, 由 `edk2-build.sh` 单独装。)

## 进程模型

- HVM 主进程通过 `Foundation.Process` 启动 `Bundle.main/Resources/QEMU/bin/qemu-system-aarch64`, **不**链接 `libqemu`
- 控制通道: QMP 仅监听 unix domain socket (`<bundle>/run/<vm-id>.qmp`), **严禁 TCP 监听**
- 显示通道: HDP iosurface 也只 unix socket (`<bundle>/run/<vm-id>.iosurface.sock`)
- TPM: swtpm 作 sidecar 子进程, unix socket 与 QEMU 对接
- swtpm 自动打包入 `.app` (`bundle_swtpm` step), 依赖 dylib 经 `install_name_tool` 重定向到 `@rpath/../lib/`
- 生命周期、日志、崩溃退出码、资源回收 (子进程强杀) 由 `HVMQemu/QemuProcessRunner.swift` + `SwtpmRunner.swift` 管理

## Bundle 互斥

QEMU 后端 VM 与 VZ 后端 VM 同样遵守"单 `.hvmz` 单进程"原则, 复用 `HVMBundle` 的 fcntl flock (BundleLock), 与 VZ 共享同一锁文件。

## 签名闭环

- `Resources/QEMU/bin/*` 必须**逐文件** codesign (qemu-system-aarch64 / qemu-img / swtpm 等), 严格不吞错
- `Resources/QEMU/lib/*.dylib` + `Resources/QEMU/libexec/*` 当前用 `|| true` 吞错 (软模式; 已识别为 v2 P0 #1, 计划修)
- QEMU 子进程使用独立 entitlement `app/Resources/QEMU.entitlements` (含 `com.apple.security.hypervisor`, HVF 必需), **不**与 HVM 主进程的 `com.apple.security.virtualization` 共用
- 整包再 `codesign --deep` 包裹
- `codesign --verify --deep --strict` 收尾

## GPL 合规

- 上游 QEMU GPLv2; 随 `HVM.app` 再分发其二进制必须遵守 license:
  - LICENSE 全文随包: `Resources/QEMU/LICENSE` + `LICENSE.LGPL`
  - 对应版本源码可获取: HVM 仓库 GitHub 公开 + `MANIFEST.json` 内 `qemu_tag` (v10.2.0) + `qemu_commit_sha` 锁定上游 commit, 配合 `patches/qemu/series` 即能复现
- EDK2 / swtpm / libtpms 同样写入 `MANIFEST.json`
- UI "关于" 页面后续追加"开放源代码许可"入口列出 QEMU + EDK2 + swtpm/libtpms (M6 待办)

## 与 VZ 的功能边界

- `VMConfig.engine` 字段区分 `vz` / `qemu`, 默认 `vz`
- 不在无迁移流程下随意切换同一磁盘文件: VZ raw vs QEMU qcow2 / 设备模型差异; 详见 [STORAGE.md](STORAGE.md) "磁盘格式按 engine 分流"
- `hvm-dbg` 现有 screenshot/key/mouse/ocr 等仅 VZ 后端; QEMU 等价物 (QMP `screendump` + `human-monitor-command sendkey`) 待接入

## 不做什么

- **非 arm64 的 guest** (x86_64 / 32-bit / riscv): 不在范围, 不扩展对应 `qemu-system-*` 打包
- **不实现"用户自行指定系统 QEMU 路径"作默认**: 违背"全包在 .app 内"; 仅 env override (`HVM_QEMU_ROOT`) 给 CI / 调试
- **不一次性接入 QEMU 完整设备矩阵**: 一期以"能可靠启动/停止 + 可观测日志"为主
- **不打 `qemu-system-x86_64` 等其他 system target**: 控签名面 + 体积
- **不 fork 上游 QEMU / EDK2**: 全走 `patches/<repo>/series` 串行管理

## 实施状态

QEMU 后端 Win11 / Linux arm64 完整闭环已落地。`make build-all` 一次跑通后, `.app` 自带 QEMU + EDK2 + swtpm + 全部依赖 dylib, 最终用户机器零依赖。Swift 侧模块: `HVMQemu/` (QemuPaths / QemuArgsBuilder / QemuProcessRunner / QmpClient / SwtpmRunner / SidecarProcessRunner / QgaExec / WindowsUnattend / QemuConsoleBridge ...) + `HVMDisplayQemu/` (HDP 协议 + Metal renderer + iosurface 通路, 详见 [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md))。

### 待办

- 真实 Win11 / Linux arm64 ISO 端到端实测覆盖 TPM / SecureBoot / virtio 驱动加载
- QEMU 后端 `dbg.*` 命令支持 (screenshot / key / mouse / ocr 等)
- bundle.sh dylib `|| true` 漏洞 (v2 #1)

## 未决事项

| 编号 | 内容 |
|---|---|
| M6 | UI "关于" 页面追加"开放源代码许可"入口, 列 QEMU + EDK2 + swtpm/libtpms; 当前以 `Resources/QEMU/LICENSE` + `MANIFEST.json` 满足强制要求 |

## 相关文档

- [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) — HDP 协议规范 (patch 0002 引入)
- [BUILD_SIGN.md](BUILD_SIGN.md) — `bundle.sh` / 签名顺序 / env override 列表
- [NETWORK.md](NETWORK.md) — socket_vmnet 走 brew 不入包
- [VM_BUNDLE.md](VM_BUNDLE.md) — `config.yaml` `engine` 字段
- [STORAGE.md](STORAGE.md) — VZ raw vs QEMU qcow2 分流
- `patches/qemu/README.md` — 添加新补丁流程

---

**最后更新**: 2026-05-04
