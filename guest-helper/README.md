# hvm-guest-helper

HVM 给 Windows guest 的 user-session helper service.

跟 host 端通过新 virtio-serial chardev (`com.hellmessage.hvm-clipboard.0`) 收 JSON
指令, 调 Windows `SetClipboardData(CF_HDROP, ...)` 设置用户剪贴板. 主要给 UTM 风格
"paste-where-you-paste" 文件粘贴用 — host 端 Cmd+C 一个 macOS 文件, 后台传到 guest,
helper 把 guest 端文件路径写进 Windows clipboard, 用户在 guest 任意 app Ctrl+V
触发原生 paste (Explorer 拷贝文件 / Telegram 上传图片 / Word 嵌入...).

设计稿: [`docs/v3/HOST_FILE_CLIPBOARD.md`](../docs/v3/HOST_FILE_CLIPBOARD.md)

---

## 构建

### 跨平台编译 (从 macOS 编 Windows arm64 EXE)

需要 LLVM-MinGW 工具链 (clang + lld + windows sysroot). Homebrew 没现成包,
从 GitHub releases 下载:

```bash
# 1. 下载 llvm-mingw arm64 macOS host 版 (~300 MB; 一次性)
curl -L -o /tmp/llvm-mingw.tar.xz \
  https://github.com/mstorsjo/llvm-mingw/releases/download/20251208/llvm-mingw-20251208-ucrt-macos-arm64.tar.xz

# 2. 解压到 /opt/llvm-mingw
sudo mkdir -p /opt/llvm-mingw
sudo tar -xJf /tmp/llvm-mingw.tar.xz -C /opt/llvm-mingw --strip-components=1

# 3. 把它的 bin/ 加到 PATH (例如 ~/.zshrc)
export PATH="/opt/llvm-mingw/bin:$PATH"

# 4. 装 Rust target (本仓库 toolchain 已带 aarch64-pc-windows-gnullvm)
rustup target add aarch64-pc-windows-gnullvm
```

确认链接器在 PATH:

```bash
which aarch64-w64-mingw32-clang
# 应输出 /opt/llvm-mingw/bin/aarch64-w64-mingw32-clang
```

### 编译

```bash
cd guest-helper
cargo build --target aarch64-pc-windows-gnullvm --release
# 产物: target/aarch64-pc-windows-gnullvm/release/hvm-guest-helper.exe (~500 KB)
```

### 不要构建只校验代码 (无需 llvm-mingw, 用 host rustc 校语义)

```bash
cargo check --target aarch64-pc-windows-gnullvm
```

---

## 在 HVM 仓库里的位置

- 源码: `guest-helper/`
- 产物 (commit 进仓库, 给没装 llvm-mingw 的用户直接用): `guest-helper/dist/aarch64/hvm-guest-helper.exe`
- HVM `make install` 自动把 dist EXE 拷贝进 `HVM.app/Contents/Resources/GuestHelper/`
- 首次启动 Windows guest 时 HVM 通过 QGA 把 EXE 推到 guest + 注册自启 (详见设计稿 §4.5)

---

## 测试

无 Windows guest 时 (本地开发):

```bash
cargo test           # 单元测试 (协议层 + clipboard 序列化)
cargo check          # 语义检查
```

真机 e2e (Win VM):

```bash
# 通过 hvm-dbg 触发 host 端 NSPasteboard 模拟文件 URL → 验证 guest clipboard 真的被设上
hvm-dbg clipboard-files set --vm 测试 --file /path/to/foo.png
# 然后在 Win 端任意 app Ctrl+V 看 foo.png 出现
```

(`hvm-dbg clipboard-files` 子命令在 PR-5 实现, 此 PR-1 scaffold 仅 helper 自身)

---

## 协议简要

length-prefix framing (4-byte BE u32 length + JSON UTF-8 body), 跟现有 HVMIPC `Frame.swift` 兼容.

**请求** (host → helper):
```json
{"id":"...", "op":"ping"}
{"id":"...", "op":"set-clipboard", "paths":["C:\\ProgramData\\HVM\\clipboard\\foo.png"]}
{"id":"...", "op":"clear-clipboard"}
```

**响应** (helper → host):
```json
{"id":"...", "ok": true, "version": "1.0.0"}
{"id":"...", "ok": false, "code":"clipboard.access_denied", "message":"..."}
```

---

## 日志

`%LOCALAPPDATA%\HVM\helper.log` (滚动 10 MB, 老的 → `.log.old`).
