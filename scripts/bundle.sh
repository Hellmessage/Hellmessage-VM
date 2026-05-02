#!/usr/bin/env bash
# 组装 build/HVM.app + 拷 hvm-cli / hvm-dbg 到 build/, 并做 ad-hoc 签名
# 由 make bundle 调用, 依赖 make compile 已完成

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIGURATION:-release}"
BUILD="$ROOT/build"
ENTITLEMENTS="$ROOT/app/Resources/HVM.entitlements"

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
    cat <<'EOF'
⚠ ad-hoc 签名 (本机 Keychain 没有 Apple Development 证书)
  - 本机开发期可用: AMFI 接受 com.apple.security.virtualization, VZ guest 能正常起
  - 不能拷给其他人用: 其他 Mac 上 AMFI 会拒绝 entitlement, .app 启动即崩
  - 想出可分发版本: 在 Apple Developer 注册个人证书后 make build 会自动用真实身份
  - 详见 docs/BUILD_SIGN.md
EOF
fi

# SwiftPM 输出路径 (仅 arm64-apple-macosx, 因为项目硬约束 Apple Silicon)
SWIFT_BIN="$ROOT/app/.build/arm64-apple-macosx/$CONFIG"
if [ ! -x "$SWIFT_BIN/HVM" ]; then
    echo "✗ 未找到 $SWIFT_BIN/HVM, 请先 swift build --package-path app" >&2
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
    "$ROOT/app/Resources/Info.plist.template" > "$CONTENTS/Info.plist"
plutil -convert xml1 "$CONTENTS/Info.plist"

# 3. Resources (图标可选)
if [ -f "$ROOT/app/Resources/AppIcon.icns" ]; then
    cp "$ROOT/app/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# 4. provisioning profile (仅当 bridged entitlement 审批通过并放入时)
if [ -f "$ROOT/app/Resources/embedded.provisionprofile" ]; then
    cp "$ROOT/app/Resources/embedded.provisionprofile" "$CONTENTS/embedded.provisionprofile"
fi

# 4.4 拷贝 install-vmnet-daemons.sh 入 Resources/scripts/, 让 GUI VMnetSupervisor 可定位.
#     按 CLAUDE.md 第三方二进制约束, GUI 严格只走 Bundle.main/Resources/scripts/, 不再
#     fallback 到仓库 scripts/; 改完此脚本必须 make install 才能让 /Applications/HVM.app 同步.
mkdir -p "$RESOURCES/scripts"
if [ -f "$ROOT/scripts/install-vmnet-daemons.sh" ]; then
    cp "$ROOT/scripts/install-vmnet-daemons.sh" "$RESOURCES/scripts/install-vmnet-daemons.sh"
    chmod +x "$RESOURCES/scripts/install-vmnet-daemons.sh"
fi

# 4.5 嵌入 QEMU 后端 (软模式: third_party/qemu-stage/ 不存在则跳过, 仍出 .app)
#     完整发布走 make build-all (会先 make qemu); 此处 make build 不强制要求 QEMU 就绪
#     stage 即 qemu-build.sh 的最终成品 (已裁剪 / 嵌 swtpm / 清 xattr / 写 LICENSE+MANIFEST)
#     socket_vmnet 不再入包 — 用户机器自行 brew install, install-vmnet-helper.sh 从 brew 路径起 daemon
QEMU_STAGE_DIR="$ROOT/third_party/qemu-stage"
QEMU_BIN_SRC="$QEMU_STAGE_DIR/bin/qemu-system-aarch64"
EMBED_QEMU=0
if [ -x "$QEMU_BIN_SRC" ]; then
    QEMU_DST="$RESOURCES/QEMU"
    rm -rf "$QEMU_DST"
    mkdir -p "$QEMU_DST"
    for sub in bin share libexec lib; do
        if [ -d "$QEMU_STAGE_DIR/$sub" ]; then
            cp -R "$QEMU_STAGE_DIR/$sub" "$QEMU_DST/"
        fi
    done
    [ -f "$QEMU_STAGE_DIR/LICENSE"       ] && cp "$QEMU_STAGE_DIR/LICENSE"       "$QEMU_DST/LICENSE"
    [ -f "$QEMU_STAGE_DIR/LICENSE.LGPL"  ] && cp "$QEMU_STAGE_DIR/LICENSE.LGPL"  "$QEMU_DST/LICENSE.LGPL"
    [ -f "$QEMU_STAGE_DIR/MANIFEST.json" ] && cp "$QEMU_STAGE_DIR/MANIFEST.json" "$QEMU_DST/MANIFEST.json"
    # 防御: 清扩展属性, 避免 codesign 报 "resource fork ... not allowed"
    # (qemu-build.sh strip_xattrs 已清过, 这里再清一次保 cp 期间不被打回)
    find "$QEMU_DST" -type f -exec xattr -c {} + 2>/dev/null || true
    EMBED_QEMU=1
    echo "✔ 已嵌入 QEMU 后端: $QEMU_DST"
else
    cat <<'EOF'
ℹ 跳过 QEMU 嵌入 (third_party/qemu-stage/ 不存在)
  - 此构建只含 VZ 后端, 不支持 Windows arm64
  - 需要 QEMU 后端: 跑 make build-all (首次会自动 make qemu, 耗时 10-30 分钟)
EOF
fi

# 5. 签名
#    QEMU 子进程使用独立 entitlement (com.apple.security.hypervisor, HVF 必需);
#    HVM 主进程 entitlement 含 com.apple.security.virtualization, 二者不能混用
#    真实证书走 hardened runtime; ad-hoc 签名不叠加 --options runtime
SIGN_ARGS=(--force --sign "$SIGN" --entitlements "$ENTITLEMENTS" --timestamp=none)
if [ "$SIGN" != "-" ]; then
    SIGN_ARGS+=(--options runtime)
fi

# 5.0 先签 QEMU (若已嵌入), 由内向外: dylib → libexec → bin
if [ "$EMBED_QEMU" = "1" ]; then
    QEMU_ENT="$ROOT/app/Resources/QEMU.entitlements"
    QEMU_SIGN_ARGS=(--force --sign "$SIGN" --entitlements "$QEMU_ENT" --timestamp=none)
    if [ "$SIGN" != "-" ]; then
        QEMU_SIGN_ARGS+=(--options runtime)
    fi
    # dylib (lib/ 可能不存在, 取决于 configure 是否启用动态依赖)
    if [ -d "$RESOURCES/QEMU/lib" ]; then
        find "$RESOURCES/QEMU/lib" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 \
            | while IFS= read -r -d '' f; do
                codesign "${QEMU_SIGN_ARGS[@]}" "$f" || true
            done
    fi
    # libexec helper (qemu-bridge-helper 等)
    if [ -d "$RESOURCES/QEMU/libexec" ]; then
        find "$RESOURCES/QEMU/libexec" -type f -perm -u+x -print0 \
            | while IFS= read -r -d '' f; do
                codesign "${QEMU_SIGN_ARGS[@]}" "$f" || true
            done
    fi
    # bin (qemu-system-aarch64 + 其他可执行) — 必须签成功
    find "$RESOURCES/QEMU/bin" -type f -perm -u+x -print0 \
        | while IFS= read -r -d '' f; do
            codesign "${QEMU_SIGN_ARGS[@]}" "$f"
        done
fi

# 5.1 签 HVM 自家 binary
codesign "${SIGN_ARGS[@]}" "$MACOS/HVM"
codesign "${SIGN_ARGS[@]}" "$MACOS/hvm-cli"
codesign "${SIGN_ARGS[@]}" "$MACOS/hvm-dbg"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign "${SIGN_ARGS[@]}" "$BUILD/hvm-cli"
codesign "${SIGN_ARGS[@]}" "$BUILD/hvm-dbg"

# 6. 验证签名结构 (--deep 会顺带验 Resources/QEMU/ 内 mach-o)
codesign --verify --deep --strict "$APP" > /dev/null

# 7. 通知 Launch Services 重新注册, 使 .hvmz 立即被识别为 package + 关联到 HVM.app
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREG" ]; then
    "$LSREG" -f "$APP" 2>/dev/null || true
fi

echo "✔ 构建完成: $APP"
echo "  $BUILD/hvm-cli"
echo "  $BUILD/hvm-dbg"
