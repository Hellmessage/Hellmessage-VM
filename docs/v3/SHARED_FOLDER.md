# 共享目录 (host ↔ guest) — SPICE WebDAV 路线

> 状态: **代码已合入 2026-05-24** (PR-0 ~ PR-7 当晚一次性落地)
>
> 现状回写: [../v1/SHARING.md](../v1/SHARING.md). 约束回写: [CLAUDE.md "共享目录约束"](../../CLAUDE.md). 本稿留底作决策溯源.
>
> **设计变更说明**: v1 稿走 "Linux 9p 先, Win SPICE WebDAV 推后". 用户 2026-05-24 改"Win 先 Linux 后", 全文重写为 SPICE WebDAV 统一路径 (Win + Linux 同协议, 复用现有 SPICE 客户端框架). 9p 路线在"未来选项 / 备选"节留底, 不动手.
>
> **未实测**: 真机 Win11 / Linux guest 内 spice-webdavd ↔ host SpiceWebdavServer 端到端连接 (用户运行中 VM, 未敢扰动). **协议层完整 e2e 验过** (44 单测 + 23 socket-level mux+HTTP 测), host wiring 在 OpenWrt QEMU VM 上验过 (log `webdav connected to <private> roots=1`). 用户真机 guest 测时若 spice-webdavd 握手失败, 排查方向: (1) 检 guest `/dev/virtio-ports/org.spice-space.webdav.0` 存在; (2) 检 host log `SpiceWebdav` category; (3) 抓 mux frame 帧头确认协议字段顺序.

## 目标

- **解决问题**: host ↔ guest 之间没有持久共享通路, 现状只能 `hvm-dbg file push/pull` 单文件传 (QGA, 1-10 MB/s, 4 GiB 上限). 开发场景"在 host 编辑代码, 在 guest 编译"反复折腾极不便
- **交付**: 详情页 Sharing 区新增"共享目录"卡片, 用户挑 host 目录 → 启动 VM 自动挂到 guest, 默认 read-only, dialog 可勾 RW
- **范围**:
  - **PR-1 ~ PR-5**: QEMU 后端 + Windows ARM64 guest (SPICE WebDAV channel `org.spice-space.webdav.0`)
  - **PR-6 ~ PR-7**: QEMU 后端 + Linux guest (同 SPICE WebDAV 路径, guest 内装 phodav-mount/spice-webdavd)
  - VZ 后端: **单独 VZ_SHARED_DIRECTORY.md 提案**, 不在本设计稿范围
- **范围外**:
  - 双向剪贴板: 已有 (vdagent 通道), 不动
  - 拖拽传文件 (drag-and-drop): 推后
  - 多目录共享: v1 单目录 (WebDAV 协议天然支持多 root, schema 留扩展, 实现先单)
  - 同步 / 单向 mirror: 不做
  - 跨 VM 共享同一 host 目录: 允许 (用户自负数据竞争), 不做特殊处理

## 项目当前状态 (设计前提)

```
✅ 已有:
  third_party/spice-server-stage/lib/libspice-server.1.dylib  (0.16.0, UTM patch 移植)
  third_party/spice-server-src/                                 (源码 + patches)
  scripts/qemu-build.sh                                         (--disable-spice, QEMU 不链 spice-server)
  app/Sources/HVMQemu/QemuArgsBuilder.swift                     (vdagentSocketPath 已支持)
    └─ -chardev socket,id=vdagent,path=<sock>,server=on,wait=off
    └─ -device virtserialport,bus=vsp0.0,chardev=vdagent,name=com.redhat.spice.0
  HVM 主进程 SPICE main channel 客户端                          (Swift 实现, 当前发 VDAgentMonitorsConfig)
  app/Sources/HVMInstall/UtmGuestToolsCache.swift               (UTM Guest Tools ISO 下载/缓存)
  WindowsUnattend.swift                                          (静默装 UTM Guest Tools)

❌ 缺失:
  org.spice-space.webdav.0 channel 的 Swift 实现 (WebDAV 协议 server 端)
  guest 内 webdav 客户端的安装确认 (UTM Guest Tools 是否含 phodav-mount?)
  config schema 字段 (sharedFolders)
  CLI / GUI 入口
  自动挂载脚本 (Win 不需要, phodav-mount 装好后自动挂; Linux 需 systemd 接管 spice-webdavd)
```

**核心洞察**: 不需要重 build QEMU, 不需要打包额外 dylib. 在现有"Swift 主进程接 virtio-serial socket 实现 SPICE 协议"的模式上, 再加一条 `org.spice-space.webdav.0` channel + 一个 WebDAV server 实现, 端到端打通.

## 选型对比

### 后端协议: 4 选 1

| 协议 | host 端 | guest 端 | macOS host 可用 | Win guest 可用 | 估时 (本次评估) |
|---|---|---|---|---|---|
| **SPICE WebDAV** ✅ 选定 | 现有 spice client 模式扩条 channel | Win: phodav-mount (UTM Guest Tools 待确认); Linux: spice-webdavd | ✅ | ✅ | **1.5 周** (复用现有框架) |
| virtiofs (`vhost-user-fs`) | virtiofsd Rust binary | Linux 5.4+ kernel; Win virtio-win | ❌ virtiofsd 不支持 macOS host (gitlab #169) | ✅ | N/A, 路堵死 |
| 9p (`virtio-9p-pci`) | QEMU 内建 | Linux 内核自带 | ✅ | ❌ Win 无 9p driver | 4 天但**不覆盖 Win** |
| SMB over user-network | QEMU `-smb` (slirp samba) | guest SMB client | ✅ | ✅ | slirp 限制多, 防火墙坑, 不考虑 |

**选定 SPICE WebDAV**. 唯一同时覆盖 Win + Linux + macOS host 的协议, 且与现有 SPICE 基础设施天然兼容.

### WebDAV server 实现: 3 选 1

| 方案 | 实现 | 评价 |
|---|---|---|
| **Swift 原生 WebDAV server** ✅ 选定 | HVM 主进程内 Swift 实现 WebDAV (HTTP-ish 协议) over spice port | 零额外二进制, 与现有 spice client 同进程同套生命周期, 协议简单 (PROPFIND / GET / PUT / DELETE / MKCOL 几个动词) |
| 打包 phodav 二进制 (UTM 同款) | 编译 phodav-server for macOS, per-VM 起子进程, 走 socket | 多一个 helper 进程, 多一份 license / 打包 / 签名工作量; phodav 在 macOS 编译有 glib 依赖坑 |
| 编译 phodav 进 spice-server lib + QEMU 链 | 重 build QEMU `--enable-spice` + phodav 静态链 | 重做 QEMU build, 重新分发, 与项目"QEMU 不链 spice"现状冲突 |

**选定 Swift 原生**. WebDAV 协议小, server 端 read-only + RW 两条路径, 几百行 Swift. 与现有 `QemuHostEntry` 内的 spice main client 同模式.

WebDAV-over-spice-port 协议参考: spice-space `port_forward` doc + phodav-mount 客户端实测抓包 (PR-1 真机).

### 自动挂载实现 (guest 侧)

| guest OS | 客户端 binary | 自动启动 |
|---|---|---|
| Windows ARM64 | phodav-mount.exe (?? 待验证 UTM Guest Tools 是否含 ARM64 版) | Windows 服务 (UTM Guest Tools 装时注册) |
| Linux | `spice-webdavd` daemon + GVFS `gvfs-mount` 或 systemd `gvfs-daemon` | systemd service, 已在 spice-vdagent 包内 |

**关键待验证 (P0)**: UTM Guest Tools ISO 是否含 phodav-mount.exe (ARM64 native)? 若无, 用户得自己装 ARM64 native phodav, 或我们 build 一个 win-arm64 binary 加进 unattend ISO. **PR-0 必须先 mount UTM Guest Tools ISO 看里面文件**, 没有再加一项 "build phodav-mount win-arm64" 的子任务.

## 实现要点

### config schema (写入 config.yaml)

```yaml
# 新增字段 (VMConfig)
sharedFolders:
  - hostPath: /Users/me/code            # host 端绝对路径
    name: code                           # 用户给的友好名, 影响 guest 内挂载点
    readOnly: true                       # 默认 true
    autoMount: true                      # 默认 true, v1 永远 true 不暴露
```

**字段缺省**: 旧 yaml 无 `sharedFolders` → 解码 `?? []`. **schema bump 不需要** (默认值无破坏). VZ 后端解码到 `sharedFolders` 非空 → 启动期警告"VZ 后端共享目录推后, 已忽略", **不**阻塞启动.

guest 内挂载点 (固定规则, 不让用户改):
- Windows: 装 phodav-mount 后默认挂为 `\\spice-webdav\` 网络位置, 内含 `<name>` 子目录
- Linux: GVFS 挂到 `~/.gvfs/SPICE shared folder/<name>` 或 `/run/user/$UID/gvfs/...` (依发行版)

### QEMU argv 新增

[`QemuArgsBuilder`](../../app/Sources/HVMQemu/QemuArgsBuilder.swift) 增字段:

```swift
public struct Input {
    // ...现有字段...
    public var webdavSocketPath: String?       // sharedFolders 非空时设
}
```

argv 增加 (与 vdagent 同 virtio-serial bus `vsp0`):

```bash
-chardev socket,id=webdav,path=<webdavSocketPath>,server=on,wait=off
-device virtserialport,bus=vsp0.0,chardev=webdav,name=org.spice-space.webdav.0
```

PCI bus 复用现有 `vsp0` (virtio-serial bus, vdagent / qga 共用), 不新增 PCI slot. port number 走 vsp0 上的下一个空闲位.

### Swift 端 WebDAV server

新增 [`app/Sources/HVMQemu/SpiceWebdavServer.swift`](../../app/Sources/HVMQemu/SpiceWebdavServer.swift):

```swift
public actor SpiceWebdavServer {
    public init(
        socketPath: String,
        roots: [SharedFolderRoot],   // [(name, hostURL, readOnly)]
        log: Logger
    )

    public func start() async throws    // listen unix socket, accept guest 连接
    public func stop() async
}

public struct SharedFolderRoot: Sendable {
    public let name: String
    public let hostURL: URL
    public let readOnly: Bool
}
```

实现要点:
- listen unix socket, 等 guest phodav-mount/spice-webdavd 来连
- 协议: WebDAV-over-spice-port (HTTP/1.1-like, 但跑在 spice port 帧之上, 帧格式简单 4-byte length-prefix + 0xFFFFFFFF 关闭语义, 参考现有 vdagent 路径)
- 支持动词: `OPTIONS / PROPFIND / GET / PUT / DELETE / MKCOL / MOVE / COPY`
- read-only 模式拒绝 PUT / DELETE / MKCOL / MOVE / COPY, 返 403 Forbidden
- 路径规范化必须做 (`..` / 绝对路径 / symlink) — **防 guest escape host 路径** (P0 security)
- 大文件 GET / PUT 走 chunked transfer, 不一次性 read 进内存 (64 KiB buffer)
- 多 root 支持: WebDAV depth-1 列出 `/<name>` 子目录列表

### 主流程时序

```
1. 用户在详情页 Sharing 区点 [+ 共享目录]
2. NSOpenPanel 选 host 目录
3. SharedFolderDialog (HVMModal) 显示路径 + 友好名 + RW toggle + [保存]
4. 保存 → VMConfig.sharedFolders 增条, BundleIO.save (加密 VM 走 EncryptedConfigIO.save)
5. VM stopped → 下次启动生效; running → 提示"重启 VM 生效" (chardev 不支持热加)
6. 启动 VM:
   a. QemuHostEntry 计算 webdavSocketPath (runDir/<vm>.webdav)
   b. SpiceWebdavServer 起 listen
   c. QemuArgsBuilder 注入 -chardev + -device
   d. QEMU 起, guest 起来后 spice-webdavd / phodav-mount 自动连
7. guest 内自动可见 (Win: 文件资源管理器看到 \\spice-webdav 网络位置; Linux: GVFS 挂载)
8. host 端目录变化 → guest 端实时可见 (WebDAV 无 inotify, 但 GET / PROPFIND 都是实时读 host fs, 没缓存)
```

### dialog / 按钮

走 [`HVMModal`](../../app/Sources/HVM/UI/Style/) 容器. probe id 命名 (HVM_DBG_GUI_PROTOCOL):

```
detail.sharing.sharedFolder.button.add
detail.sharing.sharedFolder.list.row.<index>
detail.sharing.sharedFolder.button.remove.<index>
dialog.sharedFolder.label.hostPath
dialog.sharedFolder.input.name
dialog.sharedFolder.toggle.readOnly
dialog.sharedFolder.button.save
dialog.sharedFolder.button.cancel
```

详情页 Sharing 区卡片:

```
┌─ 共享目录 ────────────────────────────────────────┐
│ code   /Users/me/code         [只读]  [已挂载]  ✕│
│ docs   /Users/me/docs          [可写]  [已挂载]  ✕│
└──────────────────────────────────────────────────┘
[+ 共享目录]
```

### 后端 / OS 矩阵

| guest OS | VZ 后端 | QEMU 后端 |
|---|---|---|
| Windows | N/A (Win 必走 QEMU) | ✅ PR-1~5, SPICE WebDAV |
| Linux | 推后 (VZ_SHARED_DIRECTORY.md) | ✅ PR-6~7, SPICE WebDAV (与 Win 同代码路径) |
| macOS | 推后 (VZ_SHARED_DIRECTORY.md, VZSharedDirectory) | N/A (macOS 必走 VZ) |

## 风险与待验证项

### P0 must-pass

- **R1 (PR-0)**: **UTM Guest Tools ISO 是否含 phodav-mount.exe (ARM64 native)?** 若无, 需补一项 "build phodav-mount win-arm64" 子任务 (额外 2-3 天). 用 `hdiutil attach` 挂 `cache/spice-tools/utm-guest-tools.iso` 看里面文件
- **R2 (PR-2)**: WebDAV-over-spice-port 协议帧格式 / 握手序列与现有 vdagent 通道是否一致? 实测 phodav-mount 连上后第一个发什么包. 必要时抓包对照 UTM master 版本 (CLAUDE.md "参考实现 UTM")
- **R3 (PR-3)**: **路径 escape** 防护是否覆盖所有 case: `..` 相对路径 / 绝对路径 / symlink to /etc/passwd / Windows path style `..\..\` / 大小写折叠. PR-3 必须落 fuzz-style 测试
- **R4 (PR-4)**: 大文件 (1 GB+) 双向传输是否稳定, 吞吐 ≥ 50 MB/s (UTM 实测 WebDAV 上限约 80 MB/s on macOS host, 比 9p 慢但比 QGA 快 10x)
- **R5 (PR-4)**: 加密 VM (config.yaml.enc) 改 sharedFolders 走 EncryptedConfigIO.save 路径必须验证 (CLAUDE.md "加密 VM 改 config" 历史教训, 必须 grep BundleIO.save 全树)

### P1 应该验证

- **R6**: Win guest 启动后 phodav-mount 服务起多久能挂到? (~5-15s, 与 vdagent 服务起得快慢有关). dialog "已挂载" 状态需轮询确认
- **R7**: VM crash / kill 后 unix socket 残留 cleanup
- **R8**: 多 VM 同时跑共享目录, host CPU/mem 占用 (每 VM 一个 SpiceWebdavServer actor, 不共享)
- **R9**: host 路径包含**空格 / 中文 / emoji** 的 WebDAV URL 编码 (RFC 3986 percent-encode)
- **R10**: read-only 模式下 Win guest 在文件资源管理器内右键 "新建文件" 报什么错? 友好程度

### 已知坑 (写入用户文档)

- **WebDAV 不支持文件锁 lockfile 协议** (我们不实现 LOCK/UNLOCK 动词). 多端同时写同一文件 → last-write-wins, 无冲突检测
- **WebDAV 性能不如 virtiofs**: 50-80 MB/s 上限, 千文件 `ls` 慢 (PROPFIND depth-1 一次往返). 适合代码同步, 不适合大文件库 (照片库 / 视频)
- **inotify / FSEvents 不打通**: guest 端 IDE 看不到 host 端文件改动事件 (需手动刷新). WebDAV 协议本身无此能力
- **mmap 不支持**: 同 9p, 在 WebDAV 上跑 sqlite / git internal mmap 会回退到 read mode 或报错

## PR 拆解

| PR | 时间盒 | 范围 | 验收 |
|---|---|---|---|
| **PR-0** | 0.5 天 | **R1 调研**: 挂 UTM Guest Tools ISO 验证 phodav-mount.exe 存在性 + ARM64 兼容. 若缺, 加"build phodav-mount win-arm64"子提案. 抓包 phodav-mount ↔ UTM-stock spice-server 第一握手帧, 反推协议 | 报告 phodav-mount 是否齐全; 若缺, 列出补 build 方案 |
| **PR-1** | 0.5 天 | `VMConfig.sharedFolders` schema + Codable 缺省 + EncryptedConfigIO save 适配. 加 `hvm-cli shared-folder add/list/remove <vm>` 子命令 (无 mount, 仅 config) | `make build` + 加密/明文 VM 加共享目录 `hvm-cli config <vm>` 看到字段; 老 yaml 无字段解码无错 |
| **PR-2** | 2 天 | `SpiceWebdavServer` actor 骨架: listen unix socket, 接 spice port 帧协议, 实现 `OPTIONS / PROPFIND / GET`. 单 root, read-only. 加 `hvm-dbg webdav-serve --root <path> --socket <sock>` 子命令独立测 | `hvm-dbg webdav-serve` 起 + 另起 phodav-mount 客户端 (或 curl WebDAV mode) → `OPTIONS` 拿 capabilities, `PROPFIND` 列 root 内容, `GET` 下文件 |
| **PR-3** | 1.5 天 | PR-2 之上加 `PUT / DELETE / MKCOL / MOVE / COPY` (RW 模式), 路径 escape 防护 + fuzz 测试, 多 root 支持. read-only 模式拒写返 403 | `hvm-dbg webdav-serve --rw` + curl 上传文件 / mkdir / rename, host 端实时可见; fuzz 路径 `..` / abs / symlink 全部拒绝 |
| **PR-4** | 1 天 | `QemuArgsBuilder` 加 `webdavSocketPath` + `-chardev/-device` argv. `QemuHostEntry` 起 `SpiceWebdavServer` 与 QEMU 同生命周期. 真机 Win11 ARM QEMU VM 端到端 | 启 Win11 VM, guest 内文件资源管理器看到 `\\spice-webdav`, 列出 host 端 `code/` 目录, 双向读写正常 |
| **PR-5** | 1 天 | GUI: SharedFolderDialog (HVMModal) + 详情页 Sharing 区共享目录卡片 + [+ 共享目录] + [✕] + RW toggle. probe id 全套 | `hvm-dbg gui` 自动化: 点 add → 选目录 → 保存 → config 落地 → 重启 VM → guest 内可见 |
| **PR-6** | 0.5 天 | Linux QEMU VM 端到端验证: spice-webdavd 包是否随 spice-vdagent 一起装? 若无, 文档教用户 `apt install spice-webdavd`. GVFS 自动挂载验证 | Ubuntu 24.04 ARM QEMU VM 启动后 `gvfs-mount -l` 看到 SPICE 共享, `~/.gvfs/SPICE shared folder/code` 可读写 |
| **PR-7** | 0.5 天 | 文档回写 v1/SHARING.md (新建) + CLAUDE.md "共享目录约束" + WebDAV 已知坑写进 v1 + README.md 提一句 | 文档已落, 设计稿头改 `代码已合入` |

总计 **7.5 天 (≈ 1.5 周)**, 若 PR-0 发现 phodav-mount 缺补 build, +2-3 天 → 2 周.

**每 PR 必须**: `make build` + `make install` + smoke 加密 VM (确认 sharedFolders 走 EncryptedConfigIO 不破)

## 未来工作 (不在本提案)

- **`docs/v3/VZ_SHARED_DIRECTORY.md`** (单独提案): VZ 后端 `VZSharedDirectory + VZVirtioFileSystemDeviceConfiguration`, macOS 13+ guest 原生支持, Linux VZ 同步走 virtiofs. 估时 1 周
- 多目录共享 UI (schema 已留, GUI 加号按钮可加多条)
- 拖拽传文件 (相对独立)
- WebDAV LOCK/UNLOCK (协作场景, 暂不需要)
- 9p 备选 (本提案备而不用; 若用户实测 WebDAV 太慢, 可加 Linux 9p alt 路径作 fallback)

## 未决事项 (Decisions)

| ID | 决策项 | 默认 | 决策时机 |
|---|---|---|---|
| **D1** | guest 内挂载点是否允许用户改? | **固定** (Win: \\spice-webdav, Linux: GVFS 默认), 减决策 | 永久 |
| **D2** | host 路径**符号链接**: 跟随 vs 拒绝? | **拒绝** (security, 防 guest escape; WebDAV server 路径规范化时 `realpath` 后比对 root, 不在范围内一律 403) | PR-3 |
| **D3** | guest 内文件 owner / mode: WebDAV 协议无 uid 概念, host fs 上文件是 HVM 主进程 uid | 接受 (WebDAV 限制) | 永久 |
| **D4** | 加密 VM 允许共享目录? (host 端目录明文与 VM 加密语义冲突) | **允许 + 弹一次警告对话框** "host 端目录不加密, 写入 guest 共享目录的数据在 host 上是明文". 用户可勾"不再提示" | PR-5 |
| **D5** | VM **running 中**改 sharedFolders 配置: 提示重启 vs 阻塞编辑? | **提示重启** (chardev 不支持热加, 不阻塞编辑但保存后弹 toast "下次启动生效") | PR-5 |
| **D6** | 同一 host 目录被多个 VM 共享: 锁 vs 警告 vs 放任? | **放任** (用户自负数据竞争) | 永久 |
| **D7** | hvm-cli shared-folder add 是否支持相对路径? | **否, 强制绝对路径** | PR-1 |
| **D8** | WebDAV server 失败 (socket 起不来 / 协议错): 阻塞 VM 启动 vs 警告启动? | **警告启动** (共享目录不是 VM 必须功能, sharedFolders 不可用不该挡住 VM 跑) | PR-4 |
| **D9** | guest 端挂载状态 (已挂载 / 未挂载) 怎么显示? UI"已挂载"通过什么数据源判定? | **轮询 WebDAV server actor 内部连接计数** (guest phodav-mount 连上后 server 有 active connection). 简单准确, 不打 QGA | PR-5 |
| **D10** | UTM Guest Tools ISO 缺 phodav-mount 时, 选项: (a) 自家 build win-arm64 (b) 文档教用户从 spice-space 下载 (无 ARM 版本) (c) 推后该 PR | (a) 自家 build (UTM 已开源 phodav 自家 fork) | PR-0 调研后定 |
| **D11** | Linux guest 缺 spice-webdavd 包时: 文档教 apt vs 自动检测装? | **文档教用户装** (我们不动 guest 包管理) | PR-6 |
| **D12** | WebDAV "已挂载" 状态判定 fail-open vs fail-closed? guest 没装客户端时 dialog 显灰 "未挂载" 容易让人以为坏了 | **fail-open + 文案** "等待 guest 内客户端连接... (需装 UTM Guest Tools / spice-webdavd)" | PR-5 |
