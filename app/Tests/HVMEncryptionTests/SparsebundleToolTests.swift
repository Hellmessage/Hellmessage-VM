// HVMEncryptionTests/SparsebundleToolTests.swift
// 真跑 hdiutil 一遍 round-trip 验证 PR-1 工具层基础链路:
//   create → attach → 写读测试文件 → detach → 改密 → 重 attach 验证 → 卸载 → 删
//
// 使用最小可行 sparsebundle (50 MiB), 单测开销控制在秒级.
// 失败一律 detach + rm 兜底, 避免污染 test 机器残留挂载.
//
// 设计稿 docs/v3/ENCRYPTION.md, 真机集成验证 (T1: VZ + QEMU 能否读写自家挂载点) 留 PR-5.

import XCTest
@testable import HVMEncryption
@testable import HVMCore

final class SparsebundleToolTests: XCTestCase {

    private var tmpRoot: URL!
    private var sparsebundleURL: URL!
    private var mountpoint: URL!
    private let pw = "test-pass-\(UUID().uuidString.prefix(6))"
    private let pw2 = "new-pass-\(UUID().uuidString.prefix(6))"

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-enc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        sparsebundleURL = tmpRoot.appendingPathComponent("test.sparsebundle")
        mountpoint = tmpRoot.appendingPathComponent("mnt")
    }

    override func tearDownWithError() throws {
        // 兜底: 先卸再删, 防止前一个 case attach 失败留下挂载
        if FileManager.default.fileExists(atPath: mountpoint.path) {
            try? SparsebundleTool.detach(mountpoint: mountpoint, force: true)
        }
        if let r = tmpRoot {
            try? FileManager.default.removeItem(at: r)
        }
    }

    // MARK: - 1. 完整 create / attach / detach round-trip

    func testCreateAttachWriteReadDetach() throws {
        // create
        let opts = SparsebundleTool.CreateOptions(
            sizeBytes: 50 * 1024 * 1024,    // 50 MiB
            volumeName: "HVM-test"
        )
        try SparsebundleTool.create(at: sparsebundleURL, password: pw, options: opts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sparsebundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sparsebundleURL.appendingPathComponent("Info.plist").path),
            "sparsebundle 应该有内部 Info.plist")

        // attach
        let attached = try SparsebundleTool.attach(at: sparsebundleURL,
                                                    password: pw,
                                                    mountpoint: mountpoint)
        XCTAssertEqual(attached.mountpoint.standardizedFileURL.path,
                       mountpoint.standardizedFileURL.path)
        XCTAssertTrue(attached.devNode.hasPrefix("/dev/disk"),
                      "devNode 应是 /dev/diskN 形式, 实=\(attached.devNode)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountpoint.path))

        // 写读: 在挂载点内放文件, 卸载后内容应消失 (= 真在加密 volume 上)
        let payload = "secret-\(UUID().uuidString)".data(using: .utf8)!
        let f = mountpoint.appendingPathComponent("payload.txt")
        try payload.write(to: f)
        XCTAssertEqual(try Data(contentsOf: f), payload)

        // detach
        try SparsebundleTool.detach(mountpoint: mountpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path),
                       "卸载后挂载点内文件不应再可见")
    }

    // MARK: - 2. attach 重新挂上, 加密内容仍能读到

    func testReattachPreservesContent() throws {
        let opts = SparsebundleTool.CreateOptions(
            sizeBytes: 50 * 1024 * 1024, volumeName: "HVM-test")
        try SparsebundleTool.create(at: sparsebundleURL, password: pw, options: opts)
        _ = try SparsebundleTool.attach(at: sparsebundleURL, password: pw,
                                         mountpoint: mountpoint)
        let payload = "persist-\(UUID().uuidString)".data(using: .utf8)!
        try payload.write(to: mountpoint.appendingPathComponent("p.txt"))
        try SparsebundleTool.detach(mountpoint: mountpoint)

        // 重 attach
        _ = try SparsebundleTool.attach(at: sparsebundleURL, password: pw,
                                         mountpoint: mountpoint)
        defer { try? SparsebundleTool.detach(mountpoint: mountpoint, force: true) }

        let read = try Data(contentsOf: mountpoint.appendingPathComponent("p.txt"))
        XCTAssertEqual(read, payload, "重新挂载后写入的密文内容应仍可读")
    }

    // MARK: - 3. 错密码 attach 抛 .wrongPassword

    func testAttachWithWrongPasswordThrows() throws {
        let opts = SparsebundleTool.CreateOptions(
            sizeBytes: 50 * 1024 * 1024, volumeName: "HVM-test")
        try SparsebundleTool.create(at: sparsebundleURL, password: pw, options: opts)

        XCTAssertThrowsError(try SparsebundleTool.attach(at: sparsebundleURL,
                                                          password: "definitely-wrong",
                                                          mountpoint: mountpoint)) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("应抛 .wrongPassword, 实抛 \(err)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountpoint.path),
                       "失败 attach 不应留挂载点")
    }

    // MARK: - 4. 重复 create 拒绝覆盖

    func testCreateRejectsExisting() throws {
        let opts = SparsebundleTool.CreateOptions(
            sizeBytes: 50 * 1024 * 1024, volumeName: "HVM-test")
        try SparsebundleTool.create(at: sparsebundleURL, password: pw, options: opts)
        XCTAssertThrowsError(try SparsebundleTool.create(at: sparsebundleURL,
                                                          password: pw,
                                                          options: opts)) { err in
            guard case HVMError.encryption(.sparsebundleAlreadyExists) = err else {
                XCTFail("应抛 .sparsebundleAlreadyExists, 实抛 \(err)")
                return
            }
        }
    }

    // MARK: - 5. chpass 老密码不能再用, 新密码可用

    func testChpassRotatesPassword() throws {
        let opts = SparsebundleTool.CreateOptions(
            sizeBytes: 50 * 1024 * 1024, volumeName: "HVM-test")
        try SparsebundleTool.create(at: sparsebundleURL, password: pw, options: opts)

        try SparsebundleTool.chpass(at: sparsebundleURL,
                                     oldPassword: pw,
                                     newPassword: pw2)

        // 老密码 attach 必失败
        XCTAssertThrowsError(try SparsebundleTool.attach(at: sparsebundleURL,
                                                          password: pw,
                                                          mountpoint: mountpoint)) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("老密码 attach 应抛 .wrongPassword, 实抛 \(err)")
                return
            }
        }

        // 新密码 attach 必成功
        _ = try SparsebundleTool.attach(at: sparsebundleURL,
                                         password: pw2,
                                         mountpoint: mountpoint)
        defer { try? SparsebundleTool.detach(mountpoint: mountpoint, force: true) }
    }

    // MARK: - 6. chpass 老密码错抛 .wrongPassword

    func testChpassWithWrongOldPasswordThrows() throws {
        let opts = SparsebundleTool.CreateOptions(
            sizeBytes: 50 * 1024 * 1024, volumeName: "HVM-test")
        try SparsebundleTool.create(at: sparsebundleURL, password: pw, options: opts)
        XCTAssertThrowsError(try SparsebundleTool.chpass(at: sparsebundleURL,
                                                          oldPassword: "wrong-old",
                                                          newPassword: pw2)) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("应抛 .wrongPassword, 实抛 \(err)")
                return
            }
        }
        // 验证密码没真被改: 用原密码仍能 attach
        _ = try SparsebundleTool.attach(at: sparsebundleURL,
                                         password: pw, mountpoint: mountpoint)
        try SparsebundleTool.detach(mountpoint: mountpoint)
    }

    // MARK: - 7. info() 列已挂载 sparsebundle, detach 后消失

    func testInfoListsMountedSparsebundle() throws {
        let opts = SparsebundleTool.CreateOptions(
            sizeBytes: 50 * 1024 * 1024, volumeName: "HVM-test")
        try SparsebundleTool.create(at: sparsebundleURL, password: pw, options: opts)
        _ = try SparsebundleTool.attach(at: sparsebundleURL, password: pw,
                                         mountpoint: mountpoint)

        let entries = try SparsebundleTool.info()
        let normalizedSparse = sparsebundleURL.standardizedFileURL.path
        let mine = entries.first { entry in
            URL(fileURLWithPath: entry.imagePath).standardizedFileURL.path == normalizedSparse
        }
        XCTAssertNotNil(mine, "info() 应能列出当前挂载的 sparsebundle")
        XCTAssertEqual(mine?.mountpoint.flatMap { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       mountpoint.standardizedFileURL.path)
        XCTAssertTrue(mine?.devNode.hasPrefix("/dev/disk") ?? false)

        try SparsebundleTool.detach(mountpoint: mountpoint)
        let entriesAfter = try SparsebundleTool.info()
        let stillThere = entriesAfter.contains { entry in
            URL(fileURLWithPath: entry.imagePath).standardizedFileURL.path == normalizedSparse
        }
        XCTAssertFalse(stillThere, "detach 后 info() 不应再列此 sparsebundle")
    }

    // MARK: - 8. detach 已未挂载的 mountpoint 是 noop, 不抛

    func testDetachAlreadyUnmountedNoop() throws {
        // mountpoint 不存在
        XCTAssertNoThrow(try SparsebundleTool.detach(mountpoint: mountpoint))
        // 创建 + 立即 detach (没 attach 过)
        try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        XCTAssertNoThrow(try SparsebundleTool.detach(mountpoint: mountpoint))
    }
}
