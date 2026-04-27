# HVM-QEMU 显示嵌入协议 (HDP)

> **HVM Display Protocol** · 当前版本 **1.0.0** · 最后更新 2026-04-27

QEMU 把 guest framebuffer 嵌入 HVM 主窗口右栏所走的 IPC 协议。host (HVM Swift app) 与 QEMU 子进程之间通过 AF_UNIX SOCK_STREAM 通信, framebuffer 像素经 POSIX shm + SCM_RIGHTS 零拷贝传递。

本协议仅服务 HVM 项目, 不是开放标准。设计上侧重**简单可靠** + **严格向后兼容**, 不追求 SPICE/RDP 那种全功能 (剪贴板/USB/音频/录像不在范围)。

---

## 1. 进程模型

```
┌─────────────────────────┐                ┌─────────────────────────┐
│ HVM.app (host)          │                │ qemu-system-aarch64     │
│ HVMDisplayQemu.framework│  AF_UNIX +     │ ui/iosurface backend    │
│   - DisplayChannel      │  SOCK_STREAM   │   - listener pthread    │
│   - FramebufferRenderer │ ◄────────────► │   - DCL ops             │
│   - InputForwarder      │  SCM_RIGHTS fd │   - shm publisher       │
│   (Metal)               │                │                         │
└─────────────────────────┘                └─────────────────────────┘
       ▲                                           ▲
       │ mmap(shm fd)                              │ shm_open + ftruncate
       │ MTLBuffer(bytesNoCopy:)                   │ + dpy_gfx_switch
       │                                           │
       └─────────── /qemu-hvm-<uuid8>-<seq> ───────┘
                  POSIX shm (BGRA8 framebuffer)
```

- **服务端**: QEMU 进程, `bind` AF_UNIX path 后 `listen`, 接收 host 的 `connect`
- **客户端**: HVM host 进程
- 单连接 (`accept` 一次, host 退出后 QEMU 重新进入 listen 状态)
- **键鼠**输入走独立的 QMP socket (`input-send-event` 命令), **不**走本协议
- **swtpm / vmnet / 串口**走各自独立 socket, **不**走本协议

socket 路径: `<bundle>/run/<vm-id>.iosurface.sock`, 由 host 创建目录, QEMU 使用绝对路径 bind.

---

## 2. 编码约定

- **字节序**: 一律 **little-endian**. Apple Silicon 与 x86 host 均为 LE, 无运行时转换
- **对齐**: 协议结构按 `__attribute__((packed))` 序列化, 不做 padding. 所有字段自然对齐到 4 字节内
- **整数**: 严格使用 `uint8_t / uint16_t / uint32_t / int16_t / int32_t / uint64_t`, 不使用 `int / long` 等平台相关类型
- **字符串**: 1.0.0 协议**不含**字符串字段. 后续若需要, 走 length-prefix UTF-8 (`u32 len` + bytes), 不带 nul 终结符

---

## 3. 消息头

固定 **8 字节**, 所有消息共用:

| 偏移 | 长度 | 字段 | 说明 |
|---|---|---|---|
| 0 | 2 | `type` | 16-bit 消息类型 ID, little-endian |
| 2 | 2 | `flags` | 16-bit 标志位, 见 §4 |
| 4 | 4 | `payload_len` | 32-bit payload 字节数 (不含本头), little-endian |

后续紧跟 `payload_len` 字节的 payload (可为 0). 若 `flags` 含 `HAS_FD`, 该消息通过 `sendmsg(2)` 携带一个 SCM_RIGHTS fd, 接收方必须用 `recvmsg(2)` 读取.

接收伪代码:
```c
read_exact(sock, &hdr, 8);
recv_payload_with_optional_fd(sock, hdr.payload_len, hdr.flags & HAS_FD, &fd_out);
```

---

## 4. flags 字段

| Bit | 名称 | 含义 |
|---|---|---|
| 0 | `HVM_DISP_FLAG_HAS_FD` | 本消息通过 SCM_RIGHTS 携带一个 fd, 接收方必须用 recvmsg |
| 1 | `HVM_DISP_FLAG_URGENT` | 优先级提示 — 收方可考虑插队处理 (例如 cursor 更新) |
| 2-15 | (保留) | **接收方必须 ignore 不识别的 bit, 不报错不断连** |

---

## 5. 协议版本号与协商

### 5.1 版本号编码

单 `uint32_t`, 三段语义化版本:
```
proto_version = (major << 16) | (minor << 8) | patch
```

当前: `1.0.0` → `0x00010000`.

### 5.2 协商流程

连接建立后, **双方各自先发 HELLO**, 互不阻塞:

```
host                                  QEMU
  │  ── HELLO(1.0.0, caps=...)──────►  │
  │  ◄────── HELLO(1.0.0, caps=...) ── │
  │                                    │
  │   双方各自计算:                    │
  │     negotiated_major = self.major  │  (必须等于 peer.major)
  │     negotiated_minor = min(self,peer).minor
  │     effective_caps   = self.caps & peer.caps
```

### 5.3 兼容性规则

| 变更 | major | minor | patch | 行为 |
|---|---|---|---|---|
| 不兼容修改 (改字段语义/复用 ID) | bump | reset | reset | 双方 major 必须相等; 不等则 GOODBYE(VERSION_MISMATCH) + 断 |
| 加新可选消息 / 加 capability_flags bit | – | bump | reset | 高 minor 端**不发**对端不识别的可选消息 |
| Bug 修复, 不改语义 | – | – | bump | 完全兼容, 无需协商行为 |

### 5.4 强制的容错义务

实现必须做到以下几点, 否则不算合规:

1. **未知 `type` 容错**: 收到不识别的消息类型, **严格按 `payload_len` 跳过**, 不报错不断连
2. **未识别 `flags` bit 容错**: ignore, 不报错
3. **payload tail extension**: 已有消息尾部多出未识别字节时, **截断到已知字段, skip 多余字节**, 不报错
4. **未识别 capability_flags bit**: ignore, 视为对端不支持该 capability
5. **以上 4 条违反**会破坏向后兼容, 等同协议 bug

---

## 6. capability_flags

HELLO 携带 `uint32_t capability_flags`, 用于声明可选 feature. **bit 永不复用**, 删除 feature 只能标 deprecated.

| Bit | 名称 | 1.0.0 状态 | 含义 |
|---|---|---|---|
| 0 | `CAP_CURSOR_BGRA` | mandatory | 硬件光标 BGRA 推送 (CURSOR_DEFINE) |
| 1 | `CAP_LED_STATE` | mandatory | guest LED 反向回传 |
| 2 | `CAP_VDAGENT_RESIZE` | optional | 动态分辨率 — guest 装 spice-vdagent 后才生效 |
| 3-31 | (保留) | – | 顺序占用, 不跳号 |

`mandatory` 表示 1.0.0 双端必报告该 cap; `optional` 取决于 guest 内 agent 安装情况.

---

## 7. 消息类型表

16-bit `type` 字段按段分配, 段内顺序占用:

| 段 | 用途 |
|---|---|
| `0x00xx` | 控制 / 帧基础 |
| `0x001x` | cursor |
| `0x002x` | 反向回传 (Q→H 状态通知) |
| `0x008x` | host→Q 命令 |
| `0x00FF` | GOODBYE |
| `0x01xx` | (保留) 帧高级 — GPU 加速 / 多 scanout |
| `0x02xx` | (保留) 输入扩展 |
| `0x03xx` | (保留) 音频 |
| `0xFFxx` | (保留) 厂商私有, 不进入标准协议 |

### 1.0.0 基础消息集

| ID | 名称 | 方向 | flags | 说明 |
|---|---|---|---|---|
| `0x0001` | HELLO | 双向 | – | 协议握手 + 版本 + capabilities |
| `0x0002` | SURFACE_NEW | Q→H | `HAS_FD` | 新 framebuffer (分辨率切换) |
| `0x0003` | SURFACE_DAMAGE | Q→H | – | 脏区 hint |
| `0x0010` | CURSOR_DEFINE | Q→H | – | 硬件光标位图 |
| `0x0011` | CURSOR_POS | Q→H | (`URGENT`) | 光标位置 |
| `0x0020` | LED_STATE | Q→H | – | guest LED (CapsLock/NumLock/ScrollLock) |
| `0x0080` | RESIZE_REQUEST | H→Q | – | host 请求 guest 调分辨率 |
| `0x00FF` | GOODBYE | 双向 | – | 关闭通知 + reason |

---

## 8. 消息 payload 定义

### 8.1 HELLO (`0x0001`)

```
+--------+--------+
| u32    | u32    |
| proto  | caps   |
| ver    | flags  |
+--------+--------+
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `proto_version` | u32 | 见 §5.1 |
| `capability_flags` | u32 | 见 §6 |

**协商规则**见 §5.2.

---

### 8.2 SURFACE_NEW (`0x0002`, `flags |= HAS_FD`)

QEMU 端通过 `dpy_gfx_switch` 触发 (分辨率/格式变化). 同步携带新创建的 shm fd.

```
+--------+--------+--------+--------+----------------+
| u32    | u32    | u32    | u32    | u64            |
| width  | height | stride | format | shm_size       |
+--------+--------+--------+--------+----------------+
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `width` | u32 | 像素宽 |
| `height` | u32 | 像素高 |
| `stride` | u32 | 字节每行 (可能 > width × bpp 因对齐) |
| `format` | u32 | 像素格式枚举, 1.0.0 仅 `0x01 = BGRA8` |
| `shm_size` | u64 | mmap 长度 (字节), 通常 = `stride * height` |

**fd**: 通过 SCM_RIGHTS 一同传递. host 收到后 `mmap(NULL, shm_size, PROT_READ, MAP_SHARED, fd, 0)` 拿到只读映射, **必须立即 close fd** (mmap 已持有引用), 然后用 `MTLBuffer(bytesNoCopy:length:options:.storageModeShared, deallocator:)` 包装, 创建 BGRA `MTLTexture`.

收到新 SURFACE_NEW 时, host 必须先释放老 buffer/texture, 再 mmap 新 fd.

---

### 8.3 SURFACE_DAMAGE (`0x0003`)

QEMU `dpy_gfx_update` 触发, 提示哪一块区域有变化. host 可据此局部 invalidate, 但当前 1.0.0 实现允许整屏重绘 (Metal fullscreen shader 廉价).

```
+--------+--------+--------+--------+
| u32    | u32    | u32    | u32    |
| x      | y      | w      | h      |
+--------+--------+--------+--------+
```

字段全为像素坐标. 必须满足 `x + w ≤ width && y + h ≤ height`, 否则 host 应 skip 该消息 (defensive).

---

### 8.4 CURSOR_DEFINE (`0x0010`)

QEMU `dpy_cursor_define` 触发. payload 头后紧跟 `width × height × 4` 字节 BGRA 像素 (premultiplied alpha).

```
+--------+--------+--------+--------+----------------------+
| u16    | u16    | i16    | i16    | u8 pixels[w*h*4]     |
| width  | height | hot_x  | hot_y  | (BGRA premultiplied) |
+--------+--------+--------+--------+----------------------+
```

`width × height` 上限 1.0.0 规定 ≤ 256 × 256 (覆盖常见硬件光标尺寸). 超出时 QEMU 应**回退为 software cursor**, 不发本消息.

---

### 8.5 CURSOR_POS (`0x0011`, 可带 `URGENT`)

```
+--------+--------+--------+
| i32    | i32    | u32    |
| x      | y      | visible|
+--------+--------+--------+
```

| 字段 | 说明 |
|---|---|
| `x`, `y` | guest 坐标系绝对像素位置. 可负 (光标暂离开屏幕外) |
| `visible` | `0` 隐藏, `1` 显示 |

---

### 8.6 LED_STATE (`0x0020`)

```
+--------+--------+--------+
| u32    | u32    | u32    |
| caps   | num    | scroll |
+--------+--------+--------+
```

每字段 `0` = off, `1` = on. host 据此同步 macOS 端 CapsLock 状态, 避免 host/guest 不一致 (例: 用户在 host 上按 Caps 但 guest 没收到).

---

### 8.7 RESIZE_REQUEST (`0x0080`, host → QEMU)

host 主窗口 resize 时发送. QEMU 收到后调用 `dpy_set_ui_info` 触发 EDID 更新, guest 内 spice-vdagent 监听 EDID 变化自动改分辨率 (要求 `CAP_VDAGENT_RESIZE`).

```
+--------+--------+
| u32    | u32    |
| width  | height |
+--------+--------+
```

最小 `640 × 480`, 最大 `7680 × 4320` (8K). 超界 QEMU 应 ignore.

未协商 `CAP_VDAGENT_RESIZE` 时, host **不应**发送本消息 (发了 QEMU 也只能 ignore).

---

### 8.8 GOODBYE (`0x00FF`)

任一方主动断连前发送.

```
+--------+
| u32    |
| reason |
+--------+
```

| reason | 名称 | 含义 |
|---|---|---|
| `0` | `NORMAL` | 主动正常关闭 (vm 关机 / host 退出) |
| `1` | `VERSION_MISMATCH` | major 版本不匹配 |
| `2` | `PROTOCOL_ERROR` | 收到非法消息 / payload 越界 |
| `3` | `INTERNAL_ERROR` | 实现内部异常 |
| `4-` | (保留) | 后续扩展, 不识别的值视同 `INTERNAL_ERROR` |

发送方在写完 GOODBYE 后应 `shutdown(WR)`, 等对方 EOF 后 `close`.

---

## 9. 像素格式 / shm 管理

### 9.1 像素格式

1.0.0 仅支持 `HVM_DISP_PIXFMT_BGRA8 = 0x01`:
- 32-bit per pixel, byte order: B G R A (低位在前, little-endian)
- 等价 Metal `MTLPixelFormat.bgra8Unorm`
- guest 输出其他格式时, QEMU 内部 `pixman_image_composite` 转换到 BGRA8 shm

### 9.2 shm 命名

`/qemu-hvm-<uuid8>-<seq>` (≤ 31 字符 macOS 限制).
- `<uuid8>` = VM UUID 前 8 字符
- `<seq>` = 单调递增 u16 (每次 SURFACE_NEW 自增, 防同 VM 重连冲突)

### 9.3 生命周期

QEMU 端:
1. `shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600)` → fd
2. `ftruncate(fd, size)`
3. `mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)` → guest framebuffer 写这里
4. **立即** `shm_unlink(name)` — name 表删除, fd 仍可用; 进程 crash 时 OS 自动回收, 不留残留
5. SCM_RIGHTS 把 fd 发给 host
6. host close 自己的 fd; QEMU 端在切下一个 SURFACE_NEW 或 vm shutdown 时 munmap + close

host 端:
1. `recvmsg` 拿到 fd
2. `mmap(NULL, shm_size, PROT_READ, MAP_SHARED, fd, 0)`
3. `close(fd)`
4. 用 mmap 指针构造 `MTLBuffer.bytesNoCopy`, deallocator 在 buffer 释放时 `munmap`

---

## 10. 流控

- 不做窗口控制. 1.0.0 信任 socket 缓冲 + QEMU `dpy_refresh` ~30Hz 自然限流
- 发送 `EAGAIN` 时:
  - SURFACE_DAMAGE 可 drop 老的, 合并到新一帧
  - SURFACE_NEW / CURSOR_DEFINE / CURSOR_POS / LED_STATE / GOODBYE **必送** (block 直到成功或断连)
- host 端读 loop 应在独立线程, 不阻塞 UI

---

## 11. 错误处理

- **任何协议违例** (header 解析失败 / payload_len 超限 / 字段越界) → 发 `GOODBYE(PROTOCOL_ERROR)` + 断连
- **fd 接收失败** (ancillary 数据错位 / fd 数量不为 1) → `PROTOCOL_ERROR`
- **mmap 失败** (host 端) → `INTERNAL_ERROR`
- 任何错误**不留残留 shm** — QEMU shm_unlink 已先于 send 执行, OS 自然回收
- SIGPIPE 双方都必须 `signal(SIGPIPE, SIG_IGN)` 或用 `MSG_NOSIGNAL` (macOS 上 `SO_NOSIGPIPE` socket option), 防 host 退出时 QEMU 被信号杀

---

## 12. C 头草稿

实现侧 `include/ui/hvm_display_proto.h`, 协议规范与代码同源.

```c
/*
 * HVM-QEMU display backend protocol (HDP) — version 1.0.0
 * AF_UNIX SOCK_STREAM transport, little-endian wire format.
 * Canonical spec: docs/QEMU_DISPLAY_PROTOCOL.md
 */
#ifndef HVM_DISPLAY_PROTO_H
#define HVM_DISPLAY_PROTO_H

#include <stdint.h>

/* ---- version ---- */
#define HVM_DISP_PROTO_MAJOR  1
#define HVM_DISP_PROTO_MINOR  0
#define HVM_DISP_PROTO_PATCH  0
#define HVM_DISP_PROTO_VERSION (((uint32_t)HVM_DISP_PROTO_MAJOR << 16) | \
                                ((uint32_t)HVM_DISP_PROTO_MINOR <<  8) | \
                                 (uint32_t)HVM_DISP_PROTO_PATCH)

/* ---- header (8 bytes, little-endian) ---- */
struct hvm_disp_hdr {
    uint16_t type;
    uint16_t flags;
    uint32_t payload_len;
} __attribute__((packed));

/* ---- flags bits ---- */
#define HVM_DISP_FLAG_HAS_FD   0x0001u
#define HVM_DISP_FLAG_URGENT   0x0002u

/* ---- capability_flags bits (HELLO payload) ---- */
#define HVM_DISP_CAP_CURSOR_BGRA      0x00000001u
#define HVM_DISP_CAP_LED_STATE        0x00000002u
#define HVM_DISP_CAP_VDAGENT_RESIZE   0x00000004u

/* ---- pixel formats (SURFACE_NEW.format) ---- */
#define HVM_DISP_PIXFMT_BGRA8  0x00000001u

/* ---- message type IDs ---- */
enum {
    HVM_DISP_MSG_HELLO          = 0x0001,
    HVM_DISP_MSG_SURFACE_NEW    = 0x0002,
    HVM_DISP_MSG_SURFACE_DAMAGE = 0x0003,
    HVM_DISP_MSG_CURSOR_DEFINE  = 0x0010,
    HVM_DISP_MSG_CURSOR_POS     = 0x0011,
    HVM_DISP_MSG_LED_STATE      = 0x0020,
    HVM_DISP_MSG_RESIZE_REQUEST = 0x0080,
    HVM_DISP_MSG_GOODBYE        = 0x00FF,
};

/* ---- payloads ---- */

struct hvm_disp_hello {
    uint32_t proto_version;
    uint32_t capability_flags;
} __attribute__((packed));

struct hvm_disp_surface_new {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t format;
    uint64_t shm_size;
} __attribute__((packed));

struct hvm_disp_surface_damage {
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
} __attribute__((packed));

/* CURSOR_DEFINE: header + (width*height*4) BGRA bytes */
struct hvm_disp_cursor_define {
    uint16_t width;
    uint16_t height;
    int16_t  hot_x;
    int16_t  hot_y;
    /* uint8_t pixels[width * height * 4]; */
} __attribute__((packed));

struct hvm_disp_cursor_pos {
    int32_t  x;
    int32_t  y;
    uint32_t visible;
} __attribute__((packed));

struct hvm_disp_led_state {
    uint32_t caps_lock;
    uint32_t num_lock;
    uint32_t scroll_lock;
} __attribute__((packed));

struct hvm_disp_resize_request {
    uint32_t width;
    uint32_t height;
} __attribute__((packed));

struct hvm_disp_goodbye {
    uint32_t reason;
} __attribute__((packed));

#define HVM_DISP_GOODBYE_NORMAL            0u
#define HVM_DISP_GOODBYE_VERSION_MISMATCH  1u
#define HVM_DISP_GOODBYE_PROTOCOL_ERROR    2u
#define HVM_DISP_GOODBYE_INTERNAL_ERROR    3u

#endif /* HVM_DISPLAY_PROTO_H */
```

> **同步规则**: 修改本头时**必须**同步本规范文档的对应章节, 并在 §13 追加变更条目. 反向同样, 不允许只改一边.

---

## 13. 协议变更登记

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-27 | 1.0.0 | 协议初版. 8 字节 header, BGRA8 + shm + SCM_RIGHTS 通路, capability_flags = `CURSOR_BGRA \| LED_STATE \| VDAGENT_RESIZE` |

> 后续每次修改必须追加, **不允许 in-place 改老条目**. major bump 时清晰列出不兼容点; minor bump 列出新增消息 / 新 capability bit; patch bump 列出 bug 修复.
