# P2 — 持续改进 / 技术债

与功能开发并行, 每周清 2-3 项。21 项, 按主题分组。

---

## A. 错误处理 / 可观测性

### [x] #18 · `OCREngine.recognize` 失败被降级为 `("boot-logo", 0.5)`,自动化测试假阳 — 已修 (commit ddbfd38)

**位置**: [app/Sources/HVM/DbgOps.swift:248-254](../../app/Sources/HVM/DbgOps.swift:248)

**问题**: OCR 框架未初始化 / 内存不足时也返回 `boot-logo`, `hvm-dbg` 调用方误判为 "VM 在 boot logo 阶段"。

**修复**: OCR 错误明确返回 `dbg.ocr_unavailable`, 让上层重试或 abort:
```swift
do { items = try OCREngine.recognize(pngData: shot.data, region: nil) }
catch {
    return .failure(id: req.id, code: "dbg.ocr_unavailable",
                    message: "OCR 引擎故障: \(error)")
}
```

---

### [~] #29 · `LogSink` 初始化不验证 logsDir 可写,首次写入 panic — 重新评估: 实际架构已防御 (write 路径 `guard let fh = fileHandle else { return }`, rotate 失败 fileHandle 留 nil 自动降级 silent mode), 不会 panic. 不动.

**位置**: [app/Sources/HVMCore/LogSink.swift:56](../../app/Sources/HVMCore/LogSink.swift:56)

**问题**: 用户若给 `~/Library/Application Support/` chmod 错权限, 初始化通过, 写日志时 crash。

**修复**: init 内 `try? createDirectory + 写探针文件`, 失败降级到 `NSTemporaryDirectory()` + log 警告。

---

### [x] #30 · `HVMApp.gracefulShutdownAll` 内 `try? requestStop()` 失败无日志 — 已修 (commit 35a3954, P0 #4 同主题顺带修)

**位置**: [app/Sources/HVM/HVMApp.swift:111](../../app/Sources/HVM/HVMApp.swift:111)

**修复**: `do/catch` + `os_log` 记录每个失败的 VM ID + 错误。

---

### [x] #31 · `ErrorDialog` / `ConfirmDialog` 只靠注释禁止 `NSAlert`,无强制 — 已修 (commit ddbfd38, verify-build.sh grep 守卫)

**位置**: [app/Sources/HVM/UI/Dialogs/](../../app/Sources/HVM/UI/Dialogs)

**问题**: 新人易绕开。

**修复**(任选):
- `.swiftlint.yml` 自定义规则禁用 `NSAlert`
- CI 加 `grep -rn "NSAlert" app/Sources/HVM/UI/ && exit 1` 守卫

---

## B. 代码精简 / 死代码

### [x] #19 · `DbgOps.guestFramebufferSize()` TODO 长期未做 — 已修 (commit f4bc610, VMConfig 加可选 displaySpec, 不需要 schema v3 升级)

**位置**: [app/Sources/HVM/DbgOps.swift:234](../../app/Sources/HVM/DbgOps.swift:234)

**问题**: 注释 "将来 VMConfig 加 displaySpec 后, 这里改成读 config", 当前硬编码分辨率会让 hvm-dbg 截图坐标计算错。

**修复**:
- VMConfig 加 `DisplaySpec { width, height, ppi }`
- ConfigBuilder 与 DbgOps 都读它
- ConfigMigrator 加 v2→v3 hook 给老配置补 default(1280×720)

---

### [~] #20 · `ConfigBuilder` 是 `enum` 包单 static func + 单 struct,过度设计 — 重新评估: 实际含 1 public func + 2 private helper + 1 struct, enum 是合理 namespace. 不动.

**位置**: [app/Sources/HVMBackend/ConfigBuilder.swift:13](../../app/Sources/HVMBackend/ConfigBuilder.swift:13)

**修复**: 并入 VMHandle factory, 或改为 free function。

---

### [~] #21 · `HVMTextField.Handler` 包了 `label + closure`,本质就是 `.onSubmit` — 重新评估: 实际是 `ActionButton` (label + handler) 用作文件选择器 trailing button, 非 onSubmit. 不动. 顺带修 Style 层 2 处硬编码 (commit f1f872d).

**位置**: [app/Sources/HVM/UI/Style/HVMTextField.swift:10](../../app/Sources/HVM/UI/Style/HVMTextField.swift:10)

**修复**: 暴露 `.onSubmit { }` modifier, 删 Handler struct。

---

### [~] #22 · `VMSession.observerToken: UUID?` 死字段 — 重新评估: 实际有 `addStateObserver` register + cleanup 时 unregister 路径 (行 101 / 191). 非死字段. 不动.

**位置**: [app/Sources/HVM/UI/Content/VMSession.swift](../../app/Sources/HVM/UI/Content/VMSession.swift)

**问题**: 没 register 也没 unregister, 纯死代码。

**修复**: 删除字段。

---

### [x] #23 · `QemuPaths.swift` 注释提到 `third_party/qemu-stage` 兜底,与 CLAUDE.md 约束矛盾 — 已修 (commit f1f872d, 重写 socket_vmnet locator 注释对齐 CLAUDE.md 现状)

**位置**: [app/Sources/HVMQemu/QemuPaths.swift:10](../../app/Sources/HVMQemu/QemuPaths.swift:10)

**问题**:
- CLAUDE.md 约束 "严禁 fallback 到 third_party/qemu-stage"
- 代码注释还在说 "swift run / swift test 兜底"

**修复**: 核实代码是否真有 fallback 逻辑, 有则按约束删, 没有则同步注释。

---

## C. 配置 / Schema 健壮性

### [x] #24 · `ConfigMigrator` 链式 hook 框架空跑,未来加 v2→v3 迁移时易引数据丢失 — 已修 (commit f4bc610, 加幂等约束硬规则文档)

**位置**: [app/Sources/HVMBundle/ConfigMigrator.swift](../../app/Sources/HVMBundle/ConfigMigrator.swift)

**问题**:
- 当前没 hook, 但框架已有
- 未来加 hook 时, 若用户已用过 v2 一段时间, 运行迁移可能覆盖用户后改的字段(无幂等标记)

**修复**:
- 加第一条 hook **之前** 先补迁移测试 + 幂等约定文档
- 每条 hook 必须满足: `migrate(migrate(x)) == migrate(x)`

---

### [x] #25 · `DiskFactory.create / grow` qcow2 分支无测试覆盖 — 已修 (commit 5fe59a4, 修破老 raw tests + 加 2 个 qcow2 缺 qemuImg 拒绝路径 cases)

**位置**:
- 实现: [app/Sources/HVMStorage/DiskFactory.swift](../../app/Sources/HVMStorage/DiskFactory.swift)
- 测试: [app/Tests/HVMStorageTests](../../app/Tests/HVMStorageTests)

**问题**: 测试只覆盖 raw + ftruncate; qcow2 走 `qemu-img` 子进程, 执行路径完全不同, 无验证。

**修复**:
- 加 qcow2 创建 / resize / 错误处理用例
- fixture mock `qemu-img` 二进制存在性

---

### [x] #26 · `HVMScmRecv` C 层无单测 — 已修 (commit 5fe59a4, 新建 HVMScmRecvTests target, socketpair round-trip 3 cases: 0 fd / 单 fd dup / 多 fd EPROTO 拒绝)

**位置**: [app/Sources/HVMScmRecv/recv_fd.c](../../app/Sources/HVMScmRecv/recv_fd.c)

**问题**:
- recvmsg + cmsg_type 校验逻辑写在 C, 但 Swift 侧无测试包装
- 多 fd 拦截 / EINTR / 缓冲溢出等边界无验证

**修复**: Swift wrapper + XCTest 跑 socketpair → sendmsg/recvmsg round-trip。

---

### [x] #27 · Bundle flock 互斥无并发测试 — 已修 (commit 5fe59a4, BundleLockTests 6 cases 含 100 路并发 release / 同进程二次抢锁 .busy / inspect)

**位置**:
- 实现: [app/Sources/HVMBundle/BundleLock.swift](../../app/Sources/HVMBundle/BundleLock.swift)
- 测试: [app/Tests/HVMBundleTests](../../app/Tests/HVMBundleTests)

**问题**: 核心约束 "一个 .hvmz 同时只能被一个进程打开" 无测试。

**修复**: XCTest 起两个 `Process(self)` 抢同一个 lock 文件, 断言后到的 EWOULDBLOCK。

---

## D. 资源生命周期

### [x] #28 · `SidecarProcessRunner` stderr `readabilityHandler` 在进程被 SIGKILL 时不一定收到 EOF — 已修 (commit eebe29f, terminationHandler 显式清 readabilityHandler)

**位置**: [app/Sources/HVMQemu/SidecarProcessRunner.swift:120](../../app/Sources/HVMQemu/SidecarProcessRunner.swift:120)

**问题**: 仅靠 `availableData.isEmpty` 判 EOF, SIGKILL 路径可能死锁读线程。

**修复**:
```swift
process.terminationHandler = { [weak self] _ in
    self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
    ...
}
```

---

## E. 脚本健壮性

### [x] #32 · Makefile `run-app` 杀进程靠 `awk NF == 2`,不稳健 — 已修 (commit 38c81b8, 改 cmdline regex 匹配)

**位置**: [Makefile:130-138](../../Makefile:130)

**问题**: 用户带参启动时字段数 > 2 会漏杀。

**修复**:
```bash
OLDPID=$$(ps -axo pid,command | awk '$$2 ~ /\/HVM\.app\/Contents\/MacOS\/HVM$$/ {print $$1}' | head -1)
```

---

### [x] #33 · `verify-build.sh` 用 `plutil -extract` 不检查返回码,空值与 "格式错" 无法区分 — 已修 (commit 38c81b8)

**位置**: [scripts/verify-build.sh:16](../../scripts/verify-build.sh:16)

**修复**:
```bash
BID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist") || \
    fail "Info.plist 损坏或缺 CFBundleIdentifier"
```

---

### [x] #34 · `bundle.sh` 在 detached HEAD / 无 tag 时版本号写死 `0.0.1` — 已修 (commit 38c81b8, 降级到 dev-<sha7>)

**位置**: [scripts/bundle.sh:59](../../scripts/bundle.sh:59)

**修复**:
```bash
if git -C "$ROOT" describe --tags >/dev/null 2>&1; then
    VERSION=$(git -C "$ROOT" describe --tags --always --dirty)
else
    VERSION="dev-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
fi
```

---

### [~] #36 · `edk2-build.sh` 的 `fix_basetools_for_macos` sed 非幂等 — 重新评估: 行 128-129 已 `if grep -q ... then ok else sed`, 实际是 idempotent. 不动.

**位置**: [scripts/edk2-build.sh:125](../../scripts/edk2-build.sh:125)

**问题**: sed -i.bak 生成 `.bak` 文件, 第二次跑时已清, 二次 patch 行为难预测。

**修复**: check-then-patch:
```bash
if ! grep -q 'Wno-macro-redefined' "$mk"; then
    sed -i "" 's|...|...|g' "$mk"
fi
```

---

### [x] #37 · `qemu-build.sh` `apply_patches` 读 series 末行无 `\n` 时漏读 — 已修 (commit 38c81b8, 加 `|| [[ -n "$line" ]]` 兜底跟 edk2-build 同步)

**位置**: [scripts/qemu-build.sh:134-160](../../scripts/qemu-build.sh:134)

**问题**: 与 `edk2-build.sh:147` 不一致(后者已正确处理)。

**修复**:
```bash
while IFS= read -r line || [[ -n "$line" ]]; do
    ...
done < "$series"
```

---

### [x] #38 · patches 孤儿检测缺失 — 已修 (commit 38c81b8, verify-build.sh 加 check_orphan_patches qemu + edk2)

**问题**:
- `patches/{qemu,edk2}/series` 当前完整
- 但 CI 没有 "`*.patch` 必在 series 中" 检查
- 新加补丁时容易漏改 series 文件

**修复**: `verify-build.sh` 加循环:
```bash
for p in patches/qemu/*.patch; do
    [ -f "$p" ] || continue
    grep -qF "$(basename "$p")" patches/qemu/series || \
        fail "Orphan patch: $p (未列入 series)"
done
# edk2 同理
```

---

## F. 用户体验

### [x] #35 · `CreateVMDialog` Windows 禁用提示暴露内部路径 — 已修 (commit f1f872d, 删 `third_party/qemu-stage` 改为"此版本未含 QEMU 后端")

**位置**: [CreateVMDialog.swift:187](../../app/Sources/HVM/UI/Dialogs/CreateVMDialog.swift:187)

**当前**: `Text("Windows 暂不可选 — third_party/qemu-stage 未就绪 (需先 make qemu)")`
- 把 dev path 暴露给用户
- 暗露了项目内部结构

**修复**: 改为 `Text("Windows 暂不支持 — 此版本未包含 QEMU 后端")` 或 `"Windows 需完整版 HVM (含 QEMU 后端), 当前包未集成"`。

---

## P2 完成判定

- [x] 21 项中 **17 项已修** + **4 项重新评估判错不动** (#20 / #21 / #22 / #29 / #36)
- [x] 测试覆盖三组新增 (DiskFactory qcow2 / HVMScmRecv socketpair / BundleLock 并发)
- [x] verify-build.sh 加 NSAlert 守卫 + patches 孤儿检测
- [x] VMConfig 加 displaySpec 可选字段 (#19, 不需要 schema v3)
- [ ] **待 toolchain 修**: swift test 跑通 (xcode-select 指向 Xcode.app 后即可, 项目级既有)

## 修复 commit 索引

| 项 | 内容 | commit |
|---|---|---|
| #18 | OCR 失败明确报错 | [`ddbfd38`](https://example/commit/ddbfd38) |
| #19 | DisplaySpec 可选字段落地 | [`f4bc610`](https://example/commit/f4bc610) |
| #20 | (重新评估, 不动) | — |
| #21 | (重新评估, 不动) + Style 层 token 补漏 | [`f1f872d`](https://example/commit/f1f872d) |
| #22 | (重新评估, 不动) | — |
| #23 | QemuPaths.swift 注释重写 | [`f1f872d`](https://example/commit/f1f872d) |
| #24 | ConfigMigrator 幂等约束文档 | [`f4bc610`](https://example/commit/f4bc610) |
| #25 | DiskFactory raw 老 tests 修 + qcow2 cases | [`5fe59a4`](https://example/commit/5fe59a4) |
| #26 | HVMScmRecvTests target | [`5fe59a4`](https://example/commit/5fe59a4) |
| #27 | BundleLockTests 6 cases | [`5fe59a4`](https://example/commit/5fe59a4) |
| #28 | SidecarProcessRunner readabilityHandler | [`eebe29f`](https://example/commit/eebe29f) |
| #29 | (重新评估, 不动 — 已防御) | — |
| #30 | (P0 #4 顺带修) | [`35a3954`](https://example/commit/35a3954) |
| #31 | verify-build.sh NSAlert 守卫 | [`ddbfd38`](https://example/commit/ddbfd38) |
| #32 / #33 / #34 / #37 / #38 | Makefile run-app + verify-build plutil + bundle.sh 版本 + qemu-build series + patches 孤儿 | [`38c81b8`](https://example/commit/38c81b8) |
| #35 | CreateVMDialog 内部路径替换 | [`f1f872d`](https://example/commit/f1f872d) |
| #36 | (重新评估, 不动) | — |

---

**最后更新**: 2026-05-04
