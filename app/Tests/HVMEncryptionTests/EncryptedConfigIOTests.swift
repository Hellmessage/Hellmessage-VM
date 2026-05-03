// HVMEncryptionTests/EncryptedConfigIOTests.swift
// AES-GCM in-place 加密 config.yaml round-trip + 错误路径覆盖.

import XCTest
import CryptoKit
@testable import HVMEncryption
@testable import HVMBundle
@testable import HVMCore

final class EncryptedConfigIOTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-enc-cfg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let r = tmpRoot { try? FileManager.default.removeItem(at: r) }
    }

    private func makeConfig(displayName: String = "Encrypted-VM") -> VMConfig {
        VMConfig(
            displayName: displayName,
            guestOS: .linux,
            engine: .qemu,
            cpuCount: 4,
            memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/os.qcow2", sizeGiB: 32, format: .qcow2)],
            networks: [],
            linux: LinuxSpec()
        )
    }

    private func makeKey() -> SymmetricKey {
        // 用确定性 32 字节 (测试可重复)
        SymmetricKey(data: Data(repeating: 0x42, count: 32))
    }

    // MARK: - round-trip

    /// save → load 同 key → 同 VMConfig
    func testRoundTripPreservesConfig() throws {
        let key = makeKey()
        let cfg = makeConfig()
        try EncryptedConfigIO.save(config: cfg, to: tmpRoot, key: key)

        let url = EncryptedConfigIO.configEncURL(tmpRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(EncryptedConfigIO.isEncrypted(at: tmpRoot))

        let loaded = try EncryptedConfigIO.load(from: tmpRoot, key: key)
        XCTAssertEqual(loaded.displayName, cfg.displayName)
        XCTAssertEqual(loaded.engine, cfg.engine)
        XCTAssertEqual(loaded.cpuCount, cfg.cpuCount)
        XCTAssertEqual(loaded.disks, cfg.disks)
    }

    /// 同 plaintext + 同 key 多次 save → 不同密文 (random nonce)
    func testSaveProducesDifferentCiphertextEachTime() throws {
        let key = makeKey()
        let cfg = makeConfig()
        try EncryptedConfigIO.save(config: cfg, to: tmpRoot, key: key)
        let bytes1 = try Data(contentsOf: EncryptedConfigIO.configEncURL(tmpRoot))

        try EncryptedConfigIO.save(config: cfg, to: tmpRoot, key: key)
        let bytes2 = try Data(contentsOf: EncryptedConfigIO.configEncURL(tmpRoot))

        // 头部 8 字节相同, 但 sealedBox (含 nonce) 不同
        XCTAssertEqual(bytes1.prefix(8), bytes2.prefix(8))
        XCTAssertNotEqual(bytes1, bytes2,
                          "AES-GCM 用 random nonce, 同 plaintext 不应有相同密文")
    }

    // MARK: - 头部格式

    /// 落盘前 8 字节: "HENC" + 0x01 + reserved
    func testFileMagicAndVersion() throws {
        let key = makeKey()
        try EncryptedConfigIO.save(config: makeConfig(), to: tmpRoot, key: key)
        let bytes = try Data(contentsOf: EncryptedConfigIO.configEncURL(tmpRoot))

        XCTAssertEqual(Array(bytes.prefix(4)),
                       [0x48, 0x45, 0x4E, 0x43],
                       "magic 应是 ASCII 'HENC'")
        XCTAssertEqual(bytes[bytes.startIndex + 4], 0x01, "format version 1")
        XCTAssertEqual(Array(bytes[bytes.startIndex + 5 ..< bytes.startIndex + 8]),
                       [0, 0, 0],
                       "reserved 3 字节应是 0")
    }

    // MARK: - 错密码

    /// 错 key load → .wrongPassword
    func testLoadWithWrongKeyThrowsWrongPassword() throws {
        let cfg = makeConfig()
        try EncryptedConfigIO.save(config: cfg, to: tmpRoot, key: makeKey())

        let wrongKey = SymmetricKey(data: Data(repeating: 0xFF, count: 32))
        XCTAssertThrowsError(try EncryptedConfigIO.load(from: tmpRoot, key: wrongKey)) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("应抛 .wrongPassword, 实抛 \(err)")
                return
            }
        }
    }

    // MARK: - 文件不存在

    func testLoadNonExistentThrowsNotFound() throws {
        XCTAssertFalse(EncryptedConfigIO.isEncrypted(at: tmpRoot))
        XCTAssertThrowsError(try EncryptedConfigIO.load(from: tmpRoot, key: makeKey())) { err in
            guard case HVMError.bundle(.notFound) = err else {
                XCTFail("应抛 .bundle(.notFound), 实抛 \(err)")
                return
            }
        }
    }

    // MARK: - 文件 corrupt

    /// magic 字节被改 → .parseFailed
    func testLoadWithCorruptMagicThrowsParseFailed() throws {
        let key = makeKey()
        try EncryptedConfigIO.save(config: makeConfig(), to: tmpRoot, key: key)
        let url = EncryptedConfigIO.configEncURL(tmpRoot)
        var bytes = try Data(contentsOf: url)
        bytes[0] = 0x00       // 破坏 magic 'H'
        try bytes.write(to: url)

        XCTAssertThrowsError(try EncryptedConfigIO.load(from: tmpRoot, key: key)) { err in
            guard case HVMError.encryption(.parseFailed) = err else {
                XCTFail("应抛 .parseFailed (magic), 实抛 \(err)")
                return
            }
        }
    }

    /// 数据被改 (auth tag 验证失败) → .wrongPassword (与"密码错"用户视角等价)
    func testLoadWithModifiedCiphertextThrowsWrongPassword() throws {
        let key = makeKey()
        try EncryptedConfigIO.save(config: makeConfig(), to: tmpRoot, key: key)
        let url = EncryptedConfigIO.configEncURL(tmpRoot)
        var bytes = try Data(contentsOf: url)
        // 改 ciphertext 中段一个字节 (跳过 8 字节 header + 12 字节 nonce)
        let i = bytes.startIndex + 8 + 12 + 5
        bytes[i] ^= 0xFF
        try bytes.write(to: url)

        XCTAssertThrowsError(try EncryptedConfigIO.load(from: tmpRoot, key: key)) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("auth tag 失败应抛 .wrongPassword, 实抛 \(err)")
                return
            }
        }
    }

    /// 文件长度不够 (header 不完整) → .parseFailed
    func testLoadWithTooShortFileThrowsParseFailed() throws {
        let url = EncryptedConfigIO.configEncURL(tmpRoot)
        try Data([0x48, 0x45, 0x4E]).write(to: url)   // 只 3 字节, 不够 header
        XCTAssertThrowsError(try EncryptedConfigIO.load(from: tmpRoot, key: makeKey())) { err in
            guard case HVMError.encryption(.parseFailed) = err else {
                XCTFail("应抛 .parseFailed, 实抛 \(err)")
                return
            }
        }
    }

    // MARK: - 跨密钥隔离

    /// 不同 master 派生的 config-key 互相不可解
    func testDifferentMasterCannotDecryptEachOther() throws {
        let master1 = try MasterKey(Data(repeating: 0x01, count: 32))
        let master2 = try MasterKey(Data(repeating: 0x02, count: 32))
        let key1 = EncryptionKDF.derive(masterKey: master1, kind: .config)
        let key2 = EncryptionKDF.derive(masterKey: master2, kind: .config)

        try EncryptedConfigIO.save(config: makeConfig(), to: tmpRoot, key: key1)
        XCTAssertThrowsError(try EncryptedConfigIO.load(from: tmpRoot, key: key2)) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("用 master2 派生的 key 解 master1 加密的 config 应失败, 实抛 \(err)")
                return
            }
        }
    }
}
