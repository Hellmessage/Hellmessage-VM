# CLI 设计 (`hvm-cli`)

## 目标

- 为自动化脚本 / CI / 终端重度用户提供 GUI 之外的 VM 管理入口
- 与 GUI 共享同一套 HVM* 模块, 不维护两套逻辑
- 子命令层级清晰, 输出可机读(`--format json`)

## 定位

- `hvm-cli` 是短命进程: 每次执行做完事就退, 不常驻
- 不是 daemon: HVM 不提供后台服务, CLI 要么直接操作 bundle, 要么对已有 `HVMHost` 进程发 IPC
- GUI 和 CLI **没有主从关系**: CLI 启动的 VM, GUI 也能看到(靠扫描 `~/Library/Application Support/HVM/VMs/`); GUI 启动的 VM, CLI 也能对它下命令(靠读 `.lock` 里的 socket path)

## 全局选项

```
hvm-cli [OPTIONS] <subcommand> [ARGS...]

全局选项:
  --format <human|json>    输出格式, 默认 human
  --quiet, -q              静默模式, 只输出结果, 不输出进度
  --verbose, -v            详细输出, 显示内部日志
  --bundle-dir <path>      覆盖默认 bundle 搜索目录(默认 ~/Library/Application Support/HVM/VMs)
  --help, -h               显示帮助
  --version                显示版本
```

## 子命令总览

```
hvm-cli list                        列出所有 VM
hvm-cli create                      创建新 VM
hvm-cli delete <vm>                 删除 VM
hvm-cli start <vm>                  启动 VM
hvm-cli stop <vm>                   停止 VM (软关机)
hvm-cli kill <vm>                   强制关机
hvm-cli pause <vm>                  暂停
hvm-cli resume <vm>                 恢复
hvm-cli status <vm>                 显示单 VM 详情
hvm-cli config <vm> [get|set]       读/改配置
hvm-cli disk <vm> <op>              磁盘操作
hvm-cli snapshot <vm> <op>          快照操作
hvm-cli iso select <vm> <path>      指定安装 ISO
hvm-cli boot-from-disk <vm>         切 bootFromDiskOnly=true
hvm-cli logs <vm>                   查看日志
hvm-cli install <vm>                驱动装机流程 (macOS IPSW / Linux ISO)
```

## 命令详解

### `list`

```
hvm-cli list [--format json]
```

human 输出:

```
NAME           GUEST    STATE     CPU  MEM    DISK(main)  BUNDLE
foo            linux    running   4    8G     12G/64G     ~/VMs/foo.hvmz
ubuntu-2404    linux    stopped   4    4G     —/64G       ~/VMs/ubuntu-2404.hvmz
macOS-seq      macOS    paused    8    16G    45G/128G    ~/VMs/macOS-seq.hvmz
```

json 输出:

```json
[
  {
    "name": "foo",
    "id": "4F8E2B1A-...",
    "guestOS": "linux",
    "state": "running",
    "cpuCount": 4,
    "memoryMiB": 8192,
    "mainDisk": { "logicalGiB": 64, "actualGiB": 12 },
    "bundlePath": "/Users/me/VMs/foo.hvmz",
    "pid": 48201
  }
]
```

### `create`

非交互式:

```
hvm-cli create \
  --name ubuntu-2404 \
  --os linux \
  --cpu 4 \
  --memory 8 \
  --disk 64 \
  --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso \
  --network nat \
  --path ~/VMs/
```

选项:

| 选项 | 必填 | 说明 |
|---|---|---|
| `--name` | 是 | 显示名, 也是 bundle 目录名(会加 `.hvmz`) |
| `--os` | 是 | `macOS` / `linux` |
| `--cpu` | 否 | 默认物理核心数一半 |
| `--memory` | 否 | GiB 单位, 默认 4 |
| `--disk` | 否 | 主盘大小 GiB, 默认 64 |
| `--iso` | linux 必填 | 绝对路径, 不复制进 bundle |
| `--ipsw` | macOS 必填 | 绝对路径 |
| `--network` | 否 | `nat`(默认) / `bridged:en0` |
| `--path` | 否 | 父目录, 默认 `--bundle-dir` |
| `--mac` | 否 | 手指 MAC, 默认随机生成 |

交互式(省略必填时进入向导):

```
$ hvm-cli create
? VM 名称: ubuntu-test
? Guest OS: linux
? CPU 核心数: 4
? 内存 (GiB): 8
? 主盘 (GiB): 64
? 安装 ISO 路径: ~/Downloads/ubuntu-24.04-live-server-arm64.iso
? 网络模式: nat
? Bundle 父目录: ~/Library/Application Support/HVM/VMs
✔ 已创建 ubuntu-test.hvmz (未启动)
  下一步: hvm-cli start ubuntu-test
```

### `delete <vm>`

```
hvm-cli delete foo                      # 移入废纸篓
hvm-cli delete foo --purge              # 彻底 rm -rf, 需加 --force
hvm-cli delete foo --purge --force
```

VM 处于 running/paused 时拒绝, 提示先 stop。

### `start <vm>`

```
hvm-cli start foo                       # 后台启动, 立即返回
hvm-cli start foo --wait                # 等 guest ACPI ready 再返回
hvm-cli start foo --wait --timeout 60   # 超时 60s
```

实现:

```
1. 检查 bundle/.lock, 已被锁且 PID 存活 → 报错 "已在运行"
2. fork HVM.app 自己, 带 argv: --host-mode --bundle /path/to/foo.hvmz
3. HVMHost 启动成功后写 .lock
4. CLI 立即退出(除非 --wait)
```

--wait 模式: CLI 订阅 VMHost 的 state stream, 等到 `.running` 再退。

### `stop <vm>` / `kill <vm>`

```
hvm-cli stop foo                        # 软关机, 默认 60s 超时后自动升级为 kill
hvm-cli stop foo --timeout 120          # 延长超时
hvm-cli kill foo                        # 直接强制关机
```

### `pause <vm>` / `resume <vm>`

挂起不写磁盘, 进程退出即失效(MVP 限制)。

### `status <vm>`

```
hvm-cli status foo

foo (Linux · ubuntu-2404)
  id:         4F8E2B1A-0B25-44C1-9A2E-9E58CBE2D43C
  state:      running
  uptime:     1h23m
  pid:        48201
  cpu:        4 cores
  memory:     8 GiB
  disk main:  /path/to/foo.hvmz/disks/main.img (12 GiB used / 64 GiB)
  network:    nat · 02:AB:CD:EF:12:34
  ip (guest): 192.168.64.5 (via agent, agent online)
  bundle:     ~/VMs/foo.hvmz
  log:        ~/Library/Application Support/HVM/logs/2026-04-25.log
```

json 结构同 list 但单对象。

### `config <vm>`

读取单字段:

```
hvm-cli config foo get cpu
4

hvm-cli config foo get memory
8192
```

写入(VM 必须 stopped):

```
hvm-cli config foo set cpu 8
hvm-cli config foo set memory 16
hvm-cli config foo set displayName "my ubuntu"
```

批量:

```
hvm-cli config foo show --format json      # 等价 status 的 config 部分
```

### `disk <vm>`

```
hvm-cli disk foo list                      # 列主盘和数据盘
hvm-cli disk foo grow --role main --to 128 # 扩容主盘到 128 GiB (VM 必须 stopped)
hvm-cli disk foo add --size 100            # 加数据盘 100 GiB, 自动命名 data-<uuid8>.img
hvm-cli disk foo remove data-4f8e2b1a      # 移除数据盘
```

提醒: 扩容后 host 侧完成, guest 内仍需用户自己 `resize2fs`, CLI 在扩容成功后打印提示文本。

### `snapshot <vm>`

```
hvm-cli snapshot foo create --label before-upgrade
# 创建 disks/main.img.before-upgrade (APFS clonefile, VM 必须 stopped)

hvm-cli snapshot foo list
before-upgrade    2026-04-25 03:10  12 GiB
weekly            2026-04-20 08:00  11 GiB

hvm-cli snapshot foo delete before-upgrade
# 删除快照文件

hvm-cli snapshot foo restore before-upgrade
# 等价 mv main.img main.img.corrupted && mv main.img.before-upgrade main.img
# 二次确认
```

### `iso select <vm> <path>`

```
hvm-cli iso select foo ~/Downloads/debian-13-arm64.iso
# 写 config.installerISO, 下次启动会挂载
```

### `boot-from-disk <vm>`

```
hvm-cli boot-from-disk foo
# 写 config.bootFromDiskOnly=true, 下次启动不挂 ISO
```

### `logs <vm>`

```
hvm-cli logs foo                           # 打印今天的日志
hvm-cli logs foo --follow                  # tail -f
hvm-cli logs foo --date 2026-04-20         # 历史
hvm-cli logs foo --all                     # 全部, 谨慎使用
```

### `install <vm>`

高层装机入口:

```
hvm-cli install foo
```

根据 `guestOS` 分派:

- **macOS**: 检查 `macOS.ipsw` → 调 `VZMacOSInstaller` → 进度条 → 完成后写 `autoInstalled=true`, `bootFromDiskOnly=true`
- **Linux**: 启动 VM 挂 ISO → 让用户自己在 guest 内完成安装流程(CLI 只是帮起 VM, 不自动按键) → 安装完毕用户执行 `hvm-cli boot-from-disk foo` 切回硬盘启动

详见 [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md)。

## 输出格式

### human 模式

- 表格用等宽对齐, 不超 120 列
- 颜色: 状态列用 ANSI color(红/绿/黄), 通过 `isatty()` 判断, 管道输出自动关掉
- 单位: GiB / MiB 带单位, 不输出纯字节
- 进度: 长时操作用 `▰▰▰▱▱▱ 50%` 风格, 单行刷新

### json 模式

- 标准 JSON, 一行或缩进 2 空格均可, 默认 2 空格
- 字段名 lowerCamelCase
- 所有字节量用 `MiB` / `GiB` 为单位的 Int, 避免 Float 精度问题
- 错误也走 JSON:

```json
{
  "error": {
    "code": "bundle.busy",
    "message": "bundle 被另一个进程占用",
    "details": { "pid": 47820, "since": "2026-04-25T03:10:00Z" }
  }
}
```

## VM 定位: name vs. path

命令参数里的 `<vm>` 解析顺序:

1. 如果是绝对路径且指向 `.hvmz` 目录 → 直接用
2. 如果是相对路径且存在 → 用
3. 否则当 name 解析: `<bundle-dir>/<name>.hvmz`
4. 若有歧义(多个同名 bundle 在不同目录)报错, 要求用路径

## 退出码

| code | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 通用错误 |
| 2 | 参数错误 / 用法错误 |
| 3 | bundle 未找到 |
| 4 | bundle 被占用 |
| 5 | VM 状态不允许当前操作(例: stop 已停止的 VM) |
| 6 | 超时 |
| 10 | VZ 内部错误 |
| 64 | 未实现(功能占位) |

## shell 补全

```
hvm-cli --generate-completion zsh > ~/.zsh/completions/_hvm-cli
hvm-cli --generate-completion bash > ~/etc/bash_completion.d/hvm-cli
hvm-cli --generate-completion fish > ~/.config/fish/completions/hvm-cli.fish
```

由 `swift-argument-parser` 自带, 无需自写。

## 自动化脚本示例

```bash
#!/usr/bin/env bash
set -euo pipefail

# 起一台一次性 Ubuntu 跑测试
hvm-cli create --name ci-temp --os linux --cpu 4 --memory 4 \
               --disk 32 --iso /srv/ubuntu-24.04-arm64.iso
hvm-cli start ci-temp --wait --timeout 300

# 通过 guest agent 跑命令 (经 hvm-dbg)
hvm-dbg exec ci-temp -- /bin/bash -c "cd /src && make test"

# 清理
hvm-cli stop ci-temp
hvm-cli delete ci-temp --purge --force
```

## 与 GUI 的协同

- CLI 操作完立即推送 IPC 事件, GUI 若打开会自动刷新
- GUI 启动的 VM, CLI 可以 stop/status, 靠读 `.lock` 里的 socket 连 `HVMHost`
- CLI 不提供"切换到 GUI 打开窗口"的能力, 用户自己去主 GUI 里点

## 不做什么

1. **不做交互式 REPL / shell 模式**: 每次 `hvm-cli` 做一件事就退出
2. **不做彩色主题配置**: ANSI 默认, 不暴露配色
3. **不做别名**: 不支持 `hvm-cli ls`/`ps` 这种 git-style 别名
4. **不做远程管理**: 不支持通过 CLI 连别的 Mac 上的 HVM

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| G1 | 是否支持 `hvm-cli exec` 直接跑命令(不通过 hvm-dbg) | 不做, 职责分离, exec 走 hvm-dbg | 已决 |
| G2 | `create` 是否支持"批量从 YAML" | MVP 不做, 单命令足矣 | 有实际需求再说 |
| G3 | `--format` 是否支持 yaml | 不做, JSON 足够 | 已决 |

## 相关文档

- [DEBUG_PROBE.md](DEBUG_PROBE.md) — `hvm-dbg`, 与 CLI 职责分工
- [GUEST_OS_INSTALL.md](GUEST_OS_INSTALL.md) — `install` 子命令背后的流程
- [VM_BUNDLE.md](VM_BUNDLE.md) — config 字段语义

---

**最后更新**: 2026-04-25
