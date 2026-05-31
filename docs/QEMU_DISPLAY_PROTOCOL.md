# HDP — HVM QEMU 显示嵌入协议 (v1.0.0)

> 本文是 HDP 协议的 **canonical 规范**。
>
> 三处定义必须逐字同步, 任何一处单独改都会让 host 与 QEMU 二进制握手失配:
> - 本文档 (规范, 含 §13 版本历史)
> - Swift 端: `app/Sources/HVMDisplayQemu/HDPProtocol.swift`
> - C 端镜像头: `include/ui/hvm_display_proto.h` (随 `patches/qemu/0002-ui-iosurface-display-backend.patch` 落地)
>
> QEMU backend 实现: `ui/iosurface.m` (同 patch 0002)。

---

## 1. 协议定位

HDP (HVM Display Protocol) 是 HVM 主进程与包内 `qemu-system-aarch64` 之间传递 guest framebuffer 的私有协议。它由 **HVM patch 0002** 给 QEMU 新增的 `-display iosurface` backend 实现。

- **传输**: `AF_UNIX` + `SOCK_STREAM` (本地 unix domain socket, 不监听 TCP)
- **角色**: QEMU 端 `bind`/`listen` (server), HVM 主进程 `connect` (client)
- **像素零拷贝**: framebuffer 像素不走 socket 字节流, 而是经 **POSIX shm**(`shm_open` + `ftruncate` + `mmap`)放在共享内存里, 把 shm 的 fd 通过 `SCM_RIGHTS` ancillary message 传给 host; host 侧 `mmap` 同一物理页后直接拿 `MTLBuffer.bytesNoCopy` 建 Metal 纹理渲染, 全程零拷贝
- **socket 流上只走控制消息**: HELLO 握手 / SURFACE_NEW 元信息(宽高 / stride / shm 大小)/ damage 矩形 / 光标 / LED / host→QEMU 的 resize 请求 / GOODBYE
- **平台限定**: macOS-only backend。meson `iosurface` option `.require(host_os == 'darwin')`, 非 macOS 不编译。HVM 项目本来就 Apple Silicon only
- **字节序**: wire 上一律 **little-endian**。host 是 arm64/x86 都是 LE, 不需要 byteswap, 但 Swift 端显式按 LE 编解码不依赖 host 假设
- **结构体**: C 端所有 wire struct `__attribute__((packed))`, 无对齐填充

argv 形态(`app/Sources/HVMQemu/QemuArgsBuilder.swift`):

```
-display iosurface,socket=<path>
```

`<path>` = `HVMPaths.iosurfaceSocketPath(for:)` = `~/Library/Application Support/HVM/run/<uuid>.iosurface.sock`。未注入该 socket 时 argv 回退 `-display cocoa`(调试用, QEMU 自开独立 NSWindow)。

---

## 2. 版本号

| 字段 | 值 |
|------|----|
| major | 1 |
| minor | 0 |
| patch | 0 |

wire 上 HELLO 携带 `protoVersion: UInt32 = (major<<16) | (minor<<8) | patch` = `0x00010000`。

**兼容规则**: 只比对 **major** 段(`(version >> 16) & 0xFFFF`)。major 不一致 → 发 `GOODBYE(versionMismatch)` 后断连。minor/patch 差异向前兼容(未知消息按 §5.4 跳过)。

---

## 3. 消息头 (8 字节, little-endian)

```c
struct hvm_disp_hdr {
    uint16_t type;          // 消息类型, 见 §4
    uint16_t flags;         // header flags, 见 §3.1
    uint32_t payload_len;   // 后续 payload 字节数 (不含 header 本身)
} __attribute__((packed));
```

`payload_len` 上限两端都做 sanity guard: **16 MiB**(`16 * 1024 * 1024`)。超限直接断连。

### 3.1 header flags

| 位 | 名称 | 含义 |
|----|------|------|
| `0x0001` | `HAS_FD` | 本消息附带一个 `SCM_RIGHTS` fd, 接收方必须用 `recvmsg` |
| `0x0002` | `URGENT` | 投递优先级提示(可选), 收方可考虑插队 |

> 当前实现里 `SURFACE_NEW` 必带 `HAS_FD`; `CURSOR_POS` 带 `URGENT`。`flags` 的语义由消息类型决定, 接收方主要靠 type dispatch, 不强依赖 flag(host 侧 recvmsg 始终接收 cmsg, 不预读 flag)。

---

## 4. 消息类型 ID

| ID | 名称 | 方向 | payload |
|------|------|------|---------|
| `0x0001` | `HELLO` | 双向 | §5 |
| `0x0002` | `SURFACE_NEW` | QEMU → host | §6 (带 fd) |
| `0x0003` | `SURFACE_DAMAGE` | QEMU → host | §7 |
| `0x0010` | `CURSOR_DEFINE` | QEMU → host | §8 |
| `0x0011` | `CURSOR_POS` | QEMU → host | §9 |
| `0x0020` | `LED_STATE` | QEMU → host | §10 |
| `0x0080` | `RESIZE_REQUEST` | host → QEMU | §11 |
| `0x00FF` | `GOODBYE` | 双向 | §12 |

> 注: `LED_STATE` (0x0020) 已在协议常量中定义, host 与 QEMU 两端均有结构体; 但当前 QEMU backend (`ui/iosurface.m`) 未主动发 LED 通知, host 端 dispatch 有对应分支待用。以协议常量为准。

像素格式枚举(`SURFACE_NEW.format`):

| 值 | 名称 |
|----|------|
| `0x00000001` | `BGRA8` |

唯一支持格式 BGRA8。QEMU 端 `dpy_gfx_check_format` 只接受 `PIXMAN_x8r8g8b8` / `PIXMAN_a8r8g8b8`(LE host 上字节序即 BGRA), 与 wire 承诺一致。

---

## 5. HELLO (握手)

payload 8 字节:

```c
struct hvm_disp_hello {
    uint32_t proto_version;       // §2 的 0x00010000
    uint32_t capability_flags;    // §5.1
} __attribute__((packed));
```

### 5.1 capability flags

| 位 | 名称 | 含义 |
|----|------|------|
| `0x00000001` | `CURSOR_BGRA` | 硬件光标 BGRA payload 支持 |
| `0x00000002` | `LED_STATE` | guest LED 反向回传 |
| `0x00000004` | `VDAGENT_RESIZE` | 动态分辨率(vdagent virtio-serial 通道就绪) |

两端各自 advertise:
- QEMU host caps (`IOS_HOST_CAPS`) = 三者全开
- HVM host caps (`Capabilities.hostAdvertised`) = 三者全开

协商结果 = `peerCaps ∩ ourCaps`(交集)。

### 5.2 握手流程

1. QEMU `accept` 到 host 连接后 **主动先发 HELLO**(`send_hello`)
2. host `connect` 后也立刻发自己的 HELLO(`sendOurHello`), 然后同步收 peer HELLO(`receivePeerHello`)
3. 双方各自校验 peer major:
   - host: peer major ≠ 1 → 发 `GOODBYE(versionMismatch)` 断连, 抛 `versionMismatch`
   - QEMU: peer major ≠ 1 → 发 `GOODBYE(VERSION_MISMATCH)` 断连
4. 协商通过后 host 把 `negotiatedCaps` 通过 `Event.helloDone` 推给上层; QEMU 置 `hello_done = true`

> 规范允许任一侧先发 HELLO(实现里两边都主动发, 互不阻塞)。HELLO 不应带 fd; host 端收到 stray fd 会安全 close 不报错(向前兼容)。

### 5.3 握手后状态推送

QEMU 端收到 host HELLO 并置 `hello_done` 后, 立刻 `resend_current_surface` —— 把当前已存在的 framebuffer 通过 `SURFACE_NEW` 重发给刚接上的 client。这让 host **断线重连**后无需等下一帧切换就能拿到当前画面。

### 5.4 未知消息处理

收到未识别的 `type`: **跳过 payload, 保持连接不报错**(两端 dispatch 的 `default` 分支一致)。这是 minor/patch 向前兼容的基础。

---

## 6. SURFACE_NEW (新 framebuffer, 带 fd)

`header.flags` **必含** `HAS_FD`。payload 24 字节, 同一次 `sendmsg(2)` 附带 **恰好一个** `SCM_RIGHTS` fd(指向 framebuffer 的 shm 对象):

```c
struct hvm_disp_surface_new {
    uint32_t width;
    uint32_t height;
    uint32_t stride;      // 每行字节数, 可大于 width*4
    uint32_t format;      // §4 像素格式, 当前恒 BGRA8
    uint64_t shm_size;    // mmap 长度 (字节)
} __attribute__((packed));
```

### 6.1 stride 对齐约束 (重要)

QEMU 端把 shm 的 `stride` padding 到 **256 字节对齐**(`IOS_STRIDE_ALIGN = 256`, `align_up(width*4, 256)`), 不论源 surface 原始 stride。

原因: Apple Silicon M3+ 的 `MTLBuffer.makeTexture(bytesNoCopy:bytesPerRow:)` 要求 `bytesPerRow` 是 256 的倍数, 否则 abort。host 侧直接信任 `info.stride` 不自己推。源 surface 与目标 shm 的 stride 可能不同(目标被 padding), QEMU `gfx_switch`/`gfx_update` 按行 `memcpy` 而非整块拷。

host 端 `FramebufferRenderer` 接到 fd 后校验下界 `stride >= width*4 && stride % 16 == 0 && shm_size >= stride*height`(信任 256 对齐, 只验下界)。

### 6.2 shm 生命周期

QEMU 端 `create_shm`:
- 名字 `/qemu-hvm-<pid>-<seq>`(darwin shm name 限 31 字节, 此格式约 20 字节)
- `shm_open(O_RDWR|O_CREAT|O_EXCL, 0600)` 后**立即 `shm_unlink`** —— name table 条目删掉, fd 仍映射 OS 托管内存; host 或 QEMU 崩溃时 OS 自动回收
- `ftruncate` 到 `stride*height` + `mmap(MAP_SHARED)`
- 每次 `gfx_switch`(分辨率变 / surface 重建)`release_shm` 旧的再 `create_shm` 新的, 并发 `SURFACE_NEW`

host 端 fd 所有权约定(`DisplayChannel.SurfaceArrival` + `FramebufferRenderer`):
- fd 由 `DisplayChannel` 通过 `SCM_RIGHTS` 收下, 经 `Event.surfaceNew(SurfaceArrival)` 转交消费者
- 消费者**必须** `mmap` 后立即 `close(shmFD)`(mmap 已持内核引用); 不消费就泄漏 fd
- `MTLBuffer.makeBuffer(bytesNoCopy:deallocator:)` 包住 mmap 区, deallocator 在 GPU 释放最后引用时 `munmap`(持 buffer 引用即保活, 无需手动 munmap)

---

## 7. SURFACE_DAMAGE (脏矩形)

payload 16 字节, QEMU `gfx_update` 在每帧脏区拷进 shm 后发, 通知 host 哪块需重绘:

```c
struct hvm_disp_surface_damage {
    uint32_t x, y, w, h;
} __attribute__((packed));
```

像素已经在 shm 里(QEMU 按行 memcpy 进 padding 后的 dst stride), DAMAGE 只携带矩形坐标。

---

## 8. CURSOR_DEFINE (硬件光标位图)

payload = 8 字节头 + `width*height*4` BGRA 字节(premultiplied alpha)。规范上限 `width,height <= 256`:

```c
struct hvm_disp_cursor_define {
    uint16_t width;
    uint16_t height;
    int16_t  hot_x;       // 热点
    int16_t  hot_y;
    // uint8_t pixels[width * height * 4];  紧随其后
} __attribute__((packed));
```

QEMU 端宽或高为 0、或 > 256 直接不发。host 端 decode 时校验 `payload >= 8 + width*height*4`。

---

## 9. CURSOR_POS (光标位置)

payload 12 字节, `header.flags` 带 `URGENT`:

```c
struct hvm_disp_cursor_pos {
    int32_t  x, y;
    uint32_t visible;     // 0 = 隐藏, 1 = 可见
} __attribute__((packed));
```

---

## 10. LED_STATE (guest 键盘 LED 反向回传)

payload 12 字节:

```c
struct hvm_disp_led_state {
    uint32_t caps_lock;
    uint32_t num_lock;
    uint32_t scroll_lock;
} __attribute__((packed));
```

各字段 0/1 布尔。**协议已定义两端结构体**; 当前 QEMU backend 未主动产生 LED 通知, host dispatch 有对应分支待接。

---

## 11. RESIZE_REQUEST (host → QEMU 改分辨率)

唯一 host → QEMU 方向的消息。payload 8 字节:

```c
struct hvm_disp_resize_request {
    uint32_t width;
    uint32_t height;
} __attribute__((packed));
```

host 端在用户拖动 HVM 主窗口时发(`DisplayChannel.requestResize`)。host 端**不**检查 `negotiatedCaps` 就发(只检查 socket 已连接)—— 即便 QEMU backend 没 advertise `VDAGENT_RESIZE`, 仍能走到 `dpy_set_ui_info → vdagent` 通路; cap check 静默丢请求会让用户拖窗 guest 不改分辨率。

QEMU 端 `handle_message` 对 RESIZE_REQUEST 的处理:
1. **要求**协商出 `VDAGENT_RESIZE` cap, 否则丢弃
2. 尺寸边界: `[640×480, 7680×4320]`, 越界丢弃
3. 通过则 `dpy_set_ui_info(con, {width,height}, false)` —— 更新 EDID, vdagent 装好的 guest 自动改分辨率

---

## 12. GOODBYE (断连)

payload 4 字节:

```c
struct hvm_disp_goodbye {
    uint32_t reason;
} __attribute__((packed));
```

reason 码:

| 值 | 名称 |
|----|------|
| 0 | `NORMAL` |
| 1 | `VERSION_MISMATCH` |
| 2 | `PROTOCOL_ERROR` |
| 3 | `INTERNAL_ERROR` |

host 主动 `disconnect` 时发 `GOODBYE(reason)` 再 `close`(idempotent)。收到 GOODBYE → read loop 结束, 推 `Event.disconnected(reason:)`。网络错误断开时 reason 可能为 nil(没机会收 GOODBYE)。

---

## 13. host 侧接收路径

### 13.1 DisplayChannel (Swift)

`app/Sources/HVMDisplayQemu/DisplayChannel.swift` 是 host-side client:

1. `openSocket`: `socket(AF_UNIX, SOCK_STREAM)` + `connect` 到 QEMU 暴露的 socket path
2. HELLO 协商(§5.2): 同步发我方 HELLO → 收 peer HELLO → 校 major → 取 cap 交集
3. 起后台 `readLoop` thread, 循环 `recvHeader` → `recvPayload` → `dispatchMessage`, 通过 `AsyncStream<Event>` 把消息推给上层(`helloDone` / `surfaceNew` / `surfaceDamage` / `cursorDefine` / `cursorPos` / `ledState` / `disconnected`)
4. 发送侧(GOODBYE / RESIZE_REQUEST)走串行 `sendQueue`, `sendAll` 处理短写 + `EINTR` 重试

### 13.2 SCM_RIGHTS fd 接收: HVMScmRecv C 胶水层

`SCM_RIGHTS` 的 cmsg accessor 宏(`CMSG_FIRSTHDR` / `CMSG_DATA` / `CMSG_LEN` / `CMSG_NXTHDR`)在 Swift 里不可 import, 因此用一层 C 胶水 `app/Sources/HVMScmRecv/`:

- `include/HVMScmRecv.h` + `recv_fd.c` 暴露单函数:

  ```c
  ssize_t hvm_scm_recv_msg(int sock_fd, void *buf, size_t bufsize, int *out_fd);
  ```

- 内部一次 `recvmsg` 同时填 `buf`(字节)+ 提取首个 `SCM_RIGHTS` fd 到 `*out_fd`(无 fd 则 -1)
- 返回值镜像 `recv(2)`: `>0` 字节数 / `0` EOF / `-1` 错误
- **多 fd 视为协议违例**: 关掉所有 fd, 返回 -1 + `errno=EPROTO`

### 13.3 fd 必须在 header 阶段接收

QEMU 端用单次 `sendmsg(iov={hdr,payload}, cmsg={fd})` 把 header + payload + fd 一起发。cmsg 跟 `sendmsg` 调用绑定: 第一次 `recvmsg` 拿到部分字节时一并收到 cmsg, 之后再 recv 后续字节不再有 cmsg。

因此 host **必须**在 `recvHeader`(头 8 字节那次 recvmsg)阶段接 fd, 不能延到 `recvPayload`。`DisplayChannel.recvHeader` 把 `fdSink` 传给 `hvm_scm_recv_msg`, payload 阶段 `fdSink=nil`。

### 13.4 渲染 (零拷贝)

`app/Sources/HVMDisplayQemu/FramebufferRenderer.swift`:
1. `mmap(shmFD, PROT_READ|WRITE, MAP_SHARED)` 同一物理页, 成功后 `close(shmFD)`
2. `device.makeBuffer(bytesNoCopy: raw, deallocator: { munmap })` —— GPU 与 host 共享物理页
3. `buffer.makeTexture(descriptor:offset:0, bytesPerRow: stride)` —— Metal 纹理直接 view 自 mmap, 不再拷
4. 缩略图 encode 走独立 Data 副本(避免与 GPU 抢同一物理页 cache 引发卡顿)

---

## 14. ramfb + virtio-gpu 双路设备 (patch 0003, 概述)

HDP 是 **显示传输层**(QEMU console → host)。guest framebuffer 怎么进 QEMU console 是另一层, 由 `patches/qemu/0003-hw-display-hvm-gpu-ramfb-pci.patch` 的融合设备 `hvm-gpu-ramfb-pci` 处理(主要服务 Windows guest 装机 + 运行期动态分辨率)。

单 PCI 设备同时挂两个角色, 内部 dispatcher 按 `g->enable` 切:

- **boot 期 (`enable == 0`)**: 走 **ramfb** 路径。fw_cfg `etc/ramfb` 接口给 EDK2 GOP / `bootmgfw.efi` 用, framebuffer 在 `cpu_physical_memory_map` 出来的 guest RAM 区; `ramfb_display_update → dpy_gfx_replace_surface` 把 surface 推给 console。兼容 UEFI/装机界面。
- **OS 期 (`enable == 1`)**: guest virtio-gpu driver(Windows `viogpudo.sys` / Linux 内核 virtio-gpu)装好并发出第一条 `VIRTIO_GPU_CMD_SET_SCANOUT` 后, 走 **virtio-gpu** 路径, 由 virtio-gpu 命令处理函数自己 `dpy_gfx_update` 推动态尺寸 framebuffer 给**同一个** console。这是 dynamic resize 能力的来源。

dispatcher 不论走哪路, 最终都落到同一个 QEMU console, 再由 HDP `iosurface` backend 推给 host。

其它要点:
- **vendor/device id 复用 `0x1AF4/0x1050`**(Red Hat virtio-gpu), 让 `viogpudo.inf` 自动 match, 不改 guest driver; PCI class `DISPLAY_OTHER`。套版自 `hw/display/virtio-vga.c`(把 VGA 路径换成 ramfb)
- **reset 修复**: virtio-gpu reset 会对 scanout 调 `dpy_gfx_replace_surface(con, NULL)`, console 顶上变成内置 "Display output is not active." placeholder。`reset_hold` hook 末尾强制 `g->enable = 0` + `ramfb_resend_surface`, 下个 gfx_update tick 把 placeholder 换回真 ramfb, 否则装机界面卡 placeholder
- **`ramfb_resend_surface`**(新增公开 API): 从 cached fw_cfg config 重建 surface, 供上述 hook 调用

### 14.1 与 vdagent / EDID 的 ui_info 通路 (概述)

融合设备的 `hvm_ramfb_ui_info` **始终**把 `ui_info` 转给 virtio-gpu(`g->hw_ops->ui_info`), 即便 guest driver 还没起。这样当 host 经 §11 `RESIZE_REQUEST → dpy_set_ui_info` 更新尺寸 hint 时, virtio-gpu 的 `req_state` / EDID 立即被更新; driver 一起来就拿到 host 端尺寸 hint, vdagent 通路据此让 guest 自动 resize。

完整链路: 用户拖 HVM 窗口 → host `RESIZE_REQUEST` → QEMU `dpy_set_ui_info` → ui_info 转 virtio-gpu + 更新 EDID → guest vdagent / virtio-gpu driver 读到新尺寸 → guest 改分辨率 → 新 surface → HDP `SURFACE_NEW` 回推 host。

> 注: vdagent 自身走独立 virtio-serial 通道(`HVMDisplayQemu/VdagentClient.swift` 等, socket `<uuid>.vdagent.sock`), 与 HDP 是不同通路; 此处仅描述 HDP `RESIZE_REQUEST` 如何借 `dpy_set_ui_info` 触发 EDID/vdagent resize, 不展开 vdagent 协议本身。

---

## 15. 版本历史

| 版本 | 变更 |
|------|------|
| 1.0.0 | 起步版本。HELLO / SURFACE_NEW(shm+SCM_RIGHTS)/ SURFACE_DAMAGE / CURSOR_DEFINE / CURSOR_POS / LED_STATE / RESIZE_REQUEST / GOODBYE 全消息集; BGRA8 像素格式; 256B stride 对齐; cap: CURSOR_BGRA / LED_STATE / VDAGENT_RESIZE |

> 后续任何 wire 改动(新消息 / 新字段 / 新 cap)必须同步改三处文件并在本表追加条目。major 段递增 = 不兼容断连。
