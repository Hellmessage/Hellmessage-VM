# P0 — 立即修

影响功能正确性 / 安全, 应在 1-2 天内修完。

---

## [ ] #1 · `bundle.sh` 给 dylib/libexec 签名加了 `|| true`,会让用户启动 .app 时被 AMFI 拒签

**位置**: [scripts/bundle.sh:138](../../scripts/bundle.sh:138), [scripts/bundle.sh:145](../../scripts/bundle.sh:145)

**当前代码**:
```bash
codesign "${QEMU_SIGN_ARGS[@]}" "$f" || true   # ← 错: lib/*.dylib + libexec/* 失败被吞
```

对比 [bundle.sh:151](../../scripts/bundle.sh:151) 的 `bin/*` 是正确的(无 `|| true`)。后续 `codesign --verify --deep --strict`(行 164)对嵌套 dylib 检测不够严, 真正报错要等用户点开 .app 时 SIGKILL。

**修复**:
- 删掉 `lib/` 与 `libexec/` 两处 `|| true`
- 让签名失败立即 fail-fast

**验证**:
- 故意把某个 dylib 改坏 (chmod 000) 跑 `make build`, 应在 bundle.sh 阶段失败而不是 verify 阶段 silent pass

---

## [ ] #2 · `install-vmnet-daemons.sh` 白名单 reject 后只 `continue`,脚本仍 exit 0

**位置**: [scripts/install-vmnet-daemons.sh:150-159](../../scripts/install-vmnet-daemons.sh:150)

**当前代码**:
```bash
for iface in "$@"; do
    if ! [[ "$iface" =~ ^[a-zA-Z0-9]+$ ]]; then
        echo "    ⚠ 跳过非法接口名 '$iface'"
        continue                # ← GUI/CI 调用方拿到 0 退出码,以为成功
    fi
    install_one ...
done
```

Touch ID 提权场景下用户不会留意 stderr, 会以为安装成功但实际 daemon 没装。**安全风险**: 配合 plist heredoc 直拼(见 #17), 攻击者若能影响接口名输入(虽然现状 osascript 路径不会)还可能拼出非法 plist。

**修复**:
- 非法接口名直接 `err "非法接口名: $iface (仅允许 [a-zA-Z0-9]+)"` 退出非 0
- GUI / CI 都能感知失败

**验证**:
- 跑 `sudo ./install-vmnet-daemons.sh "en0; rm -rf /"` 应 exit 1 且不创建任何 plist

---

## [ ] #3 · swtpm sidecar 进程清理时序错,可能写坏 NVRAM

**位置**: [app/Sources/HVM/QemuHostEntry.swift:412](../../app/Sources/HVM/QemuHostEntry.swift:412) 附近 + [app/Sources/HVMQemu/SidecarProcessRunner.swift](../../app/Sources/HVMQemu/SidecarProcessRunner.swift) `forceKill`

**问题**:
- `forceKill` → `waitUntilExit` → `lock.release()` 链路上,`runAsRoot=true` 时 `forceKill` 走 `sudo pkill -9 -P <pid>` 是异步的
- `waitUntilExit` 拿到的是 wrapper sudo 的退出, 不是 swtpm 真退出
- lock 释放后 swtpm 还可能向 vTPM NVRAM 写一帧, 数据可能损坏

**修复**:
- `SidecarProcessRunner.forceKill` 同步等 pkill 完成
- 或在 `waitUntilExit` 之后加 ~500ms 安全 sleep 再 release lock
- 更稳: 把 swtpm 装到 `setsid` 子会话, 用 SIGTERM + SIGKILL 双段, 每段 polled

**验证**:
- 反复跑 "Win11 装机中途强制 stop" 50 次, 确认 NVRAM 不损坏(下次启动 TPM 仍可用)

---

## [ ] #4 · App 退出时 graceful shutdown 不等 forceStop 完成,留孤儿 QEMU/swtpm

**位置**: [app/Sources/HVM/HVMApp.swift:111-127](../../app/Sources/HVM/HVMApp.swift:111)

**当前代码**:
```swift
for s in model.sessions.values where s.state != .stopped {
    try? await s.forceStop()    // 不等真转 stopped 就 return
}
```

退出后用户看到 `ps aux | grep qemu` 还在, 需手动 kill。

**修复**:
- `forceStop` 后 poll session.state 到 `.stopped` 或 5s 超时
- 超时仍未停止时 `os_log` 报告残留 PID, 让用户手动清

**示例**:
```swift
for s in model.sessions.values where s.state != .stopped {
    try? await s.forceStop()
    let deadline = Date().addingTimeInterval(5)
    while s.state != .stopped && Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if s.state != .stopped {
        HVMLog.logger().error("退出时 VM \(s.id) 未停止 PID=\(s.pid ?? 0)")
    }
}
```

**验证**:
- GUI 起 3 个 VM, Cmd+Q 退出, 5s 后 `ps aux | grep -E 'qemu|swtpm'` 应无残留

---

## [ ] #5 · `BundleLock.release()` 非线程安全,double-close 风险

**位置**: [app/Sources/HVMBundle/BundleLock.swift:81](../../app/Sources/HVMBundle/BundleLock.swift:81)

**当前代码**:
```swift
public func release() {
    guard !released else { return }
    released = true
    _ = flock(fd, LOCK_UN)
    close(fd)
}

deinit { release() }
```

**问题**:
- `released` 是非原子 Bool
- deinit 与显式 release 可能并发跑(Task 持有 + ARC 释放)
- 两路都通过 guard 后 `close(fd)` 两次
- macOS `close()` 行为不保证幂等(可能 close 别的 fd, 引发难诊断的 fd 串台)

**修复**:
```swift
private let releaseLock = NSLock()
public func release() {
    releaseLock.lock()
    defer { releaseLock.unlock() }
    guard !released else { return }
    released = true
    _ = flock(fd, LOCK_UN)
    close(fd)
}
```
或改 `os_unfair_lock`(更轻)。

**验证**:
- 加 stress 测试: 100 个并发 Task 同时调 release, 断言只有一次 close
- TSan 跑测试套件应无报警

---

## [ ] #6 · `qemu-build.sh` 的 `mktemp` 没 trap,异常退出泄露 tmp

**位置**: [scripts/qemu-build.sh:389](../../scripts/qemu-build.sh:389)

**问题**:
- `bundle_dylib_deps` 内 `mktemp -t hvm-bundle-deps`
- 函数递归内任何 `install_name_tool` 失败(目前是 warn 不 fail), 但若真异常退出, tmp 文件不清
- 反复 `make qemu` 堆 `/var/folders/.../hvm-bundle-deps.*`

**修复**:
```bash
processed="$(mktemp -t hvm-bundle-deps)"
trap 'rm -f "$processed"' EXIT
: > "$processed"
bundle_dylib_deps "$bin_dst" "$lib_dir" "$processed"
# rm -f 由 trap 兜底
```

**验证**:
- 故意 `kill -INT $$` 中断 `make qemu`, 检查 `/var/folders/` 下无残留 hvm-bundle-deps.*

---

## P0 完成判定

- [ ] 所有 6 项验证通过
- [ ] `make build` + `make install` 跑通
- [ ] 跑一次 Win11 + Linux + macOS 装机闭环, 退出时无孤儿进程
- [ ] CLAUDE.md / docs/v1/ 同步更新影响约束的章节(主要是 BUILD_SIGN.md 与 NETWORK.md)

---

**最后更新**: 2026-05-03
