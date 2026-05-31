#!/usr/bin/env bash
# build.sh — 编 hvm-guest-helper 成【无 DLL 单 exe】(Windows ARM64). 由 `make guest-helper` 调.
#
# gnullvm 目标链接需 llvm-mingw 的 aarch64-w64-mingw32-clang 驱动 (rust 自带 rust-lld 不够, 要
# clang 拉 CRT/静态库). +crt-static 静态链 libunwind.a / libc++.a / ucrt → 产物只依赖 Windows
# 系统 DLL (kernel32/ntdll/user32/oleaut32/api-ms-win-*), 无 libunwind.dll / libc++.dll.
#
# llvm-mingw (打包者机器, 跟 qemu/edk2 同性质的源→包工具, 不入最终 .app): 缺则自动下载锁定版本到
# third_party/llvm-mingw/ (github.com/mstorsjo/llvm-mingw, ucrt-macos-universal). 或设 HVM_LLVM_MINGW.
set -euo pipefail

# 版本锁定 (升级须同步改 + 重编 + 重 commit dist exe)
LLVM_MINGW_TAG="20260519"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
MINGW="${HVM_LLVM_MINGW:-$ROOT/third_party/llvm-mingw}"
TARGET="aarch64-pc-windows-gnullvm"
SYS_DLL_RE="kernel32|api-ms-win|ntdll|advapi32|user32|ole32|oleaut32|bcrypt|secur32|ws2_32|crypt32|userenv|shell32|dbghelp"

# ---- 1. 确保 llvm-mingw 就位 (缺则下载锁定版本) ----
if [ ! -x "$MINGW/bin/aarch64-w64-mingw32-clang" ]; then
    if [ -n "${HVM_LLVM_MINGW:-}" ]; then
        echo "✗ HVM_LLVM_MINGW=$HVM_LLVM_MINGW 下无 aarch64-w64-mingw32-clang"; exit 1
    fi
    TB="llvm-mingw-${LLVM_MINGW_TAG}-ucrt-macos-universal"
    echo "→ 未找到 llvm-mingw, 下载 ${LLVM_MINGW_TAG} (ucrt-macos-universal, ~数百 MB) 到 third_party/ ..."
    mkdir -p "$ROOT/third_party"
    curl -fL "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_TAG}/${TB}.tar.xz" \
        -o "$ROOT/third_party/llvm-mingw.tar.xz"
    ( cd "$ROOT/third_party" && tar xf llvm-mingw.tar.xz && rm -f llvm-mingw.tar.xz \
        && rm -rf llvm-mingw && mv "$TB" llvm-mingw )
    [ -x "$MINGW/bin/aarch64-w64-mingw32-clang" ] || { echo "✗ llvm-mingw 解压后仍无 clang"; exit 1; }
fi
export PATH="$MINGW/bin:$PATH"

rustup target add "$TARGET" >/dev/null 2>&1 || true

# ---- 2. crt-static 全静态编 ----
echo "→ crt-static 全静态编 ($TARGET) ..."
cd "$HERE"
RUSTFLAGS="-C target-feature=+crt-static" cargo build --target "$TARGET" --release

EXE="target/$TARGET/release/hvm-guest-helper.exe"
[ -f "$EXE" ] || { echo "✗ 构建失败: $EXE 不存在"; exit 1; }

# ---- 3. 硬校验: 无非系统 DLL 依赖 (单 exe 约束) ----
BAD="$(strings -a "$EXE" | grep -iE "\.dll$" | grep -ivE "$SYS_DLL_RE" | grep -ivE "^~" | sort -u || true)"
if [ -n "$BAD" ]; then
    echo "✗ 产物仍依赖非系统 DLL (不是单 exe):"; echo "$BAD"; exit 1
fi

# ---- 4. 拷到 dist (bundle.sh 从这里取入 .app) ----
mkdir -p dist/aarch64
cp "$EXE" dist/aarch64/hvm-guest-helper.exe
rm -f dist/aarch64/libunwind.dll   # 单 exe 不再随附 DLL

echo "✔ 无 DLL 单 exe: patches/guest/helper-win/dist/aarch64/hvm-guest-helper.exe ($(ls -lh "$EXE" | awk '{print $5}'))"
