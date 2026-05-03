# CLI 设计 (`hvm-cli`)

## 目标

- 给自动化脚本 / CI / 终端用户 GUI 之外的 VM 管理入口
- 与 GUI 共享同一套 HVM* 模块 (HVMCore / HVMBundle / HVMStorage / HVMInstall 等), 不维护两套逻辑
- 子命令层级清晰, 输出可机读 (`--format json`)

## 定位

- `hvm-cli` 是短命进程: 每次执行做完事就退, 不常驻
- 不是 daemon: VM 启动时, `hvm-cli start` 会拉起 `HVM.app` 自身作为 `--host-mode-bundle` 子进程 (即 VMHost), 该子进程持有 `VZVirtualMachine` / 启动 QEMU 后端 + IPC socket
- GUI 与 CLI 没有主从关系: CLI 启动的 VM, GUI 扫 `~/Library/Application Support/HVM/VMs/` 自动可见; GUI 启动的 VM, CLI 通过 `<bundle>/.lock` 里记录的 socket 连 VMHost 下命令

### `HostLauncher.locateHVMBinary`

CLAUDE.md 第三方二进制约束: 严格只查 .app 安装位置, 不再 fallback 到仓库 `build/HVM.app`。

```
1. $HVM_APP_PATH (CI / 调试 override)
2. /Applications/HVM.app
3. ~/Applications/HVM.app
```

dev 期 `hvm-cli start` 前必须先 `make install` 把 `build/HVM.app` 同步到 `/Applications/HVM.app`, 否则报 "未找到 HVM.app"。

## 子命令总览

入口 `app/Sources/hvm-cli/HvmCli.swift` 注册的子命令:

```
hvm-cli list [--watch / -w] [--interval N] [--format human|json]   列 VM, 可滚动监听
hvm-cli status <vm>                  显示单 VM 详情
hvm-cli create ...                   创建新 VM bundle (linux / macOS / windows)
hvm-cli delete <vm> [--purge]        删除 VM
hvm-cli clone <vm> --name <new>      整 VM 克隆 (APFS clonefile + 身份字段重生)
hvm-cli start <vm>                   启动 VM (拉起 HVMHost 子进程)
hvm-cli stop <vm>                    软关机 (ACPI shutdown)
hvm-cli kill <vm>                    强制关机
hvm-cli pause <vm> / resume <vm>     vCPU 挂起 / 恢复
hvm-cli boot-from-disk <vm>          标记仅从硬盘启动 (装完后用)
hvm-cli iso select <vm> <path>       指定 / 替换安装 ISO (并清 bootFromDiskOnly)
hvm-cli iso eject <vm>               弹出 ISO + 切硬盘启动
hvm-cli disk <vm> list|add|resize|delete   磁盘操作 (vz=raw / qemu=qcow2)
hvm-cli snapshot <vm> create|list|restore|delete   APFS clonefile 整体快照
hvm-cli config <vm> get|set          读 / 改 cpu / memory
hvm-cli logs <vm> [--date YYYY-MM-DD] [--all]   打印 host 端日志
hvm-cli install <vm>                 macOS 全自动装机; Linux 走 start + 手动安装
hvm-cli ipsw latest|catalog|fetch|list|rm        macOS IPSW 缓存管理
hvm-cli osimage list|fetch|cache|rm  Linux / Windows guest ISO 自动下载与缓存
```

## 命令详解

### `list` (含 `--watch`)

`hvm-cli list [--bundle-dir <path>] [--format human|json] [--watch / -w] [--interval N]`

- 默认单次 + 退出
- `--watch / -w` 持续刷新, `--interval` 默认 2 (秒)
- watch 模式下 human 输出走 ANSI 清屏 (`\x1B[H\x1B[2J`) + 顶头时间戳; **json 模式不清屏**, 方便 `pipe` 给 `jq -c` 流式消费
- watch 通过 `signal(SIGINT, SIG_IGN)` + `DispatchSource.makeSignalSource(.SIGINT)` 优雅退出 (Ctrl+C 100ms 内退)
- `--interval <= 0` 报错退出码 2

### `status <vm>`

human 渲染 / `--format json` 给单对象, 字段对齐 list 的 row 模式 (id / state / cpu / memory / mainDisk / bundlePath 等)。

### `create`

非交互式, 选项一览 (节选 `CreateCommand.swift`):

| 选项 | 说明 |
|---|---|
| `--name` | 必填; bundle 目录 `<name>.hvmz` |
| `--os` | `linux` / `macOS` / `windows` |
| `--engine` | `vz` / `qemu` (默认: linux/macOS=vz, windows=qemu 强制) |
| `--cpu` `--memory` `--disk` | CPU 核心 / 内存 GiB / 主盘 GiB |
| `--iso` | Linux ISO 绝对路径 |
| `--ipsw` | macOS IPSW 绝对路径 |
| `--import-disk` | 直接复用现有 raw / qcow2 当主盘 (装好的 cloud image) |
| `--network` | `nat` / `bridged:<iface>` / `shared` / `host` |
| `--path` | bundle 父目录 |
| `--mac` | 手动 MAC, 默认随机 locally-administered |

### `start <vm>`

```
1. 检查 <bundle>/.lock fcntl flock, 已被锁 → 报 bundle.busy (退出 4)
2. HostLauncher.launch(bundleURL:): fork HVM.app 自身 + argv `--host-mode-bundle <path>`
3. VMHost 启动后写 .lock + IPC socket; CLI 立即返回
```

stdout/stderr 走全局 log: `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/host-<date>.log` (CLAUDE.md 日志路径约束)。

### `stop` / `kill` / `pause` / `resume`

走 IPC 命令到 VMHost (`HVMIPC/Protocol.swift` `IPCOp.stop / kill / pause / resume`)。socket 不存在直接报 ipc 错误。

### `disk <vm>`

`disk list / disk add --size <GiB> / disk resize --role main|data --to <GiB> --uuid <uuid8> / disk delete <uuid8>`

- 加 / 改 / 删都要求 VM stopped
- 主盘扩容: VZ raw 走 ftruncate, QEMU qcow2 走 `qemu-img resize` (从 `Bundle.main` 包内 QEMU)
- guest 内仍需 `resize2fs` / 分区工具, CLI 完成后打印提示

### `snapshot <vm>`

`snapshot create [--label] / snapshot list / snapshot restore <name> / snapshot delete <name>` — 基于 APFS clonefile, 几乎零空间, 全程 VM 必须 stopped。

### `clone <vm>`

`hvm-cli clone <vm> --name <new> [--target-dir <dir>] [--keep-mac] [--include-snapshots] [--format human|json]`

整 VM 克隆 (跨 bundle, 与 snapshot 正交, 见 [STORAGE.md "Clone"](STORAGE.md)):

| 选项 | 说明 |
|---|---|
| `<vm>` | 源 VM 名称 / bundle 路径 |
| `--name` | 必填; 新 VM 显示名 (1-64 字符, 不允许 / NUL); 同时也是目录名 `<name>.hvmz` |
| `--target-dir` | 目标父目录, 缺省 = 源父目录 (通常 `~/Library/Application Support/HVM/VMs`); 必须与源同 APFS 卷 |
| `--keep-mac` | 保留所有 NIC MAC (默认: 重生; 用户自负同 LAN 不双开) |
| `--include-snapshots` | 复制 `snapshots/` 整目录 (默认: 不带, 克隆是另起新 VM) |

行为:
- 抢源 `.edit` lock 排他, 与 `.runtime` 冲突直接抛 `.bundle(.busy)` (退出 4)
- 同卷校验失败抛 `.storage(.cross_volume_not_allowed)` (退出 1)
- 目标已存在抛 `.bundle(.alreadyExists)` (退出 1)
- 任意失败 → 自动清掉目标残留, 不留 partial bundle
- 成功输出 (human): 源/目标路径 + 新 UUID + 数据盘 uuid8 重生映射
- 成功输出 (json): `{ ok, source, target, newId, renamedDataDisks }`

字段重生 / 保留矩阵详见 [VM_BUNDLE.md](VM_BUNDLE.md) 顶层字段表 + [STORAGE.md "Clone"](STORAGE.md).

### `config <vm>`

- `config get` 打印当前 config (`--format json` 给 yaml→json 化)
- `config set --cpu N --memory G` 改后写回 `config.yaml` (schema v2)

### `iso select` / `iso eject` / `boot-from-disk`

装机三联操作: `iso select` 写 `installerISO` + 清 `bootFromDiskOnly`, 用户进 guest 装好 → `boot-from-disk` (或 `iso eject`) 切回硬盘启动。

### `logs <vm>`

打印 `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/` 下的 host 端日志:
- `--date YYYY-MM-DD` 选某天 (默认今天)
- `--all` 全部 (谨慎, 可能很大)

### `install <vm>`

macOS guest 全自动装机入口 — 调 `VZMacOSInstaller`, 进度条 / json `--follow` 流式输出。Linux guest 走 `start + 手动安装`, 不在此命令里自动按键。

### `ipsw <op>` (macOS guest)

```
hvm-cli ipsw latest                                   查 Apple 推荐最新, 不下载
hvm-cli ipsw catalog                                  列 mesu.apple.com 全量 VZ 可用 build (倒序)
hvm-cli ipsw fetch [--build BUILD | --url URL]        下载 (默认 latest 三选一互斥)
hvm-cli ipsw fetch --force / --format json --follow   强制重下 / 流式 progress
hvm-cli ipsw list                                     列本地缓存
hvm-cli ipsw rm <build|all>                           删单条或清全部
```

走 `IPSWFetcher` + `ResumableDownloader` (`HVMUtils/`), 落 `~/Library/Application Support/HVM/cache/ipsw/<buildVersion>.ipsw` + `.partial` + `.meta`, 断点续传 (HTTP `Range` + `If-Range`, 416 / 200 兼容)。详见 [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md#macos-guest-装机)。

### `osimage <op>` (Linux / Windows ISO 自动下载, 2026-05-03 落地)

`OSImageCatalog` 内置 7 个 arm64 发行版 + Windows custom URL 兜底, 走 `OSImageFetcher` + `ResumableDownloader` + SHA256 校验:

```
hvm-cli osimage list [--format json]                       列 catalog 内置 7 个 entry + 缓存状态
hvm-cli osimage fetch <id|--url URL> [--force]             下 entry id (e.g. ubuntu-24.04) 或自定 URL
                       [--format json] [--follow]
hvm-cli osimage cache [--family ubuntu|debian|...|custom]  列已缓存
hvm-cli osimage rm <id|all>                                删 entry 缓存 (.iso + .partial + .meta)
```

缓存路径 `~/Library/Application Support/HVM/cache/os-images/<family>/<file>.iso`。Custom URL 模式跳过 SHA 校验。详见 [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md#linux-guest-自动下载)。

## 输出格式

### human

- 等宽对齐, 控制在终端宽度
- 单位 `Gi` / `MiB` 带后缀
- 进度长操作单行刷新 (`\r`)

### json

- `--format json` 切, 字段 lowerCamelCase
- 错误也走 JSON: `{ "error": { "code": ..., "message": ..., "details": {...}, "hint": ... } }` (`bailJSON` 路径)

## VM 定位策略

`<vm>` 解析顺序 (`hvm-cli/Support/BundleResolve.swift`):

1. 绝对路径或相对路径指向 `.hvmz` 目录 → 直接用
2. 当前工作目录的 `<vm>.hvmz` 或裸 `<vm>` (若是 bundle) → 用
3. 否则当 name → `<bundle-dir>/<name>.hvmz` (默认 `~/Library/Application Support/HVM/VMs`)
4. 多个同名歧义 → 报错, 要求显式路径

## 退出码

由 `hvm-cli/Support/OutputFormat.swift::exitCode(for:)` 按 `HVMError.userFacing.code` 映射:

| code | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 通用错误 |
| 2 | 参数 / 用法错误 (`config.*`, list `--interval <= 0`) |
| 3 | bundle 未找到 (`bundle.not_found`) |
| 4 | bundle 被占用 / 磁盘忙 (`bundle.busy`, `backend.disk_busy`) |
| 5 | 状态不允许当前操作 (`backend.invalid_transition`) |
| 6 | 超时 (`ipc.timed_out`) |
| 10 | 后端 / VZ 内部错误 (`backend.*`) |

## shell 补全

`swift-argument-parser` 自带:

```
hvm-cli --generate-completion-script zsh > ~/.zsh/completions/_hvm-cli
hvm-cli --generate-completion-script bash > /usr/local/etc/bash_completion.d/hvm-cli
hvm-cli --generate-completion-script fish > ~/.config/fish/completions/hvm-cli.fish
```

## 自动化示例

```bash
#!/usr/bin/env bash
set -euo pipefail

# 起 Ubuntu 24.04 ARM 跑测试
hvm-cli osimage fetch ubuntu-24.04
hvm-cli create --name ci-temp --os linux --cpu 4 --memory 4 --disk 32 \
               --iso ~/Library/Application\ Support/HVM/cache/os-images/ubuntu/*.iso
hvm-cli start ci-temp

# guest 内跑命令 (经 hvm-dbg)
hvm-dbg exec ci-temp -- /bin/bash -c "cd /src && make test"

# 清理
hvm-cli stop ci-temp
hvm-cli delete ci-temp --purge --force
```

## 与 GUI 的协同

- CLI 操作通过 IPC 推送事件, GUI 打开时自动刷新
- GUI 启动的 VM, CLI 可 stop/status, 走 `<bundle>/.lock` 里 socket 路径连 VMHost
- CLI 不提供"切到 GUI 打开窗口"的能力, 用户自行 open HVM.app

## 不做什么

1. 不做交互式 REPL
2. 不做远程管理 (不连别的 Mac)
3. 不做 yaml 输出 (json 已够)
4. 不做 git-style 别名

## 相关文档

- [DEBUG_PROBE.md](DEBUG_PROBE.md) — `hvm-dbg`, guest 内自动化
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — `install` / `ipsw` / `osimage` 背后流程
- [VM_BUNDLE.md](VM_BUNDLE.md) — config.yaml schema v2 字段语义

---

**最后更新**: 2026-05-04
