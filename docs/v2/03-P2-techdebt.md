# P2 — 持续改进 / 技术债

与功能开发并行, 每周清 2-3 项。21 项, 按主题分组。

---

## A. 错误处理 / 可观测性

### [ ] #18 · `OCREngine.recognize` 失败被降级为 `("boot-logo", 0.5)`,自动化测试假阳

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

### [ ] #29 · `LogSink` 初始化不验证 logsDir 可写,首次写入 panic

**位置**: [app/Sources/HVMCore/LogSink.swift:56](../../app/Sources/HVMCore/LogSink.swift:56)

**问题**: 用户若给 `~/Library/Application Support/` chmod 错权限, 初始化通过, 写日志时 crash。

**修复**: init 内 `try? createDirectory + 写探针文件`, 失败降级到 `NSTemporaryDirectory()` + log 警告。

---

### [ ] #30 · `HVMApp.gracefulShutdownAll` 内 `try? requestStop()` 失败无日志

**位置**: [app/Sources/HVM/HVMApp.swift:111](../../app/Sources/HVM/HVMApp.swift:111)

**修复**: `do/catch` + `os_log` 记录每个失败的 VM ID + 错误。

---

### [ ] #31 · `ErrorDialog` / `ConfirmDialog` 只靠注释禁止 `NSAlert`,无强制

**位置**: [app/Sources/HVM/UI/Dialogs/](../../app/Sources/HVM/UI/Dialogs)

**问题**: 新人易绕开。

**修复**(任选):
- `.swiftlint.yml` 自定义规则禁用 `NSAlert`
- CI 加 `grep -rn "NSAlert" app/Sources/HVM/UI/ && exit 1` 守卫

---

## B. 代码精简 / 死代码

### [ ] #19 · `DbgOps.guestFramebufferSize()` TODO 长期未做

**位置**: [app/Sources/HVM/DbgOps.swift:234](../../app/Sources/HVM/DbgOps.swift:234)

**问题**: 注释 "将来 VMConfig 加 displaySpec 后, 这里改成读 config", 当前硬编码分辨率会让 hvm-dbg 截图坐标计算错。

**修复**:
- VMConfig 加 `DisplaySpec { width, height, ppi }`
- ConfigBuilder 与 DbgOps 都读它
- ConfigMigrator 加 v2→v3 hook 给老配置补 default(1280×720)

---

### [ ] #20 · `ConfigBuilder` 是 `enum` 包单 static func + 单 struct,过度设计

**位置**: [app/Sources/HVMBackend/ConfigBuilder.swift:13](../../app/Sources/HVMBackend/ConfigBuilder.swift:13)

**修复**: 并入 VMHandle factory, 或改为 free function。

---

### [ ] #21 · `HVMTextField.Handler` 包了 `label + closure`,本质就是 `.onSubmit`

**位置**: [app/Sources/HVM/UI/Style/HVMTextField.swift:10](../../app/Sources/HVM/UI/Style/HVMTextField.swift:10)

**修复**: 暴露 `.onSubmit { }` modifier, 删 Handler struct。

---

### [ ] #22 · `VMSession.observerToken: UUID?` 死字段

**位置**: [app/Sources/HVM/UI/Content/VMSession.swift](../../app/Sources/HVM/UI/Content/VMSession.swift)

**问题**: 没 register 也没 unregister, 纯死代码。

**修复**: 删除字段。

---

### [ ] #23 · `QemuPaths.swift` 注释提到 `third_party/qemu-stage` 兜底,与 CLAUDE.md 约束矛盾

**位置**: [app/Sources/HVMQemu/QemuPaths.swift:10](../../app/Sources/HVMQemu/QemuPaths.swift:10)

**问题**:
- CLAUDE.md 约束 "严禁 fallback 到 third_party/qemu-stage"
- 代码注释还在说 "swift run / swift test 兜底"

**修复**: 核实代码是否真有 fallback 逻辑, 有则按约束删, 没有则同步注释。

---

## C. 配置 / Schema 健壮性

### [ ] #24 · `ConfigMigrator` 链式 hook 框架空跑,未来加 v2→v3 迁移时易引数据丢失

**位置**: [app/Sources/HVMBundle/ConfigMigrator.swift](../../app/Sources/HVMBundle/ConfigMigrator.swift)

**问题**:
- 当前没 hook, 但框架已有
- 未来加 hook 时, 若用户已用过 v2 一段时间, 运行迁移可能覆盖用户后改的字段(无幂等标记)

**修复**:
- 加第一条 hook **之前** 先补迁移测试 + 幂等约定文档
- 每条 hook 必须满足: `migrate(migrate(x)) == migrate(x)`

---

### [ ] #25 · `DiskFactory.create / grow` qcow2 分支无测试覆盖

**位置**:
- 实现: [app/Sources/HVMStorage/DiskFactory.swift](../../app/Sources/HVMStorage/DiskFactory.swift)
- 测试: [app/Tests/HVMStorageTests](../../app/Tests/HVMStorageTests)

**问题**: 测试只覆盖 raw + ftruncate; qcow2 走 `qemu-img` 子进程, 执行路径完全不同, 无验证。

**修复**:
- 加 qcow2 创建 / resize / 错误处理用例
- fixture mock `qemu-img` 二进制存在性

---

### [ ] #26 · `HVMScmRecv` C 层无单测

**位置**: [app/Sources/HVMScmRecv/recv_fd.c](../../app/Sources/HVMScmRecv/recv_fd.c)

**问题**:
- recvmsg + cmsg_type 校验逻辑写在 C, 但 Swift 侧无测试包装
- 多 fd 拦截 / EINTR / 缓冲溢出等边界无验证

**修复**: Swift wrapper + XCTest 跑 socketpair → sendmsg/recvmsg round-trip。

---

### [ ] #27 · Bundle flock 互斥无并发测试

**位置**:
- 实现: [app/Sources/HVMBundle/BundleLock.swift](../../app/Sources/HVMBundle/BundleLock.swift)
- 测试: [app/Tests/HVMBundleTests](../../app/Tests/HVMBundleTests)

**问题**: 核心约束 "一个 .hvmz 同时只能被一个进程打开" 无测试。

**修复**: XCTest 起两个 `Process(self)` 抢同一个 lock 文件, 断言后到的 EWOULDBLOCK。

---

## D. 资源生命周期

### [ ] #28 · `SidecarProcessRunner` stderr `readabilityHandler` 在进程被 SIGKILL 时不一定收到 EOF

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

### [ ] #32 · Makefile `run-app` 杀进程靠 `awk NF == 2`,不稳健

**位置**: [Makefile:130-138](../../Makefile:130)

**问题**: 用户带参启动时字段数 > 2 会漏杀。

**修复**:
```bash
OLDPID=$$(ps -axo pid,command | awk '$$2 ~ /\/HVM\.app\/Contents\/MacOS\/HVM$$/ {print $$1}' | head -1)
```

---

### [ ] #33 · `verify-build.sh` 用 `plutil -extract` 不检查返回码,空值与 "格式错" 无法区分

**位置**: [scripts/verify-build.sh:16](../../scripts/verify-build.sh:16)

**修复**:
```bash
BID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist") || \
    fail "Info.plist 损坏或缺 CFBundleIdentifier"
```

---

### [ ] #34 · `bundle.sh` 在 detached HEAD / 无 tag 时版本号写死 `0.0.1`

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

### [ ] #36 · `edk2-build.sh` 的 `fix_basetools_for_macos` sed 非幂等

**位置**: [scripts/edk2-build.sh:125](../../scripts/edk2-build.sh:125)

**问题**: sed -i.bak 生成 `.bak` 文件, 第二次跑时已清, 二次 patch 行为难预测。

**修复**: check-then-patch:
```bash
if ! grep -q 'Wno-macro-redefined' "$mk"; then
    sed -i "" 's|...|...|g' "$mk"
fi
```

---

### [ ] #37 · `qemu-build.sh` `apply_patches` 读 series 末行无 `\n` 时漏读

**位置**: [scripts/qemu-build.sh:134-160](../../scripts/qemu-build.sh:134)

**问题**: 与 `edk2-build.sh:147` 不一致(后者已正确处理)。

**修复**:
```bash
while IFS= read -r line || [[ -n "$line" ]]; do
    ...
done < "$series"
```

---

### [ ] #38 · patches 孤儿检测缺失

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

### [ ] #35 · `CreateVMDialog` Windows 禁用提示暴露内部路径

**位置**: [CreateVMDialog.swift:187](../../app/Sources/HVM/UI/Dialogs/CreateVMDialog.swift:187)

**当前**: `Text("Windows 暂不可选 — third_party/qemu-stage 未就绪 (需先 make qemu)")`
- 把 dev path 暴露给用户
- 暗露了项目内部结构

**修复**: 改为 `Text("Windows 暂不支持 — 此版本未包含 QEMU 后端")` 或 `"Windows 需完整版 HVM (含 QEMU 后端), 当前包未集成"`。

---

## P2 完成判定

- 与功能开发并行清, 不强求一次性完成
- 每月底 review 一次进度, 长期未动的项要么做、要么从 v2 撤回放到 docs/ROADMAP 不做清单
- 全部清完后 v2 文档可滚归并到 CHANGELOG

---

**最后更新**: 2026-05-04
