#!/usr/bin/env bash
# scripts/install-win11-firmware.sh
# 把 Win11 ARM64 装机用的 patched EDK2 firmware 放进 third_party/qemu-stage/share/qemu/
# 文件名: edk2-aarch64-code-win11.fd (跟 stock edk2-aarch64-code.fd 区分,
# 后者是 Linux 用的 kraxel build).
#
# 此 firmware 必须打过 ArmVirtPkg/0001-armvirt-extra-ram-region-for-win11.patch,
# 否则 Win11 ARM64 bootmgfw.efi 在 0x10000000 ConvertPages 失败超时退出.
#
# 来源 (优先序):
#   1. scripts/edk2-build.sh build 出来的 third_party/edk2-stage/edk2-aarch64-code.fd
#      (走自家 build pipeline, 但 stable202508 默认 build options 跟 kraxel firmware 行为有
#       深层差异; stable202408 BaseTools 在 macOS 新 binutils 下 VfrCompile 链碰多个 fix 仍不通.
#       完整自家 build pipeline 留作后续工作.)
#   2. 同源参考项目 hell-vm 的 Vendor 产物
#      (Apple Silicon 用户可用 hellvm 项目 build 出的 firmware, 配套 patches/edk2/0001 同思路)
#   3. env $HVM_WIN11_EDK2 显式指定 firmware 文件路径 (CI / 手动 build)
#
# 不在 .app build 流程里强制依赖 — 没装 Win11 firmware 时 .app 仍可装, 但 hvm-cli start
# Win11 VM 启动失败 (找不到 win11 firmware), 提示用户跑此 script.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_FW="$ROOT/third_party/qemu-stage/share/qemu/edk2-aarch64-code-win11.fd"

c_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
step() { c_blue "==> $*"; }
ok()   { c_green "✔ $*"; }
warn() { c_yellow "⚠ $*"; }
err()  { c_red   "✗ $*" >&2; exit 1; }

# 候选源
EDK2_BUILD_FD="$ROOT/third_party/edk2-stage/edk2-aarch64-code.fd"
HELLVM_FD="${HVM_WIN11_EDK2_FROM_HELLVM:-/Volumes/DEVELOP/Develop/hell-vm/Vendor/qemu/share/qemu/edk2-aarch64-code.fd}"

mkdir -p "$(dirname "$STAGE_FW")"

# pad 64MB (QEMU virt pflash 必需)
pad_to_64m() {
    python3 -c "
import os, sys
p = sys.argv[1]
sz = os.path.getsize(p)
target = 64*1024*1024
if sz < target:
    with open(p, 'r+b') as f:
        f.seek(target - 1)
        f.write(b'\0')
elif sz > target:
    raise SystemExit('file %s already larger than 64MB: %d' % (p, sz))
" "$1"
}

src=""
if [[ -n "${HVM_WIN11_EDK2:-}" ]]; then
    [[ -f "$HVM_WIN11_EDK2" ]] || err "HVM_WIN11_EDK2=$HVM_WIN11_EDK2 不存在"
    src="$HVM_WIN11_EDK2"
    step "用 env HVM_WIN11_EDK2: $src"
elif [[ -f "$EDK2_BUILD_FD" ]]; then
    src="$EDK2_BUILD_FD"
    step "用 scripts/edk2-build.sh 自家 build 产物: $src"
elif [[ -f "$HELLVM_FD" ]]; then
    src="$HELLVM_FD"
    step "用 hell-vm 同源参考项目 vendor 产物: $src"
    warn "  这是借用同思路 binary; 若你后续 fix 了 scripts/edk2-build.sh 让自家 build 通,"
    warn "  请删除此文件让 fallback 走自家 build."
else
    err "找不到 Win11 firmware 来源. 选项:
      a) 跑 scripts/edk2-build.sh 自家 build (stable202508 build options 还需调通)
      b) 借 hell-vm 项目: 让 hell-vm Vendor/qemu/share/qemu/edk2-aarch64-code.fd 存在
      c) export HVM_WIN11_EDK2=/path/to/edk2-aarch64-code.fd 显式指向"
fi

cp -f "$src" "$STAGE_FW"
pad_to_64m "$STAGE_FW"
ok "Win11 EDK2 firmware 就绪: $STAGE_FW (64MB)"
ok "下一步: make build && make install, 然后 HVM_QEMU_WIN11_LOWRAM=1 hvm-cli start <Win11 VM>"
