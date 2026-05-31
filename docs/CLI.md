# CLI.md — `hvm-cli` 命令行参考

> 现状文档 (QEMU 单后端)。基于 `app/Sources/hvm-cli/**` 真实代码。
> guest 仅 Linux + Windows (arm64); VZ 后端 / macOS guest / IPSW 装机均已下线。

## 1. 总览

`hvm-cli` 是 HVM 的命令行工具,定位为**短命进程**:每次调用做一件事就退出。它有两类工作方式:

1. **直接操作 bundle (`.hvmz`)** — 创建 / 删除 / 克隆 / 改 config / 管磁盘 / 快照等,直接读写 bundle 内文件 (config.yaml 或加密 VM 的 config.yaml.enc)。这类操作多数要求 VM **stopped** (持 `.edit` 锁),running 时抛 `bundle.busy`。
2. **对 host 进程发 IPC** — `stop` / `kill` / `pause` / `resume` 以及 `status` 的运行时信息,通过 VM 的 unix domain socket (`BundleLock` 记录路径) 给正在跑的 VMHost 发 `IPCRequest`,拿 `IPCResponse`。
3. **后台拉起 VMHost** — `start` 通过 `HostLauncher.launch` 后台起 `HVM.app --host-mode-bundle`,立即返回,不阻塞 shell 会话。

入口 `HvmCli.swift` 用 [swift-argument-parser](https://github.com/apple/swift-argument-parser) 的 `AsyncParsableCommand` 注册 21 个顶层子命令。`main()` 在 parse 前装 `SignalGuard.ignoreSIGPIPE()`,防止给已死的 host socket 写命令时被 `SIGPIPE` 直接杀掉。

VM 引用 `<vm>` 参数统一接受**VM 名称**或 **bundle 绝对/相对路径**,经 `BundleResolve.resolve` (内部 `BundleDiscovery.resolve`) 解析,默认搜索根 `~/Library/Application Support/HVM/VMs`;解析失败抛 `bundle.not_found`。

### 顶层子命令一览 (21 个)

| 命令 | 作用 | 子命令 |
| --- | --- | --- |
| `create` | 创建新 VM bundle | — |
| `osimage` | Linux/Windows ISO 下载与缓存 | `list` / `fetch` / `cache` / `rm` |
| `list` | 列出所有 VM | — |
| `status` | 显示单个 VM 详情 | — |
| `start` | 启动 VM (后台) | — |
| `stop` | 软关机 (ACPI shutdown) | — |
| `kill` | 强制关机 (拔电源) | — |
| `pause` | 暂停 (vCPU 挂起) | — |
| `resume` | 恢复运行 | — |
| `delete` | 删除 VM bundle | — |
| `clone` | 整 VM 克隆 | — |
| `encrypt` | 明文 VM → 加密 VM | — |
| `decrypt` | 加密 VM → 明文 VM | — |
| `rekey` | 改密加密 VM | — |
| `encrypt-status` | 查看加密状态 (不解密) | — |
| `boot-from-disk` | 标记只从硬盘启动 | — |
| `iso` | 管理安装 ISO (仅 Linux) | `select` / `eject` |
| `disk` | 管理磁盘 | `list` / `add` / `resize` / `delete` |
| `config` | 读/改 CPU/内存 | `get` / `set` |
| `snapshot` | VM 整体快照 | `create` / `list` / `restore` / `delete` |
| `shared-folder` | 共享目录 (SPICE WebDAV) | `add` / `list` / `remove` |
| `logs` | 打印 host 端日志 | — |

> 没有独立的 `install` / `ipsw` 命令 — macOS guest 随 VZ 移除,IPSW 装机通路下线。`create --ipsw` 仅保留为报错占位 flag。

---

## 2. 子命令详解

下文每节标出:命令名 · 一句话作用 · 主要参数/flag · 用法示例 · 注意。
所有命令默认带 `--format human|json` 输出格式选项 (见 §3),下文不再逐一重复,仅在有特殊语义时说明。

### `create` — 创建新 VM bundle

非交互式创建一个 `.hvmz`,默认生成主盘 (qcow2)、单网卡,写 config.yaml。

主要参数:

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--name <字符串>` | 必填 | VM 名称,bundle 落 `<name>.hvmz` |
| `--os linux\|windows` | `linux` | Guest OS (macOS 已下线) |
| `--engine qemu` | (恒 qemu) | 保留兼容,VZ 已下线 |
| `--cpu <int>` | `4` | CPU 核数 |
| `--memory <GiB>` | `4` | 内存 GiB |
| `--disk <GiB>` | `64` | 主盘大小 GiB |
| `--iso <path>` | — | Linux/Windows 装机 ISO 绝对路径 (非导入时必填) |
| `--import-disk <path>` | — | 导入现成 qcow2/raw 作主盘,与 `--iso` 互斥,仅 `--os linux` |
| `--network nat\|shared\|host\|bridged:<iface>\|none` | `nat` | 网络模式 (`nat` = user-mode NAT) |
| `--path <dir>` | VMs 根 | bundle 父目录 |
| `--mac <addr>` | 随机 | 手动 MAC (默认随机 locally-administered) |
| `--encrypt` | 关 | 创建加密 VM (强制 qemu,prompt 密码) |

示例:

```sh
hvm-cli create --name ubuntu --os linux --iso ~/iso/ubuntu-24.04.iso --cpu 4 --memory 8 --disk 64
hvm-cli create --name owrt --os linux --import-disk ~/openwrt.img   # 导入镜像直接 boot
hvm-cli create --name win --os windows --iso ~/iso/win11-arm.iso --encrypt
```

注意:
- 创建前做卷空间预检 (`VolumeInfo.assertSpaceAvailable`);导入模式按 `max(--disk, 镜像虚拟容量)` 预检。
- `--encrypt`:仅 QEMU,prompt 密码 (双重确认,≥4 字符),走 `EncryptedBundleIO.create` + LUKS qcow2 主盘,Win guest 另建 LUKS OVMF VARS;**不支持** `--import-disk`。
- 任何阶段失败会清掉半成品 bundle。
- 完成后提示下一步:导入模式直接 `start`;装机模式 `start` → 装完 `boot-from-disk`。

### `osimage` — Linux/Windows ISO 下载与缓存

管理 `~/Library/Application Support/HVM/cache/os-images` 内置发行版镜像。4 个子命令:

- **`osimage list`** — 列 `OSImageCatalog` 内置发行版 (id / version / 缓存状态 / 大小 / URL)。
- **`osimage fetch <id> | --url <URL>`** — 下载。`<id>` 走 catalog (带 SHA256 校验);`--url` 自填 URL (跳过校验)。`--force` 已缓存时强制重下;`--follow` (json 模式) 流式输出每帧进度。`id` 与 `--url` 二选一互斥。
- **`osimage cache [--family <fam>]`** — 列已缓存项 (family: ubuntu/debian/fedora/alpine/rocky/opensuse/custom)。
- **`osimage rm <id|all>`** — 删单个 entry 缓存 (含 `.partial`/`.meta`) 或 `all` 全部。

```sh
hvm-cli osimage list
hvm-cli osimage fetch ubuntu-24.04
hvm-cli osimage fetch --url https://example.com/custom.iso
hvm-cli osimage rm all
```

### `list` — 列出所有 VM

枚举 VMs 根下所有 `.hvmz` (走 `VMCatalog.list`,与新 GUI store 同一来源),显示名称 / guest / 运行态 / CPU / 内存 / 主盘占用。

参数:`--bundle-dir <dir>` 自定义搜索目录;`-w` / `--watch` 持续刷新 (Ctrl+C 退出);`--interval <秒>` watch 间隔 (默认 2,必须 > 0)。

```sh
hvm-cli list
hvm-cli list -w --interval 1
hvm-cli list --format json | jq '.[].state'
```

注意:加密 VM 不解密,GUEST 列显 `encrypted`,CPU/内存/磁盘用 0 占位 (读不到)。watch 模式拦 `SIGINT` 循环刷新,human 模式用 ANSI 清屏,json 模式不清屏方便 pipe 给 jq。

### `status` — 显示单个 VM 详情

打印单 VM 的 id / 运行态 / CPU / 内存 / 主盘占用 / ISO / 网络 / bundle 路径。若 VM 在跑,通过 IPC (`IPCOp.status`) 拿运行态 (state/pid/startedAt)。

```sh
hvm-cli status ubuntu
hvm-cli status ubuntu --format json
```

注意:加密 VM 走 routing JSON 拿基础信息 (displayName/id/scheme/KDF),不解密;运行中可从 IPC payload 补 guestOS/cpu/mem;并提示 `hvm-cli encrypt-status` 看详细加密信息。

### `start` — 启动 VM (后台,立即返回)

`HostLauncher.launch` 后台拉起 VMHost,打印 pid + 日志目录。加密 VM 会 prompt 密码并经 stdin Pipe 透传给子进程。

参数:`--password-stdin` — 从 stdin 读一行作密码 (脚本用),不设则 tty prompt。

```sh
hvm-cli start ubuntu
echo "$PW" | hvm-cli start enc-vm --password-stdin    # 脚本模式
```

注意:VM 已运行 (锁被占) 抛 `bundle.busy`。加密 VM 不解密,走 routing JSON 拿 displayName/id 用于日志路径;`--password-stdin` 读到空行抛 `config.missing_field`。

### `stop` — 软关机 (ACPI shutdown)

`VMControl.stop` 发 ACPI shutdown,等 guest 自己收尾,guest 关机后 VMHost 自动退出。

```sh
hvm-cli stop ubuntu
```

### `kill` — 强制关机 (拔电源,可能丢数据)

`VMControl.kill` 强制终止。**破坏性**:human 模式默认二次确认 (`[y/N]`),`--force` 跳过。

```sh
hvm-cli kill ubuntu          # 会问 y/N
hvm-cli kill ubuntu --force
```

注意:早探 — 未运行 / socket 缺失先抛 `ipc.socket_not_found`,不进确认 prompt。

### `pause` / `resume` — 暂停 / 恢复

`pause` 发 `IPCOp.pause` 让 vCPU 挂起 (内存保留);`resume` 发 `IPCOp.resume` 恢复。两者都要求 VM 在跑 (socket 存在),否则抛 `ipc.socket_not_found`。

```sh
hvm-cli pause ubuntu
hvm-cli resume ubuntu
```

### `delete` — 删除 VM bundle

默认移废纸篓;`--purge` 彻底删除 (二次确认,`--force` 跳过)。

参数:`--purge` 彻底删除不经废纸篓;`--secure-erase` 单 pass random 覆写整 bundle (防 APFS free block 取证);`--force` 跳过确认。

```sh
hvm-cli delete ubuntu             # 移废纸篓
hvm-cli delete ubuntu --purge     # 彻底删,问 y/N
hvm-cli delete enc-vm --purge     # 加密 VM purge 默认自动 secure-erase
```

注意:**加密 VM + `--purge` 默认走 secure-erase**;明文 VM 加 `--secure-erase` 也强制 erase。走 `VMControl.delete` (含 running 互斥)。

### `clone` — 整 VM 克隆

`CloneManager.clone` 走 APFS clonefile (COW) + 身份字段重生 (id / displayName / 数据盘 uuid8 / MAC)。

参数:`--name <显示名>` (必填,1-64 字符,不允许 `/` 或 NUL);`--target-dir <dir>` (缺省 = 源父目录);`--keep-mac` 保留所有 NIC MAC (默认重生);`--force` 跳过加密 VM 二次确认。

```sh
hvm-cli clone ubuntu --name ubuntu-copy
hvm-cli clone enc-vm --name enc-copy    # prompt 源密码, 新 VM 同密码
```

注意:
- 源必须 **stopped** (抢 `.edit` 锁,与 `.runtime` 冲突抛 `bundle.busy`)。
- 必须**同 APFS 卷** (clonefile 跨卷 `EXDEV`)。
- 目标已存在抛错;任何步骤失败清目标,绝不留半成品。
- 加密源:prompt 密码 + 二次确认,新 VM **同源密码** (想换密码 clone 后自跑 `rekey`);VZ-sparsebundle 加密 clone 未实现。

### `encrypt` — 明文 VM → 加密 VM (冷迁移)

`EncryptVMOperation.encrypt` 把现有明文 QEMU VM in-place 转成加密 (主盘/数据盘 → LUKS qcow2,config → AES-GCM)。`--force` 跳过最终确认。

```sh
hvm-cli encrypt ubuntu          # 警告 + y/N, 然后 prompt 设密码
```

注意:仅 QEMU engine;VM 必须 stopped;prompt 密码 (双重,≥4 字符);**Win VM 会重置 TPM** (BitLocker/SecureBoot 信任根丢失);需要 ≈ 主盘+数据盘大小的临时空间;转换不可中断。

### `decrypt` — 加密 VM → 明文 VM (冷迁移)

`DecryptVMOperation.decrypt` 把加密 QEMU VM 转回明文 (disks 仍是 qcow2)。`--force` 跳过确认。

```sh
hvm-cli decrypt ubuntu          # 警告 + y/N + prompt 密码
```

注意:仅 QEMU 加密形态 (`qemuPerfile`),否则抛错;需 prompt 密码;需临时空间;解密**无** TPM 重置。

### `rekey` — 改密加密 VM

`RekeyVMOperation.rekey` 重写 LUKS keyslot (毫秒级,不重密 DEK) + 用新 key 重 seal config.yaml.enc + 写新 routing salt。prompt 原密码 + 新密码 (双重)。

```sh
hvm-cli rekey ubuntu            # prompt 原密码 → 新密码
```

注意:仅 QEMU 加密形态;新密码必须 ≠ 原密码;**Win VM 重置 TPM** (swtpm 0.10 无 rewrap,BitLocker recovery key 全丢,改密前请先备份)。

### `encrypt-status` — 查看加密状态 (不解密)

走 routing JSON 显示 scheme / vmId / KDF (算法/迭代/salt/keylen) / encrypted_paths,不需密码。明文 VM 显示 `encrypted=false`。

```sh
hvm-cli encrypt-status ubuntu
hvm-cli encrypt-status ubuntu --format json
```

### `boot-from-disk` — 标记只从硬盘启动

把 `config.bootFromDiskOnly = true`,下次启动不挂 ISO (装完系统后执行)。VM 必须 stopped。加密 VM 走 `EncryptedConfigEditor` (prompt 密码) in-place 改 config。

```sh
hvm-cli boot-from-disk ubuntu
```

### `iso` — 管理安装 ISO (仅 Linux guest)

- **`iso select <vm> <path>`** — 指定/替换 ISO,同时把 `bootFromDiskOnly` 关掉。ISO 路径需真实存在。
- **`iso eject <vm>`** — 弹出 ISO 并切到仅硬盘启动 (`installerISO=nil`,`bootFromDiskOnly=true`)。

```sh
hvm-cli iso select ubuntu ~/iso/ubuntu-24.04.iso
hvm-cli iso eject ubuntu
```

注意:VM 必须 stopped (VZ 不支持热挂 storage,沿用约束);仅 `guestOS == linux` 有效,否则抛 `config.invalid_enum`。加密 VM 走 `EncryptedConfigEditor`。

### `disk` — 管理磁盘

4 个子命令,改写类全部要求 VM **stopped**。命名:主盘 id = `main`,数据盘 id = uuid8 (兼容老 `.img` 与新 `.qcow2`)。

- **`disk list <vm>`** — 列所有盘 (id / role / 名义大小 / 实际占用 / path)。
- **`disk add <vm> --size <GiB>`** — 加一块数据盘 (qcow2;加密 VM 走 LUKS qcow2)。size ≥ 1。
- **`disk resize <vm> [--id <id>] --to <GiB>`** — 扩容 (只能增大;`--id` 默认 `main`)。host 侧扩容后 guest 内还需 `resize2fs` / 分区工具。
- **`disk delete <vm> --id <uuid8>`** — 删数据盘 (主盘禁删)。

```sh
hvm-cli disk list ubuntu
hvm-cli disk add ubuntu --size 32
hvm-cli disk resize ubuntu --to 128            # 扩主盘
hvm-cli disk resize ubuntu --id a1b2c3d4 --to 64
hvm-cli disk delete ubuntu --id a1b2c3d4
```

注意:加密 VM 的数据盘/扩容走 `QcowLuksFactory` (用 session 持有的 sub key),格式必须 qcow2。

### `config` — 读/改 CPU/内存

- **`config get <vm>`** — 打印 displayName / guestOS / cpu / memory (加密 VM 标 `encrypted: true`)。
- **`config set <vm> [--cpu <n>] [--memory <GiB>]`** — 改 CPU / 内存,至少给一个;VM 必须 stopped (热改 CPU/mem 不支持)。cpu ≥ 1,memory ≥ 1。

```sh
hvm-cli config get ubuntu
hvm-cli config set ubuntu --cpu 8 --memory 16
```

注意:范围合法性由下次 `start` 时 `ConfigBuilder` 校验。加密 VM 走 `EncryptedConfigEditor` (prompt 密码,中间不落明文 yaml)。

### `snapshot` — VM 整体快照 (APFS clonefile)

整 bundle (磁盘 + config) 快照,基于 clonefile,几乎零空间。create/restore 要求 VM **stopped**。

- **`snapshot create <vm> --name <名>`** — 创建 (名: 字母/数字/`-_.`,1-64 字符)。
- **`snapshot list <vm>`** — 列出 (按时间倒序)。
- **`snapshot restore <vm> <名>`** — 还原 (当前 disks/* 和 config 会被覆盖)。
- **`snapshot delete <vm> <名>`** — 删除指定快照。

```sh
hvm-cli snapshot create ubuntu --name before-upgrade
hvm-cli snapshot list ubuntu
hvm-cli snapshot restore ubuntu before-upgrade
hvm-cli snapshot delete ubuntu before-upgrade
```

### `shared-folder` — 共享目录 (SPICE WebDAV)

管理 host ↔ guest 共享目录,仅改 config (mount 在 VM 启动时由 `SpiceWebdavServer` 接管)。仅 QEMU 后端。

- **`shared-folder add <vm> <hostPath> [--name <名>] [--rw]`** — 添加。hostPath 必须绝对路径 + 真实存在的目录;`--name` 友好名 (ASCII alnum + `-_`,1-32 字符,默认取 host 目录名 sanitize);`--rw` 允许写 (默认只读)。VM 必须 stopped (chardev 不支持热挂)。
- **`shared-folder list <vm>`** — 列出。
- **`shared-folder remove <vm> <name>`** — 按 name 移除。

```sh
hvm-cli shared-folder add ubuntu /Users/me/share --name share --rw
hvm-cli shared-folder list ubuntu
hvm-cli shared-folder remove ubuntu share
```

注意:同一 VM 内 name 唯一,重名抛错;guest 内挂载点 Win 走 `\\localhost\dav`,Linux 走 GVFS `davs://localhost/`。

### `logs` — 打印 host 端日志

打印 `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/` 下的 host 侧日志 (host-*.log / qemu-stderr.log / swtpm*.log)。

参数:`--date yyyy-MM-dd` (默认今天,匹配 `host-<date>.log`);`--all` 打印所有 log 文件 (可能很大)。

```sh
hvm-cli logs ubuntu
hvm-cli logs ubuntu --date 2026-05-29
hvm-cli logs ubuntu --all
```

注意:加密 VM 走 routing JSON 拿 displayName/id (查日志不需密码)。guest serial `console-*.log` 留在 bundle 内,不归此命令 (走 `hvm-dbg console`)。

---

## 3. 全局选项 / 输出格式

几乎所有子命令都带 `--format human | json` (`OutputFormat`,`ExpressibleByArgument`):

- **`human`** (默认) — 人类可读文本,含 ✔/⚠ 符号、表格、进度条。
- **`json`** — pretty JSON,字段稳定,方便 pipe 给 `jq`。错误也以 JSON 结构输出 (见 §5)。

注意:
- `list --watch` 在 json 模式下**不**做 ANSI 清屏 (方便 pipe);human 模式才清屏。
- `osimage fetch --follow` 仅在 json 模式生效 (流式每帧进度)。
- 进度类输出 (osimage 下载) 由 `ProgressTracker` 做步进过滤,避免 json 刷屏。
- 全局开关 `--engine` 仅 `create` 有 (恒 qemu);其余命令无后端参数 (单后端)。

---

## 4. 加密 VM 密码输入

加密 VM 的所有操作 (start / encrypt / decrypt / rekey / config / disk / iso / boot-from-disk / clone) 需要密码,统一走 `PasswordPrompt`:

- 底层 BSD `readpassphrase(3)`,带 `RPP_REQUIRE_TTY` — **强制 tty**、关闭终端 echo (不回显字符),防止密码被打进日志/历史。
- `confirm: true` 时要求二次确认 (创建 / encrypt / rekey 设新密码用),两次不一致抛错。
- 设密码场景有最小长度 (`minLength: 4`)。
- **不缓存到 Keychain**,每次操作都重新输入。

脚本/非交互场景:仅 `start` 提供 `--password-stdin`,从 stdin 读一行作密码 (经 stdin Pipe 透传给 VMHost 子进程);读到空行抛 `config.missing_field`。其余加密命令均走 tty prompt,无 stdin 路径。

```sh
hvm-cli start ubuntu                          # tty prompt: "密码 (ubuntu): "
echo "$PW" | hvm-cli start enc-vm --password-stdin
```

---

## 5. 退出码模型

错误模型基于 `HVMError` / `ErrorCodes` (见 [ARCHITECTURE.md](ARCHITECTURE.md) HVMCore 节)。每个 `HVMError` 有稳定的 `code` 字符串 (如 `bundle.not_found` / `config.missing_field`),`bail` / `bailJSON` (`HVMUtils/CliExit.swift`) 渲染输出并按 hvm-cli 自己的映射 (`Support/OutputFormat.swift` 的 `exitCode(for:)`) 退出。

| 退出码 | 触发 code 前缀 | 含义 |
| --- | --- | --- |
| `0` | — | 成功 |
| `1` | (其他/未识别) | 通用失败 |
| `2` | `config.` | 配置/参数错误 (缺字段、非法枚举、密码不符等) |
| `3` | `bundle.not_found` | VM/bundle 未找到 |
| `4` | `bundle.busy` / `backend.disk_busy` | VM 正在运行 / 资源被占 |
| `5` | `backend.invalid_transition` | 非法状态切换 |
| `6` | `ipc.timed_out` | IPC 超时 |
| `10` | `backend.` (其余) | 后端 (QEMU/HVF) 错误 |

输出形态:

- **human 模式** (`bail`) — stderr 打印 `错误: <message>` + `code:` + 各 `details` + `建议:` (若有 hint),再按上表 exit。
- **json 模式** (`bailJSON`) — stdout 输出 `{"error": {"code", "message", "details", "hint"}}`,再按上表 exit。

```sh
hvm-cli status nonexistent; echo "exit=$?"     # exit=3 (bundle.not_found)
hvm-cli config set ubuntu; echo "exit=$?"      # exit=2 (缺 --cpu/--memory)
hvm-cli start running-vm; echo "exit=$?"       # exit=4 (bundle.busy)
```

> 备注:ArgumentParser 自身的参数解析错误 (拼写错的 flag、非法枚举值如 `--engine foo` / `--os macos`、缺必填项) 在 parse 阶段就被拦下,走 ArgumentParser 默认退出码 (通常 `64`),不进上面的 `exitCode(for:)` 映射。

---

## 附:引用源文件

- 入口 / 子命令注册:`app/Sources/hvm-cli/HvmCli.swift`
- 子命令实现:`app/Sources/hvm-cli/Commands/*.swift` (21 个顶层命令 + 子命令)
- 支撑代码:`app/Sources/hvm-cli/Support/{OutputFormat,PasswordPrompt,BundleResolve,EngineArgument,EncryptedConfigEditor,ProgressTracker}.swift`
- 退出/错误渲染:`app/Sources/HVMUtils/CliExit.swift`
- 错误模型:`HVMCore` (`HVMError` / `ErrorCodes`,见 `docs/ARCHITECTURE.md`)
