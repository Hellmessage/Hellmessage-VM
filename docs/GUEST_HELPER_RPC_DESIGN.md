# GUEST_HELPER_RPC_DESIGN.md — 通用 guest helper RPC 设计稿

> 状态: **待评审** (2026-05-31)。评审通过后开 PR。把现有 `hvm-guest-helper`(只 ping/set-clipboard/clear-clipboard)
> 泛化成**通用 host→guest RPC**:`exec`(在登录用户会话跑命令)+ `write-file`/`read-file`(Unicode blob 传输)+ 现有剪贴板 op。
> 顺带:打成**无 DLL 单 exe** + **彻底修复文件复制**(中文 mojibake + 剪贴板可见性)。

## 1. 目标 + 范围

### 做
- **通用 RPC 协议**:同一条 virtio-serial `com.hellmessage.hvm-clipboard.0` 通道,扩展 op 集到 `exec` / `write-file` / `read-file`(+ 保留 `ping` / `set-clipboard` / `clear-clipboard`)。
- **helper 打成无 DLL 单 exe**(去掉 libunwind.dll)。
- **重做文件复制走 RPC**:helper `write-file`(会话内、Rust 原生 Unicode 写盘)+ `set-clipboard`(会话内、对用户可见)→ 一次性解决 ① 中文名 mojibake ② 剪贴板可见性。
- host 端 RPC client + `hvm-dbg helper-exec` 调试命令(也是 exec 的验证/诊断入口)。
- **宿主机安全模型(硬约束)**:信任单向——host 驱动 guest(下行控制),host 对 guest 上行**只收数据、绝不执行**。见 §5b。

### 不做(本期越界)
- 流式 stdout(exec 长任务实时输出)→ v2;v1 同步等完整结果 + per-request 超时。
- guest→host 主动推送(剪贴板反向 / 事件)→ 仍 host 发起、helper 应答。
- Linux guest helper(本 helper 仅 Windows;Linux 走 spice-vdagent / 共享目录)。

## 2. 为什么是这个方向(关键洞察)

**helper 跑在【登录用户的交互会话】(session 1),qemu-ga 跑在 SYSTEM(session 0)。**

| 能力 | qemu-ga (QGA) | hvm-guest-helper |
|---|---|---|
| 进程身份 | SYSTEM / session 0 | 登录用户 / 交互 session |
| 非 ASCII 路径 | **ANSI 代码页 → `?` mojibake** | Rust 原生宽字符, 正确 |
| 用户剪贴板 | 看不到用户会话剪贴板 | **在用户会话设, 用户可见** |
| GUI / 用户环境 | 无 | 有 |
| 权限 | 最高(SYSTEM) | 登录用户(更小, 更安全) |

→ 文件复制当前两个 bug(中文 mojibake 走 QGA push;剪贴板用户看不到)**根因都是"在 SYSTEM/session 0 干用户会话的事"**。把 write-file + clipboard 都搬到 helper(用户会话)就同时解决,且 exec 让我能**在 helper 的真实上下文里诊断**(查 window station / 直接验证 Ctrl+V)。

## 3. 协议设计

帧不变:**4-byte BE u32 length + JSON UTF-8 body**(跟 `HVMIPC/Frame.swift` 同款),单 client,request-response,host 发起。`MAX_FRAME_BYTES = 32 MiB`。

### op: `exec`
```jsonc
{"op":"exec","id":"..","shell":"powershell"|"cmd","script":"...","timeout_ms":60000,"stdin_b64":null}
→ {"id":"..","ok":true,"exit_code":0,"stdout_b64":"<base64>","stderr_b64":"<base64>"}
   失败: {"id":"..","ok":false,"code":"exec_timeout|spawn_failed","message":".."}
```
- 在 helper 的登录用户会话跑;powershell 走 `-NoProfile -NonInteractive -EncodedCommand <UTF16LE base64>`(Unicode 正确,跟现有 QGA 绕法同理但**会话对**)。
- 同步:helper 等子进程结束或 timeout(超时 kill + 返 `exec_timeout`)。

### op: `write-file`(host → guest blob)
```jsonc
{"op":"write-file","id":"..","path":"C:\\..\\中文.txt","data_b64":"..","offset":0,"final":true}
→ {"id":"..","ok":true,"bytes":1234}
```
- Rust `std::fs`(宽字符)写,**无 ANSI mojibake**。大文件分块:多帧,每帧带 `offset` + 末帧 `final:true`(offset=0 且 final 单帧即小文件)。chunk ≤ ~1 MiB(D3)。
- 首块(offset=0)若 final=false 则 truncate 创建,后续 append at offset。

### op: `read-file`(guest → host blob)
```jsonc
{"op":"read-file","id":"..","path":"C:\\..\\x","offset":0,"len":1048576}
→ {"id":"..","ok":true,"data_b64":"..","eof":false}
```

### 保留:`ping` / `set-clipboard` / `clear-clipboard`(不变)

## 4. 无 DLL 单 exe

现状:`aarch64-pc-windows-gnullvm` 默认动态链 LLVM `libunwind.dll`(即使 `panic="abort"`,预编 std 仍引用 unwinder)。

**方案 A(推荐, rustup 原生)**:nightly `-Zbuild-std=std,panic_abort -Zbuild-std-features=panic_immediate_abort` 重建 std(剔除 `panic_unwind` crate → 不再引用 libunwind),用自带 rust-lld,**不需外部 linker**。
**方案 B(兜底)**:下载 llvm-mingw → `RUSTFLAGS=-C target-feature=+crt-static`(走 `aarch64-w64-mingw32-clang` + 静态 libunwind.a/libc++.a)→ 全静态 exe。需外部工具链。

落地:新增 `patches/guest/helper-win/build.sh`(锁定构建命令 + 构建后**校验产物无非系统 DLL 依赖**,有则失败);更新 `dist/aarch64/`(只剩 exe);改 `scripts/bundle.sh`(不再拷 libunwind.dll)+ `GuestHelperInstaller`(不再 push DLL + 删 locateBundledDll)。

## 5. 文件复制重做(走 RPC)

`HVMFileClipboardBridge.publishFiles` 改:
1. 每个文件 → helper `write-file`(分块,Unicode 路径直接用原名,**不再 QGA push + PowerShell 改名**)到 `C:\ProgramData\HVM\clipboard\<原名>`。
2. helper `set-clipboard`(已会话内)。
3. **诊断 + 修剪贴板可见性**:先用 `exec` 在 helper 会话查 `GetProcessWindowStation`/`GetClipboardOwner`,确认 helper 是否在 `WinSta0\Default`;若不在,helper 设剪贴板前显式 attach(`OpenWindowStation("WinSta0")`+`SetProcessWindowStation`+`SetThreadDesktop("Default")`)。

→ 中文 mojibake + 剪贴板用户看不到 两个问题一起根治。QGA push 那条(含上次的 ASCII 临时名 + 改名 hack)可下线。

## 5b. 宿主机安全模型 **(硬约束, 不可违反)**

**信任单向:host = 权威方,guest = 不可信方。** "万能通道"指的是 **host 能驱动 guest 做任何事**(host→guest 下行 exec/write-file 是控制流);**反方向(guest→host 上行)只能是惰性数据,host 绝不运行/解释/据此驱动任何 host 侧操作**。guest 随时可能被攻陷,host 必须把 guest 的一切返回当敌意输入。

具体规则(实现 + review 都按此卡):
1. **方向铁律**:只 host 发请求、guest 应答(request-response)。guest **永不**主动发帧;host **不存在**"收到 guest 消息 → 触发 host 动作"的代码路径。没有 guest→host 的命令/事件通道。
2. **guest 返回 = 惰性 bytes**:`exec` 的 stdout/stderr、`read-file` 的 data,host 侧只**存/显示/转交调用方**,**绝不** eval / 拼成 host 命令 / 交给 host 的 shell·Process·NSTask / 反序列化成可执行对象。
3. **无 host 命令的反馈回路**:host 要发的 `exec` script 只能来自 **host/用户侧输入**,**严禁**用 guest 的任何返回内容去构造下一条 host→guest 命令(防 guest 操纵 host 行为)。
4. **无 guest 控制的 host 路径**:`read-file` 只回 bytes;**落盘到哪、文件名叫啥由 host 决定**,绝不用 guest 返回里的路径/文件名直接做 host 文件系统操作(防路径穿越)。host→guest 的路径由 host 给定。
5. **严格定长解析 + 上限**:guest 响应按固定 `Decodable` schema 解;帧 ≤ 32 MiB;base64 解码带上限;字段越界/格式错 → drop 不报错继续。无动态/任意类型反序列化,无正则/模板注入面。
6. **host 侧零执行**:host 进程对 guest 数据**只读不执行**——不 `Process`/`system`/`eval`/`dlopen`/`NSExpression` 任何 guest 来的串。

> 一句话:`exec` 是 **host 在 guest 里跑东西**(安全,host 本就全控 VM);host 这边永远只是个**收数据的哑终端**,不因 guest 说什么而在 host 上跑什么。

## 6. 风险与待验证项
- **P0-1 exec 安全边界**:见 §5b。exec 仅 host 发起(virtio-serial 单 client),身份是登录用户(< QGA 的 SYSTEM,无新增攻击面);host 侧严守"收数据不执行"。code review 专项核 §5b 六条。
- **P0-2 单 exe 无 DLL**:构建后 `llvm-objdump -p` / `strings` 校验仅依赖系统 DLL(kernel32/ntdll/user32/oleaut32/api-ms-win-*),无 libunwind/libc++/libgcc。
- **P0-3 剪贴板可见性**:用 exec 诊断 window station 后, .NET STA `Clipboard.GetFileDropList()` 在用户会话读到 = 用户 Ctrl+V 能粘。需在 `个人`/throwaway 实测。
- **P0-4 大文件分块**:write-file 分块写 + offset 正确拼接,边界(空文件 / 恰好 chunk 倍数 / >4GiB)验证。
- **验证**:`hvm-dbg helper-exec <vm> --ps "..."` 跑通 → 文件复制 e2e(中文名 + 程序化粘贴 count>0) → 单 exe DLL 校验。

## 7. PR 拆解
| PR | 内容 | 验收 |
|---|---|---|
| PR-A | Rust helper: exec + write-file + read-file op + 无 DLL 单 exe (build-std) + build.sh | 重编出单 exe (无 libunwind), `exec` echo 通 |
| PR-B | host RPC client (`HelperRpcClient` 或扩 `HVMFileClipboardBridge`) + `hvm-dbg helper-exec` | dbg helper-exec 跑 PS 拿 stdout |
| PR-C | 文件复制重做 (write-file + set-clipboard 会话内) + 诊断/修剪贴板 window station | 个人/throwaway: 中文复制 + 程序化粘贴 count>0 |
| PR-D | 回写 CLAUDE.md (helper RPC + 无 DLL) + bundle.sh/GuestHelperInstaller 去 DLL | 文档/打包一致 |

## 8. 未决事项 (Decisions)
| # | 议题 | 当前默认 |
|---|---|---|
| D1 | exec shell 支持 | powershell + cmd(raw exec 留 v2) |
| D2 | 单 exe 构建法 | A: nightly `-Zbuild-std` panic_abort(rustup 原生);B: llvm-mingw crt-static 兜底 |
| D3 | write-file/read-file chunk | 1 MiB/帧 |
| D4 | exec 同步 vs 流式 | v1 同步 + timeout;流式 v2 |
| D5 | 文件复制是否全迁 RPC + 下线 QGA push | 是(helper 在则走 RPC;QGA push 下线) |
| D6 | exec 是否也给 FileTransferDialog / 装机用 | 暂不(本期只接文件复制);后续按需 |
| D7 | 宿主机安全模型 | **信任单向 + host 对 guest 上行只收数据不执行(§5b 六条铁律), 不可违反** |
