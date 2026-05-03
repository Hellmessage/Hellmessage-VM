# Entitlement 状态追踪

## 当前清单

| Entitlement | 适用进程 | 状态 | 备注 |
|---|---|---|---|
| `com.apple.security.virtualization` | HVM 主进程 / VZ host 子进程 | ✅ 开发者账号自带 | VZ 基础能力, `app/Resources/HVM.entitlements` 默认启用 |
| `com.apple.vm.networking` | HVM 主进程 / VZ host 子进程 | ⏳ 审批中 | VZ bridged 网络, 已向 Apple Developer Support 提交 |
| `com.apple.security.hypervisor` | **QEMU 子进程独立 entitlement** | ✅ 开发者账号自带 | HVF 必需, 在 `app/Resources/QEMU.entitlements` 内单独声明 |
| (其他) | — | ❌ 不申请 | 没必要 |

## 签名拓扑

- **HVM 主进程 / VZ host 子进程**: 用 `app/Resources/HVM.entitlements`(virtualization + 待审 vm.networking)
- **QEMU 子进程**: 用 `app/Resources/QEMU.entitlements`(独立, 含 `com.apple.security.hypervisor`)
  - **不与主进程共用** entitlement, 隔离 HVF 能力面
  - `Resources/QEMU/bin/*` + `Resources/QEMU/lib/*.dylib` 必须逐文件 codesign
  - 整包再 `codesign --deep` 包裹
- **签名方式**: 自动 `codesign --sign "Apple Development"` ad-hoc 签名, 不公证不分发
- **签名相关代码 / 日志**: **绝对不输出** team ID / 证书 SHA / 私钥路径(根 CLAUDE.md 硬约束)

## com.apple.vm.networking 申请记录

### 申请信息

- **提交日期**: 2026-04-25
- **渠道**: <https://developer.apple.com/contact/> → 开发与技术 → 授权
- **Team ID**: 见私有签名配置, 不外露
- **Bundle ID**: `com.hellmessage.vm`
- **App 显示名**: HVM (HellMessage VM)

### 申请文案(已发出)

```
Subject: Request for com.apple.vm.networking entitlement (personal / non-distributed use)

Hi Apple Developer Support,

I'd like to request the restricted entitlement com.apple.vm.networking
for my App ID `com.hellmessage.vm`. This entitlement is not available
for self-serve enablement on the developer portal.

Use case:
I'm an individual developer building a personal Virtualization.framework-
based VM manager that runs only on my own development Mac. I need
bridged networking (VZBridgedNetworkDeviceAttachment) so my Linux
and macOS guests can:

  1. Participate on the same L2 network segment as my physical LAN.
  2. Receive broadcast / multicast traffic for mDNS / DHCP / low-level
     network protocol testing inside the guest.
  3. Be reachable from other devices on my LAN by their LAN-assigned
     IP addresses, without host-side port forwarding.

Distribution scope:
The app will NOT be distributed through the App Store, Developer ID
notarization, TestFlight, or any other public channel. It is signed
only with my Apple Development certificate and runs exclusively on
my own hardware for my personal development workflow.

Please let me know if any additional justification is needed.

Thanks,
[contact info]
```

### 审批通过后操作 (SOP)

1. **确认**: Apple 回信附 case ID, 说明已 granted
2. **刷新 profile**:
   - 登录 <https://developer.apple.com/account/resources/profiles/list>
   - 找到关联 `com.hellmessage.vm` 的 Development profile → Edit → Save → Download
   - 或 Xcode → Settings → Accounts → Download Manual Profiles
3. **嵌入 profile**:
   - 放到 `app/Resources/embedded.provisionprofile`
   - `scripts/bundle.sh` 加: `cp "$ROOT/app/Resources/embedded.provisionprofile" "$APP_DIR/Contents/embedded.provisionprofile"`
4. **更新 entitlement 文件**:
   ```xml
   <!-- app/Resources/HVM.entitlements -->
   <key>com.apple.vm.networking</key>
   <true/>
   ```
5. **接代码**:
   - `app/Sources/HVMNet/NICFactory.swift` 加 `VZBridgedNetworkDeviceAttachment` case
   - GUI 创建向导网络段加 "桥接 (VZ)" 选项
   - CLI `--network bridged:en0`(参数已是合法值, 但 VZ 端在 entitlement 缺失下报错; 审批后报错消失)
6. **重签**: `make clean && make build && make install`
7. **验证**:
   ```bash
   codesign -d --entitlements - /Applications/HVM.app
   # 应能看到 com.apple.vm.networking = true
   ```
8. **运行期**: `VZBridgedNetworkInterface.networkInterfaces` 返回非空数组, guest 在物理 LAN 拿到 IP

> 与现有 QEMU `socket_vmnet` 路径并存供选, 不互相替代。详见 [NETWORK.md](NETWORK.md)。

## VZ 明确不存在 / 不申请的 entitlement

| 曾误以为需要的 | 实际情况 |
|---|---|
| `com.apple.vm.device-access` | VZ 不支持 host USB 直通, 该 entitlement 对 VZ 无意义 |
| `com.apple.vm.hypervisor` | VZ 基础已隐含, 无需单独申请 |
| `com.apple.security.hypervisor`(主进程) | 是给直接用 HVF 的程序的, **VZ 主进程不需要**; **QEMU 子进程需要**, 走独立 entitlement 文件 |

## 本机关 AMFI 备忘 (不推荐, 仅作退路)

如果审批被拒且实在需要 VZ bridged:

```bash
# Apple Silicon: 进 1TR (开机长按电源) → 启动安全性实用工具 → 降级安全性
# Recovery 终端:
csrutil disable

# 回系统后:
sudo nvram boot-args="amfi_get_out_of_my_way=0x1"
sudo reboot
```

**代价**:

- 全系统 AMFI 关, 部分 DRM 应用(银行 / 流媒体)可能拒启
- macOS 系统更新可能重置 nvram 设置
- 对系统完整性的破坏不可接受用于日常机

**恢复**: 反向操作即可。

> 实践中走 QEMU `socket_vmnet bridged` 路径已能满足绝大多数 bridged 需求, AMFI 退路仅作极端备用。

---

**最后更新**: 2026-05-04
