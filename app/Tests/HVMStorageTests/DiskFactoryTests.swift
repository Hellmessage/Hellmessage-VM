// HVMStorageTests/DiskFactoryTests.swift

import XCTest
@testable import HVMStorage
@testable import HVMCore

final class DiskFactoryTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-disk-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(at: d) }
    }

    func testCreateAndLogicalSize() throws {
        let url = tmpDir.appendingPathComponent("a.img")
        try DiskFactory.create(at: url, sizeGiB: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let logical = try DiskFactory.logicalBytes(at: url)
        XCTAssertEqual(logical, 1024 * 1024 * 1024)
    }

    func testCreateRejectsExistingFile() throws {
        let url = tmpDir.appendingPathComponent("b.img")
        try DiskFactory.create(at: url, sizeGiB: 1)
        XCTAssertThrowsError(try DiskFactory.create(at: url, sizeGiB: 1)) { err in
            guard case HVMError.storage(.diskAlreadyExists) = err else {
                XCTFail("应抛 .diskAlreadyExists, 实抛 \(err)")
                return
            }
        }
    }

    func testGrowOnly() throws {
        let url = tmpDir.appendingPathComponent("c.img")
        try DiskFactory.create(at: url, sizeGiB: 1)
        try DiskFactory.grow(at: url, toGiB: 4)
        XCTAssertEqual(try DiskFactory.logicalBytes(at: url), 4 * 1024 * 1024 * 1024)
    }

    func testShrinkRejected() throws {
        let url = tmpDir.appendingPathComponent("d.img")
        try DiskFactory.create(at: url, sizeGiB: 4)
        XCTAssertThrowsError(try DiskFactory.grow(at: url, toGiB: 1)) { err in
            guard case HVMError.storage(.shrinkNotSupported) = err else {
                XCTFail("应抛 .shrinkNotSupported, 实抛 \(err)")
                return
            }
        }
    }

    func testActualBytesIsSparse() throws {
        let url = tmpDir.appendingPathComponent("e.img")
        try DiskFactory.create(at: url, sizeGiB: 1)
        // sparse 文件: actual << logical
        let actual = try DiskFactory.actualBytes(at: url)
        let logical = try DiskFactory.logicalBytes(at: url)
        XCTAssertLessThan(actual, logical)
    }
}
