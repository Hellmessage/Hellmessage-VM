# 网络 (socket_vmnet 桥接 / 共享)

> 现状文档 — 描述当前代码 (QEMU 单后端) 的网络实现。VZ 后端及其 networking entitlement
> (`com.apple.vm.networking` / `VZBridgedNetworkDeviceAttachment`) 已随 VZ 整条移除,
> 现存唯一联网通路是 QEMU `-netdev` + 系统级 `socket_vmnet` daemon。

涉及源文件:

- `app/Sources/HVMBundle/VMConfig.swift` — `NetworkMode` / `NICModel` / `NetworkSpec` (config.yaml 持久化字段 + socket 路径推导)
- `app/Sources/HVMCore/SocketPaths.swift` — 固定 socket 路径常量 + 就绪检测
- `app/Sources/HVMCore/NetworkInterfaces.swift` — `HostNetworkInterfaces` 枚举宿主可桥接网卡 (GUI picker 数据源)
- `app/Sources/HVMCore/VMnetBridgeProbe.swift` — 启动前 daemon 响应性轻探
- `app/Sources/HVMQemu/QemuArgsBuilder.swift` — `-netdev` argv 构造 (网络段)
- `app/Sources/HVM/Services/VMnetSupervisor.swift` — daemon 安装 / 重启 / 卸载 (osascript admin)
- `app/Sources/HVM/GUI/Layout/DetailVmnetDaemonView.swift` — 详情页 vmnet daemon 面板
- `app/Sources/HVMNet/MACAddress.swift` — MAC 生成 / 校验
- `app/Sources/HVMNet/IPResolver.swift` — host ARP 表反查 guest IP
- `scripts/install-vmnet-daemons.sh` — launchd plist 写入 (root)
- 约束: `CLAUDE.md` 「socket_vmnet 网络约束」节

---

## 1. 为什么走 socket_vmnet

macOS 的 `vmnet.framework` (shared / host / bridged 三种模式底层) 要求 **root** 才能 attach。
HVM 主进程是普通用户进程, 不能直接拉 vmnet。`socket_vmnet` 把这个权限闭环拆出来:

- 一个 **系统级 launchd daemon** (`UserName=root`) 持有 vmnet attach, 对外暴露一个
  **unix domain socket**;
- HVM 启的 QEMU 子进程以普通用户身份 **连这个 socket** 收发以太网帧, 自己不碰 root。

权限只在「装 daemon」这一刻通过 Touch ID / 密码授权一次, 之后由 launchd `KeepAlive` 托管,
启 VM 不再要权限。

**socket_vmnet 二进制不打包进 `.app`** (`CLAUDE.md` 零依赖硬约束的明确例外):

- 用户机器自行 `brew install socket_vmnet`;
- `scripts/install-vmnet-daemons.sh` 从 brew 路径拉 binary 写 launchd plist
  (`find_socket_vmnet()` 探测 `/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet` 等四个候选);
- launchd plist 内 `ProgramArguments[0]` 是 socket_vmnet 的 brew 绝对路径, 与 `.app` 位置无关;
- 缺 socket_vmnet 时脚本 fail-fast, 提示 `brew install socket_vmnet`。

这条路径完全不依赖任何 VZ networking entitlement, 所有 vmnet 模式统一走 QEMU `-netdev`。

---

## 2. 网络模式

`NetworkMode` (`VMConfig.swift`, 持久化到 config.yaml 的 `networks[].mode`):

| mode | 通路 | 需要 daemon | 用途 |
| --- | --- | --- | --- |
| `user` | QEMU 内置 user-mode (SLIRP) NAT | 否 (零依赖) | **默认**, guest 能出网, host 不直连 guest |
| `vmnetShared` | socket_vmnet shared (NAT + DHCP) | 是 | guest 出网 + 多 guest 互通 + host 可达 |
| `vmnetHost` | socket_vmnet host-only | 是 | guest ↔ host 私网, 不出外网 |
| `vmnetBridged` | socket_vmnet bridged.<iface> | 是 (每 iface 一个) | guest 直接挂物理 LAN, 拿 LAN 网段 IP |
| `none` | 不挂网卡 | — | 显式断网 |

`user` 模式是真正的默认值: 零依赖、不要 daemon、不要授权, 装机阶段最稳。其余三种 vmnet 模式
才需要 socket_vmnet daemon。

config.yaml 老枚举名向后兼容 (`NetworkSpec.init(from:)`): `nat→user` / `shared→vmnetShared`
/ `hostOnly→vmnetHost` / `bridged→vmnetBridged`, 未知值兜底 `user`。

### 固定 socket 路径

由 `SocketPaths` (`HVMCore/SocketPaths.swift`) 集中, 与 socket_vmnet 上游 / lima / hell-vm 一致
(跨工具复用同一 daemon):

```
shared          → /var/run/socket_vmnet
host            → /var/run/socket_vmnet.host
bridged.<iface> → /var/run/socket_vmnet.bridged.<iface>
```

`SocketPaths.isReady(_:)` 用 `stat` 判断「文件存在 + 是 unix socket (`S_IFSOCK`)」, 启 VM 前
据此判定 daemon 是否就绪。

`NetworkSpec` 提供路径推导, **业务侧不要自己拼**:

- `effectiveSocketPath` — 用户显式填的 `socketVmnetPath` 优先, 否则按 mode 取 `SocketPaths.*`;
  `user` / `none` 返回 nil。
- `effectiveBridgedInterface` — `bridgedInterface` 为空时 fallback `en0` (历史行为)。
- `bridgedInterface` 名只允许 `[a-zA-Z0-9]+` (脚本侧白名单强制, 见 §6)。

### NIC 设备型号

`NICModel` (`deviceModel` 字段) 翻译成 QEMU `-device` 名:

| NICModel | qemuDeviceName | 备注 |
| --- | --- | --- |
| `virtio` | `virtio-net-pci` | 默认, Linux 自带驱动 / Windows 需 NetKVM |
| `e1000e` | `e1000e` | Windows ARM 开箱自带驱动 |
| `rtl8139` | `rtl8139` | 老 guest 兜底, 性能最差 |

---

## 3. QEMU 接法 (`-netdev`)

argv 在 `QemuArgsBuilder.swift` 网络段构造。逐 NIC 跳过 `enabled=false` 与 `mode==.none`。

### user 模式

```
-netdev user,id=netN
-device virtio-net-pci,netdev=netN,mac=<mac>,bus=rpN
```

### vmnet 模式 (shared / host / bridged)

```
-netdev stream,id=netN,addr.type=unix,addr.path=<sock>,reconnect-ms=2000
-device virtio-net-pci,netdev=netN,mac=<mac>,bus=rpN
```

要点:

- **直连 unix socket, 不需 wrapper**: socket_vmnet daemon 用 4-byte length-prefix framing,
  与 QEMU `-netdev stream` 协议**兼容** (lima / hell-vm 同款)。QEMU argv 直写 `addr.type=unix`
  连 daemon socket, **不需要** `socket_vmnet_client` wrapper, **不需要**父进程
  `socket()/connect()` 把 fd 透传给子进程。(老的 sidecar fd-passing 路径已下线。)

- **`reconnect-ms=2000` 必须保留** (QEMU 7.2+ 选项, 包内 10.2.0 自带): daemon 重启
  (`--restart` 的 bootout + bootstrap, 见 §5) 会让 socket 短暂断开, QEMU 每 2s 自动重连。
  socket 一回来 QEMU 重连, guest virtio-net 只看到 carrier 短暂闪一下, DHCP lease 没过期
  直接续用。**去掉这个选项 = 任何 daemon flip 都让 running VM 永久掉网**, 用户必须手动停 + 启 VM。
  历史 commit `e9c45d4` 一段时期走父子进程 fd 透传, daemon 重启后 QEMU 永久没网正是反例。

- **启动前 gating**: 缺 daemon (socket 不存在) 时 `SocketPaths.isReady` 返 false →
  `QemuArgsBuilder` 抛 `HVMError.backend(.configInvalid)`, 文案引导「编辑配置 → 网络 →
  安装 daemon, 或先 `brew install socket_vmnet`」, 不静默启一个没网的 VM。

- **PCIe root port (与丢中断相关)**: ARM `virt` 机器默认 root bus `pcie.0` 是 legacy
  PCIe-to-PCI bridge, NIC 挂上去走 legacy MSI 而非 MSI-X, **高 frame rate 时丢中断**
  (实测 vmnet bridged DHCP / broadcast 下 guest 收不到帧)。所以启动时预定义 4 个
  `pcie-root-port` (`chassis=1..4`), NIC 通过 `bus=rpN` 挂上去走 PCIe native MSI-X。
  超过 4 个 NIC 落回 `pcie.0` legacy fallback。

---

## 4. daemon 安装 (osascript admin)

入口 `VMnetSupervisor` (`app/Sources/HVM/Services/VMnetSupervisor.swift`, `@MainActor enum`,
无 GUI 耦合) + GUI 面板 `DetailVmnetDaemonView`:

- `installAllDaemons(extraBridgedInterfaces:)` — 装 shared + host + N 个 bridged.<iface>;
- `restartAllDaemons()` — 强制 bootout + bootstrap (破坏性, 见 §5);
- `uninstallAllDaemons()` — 卸载全部 HVM 装的 daemon;
- `presentSockets()` — 扫 `/var/run` 返回 `(shared, host, bridged: [String])` 给面板展示状态。

### 提权方式

`runWithAdminPrivileges` 把 `bash <script> <args>` 包进 AppleScript
`do shell script "..." with administrator privileges`, 用 `/usr/bin/osascript` 触发系统原生
**Touch ID / 密码授权框**, 一次到位装齐所有 daemon。参数走两层转义 (shell + AppleScript)
防注入。用户点取消时 osascript 返 errno `-128` → 映射 `VMnetError.userCancelled` (不当错误处理)。

约束 (`CLAUDE.md`):

- **不写** `/etc/sudoers.d/*`;
- **不拉** Terminal sudo bash;
- **不做**自动 kickstart 防 stale (daemon 由 launchd `KeepAlive` 托管)。

### plist 写入

`install-vmnet-daemons.sh` (root 运行) 为每个 daemon 写 `/Library/LaunchDaemons/<label>.plist`:

- **label namespace**: `com.hellmessage.hvm.vmnet.{shared,host,bridged.<iface>}`
  (与 lima / colima / hell-vm 区分, 互不干扰);
- plist 关键字段: `RunAtLoad=true` + `KeepAlive=true` + `UserName=root`, 日志落
  `/var/log/socket_vmnet.<suffix>.log`;
- shared 起 `--vmnet-mode=shared` (gateway 192.168.105.1), host 起 `--vmnet-mode=host`
  (gateway 192.168.106.1), bridged 起 `--vmnet-mode=bridged --vmnet-interface=<iface>`;
- 装完 `launchctl bootstrap system <plist>` + `launchctl enable`。

### 幂等性 (不打断已连 VM)

`install_one` 把 desired plist 先落到 tmp, 跟 on-disk plist **字节比对**, 一致 + daemon 仍在
launchctl 视图 (`launchctl print`) + socket 仍在 → **直接跳过, 不 bootout**。这是修
「点 VM B 的 [安装/更新 daemon], 跑着的 VM A 全掉网」BUG 的关键 — bootout 会 SIGTERM daemon,
已连的 QEMU stream-netdev 会断且不会自动重连 (除非走 `reconnect-ms`)。只有真正需要重建
(plist 变 / daemon 不在 / socket 丢) 才走破坏性路径。

破坏性路径里对 `launchctl bootstrap` 偶发的 `Bootstrap failed: 5: Input/output error`
(launchd database stale 引用) 做了「by-label bootout + by-plist bootout + 删 plist +
sleep 0.2 + 二次 bootstrap 重试」的兜底, 不让用户撞 error 5 后还要手动「卸载全部 → 安装」。

> 注意: `brew upgrade socket_vmnet` 后 plist 内容不变, 幂等检查不会自动 refresh 已跑的
> daemon。需走「卸载全部 → 安装」或「重启」强制重起。v1 不做自动检测。

### `.app` 同步约束

`DetailVmnetDaemonView` → `VMnetSupervisor.scriptPath()` **严格只查**
`Bundle.main/Resources/scripts/install-vmnet-daemons.sh`, 不 fallback 到仓库。
daemon plist 路径写死 `/Library/LaunchDaemons/...`, 必须指向长期稳定的
`/Applications/HVM.app`。因此改完脚本必须 `make install` 同步线上 `.app` (`CLAUDE.md` 约束)。

---

## 5. 「daemon 在 ≠ bridge 在」陷阱与重启

(重要陷阱, 2026-05-23 实测撞过。)

`vmnet.framework` 内核侧 bridge attach 可能进入 **「半死」** 状态:

- daemon 进程在跑, socket 文件在, `launchctl` 视图正常, QEMU 能连上 socket、write 不报错,
- **但帧根本不打到物理 iface** (`tcpdump` 物理 iface 看不到来自 guest MAC 的帧)。

多次 bootout / bootstrap 残留是已知触发源。**幂等 install 修不了这条** —— 它的字节比对
检查正好绕开破坏性重启。

**唯一可靠的修复** = bootout + bootstrap **强制重起** daemon (会断已连 VM 的网络, 不可避免):

- GUI: 详情页 vmnet daemon 面板 **[重启]** 按钮 (`DetailVmnetDaemonView`, 走二次确认 →
  `VMnetSupervisor.restartAllDaemons` → osascript admin);
- CLI: `sudo scripts/install-vmnet-daemons.sh --restart` (与 `--uninstall` 区别: plist 保留,
  仅重起内核态;与默认 install 区别: install 幂等跳过、restart 无条件破坏性重启)。

`restart_all` 对每个 plist 走与 `install_one` 同款的 bootout 双语法 (by-label + by-plist) +
`sleep 0.2` + 清 socket + bootstrap + err5 retry。

### VMnetBridgeProbe 能抓 / 不能抓什么

`VMnetBridgeProbe.probe(socketPath:)` (`HVMCore/VMnetBridgeProbe.swift`) 在启 VM 前做
**~200ms** 轻探 (跑在专用线程, 不在 MainActor)。流程: stat 判 `S_IFSOCK` → connect →
写一帧合成 ARP request (locally-administered MAC `02:00:48:56:00:01`, sender/target IP
全 0.0.0.0, 不撞真实硬件) → 200ms poll 看是否 `POLLHUP`/`POLLERR`。

**能抓** (返回非 `.ok`):

- `.noSocket` — socket 不存在或不是 unix socket (daemon 没装 / 孤儿);
- `.connectFailed(errno)` — connect 失败 (典型 `ECONNREFUSED` daemon 没 listen);
- `.writeFailed(errno)` — 写探测帧失败 (协议错配 / daemon 立即断);
- `.daemonHangup` — 写完帧后 daemon 立刻 hangup (异常拒绝服务)。

**不能抓**: 上面 §5 的 **「bridge silently dead」**。实测无法从 user-space 区分 —
纯被动 listen 30s 收 0 字节 (即使桥是活的), 主动发帧后再 listen 2s 仍 0 字节 (socket_vmnet
默认不把入向 broadcast/multicast 转给被动 client)。唯一可靠判别需 `sudo tcpdump` 物理 iface,
不适合放主进程。这种故障由用户感知 (VM 没拿 DHCP) → 自己点 [重启 daemon] 自救。

---

## 6. bridged iface 白名单 / 卸载 / 共存

### iface 名白名单

`install-vmnet-daemons.sh` 对每个传入接口名做 `[[ "$iface" =~ ^[a-zA-Z0-9]+$ ]]` 校验,
不合法直接 **fail-fast `exit 1`** (防 shell 注入, 也防 GUI/CI 拿到 exit 0 误判成功)。
另外 socket_vmnet 二进制路径也做 `^[a-zA-Z0-9/._-]+$` 白名单 (防 plist XML 注入)。

宿主可桥接接口由 `HostNetworkInterfaces.list()` (`HVMCore/NetworkInterfaces.swift`) 枚举:
`getifaddrs` 扫描, 白名单只认 `en*` / `pktap*` (跳过 lo0 / utun* / awdl* / bridge* 等内部接口),
带 UP + IPv4 状态, 给 GUI bridged picker 当数据源。`recommendedDefault()` 优先活跃 `en0`。

### 卸载

- CLI: `sudo scripts/install-vmnet-daemons.sh --uninstall` — 遍历
  `/Library/LaunchDaemons/com.hellmessage.hvm.vmnet.*.plist`, 逐个 `launchctl bootout` +
  删 plist, 再清残留 socket 文件;
- GUI: 详情页 vmnet daemon 面板 **[卸载全部]** 按钮 (走二次确认 →
  `VMnetSupervisor.uninstallAllDaemons`)。

### 共存检测

跟 hell-vm 同款 **不做**共存检测: 用户若已装 lima / colima 的 socket_vmnet daemon,
本脚本会 unlink 别家 socket 重建 (socket 路径相同)。用户需先卸别家。

---

## 7. guest IP 反查 (旁路)

`IPResolver` (`HVMNet/IPResolver.swift`) 与 daemon 无关, 仅用于在 GUI / 菜单展示 guest IP:
跑 `arp -an` 解析 host ARP 表, 按 MAC 反查 IPv4 (5s LRU cache)。局限: guest 必须跟 host 有过
任意 traffic (DHCP/icmp/ssh) 才进 ARP 表; guest 关机后 entry 仍残留几分钟。bridged 模式同样
适用 (host 与物理 LAN 上 guest 也走 ARP)。

---

## 8. MAC 地址

`MACAddressGenerator` (`HVMNet/MACAddress.swift`):

- `random()` — 生成 locally-administered unicast MAC (`02:xx:...`, 第一字节
  `(rand & 0xFC) | 0x02`, 即 U/L 位=1、I/G 位=0), 小写冒号分隔;
- `validate(_:)` — 校验 6 段十六进制 + U/L 位为 1 + 多播位为 0, 否则抛
  `HVMError.net(.macInvalid / .macNotLocallyAdministered)`。

`NetworkSpec.macAddress` 持久化到 config.yaml。克隆 VM 时默认重生 MAC (`CloneManager` 走
`MACAddressGenerator`, `--keep-mac` 可保留)。

---

## 附: VZ 残留说明

`app/Sources/HVMNet/NICFactory.swift` 仍 `import Virtualization`, 内含老的
`NICFactory.make(spec:) -> VZVirtioNetworkDeviceConfiguration` 与 `NetworkInterfaceList.bridged`
(基于 `VZBridgedNetworkInterface`)。**QEMU 单后端下这两段是死代码** — 现网络通路全走
`QemuArgsBuilder` 的 `-netdev`。`HVMNet` target 当前仍被编译, 但实际被消费的只有
`MACAddressGenerator` (CloneManager / CreateCommand) 与 `IPResolver`。NICFactory 的 VZ 部分
属待清理残留 (随 `CLAUDE.md` VZ 全量逐行清理收尾)。
