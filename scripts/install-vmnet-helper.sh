#!/usr/bin/env bash
# scripts/install-vmnet-helper.sh
# 一次性配置 /etc/sudoers.d/hvm-socket-vmnet, 让 socket_vmnet 走 sudo NOPASSWD.
#
# 背景: macOS vmnet API 必须 root. socket_vmnet 是 Lima 项目的 daemon, 由 root 启,
#       通过 unix socket 让非 root QEMU 接 vmnet 桥接 / shared 网络.
#       为避免每次启 VM 弹密码, 一次性配置 sudoers NOPASSWD.
#
# 安全考量: sudoers entry 严格绑定具体 socket_vmnet 二进制绝对路径,
#          只允许 admin 组用户. 移动 .app 后需重新跑本脚本.
#
# 用法:
#   ./scripts/install-vmnet-helper.sh                    # 自动探测 socket_vmnet 路径
#   ./scripts/install-vmnet-helper.sh --bin <path>       # 显式指定
#   ./scripts/install-vmnet-helper.sh --check            # 只检查现有配置, 不写
#   ./scripts/install-vmnet-helper.sh --uninstall        # 删除 sudoers entry

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/hvm-socket-vmnet"

c_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
ok()    { c_green "✔ $*"; }
warn()  { c_yellow "⚠ $*"; }
err()   { c_red   "✗ $*" >&2; exit 1; }
info()  { c_blue  "ℹ $*"; }

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
    exit 0
}

# ---- 自动探测 socket_vmnet 路径 ----
# 优先级: 显式 --bin > HVM_SOCKET_VMNET_PATH env > .app 包内 > 仓库 third_party > brew
auto_locate() {
    if [[ -n "${HVM_SOCKET_VMNET_PATH:-}" && -x "$HVM_SOCKET_VMNET_PATH" ]]; then
        echo "$HVM_SOCKET_VMNET_PATH"; return
    fi
    # /Applications/HVM.app
    for app in "/Applications/HVM.app" "$HOME/Applications/HVM.app"; do
        local cand="$app/Contents/Resources/QEMU/bin/socket_vmnet"
        if [[ -x "$cand" ]]; then echo "$cand"; return; fi
    done
    # script 同根 (开发期 build/HVM.app 或 third_party/qemu)
    local script_dir
    script_dir="$(cd "$(dirname "$0")/.." && pwd)"
    for cand in \
        "$script_dir/build/HVM.app/Contents/Resources/QEMU/bin/socket_vmnet" \
        "$script_dir/third_party/qemu/bin/socket_vmnet"
    do
        if [[ -x "$cand" ]]; then echo "$cand"; return; fi
    done
    # brew 兜底
    for cand in \
        "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet" \
        "/opt/homebrew/bin/socket_vmnet" \
        "/usr/local/opt/socket_vmnet/bin/socket_vmnet"
    do
        if [[ -x "$cand" ]]; then echo "$cand"; return; fi
    done
    echo ""
}

# ---- 读现有 sudoers 配置, 提取 binary 路径 ----
current_sudoers_bin() {
    if [[ ! -r "$SUDOERS_FILE" ]]; then echo ""; return; fi
    # 解 NOPASSWD: <path> "*"  → 取 <path>
    sudo cat "$SUDOERS_FILE" 2>/dev/null \
        | grep -oE 'NOPASSWD:NOSETENV: [^ ]+' \
        | head -1 \
        | sed 's/NOPASSWD:NOSETENV: //'
}

# ---- check / install / uninstall ----
mode="install"
explicit_bin=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin)        explicit_bin="$2"; shift 2;;
        --check)      mode="check"; shift;;
        --uninstall)  mode="uninstall"; shift;;
        -h|--help)    usage;;
        *) err "未知参数: $1";;
    esac
done

case "$mode" in
    check)
        cur="$(current_sudoers_bin)"
        if [[ -z "$cur" ]]; then
            warn "$SUDOERS_FILE 未配置"
            exit 1
        fi
        if [[ ! -x "$cur" ]]; then
            warn "$SUDOERS_FILE 配置的路径已不存在: $cur"
            exit 2
        fi
        ok "$SUDOERS_FILE 已配置: $cur"
        exit 0
        ;;
    uninstall)
        if [[ ! -f "$SUDOERS_FILE" ]]; then
            info "$SUDOERS_FILE 不存在, 无需卸载"
            exit 0
        fi
        info "删除 $SUDOERS_FILE (需 sudo 密码):"
        sudo rm "$SUDOERS_FILE"
        ok "已卸载"
        exit 0
        ;;
    install)
        sv_bin="${explicit_bin:-$(auto_locate)}"
        if [[ -z "$sv_bin" || ! -x "$sv_bin" ]]; then
            err "找不到 socket_vmnet 二进制. 用 --bin <path> 显式指定; 或先 make build-all (会打包入 .app)"
        fi
        info "socket_vmnet: $sv_bin"

        # 安全: 路径必须以 /socket_vmnet 结尾, 防止误指错二进制
        if [[ "${sv_bin##*/}" != "socket_vmnet" ]]; then
            err "二进制名必须是 socket_vmnet, 收到: $sv_bin"
        fi

        # 检查与现有配置一致 → 跳过
        cur="$(current_sudoers_bin)"
        if [[ "$cur" == "$sv_bin" ]]; then
            ok "$SUDOERS_FILE 已配置且路径一致, 无需重写"
            exit 0
        fi
        if [[ -n "$cur" ]]; then
            warn "现有 sudoers 指向 $cur, 将被覆盖"
        fi

        # 生成 sudoers 内容. 跟 Lima 模板对齐, 用 %admin 组 + NOPASSWD:NOSETENV.
        # "*" 通配符: 允许任意 socket_vmnet 参数 (--vmnet-mode / --vmnet-interface /
        # --pidfile / 监听 socket 路径都是动态生成 per-VM, sudoers 没法穷举).
        # 安全等价于"所有 admin 组用户可以以 root 身份跑这个 binary 任意参数",
        # 而 socket_vmnet binary 自身只做 vmnet 相关操作, 不是通用 root shell.
        tmp="$(mktemp)"
        cat > "$tmp" <<EOF
# /etc/sudoers.d/hvm-socket-vmnet — by HVM scripts/install-vmnet-helper.sh
# 允许 admin 组用户 NOPASSWD 启动包内 socket_vmnet (vmnet 桥接 daemon).
# 移动 .app 后需重新跑该脚本更新路径.
%admin ALL=(root:root) NOPASSWD:NOSETENV: $sv_bin *
EOF
        chmod 440 "$tmp"

        info "写入 $SUDOERS_FILE (需 sudo 密码一次):"
        sudo install -m 440 -o root -g wheel "$tmp" "$SUDOERS_FILE"
        rm -f "$tmp"

        # 验证 sudoers 语法 (visudo -c)
        if ! sudo visudo -c -f "$SUDOERS_FILE" >/dev/null; then
            sudo rm "$SUDOERS_FILE"
            err "visudo 校验失败, 已回退. 请检查 $sv_bin 路径是否含特殊字符"
        fi
        ok "$SUDOERS_FILE 写入成功"

        # 自检: sudo -n 无密码跑 socket_vmnet --version 应能通
        info "自检: sudo -n $sv_bin --version"
        if sudo -n "$sv_bin" --version 2>&1 | head -3; then
            ok "NOPASSWD 配置生效"
        else
            warn "sudo -n 仍然要密码, 检查当前用户是否在 admin 组: dseditgroup -o checkmember -m \$USER admin"
        fi
        ;;
esac
