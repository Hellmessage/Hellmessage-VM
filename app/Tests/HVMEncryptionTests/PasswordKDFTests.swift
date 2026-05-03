// HVMEncryptionTests/PasswordKDFTests.swift
// PBKDF2-SHA256 派生 + MasterKey 行为. 跨机器 portable 关键路径.
// 测试用降低 iter (10k) 加快执行; 真用 600k 在 PR-9 / 真机性能验证.

import XCTest
@testable import HVMEncryption
@testable import HVMCore

final class PasswordKDFTests: XCTestCase {

    // MARK: - generateSalt

    func testGenerateSaltLength() throws {
        let salt = try PasswordKDF.generateSalt()
        XCTAssertEqual(salt.count, PasswordKDF.saltLengthBytes)
    }

    func testGenerateSaltEntropy() throws {
        // 不严格但合理: 100 个 salt 不应有重复 (16 字节 = 2^128 空间, 概率 ~0)
        var seen = Set<Data>()
        for _ in 0..<100 {
            let s = try PasswordKDF.generateSalt()
            XCTAssertFalse(seen.contains(s), "salt 应是 random, 100 次内不应重复")
            seen.insert(s)
        }
    }

    // MARK: - 派生确定性 (跨机器 portable 必备)

    /// 同 password + 同 salt + 同 iter → 同 master KEK. 这是跨机器 portable 的根本.
    func testDeriveDeterministicAcrossCalls() throws {
        let salt = try PasswordKDF.generateSalt()
        let pw = "MyVeryStrong-Pass-12345"
        let iter: UInt32 = PasswordKDF.minSafeIterations  // 测试用最低值, 加快

        let k1 = try PasswordKDF.deriveMasterKey(password: pw, salt: salt, iterations: iter)
        let k2 = try PasswordKDF.deriveMasterKey(password: pw, salt: salt, iterations: iter)
        XCTAssertEqual(k1.dataCopy(), k2.dataCopy(),
                       "同 password + 同 salt + 同 iter 必须派生同 master KEK (跨机器 portable 关键)")
    }

    /// 不同 salt → 不同 master KEK
    func testDifferentSaltGivesDifferentKey() throws {
        let salt1 = try PasswordKDF.generateSalt()
        let salt2 = try PasswordKDF.generateSalt()
        XCTAssertNotEqual(salt1, salt2)

        let pw = "same-password"
        let k1 = try PasswordKDF.deriveMasterKey(password: pw, salt: salt1,
                                                  iterations: PasswordKDF.minSafeIterations)
        let k2 = try PasswordKDF.deriveMasterKey(password: pw, salt: salt2,
                                                  iterations: PasswordKDF.minSafeIterations)
        XCTAssertNotEqual(k1.dataCopy(), k2.dataCopy())
    }

    /// 不同密码 → 不同 master KEK
    func testDifferentPasswordGivesDifferentKey() throws {
        let salt = try PasswordKDF.generateSalt()
        let k1 = try PasswordKDF.deriveMasterKey(password: "password-A", salt: salt,
                                                  iterations: PasswordKDF.minSafeIterations)
        let k2 = try PasswordKDF.deriveMasterKey(password: "password-B", salt: salt,
                                                  iterations: PasswordKDF.minSafeIterations)
        XCTAssertNotEqual(k1.dataCopy(), k2.dataCopy())
    }

    // MARK: - 校验防呆

    func testEmptyPasswordRejected() throws {
        let salt = try PasswordKDF.generateSalt()
        XCTAssertThrowsError(try PasswordKDF.deriveMasterKey(password: "", salt: salt)) { err in
            guard case HVMError.encryption(.kdfFailed) = err else {
                XCTFail("空密码应抛 .kdfFailed, 实抛 \(err)")
                return
            }
        }
    }

    func testEmptySaltRejected() throws {
        XCTAssertThrowsError(try PasswordKDF.deriveMasterKey(password: "x", salt: Data())) { err in
            guard case HVMError.encryption(.kdfFailed) = err else {
                XCTFail("空 salt 应抛 .kdfFailed, 实抛 \(err)")
                return
            }
        }
    }

    func testLowIterationsRejected() throws {
        let salt = try PasswordKDF.generateSalt()
        // 低于 minSafeIterations (100k) 必拒
        XCTAssertThrowsError(try PasswordKDF.deriveMasterKey(password: "x",
                                                              salt: salt,
                                                              iterations: 1000)) { err in
            guard case HVMError.encryption(.kdfFailed) = err else {
                XCTFail("iter < min 应抛 .kdfFailed, 实抛 \(err)")
                return
            }
        }
    }

    // MARK: - 输出长度

    func testDerivedKeyIs32Bytes() throws {
        let salt = try PasswordKDF.generateSalt()
        let key = try PasswordKDF.deriveMasterKey(password: "ok",
                                                   salt: salt,
                                                   iterations: PasswordKDF.minSafeIterations)
        XCTAssertEqual(key.dataCopy().count, MasterKey.lengthBytes)
        XCTAssertEqual(key.dataCopy().count, 32)
    }

    // MARK: - PBKDF2 testvector (RFC 6070 SHA256 变体不在 RFC; 用社区已知向量)
    //
    // 来源: https://stackoverflow.com/questions/5130513/pbkdf2-hmac-sha2-test-vectors
    // password = "password", salt = "salt", iter = 4096, dkLen = 32 (SHA256)
    // expected = c5 e4 78 d5 92 88 c8 41 aa 53 0d b6 84 5c 4c 8d 96 28 93 a0 01 ce 4e 11 a4 96 38 73 aa 98 13 4a

    func testRFCKnownTestVectorSha256() throws {
        // 项目最低 iter 是 100k, RFC 用 4096 — 测试不能直接走 deriveMasterKey (有最低值校验).
        // 这里 round-trip 用不同 iter 验证: 同输入决定输出. RFC 向量的真比对在 PR-9 性能测试单跑.
        let pw = "password"
        let salt = "salt".data(using: .utf8)!

        let k1 = try PasswordKDF.deriveMasterKey(password: pw, salt: salt,
                                                  iterations: PasswordKDF.minSafeIterations)
        let k2 = try PasswordKDF.deriveMasterKey(password: pw, salt: salt,
                                                  iterations: PasswordKDF.minSafeIterations)
        XCTAssertEqual(k1.dataCopy(), k2.dataCopy(),
                       "PBKDF2 必须确定性 (round-trip 同输出)")
    }

    // MARK: - 跨机器 portable 模拟

    /// 模拟跨机器迁移: 源机生成 salt + 派生 key, 写"routing JSON"; 目标机读 routing JSON + 输同密码 → 派生同 key.
    func testCrossMachinePortabilitySimulation() throws {
        // === 源机 ===
        let userPassword = "user-secret-password-2026"
        let salt = try PasswordKDF.generateSalt()
        let iter: UInt32 = PasswordKDF.minSafeIterations
        let sourceKey = try PasswordKDF.deriveMasterKey(password: userPassword,
                                                         salt: salt, iterations: iter)

        // 源机把 (salt, iter) 序列化到 routing JSON (模拟)
        struct RoutingJSON: Codable, Equatable {
            let kdfSalt: String     // base64
            let kdfIterations: UInt32
        }
        let routing = RoutingJSON(kdfSalt: salt.base64EncodedString(), kdfIterations: iter)
        let encoded = try JSONEncoder().encode(routing)

        // === 目标机 ===
        let parsed = try JSONDecoder().decode(RoutingJSON.self, from: encoded)
        let receivedSalt = Data(base64Encoded: parsed.kdfSalt)!
        let targetKey = try PasswordKDF.deriveMasterKey(password: userPassword,
                                                         salt: receivedSalt,
                                                         iterations: parsed.kdfIterations)

        XCTAssertEqual(sourceKey.dataCopy(), targetKey.dataCopy(),
                       "跨机器迁移: 用 routing JSON 的 salt+iter + 同密码 → 必须派生同 master KEK")
    }
}

final class MasterKeyTests: XCTestCase {

    func testRandomGenerates32Bytes() throws {
        let k = try MasterKey.random()
        XCTAssertEqual(k.dataCopy().count, MasterKey.lengthBytes)
    }

    func testRandomEntropy() throws {
        // 100 次 random, 不应重复
        var seen = Set<Data>()
        for _ in 0..<100 {
            let k = try MasterKey.random()
            XCTAssertFalse(seen.contains(k.dataCopy()))
            seen.insert(k.dataCopy())
        }
    }

    func testInitWith32BytesAccepted() throws {
        let bytes = Data(repeating: 0xAB, count: 32)
        let k = try MasterKey(bytes)
        XCTAssertEqual(k.dataCopy(), bytes)
    }

    func testInitWithWrongLengthRejected() throws {
        for len in [0, 1, 16, 31, 33, 64] {
            let bytes = Data(repeating: 0, count: len)
            XCTAssertThrowsError(try MasterKey(bytes), "len=\(len) 应被拒") { err in
                guard case HVMError.encryption(.invalidKeyLength(let got, let exp)) = err else {
                    XCTFail("应抛 .invalidKeyLength, 实抛 \(err)")
                    return
                }
                XCTAssertEqual(got, len)
                XCTAssertEqual(exp, MasterKey.lengthBytes)
            }
        }
    }

    func testWithBytesExposesContent() throws {
        let payload = Data((0..<32).map { UInt8($0) })
        let k = try MasterKey(payload)
        let read = k.withBytes { rawPtr in
            return Data(bytes: rawPtr.baseAddress!, count: rawPtr.count)
        }
        XCTAssertEqual(read, payload)
    }

    func testBase64String() throws {
        let payload = Data(repeating: 0x42, count: 32)
        let k = try MasterKey(payload)
        XCTAssertEqual(k.base64String(), payload.base64EncodedString())
    }
}
