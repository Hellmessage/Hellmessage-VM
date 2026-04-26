#!/usr/bin/env bash
# scripts/edk2-build.sh
# 一键: clone EDK2 上游 (锁定 tag) → apply patches/edk2/* → 用 brew aarch64-elf-gcc
#       cross compile ArmVirtQemu AARCH64 RELEASE → 写 third_party/edk2-stage/code.fd
# 跑完后 qemu-build.sh 会把 stage 里的 code.fd 拷进 third_party/qemu-stage/share/qemu/.
#
# 仅打包者跑; 最终用户机器不需要 (HVM.app 包内已带 firmware).
# 详见 docs/QEMU_INTEGRATION.md + CLAUDE.md "QEMU 后端约束"

set -euo pipefail

# ---- 锁定参数 (修改必须同步 docs/QEMU_INTEGRATION.md 与 CLAUDE.md) ----
EDK2_TAG="edk2-stable202508"
EDK2_REPO="https://github.com/tianocore/edk2.git"

# brew 包列表 (锁定):
#   - acpica   — iasl (ACPI 编译器, EDK2 build 时编 ACPI 表用)
#   - nasm     — x86 汇编器 (ArmVirt 不直接需要, 但 BaseTools 编译会摸到)
#   - dtc      — device tree compiler
#   - aarch64-elf-gcc — bare-metal aarch64 cross compiler (EDK2 用 GCC5 toolchain spec)
BREW_PACKAGES=(acpica nasm dtc aarch64-elf-gcc)

# ---- 路径 ----
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/third_party/edk2-src"
STAGE_DIR="$ROOT/third_party/edk2-stage"
PATCHES_DIR="$ROOT/patches/edk2"

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

# ---- 3. 拉 EDK2 源码 (含 submodules) ----
fetch_edk2_source() {
    step "拉 EDK2 源码 ($EDK2_TAG, 含 submodules)"
    if [[ -d "$SRC_DIR/.git" ]]; then
        local cur_tag
        cur_tag="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
        if [[ "$cur_tag" == "$EDK2_TAG" ]]; then
            warn "已存在 $SRC_DIR @ $EDK2_TAG, 重置到干净状态后复用"
            git -C "$SRC_DIR" reset --hard "$EDK2_TAG" >/dev/null
            git -C "$SRC_DIR" submodule update --init --recursive --depth=1 >/dev/null 2>&1 || true
            ok "源码已重置到 $EDK2_TAG 干净状态"
            return
        fi
        warn "$SRC_DIR tag 不匹配 ($cur_tag != $EDK2_TAG), 删除重拉"
        rm -rf "$SRC_DIR"
    fi
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth=1 --branch "$EDK2_TAG" --recurse-submodules --shallow-submodules \
        "$EDK2_REPO" "$SRC_DIR" || err "git clone 失败"
    ok "EDK2 源码就绪: $SRC_DIR"
}

# ---- 4. 应用 patch (patches/edk2/series 决定顺序) ----
apply_patches() {
    step "应用补丁 (patches/edk2/series)"
    local series="$PATCHES_DIR/series"
    if [[ ! -f "$series" ]]; then
        warn "$series 不存在, 跳过补丁应用"
        return
    fi
    local applied=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行 / # 开头注释
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

# ---- 5. 编译 BaseTools ----
build_basetools() {
    step "编译 EDK2 BaseTools (GenFv / GenFds / 等)"
    ( cd "$SRC_DIR" && make -C BaseTools -j"$NCPU" ) || err "BaseTools 编译失败"
    ok "BaseTools 就绪"
}

# ---- 6. 编译 ArmVirtQemu AARCH64 RELEASE ----
build_armvirt_qemu() {
    step "编译 ArmVirtQemu AARCH64 RELEASE (用 brew aarch64-elf-gcc)"
    local build_dir_rel="Build/ArmVirtQemu-AARCH64/RELEASE_GCC5"
    local build_dir="$SRC_DIR/$build_dir_rel"
    rm -rf "$build_dir"

    # EDK2 build 必须先 source edksetup.sh; bash subshell 隔离环境
    (
        cd "$SRC_DIR"
        export WORKSPACE="$SRC_DIR"
        export PACKAGES_PATH="$SRC_DIR"
        export GCC5_AARCH64_PREFIX="aarch64-elf-"
        # source edksetup.sh BaseTools (要求 BaseTools 已 make)
        # shellcheck disable=SC1091
        source ./edksetup.sh BaseTools >/dev/null
        # build 主体
        build -p ArmVirtPkg/ArmVirtQemu.dsc \
              -a AARCH64 \
              -t GCC5 \
              -b RELEASE \
              -n "$NCPU" \
              || exit 1
    ) || err "EDK2 ArmVirtQemu 编译失败"

    local fv_dir="$build_dir/FV"
    [[ -f "$fv_dir/QEMU_EFI.fd" ]] || err "QEMU_EFI.fd 未生成 (期望 $fv_dir/QEMU_EFI.fd)"

    ok "EDK2 编译完成 -> $fv_dir/"
}

# ---- 7. stage 输出 ----
# QEMU virt machine 的 pflash device 固定 64MB; padding 必须做.
# stage 同时写 MANIFEST 记录 commit + tag, GPL 合规.
stage_firmware() {
    step "stage firmware -> $STAGE_DIR"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"

    local fv_dir="$SRC_DIR/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV"
    cp "$fv_dir/QEMU_EFI.fd" "$STAGE_DIR/edk2-aarch64-code.fd"

    # padding 到 64MB (QEMU virt pflash 必需; 否则启动报 "device requires 67108864 bytes")
    python3 - <<EOF
import os
p = "$STAGE_DIR/edk2-aarch64-code.fd"
sz = os.path.getsize(p)
target = 64 * 1024 * 1024
if sz > target:
    raise SystemExit(f"firmware {p} 大小 {sz} > 64MB, 异常")
if sz < target:
    with open(p, "r+b") as f:
        f.seek(target - 1)
        f.write(b"\\0")
EOF

    # commit + tag 写 MANIFEST (GPL 合规, 用户能溯源)
    local commit
    commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
    local build_time
    build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # 收集 series 中实际生效的 patch
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

    # license 文本 (BSD-2-Clause-Patent)
    [[ -f "$SRC_DIR/License.txt" ]] && cp "$SRC_DIR/License.txt" "$STAGE_DIR/LICENSE"

    ok "EDK2 firmware: $STAGE_DIR/edk2-aarch64-code.fd (64MB)"
}

# ---- main ----
main() {
    preflight
    ensure_homebrew
    ensure_brew_packages
    fetch_edk2_source
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
    c_blue "下一步: scripts/qemu-build.sh 会自动用 stage 里的 firmware 替换 QEMU 自带版本."
    c_blue "  或者手动: cp $STAGE_DIR/edk2-aarch64-code.fd third_party/qemu-stage/share/qemu/"
}

main "$@"
