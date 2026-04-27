#!/usr/bin/env bash
# scripts/edk2-build.sh
# 一键: clone EDK2 上游 (锁定 tag) → 修 macOS BaseTools 兼容 → apply patches/edk2/* →
#       cross compile ArmVirtQemu AARCH64 RELEASE (用 brew aarch64-elf-gcc) →
#       pad 到 64MB → 写 third_party/edk2-stage/edk2-aarch64-code.fd
# 跑完后 qemu-build.sh 会把 stage firmware 拷进 third_party/qemu-stage/share/qemu/.
#
# 仅打包者跑; 最终用户机器不需要 (HVM.app 包内已带 firmware).
# 详见 docs/QEMU_INTEGRATION.md + CLAUDE.md "QEMU 后端约束"

set -euo pipefail

# ---- 锁定参数 (修改必须同步 docs/QEMU_INTEGRATION.md 与 CLAUDE.md) ----
# stable202408: PlatformBootManagerLibLight 仍有 "无 NV BootOrder 时自动 boot first device"
#               行为 (跟 kraxel firmware 一致, 也跟 hell-vm 同源参考项目对齐).
#               stable202508 上游改了 Light 行为, 无 BootOrder 落 EFI Shell, 不能直接
#               boot ISO; 切到 202508 必须额外打 PlatformBootManagerLib full 替换 patch.
EDK2_TAG="edk2-stable202408"
EDK2_REPO="https://github.com/tianocore/edk2.git"

# brew 包列表 (锁定):
#   - acpica   — iasl (ACPI 编译器, EDK2 build 时编 ACPI 表用)
#   - nasm     — x86 汇编器 (ArmVirt 不直接需要, 但 BaseTools 编译会摸到)
#   - dtc      — device tree compiler
#   - aarch64-elf-gcc — bare-metal aarch64 cross compiler (EDK2 用 GCC5 toolchain spec)
#   - aarch64-elf-binutils — 链接器 (随 aarch64-elf-gcc 自带)
BREW_PACKAGES=(acpica nasm dtc aarch64-elf-gcc aarch64-elf-binutils)

# ---- 路径 ----
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/third_party/edk2-src"
STAGE_DIR="$ROOT/third_party/edk2-stage"
PATCHES_DIR="$ROOT/patches/edk2"
BUILT_FD="$SRC_DIR/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV/QEMU_EFI.fd"
BUILT_VARS="$SRC_DIR/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV/QEMU_VARS.fd"

NCPU="$(sysctl -n hw.ncpu)"

# ---- 输出工具 ----
c_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
step() { c_blue "==> $*"; }
ok()   { c_green "✔ $*"; }
warn() { c_yellow "⚠ $*"; }
err()  { c_red   "✗ $*" >&2; exit 1; }

# ---- 1. 预检 ----
preflight() {
    step "预检 (macOS arm64 + git + python3)"
    [[ "$(uname -s)" == "Darwin" ]] || err "仅支持 macOS, 当前: $(uname -s)"
    [[ "$(uname -m)" == "arm64"  ]] || err "仅支持 Apple Silicon, 当前: $(uname -m)"
    command -v git >/dev/null     || err "git 未找到"
    command -v python3 >/dev/null || err "python3 未找到 (EDK2 BaseTools 需要)"
    ok "预检通过"
}

# ---- 2. Homebrew + 依赖 ----
ensure_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        step "安装 Homebrew (Apple Silicon /opt/homebrew)"
        NONINTERACTIVE=1 /bin/bash -c \
            "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
            || err "Homebrew 安装失败"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "Homebrew 就位"
}

ensure_brew_packages() {
    step "确保 brew 依赖: ${BREW_PACKAGES[*]}"
    local missing=()
    for pkg in "${BREW_PACKAGES[@]}"; do
        brew list --formula "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if (( ${#missing[@]} > 0 )); then
        step "安装缺失依赖: ${missing[*]}"
        brew install "${missing[@]}" || err "brew install 失败"
    fi
    ok "brew 依赖就位"
}

# ---- 3. 拉 EDK2 源码 (含必要 submodules; 跳过 SubhookLib 上游仓库已删) ----
fetch_edk2_source() {
    step "拉 EDK2 源码 ($EDK2_TAG)"
    if [[ -d "$SRC_DIR/.git" ]]; then
        local cur_tag
        cur_tag="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
        if [[ "$cur_tag" == "$EDK2_TAG" ]]; then
            warn "已存在 $SRC_DIR @ $EDK2_TAG, 重置到干净状态"
            git -C "$SRC_DIR" checkout -- . 2>/dev/null || true
            ok "源码已重置"
            return
        fi
        warn "$SRC_DIR tag 不匹配 ($cur_tag != $EDK2_TAG), 删除重拉"
        rm -rf "$SRC_DIR"
    fi
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth=1 --branch "$EDK2_TAG" "$EDK2_REPO" "$SRC_DIR" \
        || err "git clone 失败"

    # 显式 init 必要的 submodules. 跳过 SubhookLib (上游 https://github.com/Zeex/subhook
    # 已 404); ArmVirtQemu build 不需要 UnitTestFrameworkPkg.
    step "init 必要 submodules"
    git -C "$SRC_DIR" submodule update --init --depth 1 \
        ArmPkg/Library/ArmSoftFloatLib/berkeley-softfloat-3 \
        BaseTools/Source/C/BrotliCompress/brotli \
        CryptoPkg/Library/MbedTlsLib/mbedtls \
        CryptoPkg/Library/OpensslLib/openssl \
        MdeModulePkg/Library/BrotliCustomDecompressLib/brotli \
        MdeModulePkg/Universal/RegularExpressionDxe/oniguruma \
        MdePkg/Library/BaseFdtLib/libfdt \
        MdePkg/Library/MipiSysTLib/mipisyst \
        RedfishPkg/Library/JsonLib/jansson \
        SecurityPkg/DeviceSecurity/SpdmLib/libspdm \
        || err "submodule init 失败"
    ok "EDK2 源码就绪"
}

# ---- 4. macOS BaseTools 兼容修补 ----
# stable202408 的 BaseTools 在新版 Xcode SDK + 新版 brew 工具链下编译会失败:
#   1. Decompress.c 重定义 UINT8_MAX, 跟 macOS stdint.h 冲突 → 加 -Wno-macro-redefined
# 不做 git apply 形式 (非可移植 patch), 直接 idempotent sed.
fix_basetools_for_macos() {
    step "修 BaseTools macOS 兼容 (-Wno-macro-redefined)"
    local mk="$SRC_DIR/BaseTools/Source/C/Makefiles/header.makefile"
    if grep -q 'Wno-macro-redefined' "$mk"; then
        ok "BaseTools 已修过"
    else
        # macOS clang darwin block 加 flag
        sed -i.bak 's|-Wno-unused-result -nostdlib|-Wno-unused-result -Wno-macro-redefined -nostdlib|g' "$mk"
        rm -f "$mk.bak"
        ok "BaseTools header.makefile patched"
    fi
}

# ---- 5. 应用 patch (patches/edk2/series 决定顺序) ----
apply_patches() {
    step "应用补丁 (patches/edk2/series)"
    local series="$PATCHES_DIR/series"
    if [[ ! -f "$series" ]]; then
        warn "$series 不存在, 跳过补丁应用"
        return
    fi
    local applied=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local patch="$PATCHES_DIR/$line"
        [[ -f "$patch" ]] || err "series 引用的补丁不存在: $patch"
        ( cd "$SRC_DIR" && git apply --check "$patch" && git apply "$patch" ) \
            || err "patch 应用失败: $patch"
        ok "applied: $line"
        applied=$((applied + 1))
    done < "$series"
    if (( applied == 0 )); then
        warn "无补丁需要应用 (series 为空)"
    fi
}

# ---- 6. 编译 BaseTools ----
build_basetools() {
    step "编译 EDK2 BaseTools"
    # 只 build Source/C (Tests 子目录 dlg/Pccts 在新 macOS 上 link 失败, 但不影响
    # ArmVirtQemu build 需要的 GenFv/VfrCompile/etc).
    ( cd "$SRC_DIR" && make -C BaseTools/Source/C -j"$NCPU" ) || err "BaseTools 编译失败"
    [[ -x "$SRC_DIR/BaseTools/Source/C/bin/GenFv" ]] || err "GenFv 未生成"
    [[ -x "$SRC_DIR/BaseTools/Source/C/bin/VfrCompile" ]] || err "VfrCompile 未生成"
    ok "BaseTools 就绪"
}

# ---- 7. 编译 ArmVirtQemu AARCH64 RELEASE ----
build_armvirt_qemu() {
    step "编译 ArmVirtQemu AARCH64 RELEASE (用 brew aarch64-elf-gcc)"
    local build_dir="$SRC_DIR/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5"
    rm -rf "$build_dir"

    (
        cd "$SRC_DIR"
        export WORKSPACE="$SRC_DIR"
        export PACKAGES_PATH="$SRC_DIR"
        export EDK_TOOLS_PATH="$SRC_DIR/BaseTools"
        export CONF_PATH="$SRC_DIR/Conf"
        export GCC5_AARCH64_PREFIX="aarch64-elf-"
        # edksetup.sh 内部裸 dereference $EDK_TOOLS_PATH (line 80) + $PACKAGES_PATH 等,
        # 在 set -u 下未 export 时崩. 上面已显式 export 全部依赖, 仍 set +u source 防御.
        set +u
        # shellcheck disable=SC1091
        source ./edksetup.sh BaseTools >/dev/null
        set -u
        build -p ArmVirtPkg/ArmVirtQemu.dsc \
              -a AARCH64 \
              -t GCC5 \
              -b RELEASE \
              -n "$NCPU" \
              || exit 1
    ) || err "EDK2 ArmVirtQemu 编译失败"

    [[ -f "$BUILT_FD"   ]] || err "QEMU_EFI.fd 未生成 ($BUILT_FD)"
    [[ -f "$BUILT_VARS" ]] || err "QEMU_VARS.fd 未生成 ($BUILT_VARS)"
    ok "EDK2 编译完成"
}

# ---- 8. stage 输出 ----
# QEMU virt machine 的 pflash device 固定 64MB; 必须 padding.
# stage 同时写 MANIFEST 记录 commit + tag, GPL 合规.
stage_firmware() {
    step "stage firmware → $STAGE_DIR"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"

    cp "$BUILT_FD"   "$STAGE_DIR/edk2-aarch64-code.fd"
    cp "$BUILT_VARS" "$STAGE_DIR/edk2-aarch64-vars.fd"

    # padding 到 64MB
    python3 - <<EOF
import os, sys
target = 64 * 1024 * 1024
for p in [
    "$STAGE_DIR/edk2-aarch64-code.fd",
    "$STAGE_DIR/edk2-aarch64-vars.fd",
]:
    sz = os.path.getsize(p)
    if sz > target:
        raise SystemExit(f"firmware {p} 大小 {sz} > 64MB, 异常")
    if sz < target:
        with open(p, "r+b") as f:
            f.seek(target - 1)
            f.write(b"\\0")
EOF

    local commit
    commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
    local build_time
    build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local patches_json="[]"
    if [[ -f "$PATCHES_DIR/series" ]]; then
        local items
        items="$(awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { next }
            { printf "    \"%s\",\n", $1 }
        ' "$PATCHES_DIR/series" | sed '$ s/,$//')"
        if [[ -n "$items" ]]; then
            patches_json=$'[\n'"$items"$'\n  ]'
        fi
    fi

    cat > "$STAGE_DIR/MANIFEST.json" <<EOF
{
  "edk2_tag": "$EDK2_TAG",
  "edk2_commit": "$commit",
  "edk2_repo": "$EDK2_REPO",
  "build_time_utc": "$build_time",
  "host_arch": "$(uname -m)",
  "build_options": [
    "-p ArmVirtPkg/ArmVirtQemu.dsc",
    "-a AARCH64",
    "-t GCC5",
    "-b RELEASE"
  ],
  "patches": $patches_json,
  "source_note": "EDK2 上游可由 edk2_tag + edk2_commit 在 edk2_repo 复现; HVM 自身 patch 在 patches/edk2/"
}
EOF

    [[ -f "$SRC_DIR/License.txt" ]] && cp "$SRC_DIR/License.txt" "$STAGE_DIR/LICENSE"

    ok "EDK2 firmware: $STAGE_DIR/edk2-aarch64-code.fd (64MB)"
    ok "EDK2 vars 模板: $STAGE_DIR/edk2-aarch64-vars.fd (64MB)"
}

# ---- main ----
main() {
    preflight
    ensure_homebrew
    ensure_brew_packages
    fetch_edk2_source
    fix_basetools_for_macos
    apply_patches
    build_basetools
    build_armvirt_qemu
    stage_firmware
    echo
    c_green "════════════════════════════════════════"
    c_green "  EDK2 build 完成"
    c_green "  产物: $STAGE_DIR/edk2-aarch64-code.fd"
    c_green "════════════════════════════════════════"
    echo
    c_blue "下一步: scripts/qemu-build.sh 会自动用 stage 里的 firmware 替换 QEMU 自带 stock,"
    c_blue "        给 Win11 ARM64 装机用. 也可手动:"
    c_blue "          cp $STAGE_DIR/edk2-aarch64-code.fd \\"
    c_blue "             third_party/qemu-stage/share/qemu/edk2-aarch64-code-win11.fd"
}

main "$@"
