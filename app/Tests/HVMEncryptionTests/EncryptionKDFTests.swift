// HVMEncryptionTests/EncryptionKDFTests.swift
// HKDF-SHA256 派生 4 个子 key 行为验证.

import XCTest
import CryptoKit
@testable import HVMEncryption
@testable import HVMCore

final class EncryptionKDFTests: XCTestCase {

    private func makeMaster() throws -> MasterKey {
        try MasterKey.random()
    }

    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: - 输出长度 + 类型

    func testEachSubKeyIs32Bytes() throws {
        let master = try makeMaster()
        for kind in EncryptionKDF.SubKeyKind.allCases {
            let sk = EncryptionKDF.derive(masterKey: master, kind: kind)
            XCTAssertEqual(keyData(sk).count, 32, "\(kind) 应是 32 字节 / 256 bit")
        }
    }

    func testDeriveAllReturnsAllFour() throws {
        let master = try makeMaster()
        let set = EncryptionKDF.deriveAll(masterKey: master)
        let bag = [
            keyData(set.qcow2Disk),
            keyData(set.qcow2Nvram),
            keyData(set.swtpm),
            keyData(set.config),
        ]
        // 4 个子 key 应该两两不同 (HKDF info 不同 → 输出不同)
        XCTAssertEqual(Set(bag).count, 4, "4 个子 key 应两两不同")
    }

    // MARK: - 确定性 (跨机器 portable 关键)

    /// 同 master + 同 kind 多次派生 → 同 key. 这是跨机器 portable 链上的一环.
    func testDeriveDeterministic() throws {
        let bytes = Data(repeating: 0xAB, count: 32)
        let master = try MasterKey(bytes)
        let k1 = EncryptionKDF.derive(masterKey: master, kind: .qcow2Disk)
        let k2 = EncryptionKDF.derive(masterKey: master, kind: .qcow2Disk)
        XCTAssertEqual(keyData(k1), keyData(k2))
    }

    /// 不同 master → 不同子 key (HKDF 输入是 master)
    func testDifferentMasterGivesDifferentSubkey() throws {
        let m1 = try MasterKey(Data(repeating: 0x01, count: 32))
        let m2 = try MasterKey(Data(repeating: 0x02, count: 32))
        let k1 = EncryptionKDF.derive(masterKey: m1, kind: .config)
        let k2 = EncryptionKDF.derive(masterKey: m2, kind: .config)
        XCTAssertNotEqual(keyData(k1), keyData(k2))
    }

    /// 不同 kind → 不同子 key (HKDF info 不同)
    func testDifferentKindGivesDifferentSubkey() throws {
        let master = try makeMaster()
        let pairs: [(EncryptionKDF.SubKeyKind, EncryptionKDF.SubKeyKind)] = [
            (.qcow2Disk,  .qcow2Nvram),
            (.qcow2Disk,  .swtpm),
            (.qcow2Disk,  .config),
            (.qcow2Nvram, .swtpm),
            (.qcow2Nvram, .config),
            (.swtpm,      .config),
        ]
        for (a, b) in pairs {
            let kA = EncryptionKDF.derive(masterKey: master, kind: a)
            let kB = EncryptionKDF.derive(masterKey: master, kind: b)
            XCTAssertNotEqual(keyData(kA), keyData(kB), "(\(a), \(b)) 应不同")
        }
    }

    // MARK: - SubKeyKind rawValue 稳定 (不能改, 改了等于换 key)

    func testSubKeyKindRawValueStable() throws {
        XCTAssertEqual(EncryptionKDF.SubKeyKind.qcow2Disk.rawValue,  "qcow2-disk")
        XCTAssertEqual(EncryptionKDF.SubKeyKind.qcow2Nvram.rawValue, "qcow2-nvram")
        XCTAssertEqual(EncryptionKDF.SubKeyKind.swtpm.rawValue,      "swtpm")
        XCTAssertEqual(EncryptionKDF.SubKeyKind.config.rawValue,     "config")
    }

    /// SubKeySet.key(for:) 要等于 derive(masterKey:, kind:)
    func testSubKeySetMatchesIndividualDerive() throws {
        let master = try makeMaster()
        let set = EncryptionKDF.deriveAll(masterKey: master)
        for kind in EncryptionKDF.SubKeyKind.allCases {
            let direct = EncryptionKDF.derive(masterKey: master, kind: kind)
            XCTAssertEqual(keyData(set.key(for: kind)), keyData(direct),
                           "deriveAll().key(for: \(kind)) 应等于 derive(kind: \(kind))")
        }
    }
}
