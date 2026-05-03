// HVMStorageTests/DiskFactoryTests.swift
// raw 路径覆盖. qcow2 路径见 DiskFactoryQcow2Tests.swift (依赖 qemu-img).

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
        try DiskFactory.create(at: url, sizeGiB: 1, format: .raw)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let logical = try DiskFactory.logicalBytes(at: url)
        XCTAssertEqual(logical, 1024 * 1024 * 1024)
    }

    func testCreateRejectsExistingFile() throws {
        let url = tmpDir.appendingPathComponent("b.img")
        try DiskFactory.create(at: url, sizeGiB: 1, format: .raw)
        XCTAssertThrowsError(try DiskFactory.create(at: url, sizeGiB: 1, format: .raw)) { err in
            guard case HVMError.storage(.diskAlreadyExists) = err else {
                XCTFail("应抛 .diskAlreadyExists, 实抛 \(err)")
                return
            }
        }
    }

    func testGrowOnly() throws {
        let url = tmpDir.appendingPathComponent("c.img")
        try DiskFactory.create(at: url, sizeGiB: 1, format: .raw)
        try DiskFactory.grow(at: url, toGiB: 4, format: .raw)
        XCTAssertEqual(try DiskFactory.logicalBytes(at: url), 4 * 1024 * 1024 * 1024)
    }

    func testShrinkRejected() throws {
        let url = tmpDir.appendingPathComponent("d.img")
        try DiskFactory.create(at: url, sizeGiB: 4, format: .raw)
        XCTAssertThrowsError(try DiskFactory.grow(at: url, toGiB: 1, format: .raw)) { err in
            guard case HVMError.storage(.shrinkNotSupported) = err else {
                XCTFail("应抛 .shrinkNotSupported, 实抛 \(err)")
                return
            }
        }
    }

    func testActualBytesIsSparse() throws {
        let url = tmpDir.appendingPathComponent("e.img")
        try DiskFactory.create(at: url, sizeGiB: 1, format: .raw)
        // sparse 文件: actual << logical
        let actual = try DiskFactory.actualBytes(at: url)
        let logical = try DiskFactory.logicalBytes(at: url)
        XCTAssertLessThan(actual, logical)
    }

    /// qcow2 必须传 qemuImg, 缺失时 create 应抛 .creationFailed (不应 silently 走 raw 分支).
    func testCreateQcow2RequiresQemuImg() throws {
        let url = tmpDir.appendingPathComponent("f.qcow2")
        XCTAssertThrowsError(try DiskFactory.create(at: url, sizeGiB: 1, format: .qcow2, qemuImg: nil)) { err in
            guard case HVMError.storage(.creationFailed) = err else {
                XCTFail("应抛 .creationFailed (缺 qemuImg), 实抛 \(err)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "qemuImg 缺失不应留下半成品文件")
    }

    /// qcow2 grow 同样要求 qemuImg.
    func testGrowQcow2RequiresQemuImg() throws {
        let url = tmpDir.appendingPathComponent("g.qcow2")
        try "fake qcow2 header".data(using: .utf8)?.write(to: url)  // 占位
        XCTAssertThrowsError(try DiskFactory.grow(at: url, toGiB: 4, format: .qcow2, qemuImg: nil)) { err in
            guard case HVMError.storage(.ioError) = err else {
                XCTFail("应抛 .ioError (缺 qemuImg), 实抛 \(err)")
                return
            }
        }
    }
}
