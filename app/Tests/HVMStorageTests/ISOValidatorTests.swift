// HVMStorageTests/ISOValidatorTests.swift

import XCTest
@testable import HVMStorage
@testable import HVMCore

final class ISOValidatorTests: XCTestCase {

    func testNonexistentThrowsIsoMissing() {
        XCTAssertThrowsError(try ISOValidator.validate(at: "/no/such/file.iso")) { err in
            guard case HVMError.storage(.isoMissing) = err else {
                XCTFail("应抛 .isoMissing, 实抛 \(err)")
                return
            }
        }
    }

    func testTinyFileThrowsSizeSuspicious() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-iso-test-tiny-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(count: 100).write(to: tmp)
        XCTAssertThrowsError(try ISOValidator.validate(at: tmp.path)) { err in
            guard case HVMError.storage(.isoSizeSuspicious) = err else {
                XCTFail("应抛 .isoSizeSuspicious, 实抛 \(err)")
                return
            }
        }
    }

    func testValidSizePasses() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-iso-test-valid-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 2 MiB sparse: ftruncate 让 stat 拿到 size 但不实际写入 (APFS sparse)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        try fh.truncate(atOffset: 2 * 1024 * 1024)
        try fh.close()
        XCTAssertNoThrow(try ISOValidator.validate(at: tmp.path))
    }
}
