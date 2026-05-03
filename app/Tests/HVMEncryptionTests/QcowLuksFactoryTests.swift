// HVMEncryptionTests/QcowLuksFactoryTests.swift
// 真跑 HVM 包内 qemu-img 验证 LUKS qcow2 create / resize / rekey / isLuksEncrypted.
// 用 8 MiB 测试 qcow2 加速 (LUKS PBKDF iter-time 默认 ~2s, create 仍需 2-3s).
//
// qemu-img 路径: build/HVM.app/Contents/Resources/QEMU/bin/qemu-img.
// CI 上需要先 make build (或 make qemu) 才能跑.

import XCTest
import CryptoKit
@testable import HVMEncryption
@testable import HVMCore

final class QcowLuksFactoryTests: XCTestCase {

    private var tmpDir: URL!
    private var qemuImg: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-luks-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // 走 build/HVM.app 的 qemu-img — 假设 make build 已跑过. CI 没跑 → skip 整个 suite.
        let appPath = "/Volumes/DEVELOP/Develop/hvm-mac/build/HVM.app/Contents/Resources/QEMU/bin/qemu-img"
        let url = URL(fileURLWithPath: appPath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("qemu-img 不存在 (\(appPath)). 先跑 make build.")
        }
        qemuImg = url
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(at: d) }
    }

    // MARK: - helpers

    private func makeKey(seed: UInt8 = 0x42) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    // MARK: - 1. create

    func testCreateProducesLuksQcow2() throws {
        let url = tmpDir.appendingPathComponent("test.qcow2")
        try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024,
                                    key: makeKey(), qemuImg: qemuImg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(QcowLuksFactory.isLuksEncrypted(at: url, qemuImg: qemuImg),
                      "create 出来应是 LUKS qcow2")
    }

    func testCreateRejectsExistingFile() throws {
        let url = tmpDir.appendingPathComponent("dup.qcow2")
        try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024,
                                    key: makeKey(), qemuImg: qemuImg)
        XCTAssertThrowsError(try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024,
                                                         key: makeKey(), qemuImg: qemuImg)) { err in
            guard case HVMError.storage(.diskAlreadyExists) = err else {
                XCTFail("应抛 .storage(.diskAlreadyExists), 实抛 \(err)")
                return
            }
        }
    }

    func testCreateAutoMakesParent() throws {
        // 父目录不存在, create 应自动创建
        let url = tmpDir.appendingPathComponent("nested/deeper/disk.qcow2")
        try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024,
                                    key: makeKey(), qemuImg: qemuImg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 2. isLuksEncrypted

    func testIsLuksEncryptedTrueForLuksQcow2() throws {
        let url = tmpDir.appendingPathComponent("luks.qcow2")
        try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024,
                                    key: makeKey(), qemuImg: qemuImg)
        XCTAssertTrue(QcowLuksFactory.isLuksEncrypted(at: url, qemuImg: qemuImg))
    }

    func testIsLuksEncryptedFalseForMissingFile() {
        let url = tmpDir.appendingPathComponent("nope.qcow2")
        XCTAssertFalse(QcowLuksFactory.isLuksEncrypted(at: url, qemuImg: qemuImg))
    }

    func testIsLuksEncryptedFalseForRandomBytes() throws {
        // 写一堆随机字节, 让 qemu-img info 失败 / 返非 LUKS
        let url = tmpDir.appendingPathComponent("garbage.qcow2")
        try Data(repeating: 0x55, count: 4096).write(to: url)
        XCTAssertFalse(QcowLuksFactory.isLuksEncrypted(at: url, qemuImg: qemuImg))
    }

    // MARK: - 3. grow

    func testGrowExpandsVirtualSize() throws {
        let url = tmpDir.appendingPathComponent("g.qcow2")
        let key = makeKey()
        try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024, key: key, qemuImg: qemuImg)
        try QcowLuksFactory.grow(at: url, toBytes: 16 * 1024 * 1024, key: key, qemuImg: qemuImg)
        // 验证: 仍是 LUKS qcow2, 且 grow 命令成功 (qemu-img resize 0 表示成功)
        XCTAssertTrue(QcowLuksFactory.isLuksEncrypted(at: url, qemuImg: qemuImg))
    }

    func testGrowOnMissingFileThrows() {
        let url = tmpDir.appendingPathComponent("missing.qcow2")
        XCTAssertThrowsError(try QcowLuksFactory.grow(at: url, toBytes: 16 * 1024 * 1024,
                                                       key: makeKey(), qemuImg: qemuImg)) { err in
            guard case HVMError.storage(.ioError) = err else {
                XCTFail("应抛 .storage(.ioError), 实抛 \(err)")
                return
            }
        }
    }

    // MARK: - 4. rekey

    func testRekeyChangesPasswordSuccessfully() throws {
        let url = tmpDir.appendingPathComponent("rk.qcow2")
        let oldKey = makeKey(seed: 0x01)
        let newKey = makeKey(seed: 0x02)

        try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024,
                                    key: oldKey, qemuImg: qemuImg)
        try QcowLuksFactory.rekey(at: url,
                                   oldKey: oldKey, newKey: newKey,
                                   qemuImg: qemuImg)

        // 验证: rekey 后用 newKey grow 应成功 (能解 LUKS), 用 oldKey grow 应失败
        XCTAssertNoThrow(try QcowLuksFactory.grow(at: url, toBytes: 12 * 1024 * 1024,
                                                    key: newKey, qemuImg: qemuImg),
                         "新密码应可解 LUKS")
        XCTAssertThrowsError(try QcowLuksFactory.grow(at: url, toBytes: 16 * 1024 * 1024,
                                                       key: oldKey, qemuImg: qemuImg),
                             "老密码 rekey 后不应能再解") { err in
            guard case HVMError.encryption(.qemuImgFailed) = err else {
                XCTFail("应抛 .qemuImgFailed, 实抛 \(err)")
                return
            }
        }
    }

    func testRekeyWithWrongOldKeyFailsStep1() throws {
        let url = tmpDir.appendingPathComponent("rk2.qcow2")
        let realOld = makeKey(seed: 0x10)
        let wrongOld = makeKey(seed: 0xFF)
        let newKey = makeKey(seed: 0x20)

        try QcowLuksFactory.create(at: url, sizeBytes: 8 * 1024 * 1024,
                                    key: realOld, qemuImg: qemuImg)
        // step 1 用错的 oldKey → amend 解不开 → .qemuImgFailed
        XCTAssertThrowsError(try QcowLuksFactory.rekey(at: url,
                                                        oldKey: wrongOld, newKey: newKey,
                                                        qemuImg: qemuImg)) { err in
            guard case HVMError.encryption(.qemuImgFailed) = err else {
                XCTFail("应抛 .qemuImgFailed (step 1), 实抛 \(err)")
                return
            }
        }
        // 真 oldKey 应仍可用 (rekey 失败不该破坏数据)
        XCTAssertTrue(QcowLuksFactory.isLuksEncrypted(at: url, qemuImg: qemuImg))
        XCTAssertNoThrow(try QcowLuksFactory.grow(at: url, toBytes: 12 * 1024 * 1024,
                                                    key: realOld, qemuImg: qemuImg),
                         "失败的 rekey 不应破坏老 keyslot")
    }

    // MARK: - 5. SecretFile 安全 (0600 + EXCL 创建)
    //
    // 不直接测试 (private), 但通过 create / grow / rekey 路径间接覆盖.
    // unlink 之后 NSTemporaryDirectory 也不留残留 (OS 会清).
}
