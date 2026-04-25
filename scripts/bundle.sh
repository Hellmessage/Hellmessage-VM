#!/usr/bin/env bash
# 组装 build/HVM.app + 拷 hvm-cli / hvm-dbg 到 build/, 并做 ad-hoc 签名
# 由 make bundle 调用, 依赖 make compile 已完成

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIGURATION:-release}"
BUILD="$ROOT/build"
ENTITLEMENTS="$ROOT/Resources/HVM.entitlements"

# 签名身份选择. 优先级:
#   1. 显式 $SIGN_IDENTITY (非 "auto")
#   2. "Apple Development" (若本地 Keychain 有链完整的该证书)
#   3. "-" (ad-hoc 签名, VZ entitlement 在本地同样生效, 是本项目默认方案)
# 签名相关输出严格不打印证书 SHA / Team ID (CLAUDE.md 安全约束)
if [ -n "${SIGN_IDENTITY:-}" ] && [ "${SIGN_IDENTITY:-}" != "auto" ]; then
    SIGN="$SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development'; then
    SIGN="Apple Development"
else
    SIGN="-"
    echo "ℹ 使用 ad-hoc 签名 (详见 docs/BUILD_SIGN.md)"
fi

# SwiftPM 输出路径 (仅 arm64-apple-macosx, 因为项目硬约束 Apple Silicon)
SWIFT_BIN="$ROOT/.build/arm64-apple-macosx/$CONFIG"
if [ ! -x "$SWIFT_BIN/HVM" ]; then
    echo "✗ 未找到 $SWIFT_BIN/HVM, 请先 swift build" >&2
    exit 1
fi

APP="$BUILD/HVM.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$BUILD"

# 1. 拷二进制
#    HVM 主二进制 + hvm-cli / hvm-dbg 一并塞进 Contents/MacOS/, 让 GUI 可用
#    Bundle.main.url(forAuxiliaryExecutable:) 找到它们, 后续做"一键安装 CLI"
#    (从 .app 里拷到 /usr/local/bin 或 symlink) 不需要用户自己找路径.
#    同时在 build/ 留独立副本, 开发期可以直接 ./build/hvm-cli ... 不必走 .app.
cp "$SWIFT_BIN/HVM"     "$MACOS/HVM"
cp "$SWIFT_BIN/hvm-cli" "$MACOS/hvm-cli"
cp "$SWIFT_BIN/hvm-dbg" "$MACOS/hvm-dbg"
cp "$SWIFT_BIN/hvm-cli" "$BUILD/hvm-cli"
cp "$SWIFT_BIN/hvm-dbg" "$BUILD/hvm-dbg"

# 2. Info.plist (从 template 填版本号)
VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo "0.0.1")
BUILD_NUM=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo "1")
sed \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUM/g" \
    "$ROOT/Resources/Info.plist.template" > "$CONTENTS/Info.plist"
plutil -convert xml1 "$CONTENTS/Info.plist"

# 3. Resources (图标可选)
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# 4. provisioning profile (仅当 bridged entitlement 审批通过并放入时)
if [ -f "$ROOT/Resources/embedded.provisionprofile" ]; then
    cp "$ROOT/Resources/embedded.provisionprofile" "$CONTENTS/embedded.provisionprofile"
fi

# 5. 签名: 先内部 binary, 再外层 .app, 最后 cli / dbg
#    真实证书走 hardened runtime; ad-hoc 签名不叠加 --options runtime (VZ 仍接受 entitlement)
SIGN_ARGS=(--force --sign "$SIGN" --entitlements "$ENTITLEMENTS" --timestamp=none)
if [ "$SIGN" != "-" ]; then
    SIGN_ARGS+=(--options runtime)
fi

codesign "${SIGN_ARGS[@]}" "$MACOS/HVM"
codesign "${SIGN_ARGS[@]}" "$MACOS/hvm-cli"
codesign "${SIGN_ARGS[@]}" "$MACOS/hvm-dbg"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign "${SIGN_ARGS[@]}" "$BUILD/hvm-cli"
codesign "${SIGN_ARGS[@]}" "$BUILD/hvm-dbg"

# 6. 验证签名结构
codesign --verify --deep --strict "$APP" > /dev/null

# 7. 通知 Launch Services 重新注册, 使 .hvmz 立即被识别为 package + 关联到 HVM.app
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREG" ]; then
    "$LSREG" -f "$APP" 2>/dev/null || true
fi

echo "✔ 构建完成: $APP"
echo "  $BUILD/hvm-cli"
echo "  $BUILD/hvm-dbg"
