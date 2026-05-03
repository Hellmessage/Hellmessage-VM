# 已合规 / 审过免列(留底防回归)

2026-05-03 深审审过的合规项。**不需要修复**, 但记录下来防止未来回归。

每项配套 grep 验证命令, 若回归会被工具检出。

---

## 1. 日志路径合规

**约束**(CLAUDE.md 日志路径约束):
- HVM host 侧 .log 全部走 `HVMPaths.vmLogsDir(displayName:id:)`
- 禁止业务侧自己拼 `bundle.appendingPathComponent("logs/...")`
- dev/debug 临时日志同样走 `HVMPaths.logsDir`
- bundle/logs/ 唯一允许写入来源: `ConsoleBridge` (VZ) / `QemuConsoleBridge` (QEMU)

**审过结果**: 业务侧无散落到 `/tmp` / 仓库根 / 任意 redirect 路径。

**回归守卫**:
```bash
grep -rn "/tmp\|appendingPathComponent.*logs\|FileHandle.*Write" app/Sources/ | \
    grep -v Tests/ | grep -v ConsoleBridge | grep -v QemuConsoleBridge
```
应无 LogSink / 业务侧违规结果。

---

## 2. ErrorDialog 强制使用

**约束**: 所有错误对话框走统一 ErrorDialog, 禁止 NSAlert。

**审过结果**: 业务侧无 `NSAlert` 使用。

**回归守卫**:
```bash
grep -rn "NSAlert" app/Sources/HVM/UI/
```
应零结果。

---

## 3. QMP / IPC 全 Unix Socket

**约束**: QEMU QMP 仅监听 unix domain socket(`run/<vm-id>.qmp`), 严禁 TCP 监听。HVMIPC 同样只走 unix domain socket。

**审过结果**: 无 TCP `listen / bind / 0.0.0.0 / 127.0.0.1`(非测试 / 非注释)。

**回归守卫**:
```bash
grep -rn "listen\|bind\|0\.0\.0\.0\|127\.0\.0\.1" app/Sources/HVM*/ | \
    grep -v Tests/ | grep -v "^//"
```
应无网络 listen 调用结果。

---

## 4. 签名信息无泄漏

**约束**: 签名相关代码或日志不得输出 team ID / 证书 SHA / 私钥路径。

**审过结果**: 代码无运行时输出 `Q7L455FS97` / TeamID / 证书 SHA。

**回归守卫**:
```bash
grep -rn "Q7L455FS97\|Apple Development\b" app/Sources/
```
应仅在 entitlement / Info.plist / 注释中出现, 不在 print/log 输出中。

---

## 5. Modal 全套 HVMModal

**约束**: 业务侧禁止自拼 `ZStack(蒙底 + 居中卡片)`, 必须套 `HVMModal`。

**审过结果**:
- 业务 Dialog 全套 `HVMModal`
- `DialogOverlay.swift:14` 的 ZStack 是合规的"多对话框栈容器"(用于 Create/Install/IPSW/Error/Confirm 多个 modal 叠加)

**回归守卫**:
```bash
grep -rn "ZStack" app/Sources/HVM/UI/{Content,Dialogs,IPSW,Detached,Settings}/ | \
    grep -v "DialogOverlay"
```
应无新出现的自拼蒙底场景。

---

## 6. mono 字体仅用于代码值

**约束**: `HVMFont.mono / monoSmall` 仅用于 UUID / MAC / 文件路径 / shell 命令展示 / build 号; 正文 / 标题 / 按钮 / 表单一律 SF Pro。

**审过结果**: 业务侧 mono 使用全部合规:
- DetailBars.swift:428 — UUID
- DetailBars.swift:655/664 — 条件值
- OSImageFetchDialog.swift:33 — 下载路径
- CreateVMDialog.swift:612 — IPSW 路径
- IpswCatalogPicker.swift:42/98 — 版本号 / 路径
- ErrorDialog.swift:94 — 错误堆栈
- OSImagePickerDialog.swift:138 — ISO 路径
- VMSettingsNetworkSection+ModePickers.swift:171 — IP 地址

**回归守卫**: 评审时人工核验是否仍是"代码值"用途。

---

## 7. 业务侧无裸 Picker / Menu / TextField / SecureField / Toggle

**约束**:
- 下拉/单选 → `HVMFormSelect` / `HVMNetModeSegment`
- 输入框 → `HVMTextField`
- 开关 → `HVMToggle`

**审过结果**: 业务侧无裸 SwiftUI 控件违规。

**回归守卫**:
```bash
grep -rn "Picker(\|Menu {\|TextField(\|SecureField(\|Toggle(" \
    app/Sources/HVM/UI/{Content,Dialogs,IPSW,Detached,Settings,App,Shell}/ | \
    grep -v Style/
```
应零结果(Style/ 是组件实现层不约束)。

---

## 8. Swift 三方依赖白名单

**约束**: 仅允许 `swift-argument-parser` + `Yams`。

**审过结果**: [app/Package.swift](../../app/Package.swift) 三方依赖合规。

**回归守卫**:
```bash
grep -E "^[[:space:]]*\.package\(url:" app/Package.swift
```
应仅出现 swift-argument-parser 和 Yams。

---

## 9. patches series 文件无孤儿

**约束**: 所有 patch 必须列入 series, series 引用必须存在对应文件。

**审过结果**:
- `patches/qemu/series` 引用 3 个 patch, 全部存在
- `patches/edk2/series` 引用 1 个 patch, 存在

**回归守卫**(将进 P2 #38):
```bash
for p in patches/qemu/*.patch; do
    grep -qF "$(basename "$p")" patches/qemu/series || echo "Orphan: $p"
done
```
应无 orphan 输出。

---

## 10. .gitignore 覆盖完整

**审过结果**:
- `third_party/qemu-src/`, `third_party/qemu-stage/`
- `third_party/edk2-src/`, `third_party/edk2-stage/`
- `build/`

全部已 ignore。

**回归守卫**:
```bash
git check-ignore third_party/qemu-stage build
```
应回显两条路径(表示 ignored)。

---

## 11. 无废弃 vendor 中间层

**约束**: CLAUDE.md 明确 `third_party/qemu/` vendor 层已废弃, 不应存在。

**审过结果**: 仓库无 `third_party/qemu/` 目录。

**回归守卫**:
```bash
[ ! -d third_party/qemu ] && echo OK || echo "废弃 vendor 层重新出现"
```

---

## 12. hvm-cli HostLauncher 无 build/ fallback

**约束**: `HostLauncher.locateHVMBinary` 只查 `/Applications/HVM.app` + `~/Applications/HVM.app`, 禁止 fallback 到 `build/HVM.app`。

**审过结果**: 已合规, dev 期需先 `make install`。

**回归守卫**:
```bash
grep -n "build/HVM.app\|build/.*HVM.app" app/Sources/hvm-cli/
```
应零结果(注释 / 文档不算违规)。

---

## 总结

12 项合规守卫, 建议:
- 加入 `scripts/verify-build.sh`(已有该脚本)作为 CI 检查环节
- 任何回归立即失败构建
- 文档定期 review(每季度), 删过期项 / 加新项

---

**最后更新**: 2026-05-04
