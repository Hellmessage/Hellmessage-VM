// HVMQemuTests/SwtpmPathsTests.swift
// 路径解析测试: env override + 找不到时的错误形态.
// 不测系统路径 (/opt/homebrew/bin/swtpm), 因为依赖宿主机是否装了 brew swtpm,
// 不可重现; 由 D3a/D3b 实测验证.

import XCTest
@testable import HVMQemu

final class SwtpmPathsTests: XCTestCase {

    /// 在 tmp 写一个最小 fake swtpm: 可执行 sh script
    private func makeFakeSwtpm() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-swtpm-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("swtpm")
        try "#!/bin/sh\necho fake-swtpm $@\n".data(using: .utf8)!.write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return bin
    }

    private func cleanup(_ binURL: URL) {
        try? FileManager.default.removeItem(at: binURL.deletingLastPathComponent())
    }

    /// env / process info 改写工具 (与 QemuPathsTests 同模式)
    private func withEnv(_ key: String, _ value: String?, body: () throws -> Void) rethrows {
        let saved = ProcessInfo.processInfo.environment[key]
        if let v = value { setenv(key, v, 1) } else { unsetenv(key) }
        defer {
            if let s = saved { setenv(key, s, 1) } else { unsetenv(key) }
        }
        try body()
    }

    // MARK: - 测试

    func testEnvOverrideWins() throws {
        let fake = try makeFakeSwtpm()
        defer { cleanup(fake) }
        try withEnv(SwtpmPaths.envVar, fake.path) {
            let resolved = try SwtpmPaths.locate()
            XCTAssertEqual(resolved.path, fake.path)
        }
    }

    func testEnvOverrideMissingFileFallsThrough() throws {
        // env 指向不存在的文件 → 不应当抛, 应继续往下找 (Bundle / Homebrew / system)
        // 在测试环境通常会命中 /opt/homebrew/bin/swtpm (开发机有 brew swtpm),
        // 命中即测试通过; 否则期望 NotFoundError.
        try withEnv(SwtpmPaths.envVar, "/nonexistent-\(UUID().uuidString)") {
            do {
                let url = try SwtpmPaths.locate()
                // fallthrough 命中 brew/system swtpm; 路径必须可执行
                XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
            } catch is SwtpmPaths.NotFoundError {
                // 也合理: 测试机器没装 brew swtpm
            } catch {
                XCTFail("意外错误: \(error)")
            }
        }
    }

    func testNotFoundErrorListsSearchedPaths() throws {
        // 设非存在 env, 并临时在 PATH 上腾掉 brew swtpm 比较麻烦. 这里只验:
        // 若真触发 NotFoundError, searched 数组应非空且按预期顺序含 env 标识
        try withEnv(SwtpmPaths.envVar, "/zz-nonexistent-\(UUID().uuidString)") {
            do {
                _ = try SwtpmPaths.locate()
                throw XCTSkip("当前测试机有 brew swtpm, fallback 命中, skip 此负面测试")
            } catch let SwtpmPaths.NotFoundError.binaryMissing(searched) {
                XCTAssertFalse(searched.isEmpty)
                XCTAssertTrue(searched.contains(where: { $0.contains("env $\(SwtpmPaths.envVar)=") }),
                              "searched 应记录 env 候选: \(searched)")
            } catch is XCTSkip {
                throw XCTSkip("命中真实 swtpm, skip")
            } catch {
                XCTFail("期望 SwtpmPaths.NotFoundError, 实际 \(error)")
            }
        }
    }
}
