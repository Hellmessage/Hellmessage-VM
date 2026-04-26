// HVMQemu/QmpClient.swift
// QMP unix socket 客户端: 异步命令-响应配对 + 异步事件流.
//
// 生命周期:
//   1. init(socketPath:)
//   2. await connect() — open socket → 同步读 greeting → spawn read loop → 发 qmp_capabilities
//   3. await client.queryStatus() / .systemPowerdown() / ...
//   4. for await event in client.events { ... }   (并发消费, 不阻塞命令)
//   5. close()
//
// 并发约束 (Swift 6 严格并发):
//   - 全部可变状态用 OSAllocatedUnfairLock 包 (NSLock 在 async 上下文不可用)
//   - readQueue: 专用串行队列, 跑 blocking recv() loop
//   - writeQueue: 专用串行队列, 跑 send() (避免命令交错切碎)

import Foundation
import Darwin
import os.lock
import HVMCore

public final class QmpClient: @unchecked Sendable {

    // MARK: - 配置

    public let socketPath: String
    public let connectTimeoutSec: Int

    // MARK: - 事件流

    public let events: AsyncStream<QmpEvent>
    private let eventContinuation: AsyncStream<QmpEvent>.Continuation

    // MARK: - 状态 (锁内可变)

    private struct State {
        var fd: Int32 = -1
        var connected = false
        var closed = false
        var nextCmdSeq: UInt64 = 0
        var pendingCommands: [String: CheckedContinuation<Data, Error>] = [:]
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    // MARK: - 初始化

    public init(socketPath: String, connectTimeoutSec: Int = 5) {
        self.socketPath = socketPath
        self.connectTimeoutSec = connectTimeoutSec
        self.readQueue = DispatchQueue(label: "hvm.qmp.read.\(UUID().uuidString.prefix(8))",
                                       qos: .userInitiated)
        self.writeQueue = DispatchQueue(label: "hvm.qmp.write.\(UUID().uuidString.prefix(8))",
                                        qos: .userInitiated)
        var cont: AsyncStream<QmpEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.eventContinuation = cont
    }

    deinit {
        let f = state.withLock { $0.fd }
        if f >= 0 { Darwin.close(f) }
    }

    // MARK: - 连接

    /// 打开 socket, 同步读 greeting, 启动后台 read loop, 完成 qmp_capabilities 握手.
    public func connect() async throws {
        try openAndConnectSocket()

        // 同步读 greeting (一行 JSON, 必须含 "QMP" 字段)
        let greetingLine = try readLineBlocking(timeoutSec: connectTimeoutSec)
        guard let obj = try? JSONSerialization.jsonObject(with: greetingLine) as? [String: Any],
              obj["QMP"] != nil
        else {
            throw QmpError.protocolError(reason: "缺 greeting (期望含 QMP 字段)")
        }

        // 起 read loop (后台串行 queue, 跑 blocking recv)
        readQueue.async { [weak self] in self?.readLoop() }

        // 发 qmp_capabilities 进入命令模式
        _ = try await executeRaw("qmp_capabilities", argumentsObject: nil)

        state.withLock { $0.connected = true }
    }

    /// 关闭 socket, 取消所有未完成命令 (resume with .closed). 幂等.
    public func close() {
        let (alreadyClosed, pending, fdToClose) = state.withLock { s -> (Bool, [String: CheckedContinuation<Data, Error>], Int32) in
            if s.closed { return (true, [:], -1) }
            s.closed = true
            let p = s.pendingCommands
            s.pendingCommands.removeAll()
            let f = s.fd
            s.fd = -1
            return (false, p, f)
        }
        if alreadyClosed { return }

        if fdToClose >= 0 {
            shutdown(fdToClose, SHUT_RDWR)
            Darwin.close(fdToClose)
        }
        eventContinuation.finish()
        for (_, cont) in pending {
            cont.resume(throwing: QmpError.closed)
        }
    }

    // MARK: - 公共类型化命令

    /// query-status: 取当前 vm 状态 (running / paused / shutdown / ...)
    public func queryStatus() async throws -> QmpStatus {
        let returnData = try await executeRaw("query-status", argumentsObject: nil)
        return try JSONDecoder().decode(QmpStatus.self, from: returnData)
    }

    /// system_powerdown: 给 guest 发 ACPI 关机信号 (相当于按机箱电源键).
    /// guest OS 自己决定是否响应 (大多数 Linux/Win 默认会).
    public func systemPowerdown() async throws {
        _ = try await executeRaw("system_powerdown", argumentsObject: nil)
    }

    /// stop: 暂停 vCPU (state → paused). 设备 IO 也停, 但内存/磁盘状态保留.
    public func stop() async throws {
        _ = try await executeRaw("stop", argumentsObject: nil)
    }

    /// cont: 从 paused 恢复执行
    public func cont() async throws {
        _ = try await executeRaw("cont", argumentsObject: nil)
    }

    /// quit: QEMU 进程立即退出 (不走 ACPI shutdown, guest 不知情).
    /// 谨慎使用; 通常先 system_powerdown 等 SHUTDOWN event, 退化方案才 quit.
    public func quit() async throws {
        _ = try await executeRaw("quit", argumentsObject: nil)
    }

    /// screendump: 把当前 guest framebuffer 写到 host 文件 (PPM P6 format, 默认).
    /// QEMU 同步写完才返回 return; 调用方安全立即读取 filename.
    /// device: nil 走主显示设备 (我们配置只有一个 virtio-gpu), 多显示场景需指定.
    public func screendump(filename: String, device: String? = nil) async throws {
        var args: [String: Any] = ["filename": filename]
        if let device { args["device"] = device }
        // QEMU 默认 format=ppm; 显式带上更稳, 防上游改默认
        args["format"] = "ppm"
        _ = try await executeRaw("screendump", argumentsObject: args)
    }

    /// human-monitor-command: 包装 QMP HMP 桥接, 让我们能跑老 monitor 命令
    /// (sendkey / mouse_move / mouse_button 等; QMP 原生命令 send-key + input-send-event 也可,
    /// 但 sendkey HMP 形式更短). 返 monitor stdout 字符串.
    public func humanMonitorCommand(_ command: String) async throws -> String {
        let args: [String: Any] = ["command-line": command]
        let returnData = try await executeRaw("human-monitor-command", argumentsObject: args)
        // human-monitor-command 的 return 是字符串 (JSON encoded), 不是 dict
        if let s = try? JSONDecoder().decode(String.self, from: returnData) {
            return s
        }
        return String(data: returnData, encoding: .utf8) ?? ""
    }

    // MARK: - 内部: 通用命令执行

    /// 通用命令执行. 返回 "return" 字段的原始 JSON Data; QEMU error 抛 QmpError.qemu.
    /// argumentsObject 应为可 JSON 序列化的 [String: Any] / [Any], nil 表示无 arguments.
    private func executeRaw(_ command: String, argumentsObject: Any?) async throws -> Data {
        // 生成唯一 id (锁内)
        let (id, isClosed) = state.withLock { s -> (String, Bool) in
            if s.closed { return ("", true) }
            s.nextCmdSeq += 1
            return ("cmd-\(s.nextCmdSeq)", false)
        }
        if isClosed { throw QmpError.closed }

        // 构造命令 JSON
        var msg: [String: Any] = ["execute": command, "id": id]
        if let args = argumentsObject {
            msg["arguments"] = args
        }
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys])
        } catch {
            throw QmpError.parseError(reason: "encode command \(command): \(error)")
        }
        var lineBuf = jsonData
        lineBuf.append(0x0D)
        lineBuf.append(0x0A)
        let line = lineBuf

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            // 1) 先注册 continuation (避免响应先到, continuation 还没 register)
            let writeFd = state.withLock { s -> Int32 in
                s.pendingCommands[id] = cont
                return s.fd
            }
            guard writeFd >= 0 else {
                _ = state.withLock { $0.pendingCommands.removeValue(forKey: id) }
                cont.resume(throwing: QmpError.closed)
                return
            }

            // 2) 后写 socket (在 writeQueue 串行, 不与其他命令交错)
            writeQueue.async { [weak self] in
                guard let self else { return }
                let written = line.withUnsafeBytes { buf -> Int in
                    guard let base = buf.baseAddress else { return -1 }
                    return send(writeFd, base, buf.count, 0)
                }
                if written != line.count {
                    self.failPending(id: id, with: QmpError.socketError(
                        reason: "send \(command) short (\(written) of \(line.count))",
                        errno: errno
                    ))
                }
            }
        }
    }

    private func failPending(id: String, with error: Error) {
        let cont = state.withLock { $0.pendingCommands.removeValue(forKey: id) }
        cont?.resume(throwing: error)
    }

    // MARK: - 内部: socket 操作

    private func openAndConnectSocket() throws {
        let f = socket(AF_UNIX, SOCK_STREAM, 0)
        guard f >= 0 else {
            throw QmpError.socketError(reason: "socket() failed", errno: errno)
        }

        // SO_RCVTIMEO 用于 connect 阶段的同步读 greeting; read loop 会清掉
        var tv = timeval(tv_sec: connectTimeoutSec, tv_usec: 0)
        setsockopt(f, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(f)
            throw QmpError.socketError(reason: "socket path 太长 (\(pathBytes.count) bytes)", errno: 0)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(f, sa, addrLen)
            }
        }
        guard rc == 0 else {
            let saved = errno
            Darwin.close(f)
            throw QmpError.socketError(reason: "connect \(socketPath)", errno: saved)
        }

        state.withLock { $0.fd = f }
    }

    /// 同步读到下一个 \r\n 之间的内容 (不含 CRLF). 阻塞直到收齐或超时.
    private func readLineBlocking(timeoutSec: Int) throws -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        let f = state.withLock { $0.fd }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while Date() < deadline {
            let n = recv(f, &byte, 1, 0)
            if n <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw QmpError.timeout
                }
                throw QmpError.socketError(reason: "recv greeting", errno: errno)
            }
            buffer.append(byte)
            if buffer.count >= 2,
               buffer[buffer.count - 2] == 0x0D,
               buffer[buffer.count - 1] == 0x0A {
                return buffer.subdata(in: 0..<(buffer.count - 2))
            }
        }
        throw QmpError.timeout
    }

    // MARK: - 内部: read loop

    private func readLoop() {
        let f = state.withLock { $0.fd }
        if f < 0 { return }
        // 读 loop 期间禁用 recv 超时 (用 0,0 = 不超时)
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(f, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return recv(f, base, ptr.count, 0)
            }
            if n <= 0 {
                handleEofOrError()
                return
            }
            buffer.append(chunk, count: n)
            // 切 \r\n 行 (一次 recv 可能带多条消息或半条)
            while let crlfRange = buffer.range(of: Data([0x0D, 0x0A])) {
                let line = buffer.subdata(in: 0..<crlfRange.lowerBound)
                buffer.removeSubrange(0..<crlfRange.upperBound)
                if !line.isEmpty {
                    handleLine(line)
                }
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let id = obj["id"] as? String {
            handleResponse(id: id, obj: obj)
            return
        }
        if let event = obj["event"] as? String {
            let ts = (obj["timestamp"] as? [String: Any])?["seconds"] as? Double ?? 0
            let dataField = obj["data"] as? [String: Any] ?? [:]
            let dataJSON = (try? JSONSerialization.data(withJSONObject: dataField,
                                                        options: [.sortedKeys])) ?? Data()
            eventContinuation.yield(QmpEvent(name: event, timestamp: ts, dataJSON: dataJSON))
        }
    }

    private func handleResponse(id: String, obj: [String: Any]) {
        let cont = state.withLock { $0.pendingCommands.removeValue(forKey: id) }
        guard let cont else { return }
        if let errDict = obj["error"] as? [String: Any] {
            let cls = errDict["class"] as? String ?? "Unknown"
            let desc = errDict["desc"] as? String ?? ""
            cont.resume(throwing: QmpError.qemu(class: cls, desc: desc))
            return
        }
        let returnField = obj["return"] ?? [:] as [String: Any]
        let returnData = (try? JSONSerialization.data(withJSONObject: returnField,
                                                      options: [.sortedKeys])) ?? Data()
        cont.resume(returning: returnData)
    }

    private func handleEofOrError() {
        let pending = state.withLock { s -> [String: CheckedContinuation<Data, Error>] in
            let p = s.pendingCommands
            s.pendingCommands.removeAll()
            if !s.closed {
                s.closed = true
                if s.fd >= 0 {
                    Darwin.close(s.fd)
                    s.fd = -1
                }
            }
            return p
        }
        eventContinuation.finish()
        for (_, c) in pending {
            c.resume(throwing: QmpError.closed)
        }
    }
}
