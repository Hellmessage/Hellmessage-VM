#!/usr/bin/env bash
# scripts/install-vmnet-daemons.sh
# 安装 socket_vmnet 的 launchd daemon, 让 vmnet shared / host / bridged 三种模式
# 的 unix socket 由 root 自动拉起. HVM 启动 VM 时直接连固定 socket 即可.
#
# 与上一版 install-vmnet-helper.sh 的差异 (切到 hell-vm 风格):
#   - socket_vmnet 不再打包入 .app, 用户机器需先 `brew install socket_vmnet`
#   - 不再写 /etc/sudoers.d/* (HVM 不再做自动 kickstart)
#   - 由 GUI VMnetSupervisor 通过 osascript "with administrator privileges" 拉起
#     (Touch ID / 密码框), 不再走 Terminal sudo bash
#
# 幂等性 (v2):
#   install_one 先把 desired plist 写到 tmp, 跟 on-disk 现有 plist 字节比对,
#   完全一致 + daemon 还在 launchctl 视图 + socket 还在 → 直接跳过, 不 bootout.
#   这条是修 "点 VM B 的 [安装/更新 daemon], 跑着的 VM A 全掉网" BUG 的关键 —
#   bootout + rm socket + bootstrap 会切断所有已连的 QEMU stream-netdev (QEMU
#   不会自动重连). 必须只在真正需要重建时才走破坏性路径.
#
#   note: brew upgrade socket_vmnet 后 plist 内容不变, 不会自动 refresh 已跑的
#   daemon. 需要走 "卸载全部" → "安装" 强制重启. v1 不做自动检测.
#
# 用法:
#   sudo scripts/install-vmnet-daemons.sh              # 装 shared + host
#   sudo scripts/install-vmnet-daemons.sh en0          # + bridged(en0)
#   sudo scripts/install-vmnet-daemons.sh en0 en1      # + bridged(en0) + bridged(en1)
#   sudo scripts/install-vmnet-daemons.sh --uninstall  # 卸载所有 daemon
#
# socket 路径约定 (与 socket_vmnet 上游 / lima / hell-vm 一致):
#   shared          → /var/run/socket_vmnet
#   host            → /var/run/socket_vmnet.host
#   bridged.<iface> → /var/run/socket_vmnet.bridged.<iface>
#
# plist label 前缀 (HVM 自家 namespace, 避免跟 lima/colima/hell-vm 冲突):
#   com.hellmessage.hvm.vmnet.shared / .host / .bridged.<iface>

set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "错误: 需要以 root 运行"
    echo "    sudo $0 $*"
    exit 1
fi

# 查 socket_vmnet 二进制位置. brew 装法有 Apple Silicon 和 Intel 两种前缀.
find_socket_vmnet() {
    for p in /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet \
             /usr/local/opt/socket_vmnet/bin/socket_vmnet \
             /opt/homebrew/bin/socket_vmnet \
             /usr/local/bin/socket_vmnet; do
        if [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    return 1
}

PLIST_DIR="/Library/LaunchDaemons"
LABEL_PREFIX="com.hellmessage.hvm.vmnet"
SOCKET_BASE="/var/run/socket_vmnet"

# ---------- 卸载 ----------
uninstall_all() {
    shopt -s nullglob
    local removed=0
    for plist in "$PLIST_DIR"/${LABEL_PREFIX}.*.plist; do
        local label
        label=$(basename "$plist" .plist)
        echo "==> 卸载 $label"
        launchctl bootout "system/$label" 2>/dev/null || true
        rm -f "$plist"
        removed=$((removed + 1))
    done
    # 残留 socket 文件清掉, 避免下次用脏的
    rm -f "$SOCKET_BASE" "$SOCKET_BASE".host "$SOCKET_BASE".bridged.*
    echo "==> 共卸载 $removed 个 daemon"
}

if [ "${1:-}" = "--uninstall" ]; then
    uninstall_all
    exit 0
fi

# ---------- 安装 ----------
SOCKET_VMNET="$(find_socket_vmnet)" || {
    cat <<'EOF'
错误: 未找到 socket_vmnet 二进制
    请先装: brew install socket_vmnet
    然后重跑本脚本.
EOF
    exit 1
}
# 路径白名单: 后续要直拼进 plist heredoc, 含 <>& 等 XML 特殊字符会破 plist 格式.
# brew 路径正常情况下 ASCII + /._- , 这里 fail-fast 而不是生成损坏 plist 让 launchd 拒载.
if ! [[ "$SOCKET_VMNET" =~ ^[a-zA-Z0-9/._-]+$ ]]; then
    echo "✗ socket_vmnet 路径含非法字符: '$SOCKET_VMNET'" >&2
    echo "    仅允许 [a-zA-Z0-9/._-] (防 plist XML 注入)" >&2
    exit 1
fi
echo "==> socket_vmnet 路径: $SOCKET_VMNET"

# 生成单个 daemon plist + load
# 参数: <label_suffix> <socket_path> <socket_vmnet 额外参数...>
install_one() {
    local suffix="$1"; shift
    local sock="$1"; shift
    local label="${LABEL_PREFIX}.${suffix}"
    local plist="$PLIST_DIR/${label}.plist"

    # ProgramArguments 里每一项一个 <string>
    local args_xml=""
    args_xml+="    <string>$SOCKET_VMNET</string>"$'\n'
    for a in "$@"; do
        args_xml+="    <string>$a</string>"$'\n'
    done
    args_xml+="    <string>$sock</string>"

    # desired plist 先落到 tmp, 跟 on-disk 做 byte-by-byte diff. 一致 + daemon 还
    # 在 launchctl 视图 + socket 还在 → 幂等跳过 (不 bootout / 不删 socket /
    # 不打断已连接的 VM). 这是修 "点了某台 VM 的 [安装/更新], 别的 VM 全掉网"
    # BUG 的核心: bootout 会 SIGTERM daemon, 已连的 QEMU stream-netdev 会断且不重连.
    local tmp_plist
    tmp_plist=$(mktemp -t hvm-vmnet-plist) || tmp_plist="/tmp/hvm-vmnet-plist.$$.${suffix}"
    cat > "$tmp_plist" <<EOF
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

    if [ -f "$plist" ] \
        && [ -S "$sock" ] \
        && cmp -s "$tmp_plist" "$plist" \
        && launchctl print "system/$label" >/dev/null 2>&1
    then
        rm -f "$tmp_plist"
        echo "    = $label 已就绪, 跳过 (socket=$sock)"
        return 0
    fi

    # 走到这里说明: plist 内容变了 / daemon 不在 / socket 丢了 — 必须重装 (破坏性).
    # 旧 daemon 残留必须彻底清掉, 否则 launchctl bootstrap 偶发 "Bootstrap failed: 5:
    # Input/output error" — launchd database 内 stale 引用未清, 由 plist file 仍存
    # 在 / 老 service handle 还没被 GC 触发. 历史 BUG: 用户撞 "shared 缺失 + host 装好 +
    # 想加 bridged.en8" 这种部分状态, 直接点安装就 error 5; 必须先 "卸载全部" 再装.
    # 这里强化清理路径: by-label bootout + by-plist bootout (新形式更可靠) + 删 plist 文件,
    # 让 bootstrap 跑前 launchd 视图里这个 label 不存在任何痕迹.
    echo "    ↻ $label 需要 (重新) 安装"
    launchctl bootout "system/$label" 2>/dev/null || true
    if [ -f "$plist" ]; then
        # bootout 接 plist 路径 (Big Sur+) 比 by-label 更彻底, 顺手清掉 launchd 缓存
        launchctl bootout system "$plist" 2>/dev/null || true
    fi
    rm -f "$plist"
    # 短延迟给 launchd async unload + KeepAlive teardown 一点时间. 实测 bootout 返 0
    # 不代表 service 真死, 200ms 经验值够覆盖 SIGTERM → exit 路径.
    sleep 0.2

    mv "$tmp_plist" "$plist"
    chmod 644 "$plist"
    chown root:wheel "$plist"

    # 旧残留 socket 先清掉, 避免 socket_vmnet 拒绝 bind
    rm -f "$sock"

    # bootstrap: 一次失败立即兜底重试 (再 bootout + sleep + 重新 bootstrap), 不让用户
    # 看到 error 5 后还要"卸载全部 → 安装" 两步. launchctl 没有 idempotent install
    # 的官方 API, 错误码 5 (EIO) 是 launchd 内部 stale state, 二次清理通常就能过.
    if ! launchctl bootstrap system "$plist" 2>/tmp/hvm-vmnet-bootstrap.err; then
        local err1
        err1=$(cat /tmp/hvm-vmnet-bootstrap.err 2>/dev/null || true)
        echo "    ⚠ bootstrap 第 1 次失败: ${err1:-unknown}, 强制清理后重试 ..."
        launchctl bootout "system/$label" 2>/dev/null || true
        launchctl bootout system "$plist" 2>/dev/null || true
        sleep 0.5
        if ! launchctl bootstrap system "$plist"; then
            echo "    ✗ bootstrap 第 2 次仍失败 — 请运行 '$0 --uninstall' 后重试" >&2
            return 1
        fi
    fi
    rm -f /tmp/hvm-vmnet-bootstrap.err
    # enable 一次, 下次系统重启也会自动起
    launchctl enable "system/$label" 2>/dev/null || true
    echo "    ✓ $label  →  $sock"
}

echo "==> 安装 shared (NAT + DHCP)"
install_one "shared" "$SOCKET_BASE" \
    "--vmnet-mode=shared" \
    "--vmnet-gateway=192.168.105.1" \
    "--vmnet-dhcp-end=192.168.105.254"

echo "==> 安装 host-only"
install_one "host" "${SOCKET_BASE}.host" \
    "--vmnet-mode=host" \
    "--vmnet-gateway=192.168.106.1" \
    "--vmnet-dhcp-end=192.168.106.254"

# 桥接: 每个传入的接口起一个 daemon
for iface in "$@"; do
    # 过滤参数, 不接受奇怪的字符 (防 shell 注入). 之前是 warn + continue,
    # 但 GUI/CI 调用方拿到 0 退出码会以为安装成功 — 改 fail-fast.
    if ! [[ "$iface" =~ ^[a-zA-Z0-9]+$ ]]; then
        echo "✗ 非法接口名: '$iface' (仅允许 [a-zA-Z0-9]+, 防 shell 注入)" >&2
        exit 1
    fi
    echo "==> 安装 bridged (iface=$iface)"
    install_one "bridged.$iface" "${SOCKET_BASE}.bridged.$iface" \
        "--vmnet-mode=bridged" \
        "--vmnet-interface=$iface"
done

echo ""
echo "==> 完成. 当前 socket:"
ls -la ${SOCKET_BASE}* 2>/dev/null || echo "    (socket 未立即出现, daemon 启动有 1-2 秒延迟)"
echo ""
echo "卸载: sudo $0 --uninstall"
