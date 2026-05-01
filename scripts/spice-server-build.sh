#!/usr/bin/env bash
# scripts/spice-server-build.sh
# 一键: 拉 spice-server v0.16.0 源码 → 应用 patches/spice-server/series → meson build →
#       裁剪 + 写 LICENSE/MANIFEST → 落 third_party/spice-server-stage/
# 仅打包者跑 (CLAUDE.md「QEMU 后端约束」例外允许的源 → .app 桥梁).
#
# 为啥要自己 build:
#   stock spice-server (brew install spice-server) 在 reds.cpp:1180 收到
#   AGENT_MSG_FILTER_MONITORS_CONFIG 后 return 直接吞掉, 不 forward 给 vdagent
#   端 → ARM Win 11 上 spice-vdagent (utmapp 自家 viogpudo) 收不到 monitors config,
#   dynamic resize 失效. UTM 走自己 patch 过的 spice-server, HVM 也必须如此.
#   详见 patches/spice-server/0001-reds-always-forward-monitors-config.patch.
#
# 产物路径:
#   third_party/spice-server-src/   — 上游 v0.16.0 tarball 解压后的源 (~2MB)
#   third_party/spice-server-stage/ — meson install 输出 (lib + include + pkgconfig)
#   third_party/spice-server-stage/lib/libspice-server.X.dylib — patched dylib
#   third_party/spice-server-stage/lib/pkgconfig/spice-server.pc — 给 QEMU configure 用
#
# 调用方:
#   - scripts/qemu-build.sh main() 在 ensure_brew_packages 后, build_qemu 前调本脚本,
#     export PKG_CONFIG_PATH=third_party/spice-server-stage/lib/pkgconfig:$PKG_CONFIG_PATH
#     让 QEMU configure 用 patched 版本而不是 brew 装的 stock 版本.
#   - bundle_qemu_system 跑 bundle_dylib_deps 时自动把 patched libspice-server 拉进
#     stage/lib/ (因为 qemu-system-aarch64 link 的就是 patched 版本).

set -euo pipefail

# ---- 锁定参数 ----
SPICE_SERVER_TAG="0.16.0"
SPICE_SERVER_TARBALL="https://www.spice-space.org/download/releases/spice-server/spice-${SPICE_SERVER_TAG}.tar.bz2"
SPICE_SERVER_SHA256="0a6ec9528f05371261bbb2d46ff35e7b5c45ff89bb975a99af95a5f20ff4717d"

# ---- 路径 ----
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/third_party/spice-server-src"
STAGE_DIR="$ROOT/third_party/spice-server-stage"
PATCHES_DIR="$ROOT/patches/spice-server"

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

# ---- 0. 装 spice-common 编译依赖 (python pyparsing) ----
ensure_pyparsing() {
    step "检查 python3 pyparsing (spice-common 代码生成依赖)"
    if python3 -c "import pyparsing" 2>/dev/null; then
        ok "pyparsing 已存在"
        return
    fi
    warn "pyparsing 不存在, 用 pip3 --user --break-system-packages 装"
    # PEP 668 要求 system python 用 pipx; 但 build 临时依赖装 user 级别 OK,
    # --break-system-packages 显式 ack 不污染 system site-packages
    pip3 install --user --break-system-packages pyparsing 2>&1 | tail -3 \
        || err "pyparsing 安装失败"
    python3 -c "import pyparsing" 2>/dev/null \
        || err "pyparsing 装完仍 import 失败 (PYTHONPATH 异常?)"
    ok "pyparsing 装好"
}

# ---- 1. 拉源码 ----
fetch_source() {
    step "拉 spice-server $SPICE_SERVER_TAG 源码"
    if [[ -d "$SRC_DIR/server" ]]; then
        ok "源码已存在: $SRC_DIR (复用; 强制重拉删 third_party/spice-server-src)"
        return
    fi
    mkdir -p "$(dirname "$SRC_DIR")"
    local tarball="$ROOT/third_party/.spice-server-${SPICE_SERVER_TAG}.tar.bz2"
    if [[ ! -f "$tarball" ]]; then
        curl -fsSL "$SPICE_SERVER_TARBALL" -o "$tarball" \
            || err "下载失败: $SPICE_SERVER_TARBALL"
    fi
    # SHA256 校验 (锁版本必校验, 防上游 tarball 偷换)
    local actual_sha
    actual_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [[ "$actual_sha" != "$SPICE_SERVER_SHA256" ]]; then
        rm -f "$tarball"
        err "spice-server tarball SHA256 不匹配: 期望 $SPICE_SERVER_SHA256, 实际 $actual_sha"
    fi
    rm -rf "$SRC_DIR"
    local tmp_extract
    tmp_extract="$(mktemp -d -t hvm-spice-extract)"
    tar xjf "$tarball" -C "$tmp_extract"
    mv "$tmp_extract/spice-${SPICE_SERVER_TAG}" "$SRC_DIR"
    rm -rf "$tmp_extract"
    ok "源码就绪: $SRC_DIR"
}

# ---- 2. 应用补丁 ----
apply_patches() {
    step "应用补丁 (patches/spice-server/series)"
    local series="$PATCHES_DIR/series"
    if [[ ! -f "$series" ]]; then
        warn "$series 不存在, 跳过补丁应用"
        return
    fi
    local count=0
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        local patch="$PATCHES_DIR/$line"
        [[ -f "$patch" ]] || err "series 引用的补丁不存在: $patch"
        echo "  → $line"
        # 用 patch -p1 (源码不在 git 仓库, 不能用 git apply)
        ( cd "$SRC_DIR" && patch -p1 --forward --silent < "$patch" ) \
            || err "补丁失败: $line (检查源码版本是否锁定 $SPICE_SERVER_TAG)"
        count=$((count+1))
    done < "$series"
    ok "应用了 $count 个补丁"
}

# ---- 3. meson configure + ninja build + install ----
build_and_install() {
    step "meson configure + ninja build"
    rm -rf "$STAGE_DIR"
    local build_dir="$SRC_DIR/build"
    rm -rf "$build_dir"
    # spice-server 必需依赖: pixman, glib (跟 QEMU 共享 brew 装的同版本).
    # 关键 build option:
    #   --buildtype=release       优化 + 不带 debug symbol
    #   -Dgstreamer=no            HVM 不需要视频 streaming 通道, 关掉省 dylib 依赖
    #   -Dlz4=false -Dsasl=false  跟 UTM 一致 (不开 lz4 image 压缩 / SASL 认证)
    #   -Dsmartcard=false         HVM 不接 USB smartcard 重定向
    #   -Dopus=disabled           audio codec 关 (display only, audio 走自家)
    #   -Dtests=false             跳过单元测试节约时间
    #   --prefix=stage            install 到 stage 目录 (lib/, include/, lib/pkgconfig/)
    meson setup "$build_dir" "$SRC_DIR" \
        --prefix="$STAGE_DIR" \
        --buildtype=release \
        -Dgstreamer=no \
        -Dlz4=false \
        -Dsasl=false \
        -Dsmartcard=disabled \
        -Dopus=disabled \
        -Dtests=false \
        || err "meson setup 失败"
    ninja -C "$build_dir" -j "$NCPU" || err "ninja build 失败"
    ninja -C "$build_dir" install || err "ninja install 失败"
    ok "spice-server 构建完成: $STAGE_DIR"
}

# ---- 4. 写 MANIFEST + LICENSE ----
write_manifest() {
    step "写 MANIFEST.json + LICENSE (LGPL 合规)"
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
  "spice_server_version": "$SPICE_SERVER_TAG",
  "spice_server_tarball": "$SPICE_SERVER_TARBALL",
  "spice_server_sha256": "$SPICE_SERVER_SHA256",
  "build_time_utc": "$build_time",
  "host_arch": "$(uname -m)",
  "build_options": [
    "--buildtype=release",
    "-Dgstreamer=no",
    "-Dlz4=false",
    "-Dsasl=false",
    "-Dsmartcard=false",
    "-Dopus=disabled",
    "-Dtests=false"
  ],
  "patches": $patches_json,
  "source_note": "spice-server $SPICE_SERVER_TAG 源 tarball + HVM 自家 patch (移植自 UTM PATCH 09/11)"
}
EOF
    [[ -f "$SRC_DIR/COPYING" ]] && cp "$SRC_DIR/COPYING" "$STAGE_DIR/LICENSE"
    ok "MANIFEST + LICENSE 写入"
}

# ---- main ----
main() {
    ensure_pyparsing
    fetch_source
    apply_patches
    build_and_install
    write_manifest
    echo
    c_green "════════════════════════════════════════"
    c_green "  spice-server (patched) 构建完成"
    c_green "════════════════════════════════════════"
    echo "  dylib:    $STAGE_DIR/lib/libspice-server.1.dylib"
    echo "  pkgconfig: $STAGE_DIR/lib/pkgconfig/spice-server.pc"
    echo "  manifest:  $STAGE_DIR/MANIFEST.json"
    echo "  下一步:   make qemu (qemu-build.sh 自动 export PKG_CONFIG_PATH 用本 stage)"
}

main "$@"
