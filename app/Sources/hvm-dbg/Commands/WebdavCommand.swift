// WebdavCommand.swift
// hvm-dbg webdav-serve / webdav-test — 独立测 SpiceWebdavServer 的协议层 + 端到端.
//
// webdav-test: 离线跑 mux frame codec + HTTP 解析 + WebDAV 动词测试, 不接 socket.
// webdav-serve: 模拟"我作为 SPICE server 在 socket 上 listen", 等真实 spice-webdavd 客户端连;
//               同时也允许 socat 转发等手动测.

import ArgumentParser
import Foundation
import HVMCore
import HVMQemu

// MARK: - webdav-test (离线协议层自测)

struct WebdavTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webdav-test",
        abstract: "离线测 SPICE WebDAV mux frame codec + HTTP 解析 + 动词分发 (不接 socket)"
    )

    func run() async throws {
        var pass = 0
        var fail = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond { pass += 1; print("✔ \(name)") }
            else    { fail += 1; print("✗ \(name)  \(detail)") }
        }

        // ---- 0. 准备临时 root 目录 ----
        let tmp = NSTemporaryDirectory() + "hvm-webdav-test-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let roRoot = tmp + "ro-root"
        let rwRoot = tmp + "rw-root"
        try? FileManager.default.createDirectory(atPath: roRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: rwRoot, withIntermediateDirectories: true)
        try? "hello from host\n".write(toFile: roRoot + "/hello.txt", atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(atPath: roRoot + "/sub", withIntermediateDirectories: true)
        try? "nested\n".write(toFile: roRoot + "/sub/nested.txt", atomically: true, encoding: .utf8)

        // ---- 1. Mux frame round-trip ----
        let f1 = MuxFrame(clientId: 0xDEADBEEFCAFEBABE, payload: Data([0x47, 0x45, 0x54]))  // "GET"
        let encoded = f1.encode()
        check("mux frame 编码长度 = 10 + payload", encoded.count == 13, "got \(encoded.count)")
        var buf = encoded
        guard let f2 = MuxFrame.tryParse(buffer: &buf) else {
            check("mux frame 解码", false, "tryParse nil"); return
        }
        check("mux frame 解码 client_id", f2.clientId == 0xDEADBEEFCAFEBABE, "got 0x\(String(f2.clientId, radix: 16))")
        check("mux frame 解码 payload", f2.payload == Data([0x47, 0x45, 0x54]))
        check("mux frame 解码后 buffer 空", buf.isEmpty)

        // 跨边界: 半帧 (只给前 5 字节) → nil
        var partial = Data(encoded.prefix(5))
        check("mux frame 半帧 → nil", MuxFrame.tryParse(buffer: &partial) == nil)

        // size=0 关帧
        var closeBuf = Data()
        let closeF = MuxFrame(clientId: 1, payload: Data()).encode()
        closeBuf.append(closeF)
        guard let cf = MuxFrame.tryParse(buffer: &closeBuf) else {
            check("close frame 解码", false); return
        }
        check("close frame payload 空", cf.payload.isEmpty)
        check("close frame client_id", cf.clientId == 1)

        // 拼接两个 frame: 一次 tryParse 切第一个, 第二次 tryParse 切第二个
        var pipeline = Data()
        pipeline.append(MuxFrame(clientId: 5, payload: Data("AAA".utf8)).encode())
        pipeline.append(MuxFrame(clientId: 6, payload: Data("BB".utf8)).encode())
        let p1 = MuxFrame.tryParse(buffer: &pipeline)
        let p2 = MuxFrame.tryParse(buffer: &pipeline)
        check("pipeline 第一帧", p1?.clientId == 5 && p1?.payload == Data("AAA".utf8))
        check("pipeline 第二帧", p2?.clientId == 6 && p2?.payload == Data("BB".utf8))
        check("pipeline 切完空", pipeline.isEmpty)

        // ---- 2. HTTP 解析器 ----
        var parser = HTTPRequestParser()
        var hbuf = Data("OPTIONS / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n".utf8)
        let r1 = parser.tryParse(buffer: &hbuf)
        if case .ready(let req) = r1 {
            check("OPTIONS 方法", req.method == "OPTIONS")
            check("OPTIONS 路径", req.path == "/")
            check("OPTIONS Host header", req.header("Host") == "localhost")
            check("OPTIONS 解析完 buffer 空", hbuf.isEmpty)
        } else {
            check("OPTIONS 解析", false, "result=\(r1)")
        }

        // PUT 带 body
        let body = Data("hello body!".utf8)
        var putBuf = Data()
        putBuf.append(Data("PUT /code/test.txt HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
        putBuf.append(body)
        let r2 = parser.tryParse(buffer: &putBuf)
        if case .ready(let req) = r2 {
            check("PUT 方法", req.method == "PUT")
            check("PUT body 字节", req.body == body)
        } else {
            check("PUT 解析", false, "result=\(r2)")
        }

        // 不完整 header → needMore
        var partial2 = Data("GET /path HTTP/1.1\r\nHost: ".utf8)
        let r3 = parser.tryParse(buffer: &partial2)
        if case .needMore = r3 { check("partial header needMore", true) } else { check("partial header needMore", false, "result=\(r3)") }

        // ---- 3. WebDAV handler ----
        let roots: [SpiceWebdavServer.Root] = [
            .init(name: "ro", url: URL(fileURLWithPath: roRoot), readOnly: true),
            .init(name: "rw", url: URL(fileURLWithPath: rwRoot), readOnly: false),
        ]
        var byName: [String: SpiceWebdavServer.Root] = [:]
        for r in roots { byName[r.name] = r }
        let handler = WebDavHandler(roots: roots, rootsByName: byName)

        // OPTIONS
        let optResp = handler.process(request: HTTPRequest.fromTuples(method: "OPTIONS", path: "/", headers: [], body: Data()))
        check("OPTIONS 返 200", optResp.status == 200)
        check("OPTIONS 含 DAV header", optResp.headers.contains(where: { $0.0 == "DAV" }))

        // PROPFIND 根 (列 roots)
        let pf0 = handler.process(request: HTTPRequest.fromTuples(method: "PROPFIND", path: "/", headers: [("depth", "1")], body: Data()))
        check("PROPFIND / 返 207", pf0.status == 207)
        let pf0Text = String(data: pf0.body, encoding: .utf8) ?? ""
        check("PROPFIND / 含 ro root", pf0Text.contains("<D:displayname>ro</D:displayname>"))
        check("PROPFIND / 含 rw root", pf0Text.contains("<D:displayname>rw</D:displayname>"))

        // PROPFIND ro/ depth=1 列 hello.txt + sub/
        let pfRo = handler.process(request: HTTPRequest.fromTuples(method: "PROPFIND", path: "/ro/", headers: [("depth", "1")], body: Data()))
        check("PROPFIND /ro 返 207", pfRo.status == 207)
        let pfRoText = String(data: pfRo.body, encoding: .utf8) ?? ""
        check("PROPFIND /ro 列出 hello.txt", pfRoText.contains("hello.txt"))
        check("PROPFIND /ro 列出 sub", pfRoText.contains("<D:displayname>sub</D:displayname>"))
        check("PROPFIND /ro hello.txt 标 file (无 collection)", pfRoText.contains("hello.txt") && pfRoText.contains("<D:getcontentlength>"))

        // GET ro/hello.txt
        let getResp = handler.process(request: HTTPRequest.fromTuples(method: "GET", path: "/ro/hello.txt", headers: [], body: Data()))
        check("GET /ro/hello.txt 返 200", getResp.status == 200)
        check("GET /ro/hello.txt body 一致", String(data: getResp.body, encoding: .utf8) == "hello from host\n")

        // PUT 到 ro → 403
        let putRoResp = handler.process(request: HTTPRequest.fromTuples(method: "PUT", path: "/ro/new.txt", headers: [("content-length", "3")], body: Data("abc".utf8)))
        check("PUT /ro 403 read-only", putRoResp.status == 403)

        // PUT 到 rw → 201
        let putRwResp = handler.process(request: HTTPRequest.fromTuples(method: "PUT", path: "/rw/new.txt", headers: [("content-length", "5")], body: Data("hello".utf8)))
        check("PUT /rw 201", putRwResp.status == 201, "got \(putRwResp.status)")
        check("PUT /rw 文件落地", FileManager.default.fileExists(atPath: rwRoot + "/new.txt"))
        if let data = try? String(contentsOfFile: rwRoot + "/new.txt", encoding: .utf8) {
            check("PUT /rw 内容一致", data == "hello")
        }

        // MKCOL /rw/newdir → 201
        let mkResp = handler.process(request: HTTPRequest.fromTuples(method: "MKCOL", path: "/rw/newdir", headers: [], body: Data()))
        check("MKCOL /rw/newdir 201", mkResp.status == 201, "got \(mkResp.status)")
        var isDir: ObjCBool = false
        check("MKCOL 目录存在", FileManager.default.fileExists(atPath: rwRoot + "/newdir", isDirectory: &isDir) && isDir.boolValue)

        // DELETE /rw/new.txt → 204
        let delResp = handler.process(request: HTTPRequest.fromTuples(method: "DELETE", path: "/rw/new.txt", headers: [], body: Data()))
        check("DELETE /rw/new.txt 204", delResp.status == 204)
        check("DELETE 后文件消失", !FileManager.default.fileExists(atPath: rwRoot + "/new.txt"))

        // MOVE /rw/newdir → /rw/renamed → 201
        let moveResp = handler.process(request: HTTPRequest.fromTuples(method: "MOVE", path: "/rw/newdir",
                                                             headers: [("destination", "/rw/renamed")],
                                                             body: Data()))
        check("MOVE 201", moveResp.status == 201, "got \(moveResp.status)")
        check("MOVE 后目标存在", FileManager.default.fileExists(atPath: rwRoot + "/renamed"))
        check("MOVE 后源消失", !FileManager.default.fileExists(atPath: rwRoot + "/newdir"))

        // 路径 escape: GET /ro/../../etc/passwd → 404 或 403
        let escResp = handler.process(request: HTTPRequest.fromTuples(method: "GET", path: "/ro/../etc/passwd", headers: [], body: Data()))
        check("路径 escape .. 拒", escResp.status >= 400, "got \(escResp.status)")

        // 不存在的 root → 404
        let nrResp = handler.process(request: HTTPRequest.fromTuples(method: "GET", path: "/nonexistent/file", headers: [], body: Data()))
        check("不存在 root 404", nrResp.status == 404, "got \(nrResp.status)")

        // ---- 4. 响应序列化 ----
        let resp = HTTPResponse.ok(body: Data("ABC".utf8), contentType: "text/plain")
        let raw = resp.serialize()
        let rawStr = String(data: raw, encoding: .utf8) ?? ""
        check("response 序列化首行", rawStr.hasPrefix("HTTP/1.1 200 OK\r\n"))
        check("response 含 Content-Length: 3", rawStr.contains("Content-Length: 3"))
        check("response 含 body ABC", rawStr.hasSuffix("\r\n\r\nABC"))

        // ---- 总结 ----
        print("\n— 总计: \(pass + fail), 通过: \(pass), 失败: \(fail)")
        if fail > 0 {
            throw ExitCode(1)
        }
    }
}

// MARK: - webdav-serve (真 socket 模式, 端到端测)

struct WebdavServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webdav-serve",
        abstract: "独立跑 SpiceWebdavServer (作 client 连一个已存在的 socket; 主要测 QEMU 起来后)"
    )

    @Option(name: .long, help: "QEMU chardev unix socket 路径")
    var socket: String

    @Option(name: .long, parsing: .upToNextOption, help: "共享根: name=path[:ro|:rw] 可多个")
    var root: [String]

    @Flag(name: .long, help: "listen 模式: HVM 作 server 监听 socket (默认是 client 连入). 用于本机协议测.")
    var listen: Bool = false

    func run() async throws {
        guard !root.isEmpty else {
            print("错: --root 至少一条 (e.g. --root code=/Users/me/code:rw)")
            throw ExitCode(2)
        }
        var roots: [SpiceWebdavServer.Root] = []
        for spec in root {
            // 解析 name=path[:ro|:rw]
            guard let eq = spec.firstIndex(of: "=") else {
                print("错: --root 格式 name=path[:ro|:rw], 给的: \(spec)")
                throw ExitCode(2)
            }
            let name = String(spec[..<eq])
            var rest = String(spec[spec.index(after: eq)...])
            var readOnly = true
            if rest.hasSuffix(":rw") { readOnly = false; rest = String(rest.dropLast(3)) }
            else if rest.hasSuffix(":ro") { readOnly = true; rest = String(rest.dropLast(3)) }
            let url = URL(fileURLWithPath: rest)
            roots.append(.init(name: name, url: url, readOnly: readOnly))
            print("root[\(name)] = \(rest) [\(readOnly ? "ro" : "rw")]")
        }
        let server = SpiceWebdavServer(socketPath: socket, roots: roots, listenMode: listen)
        print("\(listen ? "listening on" : "connecting to") \(socket) ... (Ctrl-C 退出)")
        server.connect()
        // 跑到信号 (无 dispatchMain - 用 sleep loop 让 Ctrl-C 起效)
        while true {
            sleep(3600)
        }
    }
}
