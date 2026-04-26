// hvm-dbg/Commands/ExecCommand.swift
// hvm-dbg exec — 通过 console 自动登录 + 跑命令 + 拿输出.
//
// 完全客户端实现, 状态机由 hvm-dbg 跑, 服务端只暴露 console.read/write 两个原子 op.
//
// 流程:
//   1. 拿当前 console totalBytes 当 watermark, 后续轮询都从这个起点之后
//   2. 写 "\n" 触发 prompt
//   3. 轮询 console.read, 看 buffer 尾部:
//        - 命中 shell prompt ($ / # / %)         → 已登录, 直接跑命令
//        - 命中 "login:" / "Username:"          → 写 user + "\n", 等 "Password:"
//        - 命中 "Password:"                      → 写 password + "\n", 等 shell prompt
//   4. 用 uuid sentinel 包裹命令: echo __HVM_BEGIN_<uuid>__; <cmd>; echo __HVM_END_<uuid>__:$?
//   5. 等 END sentinel 出现, 提取 BEGIN..END 之间字节作为 stdout, 抓 exit code
//
// 安全:
//   - password 字段不打日志, 不写入 stdout/stderr
//   - 推荐 --password-from-stdin (避免命令行 history 泄露)
//   - 出错时 message 里不带密码
//
// 退出码: 0 = guest 命令成功 (exit 0), 非 0 = guest 命令失败 (透传 guest exit code, 上限 255), 6 = 超时.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct ExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "通过 console 自动登录 + 跑命令 + 拿输出 (需 guest 内 hvc0 起 getty)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "via console (目前只支持 console)")
    var via: String = "console"

    @Option(name: .long, help: "登录用户名 (省略则假定 guest 已是 logged-in shell)")
    var user: String?

    @Option(name: .long, help: "登录密码 (不推荐, 走命令行 history 会泄露; 优先用 --password-from-stdin)")
    var password: String?

    @Flag(name: .customLong("password-from-stdin"), help: "从 stdin 读一行作密码 (推荐)")
    var passwordFromStdin: Bool = false

    @Option(name: .long, help: "超时 (秒), 包括登录 + 跑命令")
    var timeout: Double = 60

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .json

    @Argument(parsing: .postTerminator,
              help: "要在 guest 跑的命令 (-- 后, 例: -- /bin/sh -c \"uname -r\")")
    var command: [String] = []

    func run() async throws {
        guard via == "console" else {
            format == .json
                ? bailJSON(HVMError.config(.invalidEnum(field: "exec.via", raw: via, allowed: ["console"])))
                : bail(HVMError.config(.invalidEnum(field: "exec.via", raw: via, allowed: ["console"])))
            return
        }
        guard !command.isEmpty else {
            format == .json
                ? bailJSON(HVMError.config(.missingField(name: "exec.command (需在 -- 后给命令)")))
                : bail(HVMError.config(.missingField(name: "exec.command (需在 -- 后给命令)")))
            return
        }

        let pwd: String? = {
            if passwordFromStdin {
                guard let line = readLine(strippingNewline: true) else { return nil }
                return line
            }
            return password
        }()

        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let session = ConsoleSession(socketPath: socketPath, timeout: timeout)
            // 1. 拿初始 watermark
            try session.refreshWatermark()
            // 2. 触发 prompt
            try session.write("\n")
            // 3. 自动登录 (若需要)
            if let u = user {
                try session.loginIfNeeded(user: u, password: pwd)
            } else {
                // 没 user: 等 shell prompt, 没等到也不强报错 (可能 guest 早已登录 + 无 prompt)
                _ = try session.waitForShellPrompt(softTimeoutSec: 5)
            }
            // 4. 跑命令
            let result = try session.runCommand(command)

            switch format {
            case .json:
                printJSON([
                    "exitCode": result.exitCode,
                    "stdout":   result.stdout,
                ])
            case .human:
                FileHandle.standardOutput.write(Data(result.stdout.utf8))
            }
            // 透传 guest exit code (上限 255), 避免 0 误报成功
            if result.exitCode != 0 {
                throw ExitCode(Int32(min(result.exitCode, 255)))
            }
        } catch let e as ExitCode {
            throw e
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

// MARK: - 客户端会话状态机

private final class ConsoleSession {
    let socketPath: String
    let deadline: Date
    private var watermark: Int = 0
    private var buffer = Data()  // watermark 之后的所有字节, 字符串匹配走它

    init(socketPath: String, timeout: Double) {
        self.socketPath = socketPath
        self.deadline = Date().addingTimeInterval(timeout)
    }

    func refreshWatermark() throws {
        let r = try readOnce(sinceBytes: Int.max)  // 拿空, 但带回 totalBytes
        watermark = r.totalBytes
        buffer.removeAll()
    }

    func write(_ text: String) throws {
        let data = Data(text.utf8)
        _ = try IPCCall.send(socketPath: socketPath, op: .dbgConsoleWrite,
                              args: ["dataBase64": data.base64EncodedString()],
                              timeoutSec: 10)
    }

    /// 把 watermark 之后的新字节追加进 buffer; 返回是否有新字节
    @discardableResult
    func pollIncrement() throws -> Bool {
        let r = try readOnce(sinceBytes: watermark)
        if !r.data.isEmpty {
            buffer.append(r.data)
            watermark = r.totalBytes
            return true
        }
        return false
    }

    /// 等 buffer 末尾命中 patterns 之一 (大小写不敏感, 检查最后 256 字节窗口).
    /// 命中返回索引; 超时抛 ExitCode 6.
    func waitForAny(_ patterns: [String], softTimeoutSec: Double? = nil) throws -> Int {
        let local = softTimeoutSec.map { Date().addingTimeInterval($0) } ?? deadline
        while true {
            try pollIncrement()
            let tail = String(data: buffer.suffix(256), encoding: .utf8)?.lowercased() ?? ""
            for (i, p) in patterns.enumerated() where tail.contains(p.lowercased()) {
                return i
            }
            if Date() >= local || Date() >= deadline {
                throw ExitCode(6)
            }
            usleep(150_000)  // 150ms
        }
    }

    /// 软等 shell prompt, 超时不报错 (返回 false), 用于"省略 --user 假定已登录"路径.
    func waitForShellPrompt(softTimeoutSec: Double) throws -> Bool {
        do {
            _ = try waitForAny(["$ ", "# ", "% "], softTimeoutSec: softTimeoutSec)
            return true
        } catch is ExitCode {
            return false
        }
    }

    func loginIfNeeded(user: String, password: String?) throws {
        // 一次性匹配: prompt 已经在了 / login: 在 / Password: 在 / shell prompt 在
        let idx = try waitForAny(["login:", "username:", "password:", "$ ", "# ", "% "])
        switch idx {
        case 0, 1:  // login: / username:
            try write(user + "\n")
            _ = try waitForAny(["password:"])
            try writePassword(password)
            _ = try waitForAny(["$ ", "# ", "% "])
        case 2:  // password: 直接来了 (上一会话留的)
            try writePassword(password)
            _ = try waitForAny(["$ ", "# ", "% "])
        default:  // shell prompt 已经在
            break
        }
    }

    func runCommand(_ argv: [String]) throws -> (exitCode: Int, stdout: String) {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let begin = "__HVM_BEGIN_\(uuid)__"
        let end   = "__HVM_END_\(uuid)__"
        // 用 sh 包一层, 让 argv 里的引号/空格按 shell 规则解析
        let joined = argv.map { shellEscape($0) }.joined(separator: " ")
        let cmd = "echo \(begin); \(joined); echo \(end):$?"
        try write(cmd + "\n")

        // 等 END sentinel 出现; 拿到 buffer 后切片
        // waitForAny 用 256 字节尾窗判断, 这里 sentinel 不长能命中
        _ = try waitForAny([end + ":"])

        // 提取 BEGIN..END 之间内容
        let bufStr = String(data: buffer, encoding: .utf8) ?? ""
        guard let beginRange = bufStr.range(of: begin),
              let endRange   = bufStr.range(of: end + ":", range: beginRange.upperBound..<bufStr.endIndex) else {
            return (exitCode: -1, stdout: "")
        }
        // BEGIN 行后跨过自身 echo 的换行
        var startIdx = beginRange.upperBound
        if startIdx < bufStr.endIndex, bufStr[startIdx] == "\r" { startIdx = bufStr.index(after: startIdx) }
        if startIdx < bufStr.endIndex, bufStr[startIdx] == "\n" { startIdx = bufStr.index(after: startIdx) }
        var stdoutSlice = String(bufStr[startIdx..<endRange.lowerBound])
        // 去掉末尾空行
        if stdoutSlice.hasSuffix("\r\n") { stdoutSlice.removeLast(2) }
        else if stdoutSlice.hasSuffix("\n") { stdoutSlice.removeLast() }

        // 抓 exit code: END:<digits>
        let after = bufStr[endRange.upperBound...]
        let exitStr = after.prefix { $0.isNumber }
        let exitCode = Int(exitStr) ?? -1
        return (exitCode: exitCode, stdout: stdoutSlice)
    }

    // MARK: - 私有

    private func writePassword(_ pwd: String?) throws {
        guard let pwd else {
            throw HVMError.config(.missingField(name: "exec.password (需 --password 或 --password-from-stdin)"))
        }
        try write(pwd + "\n")
    }

    private func readOnce(sinceBytes: Int) throws -> (data: Data, totalBytes: Int) {
        let resp = try IPCCall.send(socketPath: socketPath, op: .dbgConsoleRead,
                                     args: ["sinceBytes": String(sinceBytes)],
                                     timeoutSec: 10)
        guard let json = resp.data?["payload"],
              let raw = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IPCDbgConsoleReadPayload.self, from: raw) else {
            throw HVMError.ipc(.decodeFailed(reason: "console.read payload"))
        }
        let bytes = Data(base64Encoded: payload.dataBase64) ?? Data()
        return (bytes, payload.totalBytes)
    }

    private func shellEscape(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
