// HVMIPC/Protocol.swift
// hvm-cli / hvm-dbg / HVMHost 共享的 JSON 协议定义.
//
// 协议版本: 用户可能从老 .app 启动 VMHost 又用新 hvm-cli 调用, 版本错位需检测.
//   - 客户端在 IPCRequest 填 protoVersion = IPCProtocol.version
//   - 服务端校验: nil (老客户端) 视作 legacy 接受; != current 返 ipc.protocol_mismatch
//   - 未知 op 由 handler 兜底返 ipc.unknown_op
// JSONDecoder 忽略未知字段, 所以新→老 / 老→新 都兼容; 真正错位需双方都 != current 才拦下.

import Foundation

public enum IPCProtocol {
    /// 协议版本. 改 IPCRequest / IPCResponse / 已知 op 语义时 +1.
    /// 加新 op (向上扩展) 不需要 +1.
    public static let version: Int = 1
}

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var op: String
    public var args: [String: String]
    /// 客户端协议版本. nil 视作 legacy 客户端 (兼容老 hvm-cli).
    public var protoVersion: Int?

    public init(
        id: String = UUID().uuidString,
        op: String,
        args: [String: String] = [:],
        protoVersion: Int? = IPCProtocol.version
    ) {
        self.id = id
        self.op = op
        self.args = args
        self.protoVersion = protoVersion
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var data: [String: String]?
    public var error: IPCErrorPayload?

    public static func success(id: String, data: [String: String] = [:]) -> IPCResponse {
        IPCResponse(id: id, ok: true, data: data, error: nil)
    }

    public static func failure(id: String, code: String, message: String, details: [String: String] = [:]) -> IPCResponse {
        IPCResponse(id: id, ok: false, data: nil,
                    error: IPCErrorPayload(code: code, message: message, details: details))
    }

    /// 把 Codable payload 编码为 JSON 包成 success 响应; 失败返 failure(ipc.encode_failed).
    /// kind: 失败 message 用, 让客户端定位哪类响应失败. dateStrategy 默认 .iso8601.
    public static func encoded<T: Encodable>(
        id: String,
        payload: T,
        kind: String,
        dateStrategy: JSONEncoder.DateEncodingStrategy = .iso8601
    ) -> IPCResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateStrategy
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(id: id, code: "ipc.encode_failed",
                            message: "\(kind) payload 编码失败")
        }
        return .success(id: id, data: ["payload": json])
    }
}

public struct IPCErrorPayload: Codable, Sendable {
    public var code: String
    public var message: String
    public var details: [String: String]
}

// MARK: - 已知 op

public enum IPCOp: String, Sendable {
    case status  = "status"
    case stop    = "stop"
    case kill    = "kill"
    case pause   = "pause"
    case resume  = "resume"

    // hvm-dbg 子命令对应的 op (M5)
    case dbgScreenshot   = "dbg.screenshot"
    case dbgStatus       = "dbg.status"
    case dbgKey          = "dbg.key"
    case dbgMouse        = "dbg.mouse"
    case dbgOcr          = "dbg.ocr"
    case dbgFindText     = "dbg.find_text"
    case dbgBootProgress = "dbg.boot_progress"
    case dbgConsoleRead  = "dbg.console.read"
    case dbgConsoleWrite = "dbg.console.write"
    /// hvm-dbg display-info — QMP screendump 拿 guest 真实 framebuffer 尺寸. 验证 dynamic resize 是否生效.
    case dbgDisplayInfo  = "dbg.display.info"
    /// hvm-dbg display-resize — 模拟 GUI 拖窗口触发 host → guest resize, 走两条通路:
    ///   A. HDP RESIZE_REQUEST (Linux virtio-gpu)  B. vdagent MONITORS_CONFIG (Win spice-vdagent)
    /// 测试规约: 调用此 op 时 GUI 不能同时 attach (iosurface/vdagent chardev 单 client).
    case dbgDisplayResize = "dbg.display.resize"
    /// qemu-guest-agent (qga) 在 guest 内跑 process 拿 stdout/stderr/exit_code (给 hvm-dbg exec-guest).
    /// 不依赖 keyboard typing / OCR / GUI mouse, 避字符替换 / 识别误差 / 坐标问题.
    case dbgExecGuest    = "dbg.exec.guest"
    /// host → guest 单文件 push. args: localPath, remotePath, timeoutSec? (默认 600).
    /// 走 qga guest-file-* API: VMHost open(2) localPath → 1 MiB chunk base64 → guest qemu-ga 写 remotePath.
    case dbgFilePush     = "dbg.file.push"
    /// guest → host 单文件 pull (与 push 反向, 同款协议). 本地走 .hvm-tmp + atomic rename 防半成品.
    case dbgFilePull     = "dbg.file.pull"
    /// 列 guest 内目录 (GUI "从 VM 取文件" 浏览器 + hvm-dbg dir ls). args: path, timeoutSec? (默认 30).
    /// 走 qga guest-exec PowerShell (Win) / find (Linux). entries 排序: 目录在前, 名字字母序.
    case dbgListDir      = "dbg.dir.list"
    /// host (GUI) 通知 VMHost 改 guest 分辨率, args.width/height. VMHost 持久持有 vdagent socket
    /// (single-client, 必须唯一持有), 通过 VDAgentMonitorsConfig 转给 guest spice-vdagent.
    case displaySetMonitors = "display.setMonitors"
    /// host (GUI) 切剪贴板共享, args.enabled = "1"/"0". 立即生效 (不必重启). 持久化由 GUI 侧改 yaml.
    case clipboardSetEnabled = "clipboard.setEnabled"
    /// host (GUI) 把 Cmd+V 选中的 host 文件 list 推给 VMHost, 走 vdagent VD_AGENT_FILE_XFER_* 流给 guest,
    /// 落 ~/Downloads. args.paths = JSON host 绝对路径数组. 仅 QEMU + Linux/Windows. 长事务 timeoutSec ≥ 600.
    case clipboardPasteFiles = "clipboard.paste-files"
    /// host (GUI) "一键装 helper": QGA 推 EXE + 注册 schtasks ONLOGON HIGHEST + 立即拉起.
    /// 仅 QEMU + Windows. args.force = "1" 跳过 marker 强制重装. 详见 GuestHelperInstaller.
    case clipboardInstallHelper = "clipboard.install-helper"
}

/// clipboard.paste-files 响应. 三分桶 (成功 / 跳过 / 失败); GUI 侧成功走通知, 跳过+失败走 ErrorDialog.
public struct IPCClipboardPasteFilesPayload: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let path: String
        public let reason: String        // 跳过 / 失败原因; 成功项填 ""
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }
    public let successful: [Item]
    public let skipped: [Item]
    public let failed: [Item]
    public init(successful: [Item], skipped: [Item], failed: [Item]) {
        self.successful = successful
        self.skipped = skipped
        self.failed = failed
    }
}

/// dbg.display.info payload — guest 真实当前 framebuffer 尺寸.
public struct IPCDbgDisplayInfoPayload: Codable, Sendable {
    public let widthPx: Int
    public let heightPx: Int
    public init(widthPx: Int, heightPx: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// dbg.display.resize 响应 — 双通路 send 结果, 任一通路结果由日志为准, 这里只摘要.
public struct IPCDbgDisplayResizePayload: Codable, Sendable {
    public let widthPx: UInt32
    public let heightPx: UInt32
    public let hdpResult: String   // "sent" / "skipped" / "connect_failed: ..."
    public let vdagentResult: String  // "sent" / "connect_failed: ..." / "skipped"
    public init(widthPx: UInt32, heightPx: UInt32, hdpResult: String, vdagentResult: String) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.hdpResult = hdpResult
        self.vdagentResult = vdagentResult
    }
}

/// dbg.exec.guest payload — 跑 guest 内 process 拿结果. exit_code=-1 表示 timeout.
public struct IPCDbgExecPayload: Codable, Sendable {
    public let exitCode: Int
    public let stdoutBase64: String
    public let stderrBase64: String
    public init(exitCode: Int, stdoutBase64: String, stderrBase64: String) {
        self.exitCode = exitCode
        self.stdoutBase64 = stdoutBase64
        self.stderrBase64 = stderrBase64
    }
}

/// dbg.file.push / dbg.file.pull 响应 — 文件传输结果摘要 (进度反馈走 client 端字节计数).
public struct IPCDbgFileTransferPayload: Codable, Sendable {
    public let bytesTransferred: Int64
    public let durationMs: Int64
    public init(bytesTransferred: Int64, durationMs: Int64) {
        self.bytesTransferred = bytesTransferred
        self.durationMs = durationMs
    }
}

/// dbg.dir.list 响应 — guest 目录条目列表.
public struct IPCDbgListDirPayload: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let name: String
        public let fullPath: String
        public let isDir: Bool
        public let size: Int64
        public init(name: String, fullPath: String, isDir: Bool, size: Int64) {
            self.name = name; self.fullPath = fullPath
            self.isDir = isDir; self.size = size
        }
    }
    public let path: String          // echo 回的 query path (guest 内绝对路径)
    public let entries: [Entry]
    public init(path: String, entries: [Entry]) {
        self.path = path; self.entries = entries
    }
}

// MARK: - hvm-dbg payloads

/// dbg.screenshot 响应. PNG 二进制 base64 编码.
public struct IPCDbgScreenshotPayload: Codable, Sendable {
    public var pngBase64: String
    public var widthPx: Int
    public var heightPx: Int
    public var sha256: String

    public init(pngBase64: String, widthPx: Int, heightPx: Int, sha256: String) {
        self.pngBase64 = pngBase64
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.sha256 = sha256
    }
}

/// dbg.ocr 响应. texts 数组里每项 bbox 是 guest 像素左上原点.
public struct IPCDbgOcrPayload: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public var text: String
        public var confidence: Float

        public init(x: Int, y: Int, width: Int, height: Int, text: String, confidence: Float) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.text = text; self.confidence = confidence
        }
    }
    public var widthPx: Int
    public var heightPx: Int
    public var texts: [Item]

    public init(widthPx: Int, heightPx: Int, texts: [Item]) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.texts = texts
    }
}

/// dbg.find_text 响应. 找到 (match=true) 返回 bbox + center; 找不到 (match=false) 其余字段 nil.
public struct IPCDbgFindTextPayload: Codable, Sendable {
    public var match: Bool
    public var x: Int?
    public var y: Int?
    public var width: Int?
    public var height: Int?
    public var centerX: Int?
    public var centerY: Int?
    public var text: String?
    public var confidence: Float?

    public init(match: Bool, x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil,
                centerX: Int? = nil, centerY: Int? = nil, text: String? = nil, confidence: Float? = nil) {
        self.match = match
        self.x = x; self.y = y; self.width = width; self.height = height
        self.centerX = centerX; self.centerY = centerY
        self.text = text; self.confidence = confidence
    }
}

/// dbg.status 响应. 偏 guest 视角 (区别于 hvm-cli status 的 host 视角), 给 agent 判断画面/存活.
public struct IPCDbgStatusPayload: Codable, Sendable {
    public var state: String                     // RunState string
    public var guestWidthPx: Int                 // guest framebuffer 宽
    public var guestHeightPx: Int                // guest framebuffer 高
    public var lastFrameSha256: String?          // 最近一次截图 hash, 没截过 = nil
    public var consoleAgentOnline: Bool

    public init(state: String, guestWidthPx: Int, guestHeightPx: Int,
                lastFrameSha256: String?, consoleAgentOnline: Bool) {
        self.state = state
        self.guestWidthPx = guestWidthPx
        self.guestHeightPx = guestHeightPx
        self.lastFrameSha256 = lastFrameSha256
        self.consoleAgentOnline = consoleAgentOnline
    }
}

/// dbg.console.read 响应. data 是 base64 编码的原始字节 (guest stdout 可能是 UTF-8 也可能是
/// 二进制 escape 序列, 不强行解码). 客户端拿 totalBytes 当下次 sinceBytes 实现增量轮询.
public struct IPCDbgConsoleReadPayload: Codable, Sendable {
    public var dataBase64: String         // 本次返回的字节
    public var totalBytes: Int            // guest 累计输出字节数 (跨 ring 截断仍累加)
    public var returnedSinceBytes: Int    // 本次数据起点; 落在 ring 窗口外时会上调到窗口左界

    public init(dataBase64: String, totalBytes: Int, returnedSinceBytes: Int) {
        self.dataBase64 = dataBase64
        self.totalBytes = totalBytes
        self.returnedSinceBytes = returnedSinceBytes
    }
}

/// dbg.boot_progress 响应. 启发式判断 guest 启动阶段, confidence < 0.5 时 phase=unknown.
/// 阶段定义见 boot-progress 实现.
public struct IPCDbgBootProgressPayload: Codable, Sendable {
    public var phase: String          // bios | boot-logo | ready-tty | ready-gui | unknown
    public var confidence: Float      // [0, 1]
    public var elapsedSec: Int?       // 自 startedAt 起的秒数, 没启动过 = nil

    public init(phase: String, confidence: Float, elapsedSec: Int?) {
        self.phase = phase
        self.confidence = confidence
        self.elapsedSec = elapsedSec
    }
}

public struct IPCStatusPayload: Codable, Sendable {
    public var state: String        // RunState 的 string
    public var id: String           // UUID string
    public var bundlePath: String
    public var displayName: String
    public var guestOS: String
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var pid: Int32
    public var startedAt: Date?

    public init(state: String, id: String, bundlePath: String, displayName: String,
                guestOS: String, cpuCount: Int, memoryMiB: UInt64, pid: Int32, startedAt: Date?) {
        self.state = state
        self.id = id
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.guestOS = guestOS
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.pid = pid
        self.startedAt = startedAt
    }
}
