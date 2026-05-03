# P1 — 本周做

可观测性 / 易出事的脆弱点 / UI 合规漂移。3-5 天工作量。

---

## [ ] #7 · UI 业务侧硬编码 `.font(.system(size:))` ≈ 35 处违反 CLAUDE.md UI 控件约束

**集中点**:
- [Content/DetailBars.swift](../../app/Sources/HVM/UI/Content/DetailBars.swift) — 7 处 (size 10/11/12/38)
- [Content/Buttons.swift](../../app/Sources/HVM/UI/Content/Buttons.swift) — 5 处 (size 12/13/14, **Style 层都漂了**)
- [Dialogs/CreateVMDialog.swift](../../app/Sources/HVM/UI/Dialogs/CreateVMDialog.swift) — 4 处 (size 11/12)
- [Shell/Toolbar.swift](../../app/Sources/HVM/UI/Shell), [Shell/MenuPopoverView.swift](../../app/Sources/HVM/UI/Shell), [Settings/*](../../app/Sources/HVM/UI/Settings) — 共 ~15 处
- [Content/GuestIcon.swift:60](../../app/Sources/HVM/UI/Content/GuestIcon.swift:60) — 1 处
- [Settings/VMSettingsNetworkSection+ModePickers.swift:167](../../app/Sources/HVM/UI/Settings/VMSettingsNetworkSection+ModePickers.swift:167) — `.font(.system(..., design: .monospaced))` 应走 `HVMFont.mono`

**修复路径**:
1. 在 `app/Sources/HVM/UI/Style/Theme.swift` 扩 `HVMFont`:
   ```swift
   public extension HVMFont {
       static let caption       = Font.system(size: 11, weight: .regular)
       static let captionBold   = Font.system(size: 10, weight: .semibold)
       static let small         = Font.system(size: 12, weight: .regular)
       static let body          = Font.system(size: 13, weight: .regular)
       static let button        = Font.system(size: 13, weight: .semibold)
       static let buttonMedium  = Font.system(size: 13, weight: .medium)
       static let heroButton    = Font.system(size: 14, weight: .semibold)
       static let pillButton    = Font.system(size: 12, weight: .semibold)
       static let display       = Font.system(size: 38, weight: .light)
       static let bodyBold      = Font.system(size: 12, weight: .bold)
   }
   ```
2. 业务侧批量替换 `.font(.system(size: 12))` → `.font(HVMFont.small)` 等
3. mono 系列改 `.font(HVMFont.mono.weight(.bold))`

**验证**:
- `grep -rn "\.font(\.system(" app/Sources/HVM/UI/{Content,Dialogs,IPSW,Detached,Settings,App,Shell}/` 应零结果
- Style/ 下 Buttons.swift 也修(虽然不在业务边界, 但 token 系统应该统一)

---

## [ ] #8 · UI 业务侧硬编码 RGB / 系统色 8 处

**位置**:
| 文件:行 | 当前 | 建议 token |
|---|---|---|
| [Content/GuestIcon.swift:26](../../app/Sources/HVM/UI/Content/GuestIcon.swift:26) | `Color(red: 0.95, green: 0.65, blue: 0.20)` | `HVMColor.guestLinuxAccent` |
| [Content/GuestIcon.swift:32](../../app/Sources/HVM/UI/Content/GuestIcon.swift:32) | `Color(red: 0.85, green: 0.88, blue: 0.94)` | `HVMColor.guestMacOSAccent` |
| [Content/GuestIcon.swift:38](../../app/Sources/HVM/UI/Content/GuestIcon.swift:38) | `Color(red: 0.302, green: 0.616, blue: 1.00)` | `HVMColor.guestWindowsAccent` |
| [Detached/DetachedVMWindowController.swift:434](../../app/Sources/HVM/UI/Detached/DetachedVMWindowController.swift:434) | `Color(red: 1.0, green: 0.37, blue: 0.36)` | `HVMColor.windowClose` |
| [Detached/DetachedVMWindowController.swift:435](../../app/Sources/HVM/UI/Detached/DetachedVMWindowController.swift:435) | 黄色 RGB | `HVMColor.windowMin` |
| [Detached/DetachedVMWindowController.swift:436](../../app/Sources/HVM/UI/Detached/DetachedVMWindowController.swift:436) | 绿色 RGB | `HVMColor.windowZoom` |
| [Shell/MenuPopoverView.swift:41,105,107](../../app/Sources/HVM/UI/Shell/MenuPopoverView.swift:41) | `Color.green` | `HVMColor.statusRunning` |

**修复**: `HVMColor` 加上述 7 个 token, 业务侧批量替换。

**验证**:
- `grep -rn "Color(red\|Color\.green\|Color\.gray\|Color\.black\|Color\.white" app/Sources/HVM/UI/{Content,Dialogs,IPSW,Detached,Settings,App,Shell}/` 应零结果

---

## [ ] #9 · UI 业务侧硬编码 padding 数字 ≈ 6 处

**位置**:
- [Buttons.swift:15,36,77,96](../../app/Sources/HVM/UI/Content/Buttons.swift:15) — vertical padding 7/6/5/10 不统一
- [DetailBars.swift:453,548,576](../../app/Sources/HVM/UI/Content/DetailBars.swift:453) — `.padding(.vertical, 9)` / `.padding(.vertical, 12)`
- [Settings/VMSettingsNetworkSection+ModePickers.swift:48,145](../../app/Sources/HVM/UI/Settings/VMSettingsNetworkSection+ModePickers.swift:48) — `.padding(6)`

**修复**: `HVMSpace` 扩:
```swift
public extension HVMSpace {
    static let buttonPadVerticalPrimary: CGFloat   = 7
    static let buttonPadVerticalSecondary: CGFloat = 6
    static let buttonPadVerticalSmall: CGFloat     = 5
    static let buttonPadVerticalHero: CGFloat      = 10
    static let rowPad: CGFloat                     = 9
    static let rowPadLarge: CGFloat                = 12
    static let segmentItemPad: CGFloat             = 6
}
```

**验证**:
- `grep -rn '\.padding\([0-9]\+\|\.padding(\.vertical, [0-9]\+\|\.padding(\.horizontal, [0-9]\+' app/Sources/HVM/UI/{Content,Dialogs,IPSW,Detached,Settings,App,Shell}/` 应零结果

---

## [ ] #10 · `hvm-cli` 与 `hvm-dbg` 的 `OutputFormat.bail / bailJSON` 完全重复

**位置**:
- [app/Sources/hvm-cli/Support/OutputFormat.swift](../../app/Sources/hvm-cli/Support/OutputFormat.swift)
- [app/Sources/hvm-dbg/Support/OutputFormat.swift](../../app/Sources/hvm-dbg/Support/OutputFormat.swift)

两份 ≈10 行一致的 `bail()` / `bailJSON()` 实现。

**修复**:
- 挪 `bail` 系列到 `app/Sources/HVMUtils/CliExit.swift`
- 两侧 `import HVMUtils` 后删本地副本
- `Package.swift` 给 hvm-cli / hvm-dbg target 加 HVMUtils 依赖(若尚未)

**验证**:
- `grep -rn "func bail" app/Sources/` 应只剩一份在 HVMUtils

---

## [ ] #11 · `DetailBars.swift` 卡片样式 `RoundedRectangle.fill + RoundedRectangle.stroke` 重复 5+ 处

**位置**: [DetailBars.swift:301,339,365,379,509](../../app/Sources/HVM/UI/Content/DetailBars.swift:301)

**问题**: 同一种"圆角卡片+边框"组合各处复制粘贴, 圆角值 / 描边色 / 不透明度容易漂移。

**修复**: 在 `app/Sources/HVM/UI/Style/HVMCard.swift` 加:
```swift
public extension View {
    func hvmCard(radius: CGFloat = HVMRadius.card,
                 fill: Color = HVMColor.surfaceElevated,
                 stroke: Color = HVMColor.divider) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke, lineWidth: 1))
    }
}
```
业务侧改 `.hvmCard()` 一行。

**验证**:
- `grep -rn "RoundedRectangle.*\.fill" app/Sources/HVM/UI/Content/` 数量大幅下降

---

## [ ] #12 · `BundleIO` schema v1 → v2 断兼容路径完全无测

**位置**:
- 实现: [app/Sources/HVMBundle/BundleIO.swift](../../app/Sources/HVMBundle/BundleIO.swift)
- 测试: [app/Tests/HVMBundleTests](../../app/Tests/HVMBundleTests)

**风险**:
- 用户从老版本带 `config.json` 上来时, 期望明确报错 "请重新创建 VM"
- 当前没测, schema 变化时无回归保障

**修复**: 加 `BundleIO_LegacyJSONTests`:
- fixture: 假 bundle 仅含 `config.json` 无 `config.yaml`
- 断言抛指定错误码 (例如 `bundle.legacy_v1_config`)
- 错误消息必须含 "请重新创建 VM" 与 "config.json" 关键词

**验证**:
- `swift test --filter BundleIO_LegacyJSON` 通过

---

## [ ] #13 · QEMU display protocol (HDP) 解析层无 malformed input 测试

**位置**:
- 协议层: [app/Sources/HVMDisplayQemu/HDPProtocol.swift](../../app/Sources/HVMDisplayQemu/HDPProtocol.swift)
- 通道: [app/Sources/HVMDisplayQemu/DisplayChannel.swift](../../app/Sources/HVMDisplayQemu/DisplayChannel.swift)

**风险**:
- 协议层走 unix domain socket, 同机进程能投毒(虽然受签名隔离, 仍脆弱)
- truncated header / oversized payload_len / unknown msg type / SCM_RIGHTS fd 缺失等当前都没测

**修复**: 加 `HDPProtocolFuzzTests` 覆盖:
- header 截断(<8 byte)
- magic 错(非 'HDP1')
- payload_len 超阈值(>16MB)
- 未知 msg type → 协议层抛 `HDPError.unknownMessage`
- ancillary 缺 fd → 抛 `HDPError.missingFD`
- 至少 10 个用例

**验证**:
- 协议变更时新加 fuzz case 都能跑通

---

## [ ] #14 · 多处 `try? FileManager.removeItem` / `try? close` 静默吞错

**位置**:
- [QemuHostEntry.swift:51,107,153,185,371,382](../../app/Sources/HVM/QemuHostEntry.swift)
- [QemuConsoleBridge.swift:107,174](../../app/Sources/HVMQemu/QemuConsoleBridge.swift)
- [OrphanReaper.swift:141](../../app/Sources/HVM/UI/App/OrphanReaper.swift)

**风险**: 残留 socket 删失败 → QEMU 下次 bind 失败 → 用户看到神秘的 "address already in use"。

**修复**: 统一走 `HVMLog.logger().warning(...)` 记一行(不阻塞流程, 但留诊断线索):
```swift
do {
    try FileManager.default.removeItem(at: url)
} catch CocoaError.fileNoSuchFile { /* ok */ }
catch {
    HVMLog.logger().warning("清理残留失败 \(url.path): \(String(describing: error))")
}
```

**验证**:
- 故意 chmod 000 一个 socket 父目录, 启动 VM 时 logs 应有明确警告(不 panic)

---

## [ ] #15 · QMP 连接 / 截图错误日志只输出原始 `\(error)`,无法定位根因

**位置**:
- [QemuHostEntry.swift:215-225](../../app/Sources/HVM/QemuHostEntry.swift:215) 连接超时分支
- [QemuHostEntry.swift:607-629](../../app/Sources/HVM/QemuHostEntry.swift:607) `handleDbgScreenshot`

**风险**: 用户看到 "Connection reset" / "QMP 连接失败 (15s 超时)" 时无法区分:
- QEMU 没启
- socket 文件没创建
- 权限拒绝
- QEMU 已 crash

**修复**:
- `tryConnectQmp` 每个分支记下 `lastError`, 失败时一并报
- catch 块按 `QmpError` 子类型映射:
  - `.closed` → `backend.qmp_closed`
  - `.protocolError(...)` → `backend.qmp_protocol_error`
  - `.timeout` → `backend.qmp_timeout`
  - 其他 → `backend.qmp_error` + 原始 description

**验证**:
- 手动复现 4 种失败场景, 错误码与 stderr log 应能区分

---

## [ ] #16 · `Makefile` 无增量,每次 `make build` 都重签 ~30 个 QEMU dylib

**位置**: [Makefile:22-56](../../Makefile:22)

**问题**: 即使 `app/Sources/` 没改, `make build` 也会跑完整 `bundle.sh`, 逐文件签 `Resources/QEMU/lib/*.dylib`。开发期日常迭代痛点。

**修复**: stamp 文件机制
```makefile
build: $(BUILD)/.bundle-stamp

$(BUILD)/.bundle-stamp: compile icon scripts/bundle.sh app/Resources/HVM.entitlements app/Resources/QEMU.entitlements
	@CONFIGURATION=$(CONFIGURATION) SIGN_IDENTITY="$(SIGN_IDENTITY)" bash scripts/bundle.sh
	@touch $@

clean:
	rm -rf $(BUILD_DIR) $(SWIFTPM_DIR)
```
注意:
- `compile` 已经是 PHONY, 它每次必跑(SwiftPM 自己增量), 但若 SwiftPM 输出二进制没变, bundle 也不该重跑
- 加一层中间文件 `$(BUILD)/HVM-binary-stamp` 检测 `app/.build/.../HVM` 修改时间

**收益**: 日常 `make build` 从 ~30s 降到 ~5s。

**验证**:
- 连跑两次 `make build`, 第二次应跳过 bundle.sh

---

## [ ] #17 · `install-vmnet-daemons.sh` 拼 plist 不转义 XML

**位置**: [scripts/install-vmnet-daemons.sh:101-123](../../scripts/install-vmnet-daemons.sh:101)

**问题**: 直接 heredoc `<string>$label</string>` / `<string>$SOCKET_VMNET</string>`。
- `$label` 受白名单约束, 安全
- `$SOCKET_VMNET` 来自 `find_socket_vmnet()`, brew 安装路径理论上可含特殊字符(虽然现实不会)

**修复**(任选其一):
- 改用 `plutil -create / -insert`(推荐, 标准库支持)
- 或加路径白名单: `[[ "$SOCKET_VMNET" =~ ^[a-zA-Z0-9/._-]+$ ]] || err "非法 socket_vmnet 路径: $SOCKET_VMNET"`

**验证**:
- 故意把 `socket_vmnet` 复制到含 `<>` 的路径(例如 `/tmp/<a>/socket_vmnet`), 跑 `--install`, 应 fail-fast 而不是生成损坏 plist

---

## P1 完成判定

- [ ] 11 项全部勾掉
- [ ] UI 漂移 grep 全清(7/8/9 三项零结果)
- [ ] Test 套件多出 BundleIO_LegacyJSON / HDPProtocolFuzz 两组
- [ ] `make build` 实测增量生效(连跑两次第二次秒过)
- [ ] CLAUDE.md UI 控件约束 + BUILD_SIGN.md 同步更新

---

**最后更新**: 2026-05-04
