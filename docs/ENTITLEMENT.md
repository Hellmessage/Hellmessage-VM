# Entitlement 状态追踪

## 当前清单

| Entitlement | 状态 | 备注 |
|---|---|---|
| `com.apple.security.virtualization` | ✅ 开发者账号自带 | VZ 基础能力, `app/Resources/HVM.entitlements` 默认启用 |
| `com.apple.vm.networking` | ⏳ 审批中 | 桥接网络, 已向 Apple Developer Support 提交 |
| (其他) | ❌ 不申请 | 没必要 |

## com.apple.vm.networking 申请记录

### 申请信息

- **提交日期**: 2026-04-25
- **渠道**: https://developer.apple.com/contact/ → 开发与技术 → 授权
- **Team ID**: `Q7L455FS97`
- **Bundle ID**: `com.hellmessage.vm`
- **申请人**: jiahan chen (`h13642229904@gmail.com`)

### 申请文案(已发出)

```
Subject: Request for com.apple.vm.networking entitlement (personal / non-distributed use)

Hi Apple Developer Support,

I'd like to request the restricted entitlement com.apple.vm.networking
for one of my App IDs. This entitlement is not available for self-serve
enablement on the developer portal's Capability Requests page, so I'm
submitting this request here.

Account info:
  - Team ID: Q7L455FS97
  - App ID / Bundle ID: com.hellmessage.vm
  - App name: HellMessage VM
  - Apple ID: h13642229904@gmail.com

Use case:
I'm an individual developer building a personal Virtualization.framework-
based VM manager that runs only on my own development Mac. I need
bridged networking (VZBridgedNetworkDeviceAttachment) so my Linux
and macOS guests can:

  1. Participate on the same L2 network segment as my physical LAN,
     which VZNATNetworkDeviceAttachment cannot provide.
  2. Receive broadcast and multicast traffic for mDNS, DHCP and
     low-level network protocol testing inside the guest.
  3. Be reachable from other devices on my LAN using their own
     LAN-assigned IP addresses, without host-side port forwarding.

Distribution scope:
The app will NOT be distributed through the App Store, Developer ID
notarization, TestFlight, or any other public channel. It is signed
only with my Apple Development certificate and runs exclusively on
my own hardware for my personal development workflow.

Please let me know if any additional justification or information is
needed to grant this entitlement.

Thanks,
jiahan chen
h13642229904@gmail.com
```

### 审批通过后操作(SOP)

1. **确认**: Apple 回信有 case ID, 说明已 granted
2. **刷新 profile**:
   - 登录 https://developer.apple.com/account/resources/profiles/list
   - 找到关联 `com.hellmessage.vm` 的 Development profile → Edit → Save → Download
   - 或 Xcode → Preferences → Accounts → Download Manual Profiles
3. **把 profile 嵌入项目**:
   - 放到 `app/Resources/embedded.provisionprofile`
   - `scripts/bundle.sh` 加一行 `cp "$ROOT/app/Resources/embedded.provisionprofile" "$APP_DIR/Contents/embedded.provisionprofile"`
4. **更新 entitlement 文件**:
   ```xml
   <!-- app/Resources/HVM.entitlements -->
   <key>com.apple.vm.networking</key>
   <true/>
   ```
5. **重新签名**: `make clean && make build`
6. **验证**:
   ```bash
   codesign -d --entitlements - build/HVM.app
   # 能看到 com.apple.vm.networking = true
   ```
7. **运行期验证**: `VZBridgedNetworkInterface.networkInterfaces` 返回非空数组, 能列出 host 网卡

## VZ 明确不存在/不申请的 entitlement

| 曾误以为需要的 | 实际情况 |
|---|---|
| `com.apple.vm.device-access` | VZ 不支持 host USB 直通, 该 entitlement 对 VZ 无意义 |
| `com.apple.vm.hypervisor` | VZ 基础能力里已隐含, 无需单独申请 |
| `com.apple.security.hypervisor` | 是给直接用 HVF 的程序的, VZ 不需要 |

## 本机关 AMFI 备忘(不推荐, 仅作退路)

如果审批被拒且实在需要桥接网络:

```bash
# Apple Silicon: 进 1TR → 启动安全性实用工具 → 降级安全性
# Recovery 终端:
csrutil disable

# 回系统后:
sudo nvram boot-args="amfi_get_out_of_my_way=0x1"
sudo reboot
```

**代价**: 全系统 AMFI 关, 部分 DRM 应用(银行/流媒体)可能拒启, macOS 更新可能被重置。

**恢复**: 反向做一遍。

---

**最后更新**: 2026-04-25
