#!/usr/bin/env bash
# scripts/install-vmnet-helper.sh
# 安装 socket_vmnet 的 launchd daemon, 让 vmnet shared / host / bridged 三种模式
# 的 unix socket 由 root 自动拉起, HVM 启动 VM 时直接连固定 socket 即可, 不再 per-VM sudo.
#
# 架构:
#   - launchd daemon 以 root 运行 socket_vmnet (vmnet.framework 要求 root)
#   - HVM 主进程 (普通用户) 通过 -netdev stream 连 /var/run/socket_vmnet*  (普通用户可读写)
#   - 一次 sudo 装好, 之后所有 VM 启动 / 关闭 都不再需要 sudo
#
# 用法:
#   sudo scripts/install-vmnet-helper.sh                # 装 shared + host (默认)
#   sudo scripts/install-vmnet-helper.sh en0            # + bridged(en0)
#   sudo scripts/install-vmnet-helper.sh en0 en1        # + bridged(en0) + bridged(en1)
#   sudo scripts/install-vmnet-helper.sh --uninstall    # 卸载所有 daemon
#   sudo scripts/install-vmnet-helper.sh --check        # 只列出当前 daemon 状态
#
# socket 路径约定 (与 socket_vmnet 上游 / lima / hell-vm 一致):
#   shared          → /var/run/socket_vmnet
#   host            → /var/run/socket_vmnet.host
#   bridged.<iface> → /var/run/socket_vmnet.bridged.<iface>

set -euo pipefail

PLIST_DIR="/Library/LaunchDaemons"
LABEL_PREFIX="com.hellmessage.hvm.vmnet"
SOCKET_BASE="/var/run/socket_vmnet"

c_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
ok()    { c_green "✔ $*"; }
warn()  { c_yellow "⚠ $*"; }
err()   { c_red   "✗ $*" >&2; exit 1; }
info()  { c_blue  "ℹ $*"; }

# ---- 必须 root ----
require_root() {
    if [ "$(id -u)" != "0" ]; then
        err "需要以 root 运行: sudo $0 $*"
    fi
}

# ---- 探测 socket_vmnet 二进制 ----
# 严格只走 /Applications/HVM.app 内的副本: launchd plist 把路径写死, 必须指向用户已安装
# 的稳定位置 (build/HVM.app 临时, make clean 后 daemon 即失效; brew 版本可能与打包版本协议不一致).
# 优先级: 显式 --bin > HVM_SOCKET_VMNET_PATH env > /Applications/HVM.app > ~/Applications/HVM.app
auto_locate() {
    if [[ -n "${HVM_SOCKET_VMNET_PATH:-}" && -x "$HVM_SOCKET_VMNET_PATH" ]]; then
        echo "$HVM_SOCKET_VMNET_PATH"; return
    fi
    for app in "/Applications/HVM.app" "$HOME/Applications/HVM.app"; do
        local cand="$app/Contents/Resources/QEMU/bin/socket_vmnet"
        if [[ -x "$cand" ]]; then echo "$cand"; return; fi
    done
    echo ""
}

# ---- check: 列出当前 daemon 状态 ----
mode_check() {
    info "当前 HVM socket_vmnet daemon 状态:"
    local found=0
    for plist in "$PLIST_DIR"/${LABEL_PREFIX}.*.plist; do
        [ -e "$plist" ] || continue
        found=1
        local label
        label=$(basename "$plist" .plist)
        local sock
        case "$label" in
            "${LABEL_PREFIX}.shared")        sock="$SOCKET_BASE";;
            "${LABEL_PREFIX}.host")          sock="${SOCKET_BASE}.host";;
            "${LABEL_PREFIX}.bridged."*)     sock="${SOCKET_BASE}.bridged.${label##*.bridged.}";;
            *)                               sock="?";;
        esac
        local status="DOWN"
        if [ -S "$sock" ]; then status="UP"; fi
        echo "    [$status] $label  →  $sock"
    done
    if [ "$found" = "0" ]; then
        echo "    (无)"
        echo ""
        info "运行 \`sudo $0\` 安装 shared+host; 或 \`sudo $0 en0\` 加桥接 en0"
        exit 1
    fi
    exit 0
}

# 把 HVM plist label 的 suffix (shared/host/bridged.<iface>) 映射到 socket 路径.
# 给 mode_uninstall + install_one 共用. label 不在白名单 → 返回空字符串.
suffix_to_socket() {
    local suffix="$1"
    case "$suffix" in
        shared)         echo "$SOCKET_BASE" ;;
        host)           echo "${SOCKET_BASE}.host" ;;
        bridged.*)
            local iface="${suffix#bridged.}"
            # 接口名只允许 [a-zA-Z0-9]+, 防 shell 注入
            if [[ "$iface" =~ ^[a-zA-Z0-9]+$ ]]; then
                echo "${SOCKET_BASE}.bridged.$iface"
            else
                echo ""
            fi
            ;;
        *) echo "" ;;
    esac
}

# ---- uninstall: 卸载所有 HVM 装的 daemon ----
# 严格只动 HVM 自己的 plist 范围. 不再 glob 删 /var/run/socket_vmnet.bridged.*,
# 否则会误删 lima / colima / hell-vm 等并存项目的 daemon socket.
mode_uninstall() {
    require_root "$@"
    shopt -s nullglob
    local removed=0
    for plist in "$PLIST_DIR"/${LABEL_PREFIX}.*.plist; do
        local label suffix sock
        label=$(basename "$plist" .plist)
        suffix="${label#${LABEL_PREFIX}.}"
        sock=$(suffix_to_socket "$suffix")

        info "卸载 $label"
        launchctl bootout "system/$label" 2>/dev/null || true
        rm -f "$plist"
        # 仅删跟本 plist 1:1 配套的 socket; 别家 plist 占的 socket 不动
        if [[ -n "$sock" ]]; then
            rm -f "$sock"
        fi
        removed=$((removed + 1))
    done
    ok "已卸载 $removed 个 daemon"
    exit 0
}

# ---- install: 装一个 daemon plist + bootstrap ----
# 参数: <suffix> <socket_path> <socket_vmnet 额外参数...>
install_one() {
    local suffix="$1"; shift
    local sock="$1"; shift
    local label="${LABEL_PREFIX}.${suffix}"
    local plist="$PLIST_DIR/${label}.plist"

    # 共存检测: 如果对应 socket 路径已被另一个项目 (lima / colima / hell-vm) 装的
    # daemon 占用 (socket 文件存在且是 unix socket), 而且 HVM 自己**没装过**这个
    # plist (PLIST_DIR 下没我们的同 label 文件), 就跳过安装, 复用外部 daemon.
    # 这样 HVM 不会跟 lima/colima 等共存项目抢资源, 也避免 unlink 别家 socket.
    if [[ ! -f "$plist" && -S "$sock" ]]; then
        info "检测到 $sock 已被外部 daemon 占用 (lima / colima / hell-vm 等)"
        info "  → 复用现有 daemon, 跳过 HVM plist 安装. 卸载外部项目后请重跑本脚本."
        return 0
    fi

    local args_xml=""
    args_xml+="    <string>$SOCKET_VMNET</string>"$'\n'
    for a in "$@"; do
        args_xml+="    <string>$a</string>"$'\n'
    done
    args_xml+="    <string>$sock</string>"

    # 旧 plist 存在则先 bootout, 保证新参数生效.
    # bootout 是异步: launchd 标记退出后立刻返回, 实际 daemon 进程 + socket 资源释放
    # 需要几百 ms; 紧接 bootstrap 会撞 "Bootstrap failed: 5: Input/output error".
    # 故 bootout 后轮询 launchctl print 等服务真消失再继续.
    launchctl bootout "system/$label" 2>/dev/null || true
    local _bootout_wait=0
    while launchctl print "system/$label" >/dev/null 2>&1; do
        _bootout_wait=$((_bootout_wait + 1))
        if (( _bootout_wait > 25 )); then break; fi   # 5s 上限, 防极端 hang
        sleep 0.2
    done

    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args_xml
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>UserName</key>
  <string>root</string>
  <key>StandardOutPath</key>
  <string>/var/log/socket_vmnet.$suffix.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/socket_vmnet.$suffix.log</string>
</dict>
</plist>
EOF
    chmod 644 "$plist"
    chown root:wheel "$plist"
    rm -f "$sock"
    # bootstrap retry: 偶发 EIO (launchd 内部 race). 5 次, 每次间隔指数后退.
    local _boot_try=0 _boot_max=5 _boot_sleep
    while ! launchctl bootstrap system "$plist" 2>/tmp/.hvm_vmnet_boot.err; do
        _boot_try=$((_boot_try + 1))
        if (( _boot_try >= _boot_max )); then
            cat /tmp/.hvm_vmnet_boot.err >&2
            rm -f /tmp/.hvm_vmnet_boot.err
            die "launchctl bootstrap $label 失败 (尝试 $_boot_max 次仍失败)"
        fi
        _boot_sleep=$(awk "BEGIN { printf \"%.2f\", 0.3 * (2 ^ ($_boot_try - 1)) }")
        warn "launchctl bootstrap $label 失败, ${_boot_sleep}s 后重试 ($_boot_try/$_boot_max)"
        # 失败时再保险 bootout 一次 + 等
        launchctl bootout "system/$label" 2>/dev/null || true
        sleep "$_boot_sleep"
    done
    rm -f /tmp/.hvm_vmnet_boot.err
    launchctl enable "system/$label" 2>/dev/null || true
    ok "$label  →  $sock"
}

# ---- 主流程 ----
mode="install"
ifaces=()
explicit_bin=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)      mode="check"; shift;;
        --uninstall)  mode="uninstall"; shift;;
        --bin)        explicit_bin="$2"; shift 2;;
        -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0;;
        -*)           err "未知参数: $1";;
        *)            ifaces+=("$1"); shift;;
    esac
done

case "$mode" in
    check)     mode_check;;
    uninstall) mode_uninstall;;
esac

# install 路径
require_root "$@"
SOCKET_VMNET="${explicit_bin:-$(auto_locate)}"
if [[ -z "$SOCKET_VMNET" || ! -x "$SOCKET_VMNET" ]]; then
    err "找不到 socket_vmnet 二进制 (仅查 /Applications/HVM.app 与 ~/Applications/HVM.app).
    daemon plist 路径写死, 必须指向稳定位置, 不接受 build/ 或 brew fallback.
    解决:
      1) make build-all (出 build/HVM.app, 含 socket_vmnet)
      2) make install (拷到 /Applications/HVM.app)
      3) sudo $0 [iface...]
    显式覆盖 (调试用): $0 --bin /path/to/socket_vmnet"
fi
# 安全: 路径必须以 /socket_vmnet 结尾
if [[ "${SOCKET_VMNET##*/}" != "socket_vmnet" ]]; then
    err "二进制名必须是 socket_vmnet, 收到: $SOCKET_VMNET"
fi
info "socket_vmnet: $SOCKET_VMNET"

info "安装 shared (类 NAT, host 与 guest 互通; 多 guest 互通)"
install_one "shared" "$SOCKET_BASE" \
    "--vmnet-mode=shared" \
    "--vmnet-gateway=192.168.105.1" \
    "--vmnet-dhcp-end=192.168.105.254"

info "安装 host (host-only, 仅 host 与 guest 互通)"
install_one "host" "${SOCKET_BASE}.host" \
    "--vmnet-mode=host" \
    "--vmnet-gateway=192.168.106.1" \
    "--vmnet-dhcp-end=192.168.106.254"

# bridged: 每个传入的接口起一个 daemon.
# guard: bash set -u 下空数组 "${ifaces[@]}" 展开会 unbound; 0 接口时直接跳过.
if (( ${#ifaces[@]} > 0 )); then
    for iface in "${ifaces[@]}"; do
        if ! [[ "$iface" =~ ^[a-zA-Z0-9]+$ ]]; then
            warn "跳过非法接口名 '$iface'"
            continue
        fi
        info "安装 bridged($iface) (跨物理 LAN; guest IP 落物理网段)"
        install_one "bridged.$iface" "${SOCKET_BASE}.bridged.$iface" \
            "--vmnet-mode=bridged" \
            "--vmnet-interface=$iface"
    done
fi

echo ""
info "完成. 当前 socket:"
ls -la ${SOCKET_BASE}* 2>/dev/null || echo "    (socket 启动有 1-2s 延迟, 稍等再 ls)"
echo ""
info "卸载: sudo $0 --uninstall"
info "状态: $0 --check"
