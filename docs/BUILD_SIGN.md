# 构建与签名

HVM 的构建 / 签名现状文档。基于真实代码 (`Makefile` / `scripts/bundle.sh` /
`scripts/verify-build.sh` / `app/Package.swift` / `app/Resources/*.entitlements`)。本项目走
**QEMU 后端单一路线** (`qemu-system-aarch64` + HVF), guest 仅 Linux/Windows arm64。

> 现状提示 (代码留痕)：仓库 `app/Resources/HVM.entitlements` 主进程 entitlement 与
> `scripts/bundle.sh` / `scripts/verify-build.sh` 内仍写 `com.apple.security.virtualization`
> (VZ) 字样, 这是 VZ 移除 (2026-05-30) 后尚未清理的残留。**真正必需的 entitlement** 是
> QEMU 子进程的 `com.apple.security.hypervisor` (HVF 加速)。下文以代码实际行为为准, 同时把
> VZ 残留处显式标出。

---

## 1. 构建系统总览

- **SwiftPM 是唯一构建系统**。`app/Package.swift` (`swift-tools-version: 6.0`,
  `platforms: [.macOS(.v14)]`) 声明三个可执行 target：
  - `HVM` — GUI 主进程 + VM host 子进程 (同一二进制, 靠 argv 区分模式)
  - `hvm-cli` — 命令行工具
  - `hvm-dbg` — 调试 / GUI 自动化探针
- **Makefile 是唯一构建入口**, 把 `swift build` 的裸二进制交给 `scripts/bundle.sh` 组装 +
  签名成 `.app`。Xcode 打开 `app/Package.swift` 仅作开发期辅助 (见第 7 节), 不是权威构建路径。
- **所有产物输出到仓库根 `build/`**：
  - `build/HVM.app` — 带签名 + entitlement 的应用包
  - `build/hvm-cli` — 独立 CLI 副本 (同时也塞进 `.app/Contents/MacOS/`)
  - `build/hvm-dbg` — 独立 dbg 副本 (同时也塞进 `.app/Contents/MacOS/`)
- SwiftPM 中间产物在 `app/.build/`；最终 SwiftPM 二进制在
  `app/.build/arm64-apple-macosx/{release,debug}/`。架构硬约束 Apple Silicon, 路径固定
  `arm64-apple-macosx` (见 `bundle.sh` `SWIFT_BIN`)。

### 三方依赖白名单

`Package.swift` 仅引入两个三方包 (均 SwiftPM 静态链接进二进制, 空白机器无需额外安装)：

| 包 | 用途 |
| --- | --- |
| `swift-argument-parser` (from 1.5.0) | `hvm-cli` / `hvm-dbg` 参数解析 |
| `Yams` (from 5.1.0) | YAML 1.1 解析, `BundleIO` 读写 `<bundle>/config.yaml` |

target 依赖图 (摘 `Package.swift`)：`HVMCore` 为基础库无下游依赖；`HVMControl` 收口
枚举 / 启停 / 删除 (CLI 与 GUI store 共用)；`HVMQemu` 是 QEMU 后端编排 + argv + QMP；
`HVMDisplayQemu` 走 HDP v1.0.0 显示协议 (依赖 C target `HVMScmRecv` 做 SCM_RIGHTS fd 接收)；
`HVMEncryption` 整盘加密；`HVMGuiProbe` 是 HDP-GUI 测试协议。**无 `.testTarget`** (CLAUDE.md
约束：不写 XCTest)。

---

## 2. Make target 一览

| target | 作用 |
| --- | --- |
| `build` (默认) | release 模式, 组装 `.app` + 签名；QEMU stage 缺则跳过嵌入仍出 `.app` |
| `dev` | `build` 的 debug 变体 (`CONFIGURATION=debug`) |
| `compile` | 仅 `swift build` 三个 product (内部步骤) |
| `bundle` | 等价 `build` (兼容老调用方) |
| `icon` | 从 `app/Resources/AppIcon-src.png` 生成 `AppIcon.icns` (源图缺则跳过) |
| `verify` | 跑 `scripts/verify-build.sh` smoke test |
| `install` | `build` 后把 `build/HVM.app` 同步到 `/Applications/HVM.app` |
| `uninstall` | 从 `/Applications/` 删 `HVM.app` (用户数据保留) |
| `run-app` / `open` | `build` 后重启 `build/HVM.app` GUI 主进程 (不动 host 子进程, 不写 `/Applications/`) |
| `dev-open` | debug 模式 dev loop (`make open CONFIGURATION=debug`, 改一行 ~3–5s) |
| `edk2` | 拉 EDK2 + apply Win11 patch + cross compile (仅打包者跑) |
| `edk2-clean` | 清 `third_party/edk2-src/` + `edk2-stage/` |
| `qemu` | 装 brew 依赖 + 拉源码 + 编译 QEMU (仅打包者跑, 10–30 分钟) |
| `qemu-clean` | 清 `third_party/qemu-src/` + `qemu-stage/` |
| `build-all` | `edk2` + `qemu` + `build` (发布完整流程) |
| `clean` | 清 `build/` 与 `app/.build/` |
| `xed` | Xcode 打开 `app/Package.swift` (开发辅助) |
| `register-types` | 刷新 Launch Services 让 Finder 识别 `.hvmz` package |
| `reset-vm NAME=<vm>` | 清指定 VM 运行时残留 + EFI nvram (启动卡死时一键清理) |

变量：`CONFIGURATION ?= release`、`SIGN_IDENTITY ?= auto`、`ENTITLEMENTS := app/Resources/HVM.entitlements`。
`-include makefile.local` 引入本地凭据 (gitignore)；`makefile.local` 内
`MACOS_CODESIGN_IDENTITY` 非空时覆盖 `auto` 签名身份。

### 增量构建机制

`build` 的实质是 stamp target `build/.bundle-stamp`, 依赖：三个 SwiftPM 二进制 mtime +
`$(QEMU_BIN)` (wildcard) + `bundle.sh` + `install-vmnet-daemons.sh` + 两个 entitlements +
`Info.plist.template` + Windows guest helper 产物 + `makefile.local`。`compile` 虽是 PHONY 每次
都跑 `swift build`, 但 no-op 时 SwiftPM 不重链接 → 二进制 mtime 不变 → 跳过 `bundle.sh`。
因此日常改 docs 后 `make build` 走快路径 (~5s), 改源码才重 bundle。debug / release 各自
`.build/{debug,release}` 子目录, 切 `CONFIGURATION` 会 invalidate stamp 重 bundle。

---

## 3. `make build` vs `make build-all`

### `make build` (默认, 日常)

只编 SwiftPM + 组装签名 `.app`：

1. `compile`：`swift build -c release` 三个 product (`HVM` / `hvm-cli` / `hvm-dbg`)。
2. `icon`：生成 `AppIcon.icns` (缺源图跳过)。
3. `bundle.sh`：组装 `build/HVM.app` + 拷 CLI 副本 + 签名 (见第 4 节)。

**`make build` 自身不编译 QEMU / EDK2**。`third_party/qemu-stage/` 不存在时 `bundle.sh`
软跳过 QEMU 嵌入 (`EMBED_QEMU=0`), 仍出可用 `.app`, 但不含 QEMU 后端。

### `make build-all` (发布完整流程)

确保后端就绪后再 build：

1. 若 `third_party/edk2-stage/edk2-aarch64-code.fd` 不存在 → 触发 `make edk2`
   (clone `edk2-stable202408` + apply `patches/edk2/0001-armvirt-extra-ram-region-for-win11.patch`
   + cross compile via brew aarch64-elf-gcc)。
2. 若 `third_party/qemu-stage/bin/qemu-system-aarch64` 不存在 → 触发 `make qemu`
   (装 Homebrew + 锁定 brew 包 + 拉 `v10.2.0` 源码 + apply `patches/qemu/*` + 编译, 10–30 分钟)。
3. `make build`：此时 `bundle.sh` 检测到 `qemu-stage/` 存在, 把整套 QEMU 嵌入 `.app`。

`edk2` / `qemu` 这两步**只在打包者机器跑**, 会自动装 Homebrew 与一组锁定 brew 包 (仅编译
QEMU + EDK2 + swtpm)。最终用户机器零这类依赖 (运行时产物随 `.app` 分发)。

> 版本锁定 (CLAUDE.md QEMU 约束): QEMU `v10.2.0`、EDK2 `edk2-stable202408`, 与
> `scripts/qemu-build.sh` / `scripts/edk2-build.sh` 内 tag 严格绑定。

---

## 4. `bundle.sh` 组装 + 签名闭环

`scripts/bundle.sh` (由 `make bundle`/`build` 调, 入参 `CONFIGURATION` / `SIGN_IDENTITY`)
按以下步骤组装 `build/HVM.app`：

### 4.1 组装

1. **拷二进制**：`HVM` / `hvm-cli` / `hvm-dbg` → `Contents/MacOS/`；`hvm-cli` / `hvm-dbg`
   再各拷一份到 `build/` (开发期可直接 `./build/hvm-cli ...` 不走 `.app`)。
2. **Info.plist**：从 `Info.plist.template` 填版本号。版本号取
   `git describe --tags --always --dirty` (无 tag / detached 时降级 `dev-<sha>`, 再降级 `0.0.1`)；
   `CFBundleVersion` 取 `git rev-list --count HEAD`。最后 `plutil -convert xml1`。
3. **图标**：`AppIcon.icns` 存在则拷入 `Resources/`。
4. **provisioning profile**：`embedded.provisionprofile` 存在则拷入 (当前未使用)。
5. **`install-vmnet-daemons.sh`** → `Resources/scripts/` (GUI `VMnetSupervisor` 严格只查
   `Bundle.main/Resources/scripts/`, 改此脚本必须 `make install` 才能让 `/Applications/` 同步)。
6. **Windows guest helper** (若有)：`patches/guest/helper-win/dist/aarch64/hvm-guest-helper.exe`
   + `libunwind.dll` → `Resources/GuestHelper/` (QemuHostEntry 经 QGA push 到 Win guest)。
7. **嵌入 QEMU** (软模式)：`third_party/qemu-stage/{bin,share,libexec,lib}` →
   `Resources/QEMU/`, 连带 `LICENSE` / `LICENSE.LGPL` / `MANIFEST.json` (GPL 合规)。拷完
   `xattr -c` 清扩展属性防 codesign 报 "resource fork not allowed"。`qemu-stage/` 缺则跳过。
   `socket_vmnet` **不入包** (用户机器自行 `brew install`)。

### 4.2 签名身份选择

`bundle.sh` 优先级 (输出严格不打印证书 SHA / Team ID, CLAUDE.md 安全约束)：

1. 显式 `$SIGN_IDENTITY` (非 `auto`) — 来自 `makefile.local` 的 `MACOS_CODESIGN_IDENTITY`；
2. `"Apple Development"` (本机 Keychain 有该证书时)；
3. `"-"` (ad-hoc 签名, 本项目默认；本机开发可用, 但拷给别的 Mac 会被 AMFI 拒)。

### 4.3 双 entitlement 签名 (核心闭环)

QEMU 子进程与 HVM 主进程用**两份不同 entitlement**, 严禁混用：

| 对象 | entitlement 文件 | 关键 key |
| --- | --- | --- |
| `Resources/QEMU/{bin,lib,libexec}/*` | `app/Resources/QEMU.entitlements` | `com.apple.security.hypervisor` (HVF 必需) |
| `Contents/MacOS/{HVM,hvm-cli,hvm-dbg}` + `.app` + `build/{hvm-cli,hvm-dbg}` | `app/Resources/HVM.entitlements` | `com.apple.security.virtualization` (VZ 残留, 见顶部提示) |

签名顺序 **由内向外**, 保证嵌套 mach-o 先签：

1. 先签 QEMU (仅 `EMBED_QEMU=1` 时)：`lib/*.dylib`+`*.so` → `libexec/` 可执行 → `bin/` 可执行,
   每个文件用 `QEMU.entitlements`。三段都用进程替换 `< <(find ... -print0)` 而非 pipe
   (避免 while 跑进 subshell 吞掉 `set -e`)；任一 `codesign` 失败立即 `exit 1`
   (历史上未签的 dylib 会让 `.app` 启动时被 AMFI `SIGKILL`)。
2. 再签 HVM 自家：`MACOS/HVM` / `hvm-cli` / `hvm-dbg` → `.app` 整包 → `build/hvm-cli` /
   `build/hvm-dbg`, 用 `HVM.entitlements`。

签名参数：`--force --sign "$SIGN" --entitlements <ent> --timestamp=none`；当 `$SIGN != "-"`
(真实证书) 时追加 `--options runtime` (hardened runtime)；ad-hoc 不叠加。

### 4.4 验证 + Launch Services

- `codesign --verify --deep --strict "$APP"` — `--deep` 顺带验 `Resources/QEMU/` 内 mach-o。
- `lsregister -f "$APP"` — 让 `.hvmz` 立即被识别为 package 并关联 HVM.app。

---

## 5. 零运行时依赖

- **最终用户机器**：除 **Xcode Command Line Tools** 外零手动依赖。所有运行时产物
  (QEMU / swtpm / EDK2 firmware / 依赖 dylib) 随 `.app` 包内分发, 走
  `Bundle.main/Resources/QEMU/...`。HVM 主体逻辑全 Swift + Apple framework。
- **`socket_vmnet` 是唯一例外**：桥接网络的 vmnet daemon 二进制不入包, 用户机器自行
  `brew install socket_vmnet`；`install-vmnet-daemons.sh` 从 brew 路径
  (`/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet`) 拉 binary 写 launchd plist。
- **打包者机器例外**：`scripts/qemu-build.sh` / `scripts/edk2-build.sh` 允许装 Homebrew +
  一组锁定 brew 包, 仅用于编译 QEMU/EDK2/swtpm 源码, 不影响最终用户。
- **dylib bundle 闭环** (CLAUDE.md QEMU 约束): `qemu-build.sh` 的 `bundle_qemu_dylibs()` 把
  qemu 链接的 brew dylib (`libcapstone`/`libgnutls`/`libpixman`/`libglib`/`libslirp`/`libzstd`
  等) 拷进 `Resources/QEMU/lib/` + `install_name_tool` 重定向到 `@executable_path/../lib/`。
  不这么做会偷偷依赖 host homebrew, 且 hardened runtime 库校验会拒非同 team 的 adhoc dylib
  (brew 升级重签后 QEMU 启动即 `signal 9`)。这些 dylib 由 `bundle.sh` 4.3 步逐文件签名。

---

## 6. `make install` 何时必须

`make build` 只更新 `build/HVM.app`；用户实际运行的是 `/Applications/HVM.app`。
`make install` 把前者 `cp -R` 同步到后者 (admin 用户对 `/Applications` 有写权限, 无需 sudo；
存在旧版先 `rm -rf` 再拷, 因 `.app` 是 directory 不能直接覆盖), 再 `lsregister -f` 刷新关联。

**以下改动后必须 `make install`** (否则 `/Applications/HVM.app` 仍跑旧版)：

- 改 `third_party/qemu-stage/*` (QEMU / swtpm / firmware) — 否则 GUI 启 VM 用旧 QEMU。
- 改 `scripts/install-vmnet-daemons.sh` — 否则 GUI `VMnetSupervisor` 拉旧脚本 (严格只查
  `Bundle.main/Resources/scripts/`)。
- 改任何被 `bundle.sh` 拷入 `.app` 的内容 (guest helper / 资源等)。

另：`hvm-cli start` 等命令通过 `HostLauncher.locateHVMBinary` 定位 HVM, 探测顺序为
`HVM_APP_PATH` env → 调用方自身位置兄弟 (`build/hvm-cli` 兄弟即 `build/HVM.app`) →
`/Applications/HVM.app` / `~/Applications/HVM.app` 兜底。dev 期 `./build/hvm-cli` 会自动用
`build/HVM.app`, **不必先 `make install`**；但想测从 `/Applications/` 路径启动的链路 (如真实
GUI 安装态), 需先 `make install`。`run-app` / `dev-open` 故意只启 `build/HVM.app` 不写
`/Applications/`, 避免 dev 期污染线上副本。

CLAUDE.md 反复强调：commit 涉及上述包内第三方二进制 / 脚本改动时, 必须显式 `make install`
确认 `/Applications/HVM.app` 同步。

---

## 7. Xcode 兼容

- `make xed` (或 `xed app/Package.swift`) 用 Xcode 打开 SwiftPM 包, 可直接编辑 / 补全 / 构建。
- **Xcode 产物是裸二进制, 无 entitlement, 不签名**, 仅供开发期调试。HVF / 加密 VM 启动等需
  entitlement 的真实运行**必须走 `make build`** (出带 entitlement 的 `.app`)。
- `makefile.local` 的 `APPLE_DEV_TEAM` 可给 Xcode 工程注入 `DEVELOPMENT_TEAM` 免手选 (示例见
  `makefile.local.example`)。

---

## 8. `make verify` smoke test

`scripts/verify-build.sh` 做静态检查 (不启 VM)：

1. 产物结构：`HVM.app/Contents/MacOS/HVM` 可执行 + `Info.plist` + `build/{hvm-cli,hvm-dbg}` 存在。
2. Bundle ID = `com.hellmessage.vm` (`plutil -extract CFBundleIdentifier`)。
3. 签名有效：`codesign --verify --deep --strict` 验 `.app` + CLI / dbg。
4. entitlement 存在：grep `com.apple.security.virtualization` (**VZ 残留检查**, 与顶部提示一致,
   QEMU-only 转向后此项尚未改为查 `com.apple.security.hypervisor`)。
5. CLI 可启动：`hvm-cli --version` / `hvm-dbg --version`。
6. patch 孤儿检测：`patches/qemu/*.patch` + `patches/edk2/*.patch` 必须全列入对应 `series`。
7. GUI 约束守卫：`grep` `app/Sources/HVM/UI/` 确认业务侧无 `NSAlert()` 实例化 (须走
   `ErrorDialog` / `ConfirmDialog`)。

---

## 9. 签名 / entitlement 约束速查

- **必需 entitlement**：`com.apple.security.hypervisor` (QEMU 子进程, HVF 加速；走
  `QEMU.entitlements`)。VZ 的 `com.apple.security.virtualization` / 桥接
  `com.apple.vm.networking` 已随 VZ 移除不再实际需要 (代码内 `HVM.entitlements` 残留待清)。
- **签名方式**：自动 `codesign --sign "Apple Development"` 或 ad-hoc `-`, 不公证不分发。
- **桥接网络**：走 `socket_vmnet` launchd daemon (brew + osascript admin 提权), 不依赖任何
  VZ networking entitlement。
- **保密**：签名相关代码 / 日志不得输出任何 team ID / 证书 SHA / 私钥路径
  (`bundle.sh` 已遵守)。
- **GPL 合规**：QEMU 上游 commit SHA + tag + license 写入 `Resources/QEMU/MANIFEST.json` +
  `LICENSE`；HVM 仓库 GitHub 公开即满足源码可获取要求。
