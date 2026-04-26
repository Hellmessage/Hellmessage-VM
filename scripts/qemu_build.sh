#!/usr/bin/env bash
# scripts/qemu_build.sh
# 一键: 装 Homebrew + 依赖 → 拉 QEMU v10.2.0 源码 → 应用补丁 → 构建 → 落 third_party/qemu/
# 仅打包者跑; 最终用户机器不需要 (HVM.app 包内已带产物)
# 详见 docs/QEMU_INTEGRATION.md 与 CLAUDE.md「QEMU 后端约束」

set -euo pipefail

# ---- 锁定参数 (修改必须同步 docs/QEMU_INTEGRATION.md 与 CLAUDE.md) ----
QEMU_TAG="v10.2.0"
QEMU_REPO="https://gitlab.com/qemu-project/qemu.git"
# Linaro 官方预编译 EDK2 (aarch64 UEFI), Win11/Linux arm64 启动必需
EDK2_FIRMWARE_URL="https://releases.linaro.org/components/kernel/uefi-linaro/latest/release/qemu64/QEMU_EFI.fd"

# brew 包列表 (锁定; swtpm/libtpms 是 Win11 TPM 2.0 必需)
# 注: Homebrew 已把 pkg-config 别名到 pkgconf, 直接用新名避免每次 install no-op
BREW_PACKAGES=(meson ninja pkgconf glib pixman libslirp dtc capstone swtpm libtpms)

# ---- 路径 ----
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/build/qemu-src"
STAGING_DIR="$ROOT/build/qemu-stage"
VENDOR_DIR="$ROOT/third_party/qemu"
PATCHES_DIR="$ROOT/patches/qemu"

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
    step "预检 (macOS arm64 + Xcode CLT + git)"
    [[ "$(uname -s)" == "Darwin" ]] || err "仅支持 macOS, 当前: $(uname -s)"
    [[ "$(uname -m)" == "arm64"  ]] || err "仅支持 Apple Silicon (arm64), 当前: $(uname -m)"
    xcode-select -p >/dev/null 2>&1 || err "未安装 Xcode Command Line Tools, 请运行: xcode-select --install"
    command -v git >/dev/null      || err "git 未找到 (Xcode CLT 应自带)"
    command -v curl >/dev/null     || err "curl 未找到"
    ok "预检通过"
}

# ---- 2. Homebrew (空白 Mac 自动装) ----
ensure_homebrew() {
    step "检查 Homebrew"
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew 已安装: $(brew --version | head -1)"
        return
    fi
    warn "未检测到 Homebrew, 即将运行官方安装脚本:"
    warn "  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
    warn "脚本会向系统安装 /opt/homebrew (Apple Silicon), 需要 sudo 权限"
    read -rp "继续? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || err "用户取消, 请手动装 Homebrew 后再跑本脚本"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # 让当前 shell 立即识别 brew
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    command -v brew >/dev/null || err "Homebrew 安装后仍找不到 brew, 请检查 PATH"
    ok "Homebrew 安装完成"
}

# ---- 3. brew packages (按需补装) ----
ensure_brew_packages() {
    step "确保 brew 依赖: ${BREW_PACKAGES[*]}"
    local installed
    installed=" $(brew list --formula -1 2>/dev/null | tr '\n' ' ') "
    local missing=()
    for pkg in "${BREW_PACKAGES[@]}"; do
        if [[ "$installed" != *" $pkg "* ]]; then
            missing+=("$pkg")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "全部依赖已就绪"
        return
    fi
    warn "缺失: ${missing[*]}"
    brew install "${missing[@]}"
    ok "依赖安装完成"
}

# ---- 4. 拉 QEMU 源码 ----
fetch_qemu_source() {
    step "拉 QEMU 源码 ($QEMU_TAG)"
    if [[ -d "$SRC_DIR/.git" ]]; then
        local cur_tag
        cur_tag="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
        if [[ "$cur_tag" == "$QEMU_TAG" ]]; then
            warn "已存在 $SRC_DIR @ $QEMU_TAG, 重置到干净状态后复用"
            git -C "$SRC_DIR" reset --hard "$QEMU_TAG" >/dev/null
            git -C "$SRC_DIR" clean -fdx >/dev/null
            ok "源码已重置到 $QEMU_TAG 干净状态"
            return
        else
            warn "已存在 $SRC_DIR 但版本是 $cur_tag, 重新克隆"
            rm -rf "$SRC_DIR"
        fi
    fi
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth=1 --branch "$QEMU_TAG" "$QEMU_REPO" "$SRC_DIR"
    ok "源码拉取完成: $SRC_DIR"
}

# ---- 5. 应用补丁 ----
apply_patches() {
    step "应用补丁 (patches/qemu/series)"
    local series="$PATCHES_DIR/series"
    if [[ ! -f "$series" ]]; then
        warn "$series 不存在, 跳过补丁应用"
        return
    fi
    local count=0
    while IFS= read -r line; do
        # 去除首尾空白
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        local patch="$PATCHES_DIR/$line"
        [[ -f "$patch" ]] || err "series 引用的补丁不存在: $patch"
        echo "  → $line"
        ( cd "$SRC_DIR" && git apply --check "$patch" && git apply "$patch" ) \
            || err "补丁失败: $line (禁止用 --reject / --3way 救场, 必须 rebase)"
        count=$((count+1))
    done < "$series"
    if [[ $count -eq 0 ]]; then
        ok "无补丁需要应用 (series 为空)"
    else
        ok "应用了 $count 个补丁"
    fi
}

# ---- 6. configure + build ----
build_qemu() {
    step "configure QEMU"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    local build_dir="$SRC_DIR/build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    # --disable-fuse: macFUSE 头文件 (fuse_darwin_attr) 与 QEMU fuse.c 不兼容, 关掉
    #                 我们不需要把 QEMU 镜像导出成 FUSE 文件系统给 host
    # 其他 disable: 都是 Win/Linux arm64 guest 用不到的远程块/显示后端,
    #               关掉可缩短编译时间 + 缩小产物 + 避免环境探测引入的脆弱性
    ( cd "$build_dir" && \
        ../configure \
            --prefix="$STAGING_DIR" \
            --target-list=aarch64-softmmu \
            --enable-cocoa \
            --enable-hvf \
            --disable-docs \
            --disable-gtk \
            --disable-sdl \
            --disable-vnc \
            --disable-curses \
            --disable-debug-info \
            --disable-werror \
            --disable-fuse \
            --disable-spice \
            --disable-libssh \
            --disable-curl \
            --disable-libnfs \
            --disable-libiscsi \
            --disable-rbd \
            --disable-glusterfs \
            --disable-rdma \
    ) || err "configure 失败"
    step "make -j$NCPU (10-30 分钟, 视 CPU 而定)"
    ( cd "$build_dir" && make -j"$NCPU" ) || err "make 失败"
    step "make install -> $STAGING_DIR"
    ( cd "$build_dir" && make install ) || err "make install 失败"
    ok "QEMU 构建完成"
}

# ---- 7. EDK2 firmware (Win11/Linux arm64 UEFI 引导必需) ----
fetch_edk2_firmware() {
    step "下载 EDK2 aarch64 firmware (QEMU_EFI.fd, Linaro 官方预编译)"
    local fw_dir="$STAGING_DIR/share/qemu"
    local fw_dst="$fw_dir/edk2-aarch64-code.fd"
    mkdir -p "$fw_dir"
    curl -fL --retry 3 -o "$fw_dst.tmp" "$EDK2_FIRMWARE_URL" \
        || err "EDK2 firmware 下载失败: $EDK2_FIRMWARE_URL"
    mv "$fw_dst.tmp" "$fw_dst"
    ok "EDK2 firmware: $fw_dst"
}

# ---- 8. 裁剪 share (删非 aarch64 用不上的固件) ----
# QEMU install 会把所有架构的固件 / ROM / 设备树都装进 share/qemu,
# 即便 configure --target-list 只有 aarch64-softmmu. 主动删非 aarch64 文件,
# 实战可把 share/qemu 从 ~250MB 缩到 ~4MB
prune_share() {
    step "裁剪 share/qemu (仅保留 aarch64 相关固件)"
    local share="$STAGING_DIR/share/qemu"
    [[ -d "$share" ]] || { warn "$share 不存在, 跳过"; return; }

    # 1) 删非 aarch64 的 EDK2 固件 (16-64MB 一个, 大头)
    # 2) 删其他架构 firmware: PowerPC (slof/skiboot/u-boot/vof/pnv/canyonlands/bamboo/pegasos)
    #    SPARC (QEMU,*) MIPS HPPA RISC-V (opensbi) s390 LoongArch Aspeed-BMC NPCM
    # 3) 删 x86 启动相关 (vgabios/pxe/multiboot/linuxboot/kvmvapic/pvh/sgabios/openbios/bios*)
    # 4) 删 Microblaze (petalogix-*) 与 Alpha (palcode-clipper)
    # 5) 删 Windows 安装器素材 (qemu-nsis.bmp)
    # 6) efi-*.rom 是 PCI NIC iPXE boot ROM. 必须保留 efi-virtio.rom (virtio-net-pci 必需);
    #    其他 (e1000 / rtl8139 / ne2k_pci / pcnet / vmxnet3 / eepro100) 是 x86 模拟 NIC 用
    find "$share" -maxdepth 1 -type f \( \
        -name 'edk2-arm-*'         -o \
        -name 'edk2-riscv-*'       -o \
        -name 'edk2-loongarch64-*' -o \
        -name 'edk2-x86_64-*'      -o \
        -name 'edk2-i386-*'        -o \
        -name 'skiboot.lid'        -o \
        -name 'u-boot-*'           -o \
        -name 'u-boot.*'           -o \
        -name 'hppa-*'             -o \
        -name 'slof.bin'           -o \
        -name 'pnv-pnor.bin'       -o \
        -name 'vof*'               -o \
        -name 'npcm*'              -o \
        -name 'opensbi-*'          -o \
        -name 's390-*'             -o \
        -name 'vgabios*.bin'       -o \
        -name 'pxe-*'              -o \
        -name 'efi-e1000*'         -o \
        -name 'efi-eepro100*'      -o \
        -name 'efi-ne2k_pci*'      -o \
        -name 'efi-pcnet*'         -o \
        -name 'efi-rtl8139*'       -o \
        -name 'efi-vmxnet3*'       -o \
        -name 'linuxboot*'         -o \
        -name 'multiboot*'         -o \
        -name 'kvmvapic.bin'       -o \
        -name 'pvh.bin'            -o \
        -name 'palcode-clipper'    -o \
        -name 'openbios-*'         -o \
        -name 'sgabios.bin'        -o \
        -name 'qemu_vga.ndrv'      -o \
        -name 'bamboo.dtb'         -o \
        -name 'canyonlands*'       -o \
        -name 'petalogix-*'        -o \
        -name 'QEMU,*.bin'         -o \
        -name 'ast*_bootrom.bin'   -o \
        -name 'bios*.bin'          -o \
        -name 'qboot.rom'          -o \
        -name 'qemu-nsis.bmp'      \
    \) -delete 2>/dev/null || true

    # 删非 aarch64 的设备树二进制目录 (PowerPC/Microblaze 的 .dtb 全在里面)
    rm -rf "$share/dtb" 2>/dev/null || true

    # firmware/ 描述符 JSON 只保留 aarch64
    if [[ -d "$share/firmware" ]]; then
        find "$share/firmware" -type f -name '*.json' ! -name '*aarch64*' -delete 2>/dev/null || true
    fi

    ok "裁剪完成 ($(du -sh "$share" 2>/dev/null | cut -f1))"
}

# ---- 9. 落入 third_party/qemu ----
install_to_vendor() {
    step "拷贝产物 → $VENDOR_DIR"
    rm -rf "$VENDOR_DIR"
    mkdir -p "$VENDOR_DIR"
    for sub in bin share libexec lib; do
        if [[ -d "$STAGING_DIR/$sub" ]]; then
            cp -R "$STAGING_DIR/$sub" "$VENDOR_DIR/"
        fi
    done
    # 清扩展属性: QEMU 上游 entitlement.sh 会给 qemu-system-aarch64 附
    # com.apple.FinderInfo + com.apple.ResourceFork (来自 pc-bios/qemu.rsrc),
    # 这些 xattr 会让后续 codesign 报 "resource fork ... not allowed".
    # bundle.sh 也会再清一次防御; 此处先清掉避免污染 third_party/
    find "$VENDOR_DIR" -type f -exec xattr -c {} + 2>/dev/null || true
    ok "拷贝完成 + xattr 清理"
}

# ---- 10. 写 LICENSE + MANIFEST (GPL 合规) ----
write_manifest() {
    step "写 MANIFEST.json + LICENSE (GPL 合规闭环)"
    local commit
    commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
    local build_time
    build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # 收集 series 中实际生效的 patch 列表 (注释 + 空行不算)
    # 用 awk 一次过滤; 空结果时 awk 返回 0, 不会触发 set -o pipefail
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

    cat > "$VENDOR_DIR/MANIFEST.json" <<EOF
{
  "qemu_tag": "$QEMU_TAG",
  "qemu_commit": "$commit",
  "qemu_repo": "$QEMU_REPO",
  "build_time_utc": "$build_time",
  "host_arch": "$(uname -m)",
  "build_options": [
    "--target-list=aarch64-softmmu",
    "--enable-cocoa",
    "--enable-hvf"
  ],
  "patches": $patches_json,
  "edk2_firmware_url": "$EDK2_FIRMWARE_URL",
  "source_note": "QEMU 上游可由 qemu_tag + qemu_commit 在 qemu_repo 复现; HVM 自身源码见本仓库 GitHub 公开页"
}
EOF
    # QEMU 上游 license 文本 (GPLv2 + LGPL 部分模块)
    [[ -f "$SRC_DIR/COPYING"     ]] && cp "$SRC_DIR/COPYING"     "$VENDOR_DIR/LICENSE"
    [[ -f "$SRC_DIR/COPYING.LIB" ]] && cp "$SRC_DIR/COPYING.LIB" "$VENDOR_DIR/LICENSE.LGPL"
    ok "MANIFEST + LICENSE 写入"
}

# ---- main ----
main() {
    preflight
    ensure_homebrew
    ensure_brew_packages
    fetch_qemu_source
    apply_patches
    build_qemu
    fetch_edk2_firmware
    prune_share
    install_to_vendor
    write_manifest
    echo
    c_green "════════════════════════════════════════"
    c_green "  QEMU 构建完成"
    c_green "════════════════════════════════════════"
    echo "  产物:    $VENDOR_DIR/bin/qemu-system-aarch64"
    echo "  manifest: $VENDOR_DIR/MANIFEST.json"
    echo "  下一步:  make build-all   (组装 .app 并嵌入 QEMU)"
}

main "$@"
