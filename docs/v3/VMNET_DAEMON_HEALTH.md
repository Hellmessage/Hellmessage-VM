# VMNET_DAEMON_HEALTH — vmnet daemon 健康监控 + 一键重启

状态: **代码已合入** (2026-05-23)
PR 拆解一次性合 (改动小, 跨 4 件事但内聚)

合入清单:
- `scripts/install-vmnet-daemons.sh` 加 `--restart` 子命令 (`restart_all` 函数)
- `VMnetSupervisor.restartAllDaemons()` (走 osascript admin)
- `StatusBarVmnetPopup` + `VMSettingsNetworkSection+VmnetDaemon` 两处 GUI 加 `[重启 daemon]` 按钮
- `HVMCore/VMnetBridgeProbe.swift` (响应性探测 — 不抓 silent bridge死, 见 R5)
- `HVMQemu/QemuHostEntry` 启 VM 前调 probe, 仅 warn 不阻断
- 回写: `CLAUDE.md` (socket_vmnet 约束加 "daemon 在 ≠ bridge 在") + `docs/v1/NETWORK.md` ("重启 daemon" 路径 + probe 现状)

## 背景

2026-05-23 实测排查 "桥接 VM 拿不到 DHCP" 问题. 根因:

- socket_vmnet bridged en10 daemon 进程在跑, plist 在, unix socket 文件在
- 但 vmnet.framework 内核侧 en10 bridge attach 状态死了 (反复 bootout 留下的残留)
- 表现: QEMU 能连上 socket, 帧发进去, 但帧不真正打到物理 en10 (tcpdump 30 秒, 0 帧 from guest MAC)
- 修复手段: bootout + bootstrap daemon 一次, 整 bridge 立刻活

`9ea4c08` 那个幂等 install fix 反而在这种场景**绕开**了救场路径 — 它检查 plist 字节一致 + daemon 在 launchctl 视图 + socket 在 → 跳过, 不动 daemon. 但 daemon 在跑 ≠ bridge 在通.

## 目标 + 范围

**目标**: 用户撞这种 "daemon 看起来好, bridge 实际死" 时, 不用走 sudo launchctl 命令行也能自救.

**做**:
1. install-vmnet-daemons.sh 加 `--restart` 子命令, 强制 bootout + bootstrap 所有已装 daemon (区别于 idempotent install)
2. VMnetSupervisor 加 `restartAllDaemons()` (osascript admin)
3. GUI: 状态栏 vmnet popup + VM 设置网络面板, 都加 "重启 daemon" 按钮 (位于 "卸载全部" 旁边)
4. 启 VM (`vmnetBridged` 模式) 前轻量自检: 连 unix socket + 被动听 2 秒, 0 字节回来时打 warning 日志 + 继续 (不阻塞启动 — 误判风险高, 只提示)

**不做**:
- 自动周期巡检 / 后台监控 (无业务诉求, 引入复杂度)
- 自动恢复 (检测到 bridge 死自动 osascript 重启) — 不弹 Touch ID 弹得用户烦, 留 manual
- shared / host 模式的健康探测 (它们没"对应物理 iface"概念, 大概率不会撞同样问题; 真撞了一键重启按钮也能修)
- 跨 VM 实时桥状态推送 (太重)

## 选型对比

### 子题 A: 重启 daemon 的脚本方式

| 方案 | tradeoff |
|---|---|
| **A1: `--restart` 子命令** (选) | 复用现有 `--uninstall` 路径模式, plist 留着不删, 重新 bootstrap; 跟 install 区分清晰 |
| A2: 在 install_one 加 `--force` flag | install 路径已经够复杂, 再叠状态机难维护; 现在的幂等检查反而是 feature, 不该污染 |
| A3: GUI 直接 osascript 调 launchctl bootout/bootstrap, 不走脚本 | 把 launchctl 命令拼到 Swift 里, 跟脚本里的清理 + 重试逻辑 (bootout 双语法 / sleep / err5 重试) 重复; 维护两份 |

### 子题 B: 启 VM 前 bridge 健康探测

| 方案 | tradeoff |
|---|---|
| **B1: 被动监听 2s + 看是否有任何字节回来** (选) | 实现简单 (just connect + read with timeout); 桥活时 LAN 上 mDNS / SLAAC RA / ARP 等广播每几秒一定有, 桥死时 0 字节 |
| B2: 主动发探测帧 + 配 host 端 echo | 协议层做不到 — vmnet daemon 没 echo 语义, 桥另一端是真物理网络, 我们不能保证有 listener |
| B3: tcpdump en10 自检 (需 sudo) | 走 osascript 弹 Touch ID 太重, 用户体验差; 启 VM 频繁触发不可接受 |

### 子题 C: 探测失败时的行为

| 方案 | tradeoff |
|---|---|
| **C1: 打 warning 日志 + 继续启动** (选) | 探测有误判风险 (LAN 真的安静 2s 完全可能); 阻塞启动会误伤 |
| C2: 弹对话框问"要不要重启 daemon", 选 yes 才继续 | 体验差, 启动加 osascript 弹窗这条路径不友好 |
| C3: 自动重启 daemon + 重试 | 同 C2, 自动 osascript 太烦 |

## 实现要点

### 1. scripts/install-vmnet-daemons.sh `--restart`

新加 `restart_all` 函数 + 顶层 dispatch:

```bash
restart_all() {
    shopt -s nullglob
    local restarted=0
    for plist in "$PLIST_DIR"/${LABEL_PREFIX}.*.plist; do
        local label
        label=$(basename "$plist" .plist)
        # 推 socket 路径 (shared / host / bridged.<iface>)
        local suffix=${label#${LABEL_PREFIX}.}
        local sock
        if [ "$suffix" = "shared" ]; then
            sock="$SOCKET_BASE"
        else
            sock="$SOCKET_BASE.$suffix"
        fi
        # 走跟 install_one 同样的破坏性路径 (含 err5 retry)
        echo "==> 重启 $label"
        launchctl bootout "system/$label" 2>/dev/null || true
        launchctl bootout system "$plist" 2>/dev/null || true
        sleep 0.5
        rm -f "$sock"
        if ! launchctl bootstrap system "$plist" 2>/tmp/hvm-vmnet-bootstrap.err; then
            # 失败重试 1 次
            launchctl bootout "system/$label" 2>/dev/null || true
            launchctl bootout system "$plist" 2>/dev/null || true
            sleep 1
            if ! launchctl bootstrap system "$plist"; then
                echo "    ✗ $label bootstrap 二次仍失败" >&2
                return 1
            fi
        fi
        rm -f /tmp/hvm-vmnet-bootstrap.err
        echo "    ✓ $label"
        restarted=$((restarted + 1))
    done
    echo "==> 共重启 $restarted 个 daemon"
}

if [ "${1:-}" = "--restart" ]; then
    restart_all
    exit 0
fi
```

### 2. VMnetSupervisor.restartAllDaemons()

```swift
public static func restartAllDaemons() async throws {
    let script = try scriptPath()
    try await runWithAdminPrivileges(args: [script, "--restart"])
}
```

### 3. GUI 按钮

- `VMSettingsNetworkSection+VmnetDaemon.swift`: 在 [安装/更新 daemon] [卸载全部] 之间加 [重启 daemon]
- `StatusBarVmnet.swift` 的 `StatusBarVmnetPopup`: 同上
- 按钮文案 + icon: SF "arrow.clockwise.circle"; busy 时显示 "正在重启…"

### 4. 启 VM 自检

新文件 `app/Sources/HVMQemu/VMnetBridgeProbe.swift` (放 HVMQemu 因为它跟 socket_vmnet 通路绑定):

```swift
public enum VMnetBridgeProbe {
    public enum Result: Sendable {
        case ok(framesSeen: Int)
        case silent     // 连上但 timeout 内 0 字节
        case noSocket   // socket 文件不存在
        case connectFail(Error)
    }

    /// 被动探测: connect unix socket, 听 listenMs 毫秒, 数收到多少字节. 不发任何数据.
    public static func probe(socketPath: String, listenMs: Int = 2000) async -> Result {
        // 1. stat 检查
        // 2. POSIX socket(AF_UNIX, SOCK_STREAM, 0) + connect
        // 3. select() 等可读 / 总超时
        // 4. read() 字节计数, 不解码 4-byte length-prefix (不需要语义, 只数活)
        // 5. close
    }
}
```

调用点: `app/Sources/HVMQemu/VMHost.swift` (或 QemuHostEntry 的 VM 启动 flow) — 在 QEMU 进程拉起 **之前**, 对每张 `vmnetBridged` 模式 NIC 跑一次 probe. 结果 `.silent` 时:

```
log.warn("vmnet bridge en10 probe silent — bridge 可能已死, 试试 [状态栏 vmnet → 重启 daemon] (sock=\(sock))")
```

不阻断启动. 用户撞到没网时, 翻 host log 能看到这条 hint.

## 风险与待验证

- **R1**: `--restart` 路径会断**所有**已连 VM 的网络 (跟 install 老路径同样问题). 必须文案明示 "会中断当前正在用 vmnet 的 VM, 启动中的 VM 可能丢网"
- **R2**: 被动 2s probe 在极安静 LAN 上误判. 默认只 warn 不阻断, 风险可控
- **R3**: probe 连 socket 本身可能多创一个 fd connection, 跟 socket_vmnet daemon 的 max client 数无关 (daemon 默认无上限, 不会冲突)
- **R4**: probe 在 shared/host 模式没意义 (没物理桥) — 实现里只对 `vmnetBridged` 触发
- **R5** (落码期发现, 设计变更): **silent bridge死无法 from user-space 可靠探测**. 实测 (2026-05-23 测试机器, en10 桥):
  - 纯被动 nc -U 监听 30s, 0 字节回来 — 即使桥是活的, 同时 QEMU client 在正常用网络
  - 主动发 ARP probe (源 MAC `02:00:48:56:00:01`) 后再 listen 2s, 仍然 0 字节 (sudo tcpdump 物理 iface 确认 ARP 帧成功到达 en10, 出向桥工作)
  - 结论: `socket_vmnet` 不把入向 LAN 广播 / 多播帧转给被动 / 短连客户端 (实际行为跟我们假设的 "MAC 学习后会广播给所有 client" 不一样, 可能跟 lima native 协议 vs QEMU stream 协议有关, 也可能是 vmnet.framework 多播 IGMP 过滤)
  - **设计变更**: probe 从"听入向帧" 改成"测 daemon 响应性" (connect + write 一帧 + 200ms 检 hangup). 抓 daemon 死 / socket 孤儿 / 协议错配 — 但**不抓** silent bridge死. 后者由用户感知 (VM 没 DHCP) → 走 `[重启 daemon]` 自救
  - 想真探 silent bridge死, 需要 sudo tcpdump 物理 iface, 不适合放主进程; 留 D5 hvm-cli vmnet doctor 后续单独提案

## P0 must-pass gate (落码后实测结果)

- ✅ `make build` 通过 (sonnet 28.7s, hvm-cli 10.8s, hvm-dbg 2.8s)
- ✅ `make install` 后, 设置面板 + 状态栏 popup 都能看到 [重启 daemon] 按钮 (screenshot 确认)
- ✅ `sudo bash install-vmnet-daemons.sh --restart` 跑通: 5 个 daemon 全部 bootout + bootstrap, pid 全变 (306/307/308/309/6782 → 17742/17765/17792/17802/17818)
- ✅ 重启过程中**不删 plist 文件** (区别于卸载, 实测确认)
- ✅ 桥模式 VM 启动时 host log 有 `✔ vmnet daemon probe NIC#0 (...) 响应正常` 记录
- ✅ VM 启动后拿到 IP `192.168.110.100`, snapd 走公网 — 桥完整通路验证 OK
- ⚠️ 已知限制 (R5): silent bridge死从 user-space 不可探, 仅依赖用户感知 + 手动 [重启 daemon]

## 决策

| ID | 决策点 | 默认 | 决策时机 |
|---|---|---|---|
| D1 | 是否做 shared/host 模式 probe | 不做 — 它们没物理桥可死 | 立即 |
| D2 | 是否做自动重启 | 不做 — 用户主动点 | 立即 |
| D3 | probe 失败弹对话框 vs 仅日志 | 仅日志 + GUI 状态栏 banner 是后续工作 | 立即, 仅 log |
| D4 | restart 是否要带 "等 daemon ready" 反馈 | osascript 同步 wait + 完成后 GUI 刷 sockets 状态; 简单 | 立即 |
| D5 | 加 `hvm-cli vmnet doctor` CLI 子命令? | **不做** (本次范围外, 后续单独提案) | 后续 |

## 落地拆解 (合一 PR)

| 步骤 | 改动 | 验收 |
|---|---|---|
| 1 | `scripts/install-vmnet-daemons.sh` 加 `restart_all` 函数 + `--restart` dispatch | sudo bash scripts/install-vmnet-daemons.sh --restart 跑通, 所有 daemon pid 变 |
| 2 | `VMnetSupervisor.restartAllDaemons()` | 单元手测: GUI 触发 → Touch ID → 通过 |
| 3 | `VMSettingsNetworkSection+VmnetDaemon` + `StatusBarVmnet` 两处 UI 加按钮 | GUI 看见 + 点能触发 |
| 4 | `HVMQemu/VMnetBridgeProbe.swift` + 启 VM 流程钩入 | host log 有探测结果 |
| 5 | bundle.sh 自动拷新版脚本进 .app/Resources/scripts/ (无新改, 现状已支持) | make install 后 .app 里脚本是新版 |
| 6 | CLAUDE.md "socket_vmnet 网络约束" 节加一行: "daemon 在 + bridge 仍可能死 → 走 [重启 daemon] 而不是 [安装/更新]" | docs 同步 |
| 7 | docs/v1/NETWORK.md 现状回写 "重启 daemon" 路径 + "bridge silent" 现象 | docs 同步 |

**状态**: 已合入 `develop` 分支 2026-05-23, 等用户跑实际场景验证.

## 追加: QEMU `-netdev stream` reconnect-ms 自愈 (2026-05-24)

用户实际跑 [重启 daemon] 流程时撞到一个体验问题: daemon 重起 ≈ 已连 VM 的 unix socket 也跟着断, QEMU 默认行为是 socket 死了就放着不重连, NIC 直接报废, 用户必须停 + 启 VM. 这条限制原本卡死了"重启 daemon" 按钮的实用性 — 谁也不想为了修一个 VM 的网, 把其他 VM 也连累停掉.

**修复**: QEMU 7.2+ 给 `-netdev stream` 加了 `reconnect-ms=<ms>` 选项 (我们 10.2.0 自带), socket 断开后按毫秒数自动重连. 把 `reconnect-ms=2000` 直接拼进 argv:

```
-netdev stream,id=net0,addr.type=unix,addr.path=/var/run/socket_vmnet.bridged.en10,reconnect-ms=2000
```

**端到端实测** (2026-05-24, Ubuntu 24.04 guest, en10 桥, 192.168.110.0/24 LAN):

- guest 内启 `ping -c 30 -i 1 192.168.110.1`
- t=4s 时 host 跑 `sudo install-vmnet-daemons.sh --restart` (重启全部 5 个 daemon, 总耗时 ≈12s)
- 结果: **30 个 ping 中 28 个收到, 仅丢 seq=1,2 (ping 启动 ARP, 跟 daemon 无关). daemon 重启的 12s 里 ping seq=5..15 全部正常收到, 0 丢包**
- 用户视角: VM 完全感知不到 daemon 重起

机制: QEMU `-netdev stream` 客户端 socket 断 → 每 2s 重连 → daemon 0.3-0.5s 内 bootstrap 完成 → QEMU 下一次 retry 命中, 链路恢复. 加上 virtio-net buffer + guest 内核 ARP / lease 缓存, 重启窗口透明.

**为什么不早做**: `9ea4c08` (idempotent install) 的设计前提就是"避免重起 daemon", 因为当时 QEMU 没有 reconnect. 这条 fix 出来后, 现在两边都安全了: install 仍然 idempotent (不必要时不重启), `[重启 daemon]` 主动按了也不连累 running VM.

**进一步**: 这条 fix 让 `--restart` 路径从"必须确认中断 VM" 变成"几乎无副作用" — 用户撞 silent-bridge 时点按钮没心理负担. 也意味着 R1 中的"会断已连 VM 网络"风险大幅降级 (仍有 1-2 秒包延迟, 但 TCP 连接基本不断, 长连接的 SSH / 数据库 / SSE 全部保留).
