// HVMQemu/SpiceWebdavServer.swift
//
// host ↔ guest 共享目录 SPICE WebDAV server.
//
// 架构:
//   QEMU chardev (server=on) ── unix socket ── SpiceWebdavServer 作 client 连入
//                                                  │
//                                                  ├─ readThread: 读 mux frames
//                                                  │      │
//                                                  │      └─ 按 client_id demux → 各自 HTTP 解析器
//                                                  │            │
//                                                  │            └─ 完整 HTTP 请求就绪 → 派给 handler
//                                                  │
//                                                  ├─ writeQueue (DispatchQueue serial)
//                                                  │      └─ 跑 WebDavHandler.process → 响应 → 切 mux frames → 写 socket
//                                                  │
//                                                  └─ roots: [Root] (host 路径 + RO flag, 唯一来源)
//
// Wire 协议 (跟 phodav 源码对齐):
//   frame: [client_id u64_le][size u16_le][payload <= 65535 bytes]
//   size=0 是 client 主动关连接 signal.
//   HTTP 跨多 frame 时同 client_id 关联, payload 按字节拼接还原 HTTP 流.
//   响应同理: 大响应分多个 frame, 各 frame size <= 65535.
//
// 安全:
//   1. 路径 escape: 所有 guest 路径必须落在 roots[].url 子树内, realpath + hasPrefix 双校验,
//      symlink follow 后越界一律 403
//   2. read-only: spec.readOnly=true 时 PUT/DELETE/MKCOL/MOVE/COPY 一律 403
//   3. name 字符集: SharedFolderSpec.sanitizeName 已限制 [a-zA-Z0-9_-], 不会出 URL 注入

import Foundation
import Darwin
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "SpiceWebdav")

// MARK: - 公共类型

public final class SpiceWebdavServer: @unchecked Sendable {

    public struct Root: Sendable {
        public let name: String     // ASCII alnum + - _, 已 sanitize
        public let url: URL         // host 绝对路径
        public let readOnly: Bool

        public init(name: String, url: URL, readOnly: Bool) {
            self.name = name
            self.url = url
            self.readOnly = readOnly
        }
    }

    private let socketPath: String
    private let roots: [Root]
    /// roots 索引, 加速 PROPFIND root 列出 + 按 name 查找
    private let rootsByName: [String: Root]
    /// listen=true: HVM 作 server bind+listen+accept; 默认 false: HVM 作 client connect 现有 socket.
    /// 生产路径 (QEMU chardev server=on) 走 false; hvm-dbg webdav-serve --listen 走 true 做端到端测.
    private let listenMode: Bool

    private let writeQueue = DispatchQueue(label: "hvm.webdav.write", qos: .userInitiated)
    /// listen 模式下的 accept socket (server fd)
    private var listenFD: Int32 = -1
    private var sockFD: Int32 = -1
    private var readThread: Thread?

    /// 每个 client_id 的 HTTP 解析器状态. 主线程是 readThread; writeQueue 不动它.
    private var clients: [UInt64: ClientState] = [:]
    /// _activeClients 写在 readThread, 读在 GUI / IPC 线程, 加锁.
    private let activeLock = NSLock()
    private var _activeClients: Int = 0

    public var activeClients: Int {
        activeLock.lock(); defer { activeLock.unlock() }
        return _activeClients
    }

    public init(socketPath: String, roots: [Root], listenMode: Bool = false) {
        self.socketPath = socketPath
        self.roots = roots
        var byName: [String: Root] = [:]
        for r in roots { byName[r.name] = r }
        self.rootsByName = byName
        self.listenMode = listenMode
    }

    deinit {
        if sockFD >= 0 { Darwin.close(sockFD) }
        if listenFD >= 0 { Darwin.close(listenFD) }
    }

    // MARK: - 公共 API

    /// 异步 connect QEMU chardev unix socket + 启动 read loop. 失败 silently warn.
    public func connect() {
        writeQueue.async { [weak self] in self?.doConnect() }
    }

    public func disconnect() {
        writeQueue.async { [weak self] in self?.doDisconnect() }
    }

    // MARK: - 内部: socket 生命周期

    /// 在 writeQueue 上跑. 跟 VdagentClient.doConnect 同款 retry 模式: 第一次失败不立即重试,
    /// 等 read loop 出错 / 下次 ensureConnectedLocked 再 lazy 重连.
    private func doConnect() {
        if sockFD >= 0 { return }
        if listenMode {
            doListen()
            return
        }
        // client 模式: 等 socket 文件出现 (QEMU 启动到 chardev listen 之间有窗口). 最多等 30s, 100ms 一探.
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.warning("webdav socket() errno=\(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(fd)
            log.warning("webdav socket path 过长: \(self.socketPath)")
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: pathLimit) { bp in
                for (i, b) in pathBytes.enumerated() { bp[i] = b }
                bp[pathBytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.connect(fd, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let saved = errno
            Darwin.close(fd)
            log.warning("webdav connect errno=\(saved) path=\(self.socketPath)")
            return
        }
        sockFD = fd
        log.info("webdav connected to \(self.socketPath) roots=\(self.roots.count, privacy: .public)")
        let t = Thread { [weak self] in self?.runReadLoop() }
        t.name = "hvm.webdav.read"
        readThread = t
        t.start()
    }

    /// listen 模式: bind + listen + accept, 同样把 accept 出的 fd 赋 sockFD 给 read loop 用.
    /// 只接受一个 client (跟 client 模式一致, 简化生命周期). client 断开 → 重新 accept.
    private func doListen() {
        // 删 stale socket
        unlink(socketPath)
        let listen = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listen >= 0 else {
            log.warning("webdav listen socket() errno=\(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(listen); log.warning("webdav listen path too long"); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: pathLimit) { bp in
                for (i, b) in pathBytes.enumerated() { bp[i] = b }
                bp[pathBytes.count] = 0
            }
        }
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.bind(listen, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRC != 0 {
            let e = errno; Darwin.close(listen)
            log.warning("webdav bind errno=\(e) path=\(self.socketPath)")
            return
        }
        if Darwin.listen(listen, 1) != 0 {
            let e = errno; Darwin.close(listen); unlink(socketPath)
            log.warning("webdav listen errno=\(e)")
            return
        }
        listenFD = listen
        log.info("webdav listening on \(self.socketPath) roots=\(self.roots.count, privacy: .public)")
        // 跑 accept loop 单独线程, 每 accept 一次起 read loop
        let t = Thread { [weak self] in self?.runAcceptLoop() }
        t.name = "hvm.webdav.accept"
        readThread = t
        t.start()
    }

    private func runAcceptLoop() {
        while listenFD >= 0 {
            let cfd = Darwin.accept(listenFD, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                log.warning("webdav accept errno=\(errno); 退出 accept loop")
                return
            }
            sockFD = cfd
            log.info("webdav 接受连接 client fd=\(cfd)")
            runReadLoop()
            // read loop 退出 = client 断, 清状态, 再 accept 下一个
            clients.removeAll()
            activeLock.lock(); _activeClients = 0; activeLock.unlock()
        }
    }

    private func doDisconnect() {
        if sockFD >= 0 {
            Darwin.close(sockFD); sockFD = -1
        }
        if listenFD >= 0 {
            Darwin.close(listenFD); listenFD = -1
            unlink(socketPath)
        }
        clients.removeAll()
        activeLock.lock(); _activeClients = 0; activeLock.unlock()
        readThread = nil
    }

    // MARK: - readThread

    private func runReadLoop() {
        // per-thread recv 缓冲, 跟 QgaConnection 同款 64KB chunk + buffer 切帧
        var recvBuf = Data()
        let chunk = 64 * 1024
        var tmp = [UInt8](repeating: 0, count: chunk)

        while true {
            let curFD = sockFD
            if curFD < 0 { return }

            // 1) 先扫现有 buffer 尝试解 frame
            while let frame = MuxFrame.tryParse(buffer: &recvBuf) {
                handleFrame(frame)
            }

            // 2) recv 一拨
            let n = tmp.withUnsafeMutableBufferPointer { bp -> Int in
                return Darwin.recv(curFD, bp.baseAddress, bp.count, 0)
            }
            if n > 0 {
                recvBuf.append(tmp, count: n)
            } else if n == 0 {
                log.info("webdav socket EOF; close + clients cleanup")
                writeQueue.async { [weak self] in self?.doDisconnect() }
                return
            } else {
                if errno == EINTR { continue }
                log.warning("webdav recv errno=\(errno); close + clients cleanup")
                writeQueue.async { [weak self] in self?.doDisconnect() }
                return
            }
        }
    }

    /// readThread 上跑. 把 frame payload 喂给对应 client 的 HTTP 解析器.
    private func handleFrame(_ frame: MuxFrame) {
        if frame.payload.isEmpty {
            // client 关
            if clients.removeValue(forKey: frame.clientId) != nil {
                activeLock.lock(); _activeClients -= 1; activeLock.unlock()
                log.debug("webdav client=\(frame.clientId) closed")
            }
            return
        }
        if clients[frame.clientId] == nil {
            clients[frame.clientId] = ClientState()
            activeLock.lock(); _activeClients += 1; activeLock.unlock()
            log.debug("webdav client=\(frame.clientId) new")
        }
        guard var state = clients[frame.clientId] else { return }
        state.recvBuf.append(frame.payload)
        // 多请求 pipeline: while 直到 parser 返 .needMore
        while true {
            let result = state.parser.tryParse(buffer: &state.recvBuf)
            switch result {
            case .ready(let req):
                // dispatch handler on writeQueue (不阻 readThread)
                let clientId = frame.clientId
                writeQueue.async { [weak self] in
                    guard let self else { return }
                    let resp = WebDavHandler(roots: self.roots, rootsByName: self.rootsByName).process(request: req)
                    self.sendResponse(clientId: clientId, response: resp)
                }
            case .needMore:
                clients[frame.clientId] = state
                return
            case .protocolError(let why):
                log.warning("webdav client=\(frame.clientId) protocol err: \(why); 关 client")
                clients.removeValue(forKey: frame.clientId)
                activeLock.lock(); _activeClients -= 1; activeLock.unlock()
                // 不向对端发关闭, 让 spice-webdavd 自己 timeout. 简化逻辑.
                return
            }
        }
    }

    // MARK: - 响应发送 (在 writeQueue 上)

    private func sendResponse(clientId: UInt64, response: HTTPResponse) {
        var body = response.serialize()
        // 切 mux frames, 每片 <= 65535
        let chunk = 65535
        while !body.isEmpty {
            let len = min(chunk, body.count)
            let part = body.prefix(len)
            let frame = MuxFrame(clientId: clientId, payload: Data(part))
            sendFrame(frame)
            body.removeFirst(len)
        }
    }

    private func sendFrame(_ frame: MuxFrame) {
        let encoded = frame.encode()
        guard sockFD >= 0 else { return }
        var off = 0
        let total = encoded.count
        encoded.withUnsafeBytes { ptr in
            while off < total {
                let r = Darwin.send(sockFD, ptr.baseAddress!.advanced(by: off), total - off, 0)
                if r < 0 {
                    if errno == EINTR { continue }
                    log.warning("webdav send errno=\(errno); 关 socket")
                    if sockFD >= 0 { Darwin.close(sockFD); sockFD = -1 }
                    return
                }
                off += r
            }
        }
    }

    // MARK: - per-client HTTP 解析状态

    private struct ClientState {
        var recvBuf = Data()
        var parser = HTTPRequestParser()
    }
}

// MARK: - Mux frame codec

/// SPICE WebDAV mux frame: 10 字节 header + payload (<=65535)
public struct MuxFrame {
    public let clientId: UInt64    // little-endian on wire
    public let payload: Data       // size = payload.count, 0 = 客户端关连接

    public init(clientId: UInt64, payload: Data) {
        self.clientId = clientId
        self.payload = payload
    }

    /// 从 buffer 尝试切一帧; 不够就返 nil. 切出后 buffer 移除头部.
    public static func tryParse(buffer: inout Data) -> MuxFrame? {
        guard buffer.count >= 10 else { return nil }
        let clientId = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self).littleEndian }
        let size     = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self).littleEndian })
        guard buffer.count >= 10 + size else { return nil }
        let payload = (size == 0) ? Data() : Data(buffer[(buffer.startIndex + 10)..<(buffer.startIndex + 10 + size)])
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 10 + size))
        return MuxFrame(clientId: clientId, payload: payload)
    }

    public func encode() -> Data {
        precondition(payload.count <= 65535, "MuxFrame payload >65535 必须先切")
        var d = Data(capacity: 10 + payload.count)
        var cid = clientId.littleEndian
        withUnsafeBytes(of: &cid) { d.append(contentsOf: $0) }
        var sz = UInt16(payload.count).littleEndian
        withUnsafeBytes(of: &sz) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }
}

// MARK: - HTTP 请求解析器

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String                // raw (未 percent-decode)
    public var headers: [Header]           // 保序, 名按 lowercase 存
    public var body: Data

    public struct Header: Sendable {
        public let name: String   // lowercase
        public let value: String
        public init(name: String, value: String) {
            self.name = name; self.value = value
        }
    }

    public init(method: String, path: String, headers: [Header], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// 元组形态便捷构造 — 静态方法避免 init 重载与 [Header]/[(String,String)] 在空 `[]`
    /// 字面量场景下二义. 测试 / 调用方写 `[("depth", "1")]` 时显式调 `.fromTuples` 即可.
    public static func fromTuples(method: String, path: String,
                                   headers: [(String, String)], body: Data) -> HTTPRequest {
        return HTTPRequest(method: method, path: path,
                           headers: headers.map { Header(name: $0.0, value: $0.1) },
                           body: body)
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.name == lower })?.value
    }
}

public enum HTTPParseResult {
    case ready(HTTPRequest)
    case needMore
    case protocolError(String)
}

/// 单 client 的 HTTP/1.1 请求解析器 (按字节驱动). 支持单 client 多 pipeline 请求.
public struct HTTPRequestParser {
    public init() {}
    /// 解析 buffer 里能切出的下一个完整请求, 切出后 buffer 移除已消费字节.
    public mutating func tryParse(buffer: inout Data) -> HTTPParseResult {
        // 找 \r\n\r\n 切 header
        guard let hdrEnd = findHeaderEnd(buffer) else {
            return buffer.count > 256 * 1024 ? .protocolError("header > 256KB") : .needMore
        }
        let hdrBytes = buffer[buffer.startIndex..<(buffer.startIndex + hdrEnd)]
        guard let hdrStr = String(data: Data(hdrBytes), encoding: .utf8) else {
            return .protocolError("header non-utf8")
        }
        let lines = hdrStr.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return .protocolError("empty request line") }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return .protocolError("bad request line: \(requestLine)") }
        let method = parts[0]
        let path = parts[1]
        // parts[2] 是 "HTTP/1.1", 不校验

        var headers: [HTTPRequest.Header] = []
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                return .protocolError("bad header: \(line)")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append(HTTPRequest.Header(name: name, value: value))
        }

        // Content-Length 决定 body 长度. 不支持 chunked transfer (phodav-mount 不用).
        let contentLength: Int
        if let cl = headers.first(where: { $0.name == "content-length" })?.value, let n = Int(cl) {
            contentLength = n
        } else {
            contentLength = 0
        }
        let totalNeeded = hdrEnd + contentLength
        guard buffer.count >= totalNeeded else {
            return .needMore
        }
        let bodyStart = buffer.startIndex + hdrEnd
        let body = contentLength > 0 ? Data(buffer[bodyStart..<(bodyStart + contentLength)]) : Data()
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + totalNeeded))
        return .ready(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    /// 返 header 末尾 (含 \r\n\r\n) 在 buffer 内的偏移; 没找到返 nil.
    private func findHeaderEnd(_ buf: Data) -> Int? {
        guard buf.count >= 4 else { return nil }
        return buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let p = raw.bindMemory(to: UInt8.self)
            let end = p.count - 4
            if end < 0 { return nil }
            for i in 0...end {
                if p[i] == 0x0D, p[i+1] == 0x0A, p[i+2] == 0x0D, p[i+3] == 0x0A {
                    return i + 4
                }
            }
            return nil
        }
    }
}

// MARK: - HTTP 响应

public struct HTTPResponse {
    public var status: Int           // 200, 207, 404, 403, 405, 500 ...
    public var headers: [(String, String)] = []
    public var body: Data = Data()

    public init(status: Int) { self.status = status }

    public static func ok(body: Data = Data(), contentType: String = "application/octet-stream") -> HTTPResponse {
        var r = HTTPResponse(status: 200)
        r.headers.append(("Content-Type", contentType))
        r.headers.append(("Content-Length", "\(body.count)"))
        r.body = body
        return r
    }

    public static func multiStatus(xml: String) -> HTTPResponse {
        let data = Data(xml.utf8)
        var r = HTTPResponse(status: 207)
        r.headers.append(("Content-Type", "application/xml; charset=utf-8"))
        r.headers.append(("Content-Length", "\(data.count)"))
        r.body = data
        return r
    }

    public static func plain(status: Int, text: String = "") -> HTTPResponse {
        let data = Data(text.utf8)
        var r = HTTPResponse(status: status)
        r.headers.append(("Content-Type", "text/plain; charset=utf-8"))
        r.headers.append(("Content-Length", "\(data.count)"))
        r.body = data
        return r
    }

    public func serialize() -> Data {
        var out = Data()
        let statusText = statusReason(status)
        out.append(Data("HTTP/1.1 \(status) \(statusText)\r\n".utf8))
        var hasConnection = false
        for (n, v) in headers {
            if n.lowercased() == "connection" { hasConnection = true }
            out.append(Data("\(n): \(v)\r\n".utf8))
        }
        if !hasConnection {
            // 不主动关连接, spice-webdavd 复用 client_id pipeline
            out.append(Data("Connection: keep-alive\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    private func statusReason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 207: return "Multi-Status"
        case 301: return "Moved Permanently"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 412: return "Precondition Failed"
        case 415: return "Unsupported Media Type"
        case 423: return "Locked"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 507: return "Insufficient Storage"
        default:  return "Unknown"
        }
    }
}

// MARK: - WebDAV handler

public struct WebDavHandler {
    public let roots: [SpiceWebdavServer.Root]
    public let rootsByName: [String: SpiceWebdavServer.Root]

    public init(roots: [SpiceWebdavServer.Root], rootsByName: [String: SpiceWebdavServer.Root]) {
        self.roots = roots
        self.rootsByName = rootsByName
    }

    public func process(request req: HTTPRequest) -> HTTPResponse {
        let path = normalizePath(req.path)
        let cl = req.body.count
        log.info("→ \(req.method, privacy: .public) \(req.path, privacy: .public) (body=\(cl)B)")
        let resp = dispatch(req: req, path: path)
        log.info("← \(resp.status, privacy: .public) for \(req.method, privacy: .public) \(req.path, privacy: .public)")
        return resp
    }

    private func dispatch(req: HTTPRequest, path: String) -> HTTPResponse {
        switch req.method.uppercased() {
        case "OPTIONS": return handleOptions()
        case "PROPFIND": return handlePropfind(req: req, path: path)
        case "GET":     return handleGet(req: req, path: path, head: false)
        case "HEAD":    return handleGet(req: req, path: path, head: true)
        case "PUT":     return handlePut(req: req, path: path)
        case "DELETE":  return handleDelete(path: path)
        case "MKCOL":   return handleMkcol(path: path)
        case "MOVE":    return handleMove(req: req, path: path)
        case "COPY":    return handleCopy(req: req, path: path)
        case "PROPPATCH": return handleProppatch(req: req, path: path)
        case "LOCK":    return handleLock(req: req, path: path)
        case "UNLOCK":  return HTTPResponse.plain(status: 204)     // 假成功; 我们没真锁状态
        default:        return HTTPResponse.plain(status: 405, text: "method not allowed: \(req.method)")
        }
    }

    // MARK: 路径解析

    /// 把请求 path 转成 (rootName, subPath) 二元组. rootName 为 "" 表示根 (列 roots).
    /// subPath 为相对 root 的路径 (e.g. "subdir/foo.txt", 不以 / 开头).
    private struct ResolvedPath {
        var rootName: String   // "" 表示 / (root 列表)
        var sub: String        // "" 表示 root 自身
    }

    private func normalizePath(_ raw: String) -> String {
        // percent-decode
        let decoded = raw.removingPercentEncoding ?? raw
        // 去 query string
        if let q = decoded.firstIndex(of: "?") {
            return String(decoded[..<q])
        }
        return decoded
    }

    private func resolve(_ guestPath: String) -> ResolvedPath {
        var p = guestPath
        // 必须 / 开头
        if !p.hasPrefix("/") { p = "/" + p }
        // 去尾部 /
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p == "/" { return ResolvedPath(rootName: "", sub: "") }
        // 切首段当 rootName
        let rest = String(p.dropFirst())
        if let slash = rest.firstIndex(of: "/") {
            return ResolvedPath(rootName: String(rest[..<slash]),
                                sub: String(rest[rest.index(after: slash)...]))
        }
        return ResolvedPath(rootName: rest, sub: "")
    }

    /// 把 ResolvedPath 转成 host 文件系统的绝对 URL, 并做 escape 防护.
    /// 返 nil 表示路径不存在 / root 名不存在 / 越界.
    private func toHostURL(_ rp: ResolvedPath) -> (root: SpiceWebdavServer.Root, url: URL)? {
        guard !rp.rootName.isEmpty, let root = rootsByName[rp.rootName] else { return nil }
        var url = root.url
        if !rp.sub.isEmpty {
            // sub 含 .. 直接拒
            let parts = rp.sub.split(separator: "/").map(String.init)
            for part in parts {
                if part == ".." || part == "." || part.isEmpty { return nil }
                url.appendPathComponent(part)
            }
        }
        // resolve symlink + 校验仍在 root 子树内
        let resolved = url.resolvingSymlinksInPath()
        let rootResolved = root.url.resolvingSymlinksInPath()
        let rPath = resolved.standardizedFileURL.path
        let rootPath = rootResolved.standardizedFileURL.path
        // hasPrefix 必须用 path + "/" 防 "/foo/bar" 命中 "/foo/baz" 的前缀错觉
        let normRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if rPath == rootPath || rPath.hasPrefix(normRoot) {
            return (root, url)
        }
        return nil
    }

    // MARK: 动词实现

    /// PROPPATCH 返 207 Multi-Status (RFC 4918 §9.2). Win shell IFileOperation 看到
    /// 裸 200 会判 "事务没真 commit", PUT 完文件后还会发 DELETE 回滚 (亲测).
    /// 解析 request body 拿用户想设的 Win32 prop 列表 (Win32CreationTime / FileAttributes
    /// 等), 每条都返 200 OK (假设成功; host fs 实际没存这些 Win 专属时间戳, 但 Win 不验证).
    private func handleProppatch(req: HTTPRequest, path: String) -> HTTPResponse {
        // 简单解析 set 块里出现的所有 <D:xxx/> tag, 逐条 echo 回 prop status.
        // 没用 XML parser, 走 regex 抠 <prop> ... </prop> 内的 tag 名 (Win 发的是标准格式).
        let bodyStr = String(data: req.body, encoding: .utf8) ?? ""
        // 抠 <D:set><D:prop>...</D:prop></D:set> 内所有 <D:tag/> / <D:tag>...</D:tag>
        // 简化: 拉所有看似 prop 的 tag 名 (排除元素本身: prop / set / remove / propertyupdate)
        var propTags: [String] = []
        let skipTags: Set<String> = ["propertyupdate", "set", "prop", "remove"]
        // 极简正则: 匹配 <D:name> 或 <D:name/> (D 前缀可选, 直接抠 :后字母数字)
        var idx = bodyStr.startIndex
        while idx < bodyStr.endIndex,
              let lt = bodyStr.range(of: "<", range: idx..<bodyStr.endIndex)
        {
            let after = lt.upperBound
            guard after < bodyStr.endIndex else { break }
            // 跳过结束标签 / 注释 / xml decl
            let c = bodyStr[after]
            if c == "/" || c == "?" || c == "!" {
                idx = bodyStr.index(after: lt.upperBound)
                continue
            }
            // 找 tag 名结束 (空格 / > / /> 之前)
            var nameEnd = after
            while nameEnd < bodyStr.endIndex {
                let ch = bodyStr[nameEnd]
                if ch == ">" || ch == " " || ch == "/" || ch == "\t" || ch == "\n" || ch == "\r" { break }
                nameEnd = bodyStr.index(after: nameEnd)
            }
            let rawName = String(bodyStr[after..<nameEnd])
            // 去 namespace 前缀
            let bareName: String
            if let colon = rawName.firstIndex(of: ":") {
                bareName = String(rawName[rawName.index(after: colon)...])
            } else {
                bareName = rawName
            }
            if !bareName.isEmpty, !skipTags.contains(bareName.lowercased()) {
                if !propTags.contains(rawName) { propTags.append(rawName) }
            }
            idx = nameEnd
        }
        // 兜底: 一个 prop 都没抠到 (body 异常 / Win 没设字段?) → 返一个空 200 prop 块
        if propTags.isEmpty {
            propTags = ["D:Win32LastModifiedTime"]
        }
        var propXml = ""
        for tag in propTags {
            propXml += "<\(tag)/>"
        }
        let href = xmlEscape(req.path)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response>
        <D:href>\(href)</D:href>
        <D:propstat>
        <D:prop>\(propXml)</D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
        </D:response>
        </D:multistatus>
        """
        return HTTPResponse.multiStatus(xml: xml)
    }

    /// 假 LOCK 实现: 直接返 200 + 一个伪 lock token. **不**维护真实锁状态.
    /// 这是 Win IFileOperation (Explorer 拖放 / Copy-Item / Set-ItemProperty) 必须的:
    /// 它会发 LOCK 申请独占锁, 若返 501 它把整个 file copy 事务当失败, PUT 完文件
    /// 立刻 DELETE 回滚, 然后报 "File Too Large for destination" 误导性错误.
    /// 单用户单机 webdav 场景没真的并发竞争, 假锁完全够用. (UTM / chezdav 同款思路.)
    private func handleLock(req: HTTPRequest, path: String) -> HTTPResponse {
        // 生成伪 opaquelocktoken (RFC 4918 §6.4): opaquelocktoken:<uuid>
        let token = "opaquelocktoken:\(UUID().uuidString.lowercased())"
        // 返 lockdiscovery XML body. 大部分 client (尤其 Win shell) 只看 Lock-Token header
        // 跟 status code, body 内容只要 valid xml + 含 locktoken href 就 OK.
        let lockroot = xmlEscape(req.path)
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:">
        <D:lockdiscovery>
        <D:activelock>
        <D:locktype><D:write/></D:locktype>
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:depth>0</D:depth>
        <D:owner><D:href>hvm-webdav</D:href></D:owner>
        <D:timeout>Second-3600</D:timeout>
        <D:locktoken><D:href>\(token)</D:href></D:locktoken>
        <D:lockroot><D:href>\(lockroot)</D:href></D:lockroot>
        </D:activelock>
        </D:lockdiscovery>
        </D:prop>
        """
        let data = Data(body.utf8)
        var r = HTTPResponse(status: 200)
        r.headers.append(("Content-Type", "application/xml; charset=utf-8"))
        r.headers.append(("Content-Length", "\(data.count)"))
        // RFC 4918 §10.5: Lock-Token header MUST 出现在 LOCK 响应里; <> 是 Coded-URL 语法
        r.headers.append(("Lock-Token", "<\(token)>"))
        r.body = data
        return r
    }

    private func handleOptions() -> HTTPResponse {
        var r = HTTPResponse(status: 200)
        r.headers.append(("DAV", "1, 2"))
        r.headers.append(("Allow", "OPTIONS, GET, HEAD, PROPFIND, PUT, DELETE, MKCOL, MOVE, COPY, PROPPATCH"))
        r.headers.append(("MS-Author-Via", "DAV"))
        r.headers.append(("Content-Length", "0"))
        return r
    }

    private func handlePropfind(req: HTTPRequest, path: String) -> HTTPResponse {
        let depth = req.header("depth") ?? "1"
        // depth=infinity 拒 (防递归列大目录把 server 卡死)
        if depth == "infinity" {
            return HTTPResponse.plain(status: 403, text: "Depth: infinity not allowed")
        }
        let depth1 = (depth != "0")
        let rp = resolve(path)
        if rp.rootName.isEmpty {
            // 列所有 roots
            return propfindRoots(depth1: depth1)
        }
        guard let (root, url) = toHostURL(rp) else {
            return HTTPResponse.plain(status: 404, text: "not found: \(path)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return HTTPResponse.plain(status: 404, text: "not found: \(path)")
        }
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<D:multistatus xmlns:D=\"DAV:\">\n"
        // 自身
        xml += propfindEntry(href: path,
                             isDir: isDir.boolValue,
                             url: url,
                             displayName: url.lastPathComponent.isEmpty ? root.name : url.lastPathComponent)
        // depth=1 列子项 (只对 dir 有意义)
        if depth1 && isDir.boolValue {
            if let kids = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) {
                let basePath = path.hasSuffix("/") ? path : path + "/"
                for k in kids {
                    var kIsDir: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: k.path, isDirectory: &kIsDir)
                    let kHref = basePath + percentEncode(k.lastPathComponent) + (kIsDir.boolValue ? "/" : "")
                    xml += propfindEntry(href: kHref, isDir: kIsDir.boolValue, url: k, displayName: k.lastPathComponent)
                }
            }
        }
        xml += "</D:multistatus>\n"
        return HTTPResponse.multiStatus(xml: xml)
    }

    private func propfindRoots(depth1: Bool) -> HTTPResponse {
        // Win WebDAV mini-redirector 挂载时第一查 root /, 没 quota 会按 "free=0" 直接拒所有 PUT
        // (报 "File Too Large for destination file system" 即便文件只有几 KB). 必须给 root
        // 自身 + 每个子 root 都挂 quota. 用 roots 中第一个的卷作 root 自身的 quota 来源
        // (root / 是虚拟集合, 没对应 host 路径; 取任意 root 的 fs 给 Win 知道总量).
        let rootQuota: (Int64, Int64)
        if let first = roots.first {
            rootQuota = Self.quotaForFilesystem(at: first.url)
        } else {
            rootQuota = (1 << 40, 0)
        }
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<D:multistatus xmlns:D=\"DAV:\">\n"
        // 根自身
        xml += "<D:response><D:href>/</D:href><D:propstat><D:prop>"
        xml += "<D:displayname></D:displayname>"
        xml += "<D:resourcetype><D:collection/></D:resourcetype>"
        xml += "<D:quota-available-bytes>\(rootQuota.0)</D:quota-available-bytes>"
        xml += "<D:quota-used-bytes>\(rootQuota.1)</D:quota-used-bytes>"
        xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
        if depth1 {
            for root in roots {
                let href = "/" + percentEncode(root.name) + "/"
                let (avail, used) = Self.quotaForFilesystem(at: root.url)
                xml += "<D:response><D:href>\(xmlEscape(href))</D:href><D:propstat><D:prop>"
                xml += "<D:displayname>\(xmlEscape(root.name))</D:displayname>"
                xml += "<D:resourcetype><D:collection/></D:resourcetype>"
                xml += "<D:quota-available-bytes>\(avail)</D:quota-available-bytes>"
                xml += "<D:quota-used-bytes>\(used)</D:quota-used-bytes>"
                xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
            }
        }
        xml += "</D:multistatus>\n"
        return HTTPResponse.multiStatus(xml: xml)
    }

    private func propfindEntry(href: String, isDir: Bool, url: URL, displayName: String) -> String {
        var s = "<D:response><D:href>\(xmlEscape(href))</D:href><D:propstat><D:prop>"
        s += "<D:displayname>\(xmlEscape(displayName))</D:displayname>"
        if isDir {
            s += "<D:resourcetype><D:collection/></D:resourcetype>"
            // quota 信息: 让 Win WebDAV 客户端别按 quota=0 拒上传 ("File Too Large").
            // 走 host fs 实际 free space; 拿不到就 fallback 1 TiB 兜底.
            // RFC 4331: quota-available-bytes / quota-used-bytes 是 directory-level prop.
            let (avail, used) = Self.quotaForFilesystem(at: url)
            s += "<D:quota-available-bytes>\(avail)</D:quota-available-bytes>"
            s += "<D:quota-used-bytes>\(used)</D:quota-used-bytes>"
        } else {
            s += "<D:resourcetype/>"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if let sz = attrs[.size] as? Int64 {
                    s += "<D:getcontentlength>\(sz)</D:getcontentlength>"
                }
                if let mt = attrs[.modificationDate] as? Date {
                    s += "<D:getlastmodified>\(rfc1123(mt))</D:getlastmodified>"
                }
            }
            s += "<D:getcontenttype>application/octet-stream</D:getcontenttype>"
        }
        s += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
        return s
    }

    /// 读 url 所在卷的 free / total bytes. 走 URLResourceValues 的 volumeAvailableCapacityForImportantUsage
    /// (macOS 优先重要数据可用容量, 比 systemFreeSize 更接近"真实可写量").
    /// 失败兜底 1 TiB available + 0 used (Win 客户端不会再按 quota=0 拒上传).
    private static func quotaForFilesystem(at url: URL) -> (avail: Int64, used: Int64) {
        let fallbackAvail: Int64 = 1 << 40  // 1 TiB
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]
        guard let vals = try? url.resourceValues(forKeys: keys) else {
            return (fallbackAvail, 0)
        }
        let avail = (vals.volumeAvailableCapacityForImportantUsage as Int64?) ?? fallbackAvail
        let total = Int64(vals.volumeTotalCapacity ?? 0)
        let used = max(0, total - avail)
        return (max(1, avail), used)
    }

    private func handleGet(req: HTTPRequest, path: String, head: Bool) -> HTTPResponse {
        let rp = resolve(path)
        if rp.rootName.isEmpty {
            return HTTPResponse.plain(status: 403, text: "cannot GET root")
        }
        guard let (_, url) = toHostURL(rp) else {
            return HTTPResponse.plain(status: 404, text: "not found")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return HTTPResponse.plain(status: 404, text: "not found or is dir")
        }
        guard let data = try? Data(contentsOf: url) else {
            return HTTPResponse.plain(status: 500, text: "read failed")
        }
        var r = HTTPResponse.ok(body: head ? Data() : data)
        if head { r.headers.removeAll { $0.0 == "Content-Length" }; r.headers.append(("Content-Length", "\(data.count)")) }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mt = attrs[.modificationDate] as? Date {
            r.headers.append(("Last-Modified", rfc1123(mt)))
        }
        return r
    }

    private func handlePut(req: HTTPRequest, path: String) -> HTTPResponse {
        let rp = resolve(path)
        if rp.rootName.isEmpty {
            return HTTPResponse.plain(status: 403, text: "cannot PUT root")
        }
        guard let root = rootsByName[rp.rootName] else {
            return HTTPResponse.plain(status: 404, text: "no such root")
        }
        if root.readOnly { return HTTPResponse.plain(status: 403, text: "read-only") }
        // 计算 dest URL (不能用 toHostURL — 目标可能不存在, toHostURL realpath 会 fail)
        guard let dest = composeDest(root: root, sub: rp.sub) else {
            return HTTPResponse.plain(status: 403, text: "path escape")
        }
        // 父目录必须存在
        let parent = dest.deletingLastPathComponent()
        var pIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &pIsDir), pIsDir.boolValue else {
            return HTTPResponse.plain(status: 409, text: "parent missing")
        }
        // 写 (覆盖)
        do {
            try req.body.write(to: dest, options: [.atomic])
        } catch {
            return HTTPResponse.plain(status: 500, text: "write fail: \(error)")
        }
        return HTTPResponse.plain(status: 201, text: "")
    }

    private func handleDelete(path: String) -> HTTPResponse {
        let rp = resolve(path)
        if rp.rootName.isEmpty {
            return HTTPResponse.plain(status: 403, text: "cannot DELETE root")
        }
        guard let (root, url) = toHostURL(rp) else {
            return HTTPResponse.plain(status: 404, text: "not found")
        }
        if root.readOnly { return HTTPResponse.plain(status: 403, text: "read-only") }
        if url.path == root.url.path { return HTTPResponse.plain(status: 403, text: "cannot delete root itself") }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return HTTPResponse.plain(status: 500, text: "delete fail: \(error)")
        }
        return HTTPResponse.plain(status: 204, text: "")
    }

    private func handleMkcol(path: String) -> HTTPResponse {
        let rp = resolve(path)
        if rp.rootName.isEmpty {
            return HTTPResponse.plain(status: 403, text: "cannot MKCOL root")
        }
        guard let root = rootsByName[rp.rootName] else {
            return HTTPResponse.plain(status: 404, text: "no such root")
        }
        if root.readOnly { return HTTPResponse.plain(status: 403, text: "read-only") }
        guard let dest = composeDest(root: root, sub: rp.sub) else {
            return HTTPResponse.plain(status: 403, text: "path escape")
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            return HTTPResponse.plain(status: 405, text: "already exists")
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            return HTTPResponse.plain(status: 409, text: "mkdir fail: \(error)")
        }
        return HTTPResponse.plain(status: 201, text: "")
    }

    private func handleMove(req: HTTPRequest, path: String) -> HTTPResponse {
        return doMoveCopy(req: req, srcPath: path, copy: false)
    }

    private func handleCopy(req: HTTPRequest, path: String) -> HTTPResponse {
        return doMoveCopy(req: req, srcPath: path, copy: true)
    }

    private func doMoveCopy(req: HTTPRequest, srcPath: String, copy: Bool) -> HTTPResponse {
        guard let destHdr = req.header("destination") else {
            return HTTPResponse.plain(status: 400, text: "no Destination header")
        }
        // Destination 可能是绝对 URL (http://host/path) 或绝对路径
        let destPath: String
        if destHdr.hasPrefix("http") {
            if let u = URL(string: destHdr) {
                destPath = u.path
            } else {
                return HTTPResponse.plain(status: 400, text: "bad Destination URL")
            }
        } else {
            destPath = destHdr
        }
        let srcRP = resolve(srcPath)
        let dstRP = resolve(destPath)
        guard let (srcRoot, srcURL) = toHostURL(srcRP) else {
            return HTTPResponse.plain(status: 404, text: "src not found")
        }
        guard let dstRoot = rootsByName[dstRP.rootName] else {
            return HTTPResponse.plain(status: 409, text: "dst root missing")
        }
        if srcRoot.readOnly || dstRoot.readOnly {
            return HTTPResponse.plain(status: 403, text: "read-only")
        }
        guard let dstURL = composeDest(root: dstRoot, sub: dstRP.sub) else {
            return HTTPResponse.plain(status: 403, text: "dst path escape")
        }
        // Overwrite header: T (default) 允许覆盖, F 拒绝
        let overwrite = (req.header("overwrite")?.uppercased() ?? "T") == "T"
        if FileManager.default.fileExists(atPath: dstURL.path) {
            if !overwrite {
                return HTTPResponse.plain(status: 412, text: "already exists; Overwrite: F")
            }
            try? FileManager.default.removeItem(at: dstURL)
        }
        do {
            if copy {
                try FileManager.default.copyItem(at: srcURL, to: dstURL)
            } else {
                try FileManager.default.moveItem(at: srcURL, to: dstURL)
            }
        } catch {
            return HTTPResponse.plain(status: 500, text: "\(copy ? "copy" : "move") fail: \(error)")
        }
        return HTTPResponse.plain(status: 201, text: "")
    }

    /// 给"目标不存在"场景算 host URL: 不走 realpath (target 还没有), 用纯字符串拼 + sub 段 escape 拦截.
    private func composeDest(root: SpiceWebdavServer.Root, sub: String) -> URL? {
        if sub.isEmpty { return root.url }   // PUT 到 root 自身没意义, 上层会处理
        let parts = sub.split(separator: "/").map(String.init)
        var url = root.url
        for part in parts {
            if part == ".." || part == "." || part.isEmpty { return nil }
            url.appendPathComponent(part)
        }
        // 父目录 resolveSymlink 后必须仍在 root 子树
        let parentResolved = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let rootResolved = root.url.resolvingSymlinksInPath()
        let pPath = parentResolved.standardizedFileURL.path
        let rPath = rootResolved.standardizedFileURL.path
        let normRoot = rPath.hasSuffix("/") ? rPath : rPath + "/"
        if pPath == rPath || pPath.hasPrefix(normRoot) {
            return url
        }
        return nil
    }
}

// MARK: - 工具

private let rfc1123Formatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return f
}()

private func rfc1123(_ d: Date) -> String { rfc1123Formatter.string(from: d) }

private func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.append(c)
        }
    }
    return out
}

private func percentEncode(_ s: String) -> String {
    // RFC 3986 path-segment: alpha / digit / "-" / "." / "_" / "~" / sub-delims / ":" / "@"
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
