# 共享 (剪贴板 / 文件传输 / 共享目录)

> 现状: **代码已合入 2026-05-24** (PR-1 ~ PR-7 SPICE WebDAV 共享目录) — 设计稿 [../v3/SHARED_FOLDER.md](../v3/SHARED_FOLDER.md)

## 三层共享通路

HVM 在 host ↔ guest 之间提供三条独立通路, **互不依赖**:

| 通路 | 用途 | 协议 | 后端 | guest 依赖 | 触发 |
|---|---|---|---|---|---|
| **剪贴板** | UTF-8 文本 | spice-vdagent (virtio-serial `com.redhat.spice.0`) | QEMU only | spice-vdagent 服务 (UTM Guest Tools 自动装) | 自动, `clipboardSharingEnabled` 配置开关 |
| **文件传输** | 单文件 push/pull, 1-10 MB/s, 100 MiB 软警告 | qemu-guest-agent `guest-file-*` (virtio-serial `org.qemu.guest_agent.0`) | QEMU only | qemu-ga.exe (UTM Guest Tools 自动装) | UI 按钮 / `hvm-dbg file push/pull` |
| **共享目录** | 持久 host 目录, host ↔ guest 双向访问 | SPICE WebDAV (virtio-serial `org.spice-space.webdav.0`) | QEMU only | spice-webdavd 服务 (Win: UTM Guest Tools 自动装; Linux: `apt install spice-webdavd`) | `hvm-cli shared-folder` / GUI 详情页 Sharing 区 |

VZ 后端推后单独提案 (`docs/v3/VZ_SHARED_DIRECTORY.md`), 暂走 NAT 自给.

## 共享目录: SPICE WebDAV 通路

### 架构

```
guest 内 (Windows / Linux)
  ┌──────────────────────────────┐
  │ User: 文件资源管理器 / nautilus│
  │   ↓ \\localhost\dav (Win)     │
  │   ↓ davs://localhost/ (Linux) │
  │ spice-webdavd  (local HTTP proxy)
  │   ↓ /dev/virtio-ports/org.spice-space.webdav.0
  └─────────┬────────────────────┘
            │  mux frames: [client_id u64_le][size u16_le][HTTP bytes]
            ▼
host (HVM 主进程)
  ┌──────────────────────────────┐
  │ SpiceWebdavServer            │
  │   ↑ Swift, 跟 vdagent 同款 single-client     │
  │   ↑ unix socket: HVMPaths.webdavSocketPath   │
  │ QEMU chardev (server=on)     │
  │   ↑ -chardev socket,id=webdav,path=...       │
  │   ↑ -device virtserialport,name=org.spice-space.webdav.0 │
  └──────────────────────────────┘
            │
            ▼
   host 文件系统 (config.sharedFolders[].hostPath)
```

**关键差异 vs UTM**: UTM 走 `--enable-spice` 把 spice-server 编进 QEMU + spice-gtk client 处理 webdav. HVM 当前 QEMU `--disable-spice`, **WebDAV server 用 Swift 原生实现**, 直接接 QEMU 的虚拟串口 chardev unix socket; 不依赖 spice-server lib / spice-gtk / 重 build QEMU.

### Wire 协议 (mux + HTTP)

每个 mux frame:

```
+---------------+---------------+---------------+
| client_id 8B  | size 2B       | payload N B   |
| (uint64 LE)   | (uint16 LE)   | (0 ≤ N ≤ 65535)|
+---------------+---------------+---------------+
```

- `client_id` 由 guest 内 spice-webdavd 分配, 用来 multiplex 多个并发 HTTP 连接
- `size = 0` 表示该 client_id 客户端主动关连接
- HTTP 请求 / 响应可跨多 frame (按字节拼接还原)
- 65535 是单 frame payload 上限, 大文件 GET / PUT 自动切多帧

实现: [`MuxFrame`](../../app/Sources/HVMQemu/SpiceWebdavServer.swift) struct.

### HTTP / WebDAV 动词

[`WebDavHandler`](../../app/Sources/HVMQemu/SpiceWebdavServer.swift) 实现:

| 动词 | 行为 | RW only? |
|---|---|---|
| OPTIONS | 返 `DAV: 1, 2` + `Allow:` | 否 |
| PROPFIND | XML 列文件 / 目录 (Depth: 0/1 支持; infinity 拒) | 否 |
| GET / HEAD | 读文件 (整文件 buffer; 大文件由 mux 自动切帧) | 否 |
| PUT | 写文件 (覆盖; atomic) | **是** (read-only root → 403) |
| DELETE | 删文件 / 空目录 | **是** |
| MKCOL | 创建目录 | **是** |
| MOVE | 移动 (Destination header; Overwrite: T/F) | **是** |
| COPY | 复制 (同上) | **是** |
| PROPPATCH | 接受 + 忽略 (兼容 spice-webdavd 客户端) | — |
| LOCK / UNLOCK | 501 Not Implemented | — |

### 路径安全

`WebDavHandler.toHostURL` + `composeDest`:

1. **拒 `..` / `.` / 空 path 段**: 字符串级直接 reject (返 nil)
2. **realpath 校验**: `URL.resolvingSymlinksInPath()` 后再比对 `root.url.standardizedFileURL.path`, 必须 `==` root 或 `hasPrefix(root + "/")`
3. **空 sub 段**: PUT/DELETE 到 root 本身一律 403
4. **大小写敏感**: macOS APFS 默认 case-insensitive, 但比对走 standardizedFileURL.path 字节比, **不**做大小写折叠 (跟 guest 一致)

[`hvm-dbg webdav-test`](../../app/Sources/hvm-dbg/Commands/WebdavCommand.swift) 内 fuzz 验证: `..` / 绝对路径 / Win-style `..\\` 都被拒返 ≥ 400.

### 生命周期

`QemuHostEntry` 启 VM 时:

1. `HVMPaths.webdavSocketPath(for: vmId)` 计算 socket 路径
2. `config.sharedFolders` 非空 → 注入 `-chardev socket,id=webdav,...` + `-device virtserialport,name=org.spice-space.webdav.0` argv
3. QEMU 启动, bind socket
4. `SpiceWebdavServer.connect()`: 后台 retry 30s 等 socket 出现, 然后 `connect()` 进去
5. 读取 mux frames, 派给 `WebDavHandler` 处理
6. 响应切 mux frames 写回
7. VM stop → socket 自动 close → SpiceWebdavServer.readThread EOF → cleanup

**失败 fail-soft**: server 起不来 / connect 失败只 log warn, 不阻塞 VM 启动. config.sharedFolders 不应让 VM 跑不起来.

### CLI

```bash
hvm-cli shared-folder add <vm> <host-path> [--name X] [--rw] [--format json]
hvm-cli shared-folder list <vm> [--format json]
hvm-cli shared-folder remove <vm> <name>
```

- `<vm>`: VM 名称或 bundle 路径; 走 `EncryptedConfigEditor` 自动处理加密 / 明文 config
- `<host-path>`: **强制绝对路径**, 必须是已存在的目录
- `--name`: 友好名 (`[a-zA-Z0-9_-]{1,32}`); 不给 → 取 host 目录 basename + sanitize
- `--rw`: 默认 read-only, 加这个允许写入
- 单 VM 内 name 唯一; 重名 add 报错
- VM 必须 `engine=qemu`; vz 后端拒绝
- VM running 时 add/remove 报 bundle.busy (chardev 不支持热挂)

### GUI

详情页 **Sharing** 区, 在剪贴板 / 文件传输按钮下方:

```
共享目录 (SPICE WebDAV)
  guitest  [只读]  /Users/me/code               [移除]
[+ 共享目录…]
走 SPICE WebDAV. Win guest: \\localhost\dav 自动可见; Linux: GVFS davs://localhost
```

- `[+ 共享目录…]` 弹 NSOpenPanel 选目录 → 自动按 basename 派生 name → 默认 read-only 落盘
- `[移除]` 按 name 删
- VM 必须 stopped + engine=qemu, 否则两按钮 disabled
- probe id: `detail.sharing.sharedFolder.button.add` / `detail.sharing.sharedFolder.button.remove.<idx>`

### guest 侧安装

**Windows**: UTM Guest Tools NSIS installer 自动跑 `msiexec /i spice-webdavd-arm64-latest.msi /qn`, 装完 `spicewebdavd` 作系统服务自启. 用户在文件资源管理器看到 `\\localhost\dav` 网络位置.

**Linux** (Ubuntu / Debian): 用户需手动 `sudo apt install spice-webdavd`, 装完 systemd `spice-webdavd.service` 自启. GVFS 自动挂载到 `~/.gvfs/SPICE shared folder/<name>` 或 `/run/user/$UID/gvfs/`. 老版 GNOME / 非 GVFS DE 需 `mount.davfs davs://localhost/<name> /mnt/foo`.

**OpenWrt / Alpine / busybox 镜像**: 不接 (spice-webdavd 不在轻量发行版仓库内).

### 已知限制 (从设计稿继承)

- **WebDAV 不支持文件锁** (LOCK/UNLOCK 返 501); 多端并发写同一文件 → last-write-wins
- **性能 < virtiofs**: 50-80 MB/s 上限 (HTTP 包装 + mux frame 开销). 适合代码同步, 不适合大文件库
- **无 inotify / FSEvents 转发**: guest IDE 看不到 host 端文件改动事件, 需手动刷新
- **mmap 不可用** (跟 9p / NFS / SMB 同款 网络挂载限制), 在 WebDAV 上跑 sqlite / git mmap 索引会回退到 read mode 或报错

### 调试

- `hvm-dbg webdav-test` — 离线跑 mux frame codec + HTTP 解析 + WebDAV 动词单元测 (44 case)
- `hvm-dbg webdav-serve --listen --socket /tmp/wd.sock --root testshare=/tmp/data:rw` — 起 server 监听 socket, 用 Python / curl / phodav-mount 客户端测协议
- 启动后 host log: `HVMHost(qemu): SPICE WebDAV server 已启动 (N roots: name[mode],...)`

## 文件传输 (单文件 QGA)

设计稿 [../v3/FILE_COPY.md](../v3/FILE_COPY.md). 短期补丁通路, 长期由共享目录取代大多数场景.

## 剪贴板共享 (vdagent)

实现 [`VdagentClient`](../../app/Sources/HVMDisplayQemu/VdagentClient.swift). 走 spice-vdagent 协议 over virtio-serial `com.redhat.spice.0`. UTF-8 文本双向. `config.clipboardSharingEnabled` 字段开关, 运行中 IPC 即时生效.
