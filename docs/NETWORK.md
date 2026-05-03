# 网络设计 (`HVMNet` + `socket_vmnet`)

## 目标

- 5-mode 网络栈跨 VZ + QEMU 两个后端: `user / vmnetShared / vmnetHost / vmnetBridged / none`
- QEMU 后端通过系统级 `socket_vmnet` launchd daemon 实现 vmnet bridged / shared / host (跟 lima / hell-vm 同款)
- 提权方式: 一次 osascript "with administrator privileges" 弹原生 Touch ID / 密码框, **不**写 sudoers / **不**拉 Terminal sudo bash / **不**做自动 kickstart 防 stale
- socket_vmnet 二进制由用户机器自己 `brew install socket_vmnet`, **不**打包入 .app

## 5 种网络模式

| `mode` | QEMU 后端 | VZ 后端 | 用途 |
|---|---|---|---|
| `user` | `-netdev user` (SLIRP) | `VZNATNetworkDeviceAttachment` | 零依赖默认 NAT, 不支持 ICMP/ping |
| `vmnetShared` | `socket_vmnet --vmnet-mode=shared` | 退化到 NAT(VZ 无等价) | NAT + DHCP, 多 guest 互通 |
| `vmnetHost` | `socket_vmnet --vmnet-mode=host` | 退化到 NAT | host-only, 仅 host 与 guest 互通, 无外网 |
| `vmnetBridged` | `socket_vmnet --vmnet-mode=bridged --vmnet-interface=<iface>` | `VZBridgedNetworkDeviceAttachment` | 真二层桥接, guest IP 落物理 LAN |
| `none` | NIC 跳过 | NIC 跳过 | 禁用 NIC(保留配置, 启动不挂) |

`NetworkSpec.enabled = false` 时无论 `mode` 如何都不挂 NIC, 配置仍持久化, 后续启用恢复同一 NIC 身份。

VZ 后端 `vmnetShared / vmnetHost` 退化为 NAT 是兜底 — 真要 socket_vmnet 多 guest 互通走 QEMU 后端。GUI 不区分 engine, 用户挑了 vmnet* 模式 + VZ 后端时启动会 fallback NAT(无 ICMP 行为变化, 但拿不到多 guest 互通)。

## 数据模型 (`NetworkSpec` / `NetworkConfig`)

```swift
public enum NetworkMode: String, Codable, CaseIterable {
    case user, vmnetShared, vmnetHost, vmnetBridged, none
}

public enum NICModel: String, Codable, CaseIterable {
    case virtio    // virtio-net-pci, Linux 自带, Windows 需装 NetKVM
    case e1000e    // Intel 千兆模拟, Win ARM / macOS 自带驱动
    case rtl8139   // 兼容性最广, 性能最差, 老 guest 兜底
}

public struct NetworkSpec {
    public var mode: NetworkMode
    public var macAddress: String           // "52:54:00:xx:xx:xx" 小写冒号格式
    public var socketVmnetPath: String?     // 显式覆盖, 默认走 SocketPaths.*
    public var bridgedInterface: String?    // vmnetBridged 选的接口, 例 "en0"
    public var deviceModel: NICModel        // 默认 virtio
    public var enabled: Bool                // 默认 true
}

public typealias NetworkConfig = NetworkSpec  // hell-vm UI 抄过来用
```

派生属性:

- `effectiveBridgedInterface` — vmnetBridged 模式下, 空 fallback `en0`
- `effectiveSocketPath` — vmnet* 模式按 `socketVmnetPath` 优先, 否则 `SocketPaths.{vmnetShared, vmnetHost, vmnetBridged(iface)}`
- `qemuStableSuffix` — MAC 去冒号小写, 给 QMP `netdev_add` / `device_add` 当稳定 ID

Codable 兼容老 yaml: `nat → user`, `bridged → vmnetBridged`, `shared → vmnetShared`,缺省字段 `deviceModel = .virtio` / `enabled = true`。

## socket_vmnet 架构 (QEMU 后端)

```
user                                                                guest
                                                                       │
HVM (普通用户) ─ -netdev stream,addr.path=… ─ unix socket            ┌─┴─┐
                                                  │                  │   │
                                                  ▼                  │GST│
       /var/run/socket_vmnet[.host|.bridged.<iface>]   ──────────►   │   │
                                                  │                  └───┘
                                                  ▼
              launchd ─► socket_vmnet (root) ─► vmnet.framework
              KeepAlive
              plist: /Library/LaunchDaemons/com.hellmessage.hvm.vmnet.<mode>.plist
```

**关键路径** (`HVMCore/SocketPaths.swift`):

```swift
public enum SocketPaths {
    public static let vmnetBase = "/var/run/socket_vmnet"
    public static var vmnetShared: String { vmnetBase }                  // shared
    public static var vmnetHost:   String { vmnetBase + ".host" }         // host
    public static func vmnetBridged(interface: String) -> String { ... }  // bridged.<iface>
    public static func isReady(_ path: String) -> Bool                    // 文件存在 + 是 unix socket
}
```

**协议要点**: socket_vmnet daemon 用 4-byte length-prefix framing, 跟 QEMU `-netdev stream` 协议一致 (lima / hell-vm 同款), 因此 QEMU 直接连 unix socket 即可,**不需要** `socket_vmnet_client` wrapper, **不需要**父进程 `socket()/connect()` 把 fd 透传给子进程 (老的 sidecar fd-passing 路径已下线)。

**plist namespace**: `com.hellmessage.hvm.vmnet.*` (HVM 自家, 跟 lima `lima.socket_vmnet` / hell-vm `io.hell.vmnet.*` / colima `com.colima.*` 区分,不互相干扰)。

## daemon 安装 / 卸载

### 路径

- 安装脚本: `scripts/install-vmnet-daemons.sh` (打包入 `/Applications/HVM.app/Contents/Resources/scripts/`)
- 用户机器先 `brew install socket_vmnet` 装二进制(脚本探测 `/opt/homebrew/opt/socket_vmnet/bin/...` 等位置)

### 提权

GUI 通过 [`VMnetSupervisor`](../app/Sources/HVM/Services/VMnetSupervisor.swift) 拉脚本:

```swift
let appleScript = "do shell script \"/bin/bash <script> <args>\" with administrator privileges"
let proc = Process(launchPath: "/usr/bin/osascript", args: ["-e", appleScript])
```

弹原生 Touch ID / 密码框,**一次到位**装 shared + host + 用户用到的 bridged.<iface> 全套 daemon。

### 入口

GUI: `编辑配置 → 网络区块 → vmnet daemon 面板 → "安装 / 更新 daemon"` 按钮
CLI(可选): `sudo scripts/install-vmnet-daemons.sh [iface ...]` 手动跑

### 卸载

GUI: 同面板 → "卸载全部" 按钮
CLI: `sudo scripts/install-vmnet-daemons.sh --uninstall`

操作动作:
- `launchctl bootout system/com.hellmessage.hvm.vmnet.*` 拆所有 daemon
- 删 `/Library/LaunchDaemons/com.hellmessage.hvm.vmnet.*.plist`
- 清残留 `/var/run/socket_vmnet*` (shared + host + bridged.<iface>)

## QEMU argv 构造 (`HVMQemu/QemuArgsBuilder`)

```swift
for net in cfg.networks {
    guard net.enabled, net.mode != .none else { continue }
    let netId = "net\(idx)", busOpt = idx < 4 ? ",bus=rp\(idx)" : ""
    let dev = "\(net.deviceModel.qemuDeviceName),netdev=\(netId),mac=\(net.macAddress)\(busOpt)"

    switch net.mode {
    case .user:
        args += ["-netdev", "user,id=\(netId)"]

    case .vmnetShared, .vmnetHost, .vmnetBridged:
        let sock = net.effectiveSocketPath!
        guard SocketPaths.isReady(sock) else {
            throw HVMError.backend(.configInvalid(...))   // 提示用户去 GUI 装 daemon
        }
        args += ["-netdev", "stream,id=\(netId),addr.type=unix,addr.path=\(sock)"]

    case .none: continue
    }
    args += ["-device", dev]
}
```

`bus=rp_N` (PCIe root port) 关键 — 不能落到 `pcie.0` legacy bridge,否则 virtio-net-pci 高 packet rate 丢中断 (实测 vmnet bridged DHCP / broadcast 频次)。前 4 张 NIC 占 `rp0..rp3`,超出 fallback 到 `pcie.0`。

## VZ NICFactory 映射

```swift
switch spec.mode {
case .user, .vmnetShared, .vmnetHost, .none:
    nic.attachment = VZNATNetworkDeviceAttachment()                // 退化 NAT
case .vmnetBridged:
    let iface = spec.effectiveBridgedInterface ?? "en0"
    let match = VZBridgedNetworkInterface.networkInterfaces
        .first(where: { $0.identifier == iface })
        ?? throw HVMError.net(.bridgedInterfaceNotFound(...))
    nic.attachment = VZBridgedNetworkDeviceAttachment(interface: match)
}
```

VZ bridged 仍依赖 Apple `com.apple.vm.networking` entitlement(申请中);entitlement 未到位时 `VZBridgedNetworkInterface.networkInterfaces` 为空,启动会抛 `bridgedInterfaceNotFound`。在此期间 VZ 用户应当走 NAT 或 QEMU 后端 + socket_vmnet bridged。

## MAC 地址

### 默认策略

`NetworkSpec.generateRandomMAC()` 产生 `52:54:00:xx:xx:xx` 格式(QEMU OUI 前缀, locally-administered + unicast)。

### 校验

`NetworkSpec.isValidMAC(_:)` 走正则 `^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$`,大小写不限。EditConfigDialog 保存时校验。

### 持久化

写入 `config.yaml` `networks[].macAddress`,VM 全生命周期不变(包括 bundle 移动 / 跨机迁移),guest 内 DHCP lease 稳定。

## NIC 型号

每张 NIC 的 `deviceModel` 决定 QEMU `-device` 名:

| NICModel | -device | 适用 |
|---|---|---|
| `virtio` | `virtio-net-pci` | Linux 默认(内核自带), Windows 需装 NetKVM |
| `e1000e` | `e1000e` | Windows ARM / macOS 自带驱动, 装机阶段首选 |
| `rtl8139` | `rtl8139` | 老 guest 兜底, 性能最差 |

GUI 编辑配置 → 网络卡片展开 → "NIC 型号" chip 三选一。

## 多 NIC

一台 VM 可挂多张 NIC, 不同 mode 混搭(例: `user` 上网 + `vmnetBridged en0` 暴露服务)。VMSettingsNetworkSection 多卡折叠 UI 直接编辑。

PCIe root port 槽位上限 4(`rp0..rp3`),第 5 张及以后挂 `pcie.0`(无 PCIe native MSI-X 中断,不影响低 traffic NIC,高 traffic NIC 有丢包风险)。

## 错误模型

```swift
HVMError.backend(.configInvalid(field: "networks[N].mode", reason: "..."))
HVMError.net(.macInvalid(String))
HVMError.net(.bridgedInterfaceNotFound(requested: String, available: [String]))
HVMError.net(.bridgedNotEntitled)        // VZ entitlement 未到位
```

## 不做什么

1. **不打包 socket_vmnet 入 .app** — 用户机器 brew install
2. **不写 /etc/sudoers.d/*** — 提权完全靠 osascript Touch ID
3. **不自动 kickstart 防 stale** — daemon 由 launchd KeepAlive 管, 偶发 stale 时用户手动卸载重装
4. **不做共存检测** — 跟 hell-vm 同款,代价是若用户已装 lima/colima 的 socket_vmnet daemon, 我们 install 时会 unlink 别家 socket 重建(用户需先卸别家)
5. **不做端口转发** — vmnet bridged / NAT 都直接可达, 不需要
6. **不做静态 IP / DHCP 池配置** — daemon 默认 gateway `192.168.105.1` (shared) / `192.168.106.1` (host),不暴露
7. **不做流量计量 / 多 VM 互联专网** — 走 bridged + 物理交换机自然实现

## 测试

- unit: `NetworkSpec.isValidMAC`, Codable yaml roundtrip
- 集成 (手动):
  1. `brew install socket_vmnet`
  2. GUI 创建 `engine=qemu` Linux VM, 编辑配置 → 网络选 vmnetShared → 装 daemon (osascript Touch ID) → 启 VM → guest `ip -4 addr` 应见 `192.168.105.x`
  3. 切 vmnetBridged en0 → 重启 VM → guest 拿物理 LAN 段 IP → host 物理 LAN 设备能 ping 到 guest

## 相关文档

- [QEMU_INTEGRATION.md](QEMU_INTEGRATION.md) — QEMU 后端整体集成
- [ENTITLEMENT.md](ENTITLEMENT.md) — VZ `com.apple.vm.networking` 申请追踪
- [VM_BUNDLE.md](VM_BUNDLE.md) — `networks[]` schema (config.yaml)

---

**最后更新**: 2026-05-03 (切到 hell-vm 风格 socket_vmnet + 5-mode + osascript admin 提权)
