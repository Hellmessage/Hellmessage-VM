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

# bundle ID 正确
BID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
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

echo
echo "M0 smoke test 全部通过 ✔"
