# 构建与签名

## 目标

- 空白 Mac 上 `make build` 一条命令跑通, 除 Xcode Command Line Tools + Apple Developer 证书外**零手动依赖**
- SwiftPM 是唯一构建系统, 产物由 `scripts/bundle.sh` 组装 + 签名成 `.app`
- Xcode 开发期可用 `xed app/Package.swift` 直接打开, 不强制走 Makefile (产裸二进制, 无 entitlement, 仅调试期使用)
- 真实运行必须走 `make build`, 出带 entitlement 签名的 `.app`
- **完整发布走 `make build-all`** (先 `make edk2` + `make qemu` 再 `make build`); `make build` 自身**不**编译 QEMU/EDK2, 缺 QEMU 产物时仍可出 `.app` 但不嵌入 QEMU 后端 (软模式)

## 工具依赖

| 工具 | 必需 | 备注 |
|---|---|---|
| Xcode 16+ (Swift 6) | 必需 | 安装 Xcode Command Line Tools 即可 |
| Apple Development 证书 | 可选 | 没有就走 ad-hoc, 自机仍能跑 VZ |
| `swift` (SwiftPM 6) | 必需 | 随 Xcode 带 |
| `codesign` / `plutil` | 必需 | 系统自带 |
| `python3` | 必需 | EDK2 firmware padding 用; macOS 自带 |
| Homebrew + brew 包 | 仅打包者 | **只**给 `scripts/qemu-build.sh` + `scripts/edk2-build.sh` 用; HVM 主体不引 brew |

CLAUDE.md 硬约束: HVM 主体不引 Homebrew / vendor / 编译外部 C 项目; **QEMU 后端例外** — 打包者机器允许 brew, 最终用户机器仍零依赖, 所有运行时产物随 `.app` 包内分发。

## 目录布局

```
HVM/
├── app/                              — SwiftPM 子目录
│   ├── Package.swift                 — manifest
│   ├── Sources/
│   │   ├── HVMCore/                  — 错误模型 / 路径 / 日志 / Tunables
│   │   ├── HVMBundle/                — .hvmz 读写 + lock + config.yaml
│   │   ├── HVMStorage/               — DiskFactory (raw/qcow2)
│   │   ├── HVMNet/                   — 5-mode 网络栈 (NetSpec / vmnet)
│   │   ├── HVMDisplay/               — VZ 显示 (NSView wrapping VZ guest screen)
│   │   ├── HVMDisplayQemu/           — QEMU HDP 显示 (Metal + iosurface)
│   │   ├── HVMBackend/               — VZ 后端 + Engine 分派
│   │   ├── HVMQemu/                  — QEMU 后端 (QmpClient / QemuArgsBuilder / SwtpmRunner ...)
│   │   ├── HVMInstall/               — IPSW / ISO 装机 + virtio-win 缓存
│   │   ├── HVMIPC/                   — host ↔ CLI/dbg unix socket IPC
│   │   ├── HVM/                      — App target (SwiftUI + host 分派入口)
│   │   ├── hvm-cli/                  — CLI
│   │   └── hvm-dbg/                  — 调试探针
│   ├── Tests/HVM*Tests/
│   └── Resources/
│       ├── HVM.entitlements          — 主进程 entitlement
│       ├── QEMU.entitlements         — QEMU 子进程独立 entitlement (com.apple.security.hypervisor)
│       ├── Info.plist.template
│       ├── AppIcon.icns / AppIcon-src.png
│       └── (embedded.provisionprofile 仅 bridged 审批通过后存在)
├── scripts/
│   ├── bundle.sh                     — 组装 .app + 签名
│   ├── qemu-build.sh                 — 锁版本 QEMU v10.2.0 build → third_party/qemu-stage/
│   ├── edk2-build.sh                 — EDK2 stable202408 build → third_party/edk2-stage/
│   ├── install-vmnet-daemons.sh      — 写 launchd plist 起 socket_vmnet daemon
│   ├── gen-icon.sh                   — PNG → .icns
│   └── verify-build.sh               — smoke test
├── patches/
│   ├── qemu/                         — QEMU 上游补丁串行 (series + 0001/0002/0003)
│   └── edk2/                         — EDK2 上游补丁串行 (series + 0001)
├── third_party/                      — gitignored
│   ├── qemu-src/                     — git clone v10.2.0 (~900M)
│   ├── qemu-stage/                   — 编译 + 裁剪 + 嵌 swtpm 后成品 (~180M)
│   ├── edk2-src/                     — git clone stable202408 含 submodules (~700M)
│   └── edk2-stage/                   — patched + padded edk2-aarch64-code.fd (Win11)
├── build/                            — 构建产物 (gitignored)
│   ├── HVM.app
│   ├── hvm-cli
│   └── hvm-dbg
├── Makefile
├── CLAUDE.md
└── docs/
```

## Makefile 入口

唯一权威构建入口, 真正命令以 `Makefile` 为准。

| target | 行为 |
|---|---|
| `make build` (默认) | release 模式 SwiftPM 编译 + `bundle.sh` 组装 + 签名; QEMU 缺则**软模式**跳过嵌入 |
| `make dev` | debug 模式 + 组装 + 签名 (转 `make build CONFIGURATION=debug`) |
| `make build-all` | EDK2 + QEMU 产物缺则触发 `make edk2` + `make qemu`, 然后 `make build`; 发布完整流程 |
| `make qemu` | 装 brew 依赖 + 拉 v10.2.0 + apply patches + configure + build → `third_party/qemu-stage/` (10–30 分钟, 仅打包者) |
| `make qemu-clean` | 删 `third_party/qemu-src/` + `third_party/qemu-stage/` |
| `make edk2` | 拉 stable202408 + apply Win11 patch + cross-compile RELEASE GCC AARCH64 → `third_party/edk2-stage/` (3–5 分钟) |
| `make edk2-clean` | 删 `third_party/edk2-src/` + `third_party/edk2-stage/` |
| `make test` | `swift test --package-path app` |
| `make verify` | smoke test, 验证 `.app` 可启动 |
| `make icon` | 从 `app/Resources/AppIcon-src.png` 生成 `AppIcon.icns` |
| `make xed` | `xed app/Package.swift` (开发期辅助, 非权威构建路径) |
| `make install` | `cp -R build/HVM.app /Applications/HVM.app` (覆盖旧版) + `lsregister -f` |
| `make uninstall` | 删 `/Applications/HVM.app` (用户数据 `~/Library/Application Support/HVM/` 不动) |
| `make run-app` | install + 仅杀**主 GUI 进程** (`awk NF==2` 严格匹配) + `open` 重新拉起; 保留正在跑的 `--host-mode-bundle` 子进程 |
| `make register-types` | LaunchServices 重注册, 让 Finder 立刻识别 `.hvmz` |
| `make reset-vm NAME=...` | pkill GUI + 删 `<bundle>/.lock` / `<bundle>/nvram/efi-vars.fd` / `~/Library/Application Support/HVM/run/*.sock` |
| `make clean` | 删 `build/` + `app/.build/` |

签名身份: 通过 `SIGN_IDENTITY` 环境变量传入, 默认 `auto` (由 `bundle.sh` 自动探测)。

## scripts/bundle.sh 流程

由 `make bundle` 调用, 依赖 `make compile` (SwiftPM 已产 `HVM` / `hvm-cli` / `hvm-dbg`)。

1. **签名身份选择** (优先级):
   1. 显式 `$SIGN_IDENTITY` 非 `auto`
   2. `Apple Development` (`security find-identity -v -p codesigning` 列出且证书链完整)
   3. ad-hoc `-` (默认; 本机自用足够, AMFI 接受 `com.apple.security.virtualization`, 但其他 Mac 上 Gatekeeper 会拒)

   签名相关输出**严格不打印** Team ID / 证书 SHA / 私钥路径 (CLAUDE.md 安全约束)。

2. **拷贝 SwiftPM 产物** (`app/.build/arm64-apple-macosx/<config>/`):
   - `HVM` → `Contents/MacOS/HVM`
   - `hvm-cli` → `Contents/MacOS/hvm-cli` + `build/hvm-cli`
   - `hvm-dbg` → `Contents/MacOS/hvm-dbg` + `build/hvm-dbg`

3. **写 Info.plist** (`app/Resources/Info.plist.template` + `sed`):
   - `CFBundleShortVersionString` = `git describe --tags --always --dirty` (无 tag 默认 `0.0.1`)
   - `CFBundleVersion` = `git rev-list --count HEAD` (单调递增)
   - `plutil -convert xml1` 规整

4. **拷 Resources**:
   - `AppIcon.icns` (若存在)
   - `embedded.provisionprofile` (仅 bridged 审批通过且文件存在时)
   - `scripts/install-vmnet-daemons.sh` → `Resources/scripts/install-vmnet-daemons.sh` + `chmod +x`
     (GUI VMnetSupervisor 严格只走 `Bundle.main/Resources/scripts/`, 不再 fallback 到仓库 `scripts/`)

5. **嵌入 QEMU 后端** (软模式: `third_party/qemu-stage/` 不存在则跳过, 仍出 `.app`):
   - `cp -R third_party/qemu-stage/{bin,share,libexec,lib}` → `Resources/QEMU/`
   - 拷 `LICENSE` / `LICENSE.LGPL` / `MANIFEST.json`
   - `xattr -c` 防御性清扩展属性 (qemu-build.sh 已清, 此处再清防 cp 期间被打回)

6. **签名 (由内向外)**:
   - QEMU 子进程使用独立 entitlement `app/Resources/QEMU.entitlements` (含 `com.apple.security.hypervisor`, HVF 必需), **不**与 HVM 主进程共用
   - 真实证书叠加 `--options runtime` (hardened runtime); ad-hoc `-` 不叠加
   - 顺序:
     1. `Resources/QEMU/lib/*.dylib` + `*.so`  ← **当前用 `|| true` 吞错** (软模式; 缺一份 dylib 不阻塞构建, 但运行时 dyld 失败时排查难)
     2. `Resources/QEMU/libexec/*` (qemu-bridge-helper 等)  ← **同样 `|| true` 吞错**
     3. `Resources/QEMU/bin/*` (qemu-system-aarch64 / swtpm 等) — **必须签成功, 不吞错**
     4. `Contents/MacOS/HVM` / `hvm-cli` / `hvm-dbg`
     5. `.app` 整包 (与 `--deep` 对应)
     6. `build/hvm-cli` / `build/hvm-dbg` (独立副本)

7. **验证签名结构**: `codesign --verify --deep --strict "$APP"`

8. **LaunchServices 重注册**: `lsregister -f "$APP"` 让 `.hvmz` 立即识别为 package + 关联 HVM。

> **已知问题** (v2 计划): 第 6.1/6.2 步的 `|| true` 是签名流程漏洞 — 任何一份 dylib/helper 签名失败都被静默吞掉, 用户机器实际运行时才报 dyld 错。v2 P0 #1 计划改成 `set -e` + 失败立即终止 + 明确错误信息。

## Entitlements

### 主进程 `app/Resources/HVM.entitlements`

```xml
<key>com.apple.security.virtualization</key><true/>
<!-- 桥接网络 entitlement, 审批通过后启用:
<key>com.apple.vm.networking</key><true/> -->
```

`com.apple.security.virtualization` 是 Apple Developer 账号自带, 不用申请。`com.apple.vm.networking` 已向 Apple 提交申请, 审批中; 批准前**只实现 NAT 网络** (vmnetShared/vmnetHost 在 VZ 上退化到 NAT)。

### QEMU 子进程 `app/Resources/QEMU.entitlements`

```xml
<key>com.apple.security.hypervisor</key><true/>
```

QEMU 用 Hypervisor.framework (HVF) 加速 aarch64-on-aarch64; 与主进程的 virtualization 能力**职责不同, 不能共用**。

## 第三方运行时定位约束

CLAUDE.md 硬约束: **运行时第三方二进制 / 资源严格只走 `.app` 包内**。

- HVM 进程内 (qemu-system-aarch64 / swtpm / EDK2 firmware): 走 `Bundle.main/Resources/QEMU/...`
  - dev: `open build/HVM.app` → `Bundle.main` = `build/HVM.app`
  - prod: `open /Applications/HVM.app` → `Bundle.main` = `/Applications/HVM.app`
- 外部脚本 (`install-vmnet-daemons.sh`): GUI VMnetSupervisor 严格只查 `Bundle.main/Resources/scripts/install-vmnet-daemons.sh`
- `hvm-cli` (`HostLauncher.locateHVMBinary`): 只查 `/Applications/HVM.app` 与 `~/Applications/HVM.app`, **不再 fallback** 到 `build/HVM.app` — dev 期 `hvm-cli start` 前需先 `make install`

**严禁 fallback** 到 `/opt/homebrew/*` / `/usr/local/*` / 仓库 `third_party/qemu-stage/*` (`socket_vmnet` 例外, 它本来就由用户机器 brew 提供, 不在 `.app` 内, 见 [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) / [NETWORK.md](NETWORK.md))。

### env override (仅 CI / 调试)

| 变量 | 用途 |
|---|---|
| `HVM_QEMU_ROOT` | 覆盖 `Resources/QEMU/` 根 (`HVMQemu/QemuPaths.swift`) |
| `HVM_SWTPM_PATH` | 覆盖 swtpm 二进制路径 (`HVMQemu/SwtpmPaths.swift`) |
| `HVM_APP_PATH` | 覆盖 HVM.app 位置 (`hvm-cli/HostLauncher.swift`) |

老的 `HVM_SOCKET_VMNET_PATH` 已废弃 — socket_vmnet 走 brew, 不再打包。

## 改动后必须 `make install` 同步线上 .app

CLAUDE.md 约束: 改完 `third_party/qemu-stage/*` / `scripts/install-vmnet-daemons.sh` / 任何被 `bundle.sh` 拷入 `.app` 的内容后, `make build` 只更新 `build/HVM.app`, 而用户实际运行的 `/Applications/HVM.app` 仍是旧版 — 必须 `make install` 同步。否则:

- GUI 启动 VM 用的是旧 QEMU/swtpm
- VMnetSupervisor 拉的是旧版 `install-vmnet-daemons.sh`

提交 commit 之前若改动涉及上述项, **必须显式跑 `make install`** 确认线上 `.app` 同步。

## 版本号策略

- `CFBundleShortVersionString` = `git describe --tags --always --dirty` (例: `v0.3.2-5-g9a8b7c6`)
- `CFBundleVersion` = `git rev-list --count HEAD` (单调递增)
- 开发期无 tag 时默认 `0.0.1`, 不阻塞构建

## Xcode 兼容路径

```bash
xed app/Package.swift
```

Xcode 内可编辑 / 补全 / LLDB 调试。点 Run 产出裸 `.build/.../HVM` 二进制, **无 entitlement**, 只能启动 UI 不能跑 VM (VZVirtualMachine 构造会被 AMFI 拒绝)。**真实运行必须 `make build`**, 出带 entitlement 签名的 `.app`。

## 不做什么

1. **不引 Homebrew / vendor 进 HVM 主体** (CLAUDE.md 硬约束; QEMU 打包脚本除外)
2. **不引 CocoaPods / Carthage**
3. **不做 Developer ID 公证 / notarize**: 不分发, 只自用
4. **不上 TestFlight / App Store**
5. **不做自更新机制** (Sparkle 等)
6. **不写 Xcode `.xcodeproj`**: SwiftPM 即可, `xed` 打开 `Package.swift`
7. **不嵌入 Python / Ruby 作为运行时依赖**: scripts/ 只允许 bash + 一处 inline `python3` (EDK2 firmware 64MB padding, macOS 自带)
8. **不引白名单外的三方 Swift 包**: 仅 `swift-argument-parser` (CLI) + `Yams` (config.yaml YAML 1.1)

## 已知问题 / v2 待修

| 编号 | 问题 | 现状 |
|---|---|---|
| v2 #1 | `bundle.sh` 第 5 步 dylib + libexec 用 `\|\| true` 吞错 | 软模式; 计划改为严格签名失败即终止 |
| v2 #16 | Makefile 无增量 — `make build` 不感知 `bundle.sh` / Resources 变化 | 当前每次 `bundle: icon compile`, 依赖 SwiftPM 自身增量; v2 计划加文件 mtime 比较 |

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| I1 | 是否生成 `.dSYM` | 默认生成, `make build` 保留 `build/HVM.app.dSYM/` | 已决 |
| I2 | 是否引入 swift-format / SwiftLint | 不引入, 靠 code review | 已决 |
| I3 | release vs debug 默认 | `make build` = release, `make dev` = debug | 已决 |
| I4 | CI | 暂不做; GitHub Actions runner 没有 VZ 能力, 跑不了集成测试 | 已决 |

## 相关文档

- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — QEMU/EDK2 打包细节, patches 串行管理, 双 firmware 策略
- [ENTITLEMENT.md](ENTITLEMENT.md) — entitlement 细节, bridged 审批 SOP
- [ARCHITECTURE.md](ARCHITECTURE.md) — 模块划分映射到 SwiftPM target
- [NETWORK.md](NETWORK.md) — socket_vmnet 走 brew + 提权方式

---

**最后更新**: 2026-05-04
