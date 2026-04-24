# 网络设计 (`HVMNet`)

## 目标

- MVP 阶段仅实现 NAT, 满足 "guest 能上网、host 能 ssh guest" 的基本需求
- 预留 bridged 路径, Apple 审批通过后快速切换
- 不实现私有子网 / VLAN / 多机组网, 保持最简

## entitlement 与能力矩阵

| 模式 | 依赖 entitlement | 当前状态 |
|---|---|---|
| NAT | `com.apple.security.virtualization`(自带) | ✅ 可用 |
| Bridged | `com.apple.vm.networking`(需申请) | ⏳ 审批中, 见 [ENTITLEMENT.md](ENTITLEMENT.md) |
| File handle (raw socket) | `com.apple.vm.networking` | ⏳ 同上, 不打算使用 |

`HVMNet` 启动时检查运行时 entitlement:

```swift
public enum NetEntitlement {
    public static var hasBridged: Bool {
        // 读 SecTaskCopyValueForEntitlement("com.apple.vm.networking")
        // 或 VZBridgedNetworkInterface.networkInterfaces.isEmpty 作代理判断
    }
}
```

GUI 创建向导根据 `hasBridged` 决定是否展示 "桥接" 选项。

## NAT 模式

### 构建

```swift
public enum NATAttachment {
    public static func make(macAddress: String?) throws -> VZNATNetworkDeviceAttachment {
        return VZNATNetworkDeviceAttachment()
    }
}

public enum NICFactory {
    public static func make(spec: NetworkSpec) throws -> VZVirtioNetworkDeviceConfiguration {
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.macAddress = spec.macAddress.flatMap { VZMACAddress(string: $0) }
                          ?? VZMACAddress.randomLocallyAdministered()
        switch spec.mode {
        case .nat:
            nic.attachment = VZNATNetworkDeviceAttachment()
        case .bridged(let ifName):
            nic.attachment = try BridgedAttachment.make(ifName: ifName)
        }
        return nic
    }
}
```

### 行为

- VZ 内部起一个 NAT 网络, guest 拿到 `192.168.64.x/24` 段私有 IP(具体范围 Apple 管理, 可能随版本变动)
- DHCP / DNS 由 VZ 自动提供
- guest → 外网: 正常
- host → guest: 需知道 guest IP, 走 `192.168.64.x` 直连可达(无需端口转发)
- **guest 之间不互通**: VZ 的 NAT 每台 VM 单独一个子网, 两台 VM 不同子网, 不能直接互联

### 获取 guest IP

VZ 不直接暴露 DHCP lease 表。HVM 提供两种方式:

1. **DHCP 嗅探**: VMHost 在 host 侧不可行(NAT 在 VZ 内部黑盒), 此路不通
2. **ARP 扫描**: host 的 `vz0/vz1` 接口 ARP 缓存可能有条目, 但不可靠
3. **推荐**: guest 内装小 agent 通过 virtio-console 汇报 IP → `hvm-dbg status <vm>` 显示
4. **兜底**: 用户在 guest 内执行 `ip -4 addr` 自己看

MVP 方案: **(3) 作为目标, (4) 作为默认**。guest agent 以后再做, 不阻塞 M1。

### mDNS 限制

NAT 模式下:

- guest 的 mDNS 广播**出不去** host 的物理 LAN, 即 host 上用 `ping guest.local` 走不到
- 反向: host 的 `.local` 名字 guest 能否看到取决于 VZ 的 NAT 实现, 不保证

要 `.local` 互通需要桥接, 见下文。

## Bridged 模式(审批通过后启用)

### 前置条件

- entitlement 生效(重签 .app, `codesign -d --entitlements` 能看到 `com.apple.vm.networking=true`)
- 至少一个物理接口(`en0` 常见为 Wi-Fi 或以太网)

### 构建

```swift
public enum BridgedAttachment {
    public static func make(ifName: String) throws -> VZBridgedNetworkDeviceAttachment {
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        guard let nif = interfaces.first(where: { $0.identifier == ifName }) else {
            throw NetError.bridgedInterfaceNotFound(requested: ifName, available: interfaces.map(\.identifier))
        }
        return VZBridgedNetworkDeviceAttachment(interface: nif)
    }
}
```

### 接口列举

```swift
public struct BridgedInterfaceInfo: Sendable {
    public let identifier: String        // "en0"
    public let localizedDisplayName: String   // "Wi-Fi" / "Ethernet"
}

public enum NetworkInterfaceList {
    public static var bridged: [BridgedInterfaceInfo] {
        VZBridgedNetworkInterface.networkInterfaces.map {
            .init(identifier: $0.identifier, localizedDisplayName: $0.localizedDisplayName ?? $0.identifier)
        }
    }
}
```

### Wi-Fi 桥接注意

- Apple 的 Wi-Fi 驱动不允许同一个 MAC 地址对应多个 L2 身份, VZ 的桥接在 Wi-Fi 上**可能发 guest 帧但收不到**
- 实测: 部分 macOS 版本 + 某些路由器不转发桥接帧, 导致 guest 拿不到 DHCP
- **建议有线**: en0 以太网最稳, Wi-Fi 属于"能用但不保证"
- GUI 在选择 Wi-Fi 接口桥接时弹黄色提示, 不阻止

## MAC 地址

### 默认策略

- 创建 VM 时自动生成一个 locally-administered (第二位为 2/6/A/E) 的 MAC
- 保存到 `config.networks[].macAddress`, 之后不变
- VM 迁移到别的机器(或同机上改 bundle 路径)不会变 MAC, guest 里的 DHCP lease 稳定

### OUI 前缀

不使用任何 vendor OUI, 始终是 locally-administered, 避免与真实设备冲突。推荐前缀 `52:54:00` 是 QEMU 传统, 但它不是 locally-administered 的保留前缀, 我们改用 `02:xx:xx:xx:xx:xx`(第一字节低两位 = 10, 标记 locally-administered):

```swift
VZMACAddress.randomLocallyAdministered()
// 实测 VZ 返回 02:xx:... 格式, 直接用
```

### 手动指定

config 允许手填 MAC, 但格式必须合法且 locally-administered, 校验:

```swift
static func validate(_ mac: String) throws {
    guard let addr = VZMACAddress(string: mac) else { throw NetError.macInvalid(mac) }
    let firstByte = addr.ethernetAddress.0
    guard (firstByte & 0x02) != 0 else { throw NetError.macNotLocallyAdministered(mac) }
}
```

## 不做什么

1. **不做端口转发 (port forwarding)**: NAT 模式下 guest IP 直接可达, 无需端口转发。若真需要, 用户自己 `socat` / `ssh -L`
2. **不做自定义 DHCP 池 / static IP 分配**: NAT 由 VZ 内部管理, 不暴露
3. **不做多 VM 互联专用网**: VZ 不提供 shared NAT bridge 这种模式, 自己用 bridged + host 侧 bridge 接口做, 不在 HVM 范畴
4. **不做 VPN / WireGuard 集成**: 这是 guest 或 host 的事
5. **不做流量计量**: VZ 不暴露 per-NIC 计数器
6. **不做 file handle (fd) attachment**: 虽然 VZ 支持 `VZFileHandleNetworkDeviceAttachment`(接 utun), 但配置复杂且同样需要 `com.apple.vm.networking` entitlement, MVP 不做

## 错误

```swift
public enum NetError: Error {
    case bridgedNotEntitled
    case bridgedInterfaceNotFound(requested: String, available: [String])
    case macInvalid(String)
    case macNotLocallyAdministered(String)
}
```

## 测试

- unit: MAC 校验、NetworkSpec 解析
- 集成(手动): 起一台 Ubuntu, `curl https://ifconfig.me` 确认出网, `ssh host` 确认反向可达

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| E1 | guest IP 自动汇报的 agent 协议 | virtio-console 上的简单换行协议: `{"kind":"ip","v4":["..."]}` | M2 与 hvm-dbg 同期定 |
| E2 | Wi-Fi 桥接不稳时是否自动退化 NAT | 不自动退化, 只告警, 由用户决定 | 已决 |
| E3 | 未来如果做多 VM 互联, 走什么路径 | 方向: host 上创建 `bridge0` 接口, 多 VM 桥接到它。等 bridged entitlement 到位后评估 | bridged 可用后 |

## 相关文档

- [ENTITLEMENT.md](ENTITLEMENT.md) — `com.apple.vm.networking` 申请追踪
- [VM_BUNDLE.md](VM_BUNDLE.md) — `networks[]` schema
- [VZ_BACKEND.md](VZ_BACKEND.md) — NIC 挂在哪里

---

**最后更新**: 2026-04-25
