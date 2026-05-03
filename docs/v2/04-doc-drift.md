# 文档漂移修订项

CLAUDE.md / README.md / docs/v1 与代码现状的不一致点。

---

## [ ] D1 · CLAUDE.md "sidecar fd-passing 路径已下线" 表述不准

**位置**: [CLAUDE.md](../../CLAUDE.md) 第 128 行附近

**当前表述**:
> 不需要 socket_vmnet_client wrapper, 不需要父进程 socket()/connect() 把 fd 透传给子进程 (老的 sidecar fd-passing 路径已下线)

**实际情况**:
- HVMScmRecv 仍是 active SwiftPM target([app/Package.swift:60](../../app/Package.swift:60))
- HVMDisplayQemu 仍 import HVMScmRecv([DisplayChannel.swift:19](../../app/Sources/HVMDisplayQemu/DisplayChannel.swift:19))
- fd 接收并未"下线", 而是从 socket_vmnet 的 sidecar 路径迁到 HDP 协议内的 SCM_RIGHTS 一部分(QEMU iosurface display backend ↔ HVM 主进程)

**修复**: CLAUDE.md 该行改为:
```
- (老的 sidecar fd-passing 路径在 socket_vmnet 集成中已下线;
   HDP 协议内 fd 接收 (iosurface 帧缓冲 IOSurface fd) 仍走 SCM_RIGHTS,
   由 HVMScmRecv 提供 C 胶水层)
```

---

## [ ] D2 · README.md socket_vmnet 是否入包描述含糊

**位置**: [README.md](../../README.md) 网络章节

**冲突**:
- CLAUDE.md 第 112 条明确 "socket_vmnet 不入包, 用户自行 brew install"
- README 当前措辞可能让用户以为 .app 自带

**修复**: README 网络段加一行:
```
依赖 `brew install socket_vmnet` (HVM 不打包此二进制, 走系统 brew 提供)。
首次启用 bridged 网络时 GUI 会引导安装 launchd daemon (Touch ID 提权)。
```

---

## [ ] D3 · CLAUDE.md `BundleLayout` 老 API 描述需复核(已部分对齐)

**位置**: [CLAUDE.md](../../CLAUDE.md) "VM 配置 (config.yaml) 约束" 章节

**情况**:
- CLAUDE.md 已正确说明 "BundleLayout 已删 mainDiskName / mainDiskURL(_ bundle) 老 API"
- VMConfig.mainDiskURL(in:) 是运行时辅助, 保留

**待办**: 此项是检查项(无修改), 但需确认:
- [ ] grep 全仓库无 `BundleLayout.mainDiskName` 引用
- [ ] grep 全仓库无 `BundleLayout.mainDiskURL` 引用
- [ ] 若有残留则按 CLAUDE.md 删

---

## [ ] D4 · docs/v1/QEMU_DISPLAY_PROTOCOL.md 版本号需对齐 patch 中 C header

**位置**:
- 文档: [docs/v1/QEMU_DISPLAY_PROTOCOL.md](../v1/QEMU_DISPLAY_PROTOCOL.md) 头部 v1.0.0
- Swift: [app/Sources/HVMDisplayQemu/HDPProtocol.swift](../../app/Sources/HVMDisplayQemu/HDPProtocol.swift) majorVersion=1, minorVersion=0, patchVersion=0
- C: `patches/qemu/0002-ui-iosurface-display-backend.patch` 内 `hvm_display_proto.h`

**待办**: 确认三处版本字段一致, 协议变更时三处必须同步。

---

## [ ] D5 · v1 todo.md 已完成项滚动清理

**位置**: [docs/v1/todo.md](../v1/todo.md) "✅ 最近完成" 段

**问题**:
- 当前列了 ~16 条 2026-04-26 ~ 2026-05-03 的完成项, 部分已超过 2 周
- 长期堆积让 todo 变 changelog, 混淆"未完成"与"历史"

**修复**:
- 重构 todo.md 时, 把 2 周前完成项迁移到 ROADMAP.md 的 "✅ 完成" 段
- todo.md 仅保留最近 2 周的完成项作上下文
- 设定每月清理一次的提醒(放 ROADMAP)

---

## [ ] D6 · 检查 docs/v1/NETWORK.md socket_vmnet 描述与 CLAUDE.md 一致

**位置**: [docs/v1/NETWORK.md](../v1/NETWORK.md)

**待办**: v1 文档重构时确认:
- socket_vmnet 不入包
- launchd plist label 命名空间 `com.hellmessage.hvm.vmnet.*`
- 固定路径 socket(`/var/run/socket_vmnet*`)
- 提权方式: GUI osascript Touch ID, **非** sudoers
- QEMU 直接 `-netdev stream,addr.type=unix,addr.path=...`, 无 sidecar

---

## 修复完成判定

- [ ] D1, D2 改完(CLAUDE.md + README.md)
- [ ] D3 grep 检查通过
- [ ] D4 三处版本号锁定写入 CLAUDE.md(协议变更约束)
- [ ] D5 v1/todo.md 重构(并入 v1 重构流程)
- [ ] D6 在 v1/NETWORK.md 重构时一并处理

---

**最后更新**: 2026-05-04
