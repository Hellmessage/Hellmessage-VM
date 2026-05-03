#!/usr/bin/env bash
# M0 smoke test: 验证 build/ 下产物结构正确、签名有效、entitlement 正确
# 不启动 VM, 仅静态检查

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/HVM.app"

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✔ $1"; }

[ -d "$APP" ] || fail "HVM.app 不存在, 请先 make build"
[ -x "$APP/Contents/MacOS/HVM" ] || fail "HVM.app/Contents/MacOS/HVM 不存在或不可执行"
[ -f "$APP/Contents/Info.plist" ] || fail "Info.plist 不存在"
[ -x "$BUILD/hvm-cli" ] || fail "hvm-cli 不存在"
[ -x "$BUILD/hvm-dbg" ] || fail "hvm-dbg 不存在"
pass "产物结构完整"

# bundle ID 正确. plutil 失败 (Info.plist 损坏 / 缺 key) 时 BID 为空, 让上层 fail
# 给清晰错误而不是 "期望 ..., 实际 (空)".
BID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist") \
    || fail "Info.plist 损坏或缺 CFBundleIdentifier (plutil 解析失败)"
[ "$BID" = "com.hellmessage.vm" ] || fail "CFBundleIdentifier 期望 com.hellmessage.vm, 实际 $BID"
pass "Bundle ID 正确"

# 签名有效
codesign --verify --deep --strict "$APP" || fail "HVM.app 签名验证失败"
codesign --verify --strict "$BUILD/hvm-cli" || fail "hvm-cli 签名验证失败"
codesign --verify --strict "$BUILD/hvm-dbg" || fail "hvm-dbg 签名验证失败"
pass "签名验证通过"

# virtualization entitlement 存在
ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)
echo "$ENT" | grep -q "com.apple.security.virtualization" || \
    fail "HVM.app 缺少 com.apple.security.virtualization entitlement"
pass "virtualization entitlement 已注入"

# CLI 能输出版本
"$BUILD/hvm-cli" --version > /dev/null || fail "hvm-cli --version 执行失败"
"$BUILD/hvm-dbg" --version > /dev/null || fail "hvm-dbg --version 执行失败"
pass "CLI / dbg 可启动"

# patches 孤儿检测: 任何 *.patch 必须列入 series. 漏列的 patch 在 qemu-build /
# edk2-build 跑时不会被应用, 是常见误漏. CI 防回归.
check_orphan_patches() {
    local subsystem="$1"
    local dir="$ROOT/patches/$subsystem"
    local series="$dir/series"
    [ -f "$series" ] || return 0  # 没 series 视为该子系统未启用
    for p in "$dir"/*.patch; do
        [ -f "$p" ] || continue  # 无 .patch 文件跳过
        local base
        base=$(basename "$p")
        grep -qF "$base" "$series" || fail "孤儿 patch (未列入 series): patches/$subsystem/$base"
    done
}
check_orphan_patches qemu
check_orphan_patches edk2
pass "patches series 无孤儿 (qemu + edk2)"

echo
echo "M0 smoke test 全部通过 ✔"
