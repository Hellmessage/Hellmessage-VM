// HVMQemuTests/QemuPathsTests.swift
// 路径解析测试: 主要覆盖 env var 覆盖路径与失败时的错误形态.
// 不测 Bundle.main / cwd 链路 (那要起 .app 才稳定, 留给 verify 阶段).

import XCTest
@testable import HVMQemu

final class QemuPathsTests: XCTestCase {

    /// 在 tmp 目录搭一个最小 fake QEMU 根: bin/qemu-system-aarch64 + share/qemu/edk2-aarch64-code.fd
    private func makeFakeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-qemu-paths-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let share = root.appendingPathComponent("share/qemu", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        // 用 echo 当 fake binary, 必须 +x
        let binFile = bin.appendingPathComponent("qemu-system-aarch64")
        try "#!/bin/sh\necho fake\n".data(using: .utf8)!.write(to: binFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binFile.path)
        // 空 firmware 文件
        try Data().write(to: share.appendingPathComponent("edk2-aarch64-code.fd"))
        return root
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // 设/清环境变量, 避免污染其他测试
    private func withEnv(_ key: String, _ value: String?, body: () throws -> Void) rethrows {
        let saved = ProcessInfo.processInfo.environment[key]
        if let v = value { setenv(key, v, 1) } else { unsetenv(key) }
        defer {
            if let s = saved { setenv(key, s, 1) } else { unsetenv(key) }
        }
        try body()
    }

    func testEnvVarOverrideWins() throws {
        let root = try makeFakeRoot()
        defer { cleanup(root) }
        try withEnv(QemuPaths.rootEnvVar, root.path) {
            let resolved = try QemuPaths.resolveRoot()
            XCTAssertEqual(resolved.path, root.path)
        }
    }

    func testQemuBinaryThroughEnvOverride() throws {
        let root = try makeFakeRoot()
        defer { cleanup(root) }
        try withEnv(QemuPaths.rootEnvVar, root.path) {
            let bin = try QemuPaths.qemuBinary()
            XCTAssertEqual(bin.lastPathComponent, "qemu-system-aarch64")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin.path))
        }
    }

    func testEdk2FirmwareThroughEnvOverride() throws {
        let root = try makeFakeRoot()
        defer { cleanup(root) }
        try withEnv(QemuPaths.rootEnvVar, root.path) {
            let fw = try QemuPaths.edk2Firmware()
            XCTAssertEqual(fw.lastPathComponent, "edk2-aarch64-code.fd")
        }
    }

    /// env var 指向不存在路径 + 没装 .app + 仓库可能不在 cwd → 应该抛 rootMissing
    /// (本测试假设 cwd 不含 third_party/qemu; 在仓库里跑可能误命中, 故 skip-if-found)
    func testThrowsWhenAllCandidatesAbsent() throws {
        try withEnv(QemuPaths.rootEnvVar, "/nonexistent-\(UUID().uuidString)") {
            // 兜底链路若意外命中真实仓库的 third_party/qemu/, 跳过本断言
            // (例如开发期 swift test 时 cwd 在仓库根)
            do {
                _ = try QemuPaths.resolveRoot()
                throw XCTSkip("当前 cwd/Bundle 链路意外命中了真实 QEMU 根, skip 此负面测试")
            } catch is QemuPaths.NotFoundError {
                // 期望路径
            } catch is XCTSkip {
                throw XCTSkip("当前 cwd/Bundle 链路意外命中了真实 QEMU 根, skip 此负面测试")
            } catch {
                XCTFail("期望 QemuPaths.NotFoundError, 实际 \(error)")
            }
        }
    }
}
