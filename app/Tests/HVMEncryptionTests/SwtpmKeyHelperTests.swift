// HVMEncryptionTests/SwtpmKeyHelperTests.swift
// SwtpmKeyHelper 行为 + 真跑 swtpm round-trip 验证.

import XCTest
import CryptoKit
@testable import HVMEncryption
@testable import HVMCore

final class SwtpmKeyHelperTests: XCTestCase {

    private var tmpDir: URL!
    private var swtpm: URL!

    override func setUpWithError() throws {
        // Unix domain socket sun_path 限 104 字符. /var/folders/.../hvm-... 已经偏长,
        // 直接走 /tmp + 8 字符 uuid 后缀, 留足够 socket 路径预算.
        let uuid8 = String(UUID().uuidString.prefix(8))
        tmpDir = URL(fileURLWithPath: "/tmp/hvm-stpm-\(uuid8)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let appPath = "/Volumes/DEVELOP/Develop/hvm-mac/build/HVM.app/Contents/Resources/QEMU/bin/swtpm"
        let url = URL(fileURLWithPath: appPath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("swtpm 不存在 (\(appPath)). 先跑 make build.")
        }
        swtpm = url
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(at: d) }
    }

    private func makeKey(seed: UInt8 = 0x77) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    // MARK: - 1. 单元: argument 字符串稳定

    func testArgumentValueStable() {
        // 修改即等于"换 key" — 改了 swtpm 解 NVRAM 失败. 防回归测试.
        XCTAssertEqual(SwtpmKeyHelper.argumentValue,
                       "fd=0,mode=aes-256-cbc,format=binary,remove=false")
    }

    // MARK: - 2. 单元: Injector flush 写 32 字节到 pipe

    func testInjectorWritesExactBytesToPipe() throws {
        let key = makeKey()
        let injector = SwtpmKeyHelper.makeInjector(key: key)
        try injector.flush()
        // pipe read 端读出来应是 32 字节 == key
        let data = try injector.pipeReadHandle.readToEnd()
        XCTAssertEqual(data?.count, 32)
        XCTAssertEqual(data, key.withUnsafeBytes { Data($0) })
    }

    /// flush 多次幂等
    func testInjectorFlushIdempotent() throws {
        let injector = SwtpmKeyHelper.makeInjector(key: makeKey())
        try injector.flush()
        XCTAssertNoThrow(try injector.flush())   // 第二次不应抛
    }

    /// 32 字节 binary 含非 UTF-8 字节 — swtpm format=binary 应接受
    func testInjectorWithNonUTF8BinaryKey() throws {
        // 0x80-0x9F 单字节非合法 UTF-8 起始; 0xFE/0xFF 必非 UTF-8
        let bytes = Data([0x80, 0xFF, 0xFE, 0x81] + Array(repeating: UInt8(0x88), count: 28))
        let key = SymmetricKey(data: bytes)
        let injector = SwtpmKeyHelper.makeInjector(key: key)
        try injector.flush()
        let read = try injector.pipeReadHandle.readToEnd()
        XCTAssertEqual(read, bytes, "binary key 应原样透传, 不做 UTF-8 转换")
    }

    // MARK: - 3. 集成: 真跑 swtpm 启动 + 重启验证 NVRAM 加密持久化

    /// 启动 swtpm with key, 等 ctrl socket 出现 (= 启动成功). 关. 重启相同 key 应仍 OK.
    func testSwtpmStartsAndPersistsWithKey() throws {
        let stateDir = tmpDir.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let ctrlPath = tmpDir.appendingPathComponent("ctrl.sock").path
        let serverPath = tmpDir.appendingPathComponent("server.sock").path
        let key = makeKey(seed: 0x55)

        // First boot
        try runSwtpmAndWaitForCtrl(stateDir: stateDir, ctrlPath: ctrlPath,
                                    serverPath: serverPath, key: key)
        let permall = stateDir.appendingPathComponent("tpm2-00.permall")
        XCTAssertTrue(FileManager.default.fileExists(atPath: permall.path),
                      "swtpm 应写出加密 NVRAM permall")
        let firstBytes = try Data(contentsOf: permall)
        XCTAssertGreaterThan(firstBytes.count, 0)

        // Second boot 用同 key — 应能读现有 permall (NVRAM 加密解密通)
        try runSwtpmAndWaitForCtrl(stateDir: stateDir, ctrlPath: ctrlPath,
                                    serverPath: serverPath, key: key)
        // permall 可能被 swtpm rewrite (state 增量), 但 swtpm 启动成功 = 解密通
    }

    /// 用错 key 启动应失败 (swtpm 解不开 NVRAM, 早退)
    func testSwtpmFailsWithWrongKey() throws {
        let stateDir = tmpDir.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let ctrlPath = tmpDir.appendingPathComponent("ctrl.sock").path
        let serverPath = tmpDir.appendingPathComponent("server.sock").path

        // Init with key A
        let keyA = makeKey(seed: 0xAA)
        try runSwtpmAndWaitForCtrl(stateDir: stateDir, ctrlPath: ctrlPath,
                                    serverPath: serverPath, key: keyA)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            stateDir.appendingPathComponent("tpm2-00.permall").path))

        // Try boot with key B (wrong) — should fail
        let keyB = makeKey(seed: 0xBB)
        XCTAssertThrowsError(try runSwtpmAndWaitForCtrl(stateDir: stateDir, ctrlPath: ctrlPath,
                                                         serverPath: serverPath, key: keyB)) { _ in
            // 任意错都行; 关键是不该静默成功
        }
    }

    // MARK: - 测试 helper

    /// 启动 swtpm 子进程, 透传 key 到 stdin, poll 等 ctrl socket 出现 (3 秒超时).
    /// 启动成功后立即 SIGTERM 关掉 (测 NVRAM 持久化, 不需要长跑).
    private func runSwtpmAndWaitForCtrl(stateDir: URL, ctrlPath: String,
                                         serverPath: String, key: SymmetricKey) throws {
        // 清掉上次留下的 socket (swtpm 启动会失败 if exist)
        unlink(ctrlPath)
        unlink(serverPath)

        let proc = Process()
        proc.executableURL = swtpm
        proc.arguments = [
            "socket",
            "--tpm2",
            "--tpmstate", "dir=\(stateDir.path)",
            "--ctrl", "type=unixio,path=\(ctrlPath),terminate",
            "--server", "type=unixio,path=\(serverPath)",
            "--flags", "startup-clear",
            "--key", SwtpmKeyHelper.argumentValue,
        ]
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        let injector = SwtpmKeyHelper.makeInjector(key: key)
        proc.standardInput = injector.pipeReadHandle

        try proc.run()
        defer {
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
        }
        try injector.flush()

        // poll ctrl socket 出现 (3 秒); 同时 swtpm 早退要立即报错
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: ctrlPath) {
                return
            }
            if !proc.isRunning {
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderrStr = String(data: errData, encoding: .utf8) ?? ""
                throw HVMError.encryption(.qemuImgFailed(
                    verb: "swtpm-start",
                    exitCode: proc.terminationStatus,
                    stderr: "swtpm 早退 (status=\(proc.terminationStatus)) stderr=\(stderrStr.prefix(500))"
                ))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HVMError.encryption(.qemuImgFailed(
            verb: "swtpm-start", exitCode: -1,
            stderr: "swtpm ctrl socket 3 秒内未出现"
        ))
    }
}
