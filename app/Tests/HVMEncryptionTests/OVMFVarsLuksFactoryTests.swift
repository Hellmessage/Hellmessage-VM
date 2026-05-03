// HVMEncryptionTests/OVMFVarsLuksFactoryTests.swift
// 真跑 HVM 包内 qemu-img 验证 OVMF VARS 模板 → LUKS qcow2 转换 round-trip.
// fake template = 64 KiB random bytes (模拟 OVMF VARS .fd 大小).

import XCTest
import CryptoKit
@testable import HVMEncryption
@testable import HVMCore

final class OVMFVarsLuksFactoryTests: XCTestCase {

    private var tmpDir: URL!
    private var qemuImg: URL!
    private var templateURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-ovmf-luks-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let appPath = "/Volumes/DEVELOP/Develop/hvm-mac/build/HVM.app/Contents/Resources/QEMU/bin/qemu-img"
        let url = URL(fileURLWithPath: appPath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("qemu-img 不存在 (\(appPath)). 先跑 make build.")
        }
        qemuImg = url

        // 64 KiB random bytes 模拟 OVMF VARS 模板 (实际文件多在 64 KiB 量级)
        let templateBytes = (0..<(64 * 1024)).map { _ in UInt8.random(in: 0...255) }
        templateURL = tmpDir.appendingPathComponent("template.fd")
        try Data(templateBytes).write(to: templateURL)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(at: d) }
    }

    private func makeKey(seed: UInt8 = 0x88) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    // MARK: - create

    func testCreateProducesLuksQcow2FromTemplate() throws {
        let url = tmpDir.appendingPathComponent("vars.qcow2")
        try OVMFVarsLuksFactory.create(at: url,
                                        fromTemplate: templateURL,
                                        key: makeKey(),
                                        qemuImg: qemuImg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(QcowLuksFactory.isLuksEncrypted(at: url, qemuImg: qemuImg),
                      "convert 出来应是 LUKS qcow2")
    }

    /// 跨机器 portable: 同 key 应能从 LUKS qcow2 解出原模板字节
    func testRoundTripPreservesTemplateBytes() throws {
        let url = tmpDir.appendingPathComponent("rt.qcow2")
        let key = makeKey()
        try OVMFVarsLuksFactory.create(at: url,
                                        fromTemplate: templateURL,
                                        key: key,
                                        qemuImg: qemuImg)

        // 走 qemu-img convert 解回 raw, 字节对比. 用公共 LuksSecretFile (base64 形式) 写 secret.
        let decrypted = tmpDir.appendingPathComponent("decrypted.raw")
        let secret = try LuksSecretFile(key: key)
        defer { secret.cleanup() }

        let proc = Process()
        proc.executableURL = qemuImg
        proc.arguments = [
            "convert",
            "--object", "secret,id=sec0,file=\(secret.path)",
            "--image-opts", "driver=qcow2,file.filename=\(url.path),encrypt.key-secret=sec0",
            "-O", "raw",
            decrypted.path,
        ]
        proc.standardError = Pipe()
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "qemu-img convert decrypt 应成功")

        let originalBytes = try Data(contentsOf: templateURL)
        let decryptedBytes = try Data(contentsOf: decrypted)
        // qemu-img convert raw→qcow2→raw 可能 padding 到 cluster 对齐.
        // OVMF VARS 64 KiB 是 qcow2 cluster 整数倍 (default 65536), 不会 padding.
        XCTAssertEqual(originalBytes, decryptedBytes,
                       "解密后 raw 字节应等于原模板 (LUKS 不修改 plaintext)")
    }

    // MARK: - 错误路径

    func testCreateRejectsMissingTemplate() throws {
        let missingTpl = tmpDir.appendingPathComponent("nope.fd")
        let url = tmpDir.appendingPathComponent("out.qcow2")
        XCTAssertThrowsError(try OVMFVarsLuksFactory.create(at: url,
                                                              fromTemplate: missingTpl,
                                                              key: makeKey(),
                                                              qemuImg: qemuImg)) { err in
            guard case HVMError.storage(.ioError) = err else {
                XCTFail("缺模板应抛 .storage(.ioError), 实抛 \(err)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCreateRejectsExistingTarget() throws {
        let url = tmpDir.appendingPathComponent("dup.qcow2")
        try OVMFVarsLuksFactory.create(at: url,
                                        fromTemplate: templateURL,
                                        key: makeKey(),
                                        qemuImg: qemuImg)
        XCTAssertThrowsError(try OVMFVarsLuksFactory.create(at: url,
                                                              fromTemplate: templateURL,
                                                              key: makeKey(),
                                                              qemuImg: qemuImg)) { err in
            guard case HVMError.storage(.diskAlreadyExists) = err else {
                XCTFail("应抛 .diskAlreadyExists, 实抛 \(err)")
                return
            }
        }
    }

    func testCreateAutoMakesParent() throws {
        let url = tmpDir.appendingPathComponent("nested/path/vars.qcow2")
        try OVMFVarsLuksFactory.create(at: url,
                                        fromTemplate: templateURL,
                                        key: makeKey(),
                                        qemuImg: qemuImg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 跨密钥隔离

    func testDifferentKeysProduceIndependentEncryption() throws {
        let url1 = tmpDir.appendingPathComponent("a.qcow2")
        let url2 = tmpDir.appendingPathComponent("b.qcow2")
        let key1 = makeKey(seed: 0x01)
        let key2 = makeKey(seed: 0x02)

        try OVMFVarsLuksFactory.create(at: url1, fromTemplate: templateURL,
                                        key: key1, qemuImg: qemuImg)
        try OVMFVarsLuksFactory.create(at: url2, fromTemplate: templateURL,
                                        key: key2, qemuImg: qemuImg)
        let bytes1 = try Data(contentsOf: url1)
        let bytes2 = try Data(contentsOf: url2)
        // 同 plaintext + 同 LUKS algorithm + 不同 key + random salt → 必不同
        XCTAssertNotEqual(bytes1, bytes2)
    }
}
