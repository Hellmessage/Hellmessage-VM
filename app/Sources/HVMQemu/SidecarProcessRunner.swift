// HVMQemu/SidecarProcessRunner.swift
// 公共 sidecar 子进程编排. QemuProcessRunner / SwtpmRunner 都是
// 它的 thin wrapper (保留各自 public API, 内部转发到这里).
//
// 抽出原因: 多个 Runner 状态机 / lifecycle / stderr 落盘 / observer 几乎逐字相同 (>75%
// 复制); bug 修一处忘另一处的风险高. 抽到一个 class 后, 通过 Config 控制差异化行为
// (是否走 sudo, 是否带 socket-ready poll), 不同业务都跑同一份代码.
// 注: socket_vmnet 改为系统级 launchd daemon 后已不再有 SocketVmnetRunner.
//
// 状态机: .idle → .running(pid) → .exited(code) | .crashed(signal)

import Foundation
import Darwin
import HVMCore

public final class SidecarProcessRunner: @unchecked Sendable {

    public enum State: Sendable, Equatable {
        case idle
        case running(pid: Int32)
        case exited(code: Int32)
        case crashed(signal: Int32)
    }

    public enum LaunchError: Error, Sendable {
        case alreadyStarted
        case spawnFailed(reason: String)
    }

    public struct Config: Sendable {
        /// 真正要跑的 binary 绝对路径. runAsRoot=true 时 sudo 之后 exec 它.
        public let binary: URL
        public let args: [String]
        /// stderr tee 到此文件 (append). nil 丢弃; 主要用于诊断 sidecar 启动失败
        public let stderrLog: URL?
        /// true → 用 /usr/bin/sudo -n <binary> <args> 拉起;
        ///        forceKill 改用 sudo + pkill -P 杀 root 子进程 (SIGKILL 不能被 sudo forward)
        /// false → 直接 exec binary, kill 直接给 pid
        public let runAsRoot: Bool
        /// 非 nil → waitForSocketReady 会 poll 此路径出现 + 进程未早退;
        /// nil → waitForSocketReady 立即返 false (业务方未提供, 不应调)
        public let socketPathForReadyWait: String?
        /// 需要在子进程里以 fd 3, 4, 5... 出现的 unix domain socket 路径列表 (顺序对应 fd 编号).
        /// 非空时启动路径走 posix_spawn (Foundation Process 不支持 fd inheritance);
        /// 父进程 socket()/connect() 每个 path, 通过 posix_spawn_file_actions_adddup2 把
        /// 连接 fd 落到目标编号 (默认从 fd 3 开始). 与 runAsRoot 互斥 (sudo 路径无 fd 透传需求).
        public let extraFdConnections: [String]

        public init(
            binary: URL,
            args: [String],
            stderrLog: URL? = nil,
            runAsRoot: Bool = false,
            socketPathForReadyWait: String? = nil,
            extraFdConnections: [String] = []
        ) {
            self.binary = binary
            self.args = args
            self.stderrLog = stderrLog
            self.runAsRoot = runAsRoot
            self.socketPathForReadyWait = socketPathForReadyWait
            self.extraFdConnections = extraFdConnections
        }
    }

    public let config: Config

    private let lock = NSLock()
    private var _state: State = .idle
    private let process = Process()
    private let stderrPipe = Pipe()
    private var stderrFileHandle: FileHandle?
    private var observers: [(State) -> Void] = []

    /// posix_spawn 路径专用; Foundation Process 路径不用. -1 表示未启动 / 已退出.
    private var spawnedPid: pid_t = -1
    /// posix_spawn 路径监听子进程退出的 DispatchSource (kqueue 包装)
    private var spawnExitSource: DispatchSourceProcess?
    /// posix_spawn 路径自管的 stderr pipe read 端 (DispatchSourceRead 异步落盘)
    private var spawnStderrReadSource: DispatchSourceRead?
    /// posix_spawn 路径父进程持有的 socket fd (子进程 dup 走副本; 父端可关). 退出时统一 close.
    private var spawnInheritedFds: [Int32] = []

    public init(config: Config) {
        self.config = config
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// 状态变化回调 (从 process 终止线程触发, 调用方需自行 dispatch 到主线程)
    public func addStateObserver(_ cb: @escaping (State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers.append(cb)
    }

    /// 启动子进程. runAsRoot=true 时走 sudo -n 包装.
    /// extraFdConnections 非空时走 posix_spawn 路径 (Foundation Process 不支持 fd inheritance).
    public func start() throws {
        lock.lock()
        guard case .idle = _state else {
            lock.unlock()
            throw LaunchError.alreadyStarted
        }
        lock.unlock()

        // 需要 fd 透传 → posix_spawn 路径; 否则走 Foundation Process
        if !config.extraFdConnections.isEmpty {
            if config.runAsRoot {
                // 设计上互斥; runAsRoot=true 时父进程是 sudo, fd inheritance 链路过长不可控
                throw LaunchError.spawnFailed(reason:
                    "runAsRoot=true 与 extraFdConnections 互斥 (sudo 包装无法承载 fd 透传)")
            }
            try startWithPosixSpawn()
            return
        }

        // stderr 落盘准备 (append, 跨 start 累积)
        if let logURL = config.stderrLog {
            let fm = FileManager.default
            try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            stderrFileHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? stderrFileHandle?.seekToEnd()
        }

        // sudo 包装 vs 直接 exec
        if config.runAsRoot {
            // -n: 不允许 prompt; sudoers NOPASSWD 没配立即非 0 退 (避免 hang)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", config.binary.path] + config.args
        } else {
            process.executableURL = config.binary
            process.arguments = config.args
        }
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = stderrPipe

        // stderr 异步 read → 落盘
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            try? self?.stderrFileHandle?.write(contentsOf: data)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let newState: State
            switch proc.terminationReason {
            case .exit:           newState = .exited(code: proc.terminationStatus)
            case .uncaughtSignal: newState = .crashed(signal: proc.terminationStatus)
            @unknown default:     newState = .exited(code: -1)
            }
            self.lock.lock()
            self._state = newState
            let cbs = self.observers
            self.lock.unlock()
            try? self.stderrFileHandle?.close()
            self.stderrFileHandle = nil
            for cb in cbs { cb(newState) }
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stderrFileHandle?.close()
            stderrFileHandle = nil
            throw LaunchError.spawnFailed(reason: "\(error)")
        }

        lock.lock()
        _state = .running(pid: process.processIdentifier)
        lock.unlock()
    }

    /// poll 等 socket 文件出现 (or 进程早退立即 false). config.socketPathForReadyWait
    /// 为 nil 时立即返 false (业务方应不调).
    public func waitForSocketReady(timeoutSec: Int) async -> Bool {
        guard let path = config.socketPathForReadyWait else { return false }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while Date() < deadline {
            switch state {
            case .exited, .crashed: return false
            default: break
            }
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// SIGTERM. runAsRoot=true 时 sudo 通常会 forward 给子进程.
    public func terminate() {
        let pid = currentPid()
        if pid > 0 { _ = kill(pid, SIGTERM) }
    }

    /// SIGKILL. runAsRoot=true 时 SIGKILL 不能被 sudo forward, 子进程会孤儿;
    /// 兜底先 sudo + pkill -P 杀 sudo 的子进程, 再杀 sudo 自己.
    public func forceKill() {
        let pid = currentPid()
        guard pid > 0 else { return }
        if config.runAsRoot {
            // pkill -P <sudo-pid>: 杀 sudo 的所有子进程 (即真正的 sidecar binary)
            // 走 sudo 让 root 子进程也能被杀
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            pkill.arguments = ["-n", "/usr/bin/pkill", "-9", "-P", "\(pid)"]
            pkill.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            pkill.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? pkill.run()
            pkill.waitUntilExit()
        }
        _ = kill(pid, SIGKILL)
    }

    /// 阻塞等到子进程结束 (主要用于测试). posix_spawn 路径用 waitpid; Foundation Process 路径委托.
    public func waitUntilExit() {
        if !config.extraFdConnections.isEmpty {
            let pid = spawnedPid
            guard pid > 0 else { return }
            var status: Int32 = 0
            // EINTR 重试; 子进程已被回收时 waitpid 返 -1 / ECHILD, 直接退出
            while waitpid(pid, &status, 0) < 0 {
                if errno == EINTR { continue }
                break
            }
            return
        }
        process.waitUntilExit()
    }

    private func currentPid() -> pid_t {
        if !config.extraFdConnections.isEmpty {
            return spawnedPid
        }
        return process.processIdentifier
    }
}

// MARK: - posix_spawn 路径 (fd 透传)

extension SidecarProcessRunner {

    /// 执行 socket()/connect() 每个 unix 路径 + posix_spawn binary, 把每个 socket fd 落到
    /// 子进程 fd 3, 4, 5...; stdin/stdout 走 /dev/null; stderr → pipe → DispatchSourceRead 落盘.
    /// 子进程退出由 DispatchSourceProcess(exit) 触发 → waitpid 收尾 → terminationHandler.
    func startWithPosixSpawn() throws {
        // 1. 父进程 socket()/connect() 每个 daemon, 收集 fd. 失败立刻全 close + throw.
        var connectedFds: [Int32] = []
        connectedFds.reserveCapacity(config.extraFdConnections.count)
        do {
            for path in config.extraFdConnections {
                let fd = try connectUnixSocket(path: path)
                connectedFds.append(fd)
            }
        } catch {
            for fd in connectedFds { close(fd) }
            throw error
        }

        // 2. stderr pipe (子进程 write end → 父进程 read end → DispatchSourceRead → 落盘)
        var pipeFds: [Int32] = [-1, -1]
        if pipe(&pipeFds) != 0 {
            let saved = errno
            for fd in connectedFds { close(fd) }
            throw LaunchError.spawnFailed(reason: "pipe() 失败 errno=\(saved)")
        }
        let stderrReadFd  = pipeFds[0]
        let stderrWriteFd = pipeFds[1]

        // 3. 准备 stderr 落盘 FileHandle
        if let logURL = config.stderrLog {
            let fm = FileManager.default
            try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            stderrFileHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? stderrFileHandle?.seekToEnd()
        }

        // 4. file_actions: stdin/stdout → /dev/null; stderr 用 pipe write end; 每个 socket fd → fd 3+i
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(stderrReadFd); close(stderrWriteFd)
            for fd in connectedFds { close(fd) }
            throw LaunchError.spawnFailed(reason: "posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        "/dev/null".withCString { devNull in
            posix_spawn_file_actions_addopen(&actions, 0, devNull, O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, devNull, O_WRONLY, 0)
        }
        // stderr: pipe write end → fd 2
        posix_spawn_file_actions_adddup2(&actions, stderrWriteFd, 2)
        posix_spawn_file_actions_addclose(&actions, stderrWriteFd)
        posix_spawn_file_actions_addclose(&actions, stderrReadFd)
        // 透传 socket fd → 目标 fd 3, 4, 5... (dup2 在子进程做, 自动清 FD_CLOEXEC)
        for (i, fd) in connectedFds.enumerated() {
            let dst = Int32(3 + i)
            posix_spawn_file_actions_adddup2(&actions, fd, dst)
            // 父进程持有的源 fd 不在子进程里出现 (dup 后立即 close 副本)
            // 注意: 若源 fd 与目标 fd 重合 (例 fd 3 dup 到 3) 不能 close, 否则吃掉 fd
            if fd != dst {
                posix_spawn_file_actions_addclose(&actions, fd)
            }
        }

        // 5. argv + envp (C 字符串数组, spawn 后立刻 free)
        let cArgv = makeCStringArray([config.binary.path] + config.args)
        defer { freeCStringArray(cArgv) }
        let cEnvp = makeCEnvp()
        defer { freeCStringArray(cEnvp) }

        // 6. posix_spawn (不是 _spawnp; 我们传绝对路径)
        var pid: pid_t = -1
        let rc = config.binary.path.withCString { binPath -> Int32 in
            return posix_spawn(&pid, binPath, &actions, nil, cArgv, cEnvp)
        }
        // 父进程关 pipe write end (持有不再读 EOF)
        close(stderrWriteFd)
        if rc != 0 {
            close(stderrReadFd)
            for fd in connectedFds { close(fd) }
            try? stderrFileHandle?.close()
            stderrFileHandle = nil
            throw LaunchError.spawnFailed(reason: "posix_spawn rc=\(rc) errno=\(errno)")
        }

        // 7. spawn 成功; 父进程 socket fd 都已被子进程 dup 走副本, 父端 close 释放
        for fd in connectedFds { close(fd) }
        spawnInheritedFds.removeAll()
        spawnedPid = pid

        // 8. stderr 异步落盘: DispatchSourceRead 监听 read fd 可读
        let readQueue = DispatchQueue(label: "hvm.sidecar.stderr.\(pid)")
        let rs = DispatchSource.makeReadSource(fileDescriptor: stderrReadFd, queue: readQueue)
        rs.setEventHandler { [weak self] in
            let avail = Int(rs.data)
            if avail <= 0 { return }
            var buf = [UInt8](repeating: 0, count: avail)
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                return read(stderrReadFd, p.baseAddress, p.count)
            }
            if n > 0 {
                let data = Data(bytes: buf, count: n)
                try? self?.stderrFileHandle?.write(contentsOf: data)
            }
        }
        rs.setCancelHandler {
            close(stderrReadFd)
        }
        rs.resume()
        spawnStderrReadSource = rs

        // 9. 子进程退出监听 (kqueue/dispatch process source)
        let exitQueue = DispatchQueue(label: "hvm.sidecar.exit.\(pid)")
        let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: exitQueue)
        ps.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            // 收尸 + 解析 exit code / signal
            while waitpid(pid, &status, 0) < 0 {
                if errno == EINTR { continue }
                break
            }
            let newState: State
            if (status & 0x7f) == 0 {
                // WIFEXITED
                newState = .exited(code: (status >> 8) & 0xff)
            } else if (status & 0x7f) != 0x7f {
                // WIFSIGNALED
                newState = .crashed(signal: status & 0x7f)
            } else {
                newState = .exited(code: -1)
            }
            self.lock.lock()
            self._state = newState
            let cbs = self.observers
            self.spawnedPid = -1
            self.lock.unlock()
            // stderr pipe read 端 cancel + close, 关闭落盘 FileHandle
            self.spawnStderrReadSource?.cancel()
            self.spawnStderrReadSource = nil
            try? self.stderrFileHandle?.close()
            self.stderrFileHandle = nil
            for cb in cbs { cb(newState) }
            ps.cancel()
        }
        ps.resume()
        spawnExitSource = ps

        lock.lock()
        _state = .running(pid: pid)
        lock.unlock()
    }

    /// AF_UNIX socket → connect(path). 失败抛 LaunchError.
    private func connectUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw LaunchError.spawnFailed(reason: "socket(AF_UNIX) errno=\(errno) path=\(path)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path 是 C char[104]; 拷字符串 + NUL 结尾
        let bytes = Array(path.utf8)
        let maxLen = withUnsafeBytes(of: &addr.sun_path) { $0.count } - 1
        if bytes.count > maxLen {
            close(fd)
            throw LaunchError.spawnFailed(
                reason: "socket path 太长 (\(bytes.count) > \(maxLen)) path=\(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        // sun_len 在 BSD/macOS 仅做 hint, 真正的长度走 connect() socklen_t 参数;
        // 给 sizeof(sockaddr_un) 足够
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let saved = errno
            close(fd)
            throw LaunchError.spawnFailed(reason: "connect errno=\(saved) path=\(path)")
        }
        return fd
    }

    /// [String] → C 字符串数组 (NULL terminated). 调用方 defer free.
    private func makeCStringArray(_ strs: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let buf = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strs.count + 1)
        for (i, s) in strs.enumerated() {
            buf[i] = strdup(s)
        }
        buf[strs.count] = nil
        return buf
    }

    private func freeCStringArray(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var i = 0
        while let p = buf[i] { free(p); i += 1 }
        buf.deallocate()
    }

    /// 当前进程 environ → C envp (子进程继承父环境)
    private func makeCEnvp() -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let env = ProcessInfo.processInfo.environment
        let pairs = env.map { "\($0.key)=\($0.value)" }
        return makeCStringArray(pairs)
    }
}
